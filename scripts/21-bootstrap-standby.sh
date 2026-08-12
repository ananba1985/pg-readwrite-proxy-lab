#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
require_command runuser
require_command systemctl
assert_safe_pgdata "${STANDBY_PGDATA}"

for binary in pg_basebackup psql pg_isready; do
  [[ -x "${STANDBY_PG_BIN_DIR}/${binary}" ]] || die "找不到 ${STANDBY_PG_BIN_DIR}/${binary}；请先执行 20-install-postgresql-standby.sh。"
done

export PGPASSWORD="${REPLICATION_PASSWORD}"
primary_psql=("${STANDBY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}" -d postgres)
primary_recovery="$("${primary_psql[@]}" -c 'select pg_is_in_recovery()')"
[[ "${primary_recovery}" == 'f' ]] || die '远端 Primary 报告为恢复态，拒绝初始化 Standby。'
primary_version_num="$("${primary_psql[@]}" -c 'show server_version_num')"
[[ "$((primary_version_num / 10000))" == "${PG_MAJOR}" ]] || die 'Primary 大版本与 PG_MAJOR 不一致。'
primary_version_full="$("${primary_psql[@]}" -c "select substring(current_setting('server_version') from '^[0-9]+\\.[0-9]+')")"
[[ "${primary_version_full}" == "${PG_VERSION_FULL}" ]] || die "Primary 版本=${primary_version_full}，配置=${PG_VERSION_FULL}。"
standby_binary_version="$(${STANDBY_PG_BIN_DIR}/postgres --version | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1)"
[[ "${standby_binary_version}" == "${PG_VERSION_FULL}" ]] || die "Standby 二进制=${standby_binary_version}，Primary=${PG_VERSION_FULL}。"
primary_wal_level="$("${primary_psql[@]}" -c 'show wal_level')"
[[ "${primary_wal_level}" =~ ^(replica|logical)$ ]] || die "Primary wal_level=${primary_wal_level}，尚不能流复制。"

primary_block_bytes="$("${primary_psql[@]}" -c "select current_setting('block_size')")"
primary_wal_block_bytes="$("${primary_psql[@]}" -c "select current_setting('wal_block_size')")"
primary_wal_segment_bytes="$("${primary_psql[@]}" -c "select current_setting('wal_segment_size')")"
[[ "$((primary_block_bytes / 1024))" == "${PG_BLOCK_SIZE_KB}" ]] || die 'Primary block_size 与 Standby 构建参数不一致。'
[[ "$((primary_wal_block_bytes / 1024))" == "${PG_WAL_BLOCK_SIZE_KB}" ]] || die 'Primary wal_block_size 与 Standby 构建参数不一致。'
[[ "$((primary_wal_segment_bytes / 1024 / 1024))" == "${PG_WAL_SEG_SIZE_MB}" ]] || die 'Primary wal_segment_size 与 Standby 构建参数不一致。'

required_preload="$("${primary_psql[@]}" -c "show shared_preload_libraries")"
if [[ -n "${required_preload}" ]]; then
  pkglibdir="$(${STANDBY_PG_BIN_DIR}/pg_config --pkglibdir)"
  IFS=',' read -r -a preload_libraries <<<"${required_preload}"
  for library in "${preload_libraries[@]}"; do
    library="$(trim "${library}")"
    library="${library#\$libdir/}"
    [[ -f "${pkglibdir}/${library}.so" || -f "${pkglibdir}/${library}" ]] || \
      die "Standby 缺少 Primary shared_preload_libraries 运行库: ${library}（${pkglibdir}）。"
  done
fi

required_extensions="$("${primary_psql[@]}" -c "select extname from pg_extension where extname <> 'plpgsql' order by 1")"
if [[ -n "${required_extensions}" ]]; then
  extension_dir="$(${STANDBY_PG_BIN_DIR}/pg_config --sharedir)/extension"
  while IFS= read -r extension_name; do
    [[ -f "${extension_dir}/${extension_name}.control" ]] || \
      die "Standby 缺少 Primary 已安装扩展的 control 文件: ${extension_name}（${extension_dir}）。"
  done <<<"${required_extensions}"
