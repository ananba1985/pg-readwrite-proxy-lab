[CmdletBinding()]
param(
    [ValidateSet('CANCEL', 'APPLY')]
    [string]$Confirmation = 'CANCEL',
    [switch]$ForceDisconnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$key = Join-Path $projectRoot 'vm\keys\lab_rsa'
$rootPasswordFile = Join-Path $projectRoot 'vm\keys\root-password.txt'
$businessPasswordFile = Join-Path $projectRoot 'vm\keys\rw-lab-test-password.txt'
$required = @($key, $rootPasswordFile, $businessPasswordFile)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "缺少测试文件：$path"
    }
}

$runId = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + $PID
$remotePrefix = "/var/tmp/pg-rw-e2e-$runId"
$answerFile = Join-Path $env:TEMP "pg-rw-e2e-answers-$runId.txt"
$answers = [Collections.Generic.List[string]]::new()
if ($ForceDisconnect) {
    $answers.Add('2')
}
$answers.Add($Confirmation)
[IO.File]::WriteAllText($answerFile, (($answers -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

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
        @{ Local = $answerFile; Remote = "$remotePrefix-answers.upload" }
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
confirmation=__CONFIRMATION__
log="${prefix}-installer.log"
install -o root -g root -m 600 "${prefix}-root.upload" "${prefix}-root.secret"
install -o root -g root -m 600 "${prefix}-business.upload" "${prefix}-business.secret"
install -o root -g root -m 600 "${prefix}-answers.upload" "${prefix}-answers"
rm -f -- "${prefix}-root.upload" "${prefix}-business.upload" "${prefix}-answers.upload"
root_password="$(tr -d '\r\n' <"${prefix}-root.secret")"
business_password="$(tr -d '\r\n' <"${prefix}-business.secret")"
set +e
bash "${project}/install.sh" \
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
  <"${prefix}-answers" >"${log}" 2>&1
status=$?
set -e
unset root_password business_password
if command -v shred >/dev/null 2>&1; then
  shred -u -- "${prefix}-root.secret" "${prefix}-business.secret" "${prefix}-answers"
else
  rm -f -- "${prefix}-root.secret" "${prefix}-business.secret" "${prefix}-answers"
fi
printf 'E2E_INSTALL_STATUS=%s\n' "${status}"
printf 'E2E_INSTALL_LOG=%s\n' "${log}"
cat "${log}"
if [[ "${confirmation}" == CANCEL ]]; then
  [[ "${status}" != 0 ]]
  grep -Fq 'READINESS_RESULT=READY role=primary' "${log}"
  grep -Fq 'READINESS_RESULT=READY role=standby' "${log}"
  grep -Fq 'READINESS_RESULT=READY role=pgpool' "${log}"
  grep -Fq '三节点只读就绪检查全部通过' "${log}"
  grep -Fq '用户取消；所有服务器均未执行部署变更' "${log}"
  printf 'E2E_CANCEL_GATE_PASS\n'
else
  [[ "${status}" == 0 ]]
  grep -Fq '安装与验收完成' "${log}"
  printf 'E2E_APPLY_PASS\n'
fi
'@
    $remoteScript = $remoteScript.Replace('__REMOTE_PREFIX__', $remotePrefix)
    $remoteScript = $remoteScript.Replace('__CONFIRMATION__', $Confirmation)
    $remoteScript = $remoteScript.Replace("`r", '')
    $remoteScript | & ssh @sshOptions 'sudo bash -c ''cat >/var/tmp/run-pg-rw-e2e-test.sh && sed -i "s/\r$//" /var/tmp/run-pg-rw-e2e-test.sh && bash -n /var/tmp/run-pg-rw-e2e-test.sh && bash /var/tmp/run-pg-rw-e2e-test.sh'''
    if ($LASTEXITCODE -ne 0) {
        throw "麒麟端到端安装器测试失败，模式=$Confirmation，退出码=$LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $answerFile -Force -ErrorAction SilentlyContinue
    Remove-Variable answers -ErrorAction SilentlyContinue
}
