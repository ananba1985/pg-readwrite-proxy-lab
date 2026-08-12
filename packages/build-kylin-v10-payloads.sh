#!/usr/bin/env bash

# 在联网的麒麟 V10 ARM64 构建机上运行；正式内网安装不运行本脚本。
# 产物包含 PostgreSQL 客户端、Pgpool-II、sshpass 以及非 glibc 私有运行库闭包。
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/var/tmp/pg-rw-kylin-payload-build}"
CLIENT_PREFIX='/opt/pgpool-client-12.0'
PGPOOL_PREFIX='/opt/pgpool-II-4.7.2'
RUNTIME_PREFIX='/opt/pgpool-runtime-kylin-v10'
OUTPUT="${ROOT}/payload"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die '请以 root 运行。'
[[ "$(uname -m)" == aarch64 ]] || die '仅支持 aarch64 构建机。'
[[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == kylin && "${VERSION_ID:-}" == V10 ]] || die '仅支持 Kylin Linux Advanced Server V10。'

for command_name in gcc make tar gzip sha256sum strip readelf ldd rpm strings; do
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少构建命令: ${command_name}"
done
for package in glibc-devel openssl-devel libxcrypt-devel; do
  rpm -q "${package}" >/dev/null 2>&1 || die "缺少构建包: ${package}"
done
(cd "${ROOT}" && sha256sum -c SOURCES.sha256)

case "${BUILD_ROOT}" in /var/tmp/pg-rw-kylin-payload-build*) ;; *) die "不安全的 BUILD_ROOT: ${BUILD_ROOT}" ;; esac
for path in "${CLIENT_PREFIX}" "${PGPOOL_PREFIX}" "${RUNTIME_PREFIX}"; do
  [[ ! -e "${path}" ]] || die "构建前缀已存在，拒绝覆盖: ${path}"
done
rm -rf -- "${BUILD_ROOT}"
mkdir -p "${BUILD_ROOT}/client-stage" "${BUILD_ROOT}/pgpool-stage" \
  "${BUILD_ROOT}/runtime-stage${RUNTIME_PREFIX}/lib" \
  "${BUILD_ROOT}/runtime-stage${RUNTIME_PREFIX}/licenses" \
  "${BUILD_ROOT}/sshpass-stage/usr/local/bin" \
  "${BUILD_ROOT}/sshpass-stage/usr/local/share/licenses/sshpass" "${OUTPUT}"

cleanup_prefixes() {
  for path in "${CLIENT_PREFIX}" "${PGPOOL_PREFIX}" "${RUNTIME_PREFIX}"; do
    case "${path}" in
      /opt/pgpool-client-12.0|/opt/pgpool-II-4.7.2|/opt/pgpool-runtime-kylin-v10) rm -rf -- "${path}" ;;
    esac
  done
}
trap cleanup_prefixes EXIT

tar -xzf "${ROOT}/sources/postgresql-12.0.tar.gz" -C "${BUILD_ROOT}"
(
  cd "${BUILD_ROOT}/postgresql-12.0"
  LDFLAGS="-Wl,-rpath,${RUNTIME_PREFIX}/lib" \
    ./configure --prefix="${CLIENT_PREFIX}" --with-openssl --without-readline --without-zlib
  # PostgreSQL 12 的子目录 Makefile 在 GNU make 4.3 并行执行时可能先链接
  # libpq、后生成 libpgcommon_shlib；显式串行完成两个前置库以消除竞态。
  make -C src/port all
  make -C src/common all
  make -C src/interfaces/libpq -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/bin/psql -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/bin/pg_config -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/bin/scripts -j "$(getconf _NPROCESSORS_ONLN)"
  make -C src/interfaces/libpq DESTDIR="${BUILD_ROOT}/client-stage" install
  make -C src/bin/psql DESTDIR="${BUILD_ROOT}/client-stage" install
  make -C src/bin/pg_config DESTDIR="${BUILD_ROOT}/client-stage" install
  make -C src/bin/scripts DESTDIR="${BUILD_ROOT}/client-stage" install
  make -C src/include DESTDIR="${BUILD_ROOT}/client-stage" install
)
strip "${BUILD_ROOT}/client-stage${CLIENT_PREFIX}/bin/"* \
  "${BUILD_ROOT}/client-stage${CLIENT_PREFIX}/lib/libpq.so.5.12" 2>/dev/null || true
tar --sort=name --mtime='UTC 2026-08-12' --owner=0 --group=0 --numeric-owner \
  -C "${BUILD_ROOT}/client-stage/opt" \
  -czf "${OUTPUT}/postgresql-client-12.0-aarch64-kylin-v10.tar.gz" pgpool-client-12.0
