#!/usr/bin/env bash

# 在不重建 Standby、不重启数据库的前提下，让现有 PostgreSQL 登录用户可通过
# Pgpool-II 访问其原本有权连接的全部数据库。脚本不创建用户、不修改密码或权限。

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_PHASE='启动参数处理'
APPLY_STARTED='no'
SUCCESS='no'
TEMP_ROOT=''
LOCAL_BACKUP_DIR=''
PRIMARY_BACKUP_DIR=''
STANDBY_BACKUP_DIR=''

readonly PGPOOL_SERVICE='pgpool'
readonly PGPOOL_CONFIG_DIR='/etc/pgpool-II'
readonly PGPOOL_CONF="${PGPOOL_CONFIG_DIR}/pgpool.conf"
readonly POOL_HBA="${PGPOOL_CONFIG_DIR}/pool_hba.conf"
readonly PGPOOL_BIN='/opt/pgpool-II-4.7.2/bin/pgpool'
readonly PGPOOL_RUNTIME_LIB='/opt/pgpool-runtime-kylin-v10/lib'
readonly DB_ADMIN_TOOL='/opt/pgsql12/bin/tools'
readonly SSHPASS_PAYLOAD='packages/payload/sshpass-1.10-aarch64-kylin-v10.tar.gz'
readonly SSHPASS_SHA256='84bcff17fc7e48d0a8552c985818e17e485f95a66b3c50c4eedde6bcbdc96ffd'
readonly HBA_MARKER='PG_RW_PROXY_ALL_DATABASE_USERS'

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() {
  local line_number="${BASH_LINENO[0]:-unknown}"
  printf '[ERROR] time=%s phase=%s line=%s exit=1\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${SCRIPT_PHASE}" "${line_number}" >&2
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

show_usage() {
  cat <<'USAGE'
用法：
  sudo bash enable-all-databases-users.sh [参数]

参数同时支持“--参数 值”和“--参数=值”；未提供的参数在启动阶段交互补全。

  --pgpool-host IP              当前 Pgpool-II 服务器内网 IPv4
  --primary-host IP             PostgreSQL Primary 内网 IPv4
  --standby-host IP             PostgreSQL Standby 内网 IPv4
  --postgresql-port PORT        Primary/Standby 共用端口，默认 5432
  --pgpool-port PORT            Pgpool-II 对外端口，默认 5432
  --ssh-port PORT               Primary/Standby 共用 root SSH 端口，默认 22
  --root-ssh-password PASSWORD  Primary/Standby 共用 root SSH 密码
  -h, --help                    显示帮助

作用：
  1. 保留 pool_hba.conf 现有客户端来源地址，只把前端认证改为 password；
  2. 仅允许 Pgpool 服务器 IP 以任意现有 PostgreSQL 用户连接全部数据库；
  3. 不创建/启用角色，不修改密码、CONNECT 权限、对象权限或数据库数据；
  4. 只 reload PostgreSQL/Pgpool，不重启数据库，不重新同步 Standby。

所有只读检查通过后，脚本会显示计划；只有输入 APPLY 才执行。
USAGE
}

validate_ipv4() {
  local value="$1" label="$2" octet old_ifs
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "${label} 必须是 IPv4 地址: ${value}"
  old_ifs="${IFS}"
  IFS='.' read -r -a octets <<<"${value}"
  IFS="${old_ifs}"
  for octet in "${octets[@]}"; do
    ((10#${octet} <= 255)) || die "${label} 不是有效 IPv4 地址: ${value}"
  done
}

validate_port() {
  local value="$1" label="$2"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] && ((10#${value} >= 1 && 10#${value} <= 65535)) || \
    die "${label} 不是有效端口: ${value}"
}

prompt_required() {
  local variable_name="$1" prompt_text="$2" value="${!1:-}"
  while [[ -z "${value}" ]]; do
    read -r -p "${prompt_text}: " value || die "无法读取 ${variable_name}。"
  done
  printf -v "${variable_name}" '%s' "${value}"
}

prompt_default() {
  local variable_name="$1" prompt_text="$2" default_value="$3" value="${!1:-}"
  if [[ -z "${value}" ]]; then
    read -r -p "${prompt_text} [${default_value}]: " value || die "无法读取 ${variable_name}。"
    value="${value:-${default_value}}"
  fi
  printf -v "${variable_name}" '%s' "${value}"
}

prompt_secret() {
  local variable_name="$1" prompt_text="$2" value="${!1:-}"
  while [[ -z "${value}" ]]; do
    read -r -s -p "${prompt_text}: " value || die "无法读取 ${variable_name}。"
    printf '\n'
  done
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die 'SSH 密码不能包含换行。'
  printf -v "${variable_name}" '%s' "${value}"
}

parse_inputs() {
  local argument option value
  declare -A seen_options=()
  while (($# > 0)); do
    argument="$1"
    case "${argument}" in
      -h|--help) show_usage; exit 0 ;;
      --*=*) option="${argument%%=*}"; value="${argument#*=}"; shift ;;
      --*)
        option="${argument}"
        (($# >= 2)) || die "参数缺少值: ${option}"
        value="$2"
        shift 2
        ;;
      *) die "不支持的位置参数: ${argument}" ;;
    esac
    [[ -n "${value}" ]] || die "参数值不能为空: ${option}"
    [[ -z "${seen_options[${option}]:-}" ]] || die "参数不能重复提供: ${option}"
    seen_options["${option}"]=1
    case "${option}" in
      --pgpool-host) PGPOOL_HOST="${value}" ;;
      --primary-host) PRIMARY_HOST="${value}" ;;
      --standby-host) STANDBY_HOST="${value}" ;;
      --postgresql-port) POSTGRESQL_PORT="${value}" ;;
      --pgpool-port) PGPOOL_PORT="${value}" ;;
      --ssh-port) SSH_PORT="${value}" ;;
      --root-ssh-password) ROOT_SSH_PASSWORD="${value}" ;;
      *) die "未知参数: ${option}" ;;
    esac
  done
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || die "缺少命令: ${command_name}"
  done
}

