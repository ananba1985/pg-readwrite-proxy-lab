[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$key = Join-Path $projectRoot 'vm\keys\lab_rsa'
if (-not (Test-Path -LiteralPath $key -PathType Leaf)) {
    throw "缺少测试 SSH 私钥：$key"
}

function Invoke-RootScript {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Script
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Script.Replace("`r", ''))
    $encoded = [Convert]::ToBase64String($bytes)
    $output = & ssh `
        -q `
        -i $key `
        -p $Port `
        -o BatchMode=yes `
        -o ConnectTimeout=10 `
        -o ServerAliveInterval=10 `
        -o ServerAliveCountMax=6 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        'labadmin@127.0.0.1' `
        "printf '%s' '$encoded' | base64 -d | sudo bash -s"
    if ($LASTEXITCODE -ne 0) {
        throw "远端审计失败：SSH 端口=$Port，退出码=$LASTEXITCODE"
    }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

$databaseAudit = @'
set -Eeuo pipefail
cd /tmp
/opt/pgsql12/bin/tools psql -d postgres -p 5432 <<'SQL'
select current_setting('cluster_name'),
       pg_is_in_recovery(),
       system_identifier,
       pg_postmaster_start_time()
from pg_control_system();
SQL
for file in \
  /pgsql/12/data/postgresql.conf \
  /pgsql/12/data/pg_hba.conf \
  /pgsql/12/data/postgresql.auto.conf \
  /pgsql/12/data/conf.d/99-pg-rw-proxy.conf; do
  if [[ -f "${file}" ]]; then
    sha256sum "${file}"
  else
    printf 'absent  %s\n' "${file}"
  fi
done
'@

$primaryBefore = Invoke-RootScript -Port 22011 -Script $databaseAudit
$standbyBefore = Invoke-RootScript -Port 22012 -Script $databaseAudit
Write-Host 'DB_FINGERPRINT_BEFORE_CAPTURED'

$repairCompleted = $false
try {
    $faultResult = Invoke-RootScript -Port 22021 -Script @'
set -Eeuo pipefail
systemctl stop pgpool
[[ "$(systemctl is-active pgpool 2>/dev/null || true)" != active ]]
! ss -lntH 'sport = :5432' | grep -q .
printf 'PGPOOL_FAULT_INJECTED service=inactive port=5432-free\n'
'@
    Write-Host $faultResult

    & (Join-Path $PSScriptRoot 'run-kylin-repair-test.ps1') -ApplyRepair
    if ($LASTEXITCODE -ne 0) {
        throw "repair.sh 故障修复测试退出码=$LASTEXITCODE"
    }
    $repairCompleted = $true
}
finally {
    $finalService = Invoke-RootScript -Port 22021 -Script @'
set -Eeuo pipefail
state="$(systemctl is-active pgpool 2>/dev/null || true)"
if [[ "${state}" != active ]]; then
  systemctl start pgpool
  state="$(systemctl is-active pgpool)"
fi
printf '%s\n' "${state}"
'@
    Write-Host "PGPOOL_FINAL_SERVICE=$finalService"
}

if (-not $repairCompleted) {
    throw 'Pgpool-only 修复未完成。'
}

$primaryAfter = Invoke-RootScript -Port 22011 -Script $databaseAudit
$standbyAfter = Invoke-RootScript -Port 22012 -Script $databaseAudit
if ($primaryBefore -cne $primaryAfter) {
    Write-Host 'PRIMARY_BEFORE'
    Write-Host $primaryBefore
    Write-Host 'PRIMARY_AFTER'
    Write-Host $primaryAfter
    throw 'repair.sh 执行后 Primary 启动时间或配置指纹发生变化。'
}
if ($standbyBefore -cne $standbyAfter) {
    Write-Host 'STANDBY_BEFORE'
    Write-Host $standbyBefore
    Write-Host 'STANDBY_AFTER'
    Write-Host $standbyAfter
    throw 'repair.sh 执行后 Standby 启动时间或配置指纹发生变化。'
}

Write-Host 'DB_FINGERPRINT_UNCHANGED primary=yes standby=yes postmaster_start_unchanged=yes'
Write-Host 'PGPOOL_ONLY_REPAIR_FAULT_TEST_PASS'
