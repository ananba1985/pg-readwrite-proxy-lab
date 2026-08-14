#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT}/enable-all-databases-users.sh"
PACKAGE_SCRIPT="${ROOT}/scripts/90-package-offline.sh"

[[ -f "${SCRIPT}" ]]

for required_text in \
  "readonly HBA_MARKER='PG_RW_PROXY_ALL_DATABASE_USERS'" \
  "host    all    all" \
  'pg_reload_conf()' \
  'systemctl reload "${PGPOOL_SERVICE}"' \
  'read -r -p '\''输入 APPLY 执行；其他输入直接退出且不修改配置:' \
  'REMOTE_SNAPSHOT=' \
  'system identifier 不一致' \
  'allow_clear_text_frontend_auth' \
  'password_rules'; do
  grep -Fq "${required_text}" "${SCRIPT}" || {
    printf '全库全用户脚本缺少合同: %s\n' "${required_text}" >&2
    exit 1
  }
done

grep -Fq '不重启数据库，不重新同步 Standby' "${SCRIPT}"
for forbidden_pattern in \
  'systemctl[[:space:]]+restart' \
  'pg_ctl[[:space:]]+(stop|restart)' \
  '^[[:space:]]*(CREATE|ALTER)[[:space:]]+ROLE' \
  '^[[:space:]]*GRANT[[:space:]]+ALL' \
  '^[[:space:]]*(local|host)[[:space:]].*[[:space:]]trust([[:space:]]|$)' \
  '(^|[;&|])[[:space:]]*([^[:space:]]*/)?pg_basebackup([[:space:]]|$)'; do
  ! grep -Eq "${forbidden_pattern}" "${SCRIPT}" || {
    printf '全库全用户脚本包含禁止动作模式: %s\n' "${forbidden_pattern}" >&2
    exit 1
  }
done

grep -Fq 'enable-all-databases-users.sh' "${PACKAGE_SCRIPT}"
grep -Fq 'enable-all-databases-users.sh' "${ROOT}/README.md"

printf 'ENABLE_ALL_DATABASES_USERS_CONTRACT_OK\n'
