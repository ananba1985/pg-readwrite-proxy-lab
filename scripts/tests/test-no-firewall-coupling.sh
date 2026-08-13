#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
for script_file in "${ROOT}/install.sh" "${ROOT}/scripts/"*.sh "${ROOT}/scripts/lib/"*.sh; do
  if grep -Eq 'firewall-cmd|systemctl[^[:cntrl:]]*firewalld|add_firewall_rule|MANAGE_DB_FIREWALL' "${script_file}"; then
    printf '检测到运行时防火墙耦合: %s\n' "${script_file}" >&2
    exit 1
  fi
done

# 兼容已经交付的全量命令：旧参数可以继续出现，但只能被解析并忽略。
die() { printf '%s\n' "$*" >&2; exit 1; }
# shellcheck source=../lib/installer-inputs.sh
source "${ROOT}/scripts/lib/installer-inputs.sh"
initialize_install_inputs
parse_install_inputs --manage-pgpool-firewall yes
[[ "${MANAGE_PGPOOL_FIREWALL}" == 'yes' ]]
! grep -Eq '\[MANAGE_PGPOOL_FIREWALL\]|MANAGE_DB_FIREWALL' "${ROOT}/install.sh"

printf 'NO_FIREWALL_COUPLING_OK\n'