fi

tablespace_rows="$("${primary_psql[@]}" -c "select spcname || '|' || pg_tablespace_location(oid) from pg_tablespace where pg_tablespace_location(oid) <> '' order by 1")"
if [[ -n "${tablespace_rows}" ]]; then
  while IFS='|' read -r tablespace_name tablespace_path; do
    [[ -d "${tablespace_path}" && -w "${tablespace_path}" ]] || \
      die "Primary 表空间 ${tablespace_name} 要求 Standby 预先挂载可写路径 ${tablespace_path}。"
  done <<<"${tablespace_rows}"
fi

log "Primary 可访问，版本=$(${STANDBY_PG_BIN_DIR}/psql --version)，wal_level=${primary_wal_level}。"
estimated_bytes="$("${primary_psql[@]}" -c "select coalesce(sum(pg_database_size(datname)),0) from pg_database where datallowconn")"
available_bytes="$(df -PB1 "$(dirname "${STANDBY_PGDATA}")" | awk 'NR==2 {print $4}')"
log "数据库逻辑体量约 ${estimated_bytes} bytes；Standby 目标文件系统可用 ${available_bytes} bytes（仅作预估，仍需预留 WAL 和增长空间）。"
((available_bytes > estimated_bytes * 12 / 10)) || die 'Standby 可用空间不足数据库逻辑体量的 120%，拒绝开始基础备份。'

systemctl stop "${STANDBY_SERVICE}" >/dev/null 2>&1 || true
timestamp="$(date '+%Y%m%d-%H%M%S')"
if [[ -d "${STANDBY_PGDATA}" ]] && find "${STANDBY_PGDATA}" -mindepth 1 -print -quit | grep -q .; then
  [[ "${ALLOW_STANDBY_REINITIALIZE}" == 'yes' ]] || \
    die "${STANDBY_PGDATA} 非空。确认可移动备份后，将 ALLOW_STANDBY_REINITIALIZE=yes。"
  backup_parent="/var/backups/pg-rw-proxy"
  mkdir -p -- "${backup_parent}"
  backup_target="${backup_parent}/standby-pgdata-${timestamp}"
  resolved_pgdata="$(readlink -f "${STANDBY_PGDATA}")"
  resolved_parent="$(readlink -f "$(dirname "${STANDBY_PGDATA}")")"
  [[ "${resolved_pgdata}" == "${resolved_parent}/"* ]] || die 'Standby PGDATA 解析结果超出预期父目录。'
  mv -- "${STANDBY_PGDATA}" "${backup_target}"
  log "原 Standby 数据目录已移动到 ${backup_target}（可恢复，未删除）。"
fi

install -d -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 700 "${STANDBY_PGDATA}"

slot_count="$("${primary_psql[@]}" -c "select count(*) from pg_replication_slots where slot_name = '$(printf '%s' "${REPLICATION_SLOT_NAME}" | sed "s/'/''/g")' and slot_type = 'physical'")"
slot_args=(--slot="${REPLICATION_SLOT_NAME}")
if [[ "${slot_count}" == '0' ]]; then
  slot_args+=(--create-slot)
  log "将创建物理复制槽 ${REPLICATION_SLOT_NAME}。"
else
  active_count="$("${primary_psql[@]}" -c "select count(*) from pg_replication_slots where slot_name = '$(printf '%s' "${REPLICATION_SLOT_NAME}" | sed "s/'/''/g")' and active")"
  [[ "${active_count}" == '0' ]] || die "复制槽 ${REPLICATION_SLOT_NAME} 正在被使用，拒绝复用。"
  warn "将复用现有未激活复制槽 ${REPLICATION_SLOT_NAME}。"
fi

log '开始 pg_basebackup；耗时取决于主库体量和网络带宽。'
run_as_pg "${STANDBY_PG_BIN_DIR}" "${STANDBY_PG_BIN_DIR}/pg_basebackup" \
  --host="${PRIMARY_HOST}" --port="${PRIMARY_PORT}" --username="${REPLICATION_USER}" \
  --pgdata="${STANDBY_PGDATA}" --wal-method=stream --checkpoint=fast --progress --verbose \
  "${slot_args[@]}"

