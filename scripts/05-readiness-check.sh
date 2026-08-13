#!/usr/bin/env bash

# 部署前只读就绪门禁。它不得修改数据库、服务、配置、账号或防火墙。
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROLE="${1:-}"
[[ "${ROLE}" =~ ^(primary|standby|pgpool)$ ]] || { printf '用法：sudo %s primary|standby|pgpool\n' "$0" >&2; exit 2; }

require_root
load_cluster_config
load_secrets

require_commands() {
  local command_name
  for command_name in "$@"; do require_command "${command_name}"; done
}

validated_pid_list() {
  local value="${1:-none}" label="$2"
  if [[ "${value}" == 'none' ]]; then
    printf '0'
    return
  fi
  [[ "${value}" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "${label} 不是受信任的 Pgpool 后端 PID 清单。"
  printf '%s' "${value}"
}

assert_local_ipv4() {
  local expected="$1" label="$2"
  /sbin/ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${expected}" || \
    die "${label}=${expected} 不属于当前服务器。"
}

assert_rw_mount() {
  local path="$1" label="$2" options
  options="$(findmnt -n -o OPTIONS -T "${path}")"
  [[ ",${options}," == *,rw,* ]] || die "${label} 所在文件系统不是可写挂载: ${path} (${options})"
}

assert_mutable_path() {
  local path="$1" label="$2" attrs
  [[ -e "${path}" && ! -L "${path}" ]] || die "${label} 缺失或为符号链接: ${path}"
  [[ -w "${path}" ]] || die "root 对 ${label} 没有写权限: ${path}"
  attrs="$(lsattr -d -- "${path}" 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ -n "${attrs}" ]] || die "无法检查 ${label} 的 inode 属性: ${path}"
  [[ "${attrs}" != *i* && "${attrs}" != *a* ]] || die "${label} 带 immutable/append-only 属性: ${path} (${attrs})"
}

assert_managed_block_shape() {
  local target="$1" marker="$2" begin_count end_count
  begin_count="$(grep -Fxc "# BEGIN ${marker}" "${target}" || true)"
  end_count="$(grep -Fxc "# END ${marker}" "${target}" || true)"
  [[ "${begin_count}" == "${end_count}" && "${begin_count}" -le 1 ]] || \
    die "${target} 中 ${marker} 受管标记残缺或重复。"
}

assert_selinux_baseline() {
  local mode
  mode="$(getenforce 2>/dev/null || printf unknown)"
  [[ "${mode}" =~ ^(Disabled|Permissive)$ ]] || die "SELinux 运行态不可接受: ${mode}；Enforcing 必须先完成专项策略验收。"
}

check_backup_capacity() {
  local target="$1" required_bytes="$2" label="$3" available
  [[ "${required_bytes}" =~ ^[0-9]+$ ]] || die "${label} 容量估算无效。"
  available="$(df -PB1 "${target}" | awk 'NR==2 {print $4}')"
  [[ "${available}" =~ ^[0-9]+$ ]] || die "无法读取 ${label} 可用空间。"
  ((available >= required_bytes)) || die "${label} 空间不足：available=${available}, required=${required_bytes}。"
}

require_commands bash awk sed grep find findmnt df du stat sha256sum timeout ss ip ping readlink \
  lsattr cut getconf uname date mkdir rm cp mv chmod chown install mktemp sleep sort paste
assert_selinux_baseline
[[ "${APPLY_PRIMARY_RESTART}" == 'yes' ]] || die '本次一键流程缺少 Primary 维护窗口授权。'
[[ "${ALLOW_STANDBY_REINITIALIZE}" == 'yes' ]] || die '本次一键流程缺少 Standby 重建授权。'

case "${ROLE}" in
  primary)
    detect_db_platform
    assert_local_ipv4 "${PRIMARY_HOST}" PRIMARY_HOST
    require_commands runuser cat
    assert_safe_pgdata "${PRIMARY_PGDATA}"
    assert_rw_mount "${PRIMARY_PGDATA}" 'Primary PGDATA'
    assert_rw_mount /var 'Primary 备份目录'
    verify_nebula_runtime "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_ADMIN_TOOL}" Primary
    pg_ctl_is_running "${PRIMARY_PG_BIN_DIR}" "${PRIMARY_PGDATA}" || die 'Primary 未由已验收 pg_ctl 运行。'

    identity="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('data_directory'),current_setting('config_file'),current_setting('hba_file')")"
    IFS='|' read -r version_num recovery actual_pgdata postgresql_conf pg_hba_conf <<<"${identity}"
    [[ "${version_num}" == '120000' && "${recovery}" == 'f' && "${actual_pgdata}" == "${PRIMARY_PGDATA}" ]] || \
      die "Primary 身份、版本或数据目录异常: ${identity}"
    for path in "${PRIMARY_PGDATA}" "${postgresql_conf}" "${pg_hba_conf}"; do
      [[ -e "${path}" && ! -L "${path}" ]] || die "Primary 必需路径缺失或为符号链接: ${path}"
    done
    [[ "$(stat -c '%U' "${PRIMARY_PGDATA}")" == "${PG_OS_USER}" ]] || die "Primary PGDATA 不属于 ${PG_OS_USER}。"
    pgdata_mode="$(stat -c '%a' "${PRIMARY_PGDATA}")"
    [[ "${pgdata_mode}" =~ ^[0-7]{3,4}$ ]] || die "Primary PGDATA 权限格式异常: ${pgdata_mode}。"
    (( (8#${pgdata_mode} & 8#077) == 0 )) || die "Primary PGDATA 组/其他用户仍有权限: ${pgdata_mode}。"
    assert_mutable_path "${PRIMARY_PGDATA}" 'Primary PGDATA'
    assert_mutable_path "${postgresql_conf}" 'Primary postgresql.conf'
    assert_mutable_path "${pg_hba_conf}" 'Primary pg_hba.conf'
    assert_mutable_path "$(dirname "${PRIMARY_PGDATA}")" 'Primary PGDATA 父目录'
    [[ ! -e "${PRIMARY_PGDATA}/postgresql.auto.conf" ]] || \
      assert_mutable_path "${PRIMARY_PGDATA}/postgresql.auto.conf" 'Primary postgresql.auto.conf'
    [[ ! -e "${PRIMARY_PGDATA}/conf.d" ]] || assert_mutable_path "${PRIMARY_PGDATA}/conf.d" 'Primary conf.d'
    [[ ! -e "${PRIMARY_PGDATA}/conf.d/99-pg-rw-proxy.conf" ]] || \
      assert_mutable_path "${PRIMARY_PGDATA}/conf.d/99-pg-rw-proxy.conf" 'Primary 受管参数文件'
    assert_managed_block_shape "${postgresql_conf}" PG_RW_PROXY_INCLUDE
    assert_managed_block_shape "${pg_hba_conf}" PG_RW_PROXY_HBA

    admin_is_superuser="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select rolsuper from pg_roles where rolname=current_user")"
    [[ "${admin_is_superuser}" == 't' ]] || die '厂商管理入口当前账号不是数据库超级用户。'
    config_errors="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_file_settings where error is not null and not (error='setting could not be applied' and name in ('listen_addresses','cluster_name','wal_level','max_wal_senders','max_replication_slots'))")"
    hba_errors="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_hba_file_rules where error is not null")"
    [[ "${config_errors}" == '0' && "${hba_errors}" == '0' ]] || \
      die "Primary 当前配置已有解析错误（postgresql=${config_errors}, hba=${hba_errors}）。"

    business_objects="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select (select count(*) from pg_roles where rolname='${BUSINESS_USER}' and rolcanlogin),(select count(*) from pg_database where datname='${BUSINESS_DATABASE}')")"
    [[ "${business_objects}" == '1|1' ]] || die "业务账号或数据库不存在: ${business_objects}"
    business_login="$(PGPASSWORD="${BUSINESS_PASSWORD}" "${PRIMARY_PG_BIN_DIR}/psql" -XAtq -v ON_ERROR_STOP=1 \
      -h 127.0.0.1 -p "${PRIMARY_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" \
      -c "select current_user,(to_regclass('business.rw_probe') is not null)::text")"
    [[ "${business_login}" == "${BUSINESS_USER}|true" ]] || die '业务密码验证失败或缺少 business.rw_probe。'

    expected_pgpool_pids="$(validated_pid_list "${EXPECTED_PGPOOL_PRIMARY_PIDS:-none}" EXPECTED_PGPOOL_PRIMARY_PIDS)"
    active_client_sessions="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_stat_activity where backend_type='client backend' and pid<>pg_backend_pid() and not (client_addr='${PGPOOL_HOST}'::inet and pid in (${expected_pgpool_pids}) and usename='${BUSINESS_USER}' and datname='${BUSINESS_DATABASE}')")"
    [[ "${active_client_sessions}" =~ ^[0-9]+$ ]] || die '无法统计 Primary 客户端连接数。'
    ((active_client_sessions == 0)) || \
      warn "Primary 检测到 ${active_client_sessions} 个客户端连接；技术检查继续，一键入口随后要求人工选择退出或强制中断。"
    custom_tablespaces="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_tablespace where pg_tablespace_location(oid) <> ''")"
    [[ "${custom_tablespaces}" == '0' ]] || die 'Primary 存在自定义表空间，当前安装器不猜测 Standby 映射。'
    foreign_replication="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_stat_replication where application_name<>'${STANDBY_APPLICATION_NAME}'")"
    [[ "${foreign_replication}" == '0' ]] || die 'Primary 存在不属于本拓扑的复制连接，拒绝自动改造。'
    slot_conflict="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select count(*) from pg_replication_slots where slot_name='${REPLICATION_SLOT_NAME}' and slot_type<>'physical'")"
    [[ "${slot_conflict}" == '0' ]] || die "复制槽 ${REPLICATION_SLOT_NAME} 已被非物理槽占用。"

    vendor_hba_tmp="${PRIMARY_PGDATA}/hba/pg_hba_tmp.conf"
    unreadable_paths="$(run_as_pg "${PRIMARY_PG_BIN_DIR}" find "${PRIMARY_PGDATA}" -xdev \
      \( -type d ! -executable -o -type f ! -readable \) ! -path "${vendor_hba_tmp}" -print 2>/dev/null || true)"
    [[ -z "${unreadable_paths}" ]] || die "Primary PGDATA 存在非已知的 postgres 不可读路径: ${unreadable_paths}"
    [[ ! -e "${vendor_hba_tmp}" || ( ! -L "${vendor_hba_tmp}" && -f "${vendor_hba_tmp}" ) ]] || \
      die "厂商临时 HBA 路径类型异常: ${vendor_hba_tmp}"
    [[ ! -e "${vendor_hba_tmp}" ]] || assert_mutable_path "${vendor_hba_tmp}" '厂商临时 HBA 文件'

    primary_bytes="$(du -sb "${PRIMARY_PGDATA}" | awk '{print $1}')"
    backup_required=$((primary_bytes / 20 + 268435456))
    check_backup_capacity /var "${backup_required}" 'Primary 配置备份文件系统'
    wal_segment_bytes="$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres \
      "select pg_size_bytes(current_setting('wal_segment_size'))")"
    [[ "${wal_segment_bytes}" =~ ^[0-9]+$ ]] || die '无法计算 Primary WAL segment 大小。'
    wal_headroom_required=$((WAL_KEEP_SEGMENTS * wal_segment_bytes + 536870912))
    check_backup_capacity "${PRIMARY_PGDATA}" "${wal_headroom_required}" 'Primary WAL 文件系统'
    ip route get "${STANDBY_HOST}" >/dev/null || die "Primary 没有到 Standby ${STANDBY_HOST} 的路由。"
    ip route get "${PGPOOL_HOST}" >/dev/null || die "Primary 没有到 Pgpool ${PGPOOL_HOST} 的路由。"
    ping -c 1 -W 2 "${STANDBY_HOST}" >/dev/null || die "Primary 无法 ping Standby ${STANDBY_HOST}。"
    ping -c 1 -W 2 "${PGPOOL_HOST}" >/dev/null || die "Primary 无法 ping Pgpool ${PGPOOL_HOST}。"
    tcp_check "${STANDBY_HOST}" "${STANDBY_PORT}" || die 'Primary 无法连接 Standby 当前数据库端口。'
    printf 'READINESS_PRIMARY=READY system_id=%s pgdata_bytes=%s active_client_sessions=%s\n' \
      "$(nebula_admin_query "${PRIMARY_ADMIN_TOOL}" "${PRIMARY_PORT}" postgres 'select system_identifier from pg_control_system()')" \
      "${primary_bytes}" "${active_client_sessions}"
    ;;

  standby)
    detect_db_platform
    assert_local_ipv4 "${STANDBY_HOST}" STANDBY_HOST
    require_commands runuser cat getent mountpoint
    assert_safe_pgdata "${STANDBY_PGDATA}"
    assert_rw_mount "${STANDBY_PGDATA}" 'Standby PGDATA'
    assert_rw_mount /var 'Standby 备份目录'
    verify_nebula_runtime "${STANDBY_PG_BIN_DIR}" "${STANDBY_ADMIN_TOOL}" 'Standby 目标机'
    [[ -d "${STANDBY_PGDATA}" && ! -L "${STANDBY_PGDATA}" ]] || die 'Standby PGDATA 缺失或为符号链接。'
    ! mountpoint -q "${STANDBY_PGDATA}" || die 'Standby PGDATA 是独立挂载点，当前安全移动逻辑不支持直接重建。'
    [[ "$(stat -c '%U' "${STANDBY_PGDATA}")" == "${PG_OS_USER}" ]] || die "Standby PGDATA 不属于 ${PG_OS_USER}。"
    pgdata_mode="$(stat -c '%a' "${STANDBY_PGDATA}")"
    [[ "${pgdata_mode}" =~ ^[0-7]{3,4}$ ]] || die "Standby PGDATA 权限格式异常: ${pgdata_mode}。"
    (( (8#${pgdata_mode} & 8#077) == 0 )) || die "Standby PGDATA 组/其他用户仍有权限: ${pgdata_mode}。"
    assert_mutable_path "${STANDBY_PGDATA}" 'Standby PGDATA'
    assert_mutable_path "$(dirname "${STANDBY_PGDATA}")" 'Standby PGDATA 父目录'
    pg_ctl_is_running "${STANDBY_PG_BIN_DIR}" "${STANDBY_PGDATA}" || die 'Standby 目标实例未运行。'
    identity="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
      "select current_setting('server_version_num'),pg_is_in_recovery(),current_setting('data_directory'),(select system_identifier from pg_control_system())")"
    IFS='|' read -r version_num recovery actual_pgdata system_id <<<"${identity}"
    [[ "${version_num}" == '120000' && "${actual_pgdata}" == "${STANDBY_PGDATA}" ]] || die "Standby 版本或路径异常: ${identity}"
    expected_pgpool_pids="$(validated_pid_list "${EXPECTED_PGPOOL_STANDBY_PIDS:-none}" EXPECTED_PGPOOL_STANDBY_PIDS)"
    standby_sessions="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
      "select count(*) from pg_stat_activity where backend_type='client backend' and pid<>pg_backend_pid() and not (client_addr='${PGPOOL_HOST}'::inet and pid in (${expected_pgpool_pids}) and usename='${BUSINESS_USER}' and datname='${BUSINESS_DATABASE}')")"
    [[ "${standby_sessions}" =~ ^[0-9]+$ ]] || die '无法统计 Standby 客户端连接数。'
    ((standby_sessions == 0)) || \
      warn "Standby 检测到 ${standby_sessions} 个客户端连接；技术检查继续，一键入口随后要求人工选择退出或强制中断。"
    config_errors="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
      "select count(*) from pg_file_settings where error is not null and not (error='setting could not be applied' and name in ('listen_addresses','cluster_name','hot_standby'))")"
    hba_errors="$(nebula_admin_query "${STANDBY_ADMIN_TOOL}" "${STANDBY_PORT}" postgres \
      "select count(*) from pg_hba_file_rules where error is not null")"
    [[ "${config_errors}" == '0' && "${hba_errors}" == '0' ]] || \
      die "Standby 当前配置已有解析错误（postgresql=${config_errors}, hba=${hba_errors}）。"
    postgres_home="$(getent passwd "${PG_OS_USER}" | cut -d: -f6)"
    [[ "${postgres_home}" == /* && -d "${postgres_home}" && ! -L "${postgres_home}" ]] || \
      die "Standby 无法使用 ${PG_OS_USER} HOME: ${postgres_home:-missing}"
    assert_mutable_path "${postgres_home}" 'Standby postgres HOME'
    [[ "${PRIMARY_SYSTEM_ID:-}" =~ ^[0-9]+$ && "${PRIMARY_PGDATA_BYTES:-}" =~ ^[0-9]+$ ]] || die '缺少 Primary 容量/身份预检上下文。'
    if [[ "${recovery}" == 't' ]]; then
      [[ "${system_id}" == "${PRIMARY_SYSTEM_ID}" ]] || die '现有 Standby 不属于目标 Primary。'
    elif [[ "${recovery}" == 'f' ]]; then
      [[ "${system_id}" != "${PRIMARY_SYSTEM_ID}" ]] || die 'Standby 目标为可写状态但 system identifier 与 Primary 相同，状态不安全。'
      [[ "${ALLOW_STANDBY_REINITIALIZE}" == 'yes' ]] || die '未授权重建 Standby。'
    else
      die "Standby 恢复状态无法识别: ${recovery}"
    fi

    standby_bytes="$(du -sb "${STANDBY_PGDATA}" | awk '{print $1}')"
    data_available="$(df -PB1 "${STANDBY_PGDATA}" | awk 'NR==2 {print $4}')"
    backup_available="$(df -PB1 /var | awk 'NR==2 {print $4}')"
    basebackup_required=$((PRIMARY_PGDATA_BYTES + PRIMARY_PGDATA_BYTES / 5 + 536870912))
    data_device="$(df -P "${STANDBY_PGDATA}" | awk 'NR==2 {print $1}')"
    backup_device="$(df -P /var | awk 'NR==2 {print $1}')"
    if [[ "${recovery}" == 'f' && "${data_device}" == "${backup_device}" ]]; then
      # 原数据被保留在同一文件系统，mv 不释放空间。
      post_move_available="${data_available}"
    elif [[ "${recovery}" == 'f' ]]; then
      ((backup_available >= standby_bytes + standby_bytes / 10 + 268435456)) || \
        die 'Standby 原 PGDATA 备份文件系统空间不足。'
      # 跨文件系统 mv 会复制后删除源，复制完成后数据盘可回收原 PGDATA 体量。
      post_move_available=$((data_available + standby_bytes))
      immutable_path="$(find "${STANDBY_PGDATA}" -xdev -exec lsattr -d -- {} + 2>/dev/null | \
        awk 'substr($1,5,1)=="i" || substr($1,6,1)=="a" {print $NF; exit}')"
      [[ -z "${immutable_path}" ]] || die "Standby 跨文件系统备份会遇到 immutable/append-only 路径: ${immutable_path}"
    else
      post_move_available="${data_available}"
    fi
    ((post_move_available >= basebackup_required)) || \
      die "Standby 数据盘空间不足：post_move_available=${post_move_available}, required=${basebackup_required}。"
    if [[ "${recovery}" == 'f' ]]; then
      # 同一文件系统的 mv 不额外占用空间；跨文件系统才按上方严格检查备份容量。
      [[ "${data_device}" == "${backup_device}" ]] || log "Standby 原数据将跨文件系统移动到 /var 备份区。"
    fi
    tcp_check "${PRIMARY_HOST}" "${PRIMARY_PORT}" || die 'Standby 无法连接 Primary 数据库端口。'
    ip route get "${PGPOOL_HOST}" >/dev/null || die "Standby 没有到 Pgpool ${PGPOOL_HOST} 的路由。"
    ping -c 1 -W 2 "${PRIMARY_HOST}" >/dev/null || die "Standby 无法 ping Primary ${PRIMARY_HOST}。"
    ping -c 1 -W 2 "${PGPOOL_HOST}" >/dev/null || die "Standby 无法 ping Pgpool ${PGPOOL_HOST}。"
    printf 'READINESS_STANDBY=READY recovery=%s system_id=%s pgdata_bytes=%s active_client_sessions=%s\n' \
      "${recovery}" "${system_id}" "${standby_bytes}" "${standby_sessions}"
    ;;

  pgpool)
    detect_pgpool_platform
    assert_local_ipv4 "${PGPOOL_HOST}" PGPOOL_HOST
    require_commands systemctl tar gzip ldd firewall-cmd openssl pgrep useradd getent md5sum readelf strings
    assert_rw_mount /opt 'Pgpool 安装目录'
    assert_rw_mount /etc 'Pgpool 配置目录'
    assert_rw_mount /var 'Pgpool 状态/备份目录'
    [[ ! -x /opt/pgsql12/bin/postgres ]] || die 'Pgpool 节点存在 PostgreSQL 服务端运行时。'
    ! pgrep -x postgres >/dev/null 2>&1 || die 'Pgpool 节点正在运行 postgres 进程。'
    for path in /opt /etc /var /etc/systemd/system; do
      [[ -d "${path}" && ! -L "${path}" && -w "${path}" ]] || die "Pgpool 目标目录不可用: ${path}"
    done
    for prefix in "${PGPOOL_RUNTIME_PREFIX}" "${PG_CLIENT_PREFIX}" "${PGPOOL_INSTALL_PREFIX}"; do
      if [[ -e "${prefix}" || -L "${prefix}" ]]; then
        [[ -d "${prefix}" && ! -L "${prefix}" && "$(readlink -f -- "${prefix}")" == "${prefix}" ]] || \
          die "既有 Pgpool 安装前缀不是安全目录: ${prefix}"
        assert_mutable_path "${prefix}" '既有 Pgpool 安装前缀'
      fi
    done
    if [[ -e "${PGPOOL_CONFIG_DIR}" || -L "${PGPOOL_CONFIG_DIR}" ]]; then
      [[ -d "${PGPOOL_CONFIG_DIR}" && ! -L "${PGPOOL_CONFIG_DIR}" ]] || die 'Pgpool 配置路径不是安全目录。'
      assert_mutable_path "${PGPOOL_CONFIG_DIR}" '既有 Pgpool 配置目录'
    fi
    unit_file="$(systemctl show -p FragmentPath --value "${PGPOOL_SERVICE}" 2>/dev/null || true)"
    service_active=no
    systemctl is-active --quiet "${PGPOOL_SERVICE}" && service_active=yes
    if [[ -n "${unit_file}" ]]; then
      [[ "${unit_file}" == "/etc/systemd/system/${PGPOOL_SERVICE}.service" && -f "${unit_file}" ]] || \
        die "系统已有非本项目 ${PGPOOL_SERVICE} 服务: ${unit_file}"
      grep -Fq "ExecStart=${PGPOOL_INSTALL_PREFIX}/bin/pgpool" "${unit_file}" || \
        die "既有 ${PGPOOL_SERVICE} 服务不属于本项目。"
      assert_mutable_path "${unit_file}" '既有 Pgpool systemd unit'
    fi
    if getent passwd pgpool >/dev/null; then
      pgpool_uid="$(getent passwd pgpool | cut -d: -f3)"
      [[ "${pgpool_uid}" =~ ^[0-9]+$ && "${pgpool_uid}" -lt 1000 ]] || die '既有 pgpool 账号不是系统账号。'
      getent group pgpool >/dev/null || die '既有 pgpool 账号缺少同名主组。'
    fi
    validate_offline_payloads
    ping -c 1 -W 2 "${PRIMARY_HOST}" >/dev/null || die "Pgpool 无法 ping Primary ${PRIMARY_HOST}。"
    ping -c 1 -W 2 "${STANDBY_HOST}" >/dev/null || die "Pgpool 无法 ping Standby ${STANDBY_HOST}。"
    tcp_check "${PRIMARY_HOST}" "${PRIMARY_PORT}" || die 'Pgpool 无法连接 Primary 数据库端口。'
    tcp_check "${STANDBY_HOST}" "${STANDBY_PORT}" || die 'Pgpool 无法连接 Standby 数据库端口。'
    if [[ "${MANAGE_PGPOOL_FIREWALL}" == 'yes' ]]; then
      systemctl is-active --quiet firewalld || die '要求托管麒麟防火墙，但 firewalld 未运行。'
      firewall-cmd --state >/dev/null || die 'root 无法读取 firewalld 状态。'
    fi
    for port in "${PGPOOL_PORT}" "${PCP_PORT}"; do
      if ss -ltnH "sport = :${port}" | grep -q .; then
        [[ "${service_active}" == yes ]] || die "TCP/${port} 正在监听，但本项目 ${PGPOOL_SERVICE} 服务并非 active。"
        [[ "${unit_file}" == "/etc/systemd/system/${PGPOOL_SERVICE}.service" && -f "${unit_file}" ]] || \
          die "TCP/${port} 已被非项目服务占用。"
        grep -Fq "ExecStart=${PGPOOL_INSTALL_PREFIX}/bin/pgpool" "${unit_file}" || die "TCP/${port} 的既有服务不属于本项目。"
        main_pid="$(systemctl show -p MainPID --value "${PGPOOL_SERVICE}")"
        [[ "${main_pid}" =~ ^[1-9][0-9]*$ ]] || die "无法确认 TCP/${port} 对应 Pgpool 主进程。"
        ss -ltnpH "sport = :${port}" | grep -Fq "pid=${main_pid}," || \
          die "TCP/${port} 监听进程不属于本项目 Pgpool systemd 主进程。"
      fi
    done
    existing_primary_pids=none
    existing_standby_pids=none
    if [[ "${service_active}" == yes ]]; then
      existing_psql="${PG_CLIENT_PREFIX}/bin/psql"
      [[ -x "${existing_psql}" ]] || die '既有 Pgpool 服务运行中，但项目专用 psql 缺失。'
      existing_ld_path="${PGPOOL_RUNTIME_PREFIX}/lib:${PG_CLIENT_PREFIX}/lib:${PGPOOL_INSTALL_PREFIX}/lib"
      pool_rows="$(timeout 20 env LD_LIBRARY_PATH="${existing_ld_path}" PGPASSWORD="${BUSINESS_PASSWORD}" \
        PGAPPNAME='pg-rw-readiness' PGCONNECT_TIMEOUT=5 "${existing_psql}" -XAtqw -F '|' -v ON_ERROR_STOP=1 \
        -h 127.0.0.1 -p "${PGPOOL_PORT}" -U "${BUSINESS_USER}" -d "${BUSINESS_DATABASE}" -c 'show pool_pools')" || \
        die '无法通过既有 Pgpool 查询前端连接状态；拒绝在未知连接状态下重启入口。'
      malformed_pool_row="$(awk -F '|' 'NF<20 {print NR; exit}' <<<"${pool_rows}")"
      [[ -z "${malformed_pool_row}" ]] || die "既有 Pgpool 返回的 POOL_POOLS 格式异常（第 ${malformed_pool_row} 行）。"
      # 每个 child 同时只服务一个 frontend；按 pool_pid 去重，避免未使用 pool slot 继承 child 状态造成误计数。
      frontend_sessions="$(awk -F '|' '$16=="1" && $6!="" {seen[$1]=1} END {for (key in seen) count++; print count+0}' <<<"${pool_rows}")"
      [[ "${frontend_sessions}" == '1' ]] || \
        die "既有 Pgpool 仍有业务前端连接（连同本次只读检查共 ${frontend_sessions} 个）；请先停止全部客户端连接池。"
      # SHOW 查询已经结束，此时本次本机检查连接已关闭；剩余已建立套接字均属于外部或异常前端。
      established_frontends="$(ss -Htn state established "sport = :${PGPOOL_PORT}" 2>/dev/null | awk 'END {print NR+0}')"
      [[ "${established_frontends}" == '0' ]] || \
        die "既有 Pgpool 对外端口仍有 ${established_frontends} 个 TCP 前端连接；请先停止全部客户端连接池。"
      existing_primary_pids="$(awk -F '|' '$5=="0" && $15~/^[0-9]+$/ && $15!="0" {print $15}' <<<"${pool_rows}" | sort -nu | paste -sd, -)"
      existing_standby_pids="$(awk -F '|' '$5=="1" && $15~/^[0-9]+$/ && $15!="0" {print $15}' <<<"${pool_rows}" | sort -nu | paste -sd, -)"
      [[ -n "${existing_primary_pids}" ]] || existing_primary_pids=none
      [[ -n "${existing_standby_pids}" ]] || existing_standby_pids=none
    fi
    payload_test_root="$(mktemp -d /var/tmp/pg-rw-payload-readiness.XXXXXX)"
    cleanup_payload_test() { rm -rf -- "${payload_test_root}"; }
    trap cleanup_payload_test EXIT
    for payload_name in "${PGPOOL_PAYLOAD_FILE}" "${PG_CLIENT_PAYLOAD_FILE}" "${PGPOOL_RUNTIME_PAYLOAD_FILE}" "${SSHPASS_PAYLOAD_FILE}"; do
      payload_path="$(offline_file "${payload_name}")"
      gzip -t "${payload_path}" || die "离线载荷 gzip 结构损坏: ${payload_name}"
      unsafe_member="$(tar -tzf "${payload_path}" | awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ {print; exit}')"
      [[ -z "${unsafe_member}" ]] || die "离线载荷包含不安全路径: ${payload_name}: ${unsafe_member}"
      tar -xzf "${payload_path}" -C "${payload_test_root}"
    done
    test_runtime="${payload_test_root}/pgpool-runtime-kylin-v10/lib"
    test_client="${payload_test_root}/pgpool-client-12.0"
    test_pgpool="${payload_test_root}/pgpool-II-4.7.2"
    test_sshpass="${payload_test_root}/usr/local/bin/sshpass"
    [[ -x "${test_client}/bin/psql" && -x "${test_pgpool}/bin/pgpool" && -x "${test_sshpass}" ]] || \
      die '离线载荷试解压后缺少必需命令。'
    [[ ! -x "${test_client}/bin/postgres" ]] || die '客户端载荷错误包含 postgres 服务端。'
    test_ld_path="${test_runtime}:${test_client}/lib:${test_pgpool}/lib"
    mapfile -t test_binaries < <(find "${test_client}" "${test_pgpool}" -type f -perm /111 -print | sort)
    test_binaries+=("${test_sshpass}")
    for test_binary in "${test_binaries[@]}"; do
      missing="$(LD_LIBRARY_PATH="${test_ld_path}" ldd "${test_binary}" 2>/dev/null | grep 'not found' || true)"
      [[ -z "${missing}" ]] || die "离线载荷动态库闭包不完整: ${test_binary}: ${missing}"
    done
    [[ "$(LD_LIBRARY_PATH="${test_ld_path}" "${test_client}/bin/psql" --version)" == 'psql (PostgreSQL) 12.0' ]] || \
      die '试解压的 psql 版本异常。'
    LD_LIBRARY_PATH="${test_ld_path}" "${test_pgpool}/bin/pgpool" --version 2>&1 | grep -Fq "${PGPOOL_VERSION}" || \
      die '试解压的 Pgpool-II 版本异常。'
    "${test_sshpass}" -V 2>&1 | grep -Fq 'sshpass 1.10' || die '试解压的 sshpass 版本异常。'
    payload_bytes="$(du -cb "$(offline_file "${PGPOOL_PAYLOAD_FILE}")" "$(offline_file "${PG_CLIENT_PAYLOAD_FILE}")" \
      "$(offline_file "${PGPOOL_RUNTIME_PAYLOAD_FILE}")" "$(offline_file "${SSHPASS_PAYLOAD_FILE}")" | awk 'END{print $1}')"
    extracted_bytes="$(du -sb "${payload_test_root}" | awk '{print $1}')"
    check_backup_capacity /opt "$((extracted_bytes + extracted_bytes / 2 + 536870912))" 'Pgpool /opt 文件系统'
    cleanup_payload_test
    trap - EXIT
    printf 'READINESS_PGPOOL=READY platform=%s payload_bytes=%s firewalld_managed=%s\n' \
      "${PRETTY_NAME}" "${payload_bytes}" "${MANAGE_PGPOOL_FIREWALL}"
    printf 'READINESS_PGPOOL_BACKENDS=READY primary_pids=%s standby_pids=%s\n' \
      "${existing_primary_pids}" "${existing_standby_pids}"
    ;;
esac

printf 'READINESS_RESULT=READY role=%s\n' "${ROLE}"
