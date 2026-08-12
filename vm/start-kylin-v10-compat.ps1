[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

function Invoke-QmpHmpCommand {
    param(
        [Parameter(Mandatory)]
        [int]$Port,
        [Parameter(Mandatory)]
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
        $writer.WriteLine('{"execute":"qmp_capabilities","id":"caps"}')
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            if ($reader.ReadLine() -match '"id"\s*:\s*"caps"') {
                break
            }
        }
        $payload = @{
            execute = 'human-monitor-command'
            arguments = @{ 'command-line' = $Command }
            id = 'hmp'
        } | ConvertTo-Json -Compress
        $writer.WriteLine($payload)
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $line = $reader.ReadLine()
            if ($line -match '"id"\s*:\s*"hmp"') {
                return ($line | ConvertFrom-Json).return
            }
        }
        throw "QMP 未返回命令结果：$Command"
    }
    finally {
        $client.Dispose()
    }
}

$vm = @($script:ValidationVmDefinitions | Where-Object Name -eq 'kylin-v10-compat')[0]
$existing = @(Get-LabVmProcess -Name $vm.Name)
if ($existing.Count -gt 0) {
    $clusterArgument = "connect=127.0.0.1:$($vm.ClusterSwitchPort)"
    if (@($existing | Where-Object { $_.CommandLine -notmatch [Regex]::Escape($clusterArgument) }).Count -gt 0) {
        throw "[$($vm.Name)] 已运行，但没有连接验证网段；请先正常停止后再运行本脚本。"
    }
    Write-Host "[$($vm.Name)] 已在运行，PID=$($existing.ProcessId -join ',')，集群地址=$($vm.ClusterAddress)。"
    return
}

foreach ($requiredPath in @($script:QemuExecutable, $script:FirmwareImage, $vm.Disk)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "缺少麒麟验证机必需文件：$requiredPath"
    }
}

$switchProcesses = @(Get-LabVmProcess -Name $script:ClusterSwitchName)
if ($switchProcesses.Count -ne 1) {
    throw "集群二层交换机未唯一运行；请先执行 .\vm\start-all.ps1。"
}

$switchListeners = @(Get-LocalTcpListener -Port $vm.ClusterSwitchPort)
if ($switchListeners.Count -eq 0) {
    $linkId = 'link_' + $vm.Name.Replace('-', '_')
    $hubPortId = 'hub_' + $vm.Name.Replace('-', '_')
    $socketResult = Invoke-QmpHmpCommand -Port $script:ClusterSwitchQmpPort `
        -Command "netdev_add socket,id=$linkId,listen=127.0.0.1:$($vm.ClusterSwitchPort)"
    if ($socketResult -match '^Error:') {
        throw "添加麒麟验证机 socket 端口失败：$socketResult"
    }
    $hubResult = Invoke-QmpHmpCommand -Port $script:ClusterSwitchQmpPort `
        -Command "netdev_add hubport,id=$hubPortId,hubid=0,netdev=$linkId"
    if ($hubResult -match '^Error:') {
        throw "把麒麟验证机端口加入 hub 失败：$hubResult"
    }
    Start-Sleep -Seconds 1
    $switchListeners = @(Get-LocalTcpListener -Port $vm.ClusterSwitchPort)
}
if ($switchListeners.Count -ne 1 -or $switchListeners[0].OwningProcess -ne $switchProcesses[0].ProcessId) {
    throw "本机端口 $($vm.ClusterSwitchPort) 未由集群交换机独占监听。"
}

foreach ($port in @($vm.SshPort, $vm.QmpPort, $vm.QgaPort, $vm.VncPort)) {
    if (@(Get-LocalTcpListener -Port $port).Count -gt 0) {
        throw "[$($vm.Name)] 所需本机 TCP 端口 $port 已被占用，拒绝启动。"
    }
}

$runtime = Join-Path $script:RuntimeDirectory $vm.Name
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$serialLog = Join-Path $runtime 'boot-cluster-serial.log'
$stdoutLog = Join-Path $runtime 'qemu.stdout.log'
$stderrLog = Join-Path $runtime 'qemu.stderr.log'
$pidFile = Join-Path $runtime 'kylin.pid'
$arguments = @(
    '-name', $vm.Name,
    '-machine', 'virt',
    '-cpu', 'cortex-a72',
    '-accel', 'tcg,thread=multi',
    '-smp', '4',
    '-m', '4096',
    '-bios', (Get-QuotedArgument $script:FirmwareImage),
    '-device', 'virtio-gpu-pci',
    '-device', 'virtio-rng-pci',
    '-device', 'virtio-serial-pci,id=virtserial0',
    '-chardev', "socket,id=qga0,host=127.0.0.1,port=$($vm.QgaPort),server=on,wait=off",
    '-device', 'virtserialport,id=qga-channel0,chardev=qga0,name=org.qemu.guest_agent.0',
    '-display', "vnc=127.0.0.1:$($vm.VncDisplay)",
    '-monitor', 'none',
    '-serial', "file:$serialLog",
    '-drive', "if=none,id=osdisk,file=$($vm.Disk),format=qcow2,cache=writeback,discard=unmap",
    '-device', 'virtio-blk-pci,drive=osdisk',
    '-netdev', "user,id=management,hostfwd=tcp:127.0.0.1:$($vm.SshPort)-:22",
    '-device', "virtio-net-pci,netdev=management,mac=$($vm.ManagementMac)",
    '-netdev', "socket,id=cluster,connect=127.0.0.1:$($vm.ClusterSwitchPort)",
    '-device', "virtio-net-pci,netdev=cluster,mac=$($vm.ClusterMac)",
    '-qmp', "tcp:127.0.0.1:$($vm.QmpPort),server=on,wait=off",
    '-boot', 'order=c,menu=on',
    '-pidfile', $pidFile
)

$process = Start-Process -FilePath $script:QemuExecutable `
    -ArgumentList $arguments `
    -WorkingDirectory $script:QemuDirectory `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru
Start-Sleep -Seconds 3
if ($process.HasExited) {
    throw "[$($vm.Name)] QEMU 启动后立即退出（退出码 $($process.ExitCode)）。请检查 $stderrLog。"
}
$process.PriorityClass = 'BelowNormal'
Set-Content -LiteralPath $pidFile -Value $process.Id -Encoding ascii
Write-Host "[$($vm.Name)] 已启动，PID=$($process.Id)，SSH=127.0.0.1:$($vm.SshPort)，集群地址=$($vm.ClusterAddress)。"
