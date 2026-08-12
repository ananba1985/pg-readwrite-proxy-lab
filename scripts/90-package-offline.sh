#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(date +%Y%m%d)}"
DIST="${ROOT}/packages/dist"
NAME="pg-readwrite-proxy-offline-${VERSION}-centos7-aarch64"
STAGE="$(mktemp -d /var/tmp/pg-rw-package.XXXXXX)"
cleanup() { [[ "${STAGE}" == /var/tmp/pg-rw-package.* ]] && rm -rf -- "${STAGE}"; }
trap cleanup EXIT

(cd "${ROOT}/packages" && sha256sum -c MANIFEST.sha256 && sha256sum -c SOURCES.sha256)
mkdir -p "${DIST}" "${STAGE}/${NAME}/packages/payload" "${STAGE}/${NAME}/packages/sources"

tar --exclude='./.git' --exclude='./vm' --exclude='./packages/sources' --exclude='./packages/payload' --exclude='./packages/dist' \
  --exclude='./config/cluster.env' --exclude='./config/secrets.env' --exclude='./config/pool-users.txt' \
  --exclude='./NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz' \
  --exclude='./PG_Safe_tool.tar.gz' --exclude='./gen_license-arm64' --exclude='./artifacts' \
  -C "${ROOT}" -cf - . | tar -C "${STAGE}/${NAME}" -xf -
while IFS=$' \t' read -r hash relative; do
  cp -p -- "${ROOT}/packages/${relative}" "${STAGE}/${NAME}/packages/${relative}"
done <"${ROOT}/packages/MANIFEST.sha256"
while IFS=$' \t' read -r hash relative; do
  cp -p -- "${ROOT}/packages/${relative}" "${STAGE}/${NAME}/packages/${relative}"
done <"${ROOT}/packages/SOURCES.sha256"

find "${STAGE}/${NAME}" -type f \( -name '*.sh' -o -name '*.sql' -o -name '*.tpl' -o -name '*.env.example' \) -exec sed -i 's/\r$//' {} +
chmod +x "${STAGE}/${NAME}/install.sh" "${STAGE}/${NAME}/scripts/"*.sh "${STAGE}/${NAME}/scripts/lib/"*.sh
find "${STAGE}/${NAME}" -type f -exec chmod go-w {} +
(cd "${STAGE}/${NAME}/packages" && sha256sum -c MANIFEST.sha256 && sha256sum -c SOURCES.sha256)
tar -C "${STAGE}" -czf "${DIST}/${NAME}.tar.gz" "${NAME}"
(cd "${DIST}" && sha256sum "${NAME}.tar.gz" >"${NAME}.tar.gz.sha256")
printf '%s\n' "${DIST}/${NAME}.tar.gz"
