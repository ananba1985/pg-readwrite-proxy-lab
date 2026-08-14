#!/usr/bin/env bash

# repair.sh 的受限 Standby 动作：只更新 postgres 私有复制密码文件，不停止或重启数据库。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
verify_nebula_runtime "${STANDBY_PG_BIN_DIR}" "${STANDBY_ADMIN_TOOL}" Standby
assert_safe_pgdata "${STANDBY_PGDATA}"
[[ -f "${STANDBY_PGDATA}/PG_VERSION" && "$(tr -d '\r\n' <"${STANDBY_PGDATA}/PG_VERSION")" == '12' ]] || \
  die 'Standby PGDATA 不完整，拒绝写入复制密码文件。'

postgres_home="$(getent passwd "${PG_OS_USER}" | cut -d: -f6)"
[[ -n "${postgres_home}" && "${postgres_home}" == /* && -d "${postgres_home}" && ! -L "${postgres_home}" ]] || \
  die "无法确定 ${PG_OS_USER} HOME。"
[[ "$(stat -c '%U' "${postgres_home}")" == "${PG_OS_USER}" ]] || die "${PG_OS_USER} HOME 所有者异常。"
passfile="${postgres_home}/.pgpass-rw-proxy"
temp_passfile="$(mktemp "${postgres_home}/.pgpass-rw-proxy.XXXXXX")"
cleanup() { rm -f -- "${temp_passfile}"; }
trap cleanup EXIT
printf '%s:%s:replication:%s:%s\n' \
  "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${REPLICATION_USER}" "${REPLICATION_PASSWORD}" >"${temp_passfile}"
chown "${PG_OS_USER}:${PG_OS_USER}" "${temp_passfile}"
chmod 600 "${temp_passfile}"
mv -f -- "${temp_passfile}" "${passfile}"
printf 'STANDBY_PASSFILE_RESULT=UPDATED database_restart=no basebackup=not_run\n'
