#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
repair_script="${ROOT}/repair.sh"
package_script="${ROOT}/scripts/90-package-offline.sh"

[[ -f "${repair_script}" ]]

for required_text in \
  'REQUEST_PRIMARY_HOST' \
  'source=current_command_only' \
  'prior_install_files=ignored' \
  'WAITING_FOR_CURRENT_INSTALL_OR_BASEBACKUP' \
  'BLOCKED_DATABASE' \
  'BLOCKED_PRIMARY_POLICY' \
  'primary_hba_policy_snapshot' \
  'primary_managed_role_snapshot' \
  'remote_credential_prerequisites' \
  'managed_credential_target_snapshot' \
  'scripts/11-rotate-managed-credentials.sh' \
  'scripts/22-resume-standby-after-basebackup.sh' \
  'scripts/23-update-standby-replication-passfile.sh' \
  'basebackup=not_run' \
  'PGPOOL_CLIENT_POLICY_FILE' \
  'scripts/30-install-pgpool.sh' \
  'scripts/31-configure-pgpool.sh' \
  'scripts/40-verify-cluster.sh'; do
  grep -Fq "${required_text}" "${repair_script}" || {
    printf 'repair.sh 缺少必需合同: %s\n' "${required_text}" >&2
    exit 1
  }
done

for forbidden_dependency in \
  'source "${CONFIG_DIR}/cluster.env"' \
  'source "${CONFIG_DIR}/secrets.env"' \
  '"${CONFIG_DIR}/${file}"'; do
  if grep -Fq "${forbidden_dependency}" "${repair_script}"; then
    printf 'repair.sh 禁止依赖上一次安装文件: %s\n' "${forbidden_dependency}" >&2
    exit 1
  fi
done

resume_script="${ROOT}/scripts/22-resume-standby-after-basebackup.sh"
[[ -f "${resume_script}" ]] || {
  printf '缺少 Standby 基础备份后续启脚本。\n' >&2
  exit 1
}
if grep -Eq 'runuser[^[:cntrl:]]+pg_basebackup|(^|[;&|])[[:space:]]*[^#[:cntrl:]]*/pg_basebackup([[:space:]]|$)' "${resume_script}"; then
  printf 'Standby 续启脚本禁止执行 pg_basebackup。\n' >&2
  exit 1
fi
if grep -Eq 'pg_ctl[^[:cntrl:]]+(-m[[:space:]]+fast[[:space:]]+stop|[[:space:]]+(stop|restart)([[:space:]]|$))' "${resume_script}"; then
  printf 'Standby 续启脚本禁止停止或重启数据库。\n' >&2
  exit 1
fi

for forbidden_call in \
  '${ROOT_DIR}/scripts/10-configure-primary.sh' \
  '${ROOT_DIR}/scripts/20-install-postgresql-standby.sh' \
  '${ROOT_DIR}/scripts/21-bootstrap-standby.sh' \
  './scripts/10-configure-primary.sh' \
  './scripts/20-install-postgresql-standby.sh' \
  './scripts/21-bootstrap-standby.sh'; do
  if grep -Fq "${forbidden_call}" "${repair_script}"; then
    printf 'repair.sh 禁止调用数据库部署脚本: %s\n' "${forbidden_call}" >&2
    exit 1
  fi
done

if grep -Eq 'pg_ctl_(stop|start)|pg_ctl[^[:cntrl:]]+(-m[[:space:]]+fast[[:space:]]+stop|[[:space:]]+(stop|start|restart)([[:space:]]|$))' "${repair_script}"; then
  printf 'repair.sh 禁止直接停止或启动数据库；Standby 续启必须经过专用受限脚本。\n' >&2
  exit 1
fi

for credential_script in \
  "${ROOT}/scripts/11-rotate-managed-credentials.sh" \
  "${ROOT}/scripts/23-update-standby-replication-passfile.sh"; do
  [[ -f "${credential_script}" ]] || {
    printf '缺少受管凭据修复脚本: %s\n' "${credential_script}" >&2
    exit 1
  }
  if grep -Eq 'pg_basebackup|pg_ctl[^[:cntrl:]]+[[:space:]]+(stop|start|restart)([[:space:]]|$)' "${credential_script}"; then
    printf '受管凭据修复脚本禁止基础备份或数据库启停: %s\n' "${credential_script}" >&2
    exit 1
  fi
done

if grep -Eq 'runuser[^[:cntrl:]]+pg_basebackup|(^|[;&|])[[:space:]]*[^#[:cntrl:]]*/pg_basebackup([[:space:]]|$)' "${repair_script}"; then
  printf 'repair.sh 禁止执行 pg_basebackup。\n' >&2
  exit 1
fi

grep -Eq 'project_files=\([^)]*' "${package_script}" || true
grep -Fq 'README.md install.sh repair.sh' "${package_script}" || {
  printf '离线包白名单缺少顶层 repair.sh。\n' >&2
  exit 1
}
grep -Fq 'scripts/tests/test-repair-no-resync-contract.sh' "${package_script}" || {
  printf '离线包白名单缺少 repair 防重同步测试。\n' >&2
  exit 1
}
grep -Fq 'scripts/lib/primary-client-policy.sh' "${package_script}" || {
  printf '离线包白名单缺少 Primary 客户端策略解析器。\n' >&2
  exit 1
}
grep -Fq 'scripts/22-resume-standby-after-basebackup.sh' "${package_script}" || {
  printf '离线包白名单缺少 Standby 基础备份后续启脚本。\n' >&2
  exit 1
}
grep -Fq 'scripts/11-rotate-managed-credentials.sh' "${package_script}" || {
  printf '离线包白名单缺少 Primary 受管凭据轮换脚本。\n' >&2
  exit 1
}
grep -Fq 'scripts/23-update-standby-replication-passfile.sh' "${package_script}" || {
  printf '离线包白名单缺少 Standby 复制密码文件更新脚本。\n' >&2
  exit 1
}
grep -Fq 'scripts/tests/test-primary-client-policy.sh' "${package_script}" || {
  printf '离线包白名单缺少 Primary 客户端策略测试。\n' >&2
  exit 1
}
grep -Fq 'scripts/tests/test-repair-stateless-contract.sh' "${package_script}" || {
  printf '离线包白名单缺少 repair 无状态合同测试。\n' >&2
  exit 1
}

printf 'REPAIR_NO_RESYNC_CONTRACT_OK\n'
