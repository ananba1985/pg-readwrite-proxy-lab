#!/usr/bin/env bash

# repair.sh 的简单 HBA IPv4 白名单同步：Primary 负责提供 CIDR，Pgpool 继续
# 使用本项目既有的 md5 + pool_passwd 认证。这里只处理常见 host 记录。

build_pgpool_client_policy() {
  local snapshot_file="$1" rules_file="$2" trace_file="$3"
  local record line_number cidr extra hba_path source_hash ignored_count
  local rule_count=0 duplicate_count=0
  declare -A seen_cidrs=()

  [[ -f "${snapshot_file}" && ! -L "${snapshot_file}" ]] || return 1
  : >"${rules_file}"
  : >"${trace_file}"
  hba_path="$(sed -n 's/^HBA_PATH=//p' "${snapshot_file}")"
  source_hash="$(sed -n 's/^HBA_SOURCE_SHA256=//p' "${snapshot_file}")"
  ignored_count="$(sed -n 's/^HBA_IGNORED_COUNT=//p' "${snapshot_file}")"
  if [[ "${hba_path}" != /* || ! "${source_hash}" =~ ^[0-9a-f]{64}$ || ! "${ignored_count}" =~ ^[0-9]+$ ]]; then
    printf 'status=ERROR reason=invalid_snapshot_metadata\n' >>"${trace_file}"
    return 1
  fi

  while IFS= read -r record || [[ -n "${record}" ]]; do
    [[ "${record}" == HBA_RULE=* ]] || continue
    record="${record#HBA_RULE=}"
    IFS='|' read -r line_number cidr extra <<<"${record}"
    if [[ ! "${line_number}" =~ ^[0-9]+$ || -n "${extra:-}" ]]; then
      printf 'status=ERROR reason=invalid_rule record=%q\n' "${record}" >>"${trace_file}"
      return 1
    fi
    validate_cidr "${cidr}" 'Primary HBA IPv4 CIDR'
    case "${cidr}" in
      127.*|0.0.0.0/0)
        printf 'status=IGNORED reason=loopback_or_world_open primary_line=%s cidr=%s\n' \
          "${line_number}" "${cidr}" >>"${trace_file}"
        continue
        ;;
    esac
    if [[ -n "${seen_cidrs[${cidr}]:-}" ]]; then
      duplicate_count=$((duplicate_count + 1))
      printf 'status=IGNORED reason=duplicate primary_line=%s cidr=%s\n' \
        "${line_number}" "${cidr}" >>"${trace_file}"
      continue
    fi
    seen_cidrs["${cidr}"]=1
    printf 'host    all       all   %-22s md5\n' "${cidr}" >>"${rules_file}"
    printf 'status=SYNCED primary_line=%s cidr=%s\n' "${line_number}" "${cidr}" >>"${trace_file}"
    rule_count=$((rule_count + 1))
  done <"${snapshot_file}"

  printf 'status=SUMMARY synced=%s duplicates=%s unsupported_ignored=%s\n' \
    "${rule_count}" "${duplicate_count}" "${ignored_count}" >>"${trace_file}"
  ((rule_count > 0)) || return 1

  PRIMARY_POLICY_HBA_PATH="${hba_path}"
  PRIMARY_POLICY_SOURCE_SHA256="${source_hash}"
  PRIMARY_POLICY_RULE_COUNT="${rule_count}"
  PRIMARY_POLICY_IGNORED_COUNT="${ignored_count}"
  PRIMARY_POLICY_DUPLICATE_COUNT="${duplicate_count}"
  PRIMARY_POLICY_SHA256="$(sha256sum "${rules_file}" | awk '{print $1}')"
  export PRIMARY_POLICY_HBA_PATH PRIMARY_POLICY_SOURCE_SHA256 PRIMARY_POLICY_RULE_COUNT
  export PRIMARY_POLICY_IGNORED_COUNT PRIMARY_POLICY_DUPLICATE_COUNT PRIMARY_POLICY_SHA256
}

validate_pgpool_client_policy_file() {
  local policy_file="$1" line type database_name user_name cidr method extra count=0
  [[ -f "${policy_file}" && ! -L "${policy_file}" ]] || die "Pgpool 客户端策略文件缺失: ${policy_file}"
  [[ "$(stat -c '%u:%a' "${policy_file}")" =~ ^0:(400|600)$ ]] || \
    die "Pgpool 客户端策略文件必须属于 root 且权限为 400/600: ${policy_file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(trim "${line}")"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    IFS=$' \t' read -r type database_name user_name cidr method extra <<<"${line}"
    [[ -z "${extra:-}" && "${type}|${database_name}|${user_name}|${method}" == 'host|all|all|md5' ]] || \
      die "Pgpool 客户端策略记录格式无效: ${line}"
    validate_cidr "${cidr}" 'Pgpool 客户端策略 CIDR'
    [[ "${cidr}" != '0.0.0.0/0' ]] || die 'Pgpool 客户端策略禁止向全网开放。'
    count=$((count + 1))
  done <"${policy_file}"
  ((count > 0)) || die 'Pgpool 客户端策略没有可同步的 IPv4 CIDR。'
}
