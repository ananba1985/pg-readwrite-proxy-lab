#!/usr/bin/env bash

# 在独立 Pgpool-II 服务器上以 root 运行。完全离线，通过 root SSH 编排两台现有数据库服务器。
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
PAYLOAD_DIR="${ROOT_DIR}/packages/payload"
STATE_DIR='/var/lib/pg-rw-proxy-installer'

log() { printf '[INSTALL] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
INSTALL_PHASE='启动参数与本机环境检查'

report_unexpected_error() {
  local exit_code="$?" line_number="${BASH_LINENO[0]:-unknown}"
  ((BASH_SUBSHELL == 0)) || return "${exit_code}"
  trap - ERR
  printf '[ERROR] 安装器在阶段“%s”异常退出（退出码=%s，install.sh 行=%s）。请保留该行及其前面的错误信息。\n' \
    "${INSTALL_PHASE}" "${exit_code}" "${line_number}" >&2
  return "${exit_code}"
}
trap report_unexpected_error ERR

# shellcheck source=scripts/lib/installer-inputs.sh
source "${ROOT_DIR}/scripts/lib/installer-inputs.sh"
initialize_install_inputs
parse_install_inputs "$@"

[[ "${EUID}" -eq 0 ]] || die '请在 Pgpool-II 服务器上使用 root 运行 bash install.sh。'
for command_name in ssh tar openssl awk sed sha256sum mktemp getenforce getconf uname id stat df date; do
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少系统基础命令: ${command_name}"
done
[[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == 'kylin' && "${VERSION_ID:-}" == 'V10' && "$(uname -m)" == 'aarch64' ]] || \
  die "一键入口只能在 Kylin Linux Advanced Server V10 aarch64 Pgpool 节点运行；当前=${PRETTY_NAME:-unknown} $(uname -m)。"
[[ "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)" == 'glibc 2.28' ]] || die 'Pgpool 节点 glibc 基线不是 2.28。'
selinux_mode="$(getenforce 2>/dev/null || printf unknown)"
[[ "${selinux_mode}" =~ ^(Disabled|Permissive)$ ]] || \
  die "SELinux 运行态不可接受: ${selinux_mode}；当前离线包未提供 Enforcing 策略。"
for script_file in "${ROOT_DIR}/install.sh" "${ROOT_DIR}/scripts/"*.sh "${ROOT_DIR}/scripts/lib/"*.sh; do
  [[ -r "${script_file}" ]] || die "安装脚本不可读: ${script_file}"
done

expected_payloads=(
  pgpool-II-4.7.2-pg12.0-aarch64-kylin-v10.tar.gz
  postgresql-client-12.0-aarch64-kylin-v10.tar.gz
  pgpool-runtime-kylin-v10-aarch64.tar.gz
  sshpass-1.10-aarch64-kylin-v10.tar.gz
)
manifest_names="$(awk 'NF==2 {print $2}' "${ROOT_DIR}/packages/MANIFEST.sha256" 2>/dev/null || true)"
[[ "$(grep -c . <<<"${manifest_names}")" == '4' ]] || die 'MANIFEST.sha256 必须且只能列出四个离线载荷。'
for payload in "${expected_payloads[@]}"; do
  [[ -f "${PAYLOAD_DIR}/${payload}" ]] || die "离线包不完整，缺少 ${payload}"
  grep -Fxq "payload/${payload}" <<<"${manifest_names}" || die "MANIFEST.sha256 未固定载荷 ${payload}"
done
(cd "${ROOT_DIR}/packages" && sha256sum -c MANIFEST.sha256) || die '离线载荷完整性校验失败。'

is_ipv4() {
  local ip="$1" octet old_ifs="${IFS}"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${ip}"
  IFS="${old_ifs}"
  for octet in "${octets[@]}"; do ((10#${octet} <= 255)) || return 1; done
}

is_cidr() {
  local cidr="$1" address prefix
  [[ "${cidr}" == */* ]] || return 1
  address="${cidr%/*}"; prefix="${cidr##*/}"
  is_ipv4 "${address}" && [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] && ((10#${prefix} <= 32))
}

validate_identifier() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "PostgreSQL 标识符不合法: $1"
}

validate_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) || die "端口无效: $1"
}

printf '\nPostgreSQL Streaming Replication + Pgpool-II 离线安装\n'
printf '目标平台：Primary、Standby 与 Pgpool 节点均为麒麟 V10 aarch64；数据库节点已安装受支持的 NebulaCM PostgreSQL 12.0。\n\n'
prompt_default PGPOOL_HOST '当前 Pgpool-II 服务器内网 IPv4 地址' '192.168.80.140'
prompt_default PRIMARY_HOST '现有 PostgreSQL Primary 内网 IPv4 地址' '192.168.80.110'
prompt_default STANDBY_HOST 'PostgreSQL Standby 目标机内网 IPv4 地址' '192.168.80.120'
for address in "${PGPOOL_HOST}" "${PRIMARY_HOST}" "${STANDBY_HOST}"; do is_ipv4 "${address}" || die "IPv4 地址无效: ${address}"; done
[[ "${PGPOOL_HOST}" != "${PRIMARY_HOST}" && "${PGPOOL_HOST}" != "${STANDBY_HOST}" && "${PRIMARY_HOST}" != "${STANDBY_HOST}" ]] || die '三台服务器地址必须不同。'

prompt_default PRIMARY_PORT 'PostgreSQL 端口' '5432'
STANDBY_PORT="${PRIMARY_PORT}"
prompt_default PGPOOL_PORT 'Pgpool-II 对外服务端口' '5432'
prompt_default SSH_PORT 'Pgpool 服务器访问 Primary 与 Standby 的 root SSH 端口' '22'
validate_port "${PRIMARY_PORT}"
validate_port "${PGPOOL_PORT}"
validate_port "${SSH_PORT}"
[[ "${PGPOOL_PORT}" != '9898' ]] || die 'Pgpool 对外端口不能与本机 PCP 端口 9898 冲突。'
prompt_default ALLOWED_CLIENT_CIDRS '允许访问 Pgpool 的客户端 IPv4 CIDR（逗号分隔）' "${PGPOOL_HOST%.*}.0/24"
IFS=',' read -r -a _allowed_cidrs <<<"${ALLOWED_CLIENT_CIDRS}"
((${#_allowed_cidrs[@]} > 0)) || die '客户端 CIDR 不能为空。'
for cidr in "${_allowed_cidrs[@]}"; do
  cidr="${cidr#"${cidr%%[![:space:]]*}"}"; cidr="${cidr%"${cidr##*[![:space:]]}"}"
  is_cidr "${cidr}" || die "客户端 CIDR 无效: ${cidr}"
  [[ "${cidr}" != '0.0.0.0/0' ]] || die '禁止向全网开放 Pgpool-II。'
done
if [[ -n "${MANAGE_PGPOOL_FIREWALL}" ]]; then
  warn '--manage-pgpool-firewall 已废弃并被忽略；安装器不会检查、启动或配置任何主机防火墙。'
fi
prompt_default BUSINESS_USER '现有业务数据库用户名（脚本不会创建或改密）' 'rw_lab_test'
prompt_default BUSINESS_DATABASE '现有业务数据库名' 'rw_proxy_lab'
validate_identifier "${BUSINESS_USER}"; validate_identifier "${BUSINESS_DATABASE}"
prompt_secret ROOT_SSH_PASSWORD 'Primary 与 Standby 的 root SSH 公共密码' allow
prompt_secret BUSINESS_PASSWORD "现有数据库用户 ${BUSINESS_USER} 的密码"

cleanup() {
  local host remote_dir sensitive_file
  if declare -F remote_root >/dev/null 2>&1; then
    for pair in "${PRIMARY_HOST}|${primary_stage:-}" "${STANDBY_HOST}|${standby_stage:-}"; do
      host="${pair%%|*}"; remote_dir="${pair#*|}"
      [[ "${remote_dir}" == /var/tmp/pg-rw-proxy-installer-* ]] || continue
      printf "case '%s' in /var/tmp/pg-rw-proxy-installer-*) rm -rf -- '%s';; esac\n" "${remote_dir}" "${remote_dir}" | remote_root "${host}" >/dev/null 2>&1 || true
    done
  fi
  [[ "${sshpass_root:-}" == /var/tmp/pg-rw-sshpass.* ]] && rm -rf -- "${sshpass_root}" || true
  if [[ "${restart_existing_pgpool_on_error:-no}" == yes ]]; then
    systemctl start "${PGPOOL_SERVICE:-pgpool}" >/dev/null 2>&1 || warn '部署中断，既有 Pgpool 服务自动恢复失败，请立即人工检查。'
  fi
  if [[ "${session_config_dir:-}" == /var/tmp/pg-rw-config.* && -d "${session_config_dir}" ]]; then
    if command -v shred >/dev/null 2>&1; then
      find "${session_config_dir}" -type f -exec shred -u -- {} + 2>/dev/null || true
    fi
    rm -rf -- "${session_config_dir}"
  fi
  unset SSHPASS ROOT_SSH_PASSWORD BUSINESS_PASSWORD
}
trap cleanup EXIT INT TERM

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
umask 077
write_env() { printf '%s=%q\n' "$2" "$3" >>"$1"; }

session_config_dir="$(mktemp -d /var/tmp/pg-rw-config.XXXXXX)"
cluster_file="${session_config_dir}/cluster.env"
: >"${cluster_file}"
declare -A values=(
  [PG_MAJOR]='12' [PG_VERSION_FULL]='12.0' [DB_DISTRIBUTION]='NebulaCM'
  [DBN_VERSION_MARKER]='NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz'
  [DB_POSTGRES_SHA256]='aecef1bcf6557271a4ffaf9b55eb53df81c883984e1489916c85e88677477bcf'
  [DB_PG_BASEBACKUP_SHA256]='c235544bad0e0dc61b9c4fbc6becc7181970b9179b2aa071ff8a1821899815bb'
  [DB_PG_CONFIG_SHA256]='90321c1cb01d583ffa55523fd54490f93b2cb17fbcbe5fd99319ef0812f224df'
  [DB_TOOLS_SHA256]='1cfa544a74dc88f1bdc88db52fac5566b73eec4a0c3b15e33e60ec86a2cffa0f'
  [PG_OS_USER]='postgres' [PGPOOL_MAJOR]='4.7' [PGPOOL_VERSION]='4.7.2'
  [PGPOOL_INSTALL_PREFIX]='/opt/pgpool-II-4.7.2' [PG_CLIENT_PREFIX]='/opt/pgpool-client-12.0' [PGPOOL_RUNTIME_PREFIX]='/opt/pgpool-runtime-kylin-v10'
  [OFFLINE_PACKAGE_DIR]='packages/payload'
  [PGPOOL_PAYLOAD_FILE]='pgpool-II-4.7.2-pg12.0-aarch64-kylin-v10.tar.gz' [PGPOOL_PAYLOAD_SHA256]='b80c79b8e6537a14a6adc8ab4ae58baa40a2e027c8fc99a3589510462425dbea'
  [PG_CLIENT_PAYLOAD_FILE]='postgresql-client-12.0-aarch64-kylin-v10.tar.gz' [PG_CLIENT_PAYLOAD_SHA256]='1314901d8b0de906fcc47c7784913fd347d07a3b563475f8eae4e16310ba8667'
  [PGPOOL_RUNTIME_PAYLOAD_FILE]='pgpool-runtime-kylin-v10-aarch64.tar.gz' [PGPOOL_RUNTIME_PAYLOAD_SHA256]='6d00411d0098b2bab0c3f9e3a0d5d009907189eb2b0e3a743edd3063bce9a257'
  [SSHPASS_PAYLOAD_FILE]='sshpass-1.10-aarch64-kylin-v10.tar.gz' [SSHPASS_PAYLOAD_SHA256]='84bcff17fc7e48d0a8552c985818e17e485f95a66b3c50c4eedde6bcbdc96ffd'
  [SSH_PORT]="${SSH_PORT}"
  [PRIMARY_HOST]="${PRIMARY_HOST}" [PRIMARY_PORT]="${PRIMARY_PORT}" [PRIMARY_PGDATA]='/pgsql/12/data'
  [PRIMARY_PG_BIN_DIR]='/opt/pgsql12/bin' [PRIMARY_ADMIN_TOOL]='/opt/pgsql12/bin/tools' [PRIMARY_LISTEN_ADDRESSES]="127.0.0.1,${PRIMARY_HOST}"
  [STANDBY_HOST]="${STANDBY_HOST}" [STANDBY_PORT]="${STANDBY_PORT}" [STANDBY_PGDATA]='/pgsql/12/data'
  [STANDBY_PG_BIN_DIR]='/opt/pgsql12/bin' [STANDBY_ADMIN_TOOL]='/opt/pgsql12/bin/tools' [STANDBY_LISTEN_ADDRESSES]="127.0.0.1,${STANDBY_HOST}"
  [STANDBY_APPLICATION_NAME]='rw_standby' [REPLICATION_SLOT_NAME]='rw_standby_slot'
  [PGPOOL_HOST]="${PGPOOL_HOST}" [PGPOOL_PORT]="${PGPOOL_PORT}" [PCP_PORT]='9898' [PGPOOL_SERVICE]='pgpool' [PGPOOL_CONFIG_DIR]='/etc/pgpool-II'
  [STANDBY_ADDRESS_CIDR]="${STANDBY_HOST}/32" [PGPOOL_ADDRESS_CIDR]="${PGPOOL_HOST}/32"
  [ALLOWED_CLIENT_CIDRS]="${ALLOWED_CLIENT_CIDRS}"
  [REPLICATION_USER]='rw_replicator' [MONITOR_USER]='pgpool_monitor'
  [BUSINESS_USER]="${BUSINESS_USER}" [BUSINESS_DATABASE]="${BUSINESS_DATABASE}" [PCP_USER]='pgpool_admin'
  [MAX_WAL_SENDERS]='10' [MAX_REPLICATION_SLOTS]='10' [WAL_KEEP_SEGMENTS]='1000'
  [PRIMARY_READ_WEIGHT]='0' [STANDBY_READ_WEIGHT]='1' [DISABLE_LOAD_BALANCE_ON_WRITE]='transaction'
  [READ_LAG_THRESHOLD_SECONDS]='5' [SR_CHECK_PERIOD]='5' [HEALTH_CHECK_PERIOD]='5' [HEALTH_CHECK_TIMEOUT]='5'
  [HEALTH_CHECK_MAX_RETRIES]='3' [HEALTH_CHECK_RETRY_DELAY]='1' [CONNECT_TIMEOUT_MS]='5000'
  [NUM_INIT_CHILDREN]='8' [MAX_POOL]='2' [CONNECTION_LIFE_TIME]='600' [LOG_PER_NODE_STATEMENT]='on'
  [APPLY_PRIMARY_RESTART]='yes' [ALLOW_STANDBY_REINITIALIZE]='yes'
)
order=(PG_MAJOR PG_VERSION_FULL DB_DISTRIBUTION DBN_VERSION_MARKER DB_POSTGRES_SHA256 DB_PG_BASEBACKUP_SHA256 DB_PG_CONFIG_SHA256 DB_TOOLS_SHA256 PG_OS_USER PGPOOL_MAJOR PGPOOL_VERSION PGPOOL_INSTALL_PREFIX PG_CLIENT_PREFIX PGPOOL_RUNTIME_PREFIX OFFLINE_PACKAGE_DIR PGPOOL_PAYLOAD_FILE PGPOOL_PAYLOAD_SHA256 PG_CLIENT_PAYLOAD_FILE PG_CLIENT_PAYLOAD_SHA256 PGPOOL_RUNTIME_PAYLOAD_FILE PGPOOL_RUNTIME_PAYLOAD_SHA256 SSHPASS_PAYLOAD_FILE SSHPASS_PAYLOAD_SHA256 SSH_PORT PRIMARY_HOST PRIMARY_PORT PRIMARY_PGDATA PRIMARY_PG_BIN_DIR PRIMARY_ADMIN_TOOL PRIMARY_LISTEN_ADDRESSES STANDBY_HOST STANDBY_PORT STANDBY_PGDATA STANDBY_PG_BIN_DIR STANDBY_ADMIN_TOOL STANDBY_LISTEN_ADDRESSES STANDBY_APPLICATION_NAME REPLICATION_SLOT_NAME PGPOOL_HOST PGPOOL_PORT PCP_PORT PGPOOL_SERVICE PGPOOL_CONFIG_DIR STANDBY_ADDRESS_CIDR PGPOOL_ADDRESS_CIDR ALLOWED_CLIENT_CIDRS REPLICATION_USER MONITOR_USER BUSINESS_USER BUSINESS_DATABASE PCP_USER MAX_WAL_SENDERS MAX_REPLICATION_SLOTS WAL_KEEP_SEGMENTS PRIMARY_READ_WEIGHT STANDBY_READ_WEIGHT DISABLE_LOAD_BALANCE_ON_WRITE READ_LAG_THRESHOLD_SECONDS SR_CHECK_PERIOD HEALTH_CHECK_PERIOD HEALTH_CHECK_TIMEOUT HEALTH_CHECK_MAX_RETRIES HEALTH_CHECK_RETRY_DELAY CONNECT_TIMEOUT_MS NUM_INIT_CHILDREN MAX_POOL CONNECTION_LIFE_TIME LOG_PER_NODE_STATEMENT APPLY_PRIMARY_RESTART ALLOW_STANDBY_REINITIALIZE)
for name in "${order[@]}"; do write_env "${cluster_file}" "${name}" "${values[${name}]}"; done
chmod 600 "${cluster_file}"

random_secret() { openssl rand -hex 32; }
secrets_file="${session_config_dir}/secrets.env"
: >"${secrets_file}"
write_env "${secrets_file}" REPLICATION_PASSWORD "$(random_secret)"
write_env "${secrets_file}" MONITOR_PASSWORD "$(random_secret)"
write_env "${secrets_file}" BUSINESS_PASSWORD "${BUSINESS_PASSWORD}"
write_env "${secrets_file}" PCP_PASSWORD "$(random_secret)"
write_env "${secrets_file}" PGPOOL_AES_KEY "$(random_secret)"
chmod 600 "${secrets_file}"
: >"${session_config_dir}/pool-users.txt"
chmod 600 "${session_config_dir}/pool-users.txt"

# 当前会话及两台远端暂存只引用 /var/tmp 配置；APPLY 前绝不覆盖解压目录中的既有配置。
export CLUSTER_CONFIG="${cluster_file}" SECRETS_CONFIG="${secrets_file}" POOL_USERS_FILE="${session_config_dir}/pool-users.txt"

# 在本项目私有临时目录使用 sshpass，不写入 /usr/local。
sshpass_root="$(mktemp -d /var/tmp/pg-rw-sshpass.XXXXXX)"
tar -xmzf "${PAYLOAD_DIR}/sshpass-1.10-aarch64-kylin-v10.tar.gz" -C "${sshpass_root}"
SSHPASS_BIN="${sshpass_root}/usr/local/bin/sshpass"
[[ -x "${SSHPASS_BIN}" ]] || die 'sshpass 离线载荷解压失败。'
export SSHPASS="${ROOT_SSH_PASSWORD}"
known_hosts="${STATE_DIR}/known_hosts"
touch "${known_hosts}"; chmod 600 "${known_hosts}"
ssh_args=(-p "${SSH_PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="${known_hosts}" \
  -o ConnectTimeout=10 -o ServerAliveInterval=15)

remote_root() {
  local host="$1"
  "${SSHPASS_BIN}" -e ssh "${ssh_args[@]}" root@"${host}" bash -s
}
remote_command() { local host="$1" command_text="$2"; printf '%s\n' "${command_text}" | remote_root "${host}"; }

stage_id="$(date '+%Y%m%d%H%M%S')-$$"
primary_stage="/var/tmp/pg-rw-proxy-installer-${stage_id}-primary"
standby_stage="/var/tmp/pg-rw-proxy-installer-${stage_id}-standby"
CLOCK_SKEW_TOLERANCE_SECONDS=5

check_remote_platform_and_clock() {
  local host="$1" local_before local_after remote_epoch estimated_skew=0
  log "校验 root SSH 和目标平台：${host}:${SSH_PORT}"
  local_before="$(date +%s)"
  if ! remote_epoch="$(remote_root "${host}" <<'REMOTE_CHECK'
set -e
test "$(id -u)" -eq 0
test "$(uname -m)" = aarch64
test -r /etc/os-release
. /etc/os-release
test "${ID:-}" = kylin
test "${VERSION_ID:-}" = V10
date +%s
REMOTE_CHECK
)"; then
    die "${host}:${SSH_PORT} 的 root SSH、麒麟 V10 ARM64 平台或远端 date 检查失败。"
  fi
  local_after="$(date +%s)"
  [[ "${remote_epoch}" =~ ^[0-9]+$ ]] || die "${host} 返回的系统时间无效。"
  if ((remote_epoch < local_before)); then
    estimated_skew=$((local_before - remote_epoch))
  elif ((remote_epoch > local_after)); then
    estimated_skew=$((remote_epoch - local_after))
  fi
  ((estimated_skew <= CLOCK_SKEW_TOLERANCE_SECONDS)) || \
    die "${host} 与 Pgpool 节点的估算时钟偏差至少为 ${estimated_skew} 秒，超过 ${CLOCK_SKEW_TOLERANCE_SECONDS} 秒门禁；请先同步系统时间。"
  log "${host} 时钟检查通过：估算偏差不超过 ${CLOCK_SKEW_TOLERANCE_SECONDS} 秒（秒级偏差允许）。"
}

for host in "${PRIMARY_HOST}" "${STANDBY_HOST}"; do
  check_remote_platform_and_clock "${host}"
done

log '输入信息已收集完毕；从此处开始只执行临时暂存和只读检查，确认 APPLY 前不修改数据库、服务、账号或持久配置。主机防火墙完全不在安装器职责内。'

copy_stage() {
  local host="$1" remote_dir="$2"
  # 远端目录只是本次安装的临时副本，不依赖源文件 mtime。解压时使用 -m，避免节点间
  # 秒级时钟偏差被 GNU tar 作为“时间戳在未来”警告并返回非零状态。
  if ! tar --exclude='./.git' --exclude='./vm' --exclude='./packages/sources' --exclude='./packages/payload' --exclude='./packages/dist' \
      --exclude='./config/cluster.env' --exclude='./config/secrets.env' --exclude='./config/pool-users.txt' \
      --exclude='./NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz' \
      --exclude='./PG_Safe_tool.tar.gz' --exclude='./gen_license-arm64' --exclude='./artifacts' \
      -C "${ROOT_DIR}" -czf - . | \
      "${SSHPASS_BIN}" -e ssh "${ssh_args[@]}" root@"${host}" \
        "mkdir -p '${remote_dir}' && tar -xmzf - -C '${remote_dir}' && chmod +x '${remote_dir}'/scripts/*.sh '${remote_dir}'/scripts/lib/*.sh"; then
    die "向 ${host} 暂存安装脚本失败；尚未修改数据库或持久配置。"
  fi
  if ! tar -C "${session_config_dir}" -czf - cluster.env secrets.env pool-users.txt | \
      "${SSHPASS_BIN}" -e ssh "${ssh_args[@]}" root@"${host}" \
        "mkdir -p '${remote_dir}/session-config' && tar -xmzf - -C '${remote_dir}/session-config' && chmod 600 '${remote_dir}'/session-config/*"; then
    die "向 ${host} 暂存会话配置失败；尚未修改数据库或持久配置。"
  fi
}
INSTALL_PHASE='向 Primary 和 Standby 暂存安装脚本与会话配置'
copy_stage "${PRIMARY_HOST}" "${primary_stage}"
copy_stage "${STANDBY_HOST}" "${standby_stage}"

# 在所有严格检查前冻结脚本会修改的持久状态；检查完成后必须逐字相同。
INSTALL_PHASE='生成三节点部署前状态指纹'
remote_env="CLUSTER_CONFIG='./session-config/cluster.env' SECRETS_CONFIG='./session-config/secrets.env' POOL_USERS_FILE='./session-config/pool-users.txt'"
primary_baseline="$(remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ${remote_env} ./scripts/06-state-fingerprint.sh primary")"
standby_baseline="$(remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ${remote_env} ./scripts/06-state-fingerprint.sh standby")"
pgpool_baseline="$("${ROOT_DIR}/scripts/06-state-fingerprint.sh" pgpool)"
pgpool_was_active=no
[[ "${pgpool_baseline}" == pgpool\|service=active\|* ]] && pgpool_was_active=yes

INSTALL_PHASE='执行三节点基础只读预检'
log '执行三节点基础只读预检。'
remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ${remote_env} ./scripts/00-preflight.sh primary"
remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ${remote_env} ./scripts/00-preflight.sh standby"
"${ROOT_DIR}/scripts/00-preflight.sh" pgpool

INSTALL_PHASE='执行 Pgpool、Primary 与 Standby 严格只读就绪检查'
log '执行部署前严格就绪检查；此阶段不修改数据库、服务、配置或账号，也不读取主机防火墙状态。'
pgpool_ready="$("${ROOT_DIR}/scripts/05-readiness-check.sh" pgpool)"
printf '%s\n' "${pgpool_ready}"
grep -Fq 'READINESS_RESULT=READY role=pgpool' <<<"${pgpool_ready}" || die 'Pgpool 严格就绪检查未返回 READY。'
existing_primary_pids="$(sed -n 's/^READINESS_PGPOOL_BACKENDS=READY primary_pids=\([^ ]*\) standby_pids=.*/\1/p' <<<"${pgpool_ready}")"
existing_standby_pids="$(sed -n 's/^READINESS_PGPOOL_BACKENDS=READY primary_pids=[^ ]* standby_pids=\([^ ]*\).*/\1/p' <<<"${pgpool_ready}")"
[[ -n "${existing_primary_pids}" && -n "${existing_standby_pids}" ]] || die '无法解析既有 Pgpool 后端 PID 清单。'

primary_ready="$(remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; EXPECTED_PGPOOL_PRIMARY_PIDS='${existing_primary_pids}' ${remote_env} ./scripts/05-readiness-check.sh primary")"
printf '%s\n' "${primary_ready}"
grep -Fq 'READINESS_RESULT=READY role=primary' <<<"${primary_ready}" || die 'Primary 严格就绪检查未返回 READY。'
PRIMARY_SYSTEM_ID="$(sed -n 's/^READINESS_PRIMARY=READY system_id=\([0-9][0-9]*\) .*/\1/p' <<<"${primary_ready}")"
PRIMARY_PGDATA_BYTES="$(sed -n 's/^READINESS_PRIMARY=READY .* pgdata_bytes=\([0-9][0-9]*\) .*/\1/p' <<<"${primary_ready}")"
PRIMARY_CLIENT_SESSIONS="$(sed -n 's/^READINESS_PRIMARY=READY .* active_client_sessions=\([0-9][0-9]*\)$/\1/p' <<<"${primary_ready}")"
[[ "${PRIMARY_SYSTEM_ID}" =~ ^[0-9]+$ && "${PRIMARY_PGDATA_BYTES}" =~ ^[0-9]+$ && \
   "${PRIMARY_CLIENT_SESSIONS}" =~ ^[0-9]+$ ]] || die '无法解析 Primary 就绪检查上下文。'

standby_ready="$(remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; PRIMARY_SYSTEM_ID='${PRIMARY_SYSTEM_ID}' PRIMARY_PGDATA_BYTES='${PRIMARY_PGDATA_BYTES}' EXPECTED_PGPOOL_STANDBY_PIDS='${existing_standby_pids}' ${remote_env} ./scripts/05-readiness-check.sh standby")"
printf '%s\n' "${standby_ready}"
grep -Fq 'READINESS_RESULT=READY role=standby' <<<"${standby_ready}" || die 'Standby 严格就绪检查未返回 READY。'
STANDBY_CLIENT_SESSIONS="$(sed -n 's/^READINESS_STANDBY=READY .* active_client_sessions=\([0-9][0-9]*\)$/\1/p' <<<"${standby_ready}")"
[[ "${STANDBY_CLIENT_SESSIONS}" =~ ^[0-9]+$ ]] || die '无法解析 Standby 客户端连接数。'
primary_after="$(remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ${remote_env} ./scripts/06-state-fingerprint.sh primary")"
standby_after="$(remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ${remote_env} ./scripts/06-state-fingerprint.sh standby")"
pgpool_after="$("${ROOT_DIR}/scripts/06-state-fingerprint.sh" pgpool)"
[[ "${primary_after}" == "${primary_baseline}" ]] || die 'Primary 在检查期间发生持久状态变化，拒绝继续。'
[[ "${standby_after}" == "${standby_baseline}" ]] || die 'Standby 在检查期间发生持久状态变化，拒绝继续。'
[[ "${pgpool_after}" == "${pgpool_baseline}" ]] || die 'Pgpool 在检查期间发生持久状态变化，拒绝继续。'

confirm_force_restart_with_clients "${PRIMARY_CLIENT_SESSIONS}" "${STANDBY_CLIENT_SESSIONS}"
if [[ "${FORCE_DB_RESTART_WITH_CLIENTS}" == 'yes' ]]; then
  warn "已取得本次运行的人工强制授权：Primary=${PRIMARY_CLIENT_SESSIONS}，Standby=${STANDBY_CLIENT_SESSIONS}；不会写入长期配置。"
fi

cat <<SUMMARY

三节点只读就绪检查全部通过，尚未执行任何部署变更。

检查范围：
  权限/平台 : 本地 root、远端 root SSH、三节点麒麟 V10 ARM64 基线、Pgpool glibc、SELinux
  命令/路径 : 所有部署命令、数据库厂商运行时哈希、PGDATA/配置/HOME/安装前缀、挂载与 inode 属性
  数据库状态 : Primary/Standby 身份、业务对象/密码/探针、活动连接、配置解析、表空间、复制连接/槽
  网络/容量 : 三机路由/ping、必要 TCP、端口归属、配置备份/基础备份/安装空间
  离线载荷 : 四个载荷 SHA256、安全路径、试解压、全部可执行文件动态库闭包及固定版本

就绪结果：
  Primary : READY，DB=${PRIMARY_HOST}:${PRIMARY_PORT}，SSH=${PRIMARY_HOST}:${SSH_PORT}，客户端连接=${PRIMARY_CLIENT_SESSIONS}
  Standby : READY，DB=${STANDBY_HOST}:${STANDBY_PORT}，SSH=${STANDBY_HOST}:${SSH_PORT}，客户端连接=${STANDBY_CLIENT_SESSIONS}
  Pgpool  : READY，${PGPOOL_HOST}:${PGPOOL_PORT}，麒麟载荷/依赖/权限条件满足
  连接处理 : 强制中断授权=${FORCE_DB_RESTART_WITH_CLIENTS}

确认后将执行：
  Primary : 备份配置、创建复制/监控账号、收紧 HBA、pg_ctl 重启
  Standby : 旧 PGDATA 移到备份目录、pg_basebackup 重建
  Pgpool  : 离线安装 Pgpool-II 4.7.2，开放配置的客户端 CIDR；PCP 仅本机
  业务库  : ${BUSINESS_USER}@${BUSINESS_DATABASE}（只验证既有对象和密码）
  客户端  : ${ALLOWED_CLIENT_CIDRS}
  网络策略 : 主机防火墙与上游 ACL 由用户自行配置；安装器不读取、不修改

基线不执行自动提升，也没有 failover/follow-primary 提升命令。
SUMMARY
INSTALL_PHASE='等待最终部署授权'
read -r -p '确认维护窗口和上述变更。输入 APPLY 开始部署: ' confirmation
[[ "${confirmation}" == 'APPLY' ]] || die '用户取消；所有服务器均未执行部署变更。'
deployment_started=yes
INSTALL_PHASE='APPLY 后最终连接复核'
if [[ "${pgpool_was_active}" == yes ]]; then
  restart_existing_pgpool_on_error=yes
  # 用户确认后首先再次确认没有新客户端连入；失败仍处于零持久变更状态。
  pgpool_apply_gate="$("${ROOT_DIR}/scripts/05-readiness-check.sh" pgpool)"
  grep -Fq 'READINESS_RESULT=READY role=pgpool' <<<"${pgpool_apply_gate}" || die 'APPLY 前最终连接复核失败。'
  log '检测到本项目既有 Pgpool 服务；最终连接复核通过，临时停止入口并执行幂等更新。'
  systemctl stop pgpool
  primary_remaining_sessions=unknown
  standby_remaining_sessions=unknown
  for _ in {1..30}; do
    primary_remaining_sessions="$(remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ${remote_env} ./scripts/07-count-business-sessions.sh")"
    standby_remaining_sessions="$(remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ${remote_env} ./scripts/07-count-business-sessions.sh")"
    [[ "${primary_remaining_sessions}" == '0' && "${standby_remaining_sessions}" == '0' ]] && break
    sleep 1
  done
