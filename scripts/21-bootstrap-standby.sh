#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
load_secrets
require_command runuser
assert_safe_pgdata "${STANDBY_PGDATA}"
verify_nebula_runtime "${STANDBY_PG_BIN_DIR}" "${STANDBY_ADMIN_TOOL}" 'Standby 目标机'
[[ "${ALLOW_STANDBY_REINITIALIZE}" == 'yes' ]] || die 'Standby 初始化需要显式维护窗口授权：ALLOW_STANDBY_REINITIALIZE=yes。'

export PGPASSWORD="${REPLICATION_PASSWORD}"
primary_psql=("${STANDBY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}" -d postgres)
primary="$("${primary_psql[@]}" -c "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('wal_level'),current_setting('max_wal_senders'),current_setting('max_replication_slots'),current_setting('block_size'),current_setting('wal_block_size'),current_setting('wal_segment_size')")"
IFS='|' read -r version_num recovery wal_level wal_senders replication_slots block_size wal_block_size wal_segment_size <<<"${primary}"
[[ "${version_num}" == '120000' && "${recovery}" == 'f' && "${wal_level}" == 'replica' ]] || die "远端 Primary 参数异常: ${primary}"
((wal_senders >= MAX_WAL_SENDERS)) || die "Primary max_wal_senders=${wal_senders} 低于要求。"
((replication_slots >= MAX_REPLICATION_SLOTS)) || die "Primary max_replication_slots=${replication_slots} 低于要求。"
[[ "${block_size}" == '8192' && "${wal_block_size}" == '8192' && "${wal_segment_size}" == '16MB' ]] || die "Primary 存储构建参数异常: ${primary}"
primary_system_id="$("${primary_psql[@]}" -c 'select system_identifier from pg_control_system()')"
[[ "${primary_system_id}" =~ ^[0-9]+$ ]] || die "无法读取 Primary system identifier: ${primary_system_id}"

export PGPASSWORD="${BUSINESS_PASSWORD}"
business_probe="$("${STANDBY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" \
  -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" -c "select current_user,(to_regclass('business.rw_probe') is not null)::text")"
[[ "${business_probe}" == "${BUSINESS_USER}|true" ]] || die "现有业务凭据或探针表验证失败: ${business_probe}"
export PGPASSWORD="${REPLICATION_PASSWORD}"

custom_tablespaces="$("${primary_psql[@]}" -c "select count(*) from pg_tablespace where pg_tablespace_location(oid) <> ''")"
[[ "${custom_tablespaces}" == '0' ]] || die 'Primary 存在自定义表空间；当前最小安装器不猜测 Standby 表空间映射，已安全停止。'

existing_recovery='f'
if pg_ctl_is_running "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"; then
  enforce_restart_connection_policy Standby "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" '实际变更前'
  existing_recovery="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres 'select pg_is_in_recovery()')"
fi
if [[ "${existing_recovery}" == 't' ]]; then
  standby_system_id="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres 'select system_identifier from pg_control_system()')"
  [[ "${standby_system_id}" == "${primary_system_id}" ]] || \
    die "现有恢复节点 system identifier=${standby_system_id}，不属于目标 Primary=${primary_system_id}，拒绝复用。"
fi

state_dir='/var/lib/pg-rw-proxy-installer'
state_file="${state_dir}/standby-bootstrap.state"
install -d -m 700 "${state_dir}"
timestamp="$(date '+%Y%m%d-%H%M%S')"

if [[ "${existing_recovery}" != 't' ]]; then
  estimated_bytes="$("${primary_psql[@]}" -c "select coalesce(sum(pg_database_size(datname)),0) from pg_database where datallowconn")"
  available_bytes="$(df -PB1 "$(dirname "${STANDBY_PGDATA}")" | awk 'NR==2 {print $4}')"
  ((available_bytes > estimated_bytes * 2)) || die 'Standby 可用空间不足数据库逻辑体量的 200%，拒绝基础备份。'

  if pg_ctl_is_running "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"; then
    enforce_restart_connection_policy Standby "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" '数据库停机前'
    pg_ctl_stop "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"
  fi
  if [[ -d "${STANDBY_PGDATA}" ]] && find "${STANDBY_PGDATA}" -mindepth 1 -print -quit | grep -q .; then
    backup_parent='/var/backups/pg-readwrite-proxy-lab'
    mkdir -p -- "${backup_parent}"
    if [[ -f "${state_file}" ]]; then
      validate_standby_resume_state
      backup_target="${backup_parent}/standby-partial-pgdata-${timestamp}"
      state_key='partial_pgdata'
    else
      backup_target="${backup_parent}/standby-pgdata-${timestamp}"
      state_key='original_pgdata'
    fi
    resolved_pgdata="$(readlink -f "${STANDBY_PGDATA}")"
    resolved_parent="$(readlink -f "$(dirname "${STANDBY_PGDATA}")")"
    [[ "${resolved_pgdata}" == "${resolved_parent}/"* ]] || die 'Standby PGDATA 解析结果超出预期父目录。'
    mv -- "${STANDBY_PGDATA}" "${backup_target}"
    printf '%s=%s\n' "${state_key}" "${backup_target}" >>"${state_file}"
    chmod 600 "${state_file}"
    log "Standby ${state_key} 已移动到 ${backup_target}（未删除，可恢复）。"
  elif [[ -f "${state_file}" ]]; then
    validate_standby_resume_state
    log "Standby 目标 PGDATA 为空，将从中断状态继续：${STANDBY_RESUME_STATE_FILE}。"
  fi

  install -d -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 700 "${STANDBY_PGDATA}"
  slot_count="$("${primary_psql[@]}" -c "select count(*) from pg_replication_slots where slot_name='${REPLICATION_SLOT_NAME}' and slot_type='physical'")"
  slot_args=(--slot="${REPLICATION_SLOT_NAME}")
  if [[ "${slot_count}" == '0' ]]; then
    slot_args+=(--create-slot)
  else
    active_count="$("${primary_psql[@]}" -c "select count(*) from pg_replication_slots where slot_name='${REPLICATION_SLOT_NAME}' and active")"
    [[ "${active_count}" == '0' ]] || die "复制槽 ${REPLICATION_SLOT_NAME} 已被其他进程占用。"
    warn "复用现有未激活物理复制槽 ${REPLICATION_SLOT_NAME}。"
  fi

  log '开始使用现有 NebulaCM pg_basebackup 初始化 Standby。'
  runuser -u "${PG_OS_USER}" -- env PATH="${STANDBY_PG_BIN_DIR}:/usr/bin:/bin" PGPASSWORD="${REPLICATION_PASSWORD}" \
    "${STANDBY_PG_BIN_DIR}/pg_basebackup" \
    --host="${PRIMARY_HOST}" --port="${PRIMARY_PORT}" --username="${REPLICATION_USER}" \
    --pgdata="${STANDBY_PGDATA}" --wal-method=stream --checkpoint=fast --progress --verbose \
    "${slot_args[@]}"
  [[ -f "${STANDBY_PGDATA}/PG_VERSION" && -f "${STANDBY_PGDATA}/postgresql.conf" ]] || die 'pg_basebackup 结果不完整。'
  touch "${STANDBY_PGDATA}/standby.signal"
