#!/usr/bin/env bash

# install.sh 的启动参数与交互补全。调用方需先定义 die()。

show_install_usage() {
  cat <<'USAGE'
用法：
  sudo bash install.sh [参数]

所有参数同时支持“--参数 值”和“--参数=值”。未提供的参数会在启动阶段交互补全。

参数：
  --pgpool-host IP                 当前 Pgpool-II 服务器内网 IPv4
  --primary-host IP                现有 PostgreSQL Primary 内网 IPv4
  --standby-host IP                PostgreSQL Standby 目标机内网 IPv4
  --postgresql-port PORT           Primary/Standby 共用 PostgreSQL 端口，默认 5432
  --pgpool-port PORT               Pgpool-II 对外服务端口，默认 5432
  --ssh-port PORT                  Primary/Standby 共用 root SSH 端口，默认 22
  --allowed-client-cidrs CIDRS     允许访问 Pgpool 的 IPv4 CIDR，多个值用逗号分隔
  --manage-pgpool-firewall yes|no  是否由安装器管理 Pgpool firewalld，默认 yes
  --business-user USER             现有业务数据库用户名
  --business-database DATABASE     现有业务数据库名
  --root-ssh-password PASSWORD     Primary/Standby 共用 root SSH 密码
  --business-password PASSWORD     现有业务数据库用户密码
  -h, --help                       显示帮助

全部只读检查通过后，数据库连接非零时会显示退出/强制中断菜单，随后仍需输入 APPLY 才开始部署。
USAGE
}

initialize_install_inputs() {
  PGPOOL_HOST=''
  PRIMARY_HOST=''
  STANDBY_HOST=''
  PRIMARY_PORT=''
  PGPOOL_PORT=''
  SSH_PORT=''
  ALLOWED_CLIENT_CIDRS=''
  MANAGE_PGPOOL_FIREWALL=''
  BUSINESS_USER=''
  BUSINESS_DATABASE=''
  ROOT_SSH_PASSWORD=''
  BUSINESS_PASSWORD=''
}

parse_install_inputs() {
  local argument option value
  declare -A seen_options=()
  while (($# > 0)); do
    argument="$1"
    case "${argument}" in
      -h|--help)
        show_install_usage
        exit 0
        ;;
      --*=*)
        option="${argument%%=*}"
        value="${argument#*=}"
        shift
        ;;
      --*)
        option="${argument}"
        (($# >= 2)) || die "参数缺少值: ${option}"
        value="$2"
        shift 2
        ;;
      *)
        die "不支持的位置参数: ${argument}；使用 --help 查看用法。"
        ;;
    esac
    [[ -n "${value}" ]] || die "参数值不能为空: ${option}"
    [[ -z "${seen_options[${option}]:-}" ]] || die "参数不能重复提供: ${option}"
    seen_options["${option}"]=1
    case "${option}" in
      --pgpool-host) PGPOOL_HOST="${value}" ;;
      --primary-host) PRIMARY_HOST="${value}" ;;
      --standby-host) STANDBY_HOST="${value}" ;;
      --postgresql-port) PRIMARY_PORT="${value}" ;;
      --pgpool-port) PGPOOL_PORT="${value}" ;;
      --ssh-port) SSH_PORT="${value}" ;;
      --allowed-client-cidrs) ALLOWED_CLIENT_CIDRS="${value}" ;;
      --manage-pgpool-firewall) MANAGE_PGPOOL_FIREWALL="${value}" ;;
      --business-user) BUSINESS_USER="${value}" ;;
      --business-database) BUSINESS_DATABASE="${value}" ;;
      --root-ssh-password) ROOT_SSH_PASSWORD="${value}" ;;
      --business-password) BUSINESS_PASSWORD="${value}" ;;
      *) die "未知参数: ${option}；使用 --help 查看用法。" ;;
    esac
  done
}

prompt_default() {
  local variable_name="$1" prompt_text="$2" default_value="$3" value="${!1:-}"
  if [[ -z "${value}" ]]; then
    read -r -p "${prompt_text} [${default_value}]: " value || \
      die "未通过启动参数提供 ${variable_name}，且无法读取交互输入。"
    value="${value:-${default_value}}"
  fi
  printf -v "${variable_name}" '%s' "${value}"
}

prompt_secret() {
  local variable_name="$1" prompt_text="$2" colon_policy="${3:-deny}" value="${!1:-}"
  while [[ -z "${value}" ]]; do
    read -r -s -p "${prompt_text}: " value || \
      die "未通过启动参数提供 ${variable_name}，且无法读取交互输入。"
    printf '\n'
  done
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die '密码不能包含换行。'
  [[ "${colon_policy}" == allow || "${value}" != *:* ]] || die '数据库密码不能包含冒号。'
  printf -v "${variable_name}" '%s' "${value}"
}

confirm_force_restart_with_clients() {
  local primary_sessions="$1" standby_sessions="$2" choice
  [[ "${primary_sessions}" =~ ^[0-9]+$ && "${standby_sessions}" =~ ^[0-9]+$ ]] || \
    die '数据库连接数不是有效数字，拒绝显示强制重启菜单。'
  if ((primary_sessions == 0 && standby_sessions == 0)); then
    FORCE_DB_RESTART_WITH_CLIENTS='no'
    return
  fi

  cat >&2 <<MENU

[WARN] 检测到数据库客户端连接：Primary=${primary_sessions}，Standby=${standby_sessions}。
[WARN] 强制继续会在实际停机前再次统计，并使用 pg_ctl fast stop 中断仍存在的会话；
[WARN] 未提交事务会回滚，客户端连接会断开。请先确认业务已经停止写入。

请选择操作：
  1) 退出部署，不修改任何持久配置
  2) 我已确认业务停止写入，允许中断连接并强制重启/重建数据库
MENU
  while true; do
    read -r -p '请输入 1 或 2: ' choice || die '无法读取数据库强制重启菜单选择。'
    case "${choice}" in
      1) die '用户取消；所有服务器均未执行部署变更。' ;;
      2) FORCE_DB_RESTART_WITH_CLIENTS='yes'; return ;;
      *) printf '[WARN] 无效选择，请输入 1 或 2。\n' >&2 ;;
    esac
  done
}