else
  primary_remaining_sessions="$(remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ${remote_env} ./scripts/07-count-business-sessions.sh")"
  standby_remaining_sessions="$(remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ${remote_env} ./scripts/07-count-business-sessions.sh")"
fi
[[ "${primary_remaining_sessions}" =~ ^[0-9]+$ && "${standby_remaining_sessions}" =~ ^[0-9]+$ ]] || \
  die 'APPLY 后无法重新统计数据库客户端连接。'
if [[ "${primary_remaining_sessions}" != '0' || "${standby_remaining_sessions}" != '0' ]]; then
  if [[ "${FORCE_DB_RESTART_WITH_CLIENTS}" != 'yes' ]]; then
    warn "APPLY 后检测到新的数据库连接，尚未修改持久配置；需要重新选择连接处理策略。"
    confirm_force_restart_with_clients "${primary_remaining_sessions}" "${standby_remaining_sessions}"
  fi
  warn "数据库最终编排复核仍有连接：Primary=${primary_remaining_sessions}, Standby=${standby_remaining_sessions}；将按人工授权在 fast stop 时中断。"
else
  log 'APPLY 后数据库连接复核：Primary=0，Standby=0。'
fi

config_backup_dir="/var/backups/pg-readwrite-proxy-lab/installer-config-$(date '+%Y%m%d-%H%M%S')"
mkdir -p -- "${CONFIG_DIR}" "${config_backup_dir}"
chmod 700 "${config_backup_dir}"
for config_name in cluster.env secrets.env pool-users.txt; do
  [[ ! -e "${CONFIG_DIR}/${config_name}" ]] || cp -a -- "${CONFIG_DIR}/${config_name}" "${config_backup_dir}/"
  install -o root -g root -m 600 "${session_config_dir}/${config_name}" "${CONFIG_DIR}/${config_name}"
