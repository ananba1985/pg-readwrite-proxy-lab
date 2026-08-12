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
[[ "${EUID}" -eq 0 ]] || die '请在 Pgpool-II 服务器上使用 root 运行 bash install.sh。'
for command_name in ssh tar openssl awk sed sha256sum mktemp; do
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少系统基础命令: ${command_name}"
done
chmod +x "${ROOT_DIR}/install.sh" "${ROOT_DIR}/scripts/"*.sh "${ROOT_DIR}/scripts/lib/"*.sh

expected_payloads=(
  pgpool-II-4.7.2-pg12.0-aarch64-centos7.tar.gz
  postgresql-client-12.0-aarch64-centos7.tar.gz
  sshpass-1.10-aarch64-centos7.tar.gz
)
for payload in "${expected_payloads[@]}"; do
  [[ -f "${PAYLOAD_DIR}/${payload}" ]] || die "离线包不完整，缺少 ${payload}"
done
(cd "${ROOT_DIR}/packages" && sha256sum -c MANIFEST.sha256) || die '离线载荷完整性校验失败。'

prompt_default() {
  local variable_name="$1" prompt_text="$2" default_value="$3" value
  read -r -p "${prompt_text} [${default_value}]: " value
  printf -v "${variable_name}" '%s' "${value:-${default_value}}"
}

prompt_secret() {
  local variable_name="$1" prompt_text="$2" value=''
  while [[ -z "${value}" ]]; do
    read -r -s -p "${prompt_text}: " value
    printf '\n'
  done
  [[ "${value}" != *$'\n'* && "${value}" != *:* ]] || die '密码不能包含换行或冒号。'
  printf -v "${variable_name}" '%s' "${value}"
}

is_ipv4() {
  local ip="$1" octet old_ifs="${IFS}"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${ip}"
  IFS="${old_ifs}"
  for octet in "${octets[@]}"; do ((10#${octet} <= 255)) || return 1; done
}

validate_identifier() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "PostgreSQL 标识符不合法: $1"
}

validate_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) || die "端口无效: $1"
}

printf '\nPostgreSQL Streaming Replication + Pgpool-II 离线安装\n'
printf '目标平台：三台 CentOS 7 aarch64；数据库节点必须已安装受支持的 NebulaCM PostgreSQL 12.0。\n\n'
prompt_default PGPOOL_HOST 'Pgpool-II 服务器内网 IPv4 地址' '192.168.80.130'
prompt_default PRIMARY_HOST '现有 PostgreSQL Primary 内网 IPv4 地址' '192.168.80.110'
prompt_default STANDBY_HOST 'PostgreSQL Standby 目标机内网 IPv4 地址' '192.168.80.120'
for address in "${PGPOOL_HOST}" "${PRIMARY_HOST}" "${STANDBY_HOST}"; do is_ipv4 "${address}" || die "IPv4 地址无效: ${address}"; done
[[ "${PGPOOL_HOST}" != "${PRIMARY_HOST}" && "${PGPOOL_HOST}" != "${STANDBY_HOST}" && "${PRIMARY_HOST}" != "${STANDBY_HOST}" ]] || die '三台服务器地址必须不同。'

