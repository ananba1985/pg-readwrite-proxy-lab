#!/usr/bin/env bash

# 只在 CentOS 7 aarch64 联网/构建机上运行；生产内网部署不运行本脚本。
# 构建独立 PostgreSQL 12.0 客户端和链接到该客户端的 Pgpool-II，不构建数据库服务端。
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(uname -m)" == aarch64 ]] || { echo '仅支持 aarch64 构建机' >&2; exit 1; }
grep -q 'release 7\.' /etc/centos-release || { echo '仅支持 CentOS 7 构建机' >&2; exit 1; }
(cd "${ROOT}" && sha256sum -c SOURCES.sha256)

work="$(mktemp -d /var/tmp/pg-rw-payload-build.XXXXXX)"
cleanup() { [[ "${work}" == /var/tmp/pg-rw-payload-build.* ]] && rm -rf -- "${work}"; }
trap cleanup EXIT
mkdir -p "${ROOT}/payload" "${work}/client-stage" "${work}/pgpool-stage" \
  "${work}/sshpass-stage/usr/local/bin" "${work}/sshpass-stage/usr/local/share/licenses/sshpass"

tar -xzf "${ROOT}/sources/postgresql-12.0.tar.gz" -C "${work}"
(
  cd "${work}/postgresql-12.0"
  ./configure --prefix=/opt/pgpool-client-12.0 --with-openssl
  make -C src/interfaces/libpq -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/bin/psql -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/bin/pg_config -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/bin/scripts -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/interfaces/libpq DESTDIR="${work}/client-stage" install
  make -C src/bin/psql DESTDIR="${work}/client-stage" install
  make -C src/bin/pg_config DESTDIR="${work}/client-stage" install
  make -C src/bin/scripts DESTDIR="${work}/client-stage" install
  make -C src/include DESTDIR="${work}/client-stage" install
)
strip "${work}/client-stage/opt/pgpool-client-12.0/bin/"* "${work}/client-stage/opt/pgpool-client-12.0/lib/libpq.so.5.12" 2>/dev/null || true
tar -C "${work}/client-stage/opt" -czf "${ROOT}/payload/postgresql-client-12.0-aarch64-centos7.tar.gz" pgpool-client-12.0

# 构建机临时安装客户端到最终前缀，使 Pgpool 只记录最终 RPATH；结束后不自动删除既有同名目录。
[[ ! -e /opt/pgpool-client-12.0 ]] || { echo '/opt/pgpool-client-12.0 已存在，拒绝覆盖' >&2; exit 1; }
tar -C /opt -xzf "${ROOT}/payload/postgresql-client-12.0-aarch64-centos7.tar.gz"
client_created=yes
cleanup_client() { [[ "${client_created:-}" == yes && -d /opt/pgpool-client-12.0 ]] && rm -rf -- /opt/pgpool-client-12.0; cleanup; }
trap cleanup_client EXIT

tar -xzf "${ROOT}/sources/pgpool-II-4.7.2.tar.gz" -C "${work}"
(
  cd "${work}/pgpool-II-4.7.2"
  LDFLAGS='-Wl,-rpath,/opt/pgpool-client-12.0/lib' \
    ./configure --prefix=/opt/pgpool-II-4.7.2 --with-pgsql=/opt/pgpool-client-12.0 --with-openssl
  make -j "$(getconf _NPROCESSORS_ONLN)"
  make DESTDIR="${work}/pgpool-stage" install
)
strip "${work}/pgpool-stage/opt/pgpool-II-4.7.2/bin/"* 2>/dev/null || true
tar -C "${work}/pgpool-stage/opt" -czf "${ROOT}/payload/pgpool-II-4.7.2-pg12.0-aarch64-centos7.tar.gz" pgpool-II-4.7.2

tar -xzf "${ROOT}/sources/sshpass-1.10.tar.gz" -C "${work}"
(
  cd "${work}/sshpass-1.10"
  ./configure --prefix=/usr/local
  make -j "$(getconf _NPROCESSORS_ONLN)"
  strip sshpass
  install -m 0755 sshpass "${work}/sshpass-stage/usr/local/bin/sshpass"
  install -m 0644 COPYING "${work}/sshpass-stage/usr/local/share/licenses/sshpass/COPYING"
)
tar -C "${work}/sshpass-stage" -czf "${ROOT}/payload/sshpass-1.10-aarch64-centos7.tar.gz" .
(cd "${ROOT}" && sha256sum payload/pgpool-II-4.7.2-pg12.0-aarch64-centos7.tar.gz \
  payload/postgresql-client-12.0-aarch64-centos7.tar.gz payload/sshpass-1.10-aarch64-centos7.tar.gz \
  >MANIFEST.generated.sha256)
echo '构建完成。复核动态库与许可证后，将 MANIFEST.generated.sha256 审批更新为 MANIFEST.sha256。'
