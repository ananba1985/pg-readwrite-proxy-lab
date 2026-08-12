#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
require_command systemctl
require_command sed

pg_enc_bin="$(find_pgpool_binary pg_enc)"
pg_md5_bin="$(find_pgpool_binary pg_md5)"
psql_bin="$(command -v psql 2>/dev/null || find /usr/pgsql-"${PG_MAJOR}"/bin -name psql -type f -print -quit 2>/dev/null || true)"
[[ -x "${psql_bin}" ]] || die '找不到 psql；请先执行 30-install-pgpool.sh。'

# 先用监控账号证明 Pgpool 主机能访问两个后端，且角色正确。
export PGPASSWORD="${MONITOR_PASSWORD}"
primary_role="$(${psql_bin} -XAtq -v ON_ERROR_STOP=1 -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${MONITOR_USER}" -d postgres -c 'select pg_is_in_recovery()')"
standby_role="$(${psql_bin} -XAtq -v ON_ERROR_STOP=1 -h "${STANDBY_HOST}" -p "${STANDBY_PORT}" -U "${MONITOR_USER}" -d postgres -c 'select pg_is_in_recovery()')"
unset PGPASSWORD
[[ "${primary_role}" == 'f' ]] || die 'backend 0 不是 Primary。'
[[ "${standby_role}" == 't' ]] || die 'backend 1 不是 Standby。'

install -d -m 750 "${PGPOOL_CONFIG_DIR}"
timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_dir="/var/backups/pg-rw-proxy/pgpool-${timestamp}"
mkdir -p -- "${backup_dir}"
chmod 700 "${backup_dir}"
for existing in pgpool.conf pool_hba.conf pool_passwd pcp.conf .pgpoolkey; do
  backup_file "${PGPOOL_CONFIG_DIR}/${existing}" "${backup_dir}"
done

temp_conf="$(mktemp)"
temp_hba="$(mktemp)"
temp_hba_rules="$(mktemp)"
temp_users="$(mktemp)"
cleanup() {
  rm -f -- "${temp_conf}" "${temp_hba}" "${temp_hba_rules}" "${temp_users}"
}
trap cleanup EXIT
umask 077

render_template "${PROJECT_ROOT}/templates/pgpool.conf.tpl" "${temp_conf}" \
  PGPOOL_PORT "${PGPOOL_PORT}" PCP_PORT "${PCP_PORT}" PGPOOL_CONFIG_DIR "${PGPOOL_CONFIG_DIR}" \
  NUM_INIT_CHILDREN "${NUM_INIT_CHILDREN}" MAX_POOL "${MAX_POOL}" CONNECTION_LIFE_TIME "${CONNECTION_LIFE_TIME}" \
  PRIMARY_HOST "${PRIMARY_HOST}" PRIMARY_PORT "${PRIMARY_PORT}" PRIMARY_READ_WEIGHT "${PRIMARY_READ_WEIGHT}" \
  STANDBY_HOST "${STANDBY_HOST}" STANDBY_PORT "${STANDBY_PORT}" STANDBY_READ_WEIGHT "${STANDBY_READ_WEIGHT}" \
  STANDBY_APPLICATION_NAME "${STANDBY_APPLICATION_NAME}" \
  DISABLE_LOAD_BALANCE_ON_WRITE "${DISABLE_LOAD_BALANCE_ON_WRITE}" \
  READ_LAG_THRESHOLD_SECONDS "${READ_LAG_THRESHOLD_SECONDS}" MONITOR_USER "${MONITOR_USER}" \
  SR_CHECK_PERIOD "${SR_CHECK_PERIOD}" HEALTH_CHECK_PERIOD "${HEALTH_CHECK_PERIOD}" \
  HEALTH_CHECK_TIMEOUT "${HEALTH_CHECK_TIMEOUT}" HEALTH_CHECK_MAX_RETRIES "${HEALTH_CHECK_MAX_RETRIES}" \
  HEALTH_CHECK_RETRY_DELAY "${HEALTH_CHECK_RETRY_DELAY}" CONNECT_TIMEOUT_MS "${CONNECT_TIMEOUT_MS}" \
  LOG_PER_NODE_STATEMENT "${LOG_PER_NODE_STATEMENT}"

IFS=',' read -r -a client_cidrs <<<"${ALLOWED_CLIENT_CIDRS}"
for cidr in "${client_cidrs[@]}"; do
  cidr="$(trim "${cidr}")"
  printf 'host    all       all   %-22s scram-sha-256\n' "${cidr}" >>"${temp_hba_rules}"
done
awk -v rules="${temp_hba_rules}" '
  $0 == "{{CLIENT_HBA_RULES}}" {
    while ((getline line < rules) > 0) print line
    close(rules)
    next
  }
  { print }
' "${PROJECT_ROOT}/templates/pool_hba.conf.tpl" >"${temp_hba}"

install -m 640 "${temp_conf}" "${PGPOOL_CONFIG_DIR}/pgpool.conf"
install -m 640 "${temp_hba}" "${PGPOOL_CONFIG_DIR}/pool_hba.conf"