prompt_default PRIMARY_PORT 'PostgreSQL 端口' '5432'
STANDBY_PORT="${PRIMARY_PORT}"
prompt_default PGPOOL_PORT 'Pgpool-II 对外服务端口' '9999'
prompt_default SSH_PORT 'Pgpool 服务器访问两个数据库节点的 root SSH 端口' '22'
validate_port "${PRIMARY_PORT}"; validate_port "${PGPOOL_PORT}"; validate_port "${SSH_PORT}"
prompt_default ALLOWED_CLIENT_CIDRS '允许访问 Pgpool 的客户端 IPv4 CIDR（逗号分隔）' "${PGPOOL_HOST%.*}.0/24"
[[ "${ALLOWED_CLIENT_CIDRS}" != *'0.0.0.0/0'* && "${ALLOWED_CLIENT_CIDRS}" =~ /[0-9]{1,2} ]] || die '客户端 CIDR 无效或过宽。'
prompt_default BUSINESS_USER '现有业务数据库用户名（脚本不会创建或改密）' 'rw_lab_test'
prompt_default BUSINESS_DATABASE '现有业务数据库名' 'rw_proxy_lab'
validate_identifier "${BUSINESS_USER}"; validate_identifier "${BUSINESS_DATABASE}"
prompt_secret ROOT_SSH_PASSWORD 'Primary 与 Standby 的 root SSH 公共密码'
prompt_secret BUSINESS_PASSWORD "现有数据库用户 ${BUSINESS_USER} 的密码"

cat <<SUMMARY

即将执行：
  Primary : ${PRIMARY_HOST}:${PRIMARY_PORT}（备份配置、创建复制/监控账号、收紧 HBA、pg_ctl 重启）
  Standby : ${STANDBY_HOST}:${STANDBY_PORT}（旧 PGDATA 移到备份目录、pg_basebackup 重建）
  Pgpool  : ${PGPOOL_HOST}:${PGPOOL_PORT}（离线安装 Pgpool-II 4.7.2，PCP 仅本机）
  业务库  : ${BUSINESS_USER}@${BUSINESS_DATABASE}（仅验证现有凭据）
  客户端  : ${ALLOWED_CLIENT_CIDRS}

基线不执行自动提升，也没有 failover/follow-primary 提升命令。
SUMMARY
read -r -p '确认业务已停、Primary 可重启、Standby 旧实例可移动备份。输入 APPLY 继续: ' confirmation
[[ "${confirmation}" == 'APPLY' ]] || die '用户取消；服务器尚未被修改。'

mkdir -p "${CONFIG_DIR}" "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
umask 077
write_env() { printf '%s=%q\n' "$2" "$3" >>"$1"; }

