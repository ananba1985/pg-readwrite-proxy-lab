#!/usr/bin/env bash

# 对部署会修改的持久状态生成无敏感信息指纹，用于证明就绪检查没有改变三台服务器。
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROLE="${1:-}"
[[ "${ROLE}" =~ ^(primary|standby|pgpool)$ ]] || { printf '用法：%s primary|standby|pgpool\n' "$0" >&2; exit 2; }
require_root
load_cluster_config

hash_or_absent() {
  local path="$1"
  if [[ -f "${path}" && ! -L "${path}" ]]; then sha256sum "${path}" | awk '{print $1}'; else printf absent; fi
}

tree_hash_or_absent() {
  local path="$1"
  if [[ -d "${path}" && ! -L "${path}" ]]; then
    find "${path}" -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'
  else
    printf absent
  fi
}

case "${ROLE}" in
  primary|standby)
    if [[ "${ROLE}" == primary ]]; then
      pgdata="${PRIMARY_PGDATA}"; bin_dir="${PRIMARY_PG_BIN_DIR}"; admin_tool="${PRIMARY_ADMIN_TOOL}"; port="${PRIMARY_PORT}"
    else
      pgdata="${STANDBY_PGDATA}"; bin_dir="${STANDBY_PG_BIN_DIR}"; admin_tool="${STANDBY_ADMIN_TOOL}"; port="${STANDBY_PORT}"
    fi
    require_commands=(sha256sum awk find sort xargs runuser)
    for command_name in "${require_commands[@]}"; do require_command "${command_name}"; done
    pg_ctl_is_running "${bin_dir}" "${pgdata}" || die "${ROLE} 在生成状态指纹时未运行。"
    identity="$(nebula_admin_query "${admin_tool}" "${port}" postgres \
      "select pg_is_in_recovery(),(select system_identifier from pg_control_system()),current_setting('cluster_name'),current_setting('listen_addresses'),current_setting('wal_level'),current_setting('max_wal_senders'),current_setting('max_replication_slots'),current_setting('wal_keep_segments')")"
    printf '%s|identity=%s|postgresql=%s|hba=%s|auto=%s|managed=%s\n' \
      "${ROLE}" "${identity}" \
      "$(hash_or_absent "${pgdata}/postgresql.conf")" "$(hash_or_absent "${pgdata}/pg_hba.conf")" \
      "$(hash_or_absent "${pgdata}/postgresql.auto.conf")" "$(hash_or_absent "${pgdata}/conf.d/99-pg-rw-proxy.conf")"
    ;;
  pgpool)
    for command_name in systemctl ss sha256sum awk find sort xargs firewall-cmd; do require_command "${command_name}"; done
    service_state="$(systemctl is-active "${PGPOOL_SERVICE}" 2>/dev/null || true)"
    listen_hash="$(ss -ltnH "sport = :${PGPOOL_PORT} or sport = :${PCP_PORT}" 2>/dev/null | sha256sum | awk '{print $1}')"
    firewall_hash="$(firewall-cmd --list-all --permanent 2>/dev/null | sha256sum | awk '{print $1}')"
    printf 'pgpool|service=%s|listen=%s|unit=%s|config=%s|runtime=%s|client=%s|binary=%s|firewall=%s\n' \
      "${service_state:-unknown}" "${listen_hash}" "$(hash_or_absent "/etc/systemd/system/${PGPOOL_SERVICE}.service")" \
      "$(tree_hash_or_absent "${PGPOOL_CONFIG_DIR}")" \
      "$([[ -e "${PGPOOL_RUNTIME_PREFIX}" ]] && printf present || printf absent)" \
      "$([[ -e "${PG_CLIENT_PREFIX}" ]] && printf present || printf absent)" \
      "$([[ -e "${PGPOOL_INSTALL_PREFIX}" ]] && printf present || printf absent)" "${firewall_hash}"
    ;;
esac
