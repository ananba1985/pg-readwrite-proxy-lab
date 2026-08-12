#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
require_command runuser
require_command sed
require_command awk

[[ -x "${PRIMARY_PG_BIN_DIR}/psql" ]] || die "找不到 ${PRIMARY_PG_BIN_DIR}/psql"
systemctl is-active --quiet "${PRIMARY_SERVICE}" || die "主库服务未运行: ${PRIMARY_SERVICE}"

psql_local=("${PRIMARY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 -p "${PRIMARY_PORT}" -d postgres)
recovery="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c 'select pg_is_in_recovery()')"
[[ "${recovery}" == 'f' ]] || die '目标 PostgreSQL 不是 Primary，拒绝修改。'

version_num="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c 'show server_version_num')"
[[ "$((version_num / 10000))" == "${PG_MAJOR}" ]] || die 'PG_MAJOR 与现有主库不一致。'

actual_pgdata="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c 'show data_directory')"
[[ "${actual_pgdata}" == "${PRIMARY_PGDATA}" ]] || die "PRIMARY_PGDATA=${PRIMARY_PGDATA}，实际=${actual_pgdata}。"
postgresql_conf="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c 'show config_file')"
pg_hba_conf="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c 'show hba_file')"
[[ -f "${postgresql_conf}" && -f "${pg_hba_conf}" ]] || die '找不到 PostgreSQL 主配置或 pg_hba.conf。'

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_dir="/var/backups/pg-rw-proxy/primary-${timestamp}"
mkdir -p -- "${backup_dir}"
chmod 700 "${backup_dir}"
backup_file "${postgresql_conf}" "${backup_dir}"
backup_file "${pg_hba_conf}" "${backup_dir}"
log "主库原配置已备份到 ${backup_dir}。"

conf_dir="$(dirname -- "${postgresql_conf}")"
managed_conf_dir="${conf_dir}/conf.d"
managed_conf="${managed_conf_dir}/99-pg-rw-proxy.conf"
mkdir -p -- "${managed_conf_dir}"
temp_conf="$(mktemp)"
temp_include="$(mktemp)"
temp_hba="$(mktemp)"
temp_sql="$(mktemp)"
cleanup() {
  rm -f -- "${temp_conf}" "${temp_include}" "${temp_hba}" "${temp_sql}"
}
trap cleanup EXIT

render_template "${PROJECT_ROOT}/templates/primary-postgresql.conf.tpl" "${temp_conf}" \
  MAX_WAL_SENDERS "${MAX_WAL_SENDERS}" \
  MAX_REPLICATION_SLOTS "${MAX_REPLICATION_SLOTS}" \
  WAL_KEEP_SIZE "${WAL_KEEP_SIZE}" \
  MAX_SLOT_WAL_KEEP_SIZE "${MAX_SLOT_WAL_KEEP_SIZE}" \
  PRIMARY_LISTEN_ADDRESSES "${PRIMARY_LISTEN_ADDRESSES}"
install -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 600 "${temp_conf}" "${managed_conf}"

printf "include_if_exists = 'conf.d/99-pg-rw-proxy.conf'\n" >"${temp_include}"
replace_managed_block "${postgresql_conf}" 'PG_RW_PROXY_INCLUDE' "${temp_include}"

render_template "${PROJECT_ROOT}/templates/primary-pg_hba.entries.tpl" "${temp_hba}" \
  REPLICATION_USER "${REPLICATION_USER}" \
  STANDBY_ADDRESS_CIDR "${STANDBY_ADDRESS_CIDR}" \
  PGPOOL_ADDRESS_CIDR "${PGPOOL_ADDRESS_CIDR}"
replace_managed_block "${pg_hba_conf}" 'PG_RW_PROXY_HBA' "${temp_hba}"

chown "${PG_OS_USER}:${PG_OS_USER}" "${postgresql_conf}" "${pg_hba_conf}"
chmod 600 "${postgresql_conf}" "${pg_hba_conf}"

rep_user_sql="$(sql_literal "${REPLICATION_USER}")"
rep_pass_sql="$(sql_literal "${REPLICATION_PASSWORD}")"
monitor_user_sql="$(sql_literal "${MONITOR_USER}")"
monitor_pass_sql="$(sql_literal "${MONITOR_PASSWORD}")"
lab_user_sql="$(sql_literal "${LAB_USER}")"
lab_pass_sql="$(sql_literal "${LAB_PASSWORD}")"
lab_db_sql="$(sql_literal "${LAB_DATABASE}")"

cat >"${temp_sql}" <<SQL
\\set ON_ERROR_STOP on
SET password_encryption = 'scram-sha-256';

SELECT format('CREATE ROLE %I LOGIN REPLICATION PASSWORD %L', ${rep_user_sql}, ${rep_pass_sql})
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ${rep_user_sql}) \\gexec
SELECT format('ALTER ROLE %I WITH LOGIN REPLICATION PASSWORD %L', ${rep_user_sql}, ${rep_pass_sql}) \\gexec
GRANT pg_monitor TO ${REPLICATION_USER};

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', ${monitor_user_sql}, ${monitor_pass_sql})
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ${monitor_user_sql}) \\gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', ${monitor_user_sql}, ${monitor_pass_sql}) \\gexec
GRANT pg_monitor TO ${MONITOR_USER};

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', ${lab_user_sql}, ${lab_pass_sql})
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ${lab_user_sql}) \\gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', ${lab_user_sql}, ${lab_pass_sql}) \\gexec