cluster_file="${CONFIG_DIR}/cluster.env"
: >"${cluster_file}"
declare -A values=(
  [PG_MAJOR]='12' [PG_VERSION_FULL]='12.0' [DB_DISTRIBUTION]='NebulaCM'
  [DBN_VERSION_MARKER]='NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz'
  [DB_POSTGRES_SHA256]='aecef1bcf6557271a4ffaf9b55eb53df81c883984e1489916c85e88677477bcf'
  [DB_PG_BASEBACKUP_SHA256]='c235544bad0e0dc61b9c4fbc6becc7181970b9179b2aa071ff8a1821899815bb'
  [DB_PG_CONFIG_SHA256]='90321c1cb01d583ffa55523fd54490f93b2cb17fbcbe5fd99319ef0812f224df'
  [DB_TOOLS_SHA256]='1cfa544a74dc88f1bdc88db52fac5566b73eec4a0c3b15e33e60ec86a2cffa0f'
  [PG_OS_USER]='postgres' [PGPOOL_MAJOR]='4.7' [PGPOOL_VERSION]='4.7.2'
  [PGPOOL_INSTALL_PREFIX]='/opt/pgpool-II-4.7.2' [PG_CLIENT_PREFIX]='/opt/pgpool-client-12.0'
  [OFFLINE_PACKAGE_DIR]='packages/payload'
  [PGPOOL_PAYLOAD_FILE]='pgpool-II-4.7.2-pg12.0-aarch64-centos7.tar.gz' [PGPOOL_PAYLOAD_SHA256]='8bcd29149d64d560bf86a1047dd029587a6f14bd55283cc606f5678d06cf6e23'
  [PG_CLIENT_PAYLOAD_FILE]='postgresql-client-12.0-aarch64-centos7.tar.gz' [PG_CLIENT_PAYLOAD_SHA256]='d6247f81998669fd66115aaa317a4d327969ed4e47bcb29199b62a05a22c10c4'
  [SSHPASS_PAYLOAD_FILE]='sshpass-1.10-aarch64-centos7.tar.gz' [SSHPASS_PAYLOAD_SHA256]='a49f0d4998710638450ee5c4d5e1e4345ca4c09d4484a6f6dceb42bd7a52af72'
  [PRIMARY_HOST]="${PRIMARY_HOST}" [PRIMARY_PORT]="${PRIMARY_PORT}" [PRIMARY_PGDATA]='/pgsql/12/data'
  [PRIMARY_PG_BIN_DIR]='/opt/pgsql12/bin' [PRIMARY_ADMIN_TOOL]='/opt/pgsql12/bin/tools' [PRIMARY_LISTEN_ADDRESSES]="127.0.0.1,${PRIMARY_HOST}"
  [STANDBY_HOST]="${STANDBY_HOST}" [STANDBY_PORT]="${STANDBY_PORT}" [STANDBY_PGDATA]='/pgsql/12/data'
  [STANDBY_PG_BIN_DIR]='/opt/pgsql12/bin' [STANDBY_ADMIN_TOOL]='/opt/pgsql12/bin/tools' [STANDBY_LISTEN_ADDRESSES]="127.0.0.1,${STANDBY_HOST}"
  [STANDBY_APPLICATION_NAME]='rw_standby' [REPLICATION_SLOT_NAME]='rw_standby_slot'
  [PGPOOL_HOST]="${PGPOOL_HOST}" [PGPOOL_PORT]="${PGPOOL_PORT}" [PCP_PORT]='9898' [PGPOOL_SERVICE]='pgpool' [PGPOOL_CONFIG_DIR]='/etc/pgpool-II'
  [STANDBY_ADDRESS_CIDR]="${STANDBY_HOST}/32" [PGPOOL_ADDRESS_CIDR]="${PGPOOL_HOST}/32"
  [ALLOWED_CLIENT_CIDRS]="${ALLOWED_CLIENT_CIDRS}" [MANAGE_FIREWALL]='no'
  [REPLICATION_USER]='rw_replicator' [MONITOR_USER]='pgpool_monitor'
  [BUSINESS_USER]="${BUSINESS_USER}" [BUSINESS_DATABASE]="${BUSINESS_DATABASE}" [PCP_USER]='pgpool_admin'
  [MAX_WAL_SENDERS]='10' [MAX_REPLICATION_SLOTS]='10' [WAL_KEEP_SEGMENTS]='1000'
  [PRIMARY_READ_WEIGHT]='0' [STANDBY_READ_WEIGHT]='1' [DISABLE_LOAD_BALANCE_ON_WRITE]='transaction'
  [READ_LAG_THRESHOLD_SECONDS]='5' [SR_CHECK_PERIOD]='5' [HEALTH_CHECK_PERIOD]='5' [HEALTH_CHECK_TIMEOUT]='5'
  [HEALTH_CHECK_MAX_RETRIES]='3' [HEALTH_CHECK_RETRY_DELAY]='1' [CONNECT_TIMEOUT_MS]='5000'
  [NUM_INIT_CHILDREN]='8' [MAX_POOL]='2' [CONNECTION_LIFE_TIME]='600' [LOG_PER_NODE_STATEMENT]='on'
  [APPLY_PRIMARY_RESTART]='yes' [ALLOW_STANDBY_REINITIALIZE]='yes'
)
order=(PG_MAJOR PG_VERSION_FULL DB_DISTRIBUTION DBN_VERSION_MARKER DB_POSTGRES_SHA256 DB_PG_BASEBACKUP_SHA256 DB_PG_CONFIG_SHA256 DB_TOOLS_SHA256 PG_OS_USER PGPOOL_MAJOR PGPOOL_VERSION PGPOOL_INSTALL_PREFIX PG_CLIENT_PREFIX OFFLINE_PACKAGE_DIR PGPOOL_PAYLOAD_FILE PGPOOL_PAYLOAD_SHA256 PG_CLIENT_PAYLOAD_FILE PG_CLIENT_PAYLOAD_SHA256 SSHPASS_PAYLOAD_FILE SSHPASS_PAYLOAD_SHA256 PRIMARY_HOST PRIMARY_PORT PRIMARY_PGDATA PRIMARY_PG_BIN_DIR PRIMARY_ADMIN_TOOL PRIMARY_LISTEN_ADDRESSES STANDBY_HOST STANDBY_PORT STANDBY_PGDATA STANDBY_PG_BIN_DIR STANDBY_ADMIN_TOOL STANDBY_LISTEN_ADDRESSES STANDBY_APPLICATION_NAME REPLICATION_SLOT_NAME PGPOOL_HOST PGPOOL_PORT PCP_PORT PGPOOL_SERVICE PGPOOL_CONFIG_DIR STANDBY_ADDRESS_CIDR PGPOOL_ADDRESS_CIDR ALLOWED_CLIENT_CIDRS MANAGE_FIREWALL REPLICATION_USER MONITOR_USER BUSINESS_USER BUSINESS_DATABASE PCP_USER MAX_WAL_SENDERS MAX_REPLICATION_SLOTS WAL_KEEP_SEGMENTS PRIMARY_READ_WEIGHT STANDBY_READ_WEIGHT DISABLE_LOAD_BALANCE_ON_WRITE READ_LAG_THRESHOLD_SECONDS SR_CHECK_PERIOD HEALTH_CHECK_PERIOD HEALTH_CHECK_TIMEOUT HEALTH_CHECK_MAX_RETRIES HEALTH_CHECK_RETRY_DELAY CONNECT_TIMEOUT_MS NUM_INIT_CHILDREN MAX_POOL CONNECTION_LIFE_TIME LOG_PER_NODE_STATEMENT APPLY_PRIMARY_RESTART ALLOW_STANDBY_REINITIALIZE)
for name in "${order[@]}"; do write_env "${cluster_file}" "${name}" "${values[${name}]}"; done
chmod 600 "${cluster_file}"

