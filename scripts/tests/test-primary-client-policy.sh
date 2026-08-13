#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_BASE="${TMPDIR:-/var/tmp}"
[[ -d "${TEMP_BASE}" && -w "${TEMP_BASE}" ]] || TEMP_BASE='/tmp'
TEMP_ROOT="$(mktemp -d "${TEMP_BASE%/}/pg-rw-policy-test.XXXXXX")"
cleanup() { [[ "${TEMP_ROOT##*/}" == pg-rw-policy-test.* ]] && rm -rf -- "${TEMP_ROOT}"; }
trap cleanup EXIT

die() { printf 'TEST_ERROR=%s\n' "$*" >&2; exit 1; }
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}
validate_cidr() {
  local value="$1" address="${1%/*}" prefix="${1##*/}" old_ifs="${IFS}" octet
  local -a octets
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "bad cidr: ${value}"
  ((10#${prefix} <= 32)) || die "bad cidr: ${value}"
  IFS='.' read -r -a octets <<<"${address}"; IFS="${old_ifs}"
  for octet in "${octets[@]}"; do ((10#${octet} <= 255)) || die "bad cidr: ${value}"; done
}
# shellcheck source=scripts/lib/primary-client-policy.sh
source "${ROOT}/scripts/lib/primary-client-policy.sh"

snapshot="${TEMP_ROOT}/snapshot"
rules="${TEMP_ROOT}/rules"
trace="${TEMP_ROOT}/trace"
cat >"${snapshot}" <<'SNAPSHOT'
HBA_PATH=/pgsql/12/data/pg_hba.conf
HBA_SOURCE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HBA_IGNORED_COUNT=4
HBA_RULE=10|127.0.0.1/32
HBA_RULE=11|10.10.8.17/32
HBA_RULE=12|172.16.9.0/24
HBA_RULE=13|10.10.8.17/32
HBA_RULE=14|0.0.0.0/0
SNAPSHOT
chmod 600 "${snapshot}"
build_pgpool_client_policy "${snapshot}" "${rules}" "${trace}"
chmod 600 "${rules}"
if [[ "$(id -u)" == 0 ]]; then
  validate_pgpool_client_policy_file "${rules}"
else
  # Windows Git Bash 无 root 所有权语义；这里只跳过所有者门禁，格式仍由后续断言覆盖。
  while IFS= read -r policy_line; do
    [[ "${policy_line}" =~ ^host[[:space:]]+all[[:space:]]+all[[:space:]]+[0-9./]+[[:space:]]+md5$ ]] || \
      die "bad policy line: ${policy_line}"
  done <"${rules}"
fi
[[ "${PRIMARY_POLICY_RULE_COUNT}|${PRIMARY_POLICY_IGNORED_COUNT}|${PRIMARY_POLICY_DUPLICATE_COUNT}" == '2|4|1' ]]
grep -Eq '^host[[:space:]]+all[[:space:]]+all[[:space:]]+10\.10\.8\.17/32[[:space:]]+md5$' "${rules}"
grep -Eq '^host[[:space:]]+all[[:space:]]+all[[:space:]]+172\.16\.9\.0/24[[:space:]]+md5$' "${rules}"
! grep -Fq '127.0.0.1' "${rules}"
! grep -Fq '0.0.0.0/0' "${rules}"

# 证明现场很多 IP 不受固定条数限制。
{
  printf 'HBA_PATH=/pgsql/12/data/pg_hba.conf\n'
  printf 'HBA_SOURCE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
  printf 'HBA_IGNORED_COUNT=0\n'
  for ((index=1; index<=400; index++)); do
    printf 'HBA_RULE=%s|10.20.%s.%s/32\n' "${index}" "$(((index - 1) / 250))" "$((((index - 1) % 250) + 1))"
  done
} >"${snapshot}"
build_pgpool_client_policy "${snapshot}" "${rules}" "${trace}"
[[ "${PRIMARY_POLICY_RULE_COUNT}" == 400 && "$(wc -l <"${rules}")" == 400 ]]

cat >"${snapshot}" <<'SNAPSHOT'
HBA_PATH=/pgsql/12/data/pg_hba.conf
HBA_SOURCE_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
HBA_IGNORED_COUNT=2
SNAPSHOT
if build_pgpool_client_policy "${snapshot}" "${rules}" "${trace}"; then
  die 'empty normal IPv4 policy must fail.'
fi

printf 'PRIMARY_CLIENT_POLICY_TEST_OK rules_without_fixed_limit=400\n'
