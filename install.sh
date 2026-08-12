#!/usr/bin/env bash

# 在 Pgpool-II 服务器上运行的一键安装器。
# 它通过 SSH 配置现有 Primary、初始化 Standby，并在本机安装/配置/验证 Pgpool-II。

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"

log() { printf '[INSTALL] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die '请在 Pgpool-II 服务器上使用 root 或 sudo 运行 ./install.sh。'
for command_name in ssh tar openssl awk sed; do
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少命令: ${command_name}"
done

prompt_default() {
  local variable_name="$1" prompt_text="$2" default_value="$3" value
  read -r -p "${prompt_text} [${default_value}]: " value
  printf -v "${variable_name}" '%s' "${value:-${default_value}}"
}

prompt_required() {
  local variable_name="$1" prompt_text="$2" value=''
  while [[ -z "${value}" ]]; do
    read -r -p "${prompt_text}: " value
  done
  printf -v "${variable_name}" '%s' "${value}"
}

is_ipv4() {
  local ip="$1" octet
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${ip}"
  for octet in "${octets[@]}"; do
    ((10#${octet} <= 255)) || return 1
  done
}

validate_identifier() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "数据库用户名不合法: $1"
}

prompt_required PGPOOL_HOST 'Pgpool-II 服务器内网 IPv4 地址'
prompt_required PRIMARY_HOST '现有 PostgreSQL Primary 内网 IPv4 地址'
prompt_required STANDBY_HOST '新 PostgreSQL Standby 内网 IPv4 地址'
for address in "${PGPOOL_HOST}" "${PRIMARY_HOST}" "${STANDBY_HOST}"; do
  is_ipv4 "${address}" || die "当前一键安装器要求填写 IPv4 地址: ${address}"
done
[[ "${PGPOOL_HOST}" != "${PRIMARY_HOST}" && "${PGPOOL_HOST}" != "${STANDBY_HOST}" && "${PRIMARY_HOST}" != "${STANDBY_HOST}" ]] || \
  die '三台服务器地址必须互不相同。'

prompt_default PRIMARY_PORT 'PostgreSQL 端口' '5432'
[[ "${PRIMARY_PORT}" =~ ^[0-9]+$ ]] && ((PRIMARY_PORT >= 1 && PRIMARY_PORT <= 65535)) || die 'PostgreSQL 端口无效。'
STANDBY_PORT="${PRIMARY_PORT}"
prompt_default PGPOOL_PORT 'Pgpool-II 对外端口' '9999'
[[ "${PGPOOL_PORT}" =~ ^[0-9]+$ ]] && ((PGPOOL_PORT >= 1 && PGPOOL_PORT <= 65535)) || die 'Pgpool-II 端口无效。'
prompt_default SSH_USER 'Primary/Standby 的 SSH 管理账号（需 root 或免密 sudo）' 'root'
prompt_default SSH_PORT 'SSH 端口' '22'
prompt_default SSH_KEY 'SSH 私钥路径；使用 ssh-agent 时输入 -' '-'
if [[ "${SSH_KEY}" != '-' ]]; then
  [[ -r "${SSH_KEY}" ]] || die "SSH 私钥不可读: ${SSH_KEY}"
fi

default_client_cidr="${PGPOOL_HOST%.*}.0/24"
prompt_default ALLOWED_CLIENT_CIDRS '允许连接 Pgpool-II 的客户端 CIDR；多个用逗号分隔' "${default_client_cidr}"
[[ "${ALLOWED_CLIENT_CIDRS}" != *'0.0.0.0/0'* ]] || die '禁止默认向全网开放 Pgpool-II。'

ssh_args=(-p "${SSH_PORT}" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ "${SSH_KEY}" == '-' ]] || ssh_args+=(-i "${SSH_KEY}")

remote_root() {
  local host="$1"
  ssh "${ssh_args[@]}" "${SSH_USER}@${host}" \
    'if [ "$(id -u)" -eq 0 ]; then exec bash -s; else exec sudo -n bash -s; fi'
}

for host in "${PRIMARY_HOST}" "${STANDBY_HOST}"; do
  log "检查 SSH/root 权限：${SSH_USER}@${host}:${SSH_PORT}"
  remote_root "${host}" <<'REMOTE_CHECK'
set -e
test "$(id -u)" -eq 0
source /etc/os-release
case "${VERSION_ID%%.*}" in 8|9) ;; *) echo "仅支持 EL 8/9" >&2; exit 1;; esac
REMOTE_CHECK
done

