#!/usr/bin/env bash

# Destructively reset one database VM to a freshly initialized, independent
# PostgreSQL 12.22 instance. This deliberately does not configure replication.

set -Eeuo pipefail
cd /tmp

CONFIRM_TOKEN=--confirm-reset
PG_PREFIX=/opt/pgsql12
PGDATA=/pgsql/12/data
PG_SERVICE=postgresql-12
PG_ARCHIVE=/var/tmp/postgresql-12.22-aarch64-prefix-20260812.tar.gz
PG_ARCHIVE_SHA256=e57c280930b9b7f6fc4973bec7b4ce6239eed4dcb7849781fb6d16f7a980ac4a

usage() {
  printf 'Usage: sudo %s %s\n' "$0" "${CONFIRM_TOKEN}" >&2
}

[[ "${1:-}" == "${CONFIRM_TOKEN}" && "$#" == 1 ]] || {
  usage
  exit 2
}
[[ "$(id -u)" == 0 ]] || {
  printf 'This reset must run as root.\n' >&2
  exit 1
}
[[ "$(uname -m)" == aarch64 ]] || {
  printf 'This reset package is only valid on aarch64.\n' >&2
  exit 1
}

instance_ip="$(/sbin/ip -o -4 addr show dev eth1 | awk '{print $4}' | cut -d/ -f1)"
case "${instance_ip}" in
  192.168.80.110)
    cluster_name=rw-primary-independent
    ;;
  192.168.80.120)
    cluster_name=rw-secondary-independent
    ;;
  *)
    printf 'Refusing reset on unexpected eth1 address: %s\n' "${instance_ip:-missing}" >&2
    exit 1
    ;;
esac

[[ "${PG_PREFIX}" == /opt/pgsql12 ]]
[[ "${PGDATA}" == /pgsql/12/data ]]
[[ "$(readlink -f /opt)" == /opt ]]
[[ "$(readlink -f /pgsql/12)" == /pgsql/12 ]]
[[ ! -L "${PG_PREFIX}" ]]
[[ ! -L "${PGDATA}" ]]
[[ "$(findmnt -n -o TARGET /pgsql)" == /pgsql ]]
[[ "$(findmnt -n -o FSTYPE /pgsql)" == xfs ]]

[[ -f "${PG_ARCHIVE}" ]] || {
  printf 'Validated PostgreSQL archive is missing: %s\n' "${PG_ARCHIVE}" >&2
  exit 1
}
actual_archive_sha="$(sha256sum "${PG_ARCHIVE}" | awk '{print $1}')"
[[ "${actual_archive_sha}" == "${PG_ARCHIVE_SHA256}" ]] || {
  printf 'PostgreSQL archive checksum mismatch.\n' >&2
  exit 1
}
archive_manifest="$(mktemp)"
trap 'rm -f -- "${archive_manifest}"' EXIT
tar -tzf "${PG_ARCHIVE}" >"${archive_manifest}"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "${archive_manifest}"; then
  printf 'Unsafe path found in PostgreSQL archive.\n' >&2
  exit 1
fi
grep -Eq '^pgsql12/bin/postgres$' "${archive_manifest}"
grep -Eq '^pgsql12/bin/initdb$' "${archive_manifest}"

timestamp="$(date '+%Y%m%d-%H%M%S')"
audit_dir="/var/backups/pg-readwrite-proxy-lab/independent-reset-${instance_ip}-${timestamp}"
install -d -o root -g root -m 0700 "${audit_dir}"
if [[ -f "${PGDATA}/PG_VERSION" ]]; then
  for config_file in postgresql.conf postgresql.auto.conf pg_hba.conf; do
    [[ ! -f "${PGDATA}/${config_file}" ]] || cp -a "${PGDATA}/${config_file}" "${audit_dir}/"
  done
  if [[ -x "${PG_PREFIX}/bin/pg_controldata" ]]; then
    runuser -u postgres -- "${PG_PREFIX}/bin/pg_controldata" "${PGDATA}" \
      >"${audit_dir}/pg_controldata-before-reset.txt" 2>&1 || true
  fi
fi
[[ ! -f /etc/systemd/system/postgresql-12.service ]] || \
  cp -a /etc/systemd/system/postgresql-12.service "${audit_dir}/"

systemctl stop "${PG_SERVICE}" 2>/dev/null || true
! systemctl is-active --quiet "${PG_SERVICE}" 2>/dev/null
systemctl disable "${PG_SERVICE}" >/dev/null 2>&1 || true
if pgrep -u postgres -x postgres >/dev/null 2>&1; then
  printf 'A postgres process is still running; refusing filesystem deletion.\n' >&2
  pgrep -a -u postgres -x postgres >&2
  exit 1