config_value() {
  local key="$1" file="$2"
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*'([^']*)'[[:space:]]*(#.*)?$/\\1/p; s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^'#[:space:]]+)[[:space:]]*(#.*)?$/\\1/p" \
    "${file}" | tail -n 1
}

managed_block_is_well_formed() {
  local file="$1" marker="$2" begin_count end_count
  begin_count="$(grep -Fxc "# BEGIN ${marker}" "${file}" || true)"
  end_count="$(grep -Fxc "# END ${marker}" "${file}" || true)"
  [[ "${begin_count}" == "${end_count}" && "${begin_count}" -le 1 ]]
}

remote_root() {
  local host="$1"
  "${SSHPASS_BIN}" -e ssh "${SSH_ARGS[@]}" root@"${host}" bash -s
}

remote_snapshot() {
  local host="$1" expected_role="$2"
  {
    printf 'ADMIN_TOOL=%q\n' "${DB_ADMIN_TOOL}"
    printf 'PORT=%q\n' "${POSTGRESQL_PORT}"
    printf 'EXPECTED_ROLE=%q\n' "${expected_role}"
    printf 'EXPECTED_PGPOOL_HOST=%q\n' "${PGPOOL_HOST}"
    cat <<'REMOTE'
set -Eeuo pipefail
for command_name in id uname sha256sum stat awk grep sed cp mv mktemp df cat mkdir chmod chown rm sleep; do
  command -v "${command_name}" >/dev/null 2>&1
done
[[ "$(id -u)" == 0 && -r /etc/os-release ]]
. /etc/os-release
[[ "$(uname -m)" == aarch64 ]]
case "${ID:-}:${VERSION_ID:-}" in
  kylin:V10) ;;
  centos:7|centos:7.*) ;; # 仅用于本项目 ARM64 实验节点回归。
  *) exit 41 ;;
esac
[[ -x "${ADMIN_TOOL}" ]]

identity="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c \
  "select current_setting('server_version_num')||'|'||(case when pg_is_in_recovery() then 'standby' else 'primary' end)||'|'||(select system_identifier from pg_control_system())||'|'||current_setting('hba_file')")"