done

INSTALL_PHASE='备份并配置 Primary'
log '1/4 备份并配置 Primary。'
remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; FORCE_DB_RESTART_WITH_CLIENTS='${FORCE_DB_RESTART_WITH_CLIENTS}' ${remote_env} ./scripts/10-configure-primary.sh"
INSTALL_PHASE='校验并初始化 Standby'
log '2/4 校验既有 NebulaCM 运行时并初始化 Standby。'
remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ${remote_env} ./scripts/20-install-postgresql-standby.sh; FORCE_DB_RESTART_WITH_CLIENTS='${FORCE_DB_RESTART_WITH_CLIENTS}' ${remote_env} ./scripts/21-bootstrap-standby.sh"
INSTALL_PHASE='安装并配置 Pgpool-II'
log '3/4 离线安装并配置 Pgpool-II。'
"${ROOT_DIR}/scripts/30-install-pgpool.sh"
"${ROOT_DIR}/scripts/31-configure-pgpool.sh"
restart_existing_pgpool_on_error=no
INSTALL_PHASE='验证复制、SQL 路由和统一入口'
log '4/4 验证复制、SQL 路由和远端客户端入口。'
"${ROOT_DIR}/scripts/40-verify-cluster.sh"
remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ${remote_env} ./scripts/42-verify-external-entry.sh"

trap - EXIT INT TERM
cleanup
printf '\n安装与验收完成。统一业务入口：%s:%s，数据库：%s，用户：%s\n' \
  "${PGPOOL_HOST}" "${PGPOOL_PORT}" "${BUSINESS_DATABASE}" "${BUSINESS_USER}"
printf '运行参数与凭据保存在 %s（权限 600）；请及时纳入受控密钥系统。\n' "${CONFIG_DIR}"