else
  log '检测到已初始化的 Standby；不再次移动或覆盖 PGDATA，仅刷新复制凭据和受管配置。'
fi

postgres_home="$(getent passwd "${PG_OS_USER}" | cut -d: -f6)"
[[ -n "${postgres_home}" && "${postgres_home}" == /* ]] || die "无法确定 ${PG_OS_USER} HOME。"
passfile="${postgres_home}/.pgpass-rw-proxy"
umask 077
printf '%s:%s:replication:%s:%s\n' "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${REPLICATION_USER}" "${REPLICATION_PASSWORD}" >"${passfile}"
chown "${PG_OS_USER}:${PG_OS_USER}" "${passfile}"
chmod 600 "${passfile}"

auto_conf="${STANDBY_PGDATA}/postgresql.auto.conf"
touch "${auto_conf}"
temp_recovery="$(mktemp)"; temp_standby_conf="$(mktemp)"; temp_include="$(mktemp)"
cleanup() { rm -f -- "${temp_recovery}" "${temp_standby_conf}" "${temp_include}"; unset PGPASSWORD; }
trap cleanup EXIT
cat >"${temp_recovery}" <<RECOVERY
primary_conninfo = 'host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPLICATION_USER} application_name=${STANDBY_APPLICATION_NAME} passfile=${passfile}'
primary_slot_name = '${REPLICATION_SLOT_NAME}'
RECOVERY
replace_managed_block "${auto_conf}" PG_RW_PROXY_RECOVERY "${temp_recovery}"

install -d -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 700 "${STANDBY_PGDATA}/conf.d"
render_template "${PROJECT_ROOT}/templates/standby-postgresql.conf.tpl" "${temp_standby_conf}" \
  STANDBY_LISTEN_ADDRESSES "${STANDBY_LISTEN_ADDRESSES}" STANDBY_PORT "${STANDBY_PORT}"
install -o "${PG_OS_USER}" -g "${PG_OS_USER}" -m 600 "${temp_standby_conf}" "${STANDBY_PGDATA}/conf.d/99-pg-rw-proxy.conf"
printf "include_if_exists = 'conf.d/99-pg-rw-proxy.conf'\n" >"${temp_include}"
replace_managed_block "${STANDBY_PGDATA}/postgresql.conf" PG_RW_PROXY_INCLUDE "${temp_include}"

# pg_basebackup 会复制 Primary HBA；显式确保旧的全网 repl 规则不复活。
sed -Ei '/^[[:space:]]*host[[:space:]]+replication[[:space:]]+repl[[:space:]]+0\.0\.0\.0\/0[[:space:]]+md5([[:space:]]*(#.*)?)?$/d' "${STANDBY_PGDATA}/pg_hba.conf"
chown -R "${PG_OS_USER}:${PG_OS_USER}" "${STANDBY_PGDATA}"
chmod 700 "${STANDBY_PGDATA}"
add_firewall_rule "${MANAGE_DB_FIREWALL}" "${PGPOOL_ADDRESS_CIDR}" "${STANDBY_PORT}" '数据库节点'

if pg_ctl_is_running "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"; then
  enforce_restart_connection_policy Standby "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" '数据库重启前'
fi
pg_ctl_stop "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}"
pg_ctl_start "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}" "${STANDBY_PGDATA}/log/pg-rw-proxy-startup.log"
wait_for_postgres "${STANDBY_PG_BIN_DIR}" 127.0.0.1 "${STANDBY_PORT}" 120 || die 'Standby 启动失败。'
standby="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
  "select current_setting('cluster_name'),pg_is_in_recovery(),coalesce((select status from pg_stat_wal_receiver limit 1),'')")"
[[ "${standby}" == 'rw-standby|t|streaming' ]] || die "Standby 未进入 streaming 恢复态: ${standby}"
rm -f -- "${state_file}"
log "Standby 初始化完成：${standby}。"
