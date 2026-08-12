[CmdletBinding()]
param(
    [switch]$PreflightOnly,
    [switch]$ConfirmReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

if ($PreflightOnly -and $ConfirmReset) {
    throw '-PreflightOnly 与 -ConfirmReset 不能同时使用。'
}

# Running without arguments is deliberately read-only. Destructive reset
# always requires the explicit -ConfirmReset switch.
$remoteMode = if ($ConfirmReset) { '--confirm-reset' } else { '--preflight' }
$operationLabel = if ($ConfirmReset) { '重置' } else { '预检' }
$resetScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'reset-pgpool-environment.sh'))
foreach ($requiredFile in @($resetScript, $script:LabSshPrivateKey)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "缺少 Pgpool 重置所需文件：$requiredFile"
    }
}

$pgpoolVm = $script:VmDefinitions | Where-Object Role -eq 'Pgpool-II'
if (-not $pgpoolVm) {
    throw 'vm-common.ps1 中没有 Pgpool-II 虚拟机定义。'
}
if (-not (Test-LabVmSsh -Vm $pgpoolVm)) {
    throw '[pg-pgpool] SSH 尚未就绪。'
}

$remoteUpload = '/var/tmp/reset-pgpool-environment.sh.upload'
try {
    & scp -q `
        -i $script:LabSshPrivateKey `
        -P $pgpoolVm.SshPort `
        -o BatchMode=yes `
        -o LogLevel=ERROR `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        $resetScript `
        "labadmin@127.0.0.1:$remoteUpload"
    if ($LASTEXITCODE -ne 0) {
        throw '[pg-pgpool] 上传重置脚本失败。'
    }

    & ssh `
        -i $script:LabSshPrivateKey `
        -p $pgpoolVm.SshPort `
        -o BatchMode=yes `
        -o ConnectTimeout=10 `
        -o LogLevel=ERROR `
        -o ServerAliveInterval=15 `
        -o ServerAliveCountMax=8 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        'labadmin@127.0.0.1' `
        "sudo bash -n $remoteUpload && sudo bash $remoteUpload $remoteMode"
    if ($LASTEXITCODE -ne 0) {
        throw "[pg-pgpool] Pgpool 环境${operationLabel}失败。"
    }
}
finally {
    & ssh -q `
        -i $script:LabSshPrivateKey `
        -p $pgpoolVm.SshPort `
        -o BatchMode=yes `
        -o ConnectTimeout=5 `
        -o LogLevel=ERROR `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        'labadmin@127.0.0.1' `
        "rm -f -- $remoteUpload" 2>$null
}

if ($ConfirmReset) {
    Write-Host 'Pgpool 节点已恢复到项目安装器运行前状态；虚拟机、网络、SSH 和离线构建介质未修改。'
}
else {
    Write-Host 'Pgpool 节点只读预检完成。执行破坏性重置时请显式传入 -ConfirmReset。'
}
