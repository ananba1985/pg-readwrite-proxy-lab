[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

Assert-LabVmPrerequisites
New-Item -ItemType Directory -Path $script:RuntimeDirectory -Force | Out-Null

$switchProcesses = @(Get-LabVmProcess -Name $script:ClusterSwitchName)
if ($switchProcesses.Count -eq 0) {
    foreach ($port in @($script:ClusterSwitchQmpPort) + @($script:VmDefinitions.ClusterSwitchPort)) {
        $listeners = @(Get-LocalTcpListener -Port $port)
        if ($listeners.Count -gt 0) {
            throw "集群二层交换机所需本机 TCP 端口 $port 已被占用，拒绝启动。"
        }
    }

    $switchStdout = Join-Path $script:RuntimeDirectory "$($script:ClusterSwitchName)-qemu.stdout.log"
    $switchStderr = Join-Path $script:RuntimeDirectory "$($script:ClusterSwitchName)-qemu.stderr.log"
    $switchProcess = Start-Process -FilePath $script:QemuExecutable `
        -ArgumentList (Get-ClusterSwitchQemuArguments) `
        -WorkingDirectory $script:ProjectRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $switchStdout `
        -RedirectStandardError $switchStderr `
        -PassThru
    Start-Sleep -Seconds 2
    if ($switchProcess.HasExited) {
        throw "集群二层交换机启动后立即退出（退出码 $($switchProcess.ExitCode)）。请检查 $switchStderr。"
    }
    Set-Content -LiteralPath (Join-Path $script:RuntimeDirectory "$($script:ClusterSwitchName).pid") `
        -Value $switchProcess.Id `
        -Encoding ascii
    Write-Host "[$($script:ClusterSwitchName)] 已启动，PID=$($switchProcess.Id)。"
}
else {
    Write-Host "[$($script:ClusterSwitchName)] 已在运行，PID=$($switchProcesses.ProcessId -join ',')。"
}

$started = @()
foreach ($vm in $script:VmDefinitions) {
    $existing = @(Get-LabVmProcess -Name $vm.Name)
    if ($existing.Count -gt 0) {
        Write-Host "[$($vm.Name)] 已在运行，PID=$($existing.ProcessId -join ',')。"
        continue
    }

    foreach ($port in @($vm.SshPort, $vm.QmpPort)) {
        if (@(Get-LocalTcpListener -Port $port).Count -gt 0) {
            throw "[$($vm.Name)] 所需本机 TCP 端口 $port 已被占用，拒绝启动。"
        }
    }

    $arguments = Get-LabVmQemuArguments -Vm $vm
    $stdoutLog = Join-Path $script:RuntimeDirectory "$($vm.Name)-qemu.stdout.log"
    $stderrLog = Join-Path $script:RuntimeDirectory "$($vm.Name)-qemu.stderr.log"
    $process = Start-Process -FilePath $script:QemuExecutable `
        -ArgumentList $arguments `
        -WorkingDirectory $script:ProjectRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    Start-Sleep -Seconds 2
    if ($process.HasExited) {
        $serialLog = Join-Path $script:RuntimeDirectory "$($vm.Name)-serial.log"
        throw "[$($vm.Name)] QEMU 启动后立即退出（退出码 $($process.ExitCode)）。请检查 $stderrLog 和 $serialLog。"
    }

    Set-Content -LiteralPath (Join-Path $script:RuntimeDirectory "$($vm.Name).pid") `
        -Value $process.Id `
        -Encoding ascii
    $started += $vm.Name
    Write-Host "[$($vm.Name)] 已启动，PID=$($process.Id)，SSH=127.0.0.1:$($vm.SshPort)，集群地址=$($vm.ClusterAddress)。"
}

if ($started.Count -eq 0) {
    Write-Host '三台虚拟机均已在运行，未重复启动。'
}
else {
    Write-Host "本次启动：$($started -join ', ')。首次启动需等待 cloud-init 完成。"
}
