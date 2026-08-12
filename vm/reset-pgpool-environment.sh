#!/usr/bin/env bash

# Reset the dedicated Pgpool-II node to the state expected before the project
# installer runs. VM networking, SSH/root access, OS packages, and offline
# build media are preserved. Project runtime, credentials, service state, and
# configuration backups are removed.

set -Eeuo pipefail
umask 077

readonly PREFLIGHT_TOKEN='--preflight'
readonly CONFIRM_TOKEN='--confirm-reset'
readonly EXPECTED_IP='192.168.80.130'
readonly PGPOOL_SERVICE='pgpool'
readonly PGPOOL_PORT='9999'
readonly PCP_PORT='9898'
readonly PGPOOL_PREFIX='/opt/pgpool-II-4.7.2'
readonly CLIENT_PREFIX='/opt/pgpool-client-12.0'
readonly CONFIG_DIR='/etc/pgpool-II'
readonly SERVICE_UNIT='/etc/systemd/system/pgpool.service'
readonly PGPOOL_HOME='/var/lib/pgpool'
readonly PGPOOL_LOG='/var/log/pgpool'
readonly PGPOOL_RUN='/run/pgpool'
readonly BACKUP_ROOT='/var/backups/pg-readwrite-proxy-lab'

usage() {
  printf 'Usage: sudo %s <%s|%s>\n' "$0" "${PREFLIGHT_TOKEN}" "${CONFIRM_TOKEN}" >&2
}

[[ "$#" == 1 && ( "$1" == "${PREFLIGHT_TOKEN}" || "$1" == "${CONFIRM_TOKEN}" ) ]] || {
  usage
  exit 2
}
[[ "$(id -u)" == 0 ]] || {
  printf 'Pgpool reset must run as root.\n' >&2
  exit 1
}
[[ "$(uname -m)" == aarch64 ]] || {
  printf 'Unexpected architecture; expected aarch64.\n' >&2
  exit 1
}

instance_ip="$(/sbin/ip -o -4 addr show dev eth1 | awk '{print $4}' | cut -d/ -f1)"
[[ "${instance_ip}" == "${EXPECTED_IP}" ]] || {
  printf 'Refusing Pgpool reset on unexpected eth1 address: %s\n' "${instance_ip:-missing}" >&2
  exit 1
}

# A proxy node must never contain or run a PostgreSQL server. Refuse to hide a
# topology violation behind a Pgpool cleanup operation.
[[ ! -x /opt/pgsql12/bin/postgres ]] || {
  printf 'Database server runtime exists on the Pgpool node; refusing reset.\n' >&2
  exit 1
}
if pgrep -x postgres >/dev/null 2>&1; then
  printf 'A postgres server process exists on the Pgpool node; refusing reset.\n' >&2
  exit 1
fi

validate_exact_tree() {
  local path="$1"
  [[ ! -e "${path}" && ! -L "${path}" ]] && return 0
  [[ ! -L "${path}" ]] || {
    printf 'Refusing recursive operation on symlink: %s\n' "${path}" >&2
    exit 1
  }
  [[ "$(readlink -f "${path}")" == "${path}" ]] || {
    printf 'Resolved path differs from the approved target: %s\n' "${path}" >&2
    exit 1
  }
}

for approved_tree in \
  "${PGPOOL_PREFIX}" \
  "${CLIENT_PREFIX}" \
  "${CONFIG_DIR}" \
  "${PGPOOL_HOME}" \
  "${PGPOOL_LOG}" \
  "${PGPOOL_RUN}" \
  "${BACKUP_ROOT}"; do
  validate_exact_tree "${approved_tree}"
done

if [[ -e "${SERVICE_UNIT}" || -L "${SERVICE_UNIT}" ]]; then
  [[ -f "${SERVICE_UNIT}" && ! -L "${SERVICE_UNIT}" ]]
  grep -Fq "ExecStart=${PGPOOL_PREFIX}/bin/pgpool" "${SERVICE_UNIT}" || {
    printf 'Existing pgpool.service is not owned by this project; refusing reset.\n' >&2
    exit 1
  }
