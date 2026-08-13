#!/usr/bin/env bash

# 与 install.sh 并列的中断续装入口。通常只修复 Pgpool；唯一数据库写操作是：
# 在严格证明 pg_basebackup 已完成后，启动/等待现有 Standby PGDATA，绝不重新同步。
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
INSTALL_PHASE='启动参数与本机环境检查'
TEMP_ROOT=''
SSHPASS_BIN=''
CHECK_PSQL=''
CHECK_LD_LIBRARY_PATH=''

log() { printf '[REPAIR] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() {
  local exit_code="${2:-1}"
  local source_file="${BASH_SOURCE[1]:-$0}"
  printf '[ERROR] time=%s host=%s source=%s line=%s phase=%s exit=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${HOSTNAME:-unknown}" \
    "${source_file##*/}" "${BASH_LINENO[0]:-unknown}" "${INSTALL_PHASE}" "${exit_code}" >&2
  printf '[ERROR] %s\n' "$1" >&2
  [[ -n "${REPAIR_LOG_FILE:-}" ]] && printf '[ERROR] 完整诊断日志：%s\n' "${REPAIR_LOG_FILE}" >&2
  exit "${exit_code}"
}

cleanup() {
  if [[ -n "${TEMP_ROOT:-}" && "${TEMP_ROOT}" == /var/tmp/pg-rw-repair.* && -d "${TEMP_ROOT}" ]]; then
    rm -rf --one-file-system -- "${TEMP_ROOT}"
  fi
  unset SSHPASS ROOT_SSH_PASSWORD REQUEST_BUSINESS_PASSWORD BUSINESS_PASSWORD
}

report_unexpected_error() {
  local exit_code="$1" line_number="$2" failed_command="$3" stack_index
  ((BASH_SUBSHELL == 0)) || return "${exit_code}"
  trap - ERR
  printf '[ERROR] repair.sh 异常：time=%s host=%s phase=%s exit=%s line=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${HOSTNAME:-unknown}" "${INSTALL_PHASE}" \
    "${exit_code}" "${line_number}" >&2
  printf '[ERROR] failed_command=%s\n' "${failed_command}" >&2
  for ((stack_index=1; stack_index<${#FUNCNAME[@]}; stack_index++)); do
    printf '[ERROR] stack[%s]=source=%s line=%s function=%s\n' \
      "${stack_index}" "${BASH_SOURCE[${stack_index}]:-unknown}" \
      "${BASH_LINENO[$((stack_index-1))]:-unknown}" "${FUNCNAME[${stack_index}]:-main}" >&2
  done
  [[ -n "${REPAIR_LOG_FILE:-}" ]] && printf '[ERROR] 完整诊断日志：%s\n' "${REPAIR_LOG_FILE}" >&2
  return "${exit_code}"
}
trap cleanup EXIT INT TERM
trap 'report_unexpected_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

INSTALLER_ENTRYPOINT_NAME='repair.sh'
INSTALLER_FINAL_BEHAVIOR='脚本先执行只读状态检测；正在同步时只报告并退出。若基础备份已完成但 Standby 启动中断，REPAIR 只续启当前 PGDATA；其余修复仅限 Pgpool，绝不重新执行基础备份。'
INSTALLER_ALLOWED_CLIENT_CIDRS_HELP='初次安装保存值，仅用于核对安装会话；实际规则从 Primary 动态读取'
# shellcheck source=scripts/lib/installer-inputs.sh
source "${ROOT_DIR}/scripts/lib/installer-inputs.sh"
initialize_install_inputs
parse_install_inputs "$@"

[[ "${EUID}" -eq 0 ]] || die '请在 Pgpool-II 服务器上使用 root 运行 bash repair.sh。'
for command_name in ssh tar awk sed sha256sum mktemp getenforce getconf uname id stat date tee ip pgrep timeout grep cmp ss systemctl readlink install find md5sum chown chmod journalctl cp rm touch; do
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少系统基础命令: ${command_name}"
done

REPAIR_LOG_DIR='/var/log/pg-readwrite-proxy-lab'
mkdir -p "${REPAIR_LOG_DIR}"
chmod 700 "${REPAIR_LOG_DIR}"
REPAIR_LOG_FILE="${REPAIR_LOG_DIR}/repair-$(date '+%Y%m%d-%H%M%S')-$$.log"
touch "${REPAIR_LOG_FILE}"
chmod 600 "${REPAIR_LOG_FILE}"
exec > >(tee -a "${REPAIR_LOG_FILE}") 2> >(tee -a "${REPAIR_LOG_FILE}" >&2)
printf '[REPAIR] 完整诊断日志：%s\n' "${REPAIR_LOG_FILE}"

[[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == 'kylin' && "${VERSION_ID:-}" == 'V10' && "$(uname -m)" == 'aarch64' ]] || \
  die "repair.sh 只能在 Kylin Linux Advanced Server V10 aarch64 Pgpool 节点运行；当前=${PRETTY_NAME:-unknown} $(uname -m)。"
[[ "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)" == 'glibc 2.28' ]] || die 'Pgpool 节点 glibc 基线不是 2.28。'
selinux_mode="$(getenforce 2>/dev/null || printf unknown)"
[[ "${selinux_mode}" =~ ^(Disabled|Permissive)$ ]] || \
  die "SELinux 运行态不可接受: ${selinux_mode}；当前离线包未提供 Enforcing 策略。"

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

validate_request_identifier() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "PostgreSQL 标识符不合法: $1"
}

validate_request_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) || die "端口无效: $1"
}

printf '\nPostgreSQL Streaming Replication + Pgpool-II 状态检测与中断续装\n'
printf '本入口不会配置或重启 Primary，不会执行 pg_basebackup；必要时只续启已完成基础备份的 Standby PGDATA。\n\n'
prompt_default PGPOOL_HOST '当前 Pgpool-II 服务器内网 IPv4 地址' '192.168.80.140'
prompt_default PRIMARY_HOST '现有 PostgreSQL Primary 内网 IPv4 地址' '192.168.80.110'
prompt_default STANDBY_HOST 'PostgreSQL Standby 目标机内网 IPv4 地址' '192.168.80.120'
for address in "${PGPOOL_HOST}" "${PRIMARY_HOST}" "${STANDBY_HOST}"; do
  is_ipv4 "${address}" || die "IPv4 地址无效: ${address}"
done
[[ "${PGPOOL_HOST}" != "${PRIMARY_HOST}" && "${PGPOOL_HOST}" != "${STANDBY_HOST}" && \
   "${PRIMARY_HOST}" != "${STANDBY_HOST}" ]] || die '三台服务器地址必须不同。'

