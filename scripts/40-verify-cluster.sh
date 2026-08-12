#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

load_cluster_config
load_secrets

psql_bin="$(command -v psql 2>/dev/null || find /usr/pgsql-"${PG_MAJOR}"/bin -name psql -type f -print -quit 2>/dev/null || true)"
[[ -x "${psql_bin}" ]] || die '找不到 psql。'

query() {
  local host="$1" port="$2" user="$3" password="$4" database="$5" sql="$6"
  PGPASSWORD="${password}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
    -h "${host}" -p "${port}" -U "${user}" -d "${database}" -F '|' -c "${sql}"
}

wait_for_value() {
  local host="$1" port="$2" user="$3" password="$4" database="$5" sql="$6" expected="$7" timeout_seconds="${8:-60}"
  local elapsed=0 value=''
  while ((elapsed < timeout_seconds)); do
    value="$(query "${host}" "${port}" "${user}" "${password}" "${database}" "${sql}" 2>/dev/null || true)"
    [[ "${value}" == "${expected}" ]] && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  warn "等待 SQL 结果超时：expected=${expected}, actual=${value}"
  return 1
}

log '1/7 检查 Primary 与 Standby 实际角色。'
primary_identity="$(query "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" "select current_setting('cluster_name'), pg_is_in_recovery()")"
standby_identity="$(query "${STANDBY_HOST}" "${STANDBY_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" "select current_setting('cluster_name'), pg_is_in_recovery()")"
[[ "${primary_identity}" == 'rw-primary|f' ]] || die "Primary 身份异常: ${primary_identity}"
[[ "${standby_identity}" == 'rw-standby|t' ]] || die "Standby 身份异常: ${standby_identity}"

log '2/7 检查 Streaming Replication 状态。'
replication_row="$(query "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${MONITOR_USER}" "${MONITOR_PASSWORD}" postgres \
  "select application_name, state, sync_state from pg_stat_replication where application_name = '${STANDBY_APPLICATION_NAME}'")"
[[ "${replication_row}" == "${STANDBY_APPLICATION_NAME}|streaming|"* ]] || die "主库未看到预期 streaming 复制连接: ${replication_row:-空}"
printf '%s\n' "${replication_row}"

log '3/7 检查 Pgpool-II 节点识别和健康状态。'
pool_nodes="$(query '127.0.0.1' "${PGPOOL_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" 'show pool_nodes')"
printf '%s\n' "${pool_nodes}"
grep -Eq '(^|\|)primary(\||$)' <<<"${pool_nodes}" || die 'SHOW POOL_NODES 中没有 Primary。'
grep -Eq '(^|\|)standby(\||$)' <<<"${pool_nodes}" || die 'SHOW POOL_NODES 中没有 Standby。'
down_rows="$(grep -Ec '(^|\|)down(\||$)' <<<"${pool_nodes}" || true)"
[[ "${down_rows}" == '0' ]] || die 'SHOW POOL_NODES 中存在 down 节点。'

log '4/7 创建隔离探针表并验证 INSERT 路由到 Primary。'
query '127.0.0.1' "${PGPOOL_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  'create schema if not exists rw_proxy_lab; create table if not exists rw_proxy_lab.route_probe (id bigint primary key, payload text not null, updated_at timestamptz not null default clock_timestamp())' >/dev/null
wait_for_value "${STANDBY_HOST}" "${STANDBY_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "select (to_regclass('rw_proxy_lab.route_probe') is not null)::text" 'true' 60 || die '探针表未复制到 Standby。'

probe_id="$(date +%s%N)"
insert_node="$(query '127.0.0.1' "${PGPOOL_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "insert into rw_proxy_lab.route_probe(id,payload) values (${probe_id},'inserted') returning current_setting('cluster_name')")"
[[ "${insert_node}" == 'rw-primary' ]] || die "INSERT 未命中 Primary: ${insert_node}"
wait_for_value "${STANDBY_HOST}" "${STANDBY_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "select payload from rw_proxy_lab.route_probe where id=${probe_id}" 'inserted' 60 || die 'INSERT 未复制到 Standby。'

log '5/7 验证普通 SELECT 路由到 Standby，UPDATE/DELETE 路由到 Primary。'
select_result="$(query '127.0.0.1' "${PGPOOL_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "select current_setting('cluster_name'), payload from rw_proxy_lab.route_probe where id=${probe_id}")"
[[ "${select_result}" == 'rw-standby|inserted' ]] || die "普通 SELECT 未命中 Standby: ${select_result}"

update_node="$(query '127.0.0.1' "${PGPOOL_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "update rw_proxy_lab.route_probe set payload='updated', updated_at=clock_timestamp() where id=${probe_id} returning current_setting('cluster_name')")"
[[ "${update_node}" == 'rw-primary' ]] || die "UPDATE 未命中 Primary: ${update_node}"
wait_for_value "${STANDBY_HOST}" "${STANDBY_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "select payload from rw_proxy_lab.route_probe where id=${probe_id}" 'updated' 60 || die 'UPDATE 未复制到 Standby。'

delete_node="$(query '127.0.0.1' "${PGPOOL_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "delete from rw_proxy_lab.route_probe where id=${probe_id} returning current_setting('cluster_name')")"
[[ "${delete_node}" == 'rw-primary' ]] || die "DELETE 未命中 Primary: ${delete_node}"
wait_for_value "${STANDBY_HOST}" "${STANDBY_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" \
  "select count(*) from rw_proxy_lab.route_probe where id=${probe_id}" '0' 60 || die 'DELETE 未复制到 Standby。'

log '6/7 验证显式事务内写后读固定在 Primary。'
tx_probe_id="$((probe_id + 1))"
tx_output="$(PGPASSWORD="${LAB_PASSWORD}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${LAB_USER}" -d "${LAB_DATABASE}" <<SQL
BEGIN;
INSERT INTO rw_proxy_lab.route_probe(id,payload) VALUES (${tx_probe_id},'tx');
SELECT 'TX_NODE=' || current_setting('cluster_name') FROM rw_proxy_lab.route_probe WHERE id=${tx_probe_id};
ROLLBACK;
SQL
)"
grep -Fxq 'TX_NODE=rw-primary' <<<"${tx_output}" || die "事务内写后读未固定在 Primary: ${tx_output}"

log '7/7 输出最终复制延迟与 Pgpool 路由计数。'
query "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${MONITOR_USER}" "${MONITOR_PASSWORD}" postgres \
  "select application_name,state,sync_state,coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn),0)::bigint as replay_lag_bytes from pg_stat_replication where application_name='${STANDBY_APPLICATION_NAME}'"
query '127.0.0.1' "${PGPOOL_PORT}" "${LAB_USER}" "${LAB_PASSWORD}" "${LAB_DATABASE}" 'show pool_nodes'

log "验证通过：DML -> Primary；普通 SELECT -> Standby；复制状态=streaming；入口=${PGPOOL_HOST}:${PGPOOL_PORT}。"
