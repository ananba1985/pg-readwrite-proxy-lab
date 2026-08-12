[CmdletBinding()]
param(
    [switch]$ConfirmReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

if (-not $ConfirmReset) {
    throw '该操作会删除并重建 Primary 上的 rw_proxy_lab；确认后请传入 -ConfirmReset。'
}

$loaderScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\50-reset-primary-test-data.sh'))
$datasetSql = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\sql\primary-test-data.sql'))
$verificationSql = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\sql\verify-primary-test-data.sql'))
foreach ($requiredFile in @($loaderScript, $datasetSql, $verificationSql, $script:LabSshPrivateKey)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "缺少测试数据导入文件：$requiredFile"
    }
}

$primaryVm = $script:VmDefinitions | Where-Object Role -eq 'Primary'
if (-not (Test-LabVmSsh -Vm $primaryVm)) {
    throw '[pg-primary] SSH 尚未就绪。'
}

foreach ($upload in @(
    [pscustomobject]@{
        Local = $loaderScript
        RemoteUpload = '/var/tmp/reset-primary-test-data.upload'
        RemoteTarget = '/usr/local/sbin/reset-primary-test-data'
        Mode = '0700'
    }
    [pscustomobject]@{
        Local = $datasetSql
        RemoteUpload = '/var/tmp/primary-test-data.sql.upload'
        RemoteTarget = '/usr/local/share/pg-readwrite-proxy-lab/primary-test-data.sql'
        Mode = '0644'
    }
    [pscustomobject]@{
        Local = $verificationSql
        RemoteUpload = '/var/tmp/verify-primary-test-data.sql.upload'
        RemoteTarget = '/usr/local/share/pg-readwrite-proxy-lab/verify-primary-test-data.sql'
        Mode = '0644'
    }
)) {
    & scp -q `
        -i $script:LabSshPrivateKey `
        -P $primaryVm.SshPort `
        -o BatchMode=yes `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        $upload.Local `
        "labadmin@127.0.0.1:$($upload.RemoteUpload)"
    if ($LASTEXITCODE -ne 0) {
        throw "上传失败：$($upload.Local)"
    }
    & ssh `
        -i $script:LabSshPrivateKey `
        -p $primaryVm.SshPort `
        -o BatchMode=yes `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        'labadmin@127.0.0.1' `
        "sudo install -d -o root -g root -m 0755 /usr/local/share/pg-readwrite-proxy-lab && sudo install -o root -g root -m $($upload.Mode) $($upload.RemoteUpload) $($upload.RemoteTarget) && rm -f $($upload.RemoteUpload)"
    if ($LASTEXITCODE -ne 0) {
        throw "安装失败：$($upload.RemoteTarget)"
    }
}

& ssh `
    -i $script:LabSshPrivateKey `
    -p $primaryVm.SshPort `
    -o BatchMode=yes `
    -o ConnectTimeout=10 `
    -o ServerAliveInterval=15 `
    -o ServerAliveCountMax=16 `
    -o StrictHostKeyChecking=no `
    -o UserKnownHostsFile=NUL `
    'labadmin@127.0.0.1' `
    'sudo /usr/local/sbin/reset-primary-test-data --confirm-reset-test-data'
if ($LASTEXITCODE -ne 0) {
    throw 'Primary 测试数据生成失败。'
}

Write-Host 'Primary 测试数据库 rw_proxy_lab 已完成确定性数据生成。'
