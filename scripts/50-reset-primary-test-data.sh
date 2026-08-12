#!/usr/bin/env bash

set -Eeuo pipefail
cd /tmp

CONFIRM_TOKEN=--confirm-reset-test-data
PG_PREFIX=/opt/pgsql12
PGDATA=/pgsql/12/data
PG_OS_USER=postgres
TEST_ROLE=rw_lab_test
TEST_DATABASE=rw_proxy_lab
TEST_SCHEMA=business
TEST_DATA_SQL=/usr/local/share/pg-readwrite-proxy-lab/primary-test-data.sql
TEST_VERIFY_SQL=/usr/local/share/pg-readwrite-proxy-lab/verify-primary-test-data.sql

usage() {
  printf 'Usage: sudo %s %s\n' "$0" "${CONFIRM_TOKEN}" >&2
}

[[ "${1:-}" == "${CONFIRM_TOKEN}" && "$#" == 1 ]] || {
  usage
  exit 2
}
[[ "$(id -u)" == 0 ]] || {
  printf 'This loader must run as root.\n' >&2
  exit 1
}

instance_ip="$(/sbin/ip -o -4 addr show dev eth1 | awk '{print $4}' | cut -d/ -f1)"
[[ "${instance_ip}" == 192.168.80.110 ]] || {
  printf 'Test data may only be reset on Primary 192.168.80.110.\n' >&2
  exit 1
}

for required_file in \
  "${PG_PREFIX}/bin/postgres" \
  "${PG_PREFIX}/bin/pg_ctl" \
  "${PG_PREFIX}/bin/psql" \
  "${PG_PREFIX}/bin/tools" \
  "${TEST_DATA_SQL}" \
  "${TEST_VERIFY_SQL}"; do
  [[ -f "${required_file}" ]] || {
    printf 'Required file is missing: %s\n' "${required_file}" >&2
    exit 1
  }
done

runuser -u "${PG_OS_USER}" -- "${PG_PREFIX}/bin/pg_ctl" -D "${PGDATA}" status >/dev/null
[[ "$("${PG_PREFIX}/bin/postgres" --version)" == postgres\ \(PostgreSQL\)\ 12.* ]]

admin_query() {
  "${PG_PREFIX}/bin/tools" psql -d "$1" -p 5432 -c "$2"
}

[[ "$(admin_query postgres 'show server_version')" == 12.* ]]
[[ "$(admin_query postgres 'select pg_is_in_recovery()')" == f ]]

role_state="$(admin_query postgres \
  "select rolcanlogin::text || '|' || rolsuper::text || '|' || rolreplication::text from pg_roles where rolname='${TEST_ROLE}'")"
[[ "${role_state}" == 'true|false|false' ]] || {
  printf 'Expected non-superuser login role %s is missing or unsafe.\n' "${TEST_ROLE}" >&2
  exit 1
}

database_owner="$(admin_query postgres \
  "select pg_get_userbyid(datdba) from pg_database where datname='${TEST_DATABASE}'")"
[[ "${database_owner}" == "${TEST_ROLE}" ]] || {
  printf 'Database %s must already exist with owner %s.\n' "${TEST_DATABASE}" "${TEST_ROLE}" >&2
  exit 1
}

active_connections="$(admin_query postgres \
  "select count(*) from pg_stat_activity where datname='${TEST_DATABASE}'")"
[[ "${active_connections}" == 0 ]] || {
  printf '%s has %s active connection(s); refusing reset.\n' "${TEST_DATABASE}" "${active_connections}" >&2
  exit 1
}

sql_sha256="$(sha256sum "${TEST_DATA_SQL}" | awk '{print $1}')"

load_wrapper="$(mktemp /var/tmp/pg-rw-test-load.XXXXXX.sql)"
verify_wrapper="$(mktemp /var/tmp/pg-rw-test-verify.XXXXXX.sql)"
cleanup() { rm -f -- "${load_wrapper}" "${verify_wrapper}"; }
trap cleanup EXIT
cat >"${load_wrapper}" <<SQL
\set ON_ERROR_STOP on
\set dataset_script_sha256 '${sql_sha256}'
SET session_replication_role=replica;
SET ROLE ${TEST_ROLE};
\i ${TEST_DATA_SQL}
SQL
cat >"${verify_wrapper}" <<SQL
\set ON_ERROR_STOP on
SET ROLE ${TEST_ROLE};
\i ${TEST_VERIFY_SQL}
SQL
chmod 600 "${load_wrapper}" "${verify_wrapper}"

set +e
"${PG_PREFIX}/bin/tools" psql -d "${TEST_DATABASE}" -p 5432 -f "${load_wrapper}"
load_status=$?
set -e
if [[ "${load_status}" != 0 ]]; then
  printf 'Dataset generation failed; the previous business schema was preserved by transaction rollback.\n' >&2
  exit "${load_status}"
fi

"${PG_PREFIX}/bin/tools" psql -d "${TEST_DATABASE}" -p 5432 -f "${verify_wrapper}"

actual_orders="$(admin_query "${TEST_DATABASE}" 'select count(*) from business.orders')"
actual_items="$(admin_query "${TEST_DATABASE}" 'select count(*) from business.order_items')"
manifest_sha="$(admin_query "${TEST_DATABASE}" \
  "select generator_sha256 from business.dataset_manifest where dataset_version='business-v1'")"
unexpected_owners="$(admin_query "${TEST_DATABASE}" \
  "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='${TEST_SCHEMA}' and c.relkind in ('r','p','S','i') and pg_get_userbyid(c.relowner) <> '${TEST_ROLE}'")"
schema_owner="$(admin_query "${TEST_DATABASE}" \
  "select pg_get_userbyid(nspowner) from pg_namespace where nspname='${TEST_SCHEMA}'")"
database_size="$(admin_query postgres "select pg_database_size('${TEST_DATABASE}')")"

[[ "${actual_orders}" == 150000 ]]
[[ "${actual_items}" == 450000 ]]
[[ "${manifest_sha}" == "${sql_sha256}" ]]
[[ "${unexpected_owners}" == 0 ]]
[[ "${schema_owner}" == "${TEST_ROLE}" ]]
[[ "${database_size}" -gt 20000000 ]]

printf 'PRIMARY_TEST_DATA_READY\n'
printf 'DATABASE=%s\n' "${TEST_DATABASE}"
printf 'DATABASE_OWNER=%s\n' "${TEST_ROLE}"
printf 'SCHEMA_OWNER=%s\n' "${TEST_ROLE}"
printf 'CUSTOMERS=30000\n'
printf 'PRODUCTS=2000\n'
printf 'ORDERS=%s\n' "${actual_orders}"
printf 'ORDER_ITEMS=%s\n' "${actual_items}"
printf 'TOTAL_BUSINESS_ROWS=632000\n'
printf 'DATABASE_SIZE_BYTES=%s\n' "${database_size}"
printf 'DATASET_SQL_SHA256=%s\n' "${sql_sha256}"
