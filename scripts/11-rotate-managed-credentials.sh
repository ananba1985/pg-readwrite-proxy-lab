#!/usr/bin/env bash

# repair.sh 的受限 Primary 动作：只轮换安装器拥有的复制/监控角色密码，不改业务账号，
# 不修改配置，不 reload/restart 数据库，也不终止现有复制连接。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
verify_nebula_runtime "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_ADMIN_TOOL}" Primary
pg_ctl_is_running "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PGDATA}" || die 'Primary 未运行。'

identity="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
  "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('cluster_name'),
          (select count(*) from pg_roles where rolname='${REPLICATION_USER}' and rolcanlogin and rolreplication),
          (select count(*) from pg_roles where rolname='${MONITOR_USER}' and rolcanlogin and not rolreplication)")"
[[ "${identity}" == '120000|f|rw-primary|1|1' ]] || die "Primary 身份或受管角色异常: ${identity}"

temp_sql="$(mktemp /var/tmp/pg-rw-credential-rotation.XXXXXX.sql)"
cleanup() { rm -f -- "${temp_sql}"; }
trap cleanup EXIT
rep_pass_sql="$(sql_literal "${REPLICATION_PASSWORD}")"
monitor_pass_sql="$(sql_literal "${MONITOR_PASSWORD}")"
cat >"${temp_sql}" <<SQL
\set ON_ERROR_STOP on
\set VERBOSITY verbose
\set SHOW_CONTEXT always
SET password_encryption = 'md5';
ALTER ROLE ${REPLICATION_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT REPLICATION PASSWORD ${rep_pass_sql};
ALTER ROLE ${MONITOR_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION PASSWORD ${monitor_pass_sql};
GRANT pg_monitor TO ${REPLICATION_USER};
GRANT pg_monitor TO ${MONITOR_USER};
GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO ${REPLICATION_USER};
SQL
chmod 600 "${temp_sql}"
nebula_admin_file "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres "${temp_sql}" >/dev/null
printf 'MANAGED_CREDENTIAL_RESULT=ROTATED roles=replication,monitor database_restart=no replication_connection_terminated=no\n'