IFS='|' read -r version_num actual_role system_id hba_path <<<"${identity}"
[[ "${version_num}" == 120000 && "${actual_role}" == "${EXPECTED_ROLE}" && "${system_id}" =~ ^[0-9]+$ ]]
[[ "${hba_path}" == /* && -f "${hba_path}" && ! -L "${hba_path}" ]]
[[ -r "${hba_path}" && -w "${hba_path}" ]]
[[ -d /var && -w /var ]]
available_kb="$(df -Pk /var | awk 'NR==2{print $4}')"
[[ "${available_kb}" =~ ^[0-9]+$ && "${available_kb}" -ge 10240 ]]
managed_begin="$(grep -Fxc '# BEGIN PG_RW_PROXY_ALL_DATABASE_USERS' "${hba_path}" || true)"
managed_end="$(grep -Fxc '# END PG_RW_PROXY_ALL_DATABASE_USERS' "${hba_path}" || true)"
[[ "${managed_begin}" == "${managed_end}" && "${managed_begin}" -le 1 ]]
hba_errors="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c "select count(*) from pg_hba_file_rules where error is not null")"
[[ "${hba_errors}" == 0 ]]
if [[ "${EXPECTED_ROLE}" == primary ]]; then
  streaming="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c "select count(*) from pg_stat_replication where state='streaming'")"
else
  streaming="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c "select count(*) from pg_stat_wal_receiver where status='streaming'")"
fi
[[ "${streaming}" =~ ^[1-9][0-9]*$ ]]
printf 'REMOTE_SNAPSHOT=%s|%s|%s|%s|%s\n' \
  "${EXPECTED_ROLE}" "${system_id}" "${hba_path}" "$(sha256sum "${hba_path}" | awk '{print $1}')" "${streaming}"
REMOTE
  } | remote_root "${host}"
}

apply_remote_hba() {
  local host="$1" role="$2" expected_hash="$3"
  {
    printf 'ADMIN_TOOL=%q\n' "${DB_ADMIN_TOOL}"
    printf 'PORT=%q\n' "${POSTGRESQL_PORT}"
    printf 'PGPOOL_CIDR=%q\n' "${PGPOOL_HOST}/32"
    printf 'EXPECTED_HASH=%q\n' "${expected_hash}"
    printf 'ROLE=%q\n' "${role}"
    printf 'TIMESTAMP=%q\n' "${RUN_TIMESTAMP}"
    cat <<'REMOTE'
set -Eeuo pipefail
umask 077
hba_path="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c "select current_setting('hba_file')")"
[[ "${hba_path}" == /* && -f "${hba_path}" && ! -L "${hba_path}" ]]
[[ "$(sha256sum "${hba_path}" | awk '{print $1}')" == "${EXPECTED_HASH}" ]]
backup_dir="/var/backups/pg-readwrite-proxy-lab/all-databases-users-${TIMESTAMP}-${ROLE}"
[[ ! -e "${backup_dir}" ]]
mkdir -p "${backup_dir}"
chmod 700 "${backup_dir}"
cp -a -- "${hba_path}" "${backup_dir}/pg_hba.conf.before"

clean_file="$(mktemp)"
new_file="${hba_path}.all-users.$$"
changed=no
rollback_local_node() {
  local status=$?
  trap - EXIT
  rm -f -- "${clean_file}" "${new_file}"
  if [[ "${status}" -ne 0 && "${changed}" == yes ]]; then
    cp -a -- "${backup_dir}/pg_hba.conf.before" "${hba_path}"
    "${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c 'select pg_reload_conf()' >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap rollback_local_node EXIT

awk '
  $0=="# BEGIN PG_RW_PROXY_ALL_DATABASE_USERS" {skip=1; next}
  $0=="# END PG_RW_PROXY_ALL_DATABASE_USERS" {skip=0; next}
  !skip {print}
' "${hba_path}" >"${clean_file}"
cp -a -- "${hba_path}" "${new_file}"
{
  printf '# BEGIN PG_RW_PROXY_ALL_DATABASE_USERS\n'
  printf '# 仅允许 Pgpool 节点代表现有登录角色访问其原有权限范围；不授予数据库权限。\n'
  printf 'host    all    all    %-22s md5\n' "${PGPOOL_CIDR}"
  printf '# END PG_RW_PROXY_ALL_DATABASE_USERS\n\n'
  cat "${clean_file}"
} >"${new_file}"
chown --reference="${hba_path}" "${new_file}"
chmod --reference="${hba_path}" "${new_file}"
mv -f -- "${new_file}" "${hba_path}"
changed=yes
reload_result="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c 'select pg_reload_conf()')"
[[ "${reload_result}" == t ]]
sleep 1
hba_errors="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c "select count(*) from pg_hba_file_rules where error is not null")"
managed_rule="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c \
  "select count(*) from pg_hba_file_rules where type='host' and database='{all}' and user_name='{all}' and address='${PGPOOL_CIDR%/*}' and netmask='255.255.255.255' and auth_method in ('md5','scram-sha-256') and error is null")"
[[ "${hba_errors}" == 0 && "${managed_rule}" =~ ^[1-9][0-9]*$ ]]
changed=no
rm -f -- "${clean_file}"
trap - EXIT
printf 'REMOTE_APPLIED=%s|%s|%s\n' "${ROLE}" "${backup_dir}" "$(sha256sum "${hba_path}" | awk '{print $1}')"
REMOTE
  } | remote_root "${host}"
}

restore_remote_hba() {
  local host="$1" backup_dir="$2"
  [[ -n "${backup_dir}" ]] || return 0
  {
    printf 'ADMIN_TOOL=%q\n' "${DB_ADMIN_TOOL}"
    printf 'PORT=%q\n' "${POSTGRESQL_PORT}"
    printf 'BACKUP_DIR=%q\n' "${backup_dir}"
    cat <<'REMOTE'
set -Eeuo pipefail
hba_path="$(${ADMIN_TOOL} psql -d postgres -p "${PORT}" -c "select current_setting('hba_file')")"
[[ "${BACKUP_DIR}" == /var/backups/pg-readwrite-proxy-lab/all-databases-users-* ]]
[[ -e "${BACKUP_DIR}" ]] || exit 0
[[ -f "${BACKUP_DIR}/pg_hba.conf.before" && ! -L "${BACKUP_DIR}/pg_hba.conf.before" ]]
cp -a -- "${BACKUP_DIR}/pg_hba.conf.before" "${hba_path}"
"${ADMIN_TOOL}" psql -d postgres -p "${PORT}" -c 'select pg_reload_conf()' >/dev/null
REMOTE
  } | remote_root "${host}"
}

cleanup_and_rollback() {
  local status=$?
  trap - EXIT
  if [[ "${status}" -ne 0 && "${APPLY_STARTED}" == yes && "${SUCCESS}" != yes ]]; then
    set +e
    warn '执行失败，开始恢复本次脚本创建的备份。'
    if [[ -n "${LOCAL_BACKUP_DIR}" && -f "${LOCAL_BACKUP_DIR}/pool_hba.conf.before" ]]; then
      cp -a -- "${LOCAL_BACKUP_DIR}/pool_hba.conf.before" "${POOL_HBA}"
      systemctl reload "${PGPOOL_SERVICE}" >/dev/null 2>&1 || true
    fi
    restore_remote_hba "${STANDBY_HOST:-}" "${STANDBY_BACKUP_DIR}" || true
    restore_remote_hba "${PRIMARY_HOST:-}" "${PRIMARY_BACKUP_DIR}" || true
    warn '自动回滚已执行；请结合本次日志复核三项服务状态。'
    set -e
  fi
  [[ -z "${TEMP_ROOT}" || "${TEMP_ROOT}" != /var/tmp/pg-rw-all-users.* ]] || rm -rf -- "${TEMP_ROOT}"
  unset SSHPASS ROOT_SSH_PASSWORD
  exit "${status}"
}
trap cleanup_and_rollback EXIT

PGPOOL_HOST=''
PRIMARY_HOST=''
STANDBY_HOST=''
POSTGRESQL_PORT=''
PGPOOL_PORT=''
SSH_PORT=''
ROOT_SSH_PASSWORD=''
parse_inputs "$@"

[[ "${EUID}" -eq 0 ]] || die '请使用 root 或 sudo 执行。'
require_commands awk sed grep tail sha256sum tar mktemp ssh systemctl journalctl ip ss stat cp mv tee date df timeout

default_pgpool_host="$(ip -o -4 addr show scope global | awk 'NR==1{split($4,a,"/");print a[1]}')"
prompt_default PGPOOL_HOST '当前 Pgpool-II 服务器内网 IPv4 地址' "${default_pgpool_host:-127.0.0.1}"
prompt_required PRIMARY_HOST 'PostgreSQL Primary 内网 IPv4 地址'
prompt_required STANDBY_HOST 'PostgreSQL Standby 内网 IPv4 地址'
prompt_default POSTGRESQL_PORT 'Primary/Standby 共用 PostgreSQL 端口' '5432'
prompt_default PGPOOL_PORT 'Pgpool-II 对外服务端口' '5432'
prompt_default SSH_PORT 'Primary/Standby 共用 root SSH 端口' '22'
prompt_secret ROOT_SSH_PASSWORD 'Primary/Standby 共用 root SSH 密码'

validate_ipv4 "${PGPOOL_HOST}" PGPOOL_HOST
validate_ipv4 "${PRIMARY_HOST}" PRIMARY_HOST
validate_ipv4 "${STANDBY_HOST}" STANDBY_HOST
validate_port "${POSTGRESQL_PORT}" POSTGRESQL_PORT
validate_port "${PGPOOL_PORT}" PGPOOL_PORT
validate_port "${SSH_PORT}" SSH_PORT
[[ "${PGPOOL_HOST}" != "${PRIMARY_HOST}" && "${PGPOOL_HOST}" != "${STANDBY_HOST}" && \
   "${PRIMARY_HOST}" != "${STANDBY_HOST}" ]] || die '三台服务器地址必须不同。'

LOG_DIR='/var/log/pg-readwrite-proxy-lab'
mkdir -p "${LOG_DIR}"
chmod 700 "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/enable-all-databases-users-$(date '+%Y%m%d-%H%M%S')-$$.log"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2)
log "完整日志：${LOG_FILE}"

SCRIPT_PHASE='只读检查 Pgpool 节点'
[[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == kylin && "${VERSION_ID:-}" == V10 && "$(uname -m)" == aarch64 ]] || \
  die "脚本只支持麒麟 V10 aarch64 Pgpool 节点；当前=${PRETTY_NAME:-unknown}/$(uname -m)。"
local_addresses="$(ip -o -4 addr show | awk '{split($4,a,"/");print a[1]}')"
grep -Fxq "${PGPOOL_HOST}" <<<"${local_addresses}" || die "本机不存在 Pgpool 地址 ${PGPOOL_HOST}。"
[[ -f "${PGPOOL_CONF}" && ! -L "${PGPOOL_CONF}" && -f "${POOL_HBA}" && ! -L "${POOL_HBA}" ]] || \
  die 'Pgpool 配置缺失或为符号链接。'
[[ -r "${PGPOOL_CONF}" && -r "${POOL_HBA}" && -w "${POOL_HBA}" && -d /var && -w /var ]] || \
  die 'Pgpool 配置读取权限、pool_hba.conf 写权限或 /var 备份权限不足。'
local_available_kb="$(df -Pk /var | awk 'NR==2{print $4}')"
[[ "${local_available_kb}" =~ ^[0-9]+$ && "${local_available_kb}" -ge 10240 ]] || \
  die "/var 可用空间不足 10 MiB: ${local_available_kb:-unknown} KiB"
managed_block_is_well_formed "${POOL_HBA}" "${HBA_MARKER}" || die 'pool_hba.conf 的全库全用户受管标记不完整。'
systemctl is-active --quiet "${PGPOOL_SERVICE}" || die 'Pgpool 服务未运行。'
[[ -x "${PGPOOL_BIN}" ]] || die "Pgpool 主程序不存在: ${PGPOOL_BIN}"
pgpool_version="$(LD_LIBRARY_PATH="${PGPOOL_RUNTIME_LIB}" "${PGPOOL_BIN}" --version 2>&1)"
grep -Fq '4.7.2' <<<"${pgpool_version}" || die "Pgpool 版本不是 4.7.2: ${pgpool_version}"
[[ "$(config_value backend_clustering_mode "${PGPOOL_CONF}")" == streaming_replication ]] || die 'Pgpool 不是流复制模式。'
[[ "$(config_value backend_hostname0 "${PGPOOL_CONF}")" == "${PRIMARY_HOST}" ]] || die 'backend 0 与输入的 Primary 不一致。'
[[ "$(config_value backend_hostname1 "${PGPOOL_CONF}")" == "${STANDBY_HOST}" ]] || die 'backend 1 与输入的 Standby 不一致。'
[[ "$(config_value backend_port0 "${PGPOOL_CONF}")" == "${POSTGRESQL_PORT}" && \
   "$(config_value backend_port1 "${PGPOOL_CONF}")" == "${POSTGRESQL_PORT}" ]] || die 'Pgpool 后端端口与输入不一致。'
[[ "$(config_value port "${PGPOOL_CONF}")" == "${PGPOOL_PORT}" ]] || die 'Pgpool 对外端口与输入不一致。'
[[ "$(config_value enable_pool_hba "${PGPOOL_CONF}")" == on ]] || die 'enable_pool_hba 未开启。'
[[ "$(config_value allow_clear_text_frontend_auth "${PGPOOL_CONF}")" == off ]] || \
  die 'allow_clear_text_frontend_auth 必须保持 off。'
ss -lnt | grep -Eq "[[:space:]](0\\.0\\.0\\.0|\\*|\\[::\\]):${PGPOOL_PORT}[[:space:]]" || \
  die "Pgpool 未对外监听 ${PGPOOL_PORT}。"

# 本项目生成的 pool_hba 只应包含 all/all + md5/password。遇到人工特例时拒绝猜测。
invalid_pool_hba="$(awk '
  /^[[:space:]]*($|#)/ {next}
  {
    line=$0; sub(/[[:space:]]+#.*/, "", line); sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); n=split(line,f,/[[:space:]]+/)
    if (f[1]=="local") {if (n!=4 || f[2]!="all" || f[3]!="all" || (f[4]!="md5" && f[4]!="password")) print $0; next}
    if (f[1]=="host") {if (n!=5 || f[2]!="all" || f[3]!="all" || (f[5]!="md5" && f[5]!="password")) print $0; next}
    print $0
  }