prompt_default PRIMARY_PORT 'PostgreSQL 端口' '5432'
STANDBY_PORT="${PRIMARY_PORT}"
prompt_default PGPOOL_PORT 'Pgpool-II 对外服务端口' '5432'
prompt_default SSH_PORT 'Pgpool 服务器访问 Primary 与 Standby 的 root SSH 端口' '22'
validate_request_port "${PRIMARY_PORT}"
validate_request_port "${PGPOOL_PORT}"
validate_request_port "${SSH_PORT}"
[[ "${PGPOOL_PORT}" != '9898' ]] || die 'Pgpool 对外端口不能与本机 PCP 端口 9898 冲突。'
prompt_default ALLOWED_CLIENT_CIDRS '初次安装保存的客户端 IPv4 CIDR（仅用于安装会话校验；repair 以 Primary 实际策略为准）' "${PGPOOL_HOST%.*}.0/24"
IFS=',' read -r -a _allowed_cidrs <<<"${ALLOWED_CLIENT_CIDRS}"
((${#_allowed_cidrs[@]} > 0)) || die '客户端 CIDR 不能为空。'
for cidr in "${_allowed_cidrs[@]}"; do
  cidr="${cidr#"${cidr%%[![:space:]]*}"}"; cidr="${cidr%"${cidr##*[![:space:]]}"}"
  is_cidr "${cidr}" || die "客户端 CIDR 无效: ${cidr}"
  [[ "${cidr}" != '0.0.0.0/0' ]] || die '禁止向全网开放 Pgpool-II。'
done
if [[ -n "${MANAGE_PGPOOL_FIREWALL}" ]]; then
  warn '--manage-pgpool-firewall 已废弃并被忽略；repair.sh 不读取或修改防火墙。'
fi
prompt_default BUSINESS_USER '现有业务数据库用户名（脚本不会创建或改密）' 'rw_lab_test'
prompt_default BUSINESS_DATABASE '现有业务数据库名' 'rw_proxy_lab'
validate_request_identifier "${BUSINESS_USER}"
validate_request_identifier "${BUSINESS_DATABASE}"
prompt_secret ROOT_SSH_PASSWORD 'Primary 与 Standby 的 root SSH 公共密码' allow
prompt_secret BUSINESS_PASSWORD "现有数据库用户 ${BUSINESS_USER} 的密码"

# 冻结本次输入；随后加载的已安装配置不得静默覆盖这些值。
REQUEST_PGPOOL_HOST="${PGPOOL_HOST}"
REQUEST_PRIMARY_HOST="${PRIMARY_HOST}"
REQUEST_STANDBY_HOST="${STANDBY_HOST}"
REQUEST_PRIMARY_PORT="${PRIMARY_PORT}"
REQUEST_PGPOOL_PORT="${PGPOOL_PORT}"
REQUEST_SSH_PORT="${SSH_PORT}"
REQUEST_ALLOWED_CLIENT_CIDRS="${ALLOWED_CLIENT_CIDRS}"
REQUEST_BUSINESS_USER="${BUSINESS_USER}"
REQUEST_BUSINESS_DATABASE="${BUSINESS_DATABASE}"
REQUEST_BUSINESS_PASSWORD="${BUSINESS_PASSWORD}"

CLUSTER_CONFIG="${CONFIG_DIR}/cluster.env"
SECRETS_CONFIG="${CONFIG_DIR}/secrets.env"
POOL_USERS_FILE="${CONFIG_DIR}/pool-users.txt"
export CLUSTER_CONFIG SECRETS_CONFIG POOL_USERS_FILE
[[ -f "${CLUSTER_CONFIG}" && -f "${SECRETS_CONFIG}" && -f "${POOL_USERS_FILE}" ]] || \
  die "缺少当前安装会话配置；必须保留 ${CONFIG_DIR}/cluster.env、secrets.env、pool-users.txt 才能在不重建 Standby 的前提下续装。" 20

# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/primary-client-policy.sh
source "${ROOT_DIR}/scripts/lib/primary-client-policy.sh"
# common.sh 提供配置/模板/载荷函数；恢复 repair.sh 自己的日志和错误处理。
log() { printf '[REPAIR] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() {
  local exit_code="${2:-1}"
  local source_file="${BASH_SOURCE[1]:-$0}"
  printf '[ERROR] time=%s host=%s source=%s line=%s phase=%s exit=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${HOSTNAME:-unknown}" \
    "${source_file##*/}" "${BASH_LINENO[0]:-unknown}" "${INSTALL_PHASE}" "${exit_code}" >&2
  printf '[ERROR] %s\n' "$1" >&2
  printf '[ERROR] 完整诊断日志：%s\n' "${REPAIR_LOG_FILE}" >&2
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM
trap 'report_unexpected_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_cluster_config
load_secrets

assert_input_matches() {
  local name="$1" requested="$2" installed="$3"
  [[ "${requested}" == "${installed}" ]] || \
    die "本次参数 ${name} 与当前安装配置不一致：输入=${requested}，已安装=${installed}。为避免修错集群，拒绝继续。" 20
}
assert_input_matches PGPOOL_HOST "${REQUEST_PGPOOL_HOST}" "${PGPOOL_HOST}"
assert_input_matches PRIMARY_HOST "${REQUEST_PRIMARY_HOST}" "${PRIMARY_HOST}"
assert_input_matches STANDBY_HOST "${REQUEST_STANDBY_HOST}" "${STANDBY_HOST}"
assert_input_matches POSTGRESQL_PORT "${REQUEST_PRIMARY_PORT}" "${PRIMARY_PORT}"
assert_input_matches STANDBY_PORT "${REQUEST_PRIMARY_PORT}" "${STANDBY_PORT}"
assert_input_matches PGPOOL_PORT "${REQUEST_PGPOOL_PORT}" "${PGPOOL_PORT}"
assert_input_matches SSH_PORT "${REQUEST_SSH_PORT}" "${SSH_PORT}"
assert_input_matches ALLOWED_CLIENT_CIDRS "${REQUEST_ALLOWED_CLIENT_CIDRS}" "${ALLOWED_CLIENT_CIDRS}"
assert_input_matches BUSINESS_USER "${REQUEST_BUSINESS_USER}" "${BUSINESS_USER}"
assert_input_matches BUSINESS_DATABASE "${REQUEST_BUSINESS_DATABASE}" "${BUSINESS_DATABASE}"
[[ "${REQUEST_BUSINESS_PASSWORD}" == "${BUSINESS_PASSWORD}" ]] || \
  die '本次 business password 与安装会话保存值不一致；拒绝用不一致的凭据重写 Pgpool。' 20

local_addresses="$(ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}')"
grep -Fxq "${PGPOOL_HOST}" <<<"${local_addresses}" || \
  die "当前服务器没有配置输入的 Pgpool 地址 ${PGPOOL_HOST}，拒绝在错误节点修复。" 20

INSTALL_PHASE='校验离线载荷并准备只读客户端'
validate_offline_payloads
TEMP_ROOT="$(mktemp -d /var/tmp/pg-rw-repair.XXXXXX)"
chmod 700 "${TEMP_ROOT}"
tar -xmzf "$(offline_file "${SSHPASS_PAYLOAD_FILE}")" -C "${TEMP_ROOT}"
tar -xmzf "$(offline_file "${PG_CLIENT_PAYLOAD_FILE}")" -C "${TEMP_ROOT}"
tar -xmzf "$(offline_file "${PGPOOL_RUNTIME_PAYLOAD_FILE}")" -C "${TEMP_ROOT}"
SSHPASS_BIN="${TEMP_ROOT}/usr/local/bin/sshpass"
CHECK_PSQL="${TEMP_ROOT}/pgpool-client-12.0/bin/psql"
CHECK_LD_LIBRARY_PATH="${TEMP_ROOT}/pgpool-runtime-kylin-v10/lib:${TEMP_ROOT}/pgpool-client-12.0/lib"
[[ -x "${SSHPASS_BIN}" && -x "${CHECK_PSQL}" ]] || die '临时只读检查工具解压不完整。'
export SSHPASS="${ROOT_SSH_PASSWORD}"
known_hosts="${TEMP_ROOT}/known_hosts"
touch "${known_hosts}"; chmod 600 "${known_hosts}"
ssh_args=(-p "${SSH_PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="${known_hosts}" \
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
scp_args=(-P "${SSH_PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="${known_hosts}" \
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

remote_root() {
  local host="$1"
  "${SSHPASS_BIN}" -e ssh "${ssh_args[@]}" root@"${host}" bash -s
}

stage_standby_resume_script() {
  local remote_stage="/var/tmp/pg-rw-standby-resume-$$"
  local resume_files=(
    scripts/22-resume-standby-after-basebackup.sh
    scripts/lib/common.sh
  ) file
  {
    printf 'set -Eeuo pipefail\n'
    printf 'umask 077\n'
    printf 'stage=%q\n' "${remote_stage}"
    printf 'rm -rf -- "${stage}"\n'
    printf 'install -d -o root -g root -m 700 "${stage}/scripts/lib" "${stage}/session-config"\n'
  } | remote_root "${STANDBY_HOST}"
  for file in "${resume_files[@]}"; do
    "${SSHPASS_BIN}" -e scp "${scp_args[@]}" "${ROOT_DIR}/${file}" \
      root@"${STANDBY_HOST}":"${remote_stage}/${file}" >/dev/null
  done
  for file in cluster.env secrets.env pool-users.txt; do
    "${SSHPASS_BIN}" -e scp "${scp_args[@]}" "${CONFIG_DIR}/${file}" \
      root@"${STANDBY_HOST}":"${remote_stage}/session-config/${file}" >/dev/null
  done
  {
    printf 'set -Eeuo pipefail\n'
    printf 'stage=%q\n' "${remote_stage}"
    printf 'chmod 700 "${stage}/scripts/22-resume-standby-after-basebackup.sh"\n'
    printf 'chmod 600 "${stage}/scripts/lib/common.sh" "${stage}/session-config/"*\n'
  } | remote_root "${STANDBY_HOST}"
  printf '%s' "${remote_stage}"
}

cleanup_standby_resume_stage() {
  local remote_stage="$1"
  [[ "${remote_stage}" == /var/tmp/pg-rw-standby-resume-[0-9]* ]] || return 0
  printf 'stage=%q\ncase "${stage}" in /var/tmp/pg-rw-standby-resume-[0-9]*) rm -rf -- "${stage}";; esac\n' \
    "${remote_stage}" | remote_root "${STANDBY_HOST}" >/dev/null 2>&1 || true
}

standby_resume_candidate_snapshot() {
  {
    printf 'PGDATA=%q\n' "${STANDBY_PGDATA}"
    printf 'BIN_DIR=%q\n' "${STANDBY_PG_BIN_DIR}"
    printf 'PORT=%q\n' "${STANDBY_PORT}"
    cat <<'REMOTE'
set -Eeuo pipefail
state_file=/var/lib/pg-rw-proxy-installer/standby-bootstrap.state
[[ -f "${state_file}" && ! -L "${state_file}" ]]
[[ "$(stat -c '%U:%a' "${state_file}")" == 'root:600' ]]
grep -Eq '^(original_pgdata|partial_pgdata|original_or_partial_pgdata)=/var/backups/pg-readwrite-proxy-lab/standby-' "${state_file}"
[[ -f "${PGDATA}/PG_VERSION" && "$(tr -d '\r\n' <"${PGDATA}/PG_VERSION")" == 12 ]]
for file in postgresql.conf postgresql.auto.conf pg_hba.conf standby.signal global/pg_control; do
  [[ -f "${PGDATA}/${file}" && ! -L "${PGDATA}/${file}" ]]
done
if grep -Fxq 'basebackup_complete=yes' "${state_file}"; then
  evidence=state_marker
elif grep -Fqx '# BEGIN PG_RW_PROXY_RECOVERY' "${PGDATA}/postgresql.auto.conf" && \
     grep -Fqx '# END PG_RW_PROXY_RECOVERY' "${PGDATA}/postgresql.auto.conf" && \
     grep -Fqx '# BEGIN PG_RW_PROXY_INCLUDE' "${PGDATA}/postgresql.conf" && \
     grep -Fqx '# END PG_RW_PROXY_INCLUDE' "${PGDATA}/postgresql.conf" && \
     grep -Fq "cluster_name = 'rw-standby'" "${PGDATA}/conf.d/99-pg-rw-proxy.conf"; then
  evidence=legacy_post_basebackup_managed_config
else
  exit 3
fi
running=no
runuser -u postgres -- env PATH="${BIN_DIR}:/usr/bin:/bin" "${BIN_DIR}/pg_ctl" -D "${PGDATA}" status >/dev/null 2>&1 && running=yes
control_system_id="$(runuser -u postgres -- env PATH="${BIN_DIR}:/usr/bin:/bin" "${BIN_DIR}/pg_controldata" "${PGDATA}" |
  awk -F: '/Database system identifier/{gsub(/[[:space:]]/,"",$2);print $2}')"
[[ "${control_system_id}" =~ ^[0-9]+$ ]]
printf 'RESUME_CANDIDATE=yes|%s|%s|%s\n' "${evidence}" "${running}" "${control_system_id}"
REMOTE
  } | remote_root "${STANDBY_HOST}"
}

count_local_full_installers() {
  local proc_file command_line count=0 proc_pid
  for proc_file in /proc/[0-9]*/cmdline; do
    proc_pid="${proc_file#/proc/}"; proc_pid="${proc_pid%/cmdline}"
    [[ "${proc_pid}" != "$$" && "${proc_pid}" != "${PPID}" ]] || continue
    command_line="$(tr '\0' ' ' <"${proc_file}" 2>/dev/null || true)"
    case "${command_line}" in
      *install.sh*|*21-bootstrap-standby.sh*) count=$((count + 1)) ;;
    esac
  done
  printf '%s' "${count}"
}

remote_activity() {
  local host="$1"
  cat <<'REMOTE' | remote_root "${host}"
set -Eeuo pipefail
basebackup_count="$(pgrep -x pg_basebackup 2>/dev/null || true)"
basebackup_count="$(grep -Ec '^[0-9]+$' <<<"${basebackup_count}" || true)"
bootstrap_count=0
for proc_file in /proc/[0-9]*/cmdline; do
  command_line="$(tr '\0' ' ' <"${proc_file}" 2>/dev/null || true)"
  case "${command_line}" in *21-bootstrap-standby.sh*) bootstrap_count=$((bootstrap_count + 1));; esac
done
printf 'BASEBACKUP=%s|BOOTSTRAP=%s\n' "${basebackup_count}" "${bootstrap_count}"
REMOTE
}

activity_value() {
  local row="$1" key="$2"
  sed -n "s/.*${key}=\([0-9][0-9]*\).*/\1/p" <<<"${row}"
}

check_active_install_or_sync() {
  local local_installers primary_activity standby_activity primary_basebackup standby_basebackup primary_bootstrap standby_bootstrap
  local_installers="$(count_local_full_installers)"
  primary_activity="$(remote_activity "${PRIMARY_HOST}")"
  standby_activity="$(remote_activity "${STANDBY_HOST}")"
  primary_basebackup="$(activity_value "${primary_activity}" BASEBACKUP)"
  standby_basebackup="$(activity_value "${standby_activity}" BASEBACKUP)"
  primary_bootstrap="$(activity_value "${primary_activity}" BOOTSTRAP)"
  standby_bootstrap="$(activity_value "${standby_activity}" BOOTSTRAP)"
  for value in "${local_installers}" "${primary_basebackup}" "${standby_basebackup}" "${primary_bootstrap}" "${standby_bootstrap}"; do
    [[ "${value}" =~ ^[0-9]+$ ]] || die '无法解析安装/同步进程状态；拒绝并发修复。' 20
  done
  if ((local_installers + primary_basebackup + standby_basebackup + primary_bootstrap + standby_bootstrap > 0)); then
    printf 'CHECK install_or_sync status=WAIT local_installer=%s primary_basebackup=%s standby_basebackup=%s primary_bootstrap=%s standby_bootstrap=%s\n' \
      "${local_installers}" "${primary_basebackup}" "${standby_basebackup}" "${primary_bootstrap}" "${standby_bootstrap}"
    printf 'REPAIR_RESULT=WAITING_FOR_CURRENT_INSTALL_OR_BASEBACKUP action=none\n'
    log '检测到完整安装或基础同步仍在运行；本次只记录状态，不停止、不修改、不并发启动 Pgpool 修复。'
    exit 10
  fi
  printf 'CHECK install_or_sync status=PASS active=0\n'
}

remote_database_snapshot() {
  local host="$1" role="$2" bin_dir admin_tool pgdata port
  if [[ "${role}" == primary ]]; then
    bin_dir="${PRIMARY_PG_BIN_DIR}"; admin_tool="${PRIMARY_ADMIN_TOOL}"; pgdata="${PRIMARY_PGDATA}"; port="${PRIMARY_PORT}"
  else
    bin_dir="${STANDBY_PG_BIN_DIR}"; admin_tool="${STANDBY_ADMIN_TOOL}"; pgdata="${STANDBY_PGDATA}"; port="${STANDBY_PORT}"
  fi
  {
    printf 'ROLE=%q\n' "${role}"
    printf 'BIN_DIR=%q\n' "${bin_dir}"
    printf 'ADMIN_TOOL=%q\n' "${admin_tool}"
    printf 'PGDATA=%q\n' "${pgdata}"
    printf 'PORT=%q\n' "${port}"
    printf 'EXPECTED_POSTGRES_SHA=%q\n' "${DB_POSTGRES_SHA256}"
    printf 'EXPECTED_BASEBACKUP_SHA=%q\n' "${DB_PG_BASEBACKUP_SHA256}"
    printf 'EXPECTED_CONFIG_SHA=%q\n' "${DB_PG_CONFIG_SHA256}"
    printf 'EXPECTED_TOOLS_SHA=%q\n' "${DB_TOOLS_SHA256}"
    printf 'EXPECTED_APPLICATION=%q\n' "${STANDBY_APPLICATION_NAME}"
    printf 'EXPECTED_SLOT=%q\n' "${REPLICATION_SLOT_NAME}"
    cat <<'REMOTE'
set -Eeuo pipefail
[[ "$(id -u)" == 0 && "$(uname -m)" == aarch64 && -r /etc/os-release ]]
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in kylin:V10|centos:7|centos:7.*) ;; *) exit 41;; esac
[[ "$(sha256sum "${BIN_DIR}/postgres" | awk '{print $1}')" == "${EXPECTED_POSTGRES_SHA}" ]]
[[ "$(sha256sum "${BIN_DIR}/pg_basebackup" | awk '{print $1}')" == "${EXPECTED_BASEBACKUP_SHA}" ]]
[[ "$(sha256sum "${BIN_DIR}/pg_config" | awk '{print $1}')" == "${EXPECTED_CONFIG_SHA}" ]]
[[ "$(sha256sum "${ADMIN_TOOL}" | awk '{print $1}')" == "${EXPECTED_TOOLS_SHA}" ]]
cd /tmp
runuser -u postgres -- env PATH="${BIN_DIR}:/usr/bin:/bin" "${BIN_DIR}/pg_ctl" -D "${PGDATA}" status >/dev/null
if [[ "${ROLE}" == primary ]]; then
  "${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c "select 'DATABASE='||current_setting('server_version_num')||'|'||(case when pg_is_in_recovery() then 't' else 'f' end)||'|'||current_setting('cluster_name')||'|'||(select system_identifier from pg_control_system())"
  "${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c "select 'REPLICATION='||coalesce((select application_name||'|'||state||'|'||sync_state||'|'||coalesce(client_addr::text,'') from pg_stat_replication where application_name='${EXPECTED_APPLICATION}' limit 1),'absent')"
  "${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c "select 'SLOT='||coalesce((select slot_name||'|'||slot_type||'|'||(case when active then 't' else 'f' end) from pg_replication_slots where slot_name='${EXPECTED_SLOT}' limit 1),'absent')"
else
  "${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c "select 'DATABASE='||current_setting('server_version_num')||'|'||(case when pg_is_in_recovery() then 't' else 'f' end)||'|'||current_setting('cluster_name')||'|'||(select system_identifier from pg_control_system())"
  "${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c "select 'WAL_RECEIVER='||coalesce((select status from pg_stat_wal_receiver limit 1),'absent')"
fi
REMOTE
  } | remote_root "${host}"
}

primary_hba_policy_snapshot() {
  {
    printf 'ADMIN_TOOL=%q\n' "${PRIMARY_ADMIN_TOOL}"
    printf 'PORT=%q\n' "${PRIMARY_PORT}"
    cat <<'REMOTE'
set -Eeuo pipefail
[[ "$(id -u)" == 0 ]]
hba_path="$("${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c "select current_setting('hba_file')")"
[[ "${hba_path}" == /* && -f "${hba_path}" && ! -L "${hba_path}" ]]
mapfile -t managed_begin_lines < <(awk '/^[[:space:]]*#[[:space:]]*BEGIN[[:space:]]+PG_RW_PROXY_HBA[[:space:]]*$/{print NR}' "${hba_path}")
mapfile -t managed_end_lines < <(awk '/^[[:space:]]*#[[:space:]]*END[[:space:]]+PG_RW_PROXY_HBA[[:space:]]*$/{print NR}' "${hba_path}")
[[ "${#managed_begin_lines[@]}" == 1 && "${#managed_end_lines[@]}" == 1 ]]
managed_begin="${managed_begin_lines[0]}"
managed_end="${managed_end_lines[0]}"
((managed_begin < managed_end))
source_hash_before="$(sha256sum "${hba_path}" | awk '{print $1}')"
hba_error_count="$("${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c \
  "select count(*) from pg_hba_file_rules where error is not null")"
[[ "${hba_error_count}" == 0 ]]
ignored_count="$("${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c \
  "select count(*) from pg_hba_file_rules
   where error is null and type<>'local'
     and not (line_number>${managed_begin} and line_number<${managed_end})
     and not (type='host' and auth_method in ('md5','scram-sha-256')
       and address ~ '^[0-9]+(\\.[0-9]+){3}$' and netmask ~ '^[0-9]+(\\.[0-9]+){3}$')")"
rules_output="$("${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c \
  "select 'HBA_RULE='||line_number||'|'||
          inet_merge(address::inet,(address::inet | ~netmask::inet))::text
   from pg_hba_file_rules
   where error is null and type='host' and auth_method in ('md5','scram-sha-256')
     and line_number not between ${managed_begin}+1 and ${managed_end}-1
     and address ~ '^[0-9]+(\\.[0-9]+){3}$' and netmask ~ '^[0-9]+(\\.[0-9]+){3}$'
   order by line_number")"
source_hash_after="$(sha256sum "${hba_path}" | awk '{print $1}')"
[[ "${source_hash_before}" == "${source_hash_after}" ]]

printf 'HBA_PATH=%s\n' "${hba_path}"
printf 'HBA_SOURCE_SHA256=%s\n' "${source_hash_before}"
printf 'HBA_MANAGED_BEGIN=%s\n' "${managed_begin}"
printf 'HBA_MANAGED_END=%s\n' "${managed_end}"
printf 'HBA_IGNORED_COUNT=%s\n' "${ignored_count}"
[[ -z "${rules_output}" ]] || printf '%s\n' "${rules_output}"
REMOTE
  } | remote_root "${PRIMARY_HOST}"
}

primary_hba_source_sha256() {
  {
    printf 'ADMIN_TOOL=%q\n' "${PRIMARY_ADMIN_TOOL}"
    printf 'PORT=%q\n' "${PRIMARY_PORT}"
    cat <<'REMOTE'
set -Eeuo pipefail
hba_path="$("${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c "select current_setting('hba_file')")"
[[ "${hba_path}" == /* && -f "${hba_path}" && ! -L "${hba_path}" ]]
sha256sum "${hba_path}" | awk '{print $1}'
REMOTE
  } | remote_root "${PRIMARY_HOST}"
}

query_direct() {
  local host="$1" port="$2" user="$3" password="$4" database="$5" sql="$6"
  env LD_LIBRARY_PATH="${CHECK_LD_LIBRARY_PATH}" PGPASSWORD="${password}" PGCONNECT_TIMEOUT=5 \
    "${CHECK_PSQL}" -XAtq -v ON_ERROR_STOP=1 -h "${host}" -p "${port}" -U "${user}" -d "${database}" -F '|' -c "${sql}"
}

database_blocked() {
  printf 'REPAIR_RESULT=BLOCKED_DATABASE action=none reason=%s\n' "$1"
  die "$2；repair.sh 不会配置或重启 Primary，也不会重新执行基础同步。" 20
}

INSTALL_PHASE='检测完整安装与基础同步进程'
check_active_install_or_sync

INSTALL_PHASE='只读校验 Primary、Standby 与 Streaming Replication'
primary_snapshot="$(remote_database_snapshot "${PRIMARY_HOST}" primary)" || \
  database_blocked primary_unreachable 'Primary 运行状态读取失败'
standby_resume_needed=no
standby_resume_evidence=''
standby_resume_running=''
standby_resume_control_system_id=''
if standby_snapshot="$(remote_database_snapshot "${STANDBY_HOST}" standby 2>"${TEMP_ROOT}/standby-snapshot.error")"; then
  :
else
  standby_snapshot_status=$?
  warn "Standby SQL 状态读取失败（status=${standby_snapshot_status}）：$(tail -n 40 "${TEMP_ROOT}/standby-snapshot.error" 2>/dev/null || true)"
  if standby_resume_candidate="$(standby_resume_candidate_snapshot 2>"${TEMP_ROOT}/standby-resume-candidate.error")"; then
    IFS='|' read -r resume_flag standby_resume_evidence standby_resume_running standby_resume_control_system_id <<<"${standby_resume_candidate}"
    [[ "${resume_flag}" == 'RESUME_CANDIDATE=yes' && "${standby_resume_control_system_id}" =~ ^[0-9]+$ ]] || \
      database_blocked standby_resume_evidence "Standby 续启证据格式异常：${standby_resume_candidate:-empty}"
    standby_resume_needed=yes
    printf 'CHECK standby_resume_candidate status=PASS evidence=%s postmaster_running=%s system_id=%s basebackup=will_not_run\n' \
      "${standby_resume_evidence}" "${standby_resume_running}" "${standby_resume_control_system_id}"
  else
    candidate_status=$?
    database_blocked standby_unavailable "Standby 当前不可查询，且不能证明基础备份已完整完成：status=${candidate_status} detail=$(tail -n 60 "${TEMP_ROOT}/standby-resume-candidate.error" 2>/dev/null || true)"
  fi
fi
primary_database="$(sed -n 's/^DATABASE=//p' <<<"${primary_snapshot}")"
primary_replication="$(sed -n 's/^REPLICATION=//p' <<<"${primary_snapshot}")"
primary_slot="$(sed -n 's/^SLOT=//p' <<<"${primary_snapshot}")"

IFS='|' read -r primary_version primary_recovery primary_cluster primary_system_id <<<"${primary_database}"
[[ "${primary_version}" == '120000' && "${primary_recovery}" == 'f' && "${primary_cluster}" == 'rw-primary' ]] || \
  database_blocked primary_identity "Primary 状态不满足 rw-primary/非恢复态：${primary_database:-empty}"
[[ "${primary_system_id}" =~ ^[0-9]+$ ]] || database_blocked primary_system_identifier 'Primary system identifier 无效'
if [[ "${standby_resume_needed}" == yes ]]; then
  [[ "${standby_resume_control_system_id}" == "${primary_system_id}" ]] || \
    database_blocked system_identifier "待续启 PGDATA system identifier=${standby_resume_control_system_id} 不属于当前 Primary=${primary_system_id}"
  [[ "${primary_slot}" == "${REPLICATION_SLOT_NAME}|physical|f" || "${primary_slot}" == "${REPLICATION_SLOT_NAME}|physical|t" ]] || \
    database_blocked replication_slot "复制槽不存在或类型异常：${primary_slot:-empty}"
  printf 'CHECK database_roles status=RESUME_NEEDED primary=rw-primary standby=existing_basebackup system_id_match=yes\n'
else
  standby_database="$(sed -n 's/^DATABASE=//p' <<<"${standby_snapshot}")"
  standby_receiver="$(sed -n 's/^WAL_RECEIVER=//p' <<<"${standby_snapshot}")"
  IFS='|' read -r standby_version standby_recovery standby_cluster standby_system_id <<<"${standby_database}"
  [[ "${standby_version}" == '120000' && "${standby_recovery}" == 't' && "${standby_cluster}" == 'rw-standby' ]] || \
    database_blocked standby_identity "Standby 状态不满足 rw-standby/恢复态：${standby_database:-empty}"
  [[ "${standby_system_id}" == "${primary_system_id}" ]] || \
    database_blocked system_identifier "Primary/Standby system identifier 不一致：Primary=${primary_system_id}, Standby=${standby_system_id:-empty}"
  [[ "${primary_replication}" == "${STANDBY_APPLICATION_NAME}|streaming|"* ]] || \
    database_blocked replication "Primary 未看到预期 streaming 复制：${primary_replication:-empty}"
  [[ "${primary_slot}" == "${REPLICATION_SLOT_NAME}|physical|t" ]] || \
    database_blocked replication_slot "复制槽未处于 active physical 状态：${primary_slot:-empty}"
  [[ "${standby_receiver}" == 'streaming' ]] || \
    database_blocked wal_receiver "Standby WAL receiver 未处于 streaming：${standby_receiver:-empty}"
  printf 'CHECK database_roles status=PASS primary=rw-primary standby=rw-standby system_id_match=yes\n'
  printf 'CHECK streaming_replication status=PASS application=%s slot=%s\n' "${STANDBY_APPLICATION_NAME}" "${REPLICATION_SLOT_NAME}"
fi

monitor_primary="$(query_direct "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${MONITOR_USER}" "${MONITOR_PASSWORD}" postgres 'select pg_is_in_recovery()')" || \
  database_blocked monitor_auth 'Pgpool 监控账号无法连接 Primary'
[[ "${monitor_primary}" == f ]] || database_blocked monitor_role "监控账号读取到的 Primary 角色异常：${monitor_primary}"

probe_contract_sql="select case when exists (
  select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='business' and c.relname='rw_probe' and c.relkind='r'
    and (select count(*) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)=4
    and exists (select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='probe_id' and a.atttypid='bigint'::regtype and a.attnotnull and a.attidentity='d')
    and exists (select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='probe_key' and a.atttypid='character varying'::regtype and a.atttypmod=84 and a.attnotnull)
    and exists (select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='payload' and a.atttypid='jsonb'::regtype and a.attnotnull and a.atthasdef)
    and exists (select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='created_at' and a.atttypid='timestamp with time zone'::regtype and a.attnotnull and a.atthasdef)
) then 'compatible' else 'incompatible' end"
business_primary="$(query_direct "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${BUSINESS_USER}" "${REQUEST_BUSINESS_PASSWORD}" "${BUSINESS_DATABASE}" "select current_user,pg_is_in_recovery(),current_setting('cluster_name'),(${probe_contract_sql})")" || \
  database_blocked business_auth '业务账号无法连接 Primary'
[[ "${business_primary}" == "${BUSINESS_USER}|f|rw-primary|compatible" ]] || \
  database_blocked business_probe "Primary 业务账号或路由探针异常：${business_primary:-empty}"
if [[ "${standby_resume_needed}" == no ]]; then
  monitor_standby="$(query_direct "${STANDBY_HOST}" "${STANDBY_PORT}" "${MONITOR_USER}" "${MONITOR_PASSWORD}" postgres 'select pg_is_in_recovery()')" || \
    database_blocked monitor_auth 'Pgpool 监控账号无法连接 Standby'
  [[ "${monitor_standby}" == t ]] || database_blocked monitor_role "监控账号读取到的 Standby 角色异常：${monitor_standby}"
  business_standby="$(query_direct "${STANDBY_HOST}" "${STANDBY_PORT}" "${BUSINESS_USER}" "${REQUEST_BUSINESS_PASSWORD}" "${BUSINESS_DATABASE}" "select current_user,pg_is_in_recovery(),current_setting('cluster_name'),(${probe_contract_sql})")" || \
    database_blocked business_auth '业务账号无法连接 Standby'
  [[ "${business_standby}" == "${BUSINESS_USER}|t|rw-standby|compatible" ]] || \
    database_blocked business_probe "Standby 业务账号或路由探针异常：${business_standby:-empty}"
  printf 'CHECK database_credentials status=PASS monitor=yes business=yes probe=compatible\n'
else
  printf 'CHECK database_credentials status=PARTIAL primary_monitor=yes primary_business=yes standby=deferred_until_resume\n'
fi

INSTALL_PHASE='从 Primary 只读提取客户端 IPv4 白名单'
primary_policy_snapshot_file="${TEMP_ROOT}/primary-hba-policy.snapshot"
primary_policy_rules_file="${TEMP_ROOT}/primary-client-policy.rules"
primary_policy_trace_file="${TEMP_ROOT}/primary-client-policy.trace"
if primary_hba_policy_snapshot >"${primary_policy_snapshot_file}"; then
  chmod 600 "${primary_policy_snapshot_file}"
else
  policy_snapshot_status=$?
  printf 'REPAIR_RESULT=BLOCKED_PRIMARY_POLICY action=none reason=snapshot_failed status=%s\n' \
    "${policy_snapshot_status}"
  die '无法从 Primary 取得稳定、可审计的 pg_hba_file_rules 快照；未修改任何节点。' 25
fi
if ! build_pgpool_client_policy "${primary_policy_snapshot_file}" "${primary_policy_rules_file}" \
  "${primary_policy_trace_file}"; then
  printf '%s\n' '--- PRIMARY_CLIENT_POLICY_TRACE_BEGIN ---'
  cat "${primary_policy_trace_file}"
  printf '%s\n' '--- PRIMARY_CLIENT_POLICY_TRACE_END ---'
  printf 'REPAIR_RESULT=BLOCKED_PRIMARY_POLICY action=none reason=no_normal_ipv4_rule_or_invalid_snapshot trace=%s\n' \
    "${primary_policy_trace_file}"
  die 'Primary 没有可同步的普通 IPv4 host 白名单，或 HBA 快照格式异常；未修改任何节点。' 25
fi
chmod 600 "${primary_policy_rules_file}" "${primary_policy_trace_file}"
printf 'CHECK primary_client_policy status=PASS source=%s source_sha256=%s rules=%s ignored=%s duplicates=%s policy_sha256=%s\n' \
  "${PRIMARY_POLICY_HBA_PATH}" "${PRIMARY_POLICY_SOURCE_SHA256}" "${PRIMARY_POLICY_RULE_COUNT}" \
  "${PRIMARY_POLICY_IGNORED_COUNT}" "${PRIMARY_POLICY_DUPLICATE_COUNT}" "${PRIMARY_POLICY_SHA256}"
printf 'PRIMARY_CLIENT_POLICY_TRACE_BEGIN\n'
cat "${primary_policy_trace_file}"
printf 'PRIMARY_CLIENT_POLICY_TRACE_END\n'

# 仅 repair.sh 设置此只读生成文件；31-configure-pgpool.sh 会再次校验文件所有者
# 及固定的 host all all <IPv4 CIDR> md5 格式，不能注入其他配置。
PGPOOL_CLIENT_POLICY_FILE="${primary_policy_rules_file}"
PGPOOL_CLIENT_POLICY_MODE='primary_hba_repair'
PGPOOL_CLIENT_POLICY_SHA256="${PRIMARY_POLICY_SHA256}"
export PGPOOL_CLIENT_POLICY_FILE PGPOOL_CLIENT_POLICY_MODE PGPOOL_CLIENT_POLICY_SHA256

declare -a repair_items=()
add_repair_item() {
  local item="$1" existing
  for existing in "${repair_items[@]:-}"; do [[ "${existing}" == "${item}" ]] && return; done
  repair_items+=("${item}")
}
[[ "${standby_resume_needed}" == yes ]] && add_repair_item standby_resume_existing_pgdata

block_unsafe_pgpool() {
  printf 'REPAIR_RESULT=BLOCKED_PGPOOL_OWNERSHIP action=none reason=%s\n' "$1"
  die "$2；为避免覆盖非项目服务，拒绝自动修复。" 22
}

INSTALL_PHASE='检测 Pgpool 安装、配置、服务与路由'
for prefix in "${PGPOOL_RUNTIME_PREFIX}" "${PG_CLIENT_PREFIX}" "${PGPOOL_INSTALL_PREFIX}"; do
  if [[ -e "${prefix}" || -L "${prefix}" ]]; then
    [[ -d "${prefix}" && ! -L "${prefix}" && "$(readlink -f -- "${prefix}")" == "${prefix}" ]] || \
      block_unsafe_pgpool unsafe_prefix "既有安装前缀不是安全目录：${prefix}"
  else
    add_repair_item pgpool_offline_runtime
  fi
done

unit_file="/etc/systemd/system/${PGPOOL_SERVICE}.service"
if [[ -e "${unit_file}" || -L "${unit_file}" ]]; then
  [[ -f "${unit_file}" && ! -L "${unit_file}" ]] || block_unsafe_pgpool unsafe_unit "Pgpool unit 类型异常：${unit_file}"
  grep -Fq "ExecStart=${PGPOOL_INSTALL_PREFIX}/bin/pgpool" "${unit_file}" || \
    block_unsafe_pgpool foreign_unit "既有 ${PGPOOL_SERVICE} 服务不属于本项目"
else
  add_repair_item pgpool_systemd_unit
fi

if [[ ! -x "${PGPOOL_INSTALL_PREFIX}/bin/pgpool" || ! -x "${PG_CLIENT_PREFIX}/bin/psql" || \
      ! -d "${PGPOOL_RUNTIME_PREFIX}/lib" ]]; then
  add_repair_item pgpool_offline_runtime
fi

desired_conf="${TEMP_ROOT}/desired-pgpool.conf"
desired_hba="${TEMP_ROOT}/desired-pool_hba.conf"
desired_hba_rules="${TEMP_ROOT}/desired-pool_hba.rules"
render_template "${ROOT_DIR}/templates/pgpool.conf.tpl" "${desired_conf}" \
  PGPOOL_PORT "${PGPOOL_PORT}" PCP_PORT "${PCP_PORT}" PGPOOL_CONFIG_DIR "${PGPOOL_CONFIG_DIR}" \
  NUM_INIT_CHILDREN "${NUM_INIT_CHILDREN}" MAX_POOL "${MAX_POOL}" CONNECTION_LIFE_TIME "${CONNECTION_LIFE_TIME}" \
  PRIMARY_HOST "${PRIMARY_HOST}" PRIMARY_PORT "${PRIMARY_PORT}" PRIMARY_READ_WEIGHT "${PRIMARY_READ_WEIGHT}" \
  STANDBY_HOST "${STANDBY_HOST}" STANDBY_PORT "${STANDBY_PORT}" STANDBY_READ_WEIGHT "${STANDBY_READ_WEIGHT}" \
  STANDBY_APPLICATION_NAME "${STANDBY_APPLICATION_NAME}" DISABLE_LOAD_BALANCE_ON_WRITE "${DISABLE_LOAD_BALANCE_ON_WRITE}" \
  READ_LAG_THRESHOLD_SECONDS "${READ_LAG_THRESHOLD_SECONDS}" MONITOR_USER "${MONITOR_USER}" \
  SR_CHECK_PERIOD "${SR_CHECK_PERIOD}" HEALTH_CHECK_PERIOD "${HEALTH_CHECK_PERIOD}" \
  HEALTH_CHECK_TIMEOUT "${HEALTH_CHECK_TIMEOUT}" HEALTH_CHECK_MAX_RETRIES "${HEALTH_CHECK_MAX_RETRIES}" \
  HEALTH_CHECK_RETRY_DELAY "${HEALTH_CHECK_RETRY_DELAY}" CONNECT_TIMEOUT_MS "${CONNECT_TIMEOUT_MS}" \
  LOG_PER_NODE_STATEMENT "${LOG_PER_NODE_STATEMENT}"
printf '# BEGIN PRIMARY_SYNCED_CLIENT_POLICY\n' >"${desired_hba_rules}"
printf '# policy_sha256=%s rules=%s\n' \
  "${PRIMARY_POLICY_SHA256}" "${PRIMARY_POLICY_RULE_COUNT}" >>"${desired_hba_rules}"
cat "${primary_policy_rules_file}" >>"${desired_hba_rules}"
printf '# END PRIMARY_SYNCED_CLIENT_POLICY\n' >>"${desired_hba_rules}"
awk -v rules="${desired_hba_rules}" '$0=="{{CLIENT_HBA_RULES}}"{while((getline line < rules)>0)print line;close(rules);next}{print}' \
  "${ROOT_DIR}/templates/pool_hba.conf.tpl" >"${desired_hba}"

if [[ ! -f "${PGPOOL_CONFIG_DIR}/pgpool.conf" || ! -f "${PGPOOL_CONFIG_DIR}/pool_hba.conf" || \
      ! -s "${PGPOOL_CONFIG_DIR}/pool_passwd" || ! -s "${PGPOOL_CONFIG_DIR}/pcp.conf" || \
      ! -s "${PGPOOL_CONFIG_DIR}/.pgpoolkey" ]]; then
  add_repair_item pgpool_configuration
else
  cmp -s "${desired_conf}" "${PGPOOL_CONFIG_DIR}/pgpool.conf" || add_repair_item pgpool_configuration
  cmp -s "${desired_hba}" "${PGPOOL_CONFIG_DIR}/pool_hba.conf" || add_repair_item pgpool_configuration
fi

service_active=no
service_enabled=no
systemctl is-active --quiet "${PGPOOL_SERVICE}" && service_active=yes
systemctl is-enabled --quiet "${PGPOOL_SERVICE}" 2>/dev/null && service_enabled=yes
[[ "${service_active}" == yes ]] || add_repair_item pgpool_service
[[ "${service_enabled}" == yes ]] || add_repair_item pgpool_service

pool_nodes=''
if [[ "${service_active}" == yes && -x "${PG_CLIENT_PREFIX}/bin/psql" ]]; then
  existing_ld_path="${PGPOOL_RUNTIME_PREFIX}/lib:${PG_CLIENT_PREFIX}/lib:${PGPOOL_INSTALL_PREFIX}/lib"
  if pool_nodes="$(timeout 20 env LD_LIBRARY_PATH="${existing_ld_path}" PGPASSWORD="${REQUEST_BUSINESS_PASSWORD}" PGCONNECT_TIMEOUT=5 \
    "${PG_CLIENT_PREFIX}/bin/psql" -XAtq -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "${PGPOOL_PORT}" \
    -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" -F '|' -c 'show pool_nodes' 2>&1)"; then
    node0="$(awk -F '|' '$1==0 {print $2"|"$3"|"$4"|"$7"|"$8}' <<<"${pool_nodes}")"
    node1="$(awk -F '|' '$1==1 {print $2"|"$3"|"$4"|"$7"|"$8}' <<<"${pool_nodes}")"
    [[ "${node0}" == "${PRIMARY_HOST}|${PRIMARY_PORT}|up|primary|primary" && \
       "${node1}" == "${STANDBY_HOST}|${STANDBY_PORT}|up|standby|standby" ]] || add_repair_item pgpool_backend_state
  else
    warn "既有 Pgpool 节点查询失败：${pool_nodes}"
    add_repair_item pgpool_backend_state
  fi
else
  add_repair_item pgpool_backend_state
fi

if [[ "${service_active}" == yes ]]; then
  ss -lntH "sport = :${PGPOOL_PORT}" | grep -Eq "(0\.0\.0\.0|\[::\]|\*):${PGPOOL_PORT}" || add_repair_item pgpool_listener
  ss -lntH "sport = :${PCP_PORT}" | grep -Eq "(127\.0\.0\.1|\[::1\]):${PCP_PORT}" || add_repair_item pgpool_listener
  if ss -lntH "sport = :${PCP_PORT}" | grep -Eq "(0\.0\.0\.0|\[::\]|\*):${PCP_PORT}"; then
    add_repair_item pgpool_listener
  fi
fi

printf 'CHECK pgpool_local status=%s service_active=%s service_enabled=%s repair_items=%s\n' \
  "$([[ ${#repair_items[@]} -eq 0 ]] && printf PASS || printf REPAIR_NEEDED)" \
  "${service_active}" "${service_enabled}" "${#repair_items[@]}"
if [[ -n "${pool_nodes}" && "${pool_nodes}" != *'password authentication failed'* ]]; then
  printf '%s\n' "${pool_nodes}"
fi

verify_local_pgpool_routing() {
  local verify_output verify_status
  INSTALL_PHASE='验证 Pgpool 复制状态与 SQL 路由'
  if verify_output="$("${ROOT_DIR}/scripts/40-verify-cluster.sh" 2>&1)"; then
    printf '%s\n' "${verify_output}"
  else
    verify_status=$?
    printf '%s\n' "${verify_output}" >&2
    return "${verify_status}"
  fi
}

if ((${#repair_items[@]} == 0)); then
  if ! verify_local_pgpool_routing; then
    add_repair_item pgpool_routing
  else
      printf 'REPAIR_DECISION=NONE\n'
      printf 'REPAIR_RESULT=HEALTHY action=none entry=%s:%s log=%s\n' "${PGPOOL_HOST}" "${PGPOOL_PORT}" "${REPAIR_LOG_FILE}"
      trap - ERR
      exit 0
  fi
fi

printf '\n检测到以下可安全续装项：\n'
printf '  - %s\n' "${repair_items[@]}"
if [[ "${standby_resume_needed}" == yes ]]; then
  printf '基础备份完整性证据已通过；修复会先启动/等待现有 Standby PGDATA，然后补齐 Pgpool。不会执行 pg_basebackup，也不会重建主从。\n'
else
  printf '数据库状态已通过；修复范围只包括当前 Pgpool 服务器的离线运行时、配置和 systemd 服务。\n'
fi
INSTALL_PHASE='等待中断续装授权'
if ! read -r -p '输入 REPAIR 执行上述安全续装；其他输入只保留日志并退出: ' confirmation; then
  confirmation=''
  printf '\n[WARN] 未读到修复授权（输入结束/EOF），按未授权处理。\n' >&2
fi
if [[ "${confirmation}" != 'REPAIR' ]]; then
  printf 'REPAIR_RESULT=NEEDED_NOT_APPLIED action=none items=%s log=%s\n' "${#repair_items[@]}" "${REPAIR_LOG_FILE}"
  trap - ERR
  exit 30
fi

INSTALL_PHASE='修复前并发与客户端连接复核'
check_active_install_or_sync
latest_primary_hba_sha256="$(primary_hba_source_sha256)" || \
  die '修复授权后无法重新读取 Primary HBA SHA256，拒绝使用旧快照。' 25
[[ "${latest_primary_hba_sha256}" == "${PRIMARY_POLICY_SOURCE_SHA256}" ]] || \
  die "Primary HBA 在检查与落盘之间发生变化：before=${PRIMARY_POLICY_SOURCE_SHA256} after=${latest_primary_hba_sha256}；请重新运行 repair.sh。" 25
[[ "$(sha256sum "${primary_policy_rules_file}" | awk '{print $1}')" == "${PRIMARY_POLICY_SHA256}" ]] || \
  die '本次 Pgpool 客户端策略文件在授权前发生变化，拒绝落盘。' 25
if [[ "${service_active}" == yes ]]; then
  established_frontends="$(ss -Htn state established "sport = :${PGPOOL_PORT}" 2>/dev/null | awk 'END{print NR+0}')"
  [[ "${established_frontends}" == '0' ]] || \
    die "Pgpool 当前仍有 ${established_frontends} 个外部 TCP 前端连接；请先停止客户端连接池后重试。" 23
fi

if [[ "${standby_resume_needed}" == yes ]]; then
  INSTALL_PHASE='续启已完成基础备份的 Standby'
  standby_resume_stage="$(stage_standby_resume_script)"
  set +e
  standby_resume_output="$({
    printf 'cd %q\n' "${standby_resume_stage}"
    printf 'CLUSTER_CONFIG=%q SECRETS_CONFIG=%q POOL_USERS_FILE=%q ./scripts/22-resume-standby-after-basebackup.sh\n' \
      "${standby_resume_stage}/session-config/cluster.env" \
      "${standby_resume_stage}/session-config/secrets.env" \
      "${standby_resume_stage}/session-config/pool-users.txt"
  } | remote_root "${STANDBY_HOST}" 2>&1)"
  standby_resume_status=$?
  set -e
  cleanup_standby_resume_stage "${standby_resume_stage}"
  printf '%s\n' "${standby_resume_output}"
  [[ "${standby_resume_status}" == 0 && "${standby_resume_output}" == *'STANDBY_RESUME_RESULT=READY'* && \
     "${standby_resume_output}" == *'basebackup=not_run'* ]] || \
    die "Standby 现有 PGDATA 续启失败（status=${standby_resume_status}）；未执行基础备份。" 21
  standby_after_resume="$(remote_database_snapshot "${STANDBY_HOST}" standby)" || \
    die 'Standby 报告续启成功，但后续只读状态查询失败。' 21
  standby_database="$(sed -n 's/^DATABASE=//p' <<<"${standby_after_resume}")"
  standby_receiver="$(sed -n 's/^WAL_RECEIVER=//p' <<<"${standby_after_resume}")"
  IFS='|' read -r standby_version standby_recovery standby_cluster standby_system_id <<<"${standby_database}"
  [[ "${standby_version}|${standby_recovery}|${standby_cluster}|${standby_system_id}|${standby_receiver}" == \
     "120000|t|rw-standby|${primary_system_id}|streaming" ]] || \
    die "Standby 续启后的状态异常：database=${standby_database} receiver=${standby_receiver}" 21
  primary_replication_after="$(remote_database_snapshot "${PRIMARY_HOST}" primary | sed -n 's/^REPLICATION=//p')"
  [[ "${primary_replication_after}" == "${STANDBY_APPLICATION_NAME}|streaming|"* ]] || \
    die "Standby 续启后 Primary 未看到 streaming：${primary_replication_after:-empty}" 21
  printf 'CHECK standby_resume status=PASS basebackup=not_run streaming=yes system_id_match=yes\n'
fi

INSTALL_PHASE='离线修复 Pgpool 运行时与 systemd 服务'
log '开始 Pgpool 修复：安装/校验本机离线运行时和 systemd unit。'
"${ROOT_DIR}/scripts/30-install-pgpool.sh"
INSTALL_PHASE='修复 Pgpool 配置、认证与服务状态'
"${ROOT_DIR}/scripts/31-configure-pgpool.sh"
INSTALL_PHASE='修复后完整路由与外部入口验收'
verify_local_pgpool_routing || die '续装修复完成后本机路由验收仍失败；请保留完整日志。' 24

repair_action='pgpool_only'
[[ "${standby_resume_needed}" == yes ]] && repair_action='resume_existing_standby_then_pgpool'
printf 'REPAIR_RESULT=REPAIRED action=%s basebackup=not_run entry=%s:%s log=%s\n' \
  "${repair_action}" "${PGPOOL_HOST}" "${PGPOOL_PORT}" "${REPAIR_LOG_FILE}"
trap - ERR
exit 0