fi
service_fragment="$(systemctl show -p FragmentPath --value "${PGPOOL_SERVICE}" 2>/dev/null || true)"
[[ -z "${service_fragment}" || "${service_fragment}" == "${SERVICE_UNIT}" ]] || {
  printf 'The loaded pgpool.service is not the project unit: %s\n' "${service_fragment}" >&2
  exit 1
}

if getent passwd pgpool >/dev/null; then
  pgpool_home="$(getent passwd pgpool | awk -F: '{print $6}')"
  pgpool_shell="$(getent passwd pgpool | awk -F: '{print $7}')"
  [[ "${pgpool_home}" == "${PGPOOL_HOME}" && "${pgpool_shell}" == /sbin/nologin ]] || {
    printf 'Existing pgpool account does not match the project system account; refusing reset.\n' >&2
    exit 1
  }
fi

port_open() {
  local port="$1"
  timeout 1 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}

count_config_backups() {
  local path name count=0
  [[ -d "${BACKUP_ROOT}" ]] || { printf '0'; return 0; }
  while IFS= read -r path; do
    name="$(basename "${path}")"
    [[ "${name}" =~ ^pgpool-[0-9]{8}-[0-9]{6}$ ]] || continue
    count=$((count + 1))
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -name 'pgpool-*' -print)
  printf '%s' "${count}"
}

is_project_stage() {
  local stage="$1"
  [[ -f "${stage}/install.sh" && -f "${stage}/scripts/30-install-pgpool.sh" ]]
}

list_project_stages() {
  local search_root marker stage resolved
  for search_root in /var/tmp /opt/pg-readwrite-proxy-installer; do
    [[ -d "${search_root}" ]] || continue
    while IFS= read -r marker; do
      stage="$(dirname "$(dirname "${marker}")")"
      [[ ! -L "${stage}" && ! -L "${stage}/scripts" ]]
      resolved="$(readlink -f "${stage}")"
      case "${search_root}" in
        /var/tmp)
          [[ "$(dirname "${resolved}")" == /var/tmp ]] || continue
          ;;
        /opt/pg-readwrite-proxy-installer)
          [[ "${resolved}" == /opt/pg-readwrite-proxy-installer || \
             "${resolved}" == /opt/pg-readwrite-proxy-installer/* ]] || continue
          ;;
      esac
      is_project_stage "${resolved}" || continue
      printf '%s\n' "${resolved}"
    done < <(find "${search_root}" -xdev -type f -path '*/scripts/30-install-pgpool.sh' -print 2>/dev/null)
  done | sort -u
}

visit_project_stages() {
  local operation="$1"
  local stage config_dir runtime_config runtime_file runtime_config_present
  for stage in "${project_stages[@]}"; do
    config_dir="${stage}/config"
    if [[ -e "${config_dir}" || -L "${config_dir}" ]]; then
      [[ -d "${config_dir}" && ! -L "${config_dir}" && "$(readlink -f "${config_dir}")" == "${config_dir}" ]] || {
        printf 'Unexpected project config directory: %s\n' "${config_dir}" >&2
        exit 1
      }
    fi
    runtime_config_present=no
    for runtime_config in cluster.env secrets.env pool-users.txt; do
      runtime_file="${stage}/config/${runtime_config}"
      [[ ! -e "${runtime_file}" && ! -L "${runtime_file}" ]] && continue
      [[ -f "${runtime_file}" && ! -L "${runtime_file}" ]] || {
        printf 'Unexpected staged runtime-config type: %s\n' "${runtime_file}" >&2
        exit 1
      }
      runtime_config_present=yes
      [[ "${operation}" == count ]] && continue
      if command -v shred >/dev/null 2>&1; then
        shred -u -- "${runtime_file}"
      else
        rm -f -- "${runtime_file}"
      fi
    done
    [[ "${operation}" != count || "${runtime_config_present}" != yes ]] || printf '%s\n' "${stage}"
  done
}

read_env_value() {
  local file="$1" key="$2"
  awk -v key="${key}" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
      sub(/\r$/, "")
      value=$0
    }
    END { print value }
  ' "${file}"
}