' "${POOL_HBA}")"
[[ -z "${invalid_pool_hba}" ]] || die "pool_hba.conf 存在脚本不能安全泛化的规则：${invalid_pool_hba}"
active_pool_rules="$(awk '/^[[:space:]]*(local|host)[[:space:]]/{count++} END{print count+0}' "${POOL_HBA}")"
((active_pool_rules > 0)) || die 'pool_hba.conf 没有可保留的客户端来源规则。'
if [[ "$(config_value ssl "${PGPOOL_CONF}")" != on ]]; then
  warn 'Pgpool 当前未启用 TLS；password 前端认证会在客户端到 Pgpool 链路上传输明文口令协议。'
fi

SCRIPT_PHASE='准备临时 SSH 客户端并检查网络'
script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
payload_path="${script_root}/${SSHPASS_PAYLOAD}"
[[ -f "${payload_path}" ]] || die "缺少离线 sshpass 载荷: ${payload_path}"
[[ "$(sha256sum "${payload_path}" | awk '{print $1}')" == "${SSHPASS_SHA256}" ]] || die 'sshpass 载荷 SHA256 不匹配。'
TEMP_ROOT="$(mktemp -d /var/tmp/pg-rw-all-users.XXXXXX)"
chmod 700 "${TEMP_ROOT}"
tar -xmzf "${payload_path}" -C "${TEMP_ROOT}"
SSHPASS_BIN="${TEMP_ROOT}/usr/local/bin/sshpass"
[[ -x "${SSHPASS_BIN}" ]] || die 'sshpass 载荷解压不完整。'
export SSHPASS="${ROOT_SSH_PASSWORD}"
known_hosts="${TEMP_ROOT}/known_hosts"
touch "${known_hosts}"
chmod 600 "${known_hosts}"
SSH_ARGS=(-p "${SSH_PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="${known_hosts}" -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

for backend_host in "${PRIMARY_HOST}" "${STANDBY_HOST}"; do
  route_output="$(ip route get "${backend_host}")"
  grep -Eq "(^|[[:space:]])src[[:space:]]+${PGPOOL_HOST}([[:space:]]|$)" <<<"${route_output}" || \
    die "到 ${backend_host} 的出站源地址不是 ${PGPOOL_HOST}: ${route_output}"
  timeout 5 bash -c "</dev/tcp/${backend_host}/${POSTGRESQL_PORT}" || \
    die "Pgpool 无法连接 ${backend_host}:${POSTGRESQL_PORT}。"
done

SCRIPT_PHASE='只读检查 Primary 和 Standby'
primary_snapshot="$(remote_snapshot "${PRIMARY_HOST}" primary)" || die 'Primary 只读检查失败。'
standby_snapshot="$(remote_snapshot "${STANDBY_HOST}" standby)" || die 'Standby 只读检查失败。'
primary_record="$(grep '^REMOTE_SNAPSHOT=' <<<"${primary_snapshot}" | tail -n 1)"
standby_record="$(grep '^REMOTE_SNAPSHOT=' <<<"${standby_snapshot}" | tail -n 1)"
[[ -n "${primary_record}" && -n "${standby_record}" ]] || die '远端检查结果格式异常。'
IFS='|' read -r primary_label primary_system_id primary_hba_path primary_hba_hash primary_streaming <<<"${primary_record#REMOTE_SNAPSHOT=}"
IFS='|' read -r standby_label standby_system_id standby_hba_path standby_hba_hash standby_streaming <<<"${standby_record#REMOTE_SNAPSHOT=}"
[[ "${primary_label}" == primary && "${standby_label}" == standby && "${primary_system_id}" == "${standby_system_id}" ]] || \
  die 'Primary/Standby 角色或 system identifier 不一致。'

cat <<PLAN

只读检查全部通过。计划如下：
  Pgpool ${PGPOOL_HOST}:${PGPOOL_PORT}
    - 保留 pool_hba.conf 当前 ${active_pool_rules} 条来源规则
    - 把这些规则的认证方法由 md5 改为 password
    - 不删除现有 pool_passwd，但全库全用户规则不再依赖它
  Primary ${PRIMARY_HOST}:${POSTGRESQL_PORT}
    - 在 ${primary_hba_path} 顶部加入 host all all ${PGPOOL_HOST}/32 md5
  Standby ${STANDBY_HOST}:${POSTGRESQL_PORT}
    - 在 ${standby_hba_path} 顶部加入相同规则

不会执行：CREATE/ALTER ROLE、GRANT、数据库重启、Pgpool 重启、pg_basebackup、主从重新同步。
现有角色仍受 LOGIN、数据库 CONNECT、schema/table 权限约束。
PLAN
warn '当前未启用 Pgpool TLS。只有确认物理隔离链路允许使用 password 前端认证时才应继续。'
read -r -p '输入 APPLY 执行；其他输入直接退出且不修改配置: ' confirmation || die '无法读取确认词。'
[[ "${confirmation}" == APPLY ]] || die '用户取消；没有修改任何配置。'

APPLY_STARTED='yes'
RUN_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')-$$"

SCRIPT_PHASE='备份并配置 Primary HBA'
PRIMARY_BACKUP_DIR="/var/backups/pg-readwrite-proxy-lab/all-databases-users-${RUN_TIMESTAMP}-primary"
primary_apply="$(apply_remote_hba "${PRIMARY_HOST}" primary "${primary_hba_hash}")" || die 'Primary HBA 配置失败。'
primary_applied_record="$(grep '^REMOTE_APPLIED=' <<<"${primary_apply}" | tail -n 1)"
[[ -n "${primary_applied_record}" ]] || die 'Primary 应用结果缺少成功记录。'
IFS='|' read -r applied_role reported_primary_backup primary_new_hash <<<"${primary_applied_record#REMOTE_APPLIED=}"
[[ "${applied_role}" == primary && "${reported_primary_backup}" == "${PRIMARY_BACKUP_DIR}" ]] || die 'Primary 应用结果格式异常。'
log "Primary HBA 已 reload，备份=${PRIMARY_BACKUP_DIR}。"

SCRIPT_PHASE='备份并配置 Standby HBA'
STANDBY_BACKUP_DIR="/var/backups/pg-readwrite-proxy-lab/all-databases-users-${RUN_TIMESTAMP}-standby"
standby_apply="$(apply_remote_hba "${STANDBY_HOST}" standby "${standby_hba_hash}")" || die 'Standby HBA 配置失败。'
standby_applied_record="$(grep '^REMOTE_APPLIED=' <<<"${standby_apply}" | tail -n 1)"
[[ -n "${standby_applied_record}" ]] || die 'Standby 应用结果缺少成功记录。'
IFS='|' read -r applied_role reported_standby_backup standby_new_hash <<<"${standby_applied_record#REMOTE_APPLIED=}"
[[ "${applied_role}" == standby && "${reported_standby_backup}" == "${STANDBY_BACKUP_DIR}" ]] || die 'Standby 应用结果格式异常。'
log "Standby HBA 已 reload，备份=${STANDBY_BACKUP_DIR}。"

SCRIPT_PHASE='备份并配置 Pgpool 前端认证'
LOCAL_BACKUP_DIR="/var/backups/pg-readwrite-proxy-lab/all-databases-users-${RUN_TIMESTAMP}-pgpool"
[[ ! -e "${LOCAL_BACKUP_DIR}" ]] || die "本地备份目录已存在: ${LOCAL_BACKUP_DIR}"
mkdir -p "${LOCAL_BACKUP_DIR}"
chmod 700 "${LOCAL_BACKUP_DIR}"
cp -a -- "${POOL_HBA}" "${LOCAL_BACKUP_DIR}/pool_hba.conf.before"
pool_hba_temp="${POOL_HBA}.all-users.$$"
cp -a -- "${POOL_HBA}" "${pool_hba_temp}"
sed -E '/^[[:space:]]*(local|host)[[:space:]]/ s/[[:space:]]+md5([[:space:]]*(#.*)?)$/ password\1/' \
  "${POOL_HBA}" >"${pool_hba_temp}"
chown --reference="${POOL_HBA}" "${pool_hba_temp}"
chmod --reference="${POOL_HBA}" "${pool_hba_temp}"
mv -f -- "${pool_hba_temp}" "${POOL_HBA}"
remaining_md5="$(awk '
  /^[[:space:]]*($|#)/ {next}
  {line=$0; sub(/[[:space:]]+#.*/, "", line); sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); n=split(line,f,/[[:space:]]+/); if ((f[1]=="local" && f[4]=="md5") || (f[1]=="host" && f[5]=="md5")) count++}
  END{print count+0}
' "${POOL_HBA}")"
password_rules="$(awk '
  /^[[:space:]]*($|#)/ {next}
  {line=$0; sub(/[[:space:]]+#.*/, "", line); sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); n=split(line,f,/[[:space:]]+/); if ((f[1]=="local" && f[4]=="password") || (f[1]=="host" && f[5]=="password")) count++}
  END{print count+0}
' "${POOL_HBA}")"
[[ "${remaining_md5}" == 0 && "${password_rules}" == "${active_pool_rules}" ]] || die 'pool_hba.conf 转换后规则数量不一致。'
systemctl reload "${PGPOOL_SERVICE}"
sleep 2
systemctl is-active --quiet "${PGPOOL_SERVICE}" || die 'Pgpool reload 后服务未运行。'
ss -lnt | grep -Eq "[[:space:]](0\\.0\\.0\\.0|\\*|\\[::\\]):${PGPOOL_PORT}[[:space:]]" || die 'Pgpool reload 后监听异常。'
if journalctl -u "${PGPOOL_SERVICE}" --since '-1 minute' --no-pager -o cat | \
    grep -Eiq 'failed to parse|configuration error|invalid authentication method|FATAL:.*pool_hba'; then
  die 'Pgpool 最新日志出现配置或认证规则解析错误。'
fi

SUCCESS='yes'
SCRIPT_PHASE='完成'
log '全库全用户透明认证已启用。'
log "Pgpool 备份=${LOCAL_BACKUP_DIR}"
log "Primary 备份=${PRIMARY_BACKUP_DIR}"
log "Standby 备份=${STANDBY_BACKUP_DIR}"
log '现有可登录角色现在可使用各自原密码，经 Pgpool 访问其本来有权连接的任意数据库。'
log '不具备 LOGIN、CONNECT 或对象权限的角色仍会被 PostgreSQL 正常拒绝。'
log '后续若运行 repair.sh，它会重新生成 pool_hba.conf；届时需重新运行本脚本。'