mkdir -p /opt
tar -C /opt -xzf "${OUTPUT}/postgresql-client-12.0-aarch64-kylin-v10.tar.gz"

tar -xzf "${ROOT}/sources/pgpool-II-4.7.2.tar.gz" -C "${BUILD_ROOT}"
(
  cd "${BUILD_ROOT}/pgpool-II-4.7.2"
  CPPFLAGS="-I${CLIENT_PREFIX}/include" \
  LDFLAGS="-Wl,-rpath,${CLIENT_PREFIX}/lib:${RUNTIME_PREFIX}/lib:${PGPOOL_PREFIX}/lib" \
    ./configure --prefix="${PGPOOL_PREFIX}" --with-pgsql="${CLIENT_PREFIX}" --with-openssl
  make -j "$(getconf _NPROCESSORS_ONLN)"
  make DESTDIR="${BUILD_ROOT}/pgpool-stage" install
)
# 运行时不需要供二次开发链接的静态/libtool 归档；其中还会保留编译目录调试字符串。
rm -f -- "${BUILD_ROOT}/pgpool-stage${PGPOOL_PREFIX}/lib/"*.a \
  "${BUILD_ROOT}/pgpool-stage${PGPOOL_PREFIX}/lib/"*.la
strip "${BUILD_ROOT}/pgpool-stage${PGPOOL_PREFIX}/bin/"* \
  "${BUILD_ROOT}/pgpool-stage${PGPOOL_PREFIX}/lib/"*.so* 2>/dev/null || true
tar --sort=name --mtime='UTC 2026-08-12' --owner=0 --group=0 --numeric-owner \
  -C "${BUILD_ROOT}/pgpool-stage/opt" \
  -czf "${OUTPUT}/pgpool-II-4.7.2-pg12.0-aarch64-kylin-v10.tar.gz" pgpool-II-4.7.2
tar -C /opt -xzf "${OUTPUT}/pgpool-II-4.7.2-pg12.0-aarch64-kylin-v10.tar.gz"

tar -xzf "${ROOT}/sources/sshpass-1.10.tar.gz" -C "${BUILD_ROOT}"
(
  cd "${BUILD_ROOT}/sshpass-1.10"
  ./configure --prefix=/usr/local
  make -j "$(getconf _NPROCESSORS_ONLN)"
  strip sshpass
  install -m 0755 sshpass "${BUILD_ROOT}/sshpass-stage/usr/local/bin/sshpass"
  install -m 0644 COPYING "${BUILD_ROOT}/sshpass-stage/usr/local/share/licenses/sshpass/COPYING"
)
tar --sort=name --mtime='UTC 2026-08-12' --owner=0 --group=0 --numeric-owner \
  -C "${BUILD_ROOT}/sshpass-stage" \
  -czf "${OUTPUT}/sshpass-1.10-aarch64-kylin-v10.tar.gz" .

