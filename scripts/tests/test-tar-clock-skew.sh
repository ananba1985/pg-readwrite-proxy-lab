#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

test_root="$(mktemp -d /tmp/pg-rw-tar-clock.XXXXXX)"
cleanup() {
  case "${test_root}" in
    /tmp/pg-rw-tar-clock.*) rm -rf -- "${test_root}" ;;
  esac
}
trap cleanup EXIT

mkdir -p "${test_root}/source" "${test_root}/target"
printf 'cluster\n' >"${test_root}/source/cluster.env"
printf 'secret\n' >"${test_root}/source/secrets.env"
chmod 600 "${test_root}/source/cluster.env" "${test_root}/source/secrets.env"

# 模拟发送端比接收端快 2 秒。-m/--touch 必须让解压不依赖归档内 mtime。
future_epoch=$(($(date +%s) + 2))
touch -d "@${future_epoch}" "${test_root}/source/cluster.env" "${test_root}/source/secrets.env"
tar -C "${test_root}/source" -czf "${test_root}/session-config.tar.gz" cluster.env secrets.env
tar -xmzf "${test_root}/session-config.tar.gz" -C "${test_root}/target" 2>"${test_root}/tar.stderr"

cmp "${test_root}/source/cluster.env" "${test_root}/target/cluster.env"
cmp "${test_root}/source/secrets.env" "${test_root}/target/secrets.env"
[[ "$(stat -c %a "${test_root}/target/cluster.env")" == '600' ]]
[[ "$(stat -c %a "${test_root}/target/secrets.env")" == '600' ]]
! grep -Eqi 'future|未来|time stamp' "${test_root}/tar.stderr"

printf 'TAR_CLOCK_SKEW_TOLERANCE_OK\n'
