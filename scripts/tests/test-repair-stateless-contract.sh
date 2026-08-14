#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
repair_script="${ROOT}/repair.sh"

for required_text in \
  'source=current_command_only' \
  'prior_install_files=ignored' \
  'old_config_dir_access=no' \
  'mktemp -d /var/tmp/pg-rw-repair-config.XXXXXX' \
  'write_env "${secrets_file}" REPLICATION_PASSWORD "$(random_secret)"' \
  'write_env "${secrets_file}" MONITOR_PASSWORD "$(random_secret)"' \
  'write_env "${secrets_file}" BUSINESS_PASSWORD "${REQUEST_BUSINESS_PASSWORD}"' \
  'rotate_installer_managed_credentials' \
  'scripts/11-rotate-managed-credentials.sh' \
  'scripts/23-update-standby-replication-passfile.sh'; do
  grep -Fq "${required_text}" "${repair_script}" || {
    printf 'repair.sh 缺少无状态合同: %s\n' "${required_text}" >&2
    exit 1
  }
done

for forbidden_text in \
  'CLUSTER_CONFIG="${CONFIG_DIR}/cluster.env"' \
  'SECRETS_CONFIG="${CONFIG_DIR}/secrets.env"' \
  'POOL_USERS_FILE="${CONFIG_DIR}/pool-users.txt"' \
  'assert_input_matches' \
  '必须保留 ${CONFIG_DIR}' \
  '"${CONFIG_DIR}/${file}"'; do
  if grep -Fq "${forbidden_text}" "${repair_script}"; then
    printf 'repair.sh 仍依赖上一次安装文件: %s\n' "${forbidden_text}" >&2
    exit 1
  fi
done

if grep -Fq 'standby-bootstrap.state' "${repair_script}" || \
   grep -Fq 'standby-bootstrap.state' "${ROOT}/scripts/22-resume-standby-after-basebackup.sh"; then
  printf 'repair 续启禁止依赖上一次安装状态文件。\n' >&2
  exit 1
fi

printf 'REPAIR_STATELESS_CONTRACT_OK\n'
