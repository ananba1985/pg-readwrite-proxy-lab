[CmdletBinding()]
param(
    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 60,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

function Send-QmpCommand {
    param(
        [int]$Port,
        [string]$Command
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.NewLine = "`r`n"
        $writer.AutoFlush = $true
        [void]$reader.ReadLine()
        $writer.WriteLine('{"execute":"qmp_capabilities"}')
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $response = $reader.ReadLine()
            if ($response -match '"return"') {
                break
            }
        }
        $writer.WriteLine((@{ execute = $Command } | ConvertTo-Json -Compress))
    }
    finally {
        $client.Dispose()
    }
}

foreach ($vm in $script:VmDefinitions) {
    $processes = @(Get-LabVmProcess -Name $vm.Name)
    if ($processes.Count -eq 0) {
        Write-Host "[$($vm.Name)] 未运行。"
        continue
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
        Write-Host "[$($vm.Name)] 已请求来宾系统正常关机。"
    }
    elseif (Test-LocalTcpPort -Port $vm.QmpPort) {
        Send-QmpCommand -Port $vm.QmpPort -Command 'system_powerdown'
        Write-Host "[$($vm.Name)] SSH 不可用，已通过 QMP 请求关机。"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $remaining = @(Get-LabVmProcess -Name $vm.Name)
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        if (-not $Force) {
            Write-Warning "[$($vm.Name)] 在 $TimeoutSeconds 秒内未退出；未强制终止。需要时显式运行 .\vm\stop-all.ps1 -Force。"
            continue
        }
        foreach ($process in $remaining) {
            Stop-Process -Id $process.ProcessId -Force
        }
        Write-Warning "[$($vm.Name)] 已按显式 -Force 强制终止。"
    }
    else {
        Write-Host "[$($vm.Name)] 已关闭。"
    }
}

$remainingVms = foreach ($vm in $script:VmDefinitions) {
    @(Get-LabVmProcess -Name $vm.Name)
}
if (@($remainingVms).Count -gt 0) {
    Write-Warning '仍有虚拟机在运行，保留集群二层交换机。'
    return
}

$switchProcesses = @(Get-LabVmProcess -Name $script:ClusterSwitchName)
if ($switchProcesses.Count -eq 0) {
    Write-Host "[$($script:ClusterSwitchName)] 未运行。"
    return
}
if (Test-LocalTcpPort -Port $script:ClusterSwitchQmpPort) {
    Send-QmpCommand -Port $script:ClusterSwitchQmpPort -Command 'quit'
}
Start-Sleep -Seconds 2
$remainingSwitch = @(Get-LabVmProcess -Name $script:ClusterSwitchName)
if ($remainingSwitch.Count -gt 0 -and $Force) {
    foreach ($process in $remainingSwitch) {
        Stop-Process -Id $process.ProcessId -Force
    }
    Write-Warning "[$($script:ClusterSwitchName)] 已按显式 -Force 强制终止。"
}
elseif ($remainingSwitch.Count -gt 0) {
    Write-Warning "[$($script:ClusterSwitchName)] 未退出；未强制终止。"
}
else {
    Write-Host "[$($script:ClusterSwitchName)] 已关闭。"
}