random_secret() { openssl rand -hex 32; }
secrets_file="${CONFIG_DIR}/secrets.env"
: >"${secrets_file}"
write_env "${secrets_file}" REPLICATION_PASSWORD "$(random_secret)"
write_env "${secrets_file}" MONITOR_PASSWORD "$(random_secret)"
write_env "${secrets_file}" BUSINESS_PASSWORD "${BUSINESS_PASSWORD}"
write_env "${secrets_file}" PCP_PASSWORD "$(random_secret)"
write_env "${secrets_file}" PGPOOL_AES_KEY "$(random_secret)"
chmod 600 "${secrets_file}"
: >"${CONFIG_DIR}/pool-users.txt"
chmod 600 "${CONFIG_DIR}/pool-users.txt"

# 在本项目私有临时目录使用 sshpass，不写入 /usr/local。
sshpass_root="$(mktemp -d /var/tmp/pg-rw-sshpass.XXXXXX)"
tar -xzf "${PAYLOAD_DIR}/sshpass-1.10-aarch64-centos7.tar.gz" -C "${sshpass_root}"
SSHPASS_BIN="${sshpass_root}/usr/local/bin/sshpass"
[[ -x "${SSHPASS_BIN}" ]] || die 'sshpass 离线载荷解压失败。'
export SSHPASS="${ROOT_SSH_PASSWORD}"
known_hosts="${STATE_DIR}/known_hosts"
touch "${known_hosts}"; chmod 600 "${known_hosts}"
ssh_args=(-p "${SSH_PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="${known_hosts}" -o ConnectTimeout=10 -o ServerAliveInterval=15)

remote_root() { "${SSHPASS_BIN}" -e ssh "${ssh_args[@]}" root@"$1" bash -s; }
remote_command() { local host="$1" command_text="$2"; printf '%s\n' "${command_text}" | remote_root "${host}"; }

stage_id="$(date '+%Y%m%d%H%M%S')-$$"
primary_stage="/var/tmp/pg-rw-proxy-installer-${stage_id}-primary"
standby_stage="/var/tmp/pg-rw-proxy-installer-${stage_id}-standby"
cleanup() {
  local host remote_dir
  for pair in "${PRIMARY_HOST}|${primary_stage}" "${STANDBY_HOST}|${standby_stage}"; do
    host="${pair%%|*}"; remote_dir="${pair#*|}"
    [[ "${remote_dir}" == /var/tmp/pg-rw-proxy-installer-* ]] || continue
    printf "case '%s' in /var/tmp/pg-rw-proxy-installer-*) rm -rf -- '%s';; esac\n" "${remote_dir}" "${remote_dir}" | remote_root "${host}" >/dev/null 2>&1 || true
  done
  [[ "${sshpass_root:-}" == /var/tmp/pg-rw-sshpass.* ]] && rm -rf -- "${sshpass_root}" || true
  unset SSHPASS ROOT_SSH_PASSWORD BUSINESS_PASSWORD
}
trap cleanup EXIT INT TERM

for host in "${PRIMARY_HOST}" "${STANDBY_HOST}"; do
  log "校验 root SSH 和目标平台：${host}"
  remote_root "${host}" <<'REMOTE_CHECK'
set -e
test "$(id -u)" -eq 0
test "$(uname -m)" = aarch64
grep -q 'release 7\.' /etc/centos-release
REMOTE_CHECK
done

copy_stage() {
  local host="$1" remote_dir="$2"
  tar --exclude='./.git' --exclude='./vm' --exclude='./packages/sources' --exclude='./packages/payload' --exclude='./packages/dist' \
    --exclude='./NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz' \
    --exclude='./PG_Safe_tool.tar.gz' --exclude='./gen_license-arm64' --exclude='./artifacts' \
    -C "${ROOT_DIR}" -czf - . | \
    "${SSHPASS_BIN}" -e ssh "${ssh_args[@]}" root@"${host}" \
      "mkdir -p '${remote_dir}' && tar -xzf - -C '${remote_dir}' && chmod +x '${remote_dir}'/scripts/*.sh '${remote_dir}'/scripts/lib/*.sh"
}
copy_stage "${PRIMARY_HOST}" "${primary_stage}"
copy_stage "${STANDBY_HOST}" "${standby_stage}"

log '1/5 执行三节点只读预检。'
remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ./scripts/00-preflight.sh primary"
remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ./scripts/00-preflight.sh standby"
"${ROOT_DIR}/scripts/00-preflight.sh" pgpool

log '2/5 备份并配置 Primary。'
remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ./scripts/10-configure-primary.sh"
log '3/5 校验既有 NebulaCM 运行时并初始化 Standby。'
remote_command "${STANDBY_HOST}" "cd '${standby_stage}'; ./scripts/20-install-postgresql-standby.sh; ./scripts/21-bootstrap-standby.sh"
log '4/5 离线安装并配置 Pgpool-II。'
"${ROOT_DIR}/scripts/30-install-pgpool.sh"
"${ROOT_DIR}/scripts/31-configure-pgpool.sh"
log '5/5 验证复制、SQL 路由和远端客户端入口。'
"${ROOT_DIR}/scripts/40-verify-cluster.sh"
remote_command "${PRIMARY_HOST}" "cd '${primary_stage}'; ./scripts/42-verify-external-entry.sh"

trap - EXIT INT TERM
cleanup
printf '\n安装与验收完成。统一业务入口：%s:%s，数据库：%s，用户：%s\n' \
  "${PGPOOL_HOST}" "${PGPOOL_PORT}" "${BUSINESS_DATABASE}" "${BUSINESS_USER}"
printf '运行参数与凭据保存在 %s（权限 600）；请及时纳入受控密钥系统。\n' "${CONFIG_DIR}"
