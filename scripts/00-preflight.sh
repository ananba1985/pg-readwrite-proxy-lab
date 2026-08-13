#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROLE="${1:-}"
[[ "${ROLE}" =~ ^(primary|standby|pgpool)$ ]] || { printf '用法：sudo %s primary|standby|pgpool\n' "$0" >&2; exit 2; }

require_root
load_cluster_config
require_command timeout
case "${ROLE}" in
  primary|standby) detect_db_platform ;;
  pgpool) detect_pgpool_platform ;;
esac
log "只读预检：角色=${ROLE}，系统=${PRETTY_NAME:-unknown}，架构=$(uname -m)，SELinux=$(getenforce 2>/dev/null || printf unknown)"

assert_local_ipv4() {
  local expected="$1" label="$2"
  /sbin/ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${expected}" || \
    die "${label} 配置地址 ${expected} 不属于当前服务器。"
}

case "${ROLE}" in
  primary)
    assert_local_ipv4 "${PRIMARY_HOST}" PRIMARY_HOST
    assert_safe_pgdata "${PRIMARY_PGDATA}"
    verify_nebula_runtime "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_ADMIN_TOOL}" Primary
    [[ -d "${PRIMARY_PGDATA}" ]] || die "Primary PGDATA 不存在: ${PRIMARY_PGDATA}"
    pg_ctl_is_running "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PGDATA}" || die 'Primary 未由 pg_ctl 运行。'
    row="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('data_directory'),current_setting('wal_level'),current_setting('max_wal_senders'),current_setting('max_replication_slots')")"
    [[ "${row}" == "120000|f|${PRIMARY_PGDATA}|"* ]] || die "Primary 身份或路径异常: ${row}"
    business_count="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_database where datname='${BUSINESS_DATABASE}'")"
    [[ "${business_count}" == '1' ]] || die "Primary 缺少现有业务库 ${BUSINESS_DATABASE}。"
    role_count="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_roles where rolname='${BUSINESS_USER}' and rolcanlogin")"
    [[ "${role_count}" == '1' ]] || die "Primary 缺少现有业务账号 ${BUSINESS_USER}。"
    log "Primary 状态=${row}"
    log "Primary PGDATA 磁盘=$(df -hP "${PRIMARY_PGDATA}" | tail -n 1)"
    ;;
  standby)
    assert_local_ipv4 "${STANDBY_HOST}" STANDBY_HOST
    assert_safe_pgdata "${STANDBY_PGDATA}"
    verify_nebula_runtime "${STANDBY_PG_BIN_DIR}" "${STANDBY_ADMIN_TOOL}" 'Standby 目标机'
    [[ -d "${STANDBY_PGDATA}" ]] || die "Standby PGDATA 不存在: ${STANDBY_PGDATA}"
    if pg_ctl_is_running "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"; then
      row="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
        "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('data_directory')")"
      [[ "${row}" == "120000|"*"|${STANDBY_PGDATA}" ]] || die "Standby 目标机版本或路径异常: ${row}"
      if [[ "${row}" == '120000|f|'* ]]; then
        warn 'Standby 目标机当前仍是独立可写实例；只有显式维护窗口授权后才会移动旧 PGDATA。'
      else
        log 'Standby 已处于恢复态；后续脚本将按原地校验/刷新凭据处理。'
      fi
    elif validate_standby_resume_state; then
      log "Standby 处于可恢复中间态：服务停止，备份状态=${STANDBY_RESUME_STATE_FILE}；允许继续基础备份。"
    else
      die 'Standby 服务未运行且没有有效的中断恢复状态，拒绝猜测。'
    fi
    log "Standby 目标磁盘=$(df -hP "${STANDBY_PGDATA}" | tail -n 1)"
    tcp_check "${PRIMARY_HOST}" "${PRIMARY_PORT}" || die "Standby 无法访问 Primary ${PRIMARY_HOST}:${PRIMARY_PORT}。"
    ;;
  pgpool)
    assert_local_ipv4 "${PGPOOL_HOST}" PGPOOL_HOST
    [[ ! -x /opt/pgsql12/bin/postgres ]] || die 'Pgpool-II 节点存在数据库服务端运行时 /opt/pgsql12/bin/postgres；请先清理错误基线。'
    validate_offline_payloads
    tcp_check "${PRIMARY_HOST}" "${PRIMARY_PORT}" || die "Pgpool 节点无法访问 Primary ${PRIMARY_HOST}:${PRIMARY_PORT}。"
    if tcp_check "${STANDBY_HOST}" "${STANDBY_PORT}"; then
      log "Pgpool 节点可访问 Standby 目标 ${STANDBY_HOST}:${STANDBY_PORT}。"
    elif [[ "${ALLOW_STANDBY_REINITIALIZE}" == 'yes' ]]; then
      warn "Standby 目标暂未监听 ${STANDBY_HOST}:${STANDBY_PORT}；已获重建授权，允许继续。Pgpool 配置前仍会强制验证角色和连通性。"
    else
      die "Pgpool 节点无法访问 Standby ${STANDBY_HOST}:${STANDBY_PORT}。"
    fi
    if ss -ltn "sport = :${PGPOOL_PORT}" 2>/dev/null | grep -q LISTEN; then
      warn "TCP/${PGPOOL_PORT} 已监听；配置阶段将重启既有 Pgpool 服务。"
    else
      log "TCP/${PGPOOL_PORT} 当前可用。"
    fi
    ;;
esac

log '只读预检通过。'
