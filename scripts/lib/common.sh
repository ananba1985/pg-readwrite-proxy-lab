#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${COMMON_DIR}/../.." && pwd)"
CLUSTER_CONFIG="${CLUSTER_CONFIG:-${PROJECT_ROOT}/config/cluster.env}"
SECRETS_CONFIG="${SECRETS_CONFIG:-${PROJECT_ROOT}/config/secrets.env}"
POOL_USERS_FILE="${POOL_USERS_FILE:-${PROJECT_ROOT}/config/pool-users.txt}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die '请使用 root，或通过 sudo 执行此脚本。'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

validate_identifier() {
  local value="$1" label="$2"
  [[ "${value}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "${label} 不是安全的 PostgreSQL 标识符: ${value}"
}

validate_ipv4() {
  local value="$1" label="$2" octet
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "${label} 必须是 IPv4 地址: ${value}"
  local old_ifs="${IFS}"
  IFS='.' read -r -a _octets <<<"${value}"
  IFS="${old_ifs}"
  for octet in "${_octets[@]}"; do
    ((10#${octet} <= 255)) || die "${label} 不是有效 IPv4 地址: ${value}"
  done
}

validate_cidr() {
  local value="$1" label="$2" address prefix
  [[ "${value}" == */* ]] || die "${label} 必须是 IPv4 CIDR: ${value}"
  address="${value%/*}"
  prefix="${value##*/}"
  validate_ipv4 "${address}" "${label}"
  [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] && ((10#${prefix} <= 32)) || die "${label} 前缀长度无效: ${value}"
}

load_cluster_config() {
  [[ -f "${CLUSTER_CONFIG}" ]] || die "缺少 ${CLUSTER_CONFIG}。"
  # shellcheck disable=SC1090
  set -a
  source "${CLUSTER_CONFIG}"
  set +a

  local required=(
    PG_MAJOR PG_VERSION_FULL DB_DISTRIBUTION DBN_VERSION_MARKER
    DB_POSTGRES_SHA256 DB_PG_BASEBACKUP_SHA256 DB_PG_CONFIG_SHA256 DB_TOOLS_SHA256 PG_OS_USER
    PGPOOL_MAJOR PGPOOL_VERSION PGPOOL_INSTALL_PREFIX PG_CLIENT_PREFIX OFFLINE_PACKAGE_DIR
    PGPOOL_PAYLOAD_FILE PGPOOL_PAYLOAD_SHA256 PG_CLIENT_PAYLOAD_FILE PG_CLIENT_PAYLOAD_SHA256
    SSHPASS_PAYLOAD_FILE SSHPASS_PAYLOAD_SHA256
    PRIMARY_HOST PRIMARY_PORT PRIMARY_PGDATA PRIMARY_PG_BIN_DIR PRIMARY_ADMIN_TOOL PRIMARY_LISTEN_ADDRESSES
    STANDBY_HOST STANDBY_PORT STANDBY_PGDATA STANDBY_PG_BIN_DIR STANDBY_ADMIN_TOOL STANDBY_LISTEN_ADDRESSES
    STANDBY_APPLICATION_NAME REPLICATION_SLOT_NAME
    PGPOOL_HOST PGPOOL_PORT PCP_PORT PGPOOL_SERVICE PGPOOL_CONFIG_DIR
    STANDBY_ADDRESS_CIDR PGPOOL_ADDRESS_CIDR ALLOWED_CLIENT_CIDRS MANAGE_FIREWALL
    REPLICATION_USER MONITOR_USER BUSINESS_USER BUSINESS_DATABASE PCP_USER
    MAX_WAL_SENDERS MAX_REPLICATION_SLOTS WAL_KEEP_SEGMENTS
    PRIMARY_READ_WEIGHT STANDBY_READ_WEIGHT DISABLE_LOAD_BALANCE_ON_WRITE READ_LAG_THRESHOLD_SECONDS
    SR_CHECK_PERIOD HEALTH_CHECK_PERIOD HEALTH_CHECK_TIMEOUT HEALTH_CHECK_MAX_RETRIES
    HEALTH_CHECK_RETRY_DELAY CONNECT_TIMEOUT_MS NUM_INIT_CHILDREN MAX_POOL CONNECTION_LIFE_TIME
    LOG_PER_NODE_STATEMENT APPLY_PRIMARY_RESTART ALLOW_STANDBY_REINITIALIZE
  )
  local name cidr
  for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || die "cluster.env 缺少参数: ${name}"
    [[ "${!name}" != *CHANGE_ME* && "${!name}" != *$'\n'* && "${!name}" != *"'"* ]] || die "cluster.env 参数不安全或未填写: ${name}"
  done

  [[ "${PG_MAJOR}" == '12' && "${PG_VERSION_FULL}" == '12.0' && "${DB_DISTRIBUTION}" == 'NebulaCM' ]] || \
    die '当前安装器只验收既有 NebulaCM PostgreSQL 12.0。'
  [[ "${PGPOOL_MAJOR}" == '4.7' && "${PGPOOL_VERSION}" == '4.7.2' ]] || die '当前安装器固定为 Pgpool-II 4.7.2。'
  [[ "${DISABLE_LOAD_BALANCE_ON_WRITE}" =~ ^(off|transaction|trans_transaction|always|dml_adaptive)$ ]] || die 'DISABLE_LOAD_BALANCE_ON_WRITE 无效。'
  [[ "${MANAGE_FIREWALL}" =~ ^(yes|no)$ ]] || die 'MANAGE_FIREWALL 只能是 yes 或 no。'
  [[ "${APPLY_PRIMARY_RESTART}" =~ ^(yes|no)$ ]] || die 'APPLY_PRIMARY_RESTART 只能是 yes 或 no。'
  [[ "${ALLOW_STANDBY_REINITIALIZE}" =~ ^(yes|no)$ ]] || die 'ALLOW_STANDBY_REINITIALIZE 只能是 yes 或 no。'

  validate_ipv4 "${PRIMARY_HOST}" PRIMARY_HOST
  validate_ipv4 "${STANDBY_HOST}" STANDBY_HOST
  validate_ipv4 "${PGPOOL_HOST}" PGPOOL_HOST
  [[ "${PRIMARY_HOST}" != "${STANDBY_HOST}" && "${PRIMARY_HOST}" != "${PGPOOL_HOST}" && "${STANDBY_HOST}" != "${PGPOOL_HOST}" ]] || die '三台服务器地址必须不同。'
  validate_cidr "${STANDBY_ADDRESS_CIDR}" STANDBY_ADDRESS_CIDR
  validate_cidr "${PGPOOL_ADDRESS_CIDR}" PGPOOL_ADDRESS_CIDR
  IFS=',' read -r -a _client_cidrs <<<"${ALLOWED_CLIENT_CIDRS}"
  ((${#_client_cidrs[@]} > 0)) || die 'ALLOWED_CLIENT_CIDRS 不能为空。'
  for cidr in "${_client_cidrs[@]}"; do
    cidr="$(trim "${cidr}")"
    validate_cidr "${cidr}" ALLOWED_CLIENT_CIDRS
    [[ "${cidr}" != '0.0.0.0/0' ]] || die '禁止向全网开放 Pgpool-II。'
  done

  for name in REPLICATION_USER MONITOR_USER BUSINESS_USER BUSINESS_DATABASE PCP_USER REPLICATION_SLOT_NAME STANDBY_APPLICATION_NAME; do
    validate_identifier "${!name}" "${name}"
  done
}

load_secrets() {
  [[ -f "${SECRETS_CONFIG}" ]] || die "缺少 ${SECRETS_CONFIG}。"
  local mode name
  mode="$(stat -c '%a' "${SECRETS_CONFIG}" 2>/dev/null || true)"
  [[ "${mode}" == '600' || "${mode}" == '400' ]] || warn "建议 chmod 600 ${SECRETS_CONFIG}（当前 ${mode:-未知}）。"
  # shellcheck disable=SC1090
  set -a
  source "${SECRETS_CONFIG}"
  set +a
  for name in REPLICATION_PASSWORD MONITOR_PASSWORD BUSINESS_PASSWORD PCP_PASSWORD PGPOOL_AES_KEY; do
    [[ -n "${!name:-}" && "${!name}" != *CHANGE_ME* && "${!name}" != *$'\n'* ]] || die "secrets.env 参数无效: ${name}"
  done
  ((${#PGPOOL_AES_KEY} >= 32)) || die 'PGPOOL_AES_KEY 至少需要 32 个字符。'
}

offline_file() {
  local name="$1" package_dir="${OFFLINE_PACKAGE_DIR}"
  [[ "${name}" != */* && "${name}" != *'..'* ]] || die "离线载荷文件名不安全: ${name}"
  [[ "${package_dir}" == /* ]] || package_dir="${PROJECT_ROOT}/${package_dir}"
  printf '%s/%s' "${package_dir}" "${name}"
}

verify_sha256() {
  local file="$1" expected="$2" label="$3" actual
  [[ -f "${file}" ]] || die "缺少${label}: ${file}"
  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "${label} SHA256 不匹配: ${file}"
}

validate_offline_payloads() {
  verify_sha256 "$(offline_file "${PGPOOL_PAYLOAD_FILE}")" "${PGPOOL_PAYLOAD_SHA256}" 'Pgpool-II 载荷'
  verify_sha256 "$(offline_file "${PG_CLIENT_PAYLOAD_FILE}")" "${PG_CLIENT_PAYLOAD_SHA256}" 'PostgreSQL 客户端载荷'
  verify_sha256 "$(offline_file "${SSHPASS_PAYLOAD_FILE}")" "${SSHPASS_PAYLOAD_SHA256}" 'sshpass 载荷'
}

detect_el_major() {
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
  # shellcheck disable=SC1091
  source /etc/os-release
  local id_like="${ID_LIKE:-}"
  [[ "${ID:-}" =~ ^(centos|rhel|rocky|almalinux)$ || "${id_like}" == *rhel* || "${id_like}" == *fedora* ]] || die "仅支持 CentOS/RHEL 兼容发行版。"
  EL_MAJOR="${VERSION_ID%%.*}"
  CPU_ARCH="$(uname -m)"
  [[ "${EL_MAJOR}" == '7' && "${CPU_ARCH}" == 'aarch64' ]] || die "当前离线载荷只验收 CentOS/RHEL 7 aarch64；检测到 ${PRETTY_NAME:-unknown} ${CPU_ARCH}。"
  warn 'CentOS 7 与 PostgreSQL 12 均已停止主流维护；正式投产前必须完成安全与升级评审。'
  export EL_MAJOR CPU_ARCH
}

verify_nebula_runtime() {
  local bin_dir="$1" admin_tool="$2" label="$3" prefix marker
  prefix="${bin_dir%/bin}"
  for file in postgres pg_basebackup pg_config pg_ctl pg_isready psql; do
    [[ -x "${bin_dir}/${file}" ]] || die "${label} 缺少 ${bin_dir}/${file}"
  done
  [[ -x "${admin_tool}" ]] || die "${label} 缺少厂商管理入口 ${admin_tool}"
  [[ -f "${prefix}/dbn_version" ]] || die "${label} 缺少 ${prefix}/dbn_version"
  marker="$(tr -d '\r\n' <"${prefix}/dbn_version")"
  [[ "${marker}" == "${DBN_VERSION_MARKER}" ]] || die "${label} 不是已验收的 NebulaCM 12.0 发行版。"
  [[ "$("${bin_dir}/postgres" --version)" == 'postgres (PostgreSQL) 12.0' ]] || die "${label} PostgreSQL 版本不等于 12.0。"
  verify_sha256 "${bin_dir}/postgres" "${DB_POSTGRES_SHA256}" "${label} postgres"
  verify_sha256 "${bin_dir}/pg_basebackup" "${DB_PG_BASEBACKUP_SHA256}" "${label} pg_basebackup"
  verify_sha256 "${bin_dir}/pg_config" "${DB_PG_CONFIG_SHA256}" "${label} pg_config"
  verify_sha256 "${admin_tool}" "${DB_TOOLS_SHA256}" "${label} tools"
}

nebula_admin_query() {
  local admin_tool="$1" port="$2" database="$3" sql="$4"
  (cd /tmp && "${admin_tool}" psql -d "${database}" -p "${port}" -c "${sql}")
}

nebula_admin_file() {
  local admin_tool="$1" port="$2" database="$3" sql_file="$4"
  (cd /tmp && "${admin_tool}" psql -d "${database}" -p "${port}" -f "${sql_file}")
}

run_as_pg() {
  local bin_dir="$1"
  shift
  runuser -u "${PG_OS_USER}" -- env PATH="${bin_dir}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c 'cd /tmp && exec "$@"' bash "$@"
}

pg_ctl_is_running() {
  local bin_dir="$1" pgdata="$2"
  run_as_pg "${bin_dir}" "${bin_dir}/pg_ctl" -D "${pgdata}" status >/dev/null 2>&1
}

pg_ctl_stop() {
  local bin_dir="$1" pgdata="$2"
  if pg_ctl_is_running "${bin_dir}" "${pgdata}"; then
    run_as_pg "${bin_dir}" "${bin_dir}/pg_ctl" -w -t 120 -D "${pgdata}" -m fast stop
  fi
}

pg_ctl_start() {
  local bin_dir="$1" pgdata="$2" log_file="$3"
  [[ ! -e "${log_file}" ]] || chown "${PG_OS_USER}:${PG_OS_USER}" "${log_file}"
  install -d -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 700 "$(dirname "${log_file}")"
  run_as_pg "${bin_dir}" "${bin_dir}/pg_ctl" -w -t 120 -D "${pgdata}" -l "${log_file}" start
}

wait_for_postgres() {
  local bin_dir="$1" host="$2" port="$3" timeout_seconds="${4:-60}" elapsed=0
  while ((elapsed < timeout_seconds)); do
    "${bin_dir}/pg_isready" -h "${host}" -p "${port}" -q && return 0
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

render_template() {
  local template="$1" output="$2" key value
  shift 2
  [[ -f "${template}" ]] || die "模板不存在: ${template}"
  cp -- "${template}" "${output}"
  while (($#)); do
    (($# >= 2)) || die 'render_template 键值参数不完整。'
    key="$1"; value="$2"; shift 2
    [[ "${value}" != *$'\n'* && "${value}" != *'|'* && "${value}" != *'&'* && "${value}" != *'\\'* ]] || die "模板参数包含不支持字符: ${key}"
    sed -i "s|{{${key}}}|${value}|g" "${output}"
  done
  ! grep -Eq '\{\{[A-Z0-9_]+\}\}' "${output}" || die "模板仍有未替换参数: ${template}"
}

replace_managed_block() {
  local target="$1" marker="$2" content="$3" begin end begin_count end_count temp
  [[ -f "${target}" && -f "${content}" ]] || die "受管配置文件不存在: ${target} / ${content}"
  begin="# BEGIN ${marker}"; end="# END ${marker}"
  begin_count="$(grep -Fxc "${begin}" "${target}" || true)"
  end_count="$(grep -Fxc "${end}" "${target}" || true)"
  [[ "${begin_count}" == "${end_count}" && "${begin_count}" -le 1 ]] || die "${target} 受管标记不完整或重复。"
  temp="$(mktemp)"
  awk -v begin="${begin}" -v end="${end}" '$0==begin{skip=1;next}$0==end{skip=0;next}!skip{print}' "${target}" >"${temp}"
  { cat "${temp}"; printf '\n%s\n' "${begin}"; cat "${content}"; printf '%s\n' "${end}"; } >"${target}"
  rm -f -- "${temp}"
}

backup_file() {
  local source_file="$1" backup_dir="$2"
  [[ -e "${source_file}" ]] || return 0
  mkdir -p -- "${backup_dir}"
  cp -a -- "${source_file}" "${backup_dir}/"
}

assert_safe_pgdata() {
  local path="$1"
  [[ "${path}" == /* && ${#path} -ge 12 ]] || die "PGDATA 路径不安全: ${path}"
  case "${path}" in /|/var|/usr|/opt|/home|/pgsql|/pgsql/12) die "拒绝处理过宽目录: ${path}" ;; esac
}

validate_standby_resume_state() {
  local state_file='/var/lib/pg-rw-proxy-installer/standby-bootstrap.state'
  local key path found=0
  [[ -f "${state_file}" ]] || return 1
  while IFS='=' read -r key path; do
    [[ "${key}" =~ ^(original_pgdata|partial_pgdata|original_or_partial_pgdata)$ ]] || \
      die "Standby 恢复状态包含未知字段: ${key}"
    [[ "${path}" == /var/backups/pg-readwrite-proxy-lab/standby-* && -d "${path}" ]] || \
      die "Standby 恢复状态指向无效备份目录: ${path}"
    found=1
  done <"${state_file}"
  ((found == 1)) || die 'Standby 恢复状态文件为空。'
  STANDBY_RESUME_STATE_FILE="${state_file}"
  export STANDBY_RESUME_STATE_FILE
}

sql_literal() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "${value}"
}

add_firewall_rule() {
  local cidr="$1" port="$2" rule
  [[ "${MANAGE_FIREWALL}" == 'yes' ]] || { warn "MANAGE_FIREWALL=no：未添加 ${cidr} -> TCP/${port}；请确认上游防火墙。"; return 0; }
  systemctl is-active --quiet firewalld || die 'MANAGE_FIREWALL=yes，但 firewalld 未运行。'
  rule="rule family=\"ipv4\" source address=\"${cidr}\" port port=\"${port}\" protocol=\"tcp\" accept"
  firewall-cmd --permanent --query-rich-rule="${rule}" >/dev/null 2>&1 || firewall-cmd --permanent --add-rich-rule="${rule}" >/dev/null
  firewall-cmd --reload >/dev/null
}

tcp_check() {
  timeout 4 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1
}

find_pgpool_binary() {
  local name="$1" path="${PGPOOL_INSTALL_PREFIX}/bin/$1"
  [[ -x "${path}" ]] || die "找不到 Pgpool-II 命令: ${path}"
  printf '%s' "${path}"
}
