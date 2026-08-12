[CmdletBinding()]
param(
    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 90,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

function Send-QgaPowerdown {
    param([int]$Port)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $Port)
        $writer = [IO.StreamWriter]::new($client.GetStream(), [Text.UTF8Encoding]::new($false))
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true
        $writer.WriteLine('{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}')
    }
    finally {
        $client.Dispose()
    }
}

$vm = @($script:ValidationVmDefinitions | Where-Object Name -eq 'kylin-v10-compat')[0]
$processes = @(Get-LabVmProcess -Name $vm.Name)
if ($processes.Count -eq 0) {
    Write-Host "[$($vm.Name)] 未运行。"
    return
}

if (Test-LabVmSsh -Vm $vm) {
    & ssh -q `
        -i $script:LabSshPrivateKey `
        -p $vm.SshPort `
        -o BatchMode=yes `
        -o ConnectTimeout=3 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        'labadmin@127.0.0.1' `
        'sudo -n /sbin/shutdown -h now' 2>$null
    Write-Host "[$($vm.Name)] 已通过 SSH 请求正常关机。"
}
elseif (Test-LocalTcpPort -Port $vm.QgaPort) {
    Send-QgaPowerdown -Port $vm.QgaPort
    Write-Host "[$($vm.Name)] SSH 不可用，已通过 Guest Agent 请求正常关机。"
}
elseif (-not $Force) {
    throw "[$($vm.Name)] SSH 与 Guest Agent 均不可用；未强制终止。需要时显式使用 -Force。"
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 1
    $remaining = @(Get-LabVmProcess -Name $vm.Name)
} while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

if ($remaining.Count -gt 0) {
    if (-not $Force) {
        throw "[$($vm.Name)] 在 $TimeoutSeconds 秒内未退出；未强制终止。"
    }
    foreach ($process in $remaining) {
        Stop-Process -Id $process.ProcessId -Force
    }
    Write-Warning "[$($vm.Name)] 已按显式 -Force 强制终止。"
}
else {
    Write-Host "[$($vm.Name)] 已关闭；集群交换机和三台正式角色保持运行。"
}
