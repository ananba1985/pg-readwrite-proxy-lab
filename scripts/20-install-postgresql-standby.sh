#!/usr/bin/env bash

# 兼容旧的步骤编号：本项目绝不在 Standby 安装/替换数据库，只校验现有 NebulaCM 运行时。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
detect_db_platform
assert_safe_pgdata "${STANDBY_PGDATA}"
verify_nebula_runtime "${STANDBY_PG_BIN_DIR}" "${STANDBY_ADMIN_TOOL}" 'Standby 目标机'
[[ -d "${STANDBY_PGDATA}" ]] || die "Standby PGDATA 不存在: ${STANDBY_PGDATA}"
if pg_ctl_is_running "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"; then
  row="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
    "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('data_directory')")"
  [[ "${row}" == "120000|"*"|${STANDBY_PGDATA}" ]] || die "Standby 现有运行时不符合要求: ${row}"
elif validate_standby_resume_state; then
  log "Standby 数据初始化从已验证中断点继续：${STANDBY_RESUME_STATE_FILE}。"
else
  die 'Standby 未运行且没有有效中断恢复状态。'
fi
log "已确认 Standby 预装的受支持 NebulaCM PostgreSQL 12.0；没有安装、复制或覆盖数据库运行时。"