collect_project_firewall_cidrs() {
  local stage cluster_env manage_firewall allowed_cidrs cidr
  local -a cidr_values=()
  for stage in "${project_stages[@]}"; do
    cluster_env="${stage}/config/cluster.env"
    [[ -f "${cluster_env}" && ! -L "${cluster_env}" ]] || continue
    manage_firewall="$(read_env_value "${cluster_env}" MANAGE_FIREWALL)"
    [[ "${manage_firewall}" == yes ]] || continue
    allowed_cidrs="$(read_env_value "${cluster_env}" ALLOWED_CLIENT_CIDRS)"
    [[ "${allowed_cidrs}" != \"*\" ]] || allowed_cidrs="${allowed_cidrs:1:${#allowed_cidrs}-2}"
    [[ "${allowed_cidrs}" != \'*\' ]] || allowed_cidrs="${allowed_cidrs:1:${#allowed_cidrs}-2}"
    IFS=',' read -r -a cidr_values <<<"${allowed_cidrs}"
    for cidr in "${cidr_values[@]}"; do
      cidr="${cidr#"${cidr%%[![:space:]]*}"}"
      cidr="${cidr%"${cidr##*[![:space:]]}"}"
      [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || {
        printf 'Unsafe ALLOWED_CLIENT_CIDRS value in %s; refusing reset.\n' "${cluster_env}" >&2
        exit 1
      }
      printf '%s\n' "${cidr}"
    done
  done
}

declare -a project_stages=()
project_stages_output="$(list_project_stages)"
if [[ -n "${project_stages_output}" ]]; then
  mapfile -t project_stages <<<"${project_stages_output}"
fi

stage_count="$(visit_project_stages count | awk 'END { print NR + 0 }')"
backup_count="$(count_config_backups)"
service_state="$(systemctl is-active "${PGPOOL_SERVICE}" 2>/dev/null || true)"
enabled_state="$(systemctl is-enabled "${PGPOOL_SERVICE}" 2>/dev/null || true)"
declare -a project_firewall_cidrs=()
firewall_cidrs_output="$(collect_project_firewall_cidrs | sort -u)"
if [[ -n "${firewall_cidrs_output}" ]]; then
  mapfile -t project_firewall_cidrs <<<"${firewall_cidrs_output}"
fi

printf 'PGPOOL_RESET_PREFLIGHT_OK\n'
printf 'INSTANCE_IP=%s\n' "${instance_ip}"
printf 'SERVICE_STATE=%s\n' "${service_state:-absent}"
printf 'SERVICE_ENABLED=%s\n' "${enabled_state:-absent}"
printf 'PGPOOL_RUNTIME=%s\n' "$([[ -d "${PGPOOL_PREFIX}" ]] && printf present || printf absent)"
printf 'CLIENT_RUNTIME=%s\n' "$([[ -d "${CLIENT_PREFIX}" ]] && printf present || printf absent)"
printf 'CONFIG_DIRECTORY=%s\n' "$([[ -d "${CONFIG_DIR}" ]] && printf present || printf absent)"
printf 'PGPOOL_PORT_%s=%s\n' "${PGPOOL_PORT}" "$(port_open "${PGPOOL_PORT}" && printf open || printf closed)"
printf 'PCP_PORT_%s=%s\n' "${PCP_PORT}" "$(port_open "${PCP_PORT}" && printf open || printf closed)"
printf 'HISTORICAL_CONFIG_BACKUPS=%s\n' "${backup_count}"
printf 'PROJECT_STAGES_WITH_SECRETS=%s\n' "${stage_count}"

[[ "$1" == "${CONFIRM_TOKEN}" ]] || exit 0

timestamp="$(date '+%Y%m%d-%H%M%S')"
audit_dir="${BACKUP_ROOT}/pgpool-reset-${timestamp}"
install -d -o root -g root -m 0700 "${audit_dir}"

# Retain metadata only. Pgpool configuration, pool_passwd, PCP credentials, and
# AES key are deliberately not copied into the reset audit.
{
  printf 'RESET_STARTED_AT=%s\n' "$(date --iso-8601=seconds)"
  printf 'INSTANCE_IP=%s\n' "${instance_ip}"
  printf 'SERVICE_STATE_BEFORE=%s\n' "${service_state:-absent}"
  printf 'SERVICE_ENABLED_BEFORE=%s\n' "${enabled_state:-absent}"
  printf 'HISTORICAL_CONFIG_BACKUPS_BEFORE=%s\n' "${backup_count}"
  printf 'PROJECT_STAGES_WITH_SECRETS_BEFORE=%s\n' "${stage_count}"
  if [[ -x "${PGPOOL_PREFIX}/bin/pgpool" ]]; then
    LD_LIBRARY_PATH="${CLIENT_PREFIX}/lib:${PGPOOL_PREFIX}/lib" \
      "${PGPOOL_PREFIX}/bin/pgpool" --version 2>&1 | head -n 1
  fi
  if [[ -x "${CLIENT_PREFIX}/bin/psql" ]]; then
    LD_LIBRARY_PATH="${CLIENT_PREFIX}/lib" "${CLIENT_PREFIX}/bin/psql" --version
  fi
  for tree in "${PGPOOL_PREFIX}" "${CLIENT_PREFIX}" "${CONFIG_DIR}" "${PGPOOL_HOME}" "${PGPOOL_LOG}"; do
    [[ ! -e "${tree}" ]] || stat -c 'TARGET=%n MODE=%a OWNER=%U:%G' "${tree}"
  done
} >"${audit_dir}/pre-reset-metadata.txt"
chmod 0600 "${audit_dir}/pre-reset-metadata.txt"

systemctl stop "${PGPOOL_SERVICE}" >/dev/null 2>&1 || true
systemctl disable "${PGPOOL_SERVICE}" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  pgrep -x pgpool >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -x pgpool >/dev/null 2>&1; then
  printf 'A pgpool process remains after service stop; refusing deletion.\n' >&2
  exit 1
fi
if port_open "${PGPOOL_PORT}" || port_open "${PCP_PORT}"; then
  printf 'Pgpool or PCP port remains open after service stop; refusing deletion.\n' >&2
  exit 1
fi

rm -f -- "${SERVICE_UNIT}"
systemctl daemon-reload
systemctl reset-failed "${PGPOOL_SERVICE}" >/dev/null 2>&1 || true

if getent passwd pgpool >/dev/null; then
  userdel pgpool
fi

remove_exact_tree() {
  local path="$1"
  [[ ! -e "${path}" && ! -L "${path}" ]] && return 0
  validate_exact_tree "${path}"
  rm -rf --one-file-system -- "${path}"
}

remove_exact_tree "${CONFIG_DIR}"
remove_exact_tree "${PGPOOL_PREFIX}"
remove_exact_tree "${CLIENT_PREFIX}"
remove_exact_tree "${PGPOOL_HOME}"
remove_exact_tree "${PGPOOL_LOG}"
remove_exact_tree "${PGPOOL_RUN}"

if getent group pgpool >/dev/null; then
  groupdel pgpool
fi

# Remove only timestamped Pgpool configuration backups created by
# scripts/31-configure-pgpool.sh. The current pgpool-reset-* metadata audit is
# excluded by the strict basename expression.
if [[ -d "${BACKUP_ROOT}" ]]; then
  while IFS= read -r backup_dir; do
    backup_name="$(basename "${backup_dir}")"
    [[ "${backup_name}" =~ ^pgpool-[0-9]{8}-[0-9]{6}$ ]] || continue
    [[ ! -L "${backup_dir}" ]]
    [[ "$(readlink -f "${backup_dir}")" == "${BACKUP_ROOT}/${backup_name}" ]]
    rm -rf --one-file-system -- "${backup_dir}"
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -name 'pgpool-*' -print)
fi

# Remove generated runtime config from verified project staging directories,
# while retaining installer code and offline media for the next test cycle.
visit_project_stages remove

# Remove only the rich rules owned by this project for the fixed Pgpool port.
firewall_rules_removed=0
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  for firewall_cidr in "${project_firewall_cidrs[@]}"; do
    firewall_rule="rule family=\"ipv4\" source address=\"${firewall_cidr}\" port port=\"${PGPOOL_PORT}\" protocol=\"tcp\" accept"
    firewall-cmd --permanent --query-rich-rule="${firewall_rule}" >/dev/null 2>&1 || continue
    firewall-cmd --permanent --remove-rich-rule="${firewall_rule}" >/dev/null
    firewall_rules_removed=$((firewall_rules_removed + 1))
  done
  ((firewall_rules_removed == 0)) || firewall-cmd --reload >/dev/null
fi

[[ ! -e "${SERVICE_UNIT}" && ! -L "${SERVICE_UNIT}" ]]
[[ "$(systemctl show -p LoadState "${PGPOOL_SERVICE}" 2>/dev/null || true)" == 'LoadState=not-found' ]]
[[ ! -e "${PGPOOL_PREFIX}" && ! -L "${PGPOOL_PREFIX}" ]]
[[ ! -e "${CLIENT_PREFIX}" && ! -L "${CLIENT_PREFIX}" ]]
[[ ! -e "${CONFIG_DIR}" && ! -L "${CONFIG_DIR}" ]]
[[ ! -e "${PGPOOL_HOME}" && ! -L "${PGPOOL_HOME}" ]]
[[ ! -e "${PGPOOL_LOG}" && ! -L "${PGPOOL_LOG}" ]]
[[ ! -e "${PGPOOL_RUN}" && ! -L "${PGPOOL_RUN}" ]]
! getent passwd pgpool >/dev/null
! getent group pgpool >/dev/null
! pgrep -x pgpool >/dev/null 2>&1
! port_open "${PGPOOL_PORT}"
! port_open "${PCP_PORT}"
[[ "$(count_config_backups)" == 0 ]]
[[ "$(visit_project_stages count | awk 'END { print NR + 0 }')" == 0 ]]

cat >"${audit_dir}/result.txt" <<RESULT
PGPOOL_ENVIRONMENT_RESET_OK
INSTANCE_IP=${instance_ip}
PGPOOL_RUNTIME_PRESENT=no
CLIENT_RUNTIME_PRESENT=no
PGPOOL_SERVICE_PRESENT=no
PGPOOL_ACCOUNT_PRESENT=no
PGPOOL_PORT_${PGPOOL_PORT}=closed
PCP_PORT_${PCP_PORT}=closed
HISTORICAL_CONFIG_BACKUPS=0
PROJECT_STAGES_WITH_SECRETS=0
FIREWALL_RULES_REMOVED=${firewall_rules_removed}
RESULT
chmod 0600 "${audit_dir}/result.txt"

printf 'PGPOOL_ENVIRONMENT_RESET_OK\n'
printf 'INSTANCE_IP=%s\n' "${instance_ip}"
printf 'AUDIT_METADATA=%s\n' "${audit_dir}"
printf 'PGPOOL_PORT_%s=closed\n' "${PGPOOL_PORT}"
printf 'PCP_PORT_%s=closed\n' "${PCP_PORT}"