# 生成 AES pool_passwd。每个通过 Pgpool 登录的业务账号都必须在 pool-users.txt 中提供原密码。
declare -A seen_users=()
add_pool_user() {
  local username="$1"
  local password="$2"
  validate_identifier "${username}" 'pool user'
  [[ -n "${password}" && "${password}" != *CHANGE_ME* && "${password}" != *$'\n'* ]] || die "pool user ${username} 的密码无效。"
  [[ -z "${seen_users[${username}]:-}" ]] || die "pool-users.txt 中账号重复: ${username}"
  seen_users["${username}"]=1
  printf '%s:%s\n' "${username}" "${password}" >>"${temp_users}"
}

add_pool_user "${MONITOR_USER}" "${MONITOR_PASSWORD}"
add_pool_user "${LAB_USER}" "${LAB_PASSWORD}"
if [[ -f "${POOL_USERS_FILE}" ]]; then
  while IFS=: read -r username password; do
    username="$(trim "${username}")"
    [[ -n "${username}" && "${username}" != \#* ]] || continue
    add_pool_user "${username}" "${password}"
  done <"${POOL_USERS_FILE}"
else
  warn "未找到 ${POOL_USERS_FILE}；当前仅测试/监控账号可通过 Pgpool 登录，尚不能承接业务账号。"
fi

key_file="${PGPOOL_CONFIG_DIR}/.pgpoolkey"
printf '%s\n' "${PGPOOL_AES_KEY}" >"${key_file}"
chmod 600 "${key_file}"
rm -f -- "${PGPOOL_CONFIG_DIR}/pool_passwd"
"${pg_enc_bin}" -m -f "${PGPOOL_CONFIG_DIR}/pgpool.conf" -i "${temp_users}" -k "${key_file}" >/dev/null
[[ -s "${PGPOOL_CONFIG_DIR}/pool_passwd" ]] || die 'pg_enc 未生成 pool_passwd。'

pcp_hash="$(printf '%s\n' "${PCP_PASSWORD}" | "${pg_md5_bin}" -p 2>/dev/null | tail -n 1)"
[[ "${pcp_hash}" =~ ^[0-9a-f]{32}$ ]] || die '无法生成 PCP 密码哈希。'
printf '# USERID:MD5PASSWD\n%s:%s\n' "${PCP_USER}" "${pcp_hash}" >"${PGPOOL_CONFIG_DIR}/pcp.conf"

service_user="$(systemctl show -p User --value "${PGPOOL_SERVICE}" 2>/dev/null || true)"
[[ -n "${service_user}" ]] || service_user=root
service_group="$(id -gn "${service_user}")"
chown root:"${service_group}" "${PGPOOL_CONFIG_DIR}/pgpool.conf" "${PGPOOL_CONFIG_DIR}/pool_hba.conf" "${PGPOOL_CONFIG_DIR}/pcp.conf"
chmod 640 "${PGPOOL_CONFIG_DIR}/pgpool.conf" "${PGPOOL_CONFIG_DIR}/pool_hba.conf" "${PGPOOL_CONFIG_DIR}/pcp.conf"
chown "${service_user}:${service_group}" "${key_file}" "${PGPOOL_CONFIG_DIR}/pool_passwd"
chmod 600 "${key_file}" "${PGPOOL_CONFIG_DIR}/pool_passwd"

install -d -o "${service_user}" -g "${service_group}" -m 755 /var/run/pgpool
override_dir="/etc/systemd/system/${PGPOOL_SERVICE}.service.d"
install -d -m 755 "${override_dir}"
printf '[Service]\nEnvironment=PGPOOLKEYFILE=%s\n' "${key_file}" >"${override_dir}/10-pgpoolkey.conf"
chmod 644 "${override_dir}/10-pgpoolkey.conf"
systemctl daemon-reload

for cidr in "${client_cidrs[@]}"; do
  add_firewall_rule "$(trim "${cidr}")" "${PGPOOL_PORT}"
done

systemctl enable "${PGPOOL_SERVICE}" >/dev/null
systemctl restart "${PGPOOL_SERVICE}"
wait_for_postgres "/usr/pgsql-${PG_MAJOR}/bin" '127.0.0.1' "${PGPOOL_PORT}" 60 || {
  journalctl -u "${PGPOOL_SERVICE}" -n 80 --no-pager >&2 || true
  die 'Pgpool-II 未在 60 秒内就绪。'
}

export PGPASSWORD="${LAB_PASSWORD}"
pool_nodes="$(${psql_bin} -XAtq -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${LAB_USER}" -d "${LAB_DATABASE}" -F '|' -c 'show pool_nodes')"
unset PGPASSWORD
printf '%s\n' "${pool_nodes}"
grep -Eq '(^|\|)primary(\||$)' <<<"${pool_nodes}" || die 'Pgpool-II 未识别到 Primary。'
grep -Eq '(^|\|)standby(\||$)' <<<"${pool_nodes}" || die 'Pgpool-II 未识别到 Standby。'
log "Pgpool-II 已启动并监听 ${PGPOOL_HOST}:${PGPOOL_PORT}；PCP 仅监听 localhost:${PCP_PORT}。"