fi
tcp_listeners="$(ss -ltn)"
if grep -q ':5432[[:space:]]' <<<"${tcp_listeners}"; then
  printf 'TCP 5432 is still in use; refusing filesystem deletion.\n' >&2
  exit 1
fi

# Exact, prevalidated reset targets. No glob or environment-derived path is used.
if [[ -e /pgsql/12/data ]]; then
  rm -rf --one-file-system -- /pgsql/12/data
fi
if [[ -e /opt/pgsql12 ]]; then
  rm -rf --one-file-system -- /opt/pgsql12
fi
rm -f -- /var/lib/pgsql/.pgpass /var/lib/pgsql/.rw-replicator-bootstrap-secret
[[ ! -e /pgsql/12/data ]]
[[ ! -e /opt/pgsql12 ]]

if ! getent group postgres >/dev/null; then
  groupadd --system postgres
fi
if ! id postgres >/dev/null 2>&1; then
  useradd --system --gid postgres --home-dir /var/lib/pgsql --create-home --shell /bin/bash postgres
fi
install -d -o postgres -g postgres -m 0700 /var/lib/pgsql /pgsql/12

tar -C /opt --numeric-owner -xzf "${PG_ARCHIVE}"
chown -R root:root "${PG_PREFIX}"
chmod 0755 "${PG_PREFIX}" "${PG_PREFIX}/bin"
for binary in postgres initdb psql pg_ctl pg_isready; do
  [[ -x "${PG_PREFIX}/bin/${binary}" ]]
  ldd_output="$(ldd "${PG_PREFIX}/bin/${binary}")"
  if grep -q 'not found' <<<"${ldd_output}"; then
    printf 'Unresolved runtime library for %s.\n' "${binary}" >&2
    exit 1
  fi
done
[[ "$(${PG_PREFIX}/bin/postgres --version)" == 'postgres (PostgreSQL) 12.22' ]]

install -d -o postgres -g postgres -m 0700 "${PGDATA}"
runuser -u postgres -- "${PG_PREFIX}/bin/initdb" \
  -D "${PGDATA}" \
  --encoding=UTF8 \
  --locale=C \
  --auth-local=peer \
  --auth-host=scram-sha-256 \
  --data-checksums

install -d -o postgres -g postgres -m 0700 "${PGDATA}/conf.d" "${PGDATA}/log"
cat >"${PGDATA}/conf.d/99-independent-install.conf" <<CONF
# Fresh independent-install baseline. Replication is intentionally not configured.
listen_addresses = '127.0.0.1,${instance_ip}'
port = 5432
cluster_name = '${cluster_name}'
password_encryption = 'scram-sha-256'

logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = '1d'
log_truncate_on_rotation = on
log_line_prefix = '%m [%p] %q%u@%d '

timezone = 'Asia/Shanghai'
log_timezone = 'Asia/Shanghai'
CONF
printf "\n# Managed independent-install baseline\ninclude_if_exists = 'conf.d/99-independent-install.conf'\n" \
  >>"${PGDATA}/postgresql.conf"

cat >"${PGDATA}/pg_hba.conf" <<'HBA'
# TYPE  DATABASE  USER  ADDRESS             METHOD
local   all       all                       peer
host    all       all   127.0.0.1/32        scram-sha-256
host    all       all   ::1/128             scram-sha-256

# Fixed-IP lab access only. Replication rules are intentionally absent.
host    all       all   192.168.80.110/32    scram-sha-256
host    all       all   192.168.80.120/32    scram-sha-256
host    all       all   192.168.80.130/32    scram-sha-256
HBA

chown postgres:postgres \
  "${PGDATA}/postgresql.conf" \
  "${PGDATA}/postgresql.auto.conf" \
  "${PGDATA}/pg_hba.conf" \
  "${PGDATA}/conf.d/99-independent-install.conf"
chmod 0600 \
  "${PGDATA}/postgresql.conf" \
  "${PGDATA}/postgresql.auto.conf" \
  "${PGDATA}/pg_hba.conf" \
  "${PGDATA}/conf.d/99-independent-install.conf"

