#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(date +%Y%m%d)}"
DIST="${ROOT}/packages/dist"
NAME="pg-readwrite-proxy-offline-${VERSION}-kylin-v10-aarch64"
STAGE="$(mktemp -d /var/tmp/pg-rw-package.XXXXXX)"
cleanup() { [[ "${STAGE}" == /var/tmp/pg-rw-package.* ]] && rm -rf -- "${STAGE}"; }
trap cleanup EXIT

(cd "${ROOT}/packages" && sha256sum -c MANIFEST.sha256 && sha256sum -c SOURCES.sha256)
mkdir -p "${DIST}" "${STAGE}/${NAME}/packages/payload" "${STAGE}/${NAME}/packages/sources"

project_files=(
  README.md install.sh
  config/cluster.env.example config/secrets.env.example config/pool-users.txt.example
  docs/TEST_DATA.md docs/acceptance-report.md docs/failure-and-delay-tests.md docs/production-notes.md
  packages/README.md packages/MANIFEST.sha256 packages/SOURCES.sha256 packages/build-kylin-v10-payloads.sh
  scripts/00-preflight.sh scripts/05-readiness-check.sh scripts/06-state-fingerprint.sh
  scripts/07-count-business-sessions.sh scripts/10-configure-primary.sh
  scripts/20-install-postgresql-standby.sh scripts/21-bootstrap-standby.sh
  scripts/30-install-pgpool.sh scripts/31-configure-pgpool.sh
  scripts/40-verify-cluster.sh scripts/41-observe-cluster.sh scripts/42-verify-external-entry.sh
  scripts/43-test-delay.sh scripts/44-test-standby-health.sh scripts/50-reset-primary-test-data.sh
  scripts/90-package-offline.sh scripts/lib/common.sh
  scripts/sql/primary-test-data.sql scripts/sql/verify-primary-test-data.sql
  templates/pgpool.conf.tpl templates/pool_hba.conf.tpl templates/primary-pg_hba.entries.tpl
  templates/primary-postgresql.conf.tpl templates/standby-postgresql.conf.tpl
)
for project_file in "${project_files[@]}"; do
  [[ -f "${ROOT}/${project_file}" && ! -L "${ROOT}/${project_file}" ]] || {
    printf '[ERROR] 打包白名单文件缺失或为符号链接: %s\n' "${project_file}" >&2
    exit 1
  }
done
tar -C "${ROOT}" -cf - "${project_files[@]}" | tar -C "${STAGE}/${NAME}" -xf -
while IFS=$' \t' read -r hash relative; do
  cp -p -- "${ROOT}/packages/${relative}" "${STAGE}/${NAME}/packages/${relative}"
done <"${ROOT}/packages/MANIFEST.sha256"
while IFS=$' \t' read -r hash relative; do
  cp -p -- "${ROOT}/packages/${relative}" "${STAGE}/${NAME}/packages/${relative}"
done <"${ROOT}/packages/SOURCES.sha256"

find "${STAGE}/${NAME}" -type f \( -name '*.sh' -o -name '*.sql' -o -name '*.tpl' -o -name '*.env.example' -o -name '*.sha256' \) -exec sed -i 's/\r$//' {} +
chmod +x "${STAGE}/${NAME}/install.sh" "${STAGE}/${NAME}/scripts/"*.sh "${STAGE}/${NAME}/scripts/lib/"*.sh
find "${STAGE}/${NAME}" -type f -exec chmod go-w {} +
(cd "${STAGE}/${NAME}/packages" && sha256sum -c MANIFEST.sha256 && sha256sum -c SOURCES.sha256)
tar -C "${STAGE}" -czf "${DIST}/${NAME}.tar.gz" "${NAME}"
(cd "${DIST}" && sha256sum "${NAME}.tar.gz" >"${NAME}.tar.gz.sha256")
printf '%s\n' "${DIST}/${NAME}.tar.gz"