[[ -f "${STANDBY_PGDATA}/postgresql.conf" ]] || die '基础备份中没有 postgresql.conf；当前主库不是标准 PGDATA 内配置布局，需要单独适配。'
touch "${STANDBY_PGDATA}/standby.signal"

postgres_home="$(getent passwd "${PG_OS_USER}" | cut -d: -f6)"
[[ -n "${postgres_home}" && "${postgres_home}" == /* ]] || die "无法确定 ${PG_OS_USER} 的 HOME。"
passfile="${postgres_home}/.pgpass-rw-proxy"
umask 077
printf '%s:%s:replication:%s:%s\n' "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${REPLICATION_USER}" "${REPLICATION_PASSWORD}" >"${passfile}"
chown "${PG_OS_USER}:${PG_OS_USER}" "${passfile}"
chmod 600 "${passfile}"

auto_conf="${STANDBY_PGDATA}/postgresql.auto.conf"
touch "${auto_conf}"
temp_recovery="$(mktemp)"
temp_standby_conf="$(mktemp)"
cleanup() {
  rm -f -- "${temp_recovery}" "${temp_standby_conf}"
}
trap cleanup EXIT
cat >"${temp_recovery}" <<RECOVERY
primary_conninfo = 'host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPLICATION_USER} application_name=${STANDBY_APPLICATION_NAME} passfile=${passfile}'
primary_slot_name = '${REPLICATION_SLOT_NAME}'
RECOVERY
replace_managed_block "${auto_conf}" 'PG_RW_PROXY_RECOVERY' "${temp_recovery}"

mkdir -p "${STANDBY_PGDATA}/conf.d"
render_template "${PROJECT_ROOT}/templates/standby-postgresql.conf.tpl" "${temp_standby_conf}" \
  STANDBY_LISTEN_ADDRESSES "${STANDBY_LISTEN_ADDRESSES}" \
  STANDBY_PORT "${STANDBY_PORT}"
install -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 600 "${temp_standby_conf}" "${STANDBY_PGDATA}/conf.d/99-pg-rw-proxy.conf"

if ! grep -Fq "# BEGIN PG_RW_PROXY_INCLUDE" "${STANDBY_PGDATA}/postgresql.conf"; then
  temp_include="$(mktemp)"
  printf "include_if_exists = 'conf.d/99-pg-rw-proxy.conf'\n" >"${temp_include}"
  replace_managed_block "${STANDBY_PGDATA}/postgresql.conf" 'PG_RW_PROXY_INCLUDE' "${temp_include}"
  rm -f -- "${temp_include}"
fi

chown -R "${PG_OS_USER}:${PG_OS_USER}" "${STANDBY_PGDATA}"
chmod 700 "${STANDBY_PGDATA}"
add_firewall_rule "${PGPOOL_ADDRESS_CIDR}" "${STANDBY_PORT}"

systemctl enable "${STANDBY_SERVICE}" >/dev/null
systemctl start "${STANDBY_SERVICE}"
wait_for_postgres "${STANDBY_PG_BIN_DIR}" '127.0.0.1' "${STANDBY_PORT}" 120 || die 'Standby 未在 120 秒内就绪。'

standby_recovery="$(run_as_pg "${STANDBY_PG_BIN_DIR}" "${STANDBY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 -p "${STANDBY_PORT}" -d postgres -c 'select pg_is_in_recovery()')"
[[ "${standby_recovery}" == 't' ]] || die 'Standby 启动后不在恢复态，立即停止并排查，禁止继续接入 Pgpool。'

receiver_status="$(run_as_pg "${STANDBY_PG_BIN_DIR}" "${STANDBY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 -p "${STANDBY_PORT}" -d postgres -c "select coalesce(status,'') from pg_stat_wal_receiver limit 1")"
[[ "${receiver_status}" == 'streaming' ]] || die "Standby wal receiver 状态=${receiver_status:-空}，未进入 streaming。"
unset PGPASSWORD
log 'Standby 已由 Primary 基础备份初始化，并进入 streaming 恢复态。'
