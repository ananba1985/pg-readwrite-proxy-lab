#!/usr/bin/env bash

# 只用于本地麒麟 V10 ARM64 兼容机 192.168.80.140。
# 清理项目拥有的 Pgpool 运行时、服务、配置、账号和已验证暂存目录；不接触数据库节点、网络或离线介质。
set -Eeuo pipefail
umask 077

readonly EXPECTED_IP='192.168.80.140'
readonly CONFIRM_TOKEN='--confirm-reset-kylin-pgpool-test'
[[ "$#" == 1 && "$1" == "${CONFIRM_TOKEN}" ]] || {
  printf 'Usage: sudo %s %s\n' "$0" "${CONFIRM_TOKEN}" >&2
  exit 2
}
[[ "$(id -u)" == 0 && "$(uname -m)" == aarch64 ]] || exit 1
[[ -r /etc/os-release ]] || exit 1
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}:${VERSION_ID:-}" == 'kylin:V10' ]] || exit 1

instance_ip="$(/sbin/ip -o -4 addr show dev enp0s6 | awk '{print $4}' | cut -d/ -f1)"
[[ "${instance_ip}" == "${EXPECTED_IP}" ]] || {
  printf 'Refusing cleanup on unexpected address: %s\n' "${instance_ip:-missing}" >&2
  exit 1
}
[[ ! -x /opt/pgsql12/bin/postgres ]] || {
  printf 'Refusing cleanup because a PostgreSQL server runtime exists on the Pgpool test node.\n' >&2
  exit 1
}
! pgrep -x postgres >/dev/null 2>&1 || {
  printf 'Refusing cleanup because a postgres process exists on the Pgpool test node.\n' >&2
  exit 1
}

readonly SERVICE_UNIT='/etc/systemd/system/pgpool.service'
if [[ -e "${SERVICE_UNIT}" || -L "${SERVICE_UNIT}" ]]; then
  [[ -f "${SERVICE_UNIT}" && ! -L "${SERVICE_UNIT}" ]] || exit 1
  grep -Fq 'ExecStart=/opt/pgpool-II-4.7.2/bin/pgpool' "${SERVICE_UNIT}" || {
    printf 'Existing pgpool.service is not owned by this project.\n' >&2
    exit 1
  }
fi

readonly -a APPROVED_TREES=(
  /opt/pgpool-II-4.7.2
  /opt/pgpool-client-12.0
  /opt/pgpool-runtime-kylin-v10
  /etc/pgpool-II
  /var/lib/pgpool
  /var/log/pgpool
  /run/pgpool
  /var/lib/pg-rw-proxy-installer
  /var/log/pg-readwrite-proxy-lab
)
for target in "${APPROVED_TREES[@]}"; do
  [[ ! -e "${target}" && ! -L "${target}" ]] && continue
  [[ ! -L "${target}" && "$(readlink -f "${target}")" == "${target}" ]] || {
    printf 'Refusing unsafe cleanup target: %s\n' "${target}" >&2
    exit 1
  }
done

mapfile -t project_stages < <(
  find /var/tmp -xdev -type f -path '*/scripts/30-install-pgpool.sh' -print 2>/dev/null |
    while IFS= read -r marker; do
      stage="$(dirname "$(dirname "${marker}")")"
      resolved="$(readlink -f "${stage}")"
      [[ ! -L "${stage}" && "$(dirname "${resolved}")" == /var/tmp ]] || continue
      [[ -f "${resolved}/install.sh" && -f "${resolved}/scripts/30-install-pgpool.sh" ]] || continue
      printf '%s\n' "${resolved}"
    done | sort -u
)

printf 'KYLIN_PGPOOL_RESET_BEGIN ip=%s stages=%s\n' "${instance_ip}" "${#project_stages[@]}"
systemctl stop pgpool >/dev/null 2>&1 || true
systemctl disable pgpool >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  pgrep -x pgpool >/dev/null 2>&1 || break
  sleep 1
done
! pgrep -x pgpool >/dev/null 2>&1 || {
  printf 'Pgpool processes remain after service stop.\n' >&2
  exit 1
}

rm -f -- "${SERVICE_UNIT}"
systemctl daemon-reload
systemctl reset-failed pgpool >/dev/null 2>&1 || true
for target in "${APPROVED_TREES[@]}"; do
  [[ ! -e "${target}" && ! -L "${target}" ]] || rm -rf --one-file-system -- "${target}"
done
# 备份根目录可能同时保存数据库审计，不能整体删除；仅删除 Pgpool 配置备份和 Pgpool reset 元数据。
readonly BACKUP_ROOT='/var/backups/pg-readwrite-proxy-lab'
if [[ -d "${BACKUP_ROOT}" && ! -L "${BACKUP_ROOT}" && "$(readlink -f "${BACKUP_ROOT}")" == "${BACKUP_ROOT}" ]]; then
  while IFS= read -r backup; do
    backup_name="$(basename "${backup}")"
    [[ "${backup_name}" =~ ^pgpool(-reset)?-[0-9]{8}-[0-9]{6}$ ]] || continue
    [[ ! -L "${backup}" && "$(readlink -f "${backup}")" == "${BACKUP_ROOT}/${backup_name}" ]] || exit 1
    rm -rf --one-file-system -- "${backup}"
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -name 'pgpool-*' -print)
fi
if getent passwd pgpool >/dev/null; then userdel pgpool; fi
if getent group pgpool >/dev/null; then groupdel pgpool; fi
for stage in "${project_stages[@]}"; do
  [[ "$(dirname "${stage}")" == /var/tmp && ! -L "${stage}" ]] || exit 1
  rm -rf --one-file-system -- "${stage}"
done

[[ "$(systemctl show -p LoadState pgpool 2>/dev/null || true)" == 'LoadState=not-found' ]]
! getent passwd pgpool >/dev/null
! getent group pgpool >/dev/null
! pgrep -x pgpool >/dev/null 2>&1
for port in 5432 9898 9999; do
  ! ss -ltnH "sport = :${port}" | grep -q . || {
    printf 'Port %s remains occupied after cleanup.\n' "${port}" >&2
    exit 1
  }
done
for target in "${APPROVED_TREES[@]}"; do
  [[ ! -e "${target}" && ! -L "${target}" ]]
done
printf 'KYLIN_PGPOOL_TEST_ENVIRONMENT_RESET_OK ip=%s ports=5432,9898,9999 stages_removed=%s\n' \
  "${instance_ip}" "${#project_stages[@]}"
