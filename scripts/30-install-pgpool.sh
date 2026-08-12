#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_cluster_config
detect_el_major
require_command dnf

# Pgpool-II 的 PG_MAJOR 变体依赖对应 libpq；先安装 PostgreSQL 官方客户端。
pgdg_repo="https://download.postgresql.org/pub/repos/yum/reporpms/EL-${EL_MAJOR}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
dnf install -y "${pgdg_repo}"
dnf -qy module disable postgresql >/dev/null 2>&1 || true
dnf install -y "postgresql${PG_MAJOR}"

# 使用 Pgpool Global Development Group 官方 4.7 仓库。
pgpool_repo="https://www.pgpool.net/yum/rpms/${PGPOOL_MAJOR}/redhat/rhel-${EL_MAJOR}-x86_64/pgpool-II-release-${PGPOOL_MAJOR}-1.noarch.rpm"
dnf install -y "${pgpool_repo}"
# PGDG 也可能发布同名包；安装时禁用 PGDG 仓库，确保来源是 Pgpool 官方仓库。
dnf install -y --disablerepo='pgdg*' "pgpool-II-pg${PG_MAJOR}"

pgpool_bin="$(find_pgpool_binary pgpool)"
installed_version="$(${pgpool_bin} --version 2>&1 | head -n 1)"
[[ "${installed_version}" == *"${PGPOOL_MAJOR}."* ]] || die "Pgpool-II 版本异常: ${installed_version}"
systemctl stop "${PGPOOL_SERVICE}" >/dev/null 2>&1 || true
log "已安装 ${installed_version}；尚未启动服务。"
