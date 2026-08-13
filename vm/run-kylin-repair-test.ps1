[CmdletBinding()]
param(
    [switch]$ApplyRepair
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$key = Join-Path $projectRoot 'vm\keys\lab_rsa'
$rootPasswordFile = Join-Path $projectRoot 'vm\keys\root-password.txt'
$businessPasswordFile = Join-Path $projectRoot 'vm\keys\rw-lab-test-password.txt'
foreach ($path in @($key, $rootPasswordFile, $businessPasswordFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "缺少测试文件：$path"
    }
}

$runId = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + $PID
$remotePrefix = "/var/tmp/pg-rw-repair-test-$runId"
$answerFile = Join-Path $env:TEMP "pg-rw-repair-answer-$runId.txt"
$answer = if ($ApplyRepair) { "REPAIR`n" } else { "" }
[IO.File]::WriteAllText($answerFile, $answer, [Text.UTF8Encoding]::new($false))

$sshOptions = @(
    '-i', $key,
    '-p', '22021',
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=20',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL',
    'labadmin@127.0.0.1'
)
$scpOptions = @(
    '-i', $key,
    '-P', '22021',
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL'
)

try {
    foreach ($upload in @(
        @{ Local = $rootPasswordFile; Remote = "$remotePrefix-root.upload" },
        @{ Local = $businessPasswordFile; Remote = "$remotePrefix-business.upload" },
        @{ Local = $answerFile; Remote = "$remotePrefix-answer.upload" }
    )) {
        & scp @scpOptions $upload.Local "labadmin@127.0.0.1:$($upload.Remote)"
        if ($LASTEXITCODE -ne 0) {
            throw "上传测试输入失败：$($upload.Local)"
        }
    }

    $remoteScript = @'
set -Eeuo pipefail
umask 077
project=/var/tmp/pg-rw-e2e-current-20260813/pg-readwrite-proxy-offline-20260812-r4-kylin-v10-aarch64
prefix=__REMOTE_PREFIX__
apply_repair=__APPLY_REPAIR__
install -o root -g root -m 600 "${prefix}-root.upload" "${prefix}-root.secret"
install -o root -g root -m 600 "${prefix}-business.upload" "${prefix}-business.secret"
install -o root -g root -m 600 "${prefix}-answer.upload" "${prefix}-answer"
rm -f -- "${prefix}-root.upload" "${prefix}-business.upload" "${prefix}-answer.upload"
root_password="$(tr -d '\r\n' <"${prefix}-root.secret")"
business_password="$(tr -d '\r\n' <"${prefix}-business.secret")"
set +e
bash "${project}/repair.sh" \
  --pgpool-host 192.168.80.140 \
  --primary-host 192.168.80.110 \
  --standby-host 192.168.80.120 \
  --postgresql-port 5432 \
  --pgpool-port 5432 \
  --ssh-port 22 \
  --allowed-client-cidrs 192.168.80.0/24 \
  --business-user rw_lab_test \
  --business-database rw_proxy_lab \
  --root-ssh-password "${root_password}" \
  --business-password "${business_password}" \
  <"${prefix}-answer"
status=$?
set -e
unset root_password business_password
if command -v shred >/dev/null 2>&1; then
  shred -u -- "${prefix}-root.secret" "${prefix}-business.secret" "${prefix}-answer"
else
  rm -f -- "${prefix}-root.secret" "${prefix}-business.secret" "${prefix}-answer"
fi
printf 'REPAIR_TEST_STATUS=%s apply=%s\n' "${status}" "${apply_repair}"
exit "${status}"
'@
    $remoteScript = $remoteScript.Replace('__REMOTE_PREFIX__', $remotePrefix)
    $remoteScript = $remoteScript.Replace('__APPLY_REPAIR__', $(if ($ApplyRepair) { 'yes' } else { 'no' }))
    $remoteScript = $remoteScript.Replace("`r", '')
    $remoteScript | & ssh @sshOptions 'sudo bash -c ''cat >/var/tmp/run-pg-rw-repair-test.sh && sed -i "s/\r$//" /var/tmp/run-pg-rw-repair-test.sh && bash -n /var/tmp/run-pg-rw-repair-test.sh && bash /var/tmp/run-pg-rw-repair-test.sh'''
    if ($LASTEXITCODE -ne 0) {
        throw "麒麟 repair.sh 测试失败，ApplyRepair=$ApplyRepair，退出码=$LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $answerFile -Force -ErrorAction SilentlyContinue
}
