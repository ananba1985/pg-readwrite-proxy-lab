#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
detect_el_major

installed_version() {
  [[ -x "${STANDBY_PG_BIN_DIR}/postgres" ]] || return 1
  "${STANDBY_PG_BIN_DIR}/postgres" --version | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1
}

current_version="$(installed_version || true)"
if [[ "${current_version}" == "${PG_VERSION_FULL}" ]]; then
  log "Standby 已预装匹配的 PostgreSQL ${current_version}，跳过软件安装。"
  exit 0
elif [[ -n "${current_version}" ]]; then
  die "Standby 已安装 PostgreSQL ${current_version}，但 Primary 是 ${PG_VERSION_FULL}；拒绝混用。"
fi

mode="${STANDBY_INSTALL_MODE}"
if [[ "${mode}" == 'auto' ]]; then
  if [[ "${EL_MAJOR}" == '7' || "${CPU_ARCH}" == 'aarch64' ]]; then
    bundle_dir="${POSTGRES_RPM_BUNDLE_DIR}"
    [[ "${bundle_dir}" == /* ]] || bundle_dir="${PROJECT_ROOT}/${bundle_dir}"
    if find "${bundle_dir}" -maxdepth 1 -type f -name '*.rpm' -print -quit 2>/dev/null | grep -q .; then
      mode='offline-rpm'
    else
      mode='source'
    fi
  else
    mode='rpm'
  fi
fi
log "Standby PostgreSQL 安装模式=${mode}，平台=EL${EL_MAJOR}/${CPU_ARCH}。"

case "${mode}" in
  preinstalled)
    die "STANDBY_INSTALL_MODE=preinstalled，但 ${STANDBY_PG_BIN_DIR}/postgres 不存在。"
    ;;
  offline-rpm)
    package_manager="$(command -v dnf 2>/dev/null || command -v yum 2>/dev/null || true)"
    [[ -n "${package_manager}" ]] || die '找不到 yum/dnf。'
    bundle_dir="${POSTGRES_RPM_BUNDLE_DIR}"
    [[ "${bundle_dir}" == /* ]] || bundle_dir="${PROJECT_ROOT}/${bundle_dir}"
    mapfile -t rpm_files < <(find "${bundle_dir}" -maxdepth 1 -type f -name '*.rpm' -print | sort)
    ((${#rpm_files[@]} > 0)) || die "离线 RPM 目录为空: ${bundle_dir}"
    "${package_manager}" localinstall -y "${rpm_files[@]}"
    ;;
  rpm)
    [[ "${EL_MAJOR}" =~ ^(8|9)$ && "${CPU_ARCH}" == 'x86_64' ]] || \
      die 'Pgpool/PostgreSQL 当前官方在线 RPM 路径只用于 EL8/9 x86_64；本平台请使用 source/offline-rpm。'
    require_command dnf
    repo_url="https://download.postgresql.org/pub/repos/yum/reporpms/EL-${EL_MAJOR}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    dnf install -y "${repo_url}"
    dnf -qy module disable postgresql >/dev/null 2>&1 || true
    dnf install -y "postgresql${PG_MAJOR}" "postgresql${PG_MAJOR}-server"
    ;;
  source)
    package_manager="$(command -v dnf 2>/dev/null || command -v yum 2>/dev/null || true)"
    [[ -n "${package_manager}" ]] || die '找不到 yum/dnf。'
    "${package_manager}" install -y gcc make tar bzip2 curl zlib-devel

    source_url="https://ftp.postgresql.org/pub/source/v${PG_VERSION_FULL}/postgresql-${PG_VERSION_FULL}.tar.bz2"
    checksum_url="${source_url}.sha256"
    build_root="$(mktemp -d /var/tmp/pg-rw-postgresql-build.XXXXXX)"
    archive="${build_root}/postgresql-${PG_VERSION_FULL}.tar.bz2"
    checksum_file="${archive}.sha256"
    curl --fail --location --silent --show-error "${source_url}" --output "${archive}"
    curl --fail --location --silent --show-error "${checksum_url}" --output "${checksum_file}"
    expected_hash="$(awk 'NR==1 {print $1}' "${checksum_file}")"
    actual_hash="$(sha256sum "${archive}" | awk '{print $1}')"
    [[ "${actual_hash}" == "${expected_hash}" ]] || die 'PostgreSQL 官方源码 SHA256 校验失败。'

    tar -xjf "${archive}" -C "${build_root}"
    source_dir="${build_root}/postgresql-${PG_VERSION_FULL}"
    prefix="${STANDBY_PG_BIN_DIR%/bin}"
    mkdir -p "$(dirname "${prefix}")"
    (
      cd "${source_dir}"
      ./configure \
        --prefix="${prefix}" \
        --without-readline \
        --with-blocksize="${PG_BLOCK_SIZE_KB}" \
        --with-wal-blocksize="${PG_WAL_BLOCK_SIZE_KB}" \
        --with-segsize="${PG_WAL_SEG_SIZE_MB}"
      make -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
      make install
      make -C contrib -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
      make -C contrib install
    )
    rm -rf -- "${build_root}"

    getent passwd "${PG_OS_USER}" >/dev/null || \
      useradd --system --home-dir /var/lib/pgsql --create-home --shell /bin/bash "${PG_OS_USER}"
    printf '%s/lib\n' "${prefix}" >"/etc/ld.so.conf.d/pg-rw-postgresql-${PG_MAJOR}.conf"
    ldconfig

    cat >"/etc/systemd/system/${STANDBY_SERVICE}.service" <<UNIT
[Unit]
Description=PostgreSQL ${PG_VERSION_FULL} Standby for pg-readwrite-proxy-lab
After=network.target

[Service]
Type=forking
User=${PG_OS_USER}
Group=${PG_OS_USER}
Environment=PGDATA=${STANDBY_PGDATA}
ExecStart=${STANDBY_PG_BIN_DIR}/pg_ctl start -D ${STANDBY_PGDATA} -s -w -t 300
ExecStop=${STANDBY_PG_BIN_DIR}/pg_ctl stop -D ${STANDBY_PGDATA} -s -m fast -w -t 300
ExecReload=${STANDBY_PG_BIN_DIR}/pg_ctl reload -D ${STANDBY_PGDATA} -s
PIDFile=${STANDBY_PGDATA}/postmaster.pid
TimeoutSec=320

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    ;;
  *)
    die "未知 Standby 安装模式: ${mode}"
    ;;
esac

[[ -x "${STANDBY_PG_BIN_DIR}/postgres" ]] || die "安装后仍找不到 ${STANDBY_PG_BIN_DIR}/postgres"
current_version="$(installed_version)"
[[ "${current_version}" == "${PG_VERSION_FULL}" ]] || \
  die "Standby PostgreSQL=${current_version}，Primary=${PG_VERSION_FULL}；物理复制要求尽量保持同一发行级别。"
systemctl stop "${STANDBY_SERVICE}" >/dev/null 2>&1 || true
log "Standby PostgreSQL ${current_version} 软件已准备；尚未初始化 PGDATA。"
