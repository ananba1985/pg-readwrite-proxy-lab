#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
用法：sudo ./scripts/00-preflight.sh primary|standby|pgpool

本脚本只读，不安装软件、不改配置、不启停服务。
EOF
}

ROLE="${1:-}"
[[ "${ROLE}" =~ ^(primary|standby|pgpool)$ ]] || {
  usage
  exit 2
}

require_root
load_cluster_config
detect_el_major
require_command systemctl
require_command timeout

log "角色=${ROLE}，系统=${PRETTY_NAME:-unknown}，架构=$(uname -m)"
log "内核=$(uname -r)，SELinux=$(getenforce 2>/dev/null || printf 'unknown')"
log "主机名=$(hostname -f 2>/dev/null || hostname)"

if [[ "${ID:-}" == 'centos' && "${EL_MAJOR}" == '8' ]] && ! grep -qi stream /etc/centos-release 2>/dev/null; then
  die 'CentOS Linux 8 已停止维护；请升级到受支持的 Stream/RHEL 兼容版本。'
fi

case "${ROLE}" in
  primary)
    [[ -x "${PRIMARY_PG_BIN_DIR}/psql" ]] || die "找不到 ${PRIMARY_PG_BIN_DIR}/psql"
    [[ -d "${PRIMARY_PGDATA}" ]] || die "主库 PGDATA 不存在: ${PRIMARY_PGDATA}"
    systemctl is-active --quiet "${PRIMARY_SERVICE}" || die "主库服务未运行: ${PRIMARY_SERVICE}"
    version_num="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PG_BIN_DIR}/psql" -XAtq -p "${PRIMARY_PORT}" -d postgres -c 'show server_version_num')"
    actual_major="$((version_num / 10000))"
    [[ "${actual_major}" == "${PG_MAJOR}" ]] || die "主库大版本=${actual_major}，配置 PG_MAJOR=${PG_MAJOR}。"
    recovery="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PG_BIN_DIR}/psql" -XAtq -p "${PRIMARY_PORT}" -d postgres -c 'select pg_is_in_recovery()')"
    [[ "${recovery}" == 'f' ]] || die '指定的主库实际处于恢复态，拒绝继续。'
    run_as_pg "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PG_BIN_DIR}/psql" -X -p "${PRIMARY_PORT}" -d postgres -c \
      "select current_setting('server_version') as version, current_setting('data_directory') as data_directory, current_setting('wal_level') as wal_level, current_setting('max_wal_senders') as max_wal_senders, current_setting('max_replication_slots') as max_replication_slots;"
    log "PGDATA 磁盘：$(df -hP "${PRIMARY_PGDATA}" | tail -n 1)"
    ;;
  standby)
    log "目标 PGDATA 磁盘：$(df -hP "$(dirname "${STANDBY_PGDATA}")" 2>/dev/null | tail -n 1 || printf '目录尚不存在')"
    if tcp_check "${PRIMARY_HOST}" "${PRIMARY_PORT}"; then
      log "可访问 Primary ${PRIMARY_HOST}:${PRIMARY_PORT}。"
    else
      warn "当前无法访问 Primary ${PRIMARY_HOST}:${PRIMARY_PORT}；可能尚未放行或尚未应用 Primary 配置。"
    fi
    [[ ! -e "${STANDBY_PGDATA}/PG_VERSION" ]] || warn "${STANDBY_PGDATA} 已包含数据库集群；初始化脚本默认会拒绝覆盖。"
    ;;
  pgpool)
    for endpoint in "${PRIMARY_HOST}:${PRIMARY_PORT}" "${STANDBY_HOST}:${STANDBY_PORT}"; do
      host="${endpoint%:*}"
      port="${endpoint##*:}"
      if tcp_check "${host}" "${port}"; then
        log "可访问后端 ${endpoint}。"
      else
        warn "当前无法访问后端 ${endpoint}。"
      fi
    done
    if ss -ltn "sport = :${PGPOOL_PORT}" 2>/dev/null | grep -q LISTEN; then
      warn "TCP/${PGPOOL_PORT} 已被占用。"
    else
      log "TCP/${PGPOOL_PORT} 当前可用。"
    fi
    ;;
esac

if systemctl is-active --quiet firewalld; then
  log 'firewalld=active'
else
  warn 'firewalld 未运行；需确认上游安全组/防火墙策略。'
fi

log '预检完成（只读，未修改系统）。'
