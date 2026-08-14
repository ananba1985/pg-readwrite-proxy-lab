#!/usr/bin/env bash

# 只读检查 Pgpool 本机 5432 监听和防火墙状态。
# 不修改服务、防火墙、路由、内核参数或 Pgpool 配置。
set -uo pipefail
IFS=$'\n\t'

PORT="${1:-5432}"
LOG_FILE="/var/tmp/pgpool-port-check-$(date '+%Y%m%d-%H%M%S')-$$.log"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die '请使用 root 运行此脚本。'
[[ "${PORT}" =~ ^[0-9]{1,5}$ ]] && ((10#${PORT} >= 1 && 10#${PORT} <= 65535)) || \
  die "端口无效: ${PORT}"

for command_name in date tee systemctl ss ip grep awk timeout; do
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少命令: ${command_name}"
done

umask 077
touch "${LOG_FILE}" || die "无法创建日志: ${LOG_FILE}"
chmod 600 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

section() {
  printf '\n========== %s ==========\n' "$1"
}

run_if_exists() {
  local command_name="$1"
  shift
  if command -v "${command_name}" >/dev/null 2>&1; then
    "$@" 2>&1 || printf '[INFO] command=%s exit=%s\n' "${command_name}" "$?"
  else
    printf '[INFO] command_missing=%s\n' "${command_name}"
  fi
}

section '基本信息'
printf 'CHECK_TIME=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
printf 'CHECK_MODE=read_only changes=no\n'
printf 'PORT=%s\nLOG_FILE=%s\n' "${PORT}" "${LOG_FILE}"
hostname 2>&1 || true
uname -a 2>&1 || true
ip -br -4 address show 2>&1 || true
ip -4 route show 2>&1 || true

section 'Pgpool 服务'
pgpool_active="$(systemctl is-active pgpool 2>/dev/null || true)"
pgpool_enabled="$(systemctl is-enabled pgpool 2>/dev/null || true)"
printf 'PGPOOL_ACTIVE=%s\nPGPOOL_ENABLED=%s\n' \
  "${pgpool_active:-unknown}" "${pgpool_enabled:-unknown}"
systemctl status pgpool --no-pager -l 2>&1 || true

section "TCP ${PORT} 监听"
listener="$(ss -Hlnpt "sport = :${PORT}" 2>&1 || true)"
if [[ -n "${listener}" ]]; then
  printf '%s\n' "${listener}"
else
  printf 'LISTENER=none\n'
fi

listener_present=no
listener_external=no
[[ -z "${listener}" ]] || listener_present=yes
if grep -Eq "(0\\.0\\.0\\.0|\\[::\\]|\\*):${PORT}([[:space:]]|$)" <<<"${listener}"; then
  listener_external=yes
fi
printf 'LISTENER_PRESENT=%s\nLISTENER_EXTERNAL=%s\n' \
  "${listener_present}" "${listener_external}"

section '本机 TCP 连接测试'
local_loopback_tcp=fail
if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then
  local_loopback_tcp=pass
fi
printf 'LOCAL_TCP_127_0_0_1=%s\n' "${local_loopback_tcp}"

server_ips="$(ip -o -4 addr show scope global | awk '{split($4,a,"/"); print a[1]}')"
local_server_ip_tcp=skipped
if [[ -z "${server_ips}" ]]; then
  printf 'SERVER_IP_TCP_TEST=skipped reason=no_global_ipv4\n'
else
  local_server_ip_tcp=pass
  while IFS= read -r server_ip; do
    [[ -n "${server_ip}" ]] || continue
    result=fail
    if timeout 3 bash -c "exec 3<>/dev/tcp/${server_ip}/${PORT}" 2>/dev/null; then
      result=pass
    fi
    [[ "${result}" == pass ]] || local_server_ip_tcp=fail
    printf 'SERVER_IP_TCP_TEST ip=%s result=%s\n' "${server_ip}" "${result}"
  done <<<"${server_ips}"
fi

section '防火墙服务状态'
firewalld_active="$(systemctl is-active firewalld 2>/dev/null || true)"
nftables_active="$(systemctl is-active nftables 2>/dev/null || true)"
printf 'FIREWALLD_ACTIVE=%s\nNFTABLES_ACTIVE=%s\n' \
  "${firewalld_active:-unknown}" "${nftables_active:-unknown}"

if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --state 2>&1 || true
  firewall-cmd --get-active-zones 2>&1 || true
  firewall-cmd --list-all-zones 2>&1 || true
else
  printf '[INFO] command_missing=firewall-cmd\n'
fi

section 'iptables 当前内核规则'
iptables_available=no
iptables_input=''
iptables_save=''
if command -v iptables >/dev/null 2>&1; then
  iptables_available=yes
  iptables --version 2>&1 || true
  iptables_input="$(iptables -w 2 -nvL INPUT --line-numbers 2>&1 || true)"
  printf '%s\n' "${iptables_input}"
  if command -v iptables-save >/dev/null 2>&1; then
    iptables_save="$(iptables-save -c 2>&1 || true)"
    printf '%s\n' "${iptables_save}"
  fi
else
  printf '[INFO] command_missing=iptables\n'
fi

section 'nft 当前内核规则'
nft_available=no
nft_rules=''
if command -v nft >/dev/null 2>&1; then
  nft_available=yes
  nft_rules="$(nft -a list ruleset 2>&1 || true)"
  if [[ -n "${nft_rules}" ]]; then
    printf '%s\n' "${nft_rules}"
  else
    printf 'NFT_RULESET=empty\n'
  fi
else
  printf '[INFO] command_missing=nft\n'
fi

section '与目标端口相关的规则'
port_rule_found=no
drop_rule_found=no
if grep -Eq "(^|[^0-9])${PORT}([^0-9]|$)" <<<"${iptables_save}"; then
  port_rule_found=yes
  grep -En "(^|[^0-9])${PORT}([^0-9]|$)" <<<"${iptables_save}" || true
fi
if grep -Eiq '(^|[[:space:]])(DROP|REJECT)([[:space:]]|$)' <<<"${iptables_input}${iptables_save}"; then
  drop_rule_found=yes
  grep -Ein '(^|[[:space:]])(DROP|REJECT)([[:space:]]|$)' <<<"${iptables_input}${iptables_save}" || true
fi
if grep -Eq "(^|[^0-9])${PORT}([^0-9]|$)" <<<"${nft_rules}"; then
  port_rule_found=yes
  grep -En "(^|[^0-9])${PORT}([^0-9]|$)" <<<"${nft_rules}" || true
fi
if grep -Eiq '(^|[[:space:]])(drop|reject)([[:space:]]|$)' <<<"${nft_rules}"; then
  drop_rule_found=yes
  grep -Ein '(^|[[:space:]])(drop|reject)([[:space:]]|$)' <<<"${nft_rules}" || true
fi
printf 'PORT_RULE_FOUND=%s\nDROP_OR_REJECT_RULE_FOUND=%s\n' \
  "${port_rule_found}" "${drop_rule_found}"

section '自动结论'
if [[ "${pgpool_active}" != active ]]; then
  conclusion='PGPOOL_SERVICE_NOT_ACTIVE'
  recommendation='Pgpool 服务未运行，先检查上面的 systemctl status 和 journalctl -u pgpool。'
elif [[ "${listener_present}" != yes ]]; then
  conclusion='PORT_NOT_LISTENING'
  recommendation="Pgpool 已运行但没有监听 ${PORT}，检查 /etc/pgpool-II/pgpool.conf 的 port/listen_addresses。"
elif [[ "${listener_external}" != yes ]]; then
  conclusion='PORT_ONLY_LISTENS_LOCALLY'
  recommendation="${PORT} 没有监听 0.0.0.0/[::]，外部客户端无法连接。"
elif [[ "${local_server_ip_tcp}" != pass ]]; then
  conclusion='LOCAL_TCP_FAILED'
  recommendation="本机通过服务器业务 IPv4 连接 ${PORT} 失败，检查本机防火墙规则、Pgpool 监听和系统日志。"
elif [[ "${port_rule_found}" == yes || "${drop_rule_found}" == yes ]]; then
  conclusion='LOCAL_SERVICE_OK_FIREWALL_RULES_REQUIRE_REVIEW'
  recommendation="Pgpool 本机监听和 TCP 测试正常，但内核存在 ${PORT} 或 DROP/REJECT 规则；把完整日志发回确认规则顺序和命中范围。"
else
  conclusion='LOCAL_SERVICE_AND_FIREWALL_LOOK_NORMAL'
  recommendation="Pgpool 本机监听和 TCP 测试正常，未发现明显本机拦截规则；若外部仍无响应，应检查上游 ACL、返回路由或安全设备。"
fi

printf 'DIAG_RESULT=%s\n' "${conclusion}"
printf 'RECOMMENDATION=%s\n' "${recommendation}"
printf '诊断完成，请把日志发回：%s\n' "${LOG_FILE}"

exit 0