# 从实际 ldd 结果收集所有非 glibc 核心依赖，并保存其 RPM 许可证。
runtime_lib="${BUILD_ROOT}/runtime-stage${RUNTIME_PREFIX}/lib"
runtime_licenses="${BUILD_ROOT}/runtime-stage${RUNTIME_PREFIX}/licenses"
is_glibc_core_soname() {
  case "$1" in
    linux-vdso.so.*|ld-linux-aarch64.so.*|libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) return 0 ;;
    *) return 1 ;;
  esac
}
mapfile -t audit_binaries < <(find "${CLIENT_PREFIX}" "${PGPOOL_PREFIX}" -type f -perm /111 -print | sort)
declare -A copied_packages=()
for binary in "${audit_binaries[@]}"; do
  while IFS=' ' read -r soname arrow resolved remainder; do
    [[ "${arrow}" == '=>' && "${resolved}" == /* ]] || continue
    is_glibc_core_soname "${soname}" && continue
    real="$(readlink -f -- "${resolved}")"
    [[ -f "${real}" ]] || die "动态库不存在: ${resolved}"
    # 项目自带的 libpq/libpgpoolpcp 已在各自载荷中，不能重复收进系统运行库闭包。
    case "${real}" in
      "${CLIENT_PREFIX}"/*|"${PGPOOL_PREFIX}"/*) continue ;;
    esac
    # ldd 在解析依赖的依赖时会输出 glibc 的真实文件名（如 libc-2.28.so），
    # 其 soname 字段不再是 libc.so.6；通过 RPM 归属再次阻止复制 glibc/加载器。
    owner_name="$(rpm -qf --qf '%{NAME}\n' "${real}" 2>/dev/null || true)"
    [[ "${owner_name}" != glibc && "${owner_name}" != glibc-* ]] || continue
    [[ "${owner_name}" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || \
      die "系统动态库没有可审计的 RPM 归属: ${real} (${owner_name:-none})"
    real_basename="$(basename "${real}")"
    cp -p -- "${real}" "${runtime_lib}/${real_basename}"
    [[ "${real_basename}" == "${soname}" ]] || ln -sfn "${real_basename}" "${runtime_lib}/${soname}"
    package="${owner_name}"
    copied_packages["${package}"]=1
  done < <(ldd "${binary}" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g' || true)
done
((${#copied_packages[@]} > 0)) || die '没有收集到任何私有动态库，拒绝生成空运行库载荷。'
if find "${runtime_lib}" -maxdepth 1 \( -name 'libc.so*' -o -name 'libc-*.so' -o -name 'libm.so*' -o -name 'libm-*.so' \
  -o -name 'libpthread.so*' -o -name 'libpthread-*.so' -o -name 'libdl.so*' -o -name 'libdl-*.so' \
  -o -name 'libresolv.so*' -o -name 'libresolv-*.so' -o -name 'ld-linux*' \) -print -quit | grep -q .; then
  die '私有运行库错误包含 glibc 核心文件。'
fi
for required_soname in libssl.so.1.1 libcrypto.so.1.1 libcrypt.so.1 libnsl.so.2; do
  [[ -L "${runtime_lib}/${required_soname}" && -f "${runtime_lib}/$(readlink "${runtime_lib}/${required_soname}")" ]] || \
    die "私有运行库缺少或存在失效链接: ${required_soname}。"
done
for package in "${!copied_packages[@]}"; do
  license_dir="${runtime_licenses}/${package}"
  mkdir -p "${license_dir}"
  while IFS= read -r license; do
    [[ -f "${license}" ]] && cp -p -- "${license}" "${license_dir}/"
  done < <(rpm -ql "${package}" | grep -E '^/usr/share/(licenses|doc)/' || true)
done
cat >"${BUILD_ROOT}/runtime-stage${RUNTIME_PREFIX}/BUILD-INFO.txt" <<INFO
Platform: Kylin Linux Advanced Server V10 (Halberd) aarch64
glibc build baseline: $(getconf GNU_LIBC_VERSION)
Private library packages: $(printf '%s ' "${!copied_packages[@]}")
Purpose: pg-readwrite-proxy-lab runtime only
INFO
tar --sort=name --mtime='UTC 2026-08-12' --owner=0 --group=0 --numeric-owner \
  -C "${BUILD_ROOT}/runtime-stage/opt" \
  -czf "${OUTPUT}/pgpool-runtime-kylin-v10-aarch64.tar.gz" pgpool-runtime-kylin-v10
tar -C /opt -xzf "${OUTPUT}/pgpool-runtime-kylin-v10-aarch64.tar.gz"

export LD_LIBRARY_PATH="${RUNTIME_PREFIX}/lib:${CLIENT_PREFIX}/lib:${PGPOOL_PREFIX}/lib"
[[ "$("${CLIENT_PREFIX}/bin/psql" --version)" == 'psql (PostgreSQL) 12.0' ]] || die 'psql 版本异常。'
"${PGPOOL_PREFIX}/bin/pgpool" --version 2>&1 | grep -F "4.7.2" >/dev/null || die 'Pgpool 版本异常。'
"${BUILD_ROOT}/sshpass-stage/usr/local/bin/sshpass" -V 2>&1 | grep -F 'sshpass 1.10' >/dev/null || die 'sshpass 版本异常。'
for binary in "${audit_binaries[@]}" "${BUILD_ROOT}/sshpass-stage/usr/local/bin/sshpass"; do
  missing="$(ldd "${binary}" 2>/dev/null | grep 'not found' || true)"
  [[ -z "${missing}" ]] || die "动态库闭包不完整: ${binary}: ${missing}"
done
for binary in "${CLIENT_PREFIX}/bin/psql" "${PGPOOL_PREFIX}/bin/pgpool"; do
  readelf -d "${binary}" | grep -E 'RPATH|RUNPATH' || die "缺少 RPATH: ${binary}"
done
if find "${CLIENT_PREFIX}" "${PGPOOL_PREFIX}" -type f -print0 | xargs -0 strings | grep -F "${BUILD_ROOT}" >/dev/null; then
  die '产物包含临时构建路径。'
fi

(cd "${OUTPUT}" && sha256sum \
  pgpool-II-4.7.2-pg12.0-aarch64-kylin-v10.tar.gz \
  postgresql-client-12.0-aarch64-kylin-v10.tar.gz \
  pgpool-runtime-kylin-v10-aarch64.tar.gz \
  sshpass-1.10-aarch64-kylin-v10.tar.gz >MANIFEST.generated.sha256)
cat "${OUTPUT}/MANIFEST.generated.sha256"
printf 'Kylin V10 aarch64 构建完成。\n'