cat >/etc/systemd/system/postgresql-12.service <<'UNIT'
[Unit]
Description=PostgreSQL 12 independent database server (community build)
Documentation=https://www.postgresql.org/docs/12/
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGDATA=/pgsql/12/data
Environment=HOME=/var/lib/pgsql
ExecStartPre=/usr/bin/test -f /pgsql/12/data/PG_VERSION
ExecStart=/opt/pgsql12/bin/pg_ctl start -D ${PGDATA} -s -w -t 90 -l ${PGDATA}/log/startup.log
ExecStop=/opt/pgsql12/bin/pg_ctl stop -D ${PGDATA} -s -m fast -w -t 90
ExecReload=/opt/pgsql12/bin/pg_ctl reload -D ${PGDATA} -s
TimeoutStartSec=120
TimeoutStopSec=120
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
chown root:root /etc/systemd/system/postgresql-12.service
chmod 0644 /etc/systemd/system/postgresql-12.service
systemctl daemon-reload
systemctl enable --now "${PG_SERVICE}"

if systemctl is-active --quiet firewalld && command -v firewall-cmd >/dev/null 2>&1; then
  for source_ip in 192.168.80.110 192.168.80.120 192.168.80.130; do
    rule="rule family=ipv4 source address=${source_ip}/32 port port=5432 protocol=tcp accept"
    firewall-cmd --permanent --query-rich-rule="${rule}" >/dev/null || \
      firewall-cmd --permanent --add-rich-rule="${rule}" >/dev/null
  done
  firewall-cmd --reload >/dev/null
fi

runuser -u postgres -- "${PG_PREFIX}/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres <<'SQL'
SELECT version();
SELECT pg_is_in_recovery() AS is_in_recovery;
SELECT count(*) AS configuration_errors FROM pg_file_settings WHERE error IS NOT NULL;
SELECT count(*) AS hba_errors FROM pg_hba_file_rules WHERE error IS NOT NULL;
SELECT count(*) AS replication_slots FROM pg_replication_slots;
SELECT count(*) AS wal_receivers FROM pg_stat_wal_receiver;
SELECT count(*) AS dedicated_replication_roles FROM pg_roles WHERE rolname = 'rw_replicator';
BEGIN;
CREATE TABLE independent_reset_smoke_test(id integer PRIMARY KEY, note text NOT NULL);
INSERT INTO independent_reset_smoke_test VALUES (1, 'fresh-independent-install');
SELECT count(*) AS smoke_rows FROM independent_reset_smoke_test;
ROLLBACK;
SQL

[[ "$(runuser -u postgres -- ${PG_PREFIX}/bin/psql -XAtq -d postgres -c 'select pg_is_in_recovery()')" == f ]]
[[ "$(runuser -u postgres -- ${PG_PREFIX}/bin/psql -XAtq -d postgres -c 'select count(*) from pg_replication_slots')" == 0 ]]
[[ "$(runuser -u postgres -- ${PG_PREFIX}/bin/psql -XAtq -d postgres -c 'select count(*) from pg_stat_wal_receiver')" == 0 ]]
[[ "$(runuser -u postgres -- ${PG_PREFIX}/bin/psql -XAtq -d postgres -c "select count(*) from pg_roles where rolname='rw_replicator'")" == 0 ]]
[[ "$(runuser -u postgres -- ${PG_PREFIX}/bin/psql -XAtq -d postgres -c "select count(*) from pg_hba_file_rules where error is not null")" == 0 ]]
[[ "$(grep -Ec '^[[:space:]]*host[[:space:]]+replication' "${PGDATA}/pg_hba.conf")" == 0 ]]
[[ ! -e "${PGDATA}/standby.signal" ]]
[[ ! -e "${PGDATA}/recovery.signal" ]]
[[ ! -e /var/lib/pgsql/.pgpass ]]
systemctl is-active --quiet "${PG_SERVICE}"
systemctl is-enabled --quiet "${PG_SERVICE}"

system_identifier="$(runuser -u postgres -- "${PG_PREFIX}/bin/pg_controldata" "${PGDATA}" \
  | awk -F: '/Database system identifier/ {gsub(/[[:space:]]/, "", $2); print $2}')"
printf 'INDEPENDENT_PG12_RESET_OK\n'
printf 'INSTANCE_IP=%s\n' "${instance_ip}"
printf 'CLUSTER_NAME=%s\n' "${cluster_name}"
printf 'SYSTEM_IDENTIFIER=%s\n' "${system_identifier}"
printf 'PREVIOUS_CONFIG_AUDIT=%s\n' "${audit_dir}"
printf 'PG_ARCHIVE_SHA256=%s\n' "${actual_archive_sha}"
