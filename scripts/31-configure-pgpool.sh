#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/primary-client-policy.sh
source "${SCRIPT_DIR}/lib/primary-client-policy.sh"

require_root
load_cluster_config
load_secrets
pg_enc_bin="$(find_pgpool_binary pg_enc)"
require_command md5sum
psql_bin="${PG_CLIENT_PREFIX}/bin/psql"
export LD_LIBRARY_PATH="${PGPOOL_RUNTIME_PREFIX}/lib:${PG_CLIENT_PREFIX}/lib:${PGPOOL_INSTALL_PREFIX}/lib"
[[ -x "${psql_bin}" ]] || die '找不到 Pgpool 节点专用 psql。'

query_direct() {
  local host="$1" password="$2" sql="$3"
  PGPASSWORD="${password}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 -h "${host}" -p "${PRIMARY_PORT}" \
    -U "${MONITOR_USER}" -d postgres -c "${sql}"
}
primary_role="$(query_direct "${PRIMARY_HOST}" "${MONITOR_PASSWORD}" 'select pg_is_in_recovery()')"
standby_role="$(query_direct "${STANDBY_HOST}" "${MONITOR_PASSWORD}" 'select pg_is_in_recovery()')"
[[ "${primary_role}" == 'f' && "${standby_role}" == 't' ]] || die "后端角色异常：Primary=${primary_role}, Standby=${standby_role}。"
business_check="$(PGPASSWORD="${BUSINESS_PASSWORD}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
  -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" \
  -c "select current_user,(to_regclass('business.rw_probe') is not null)::text")"
[[ "${business_check}" == "${BUSINESS_USER}|true" ]] || die "现有业务凭据校验失败: ${business_check}"

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_dir="/var/backups/pg-readwrite-proxy-lab/pgpool-${timestamp}"
mkdir -p -- "${backup_dir}"
chmod 700 "${backup_dir}"
for file in pgpool.conf pool_hba.conf pool_passwd pcp.conf .pgpoolkey; do backup_file "${PGPOOL_CONFIG_DIR}/${file}" "${backup_dir}"; done

temp_conf="$(mktemp)"; temp_hba="$(mktemp)"; temp_hba_rules="$(mktemp)"; temp_users="$(mktemp)"
cleanup() { rm -f -- "${temp_conf}" "${temp_hba}" "${temp_hba_rules}" "${temp_users}"; }
trap cleanup EXIT
umask 077

render_template "${PROJECT_ROOT}/templates/pgpool.conf.tpl" "${temp_conf}" \
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

if [[ -n "${PGPOOL_CLIENT_POLICY_FILE:-}" ]]; then
  [[ "${PGPOOL_CLIENT_POLICY_MODE:-}" == 'primary_hba_repair' ]] || \
    die '拒绝使用来源未标记为 Primary repair 快照的 Pgpool 客户端策略。'
  policy_realpath="$(readlink -f -- "${PGPOOL_CLIENT_POLICY_FILE}")"
  [[ "${policy_realpath}" =~ ^/var/tmp/pg-rw-repair\.[^/]+/primary-client-policy\.rules$ ]] || \
    die "Pgpool 客户端策略不在本次 repair 私有目录: ${policy_realpath}"
  validate_pgpool_client_policy_file "${PGPOOL_CLIENT_POLICY_FILE}"
  policy_sha256="$(sha256sum "${PGPOOL_CLIENT_POLICY_FILE}" | awk '{print $1}')"
  [[ "${PGPOOL_CLIENT_POLICY_SHA256:-}" =~ ^[0-9a-f]{64}$ && \
     "${policy_sha256}" == "${PGPOOL_CLIENT_POLICY_SHA256}" ]] || \
    die 'Pgpool 客户端策略在只读检查后发生变化，拒绝落盘。'
  policy_rule_count="$(grep -Ec '^[[:space:]]*host[[:space:]]' "${PGPOOL_CLIENT_POLICY_FILE}")"
  printf '# BEGIN PRIMARY_SYNCED_CLIENT_POLICY\n' >>"${temp_hba_rules}"
  printf '# policy_sha256=%s rules=%s\n' \
    "${policy_sha256}" "${policy_rule_count}" >>"${temp_hba_rules}"
  cat "${PGPOOL_CLIENT_POLICY_FILE}" >>"${temp_hba_rules}"
  printf '# END PRIMARY_SYNCED_CLIENT_POLICY\n' >>"${temp_hba_rules}"
  log "Pgpool IPv4 白名单来自 Primary 只读快照：rules=${policy_rule_count} sha256=${policy_sha256}。"