SELECT format('CREATE DATABASE %I OWNER %I', ${lab_db_sql}, ${lab_user_sql})
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = ${lab_db_sql}) \\gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', ${lab_db_sql}, ${lab_user_sql}) \\gexec
SQL
chmod 600 "${temp_sql}"
run_as_pg "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PG_BIN_DIR}/psql" -X -v ON_ERROR_STOP=1 -p "${PRIMARY_PORT}" -d postgres -f "${temp_sql}" >/dev/null
log '复制、监控和隔离测试账号已创建/同步；测试数据库已准备。'

reload_ok="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c 'select pg_reload_conf()')"
[[ "${reload_ok}" == 't' ]] || die 'PostgreSQL 配置 reload 返回失败。'
sleep 1
config_errors="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c "select count(*) from pg_file_settings where error is not null")"
[[ "${config_errors}" == '0' ]] || {
  run_as_pg "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PG_BIN_DIR}/psql" -X -p "${PRIMARY_PORT}" -d postgres -c \
    "select sourcefile, sourceline, name, error from pg_file_settings where error is not null;" >&2
  die '检测到 PostgreSQL 配置错误；请用备份目录恢复。'
}

add_firewall_rule "${STANDBY_ADDRESS_CIDR}" "${PRIMARY_PORT}"
add_firewall_rule "${PGPOOL_ADDRESS_CIDR}" "${PRIMARY_PORT}"

pending_restart="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c "select count(*) from pg_settings where pending_restart")"
if [[ "${APPLY_PRIMARY_RESTART}" == 'yes' ]]; then
  log 'APPLY_PRIMARY_RESTART=yes：正在维护窗口内重启 Primary。'
  systemctl restart "${PRIMARY_SERVICE}"
  wait_for_postgres "${PRIMARY_PG_BIN_DIR}" '127.0.0.1' "${PRIMARY_PORT}" 90 || die 'Primary 重启后未在 90 秒内就绪。'
  final_recovery="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${psql_local[@]}" -c 'select pg_is_in_recovery()')"
  [[ "${final_recovery}" == 'f' ]] || die 'Primary 重启后角色异常。'
  log 'Primary 已重启并恢复服务。'
else
  warn "未重启 Primary（pending_restart=${pending_restart}）。完成维护窗口审批后，将 APPLY_PRIMARY_RESTART=yes 再执行本脚本。"
fi

run_as_pg "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PG_BIN_DIR}/psql" -X -p "${PRIMARY_PORT}" -d postgres -c \
  "select name, setting, pending_restart from pg_settings where name in ('wal_level','max_wal_senders','max_replication_slots','wal_keep_size','max_slot_wal_keep_size','listen_addresses','cluster_name') order by name;"
log 'Primary 配置阶段完成。'