log '自动探测现有 Primary 的 PostgreSQL 版本、PGDATA、二进制目录和 systemd 服务。'
detect_script="$(cat <<DETECT
set -Eeuo pipefail
psql_bin=\$(command -v psql 2>/dev/null || find /usr/pgsql-* /usr/bin -type f -name psql -print -quit 2>/dev/null || true)
test -x "\${psql_bin}" || { echo '找不到 psql' >&2; exit 1; }
row=\$(runuser -u postgres -- "\${psql_bin}" -XAtq -v ON_ERROR_STOP=1 -p ${PRIMARY_PORT} -d postgres -F '|' -c "select current_setting('server_version_num'),current_setting('data_directory'),pg_is_in_recovery()")
version_num=\${row%%|*}
rest=\${row#*|}
pgdata=\${rest%|*}
recovery=\${row##*|}
test "\${recovery}" = f || { echo '目标不是 Primary' >&2; exit 1; }
pid=\$(head -n 1 "\${pgdata}/postmaster.pid")
postgres_bin=\$(readlink -f "/proc/\${pid}/exe")
bin_dir=\$(dirname "\${postgres_bin}")
service=''
while read -r unit _; do
  test -n "\${unit}" || continue
  main_pid=\$(systemctl show -p MainPID --value "\${unit}" 2>/dev/null || true)
  if test "\${main_pid}" = "\${pid}"; then service=\${unit%.service}; break; fi
done < <(systemctl list-units --type=service --state=running --no-legend 'postgresql*.service')
test -n "\${service}" || { echo '无法识别 PostgreSQL systemd 服务' >&2; exit 1; }
printf '%s|%s|%s|%s\n' "\${version_num}" "\${pgdata}" "\${bin_dir}" "\${service}"
DETECT
)"
primary_facts="$(remote_root "${PRIMARY_HOST}" <<<"${detect_script}")"
IFS='|' read -r primary_version_num PRIMARY_PGDATA PRIMARY_PG_BIN_DIR PRIMARY_SERVICE <<<"${primary_facts}"
PG_MAJOR="$((primary_version_num / 10000))"
[[ "${PG_MAJOR}" =~ ^(14|15|16|17|18)$ ]] || die "现有 Primary 大版本=${PG_MAJOR}，已超出当前受支持范围 14-18。"

STANDBY_PGDATA="/var/lib/pgsql/${PG_MAJOR}/data"
STANDBY_PG_BIN_DIR="/usr/pgsql-${PG_MAJOR}/bin"
STANDBY_SERVICE="postgresql-${PG_MAJOR}"
PGPOOL_MAJOR='4.7'

cat <<SUMMARY

即将执行的拓扑：
  Primary : ${PRIMARY_HOST}:${PRIMARY_PORT}
            PostgreSQL ${PG_MAJOR}, PGDATA=${PRIMARY_PGDATA}, service=${PRIMARY_SERVICE}
  Standby : ${STANDBY_HOST}:${STANDBY_PORT}
            将安装 PostgreSQL ${PG_MAJOR}, PGDATA=${STANDBY_PGDATA}
  Pgpool  : ${PGPOOL_HOST}:${PGPOOL_PORT}
  客户端  : ${ALLOWED_CLIENT_CIDRS}

安装器会重启现有 Primary 一次，以应用 wal_level/listen_addresses 等启动参数。
Standby 将由 pg_basebackup 初始化；Pgpool 基线不会自动提升 Standby。
SUMMARY
read -r -p '确认已进入维护窗口。输入 APPLY 继续: ' confirmation
[[ "${confirmation}" == 'APPLY' ]] || die '用户取消，尚未修改任何服务器。'

mkdir -p "${CONFIG_DIR}"
umask 077

write_env() {
  local file="$1" name="$2" value="$3"
  printf '%s=%q\n' "${name}" "${value}" >>"${file}"
}

cluster_file="${CONFIG_DIR}/cluster.env"
: >"${cluster_file}"
declare -A cluster_values=(
  [PG_MAJOR]="${PG_MAJOR}" [PGPOOL_MAJOR]="${PGPOOL_MAJOR}" [PG_OS_USER]='postgres'
  [PRIMARY_HOST]="${PRIMARY_HOST}" [PRIMARY_PORT]="${PRIMARY_PORT}" [PRIMARY_PGDATA]="${PRIMARY_PGDATA}"
  [PRIMARY_PG_BIN_DIR]="${PRIMARY_PG_BIN_DIR}" [PRIMARY_SERVICE]="${PRIMARY_SERVICE}" [PRIMARY_LISTEN_ADDRESSES]='*'
  [STANDBY_HOST]="${STANDBY_HOST}" [STANDBY_PORT]="${STANDBY_PORT}" [STANDBY_PGDATA]="${STANDBY_PGDATA}"
  [STANDBY_PG_BIN_DIR]="${STANDBY_PG_BIN_DIR}" [STANDBY_SERVICE]="${STANDBY_SERVICE}" [STANDBY_LISTEN_ADDRESSES]='*'
  [STANDBY_APPLICATION_NAME]='rw_standby' [REPLICATION_SLOT_NAME]='rw_standby_slot'
  [PGPOOL_HOST]="${PGPOOL_HOST}" [PGPOOL_PORT]="${PGPOOL_PORT}" [PCP_PORT]='9898' [PGPOOL_SERVICE]='pgpool'
  [PGPOOL_CONFIG_DIR]='/etc/pgpool-II' [STANDBY_ADDRESS_CIDR]="${STANDBY_HOST}/32"
  [PGPOOL_ADDRESS_CIDR]="${PGPOOL_HOST}/32" [ALLOWED_CLIENT_CIDRS]="${ALLOWED_CLIENT_CIDRS}" [MANAGE_FIREWALL]='yes'
  [REPLICATION_USER]='rw_replicator' [MONITOR_USER]='pgpool_monitor' [LAB_USER]='rw_lab_test'
  [LAB_DATABASE]='rw_proxy_lab' [PCP_USER]='pgpool_admin'
  [MAX_WAL_SENDERS]='10' [MAX_REPLICATION_SLOTS]='10' [WAL_KEEP_SIZE]='1024MB' [MAX_SLOT_WAL_KEEP_SIZE]='10GB'
  [PRIMARY_READ_WEIGHT]='0' [STANDBY_READ_WEIGHT]='1' [DISABLE_LOAD_BALANCE_ON_WRITE]='transaction'
  [READ_LAG_THRESHOLD_SECONDS]='5' [SR_CHECK_PERIOD]='5' [HEALTH_CHECK_PERIOD]='5' [HEALTH_CHECK_TIMEOUT]='5'
  [HEALTH_CHECK_MAX_RETRIES]='3' [HEALTH_CHECK_RETRY_DELAY]='1' [CONNECT_TIMEOUT_MS]='5000'
  [NUM_INIT_CHILDREN]='8' [MAX_POOL]='2' [CONNECTION_LIFE_TIME]='600' [LOG_PER_NODE_STATEMENT]='on'
  [APPLY_PRIMARY_RESTART]='yes' [ALLOW_STANDBY_REINITIALIZE]='no'
)
cluster_order=(
  PG_MAJOR PGPOOL_MAJOR PG_OS_USER PRIMARY_HOST PRIMARY_PORT PRIMARY_PGDATA PRIMARY_PG_BIN_DIR PRIMARY_SERVICE PRIMARY_LISTEN_ADDRESSES
  STANDBY_HOST STANDBY_PORT STANDBY_PGDATA STANDBY_PG_BIN_DIR STANDBY_SERVICE STANDBY_LISTEN_ADDRESSES
  STANDBY_APPLICATION_NAME REPLICATION_SLOT_NAME PGPOOL_HOST PGPOOL_PORT PCP_PORT PGPOOL_SERVICE PGPOOL_CONFIG_DIR
  STANDBY_ADDRESS_CIDR PGPOOL_ADDRESS_CIDR ALLOWED_CLIENT_CIDRS MANAGE_FIREWALL REPLICATION_USER MONITOR_USER LAB_USER LAB_DATABASE PCP_USER
  MAX_WAL_SENDERS MAX_REPLICATION_SLOTS WAL_KEEP_SIZE MAX_SLOT_WAL_KEEP_SIZE PRIMARY_READ_WEIGHT STANDBY_READ_WEIGHT
  DISABLE_LOAD_BALANCE_ON_WRITE READ_LAG_THRESHOLD_SECONDS SR_CHECK_PERIOD HEALTH_CHECK_PERIOD HEALTH_CHECK_TIMEOUT
  HEALTH_CHECK_MAX_RETRIES HEALTH_CHECK_RETRY_DELAY CONNECT_TIMEOUT_MS NUM_INIT_CHILDREN MAX_POOL CONNECTION_LIFE_TIME
  LOG_PER_NODE_STATEMENT APPLY_PRIMARY_RESTART ALLOW_STANDBY_REINITIALIZE
)
for name in "${cluster_order[@]}"; do write_env "${cluster_file}" "${name}" "${cluster_values[${name}]}"; done
chmod 600 "${cluster_file}"

random_secret() { openssl rand -hex 32; }
REPLICATION_PASSWORD="$(random_secret)"
MONITOR_PASSWORD="$(random_secret)"
LAB_PASSWORD="$(random_secret)"
PCP_PASSWORD="$(random_secret)"
PGPOOL_AES_KEY="$(random_secret)"
secrets_file="${CONFIG_DIR}/secrets.env"
: >"${secrets_file}"
write_env "${secrets_file}" REPLICATION_PASSWORD "${REPLICATION_PASSWORD}"
write_env "${secrets_file}" MONITOR_PASSWORD "${MONITOR_PASSWORD}"
write_env "${secrets_file}" LAB_PASSWORD "${LAB_PASSWORD}"
write_env "${secrets_file}" PCP_PASSWORD "${PCP_PASSWORD}"
write_env "${secrets_file}" PGPOOL_AES_KEY "${PGPOOL_AES_KEY}"
chmod 600 "${secrets_file}"

pool_users_file="${CONFIG_DIR}/pool-users.txt"
: >"${pool_users_file}"
chmod 600 "${pool_users_file}"
read -r -p '需要立即通过 Pgpool 使用的现有业务数据库用户名（多个用逗号分隔；仅架构验证可留空）: ' business_users_input
first_business_user=''
first_business_password=''
first_business_database=''
if [[ -n "${business_users_input}" ]]; then
  IFS=',' read -r -a business_users <<<"${business_users_input}"
  for raw_user in "${business_users[@]}"; do
    username="${raw_user#"${raw_user%%[![:space:]]*}"}"
    username="${username%"${username##*[![:space:]]}"}"
    validate_identifier "${username}"
    read -r -s -p "数据库用户 ${username} 的现有密码: " user_password
    printf '\n'
    [[ -n "${user_password}" && "${user_password}" != *$'\n'* ]] || die "用户 ${username} 密码为空或含换行。"
    printf '%s:%s\n' "${username}" "${user_password}" >>"${pool_users_file}"
    if [[ -z "${first_business_user}" ]]; then
      first_business_user="${username}"
      first_business_password="${user_password}"
      prompt_default first_business_database "用于验证 ${username} 的数据库名" 'postgres'
    fi
  done
else
  warn '未录入业务账号：安装后测试账号可用，但业务切换前必须补录账号并重新生成 pool_passwd。'
fi

stage_id="$(date '+%Y%m%d%H%M%S')-$$"
remote_dirs=()
cleanup_remote_secrets() {
  local item host remote_dir
  for item in "${remote_dirs[@]:-}"; do
    host="${item%%|*}"
    remote_dir="${item#*|}"
    [[ "${remote_dir}" == /var/tmp/pg-rw-proxy-installer-* ]] || continue
    remote_root "${host}" <<<"rm -f -- '${remote_dir}/config/secrets.env' '${remote_dir}/config/pool-users.txt'" >/dev/null 2>&1 || true
  done
}
trap cleanup_remote_secrets EXIT

copy_to_remote() {
  local host="$1" role="$2" remote_dir="/var/tmp/pg-rw-proxy-installer-${stage_id}-${role}"
  remote_dirs+=("${host}|${remote_dir}")
  tar --exclude='./.git' --exclude='./config/pool-users.txt' -C "${ROOT_DIR}" -czf - . | \
    ssh "${ssh_args[@]}" "${SSH_USER}@${host}" \
      "if [ \"\$(id -u)\" -eq 0 ]; then mkdir -p '${remote_dir}' && tar -xzf - -C '${remote_dir}'; else sudo -n mkdir -p '${remote_dir}' && sudo -n tar -xzf - -C '${remote_dir}'; fi"
  printf '%s' "${remote_dir}"
}

run_remote_stage() {
  local host="$1" remote_dir="$2" commands="$3"
  remote_root "${host}" <<<"set -Eeuo pipefail; cd '${remote_dir}'; ${commands}"
}

log '阶段 1/4：配置并重启现有 Primary。'
primary_stage="$(copy_to_remote "${PRIMARY_HOST}" primary)"
run_remote_stage "${PRIMARY_HOST}" "${primary_stage}" './scripts/10-configure-primary.sh'

log '阶段 2/4：安装 PostgreSQL 并通过 pg_basebackup 初始化 Standby。'
standby_stage="$(copy_to_remote "${STANDBY_HOST}" standby)"
run_remote_stage "${STANDBY_HOST}" "${standby_stage}" './scripts/20-install-postgresql-standby.sh && ./scripts/21-bootstrap-standby.sh'

log '阶段 3/4：在本机安装并配置 Pgpool-II。'
"${ROOT_DIR}/scripts/30-install-pgpool.sh"

if [[ -n "${first_business_user}" ]]; then
  psql_bin="$(command -v psql 2>/dev/null || find /usr/pgsql-"${PG_MAJOR}"/bin -name psql -type f -print -quit 2>/dev/null || true)"
  PGPASSWORD="${first_business_password}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
    -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${first_business_user}" -d "${first_business_database}" -c 'select 1' >/dev/null || \
    die "业务账号 ${first_business_user} 无法从 Pgpool 主机直连 Primary；请核对账号、密码和数据库名。"
fi
"${ROOT_DIR}/scripts/31-configure-pgpool.sh"

log '阶段 4/4：执行流复制和 SQL 路由验收。'
"${ROOT_DIR}/scripts/40-verify-cluster.sh"

if [[ -n "${first_business_user}" ]]; then
  PGPASSWORD="${first_business_password}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${first_business_user}" -d "${first_business_database}" -c 'select 1' >/dev/null || \
    die "业务账号 ${first_business_user} 通过 Pgpool 的最终连接验证失败。"
  business_status="业务账号 ${first_business_user} 已验证可通过 Pgpool 连接数据库 ${first_business_database}。"
else
  business_status='当前只完成隔离测试账号验收；业务账号需补录后才能切换。'
fi

cleanup_remote_secrets
trap - EXIT

cat <<RESULT

安装与验收完成。

统一数据库入口：${PGPOOL_HOST}:${PGPOOL_PORT}
连接示例：postgresql://<database-user>@${PGPOOL_HOST}:${PGPOOL_PORT}/<database-name>
${business_status}

敏感配置保存在本机 ${CONFIG_DIR}，权限为 600；请纳入受控密钥备份，不要提交 Git。
Primary/Standby 上的临时安装副本只保留了非敏感文件，secrets.env 已清理。
RESULT
