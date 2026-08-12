#!/usr/bin/env bash

# APPLY 后、修改数据库前调用。既有 Pgpool 已停止时，必须证明所有普通客户端连接均已释放。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
require_root
load_cluster_config
local_ip="$(/sbin/ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)"
if grep -Fxq "${PRIMARY_HOST}" <<<"${local_ip}"; then
  admin_tool="${PRIMARY_ADMIN_TOOL}"; port="${PRIMARY_PORT}"
elif grep -Fxq "${STANDBY_HOST}" <<<"${local_ip}"; then
  admin_tool="${STANDBY_ADMIN_TOOL}"; port="${STANDBY_PORT}"
else
  die '当前主机既不是 Primary 也不是 Standby。'
fi
nebula_admin_query "${admin_tool}" "${port}" postgres \
  "select count(*) from pg_stat_activity where backend_type='client backend' and pid<>pg_backend_pid()"
