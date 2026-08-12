#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
assert_safe_pgdata "${PRIMARY_PGDATA}"
verify_nebula_runtime "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_ADMIN_TOOL}" Primary
pg_ctl_is_running "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PGDATA}" || die 'Primary 未运行。'
[[ "${APPLY_PRIMARY_RESTART}" == 'yes' ]] || die 'Primary 配置需要维护窗口；APPLY_PRIMARY_RESTART 必须显式为 yes。'

identity="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
  "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('data_directory'),current_setting('config_file'),current_setting('hba_file')")"
IFS='|' read -r version_num recovery actual_pgdata postgresql_conf pg_hba_conf <<<"${identity}"
[[ "${version_num}" == '120000' && "${recovery}" == 'f' && "${actual_pgdata}" == "${PRIMARY_PGDATA}" ]] || die "Primary 身份异常: ${identity}"

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_dir="/var/backups/pg-readwrite-proxy-lab/primary-${timestamp}"
mkdir -p -- "${backup_dir}"
chmod 700 "${backup_dir}"
managed_conf="${PRIMARY_PGDATA}/conf.d/99-pg-rw-proxy.conf"
vendor_hba_tmp="${PRIMARY_PGDATA}/hba/pg_hba_tmp.conf"
for file in "${postgresql_conf}" "${pg_hba_conf}" "${PRIMARY_PGDATA}/postgresql.auto.conf" "${managed_conf}" "${vendor_hba_tmp}"; do
  backup_file "${file}" "${backup_dir}"
done
printf '%s\n' "${identity}" >"${backup_dir}/identity-before.txt"
chmod 600 "${backup_dir}/identity-before.txt"
log "Primary 原配置已备份到 ${backup_dir}。"

temp_conf="$(mktemp)"; temp_include="$(mktemp)"; temp_hba="$(mktemp)"; temp_sql="$(mktemp /var/tmp/pg-rw-primary.XXXXXX.sql)"
cleanup() { rm -f -- "${temp_conf}" "${temp_include}" "${temp_hba}" "${temp_sql}"; }
trap cleanup EXIT

render_template "${PROJECT_ROOT}/templates/primary-postgresql.conf.tpl" "${temp_conf}" \
  MAX_WAL_SENDERS "${MAX_WAL_SENDERS}" MAX_REPLICATION_SLOTS "${MAX_REPLICATION_SLOTS}" \
  WAL_KEEP_SEGMENTS "${WAL_KEEP_SEGMENTS}" PRIMARY_LISTEN_ADDRESSES "${PRIMARY_LISTEN_ADDRESSES}"
install -d -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 700 "$(dirname "${managed_conf}")"
install -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 600 "${temp_conf}" "${managed_conf}"
printf "include_if_exists = 'conf.d/99-pg-rw-proxy.conf'\n" >"${temp_include}"
replace_managed_block "${postgresql_conf}" PG_RW_PROXY_INCLUDE "${temp_include}"

render_template "${PROJECT_ROOT}/templates/primary-pg_hba.entries.tpl" "${temp_hba}" \
  REPLICATION_USER "${REPLICATION_USER}" MONITOR_USER "${MONITOR_USER}" \
  BUSINESS_USER "${BUSINESS_USER}" BUSINESS_DATABASE "${BUSINESS_DATABASE}" \
  STANDBY_ADDRESS_CIDR "${STANDBY_ADDRESS_CIDR}" PGPOOL_ADDRESS_CIDR "${PGPOOL_ADDRESS_CIDR}"
# 清除厂商初始配置中无账号且向全网开放的旧复制规则。
sed -Ei '/^[[:space:]]*host[[:space:]]+replication[[:space:]]+repl[[:space:]]+0\.0\.0\.0\/0[[:space:]]+md5([[:space:]]*(#.*)?)?$/d' "${pg_hba_conf}"
replace_managed_block "${pg_hba_conf}" PG_RW_PROXY_HBA "${temp_hba}"
chown "${PG_OS_USER}:${PG_OS_USER}" "${postgresql_conf}" "${pg_hba_conf}"
chmod 600 "${postgresql_conf}" "${pg_hba_conf}"

# PG_Safe_tool 会在 PGDATA/hba 留下 root:root 0600 的临时文件。
# pg_basebackup 的服务端进程必须能读取整个 PGDATA：先备份，再只修复该已知文件。
if [[ -f "${vendor_hba_tmp}" ]]; then
  chown "${PG_OS_USER}:${PG_OS_USER}" "${vendor_hba_tmp}"
  chmod 600 "${vendor_hba_tmp}"
  log "已备份并修复厂商临时 HBA 文件权限: ${vendor_hba_tmp}。"
fi
unreadable_paths="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" find "${PRIMARY_PGDATA}" -xdev \
  \( -type d ! -executable -o -type f ! -readable \) -print 2>/dev/null || true)"
[[ -z "${unreadable_paths}" ]] || die "Primary PGDATA 仍有 postgres 不可读路径，拒绝 pg_basebackup: ${unreadable_paths}"

