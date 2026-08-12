[CmdletBinding()]
param(
    [switch]$ConfirmReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

if (-not $ConfirmReset) {
    throw '这是破坏性重置。确认删除两台数据库的现有 PGDATA 后，请传入 -ConfirmReset。'
}

$resetScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'reset-independent-pg12.sh'))
$archive = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'runtime\postgresql-12.22-aarch64-prefix-20260812.tar.gz'))
$expectedArchiveHash = 'e57c280930b9b7f6fc4973bec7b4ce6239eed4dcb7849781fb6d16f7a980ac4a'
foreach ($requiredFile in @($resetScript, $archive, $script:LabSshPrivateKey)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "缺少重置所需文件：$requiredFile"
    }
}
$actualArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($actualArchiveHash -ne $expectedArchiveHash) {
    throw "PostgreSQL 安装归档哈希不匹配：$actualArchiveHash"
}

$databaseVms = @($script:VmDefinitions | Where-Object Role -in @('Primary', 'Standby'))
foreach ($vm in $databaseVms) {
    if (-not (Test-LabVmSsh -Vm $vm)) {
        throw "[$($vm.Name)] SSH 尚未就绪。"
    }
}

function Invoke-LabSsh {
    param(
        [Parameter(Mandatory)][pscustomobject]$Vm,
        [Parameter(Mandatory)][string]$Command
    )
    & ssh `
        -i $script:LabSshPrivateKey `
        -p $Vm.SshPort `
        -o BatchMode=yes `
        -o ConnectTimeout=10 `
        -o ServerAliveInterval=15 `
        -o ServerAliveCountMax=8 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        'labadmin@127.0.0.1' `
        $Command
    if ($LASTEXITCODE -ne 0) {
        throw "[$($vm.Name)] 远端命令失败：$Command"
    }
}

foreach ($vm in $databaseVms) {
    & scp -q `
        -i $script:LabSshPrivateKey `
        -P $vm.SshPort `
        -o BatchMode=yes `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        $resetScript `
        'labadmin@127.0.0.1:/var/tmp/reset-independent-pg12.sh'
    if ($LASTEXITCODE -ne 0) {
        throw "[$($vm.Name)] 上传重置脚本失败。"
    }
    & scp -q `
        -i $script:LabSshPrivateKey `
        -P $vm.SshPort `
        -o BatchMode=yes `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        $archive `
        'labadmin@127.0.0.1:/var/tmp/postgresql-12.22-aarch64-prefix-20260812.upload'
    if ($LASTEXITCODE -ne 0) {
        throw "[$($vm.Name)] 上传 PostgreSQL 归档失败。"
    }
    Invoke-LabSsh -Vm $vm -Command `
        "sudo install -o root -g root -m 0700 /var/tmp/reset-independent-pg12.sh /usr/local/sbin/reset-independent-pg12 && sudo bash -n /usr/local/sbin/reset-independent-pg12 && sudo install -o root -g root -m 0644 /var/tmp/postgresql-12.22-aarch64-prefix-20260812.upload /var/tmp/postgresql-12.22-aarch64-prefix-20260812.tar.gz && rm -f /var/tmp/postgresql-12.22-aarch64-prefix-20260812.upload && sha256sum /var/tmp/postgresql-12.22-aarch64-prefix-20260812.tar.gz"
}

$standbyVm = $databaseVms | Where-Object Role -eq 'Standby'
$primaryVm = $databaseVms | Where-Object Role -eq 'Primary'
Invoke-LabSsh -Vm $standbyVm -Command 'sudo systemctl stop postgresql-12 2>/dev/null || true'
Invoke-LabSsh -Vm $primaryVm -Command 'sudo /usr/local/sbin/reset-independent-pg12 --confirm-reset'
Invoke-LabSsh -Vm $standbyVm -Command 'sudo /usr/local/sbin/reset-independent-pg12 --confirm-reset'

Write-Host '两台数据库服务器已重置为互相独立的 PostgreSQL 12.22 初始安装状态。'
