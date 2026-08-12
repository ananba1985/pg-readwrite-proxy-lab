#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_cluster_config
load_secrets
psql="${PG_CLIENT_PREFIX}/bin/psql"

query() { PGPASSWORD="$4" "${psql}" -X -v ON_ERROR_STOP=1 -h "$1" -p "$2" -U "$3" -d "$5" -c "$6"; }
echo 'Primary 复制发送状态：'
query "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${MONITOR_USER}" "${MONITOR_PASSWORD}" postgres \
  "select application_name,client_addr,state,sync_state,write_lag,flush_lag,replay_lag from pg_stat_replication;"
echo 'Pgpool 节点状态：'
query 127.0.0.1 "${PGPOOL_PORT}" "${BUSINESS_USER}" "${BUSINESS_PASSWORD}" "${BUSINESS_DATABASE}" 'show pool_nodes;'