rep_pass_sql="$(sql_literal "${REPLICATION_PASSWORD}")"
monitor_pass_sql="$(sql_literal "${MONITOR_PASSWORD}")"
cat >"${temp_sql}" <<SQL
\set ON_ERROR_STOP on
SET password_encryption = 'md5';
DO \$block\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${REPLICATION_USER}') THEN
    CREATE ROLE ${REPLICATION_USER};
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${MONITOR_USER}') THEN
    CREATE ROLE ${MONITOR_USER};
  END IF;
END
\$block\$;
ALTER ROLE ${REPLICATION_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT REPLICATION PASSWORD ${rep_pass_sql};
ALTER ROLE ${MONITOR_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION PASSWORD ${monitor_pass_sql};
GRANT pg_monitor TO ${REPLICATION_USER};
GRANT pg_monitor TO ${MONITOR_USER};
GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO ${REPLICATION_USER};
SQL
chmod 600 "${temp_sql}"
nebula_admin_file "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres "${temp_sql}" >/dev/null

business_ok="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
  "select (select count(*) from pg_roles where rolname='${BUSINESS_USER}' and rolcanlogin),(select count(*) from pg_database where datname='${BUSINESS_DATABASE}')")"
[[ "${business_ok}" == '1|1' ]] || die "现有业务账号/库校验失败: ${business_ok}"
probe_ok="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" "${BUSINESS_DATABASE}" \
  "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='business' and c.relname='rw_probe'")"
[[ "${probe_ok}" == '1' ]] || die '业务库缺少验收探针表 business.rw_probe。'

reload_ok="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres 'select pg_reload_conf()')"
[[ "${reload_ok}" == 't' ]] || die 'Primary 配置 reload 失败。'
sleep 1
config_errors="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
  "select count(*) from pg_file_settings where error is not null and not (error='setting could not be applied' and name in ('listen_addresses','cluster_name','wal_level','max_wal_senders','max_replication_slots'))")"
hba_errors="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
  "select count(*) from pg_hba_file_rules where error is not null")"
[[ "${config_errors}" == '0' && "${hba_errors}" == '0' ]] || die "Primary 配置解析失败（postgresql=${config_errors}, hba=${hba_errors}），备份=${backup_dir}。"
declare -A expected_postmaster=(
  [listen_addresses]="${PRIMARY_LISTEN_ADDRESSES}"
  [cluster_name]='rw-primary'
  [wal_level]='replica'
  [max_wal_senders]="${MAX_WAL_SENDERS}"
  [max_replication_slots]="${MAX_REPLICATION_SLOTS}"
)
for setting_name in "${!expected_postmaster[@]}"; do
  parsed_value="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PG_BIN_DIR}/postgres" -D "${PRIMARY_PGDATA}" -C "${setting_name}")"
  [[ "${parsed_value}" == "${expected_postmaster[${setting_name}]}" ]] || \
    die "Primary 待重启参数 ${setting_name} 解析值=${parsed_value}，期望=${expected_postmaster[${setting_name}]}。"
done
grep -Eq '^[[:space:]]*host[[:space:]]+replication[[:space:]]+repl[[:space:]]+0\.0\.0\.0/0' "${pg_hba_conf}" && die '旧的全网 replication HBA 规则仍然存在。'

add_firewall_rule "${STANDBY_ADDRESS_CIDR}" "${PRIMARY_PORT}"
add_firewall_rule "${PGPOOL_ADDRESS_CIDR}" "${PRIMARY_PORT}"
effective_before="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
  "select current_setting('cluster_name'),current_setting('listen_addresses'),current_setting('wal_level'),current_setting('max_wal_senders'),current_setting('max_replication_slots'),current_setting('wal_keep_segments')")"
expected_effective="rw-primary|${PRIMARY_LISTEN_ADDRESSES}|replica|${MAX_WAL_SENDERS}|${MAX_REPLICATION_SLOTS}|${WAL_KEEP_SEGMENTS}"
if [[ "${effective_before}" == "${expected_effective}" ]]; then
  log 'Primary 的需重启参数已生效；本次幂等重跑不再重复重启。'
else
  log '维护窗口门禁已确认，使用厂商 pg_ctl 重启 Primary。'
  pg_ctl_stop "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PGDATA}"
  pg_ctl_start "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PGDATA}" "${PRIMARY_PGDATA}/log/pg-rw-proxy-startup.log"
  wait_for_postgres "${PRIMARY_PG_BIN_DIR}" 127.0.0.1 "${PRIMARY_PORT}" 120 || die "Primary 重启失败；请从 ${backup_dir} 恢复。"
fi
final="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
  "select current_setting('cluster_name'),pg_is_in_recovery(),current_setting('wal_level'),current_setting('max_wal_senders'),current_setting('max_replication_slots'),current_setting('wal_keep_segments')")"
[[ "${final}" == "rw-primary|f|replica|${MAX_WAL_SENDERS}|${MAX_REPLICATION_SLOTS}|${WAL_KEEP_SEGMENTS}" ]] || die "Primary 重启后参数异常: ${final}"
log "Primary 配置完成：${final}。"
