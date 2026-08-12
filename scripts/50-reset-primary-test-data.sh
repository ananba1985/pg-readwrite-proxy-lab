#!/usr/bin/env bash

set -Eeuo pipefail
cd /tmp

CONFIRM_TOKEN=--confirm-reset-test-data
PG_PREFIX=/opt/pgsql12
TEST_DATABASE=rw_proxy_lab
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
systemctl is-active --quiet postgresql-12
[[ "$(${PG_PREFIX}/bin/postgres --version)" == 'postgres (PostgreSQL) 12.22' ]]
[[ "$(runuser -u postgres -- ${PG_PREFIX}/bin/psql -XAtq -d postgres -c 'select pg_is_in_recovery()')" == f ]]
[[ -f "${TEST_DATA_SQL}" ]]
[[ -f "${TEST_VERIFY_SQL}" ]]

sql_sha256="$(sha256sum "${TEST_DATA_SQL}" | awk '{print $1}')"
active_connections="$(runuser -u postgres -- "${PG_PREFIX}/bin/psql" -XAtq -d postgres \
  -c "select count(*) from pg_stat_activity where datname='${TEST_DATABASE}'")"
[[ "${active_connections}" == 0 ]] || {
  printf '%s has %s active connection(s); refusing reset.\n' "${TEST_DATABASE}" "${active_connections}" >&2
  exit 1
}

runuser -u postgres -- "${PG_PREFIX}/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres \
  -c "DROP DATABASE IF EXISTS ${TEST_DATABASE}"
runuser -u postgres -- "${PG_PREFIX}/bin/createdb" \
  --owner=postgres \
  --encoding=UTF8 \
  --locale=C \
  --template=template0 \
  "${TEST_DATABASE}"

set +e
runuser -u postgres -- "${PG_PREFIX}/bin/psql" \
  -X \
  -v ON_ERROR_STOP=1 \
  -v "dataset_script_sha256=${sql_sha256}" \
  -d "${TEST_DATABASE}" \
  -f "${TEST_DATA_SQL}"
load_status=$?
set -e
if [[ "${load_status}" != 0 ]]; then
  printf 'Dataset generation failed; removing incomplete test database.\n' >&2
  runuser -u postgres -- "${PG_PREFIX}/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres \
    -c "DROP DATABASE IF EXISTS ${TEST_DATABASE}" || true
  exit "${load_status}"
fi

runuser -u postgres -- "${PG_PREFIX}/bin/psql" \
  -X \
  -v ON_ERROR_STOP=1 \
  -d "${TEST_DATABASE}" \
  -f "${TEST_VERIFY_SQL}"

actual_orders="$(runuser -u postgres -- "${PG_PREFIX}/bin/psql" -XAtq -d "${TEST_DATABASE}" \
  -c 'select count(*) from business.orders')"
actual_items="$(runuser -u postgres -- "${PG_PREFIX}/bin/psql" -XAtq -d "${TEST_DATABASE}" \
  -c 'select count(*) from business.order_items')"
manifest_sha="$(runuser -u postgres -- "${PG_PREFIX}/bin/psql" -XAtq -d "${TEST_DATABASE}" \
  -c "select generator_sha256 from business.dataset_manifest where dataset_version='business-v1'")"
database_size="$(runuser -u postgres -- "${PG_PREFIX}/bin/psql" -XAtq -d postgres \
  -c "select pg_database_size('${TEST_DATABASE}')")"

[[ "${actual_orders}" == 150000 ]]
[[ "${actual_items}" == 450000 ]]
[[ "${manifest_sha}" == "${sql_sha256}" ]]
[[ "${database_size}" -gt 20000000 ]]

printf 'PRIMARY_TEST_DATA_READY\n'
printf 'DATABASE=%s\n' "${TEST_DATABASE}"
printf 'CUSTOMERS=30000\n'
printf 'PRODUCTS=2000\n'
printf 'ORDERS=%s\n' "${actual_orders}"
printf 'ORDER_ITEMS=%s\n' "${actual_items}"
printf 'TOTAL_BUSINESS_ROWS=632000\n'
printf 'DATABASE_SIZE_BYTES=%s\n' "${database_size}"
printf 'DATASET_SQL_SHA256=%s\n' "${sql_sha256}"
