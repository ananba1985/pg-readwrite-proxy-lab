#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${COMMON_DIR}/../.." && pwd)"
CLUSTER_CONFIG="${CLUSTER_CONFIG:-${PROJECT_ROOT}/config/cluster.env}"
SECRETS_CONFIG="${SECRETS_CONFIG:-${PROJECT_ROOT}/config/secrets.env}"
POOL_USERS_FILE="${POOL_USERS_FILE:-${PROJECT_ROOT}/config/pool-users.txt}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die '请使用 root，或通过 sudo 执行此脚本。'
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少命令: ${command_name}"
}

load_cluster_config() {
  [[ -f "${CLUSTER_CONFIG}" ]] || die "缺少 ${CLUSTER_CONFIG}；请由 config/cluster.env.example 复制并填写。"
  # shellcheck disable=SC1090
  set -a
  source "${CLUSTER_CONFIG}"
  set +a

  local required=(
    PG_MAJOR PG_VERSION_FULL PGPOOL_MAJOR PGPOOL_VERSION PGPOOL_INSTALL_MODE PGPOOL_INSTALL_PREFIX
    PGPOOL_SOURCE_URL PGPOOL_SOURCE_SHA256 PG_CLIENT_PREFIX STANDBY_INSTALL_MODE POSTGRES_RPM_BUNDLE_DIR
    PG_BLOCK_SIZE_KB PG_WAL_BLOCK_SIZE_KB PG_WAL_SEG_SIZE_MB PG_OS_USER
    PRIMARY_HOST PRIMARY_PORT PRIMARY_PGDATA PRIMARY_PG_BIN_DIR PRIMARY_SERVICE PRIMARY_LISTEN_ADDRESSES
    STANDBY_HOST STANDBY_PORT STANDBY_PGDATA STANDBY_PG_BIN_DIR STANDBY_SERVICE STANDBY_LISTEN_ADDRESSES
    STANDBY_APPLICATION_NAME REPLICATION_SLOT_NAME
    PGPOOL_HOST PGPOOL_PORT PCP_PORT PGPOOL_SERVICE PGPOOL_CONFIG_DIR
    STANDBY_ADDRESS_CIDR PGPOOL_ADDRESS_CIDR ALLOWED_CLIENT_CIDRS MANAGE_FIREWALL
    REPLICATION_USER MONITOR_USER LAB_USER LAB_DATABASE PCP_USER
    MAX_WAL_SENDERS MAX_REPLICATION_SLOTS WAL_KEEP_SIZE MAX_SLOT_WAL_KEEP_SIZE
    PRIMARY_READ_WEIGHT STANDBY_READ_WEIGHT DISABLE_LOAD_BALANCE_ON_WRITE READ_LAG_THRESHOLD_SECONDS
    SR_CHECK_PERIOD HEALTH_CHECK_PERIOD HEALTH_CHECK_TIMEOUT HEALTH_CHECK_MAX_RETRIES
    HEALTH_CHECK_RETRY_DELAY CONNECT_TIMEOUT_MS NUM_INIT_CHILDREN MAX_POOL CONNECTION_LIFE_TIME
    LOG_PER_NODE_STATEMENT APPLY_PRIMARY_RESTART ALLOW_STANDBY_REINITIALIZE
  )
  local name
  for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || die "cluster.env 缺少参数: ${name}"
    [[ "${!name}" != *CHANGE_ME* ]] || die "cluster.env 参数尚未填写: ${name}"
    [[ "${!name}" != *$'\n'* ]] || die "参数不能包含换行: ${name}"
    [[ "${!name}" != *"'"* ]] || die "参数不能包含单引号: ${name}"
  done

  [[ "${PG_MAJOR}" =~ ^(14|15|16|17|18)$ ]] || die '当前自动化基线支持 PostgreSQL 14-18；旧版本需先单独适配。'
  [[ "${PG_VERSION_FULL}" =~ ^${PG_MAJOR}\.[0-9]+$ ]] || die 'PG_VERSION_FULL 必须是与 PG_MAJOR 相同的完整版本号。'
  [[ "${PGPOOL_MAJOR}" == '4.7' ]] || die '当前脚本与配置按 Pgpool-II 4.7 编写。'
  [[ "${PGPOOL_VERSION}" == '4.7.2' ]] || die '当前源码校验值只固定到 Pgpool-II 4.7.2。'
  [[ "${PGPOOL_INSTALL_MODE}" =~ ^(auto|rpm|source)$ ]] || die 'PGPOOL_INSTALL_MODE 只能是 auto、rpm 或 source。'
  [[ "${STANDBY_INSTALL_MODE}" =~ ^(auto|rpm|offline-rpm|source|preinstalled)$ ]] || die 'STANDBY_INSTALL_MODE 取值无效。'
  [[ "${PG_BLOCK_SIZE_KB}" =~ ^(1|2|4|8|16|32)$ ]] || die 'PG_BLOCK_SIZE_KB 取值无效。'
  [[ "${PG_WAL_BLOCK_SIZE_KB}" =~ ^(1|2|4|8|16|32|64)$ ]] || die 'PG_WAL_BLOCK_SIZE_KB 取值无效。'
  [[ "${PG_WAL_SEG_SIZE_MB}" =~ ^[0-9]+$ ]] || die 'PG_WAL_SEG_SIZE_MB 必须是整数。'
  [[ "${DISABLE_LOAD_BALANCE_ON_WRITE}" =~ ^(off|transaction|trans_transaction|always|dml_adaptive)$ ]] || \
    die 'DISABLE_LOAD_BALANCE_ON_WRITE 取值无效。'
  [[ "${MANAGE_FIREWALL}" =~ ^(yes|no)$ ]] || die 'MANAGE_FIREWALL 只能是 yes 或 no。'
  [[ "${APPLY_PRIMARY_RESTART}" =~ ^(yes|no)$ ]] || die 'APPLY_PRIMARY_RESTART 只能是 yes 或 no。'
  [[ "${ALLOW_STANDBY_REINITIALIZE}" =~ ^(yes|no)$ ]] || die 'ALLOW_STANDBY_REINITIALIZE 只能是 yes 或 no。'

  validate_identifier "${REPLICATION_USER}" 'REPLICATION_USER'
  validate_identifier "${MONITOR_USER}" 'MONITOR_USER'
  validate_identifier "${LAB_USER}" 'LAB_USER'
  validate_identifier "${LAB_DATABASE}" 'LAB_DATABASE'
  validate_identifier "${PCP_USER}" 'PCP_USER'
  validate_identifier "${REPLICATION_SLOT_NAME}" 'REPLICATION_SLOT_NAME'
  validate_identifier "${STANDBY_APPLICATION_NAME}" 'STANDBY_APPLICATION_NAME'
  validate_cidr "${STANDBY_ADDRESS_CIDR}" 'STANDBY_ADDRESS_CIDR'
  validate_cidr "${PGPOOL_ADDRESS_CIDR}" 'PGPOOL_ADDRESS_CIDR'

  local cidr
  IFS=',' read -r -a _client_cidrs <<<"${ALLOWED_CLIENT_CIDRS}"
  ((${#_client_cidrs[@]} > 0)) || die 'ALLOWED_CLIENT_CIDRS 不能为空。'
  for cidr in "${_client_cidrs[@]}"; do
    cidr="$(trim "${cidr}")"
    validate_cidr "${cidr}" 'ALLOWED_CLIENT_CIDRS'
    [[ "${cidr}" != '0.0.0.0/0' && "${cidr}" != '::/0' ]] || \
      die 'ALLOWED_CLIENT_CIDRS 禁止全网开放；请填写实际客户端网段。'
  done
}

load_secrets() {
  [[ -f "${SECRETS_CONFIG}" ]] || die "缺少 ${SECRETS_CONFIG}；请由 config/secrets.env.example 复制并填写。"
  local mode
  mode="$(stat -c '%a' "${SECRETS_CONFIG}" 2>/dev/null || true)"
  [[ "${mode}" == '600' || "${mode}" == '400' ]] || warn "建议执行 chmod 600 ${SECRETS_CONFIG}（当前权限 ${mode:-未知}）。"
  # shellcheck disable=SC1090
  set -a
  source "${SECRETS_CONFIG}"
  set +a

  local name
  for name in REPLICATION_PASSWORD MONITOR_PASSWORD LAB_PASSWORD PCP_PASSWORD PGPOOL_AES_KEY; do
    [[ -n "${!name:-}" ]] || die "secrets.env 缺少参数: ${name}"
    [[ "${!name}" != *CHANGE_ME* ]] || die "secrets.env 参数尚未填写: ${name}"
    [[ "${!name}" != *$'\n'* ]] || die "敏感参数不能包含换行: ${name}"
  done
  ((${#PGPOOL_AES_KEY} >= 32)) || die 'PGPOOL_AES_KEY 至少需要 32 个字符。'
}

validate_identifier() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "${label} 不是安全的 PostgreSQL 标识符: ${value}"
}

validate_cidr() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || die "${label} 必须是 CIDR: ${value}"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

detect_el_major() {
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
  # shellcheck disable=SC1091
  source /etc/os-release
  local id_like="${ID_LIKE:-}"
  [[ "${ID:-}" =~ ^(centos|rhel|rocky|almalinux)$ || "${id_like}" == *rhel* || "${id_like}" == *fedora* ]] || \
    die "仅支持 CentOS/RHEL 兼容发行版，当前为 ${PRETTY_NAME:-unknown}。"
  EL_MAJOR="${VERSION_ID%%.*}"
  [[ "${EL_MAJOR}" =~ ^(7|8|9)$ ]] || die "当前仅支持 EL 7/8/9；检测到 ${PRETTY_NAME:-unknown}。"
  CPU_ARCH="$(uname -m)"
  [[ "${CPU_ARCH}" =~ ^(x86_64|aarch64)$ ]] || die "当前仅适配 x86_64/aarch64；检测到 ${CPU_ARCH}。"
  if [[ "${EL_MAJOR}" == '7' ]]; then
    warn 'CentOS/RHEL 7 已停止主流维护：只走源码/离线包路径，正式投产前必须完成漏洞与仓库风险评审。'
  fi
  export EL_MAJOR CPU_ARCH
}

render_template() {
  local template="$1"
  local output="$2"
  shift 2
  [[ -f "${template}" ]] || die "模板不存在: ${template}"
  cp -- "${template}" "${output}"
  while (($#)); do
    (($# >= 2)) || die 'render_template 的键值参数不完整。'
    local key="$1"
    local value="$2"
    shift 2
    [[ "${value}" != *$'\n'* && "${value}" != *'|'* && "${value}" != *'&'* && "${value}" != *'\\'* ]] || \
      die "模板参数包含不支持的字符: ${key}"
    sed -i "s|{{${key}}}|${value}|g" "${output}"
  done
  if grep -Eq '\{\{[A-Z0-9_]+\}\}' "${output}"; then
    grep -En '\{\{[A-Z0-9_]+\}\}' "${output}" >&2 || true
    die "模板仍有未替换参数: ${template}"
  fi
}

replace_managed_block() {
  local target="$1"
  local marker="$2"
  local content="$3"
  [[ -f "${target}" ]] || die "目标文件不存在: ${target}"
  [[ -f "${content}" ]] || die "内容文件不存在: ${content}"
  local begin="# BEGIN ${marker}"
  local end="# END ${marker}"
  local begin_count end_count temp
  begin_count="$(grep -Fxc "${begin}" "${target}" || true)"
  end_count="$(grep -Fxc "${end}" "${target}" || true)"
  [[ "${begin_count}" == "${end_count}" && "${begin_count}" -le 1 ]] || \
    die "${target} 中的受管标记不完整或重复。"
  temp="$(mktemp)"
  awk -v begin="${begin}" -v end="${end}" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "${target}" >"${temp}"
  {
    cat "${temp}"
    printf '\n%s\n' "${begin}"
    cat "${content}"
    printf '%s\n' "${end}"
  } >"${target}"
  rm -f -- "${temp}"
}

backup_file() {
  local source_file="$1"
  local backup_dir="$2"
  [[ -e "${source_file}" ]] || return 0
  mkdir -p -- "${backup_dir}"
  cp -a -- "${source_file}" "${backup_dir}/"
}

assert_safe_pgdata() {
  local path="$1"
  [[ "${path}" == /* ]] || die "PGDATA 必须是绝对路径: ${path}"
  case "${path}" in
    /|/var|/var/lib|/var/lib/pgsql|/usr|/opt|/home)
      die "拒绝对过宽目录执行数据目录操作: ${path}"
      ;;
  esac
  [[ ${#path} -ge 12 ]] || die "PGDATA 路径过短，拒绝处理: ${path}"
}

sql_literal() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "${value}"
}

run_as_pg() {
  local bin_dir="$1"
  shift
  runuser -u "${PG_OS_USER}" -- env PATH="${bin_dir}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$@"
}

wait_for_postgres() {
  local bin_dir="$1"
  local host="$2"
  local port="$3"
  local timeout_seconds="${4:-60}"
  local elapsed=0
  while ((elapsed < timeout_seconds)); do
    if "${bin_dir}/pg_isready" -h "${host}" -p "${port}" -q; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

add_firewall_rule() {
  local cidr="$1"
  local port="$2"
  [[ "${MANAGE_FIREWALL}" == 'yes' ]] || {
    warn "MANAGE_FIREWALL=no：未添加 ${cidr} -> TCP/${port} 规则。"
    return 0
  }
  if ! systemctl is-active --quiet firewalld; then
    warn 'firewalld 未运行；未修改防火墙。请由外部防火墙放行所需流量。'
    return 0
  fi
  local family='ipv4'
  [[ "${cidr}" == *:* ]] && family='ipv6'
  local rule="rule family=\"${family}\" source address=\"${cidr}\" port port=\"${port}\" protocol=\"tcp\" accept"
  firewall-cmd --permanent --query-rich-rule="${rule}" >/dev/null 2>&1 || \
    firewall-cmd --permanent --add-rich-rule="${rule}" >/dev/null
  firewall-cmd --reload >/dev/null
  log "firewalld 已允许 ${cidr} 访问 TCP/${port}。"
}

tcp_check() {
  local host="$1"
  local port="$2"
  timeout 4 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

find_pgpool_binary() {
  local name="$1"
  local found
  found="$(command -v "${name}" 2>/dev/null || true)"
  if [[ -z "${found}" ]]; then
    found="$(find /usr /opt -type f -path "*/bin/${name}" -print -quit 2>/dev/null || true)"
  fi
  [[ -n "${found}" ]] || die "找不到 Pgpool-II 命令: ${name}"
  printf '%s' "${found}"
}
