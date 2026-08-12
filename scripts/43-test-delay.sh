#!/usr/bin/env bash

# 维护窗口演练：暂停 Standby 回放，制造小量 WAL，证明超过阈值后普通 SELECT 回退到 Primary。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
psql_bin="${PG_CLIENT_PREFIX}/bin/psql"
[[ -x "${psql_bin}" ]] || die '找不到 Pgpool 节点 psql。'

root_ssh_port="${ROOT_SSH_PORT:-22}"
remote_standby_admin() {
  ssh -p "${root_ssh_port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@"${STANDBY_HOST}" \
    "cd /tmp && ${STANDBY_ADMIN_TOOL} psql -d postgres -p ${STANDBY_PORT} -c \"$1\""
}

# 该独立脚本默认要求已配置 root 密钥；一键安装的实际演练可由运维等价执行。
cleanup() {
  remote_standby_admin 'select pg_wal_replay_resume()' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

remote_standby_admin 'select pg_wal_replay_pause()' >/dev/null
probe_key="delay-$(date +%s)-$$"
PGPASSWORD="${BUSINESS_PASSWORD}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" \
  -c "insert into business.rw_probe(probe_key,payload) values ('${probe_key}','{\"state\":\"delay\"}'::jsonb)" >/dev/null
sleep "$((READ_LAG_THRESHOLD_SECONDS + SR_CHECK_PERIOD + 2))"
node="$(PGPASSWORD="${BUSINESS_PASSWORD}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" \
  -c "select current_setting('cluster_name') from business.dataset_manifest limit 1")"
[[ "${node}" == 'rw-primary' ]] || die "延迟超过阈值后 SELECT 未回退 Primary: ${node}"
cleanup
trap - EXIT INT TERM

for _ in $(seq 1 60); do
  lag="$(PGPASSWORD="${MONITOR_PASSWORD}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
    -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${MONITOR_USER}" -d postgres \
    -c "select coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn),0)::bigint from pg_stat_replication where application_name='${STANDBY_APPLICATION_NAME}'")"
  [[ "${lag}" == '0' ]] && break
  sleep 1
done
[[ "${lag:-}" == '0' ]] || die "恢复回放后延迟未归零: ${lag:-unknown}"
PGPASSWORD="${BUSINESS_PASSWORD}" "${psql_bin}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" \
  -c "delete from business.rw_probe where probe_key='${probe_key}'" >/dev/null
log '延迟演练通过：超过阈值时 SELECT -> Primary，恢复后复制延迟归零。'
