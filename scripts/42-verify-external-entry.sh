#!/usr/bin/env bash

# 在 Primary 暂存目录中执行，从另一台服务器证明 Pgpool 对外入口可访问。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_cluster_config
load_secrets

result="$(PGPASSWORD="${BUSINESS_PASSWORD}" "${PRIMARY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 \
  -h "${PGPOOL_HOST}" -p "${PGPOOL_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" \
  -c "select current_user,current_database(),current_setting('cluster_name')")"
[[ "${result}" == "${BUSINESS_USER}|${BUSINESS_DATABASE}|rw-standby" ]] || die "远端 Pgpool 入口验证异常: ${result}"
log "远端客户端入口验证通过：${PGPOOL_HOST}:${PGPOOL_PORT} -> ${result}。"
