#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
detect_pgpool_platform
validate_offline_payloads
[[ "${PGPOOL_INSTALL_PREFIX}" == "/opt/pgpool-II-${PGPOOL_VERSION}" ]] || die 'Pgpool-II 安装前缀与载荷不匹配。'
[[ "${PG_CLIENT_PREFIX}" == '/opt/pgpool-client-12.0' ]] || die 'PostgreSQL 客户端安装前缀与载荷不匹配。'
[[ "${PGPOOL_RUNTIME_PREFIX}" == '/opt/pgpool-runtime-kylin-v10' ]] || die '麒麟私有运行库前缀与载荷不匹配。'
[[ ! -x /opt/pgsql12/bin/postgres ]] || die 'Pgpool-II 服务器不得安装或运行数据库服务端。'

systemctl stop "${PGPOOL_SERVICE}" >/dev/null 2>&1 || true
mkdir -p /opt
for prefix in "${PGPOOL_RUNTIME_PREFIX}" "${PG_CLIENT_PREFIX}" "${PGPOOL_INSTALL_PREFIX}"; do
  if [[ -e "${prefix}" || -L "${prefix}" ]]; then
    [[ -d "${prefix}" && ! -L "${prefix}" && "$(readlink -f -- "${prefix}")" == "${prefix}" ]] || \
      die "既有安装前缀不是安全目录，拒绝覆盖: ${prefix}"
  fi
done
tar -xzf "$(offline_file "${PGPOOL_RUNTIME_PAYLOAD_FILE}")" -C /opt
tar -xzf "$(offline_file "${PG_CLIENT_PAYLOAD_FILE}")" -C /opt
tar -xzf "$(offline_file "${PGPOOL_PAYLOAD_FILE}")" -C /opt
[[ -d "${PGPOOL_RUNTIME_PREFIX}/lib" && -f "${PGPOOL_RUNTIME_PREFIX}/BUILD-INFO.txt" ]] || die '麒麟私有运行库载荷解压不完整。'
[[ -x "${PG_CLIENT_PREFIX}/bin/psql" && -f "${PG_CLIENT_PREFIX}/lib/libpq.so.5" ]] || die 'PostgreSQL 12.0 客户端载荷解压不完整。'
[[ -x "${PGPOOL_INSTALL_PREFIX}/bin/pgpool" ]] || die 'Pgpool-II 载荷解压不完整。'

export LD_LIBRARY_PATH="${PGPOOL_RUNTIME_PREFIX}/lib:${PG_CLIENT_PREFIX}/lib:${PGPOOL_INSTALL_PREFIX}/lib"
[[ "$("${PG_CLIENT_PREFIX}/bin/psql" --version)" == 'psql (PostgreSQL) 12.0' ]] || die '离线客户端版本不是 PostgreSQL 12.0。'
version="$(${PGPOOL_INSTALL_PREFIX}/bin/pgpool --version 2>&1 | head -n 1)"
[[ "${version}" == *"${PGPOOL_VERSION}"* ]] || die "Pgpool-II 版本异常: ${version}"
if command -v ldd >/dev/null 2>&1; then
  missing="$(ldd "${PGPOOL_INSTALL_PREFIX}/bin/pgpool" "${PG_CLIENT_PREFIX}/bin/psql" 2>/dev/null | grep 'not found' || true)"
  [[ -z "${missing}" ]] || die "Pgpool/psql 动态库不完整: ${missing}"
fi

getent passwd pgpool >/dev/null || useradd --system --home-dir /var/lib/pgpool --create-home --shell /sbin/nologin pgpool
install -d -o pgpool -g pgpool -m 0755 /var/run/pgpool /var/log/pgpool
install -d -o root -g pgpool -m 0750 "${PGPOOL_CONFIG_DIR}"
cat >"/etc/systemd/system/${PGPOOL_SERVICE}.service" <<UNIT
[Unit]
Description=Pgpool-II ${PGPOOL_VERSION} PostgreSQL proxy
After=network.target

[Service]
Type=simple
User=pgpool
Group=pgpool
Environment=PGPOOLKEYFILE=${PGPOOL_CONFIG_DIR}/.pgpoolkey
Environment=LD_LIBRARY_PATH=${PGPOOL_RUNTIME_PREFIX}/lib:${PG_CLIENT_PREFIX}/lib:${PGPOOL_INSTALL_PREFIX}/lib
ExecStart=${PGPOOL_INSTALL_PREFIX}/bin/pgpool -n -f ${PGPOOL_CONFIG_DIR}/pgpool.conf -F ${PGPOOL_CONFIG_DIR}/pcp.conf -a ${PGPOOL_CONFIG_DIR}/pool_hba.conf
ExecReload=${PGPOOL_INSTALL_PREFIX}/bin/pgpool -f ${PGPOOL_CONFIG_DIR}/pgpool.conf reload
KillSignal=SIGTERM
Restart=on-failure
RestartSec=5
TimeoutStartSec=60
TimeoutStopSec=60
RuntimeDirectory=pgpool
RuntimeDirectoryMode=0755
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "/etc/systemd/system/${PGPOOL_SERVICE}.service"
systemctl daemon-reload
log "已离线安装 ${version} 和 PostgreSQL 12.0 客户端；Pgpool 节点没有数据库服务端。"