else
  IFS=',' read -r -a client_cidrs <<<"${ALLOWED_CLIENT_CIDRS}"
  for cidr in "${client_cidrs[@]}"; do
    printf 'host    all       all   %-22s md5\n' "$(trim "${cidr}")" >>"${temp_hba_rules}"
  done
  log 'Pgpool 客户端策略使用 install.sh 首次部署参数；后续 repair.sh 将同步 Primary 普通 IPv4 白名单。'
fi
awk -v rules="${temp_hba_rules}" '$0=="{{CLIENT_HBA_RULES}}"{while((getline line < rules)>0)print line;close(rules);next}{print}' \
  "${PROJECT_ROOT}/templates/pool_hba.conf.tpl" >"${temp_hba}"
install -o root -g pgpool -m 640 "${temp_conf}" "${PGPOOL_CONFIG_DIR}/pgpool.conf"
install -o root -g pgpool -m 640 "${temp_hba}" "${PGPOOL_CONFIG_DIR}/pool_hba.conf"

declare -A seen_users=()
add_pool_user() {
  local username="$1" password="$2"
  validate_identifier "${username}" 'pool user'
  [[ -n "${password}" && "${password}" != *:* && "${password}" != *$'\n'* ]] || die "pool user ${username} 密码不能包含冒号或换行。"
  [[ -z "${seen_users[${username}]:-}" ]] || die "pool-users.txt 账号重复: ${username}"
  seen_users["${username}"]=1
  printf '%s:%s\n' "${username}" "${password}" >>"${temp_users}"
}
add_pool_user "${MONITOR_USER}" "${MONITOR_PASSWORD}"
add_pool_user "${BUSINESS_USER}" "${BUSINESS_PASSWORD}"
if [[ -f "${POOL_USERS_FILE}" ]]; then
  while IFS=: read -r username password; do
    username="$(trim "${username}")"
    [[ -n "${username}" && "${username}" != \#* ]] || continue
    add_pool_user "${username}" "${password}"
  done <"${POOL_USERS_FILE}"
fi

key_file="${PGPOOL_CONFIG_DIR}/.pgpoolkey"
printf '%s\n' "${PGPOOL_AES_KEY}" >"${key_file}"
chown pgpool:pgpool "${key_file}"
chmod 600 "${key_file}"
rm -f -- "${PGPOOL_CONFIG_DIR}/pool_passwd"
PGPOOLKEYFILE="${key_file}" "${pg_enc_bin}" -m -f "${PGPOOL_CONFIG_DIR}/pgpool.conf" -i "${temp_users}" >/dev/null
[[ -s "${PGPOOL_CONFIG_DIR}/pool_passwd" ]] || die 'pg_enc 未生成 pool_passwd。'
chown pgpool:pgpool "${PGPOOL_CONFIG_DIR}/pool_passwd"
chmod 600 "${PGPOOL_CONFIG_DIR}/pool_passwd"

pcp_hash="$(printf '%s' "${PCP_PASSWORD}" | md5sum | awk '{print $1}')"
[[ "${pcp_hash}" =~ ^[0-9a-f]{32}$ ]] || die '无法生成 PCP 密码哈希。'
printf '# USERID:MD5PASSWD\n%s:%s\n' "${PCP_USER}" "${pcp_hash}" >"${PGPOOL_CONFIG_DIR}/pcp.conf"
chown root:pgpool "${PGPOOL_CONFIG_DIR}/pcp.conf"
chmod 640 "${PGPOOL_CONFIG_DIR}/pcp.conf"

systemctl enable "${PGPOOL_SERVICE}" >/dev/null
systemctl restart "${PGPOOL_SERVICE}"
wait_for_postgres "${PG_CLIENT_PREFIX}/bin" 127.0.0.1 "${PGPOOL_PORT}" 60 || {
  journalctl -u "${PGPOOL_SERVICE}" -n 100 --no-pager >&2 || true
  die 'Pgpool-II 未在 60 秒内就绪。'
}

pool_nodes="$(PGPASSWORD="${BUSINESS_PASSWORD}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" -F '|' -c 'show pool_nodes')"
printf '%s\n' "${pool_nodes}"
grep -Eq '(^|\|)primary(\||$)' <<<"${pool_nodes}" || die 'Pgpool-II 未识别 Primary。'
grep -Eq '(^|\|)standby(\||$)' <<<"${pool_nodes}" || die 'Pgpool-II 未识别 Standby。'
log "Pgpool-II 已启动：业务入口 ${PGPOOL_HOST}:${PGPOOL_PORT}；PCP 仅限 localhost:${PCP_PORT}。"
