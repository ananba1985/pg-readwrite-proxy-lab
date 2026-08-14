#!/usr/bin/env bash

# 只续接“pg_basebackup 已完成、Standby 启动/恢复等待中断”的现场状态。
# 本脚本不得执行 pg_basebackup、不得移动/删除 PGDATA、不得停止任何数据库。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
for command_name in runuser sha256sum stat tail grep awk sed sleep; do
  require_command "${command_name}"
done
assert_safe_pgdata "${STANDBY_PGDATA}"
verify_nebula_runtime "${STANDBY_PG_BIN_DIR}" "${STANDBY_ADMIN_TOOL}" 'Standby 续启节点'

[[ -f "${STANDBY_PGDATA}/PG_VERSION" && "$(tr -d '\r\n' <"${STANDBY_PGDATA}/PG_VERSION")" == '12' ]] || \
  die 'Standby PG_VERSION 缺失或版本不等于 12。'
for file in postgresql.conf postgresql.auto.conf pg_hba.conf standby.signal global/pg_control; do
  [[ -f "${STANDBY_PGDATA}/${file}" && ! -L "${STANDBY_PGDATA}/${file}" ]] || \
    die "基础备份 PGDATA 缺少必要文件或文件类型异常: ${STANDBY_PGDATA}/${file}"
done
[[ "$(stat -c '%U:%G:%a' "${STANDBY_PGDATA}")" == "${PG_OS_USER}:${PG_OS_USER}:700" ]] || \
  die "Standby PGDATA 所有者或权限异常: $(stat -c '%U:%G:%a' "${STANDBY_PGDATA}")"

if grep -Fqx '# BEGIN PG_RW_PROXY_RECOVERY' "${STANDBY_PGDATA}/postgresql.auto.conf" && \
   grep -Fqx '# END PG_RW_PROXY_RECOVERY' "${STANDBY_PGDATA}/postgresql.auto.conf" && \
   grep -Fqx '# BEGIN PG_RW_PROXY_INCLUDE' "${STANDBY_PGDATA}/postgresql.conf" && \
   grep -Fqx '# END PG_RW_PROXY_INCLUDE' "${STANDBY_PGDATA}/postgresql.conf" && \
   [[ -f "${STANDBY_PGDATA}/conf.d/99-pg-rw-proxy.conf" && ! -L "${STANDBY_PGDATA}/conf.d/99-pg-rw-proxy.conf" ]] && \
   grep -Fq "cluster_name = 'rw-standby'" "${STANDBY_PGDATA}/conf.d/99-pg-rw-proxy.conf"; then
  # standby.signal 仅在 pg_basebackup 返回 0 后创建，受管恢复配置随后写入；这些实时 PGDATA
  # 证据与 pg_control/Primary system identifier 共同证明当前基础备份可续启，无需安装状态文件。
  resume_evidence='live_pgdata_managed_recovery'
else
  die '当前 PGDATA 缺少完整受管恢复配置证据；拒绝猜测基础备份是否完整。'
fi

export PGPASSWORD="${REPLICATION_PASSWORD}"
primary_identity="$("${STANDBY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 \
  -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}" -d postgres \
  -c "select pg_is_in_recovery(),system_identifier from pg_control_system()")"
unset PGPASSWORD
IFS='|' read -r primary_recovery expected_primary_system_id <<<"${primary_identity}"
[[ "${primary_recovery}" == f && "${expected_primary_system_id}" =~ ^[0-9]+$ ]] || \
  die "无法确认当前 Primary 身份: ${primary_identity:-empty}"
control_system_id="$(run_as_pg "${STANDBY_PG_BIN_DIR}" "${STANDBY_PG_BIN_DIR}/pg_controldata" "${STANDBY_PGDATA}" |
  awk -F: '/Database system identifier/{gsub(/[[:space:]]/,"",$2);print $2}')"
[[ "${control_system_id}" == "${expected_primary_system_id}" ]] || \
  die "当前 PGDATA system identifier=${control_system_id:-empty} 与已记录 Primary=${expected_primary_system_id} 不一致。"

if ! pg_ctl_is_running "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"; then
  log 'Standby 当前未运行；仅启动现有基础备份 PGDATA，不重新同步。'
  pg_ctl_start "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}" "${STANDBY_PGDATA}/log/pg-rw-proxy-resume.log"
else
  log 'Standby postmaster 已在运行；继续等待恢复就绪，不重复启动。'
fi

if ! wait_for_postgres "${STANDBY_PG_BIN_DIR}" 127.0.0.1 "${STANDBY_PORT}" 1800; then
  startup_log="$(tail -n 200 "${STANDBY_PGDATA}/log/pg-rw-proxy-resume.log" 2>/dev/null || \
    tail -n 200 "${STANDBY_PGDATA}/log/pg-rw-proxy-startup.log" 2>/dev/null || true)"
  die "Standby 在续启后 1800 秒内仍未就绪；未重建或停止数据库。启动日志末尾：${startup_log}"
fi

standby=''
for ((elapsed=0; elapsed<300; elapsed+=2)); do
  standby="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
    "select current_setting('server_version_num'),current_setting('cluster_name'),pg_is_in_recovery(),(select system_identifier from pg_control_system()),coalesce((select status from pg_stat_wal_receiver limit 1),'')" 2>/dev/null || true)"
  [[ "${standby}" == "120000|rw-standby|t|${expected_primary_system_id}|streaming" ]] && break
  sleep 2
done
[[ "${standby}" == "120000|rw-standby|t|${expected_primary_system_id}|streaming" ]] || \
  die "Standby 已可连接但在 300 秒内未达到预期 streaming 恢复态: ${standby}"

printf 'STANDBY_RESUME_RESULT=READY action=start_or_wait_existing_pgdata basebackup=not_run evidence=%s state=%s\n' \
  "${resume_evidence}" "${standby}"
