Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:QemuDirectory = 'D:\Program Files\qemu'
$script:QemuExecutable = Join-Path $script:QemuDirectory 'qemu-system-aarch64.exe'
$script:QemuImgExecutable = Join-Path $script:QemuDirectory 'qemu-img.exe'
$script:FirmwareImage = Join-Path $script:QemuDirectory 'QEMU_EFI.fd'
$script:RuntimeDirectory = Join-Path $PSScriptRoot 'runtime'
$script:LabSshPrivateKey = Join-Path $PSScriptRoot 'keys\lab_rsa'
$script:ClusterSwitchName = 'pg-cluster-switch'
$script:ClusterSwitchQmpPort = 23010

$script:VmDefinitions = @(
    [pscustomobject]@{
        Name = 'pg-primary'
        Role = 'Primary'
        Disk = Join-Path $PSScriptRoot 'disks\pg-primary.qcow2'
        DataDisk = Join-Path $PSScriptRoot 'disks\pg-primary-data.qcow2'
        Seed = Join-Path $PSScriptRoot 'seeds\pg-primary-seed.iso'
        SshPort = 22011
        QmpPort = 23011
        ClusterSwitchPort = 15911
        ClusterAddress = '192.168.80.110'
        ManagementMac = '52:54:00:80:10:10'
        ClusterMac = '52:54:00:12:34:10'
    }
    [pscustomobject]@{
        Name = 'pg-standby'
        Role = 'Standby'
        Disk = Join-Path $PSScriptRoot 'disks\pg-standby.qcow2'
        DataDisk = Join-Path $PSScriptRoot 'disks\pg-standby-data.qcow2'
        Seed = Join-Path $PSScriptRoot 'seeds\pg-standby-seed.iso'
        SshPort = 22012
        QmpPort = 23012
        ClusterSwitchPort = 15912
        ClusterAddress = '192.168.80.120'
        ManagementMac = '52:54:00:80:20:20'
        ClusterMac = '52:54:00:12:34:20'
    }
    [pscustomobject]@{
        Name = 'pg-pgpool'
        Role = 'Pgpool-II'
        Disk = Join-Path $PSScriptRoot 'disks\pg-pgpool.qcow2'
        DataDisk = $null
        Seed = Join-Path $PSScriptRoot 'seeds\pg-pgpool-seed.iso'
        SshPort = 22013
        QmpPort = 23013
        ClusterSwitchPort = 15913
        ClusterAddress = '192.168.80.130'
        ManagementMac = '52:54:00:80:30:30'
        ClusterMac = '52:54:00:12:34:30'
    }
)

function Assert-LabVmPrerequisites {
    foreach ($requiredPath in @($script:QemuExecutable, $script:QemuImgExecutable, $script:FirmwareImage)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "缺少 QEMU 必需文件：$requiredPath"
        }
    }

    foreach ($vm in $script:VmDefinitions) {
        foreach ($requiredPath in @($vm.Disk, $vm.Seed)) {
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                throw "缺少虚拟机文件：$requiredPath"
            }
        }
        if ($vm.DataDisk -and -not (Test-Path -LiteralPath $vm.DataDisk -PathType Leaf)) {
            throw "缺少虚拟机数据盘：$($vm.DataDisk)"
        }
    }
}

function Get-LabVmProcess {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $escapedName = [Regex]::Escape($Name)
    @(Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-aarch64.exe'" -ErrorAction SilentlyContinue) |
        Where-Object { $_.CommandLine -match "(?:^|\s)-name\s+$escapedName(?:,|\s|$)" }
}

function Test-LocalTcpPort {
    param(
        [Parameter(Mandatory)]
        [int]$Port,
        [int]$TimeoutMilliseconds = 600
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Test-LabVmSsh {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Vm
    )

    if (-not (Test-Path -LiteralPath $script:LabSshPrivateKey -PathType Leaf)) {
        return $false
    }
    & ssh -q `
        -i $script:LabSshPrivateKey `
        -p $Vm.SshPort `
        -o BatchMode=yes `
        -o ConnectTimeout=3 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        'labadmin@127.0.0.1' `
        'true'
    return $LASTEXITCODE -eq 0
}

function Get-LocalTcpListener {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Get-QuotedArgument {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-LabVmQemuArguments {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Vm
    )

    $serialLog = Join-Path $script:RuntimeDirectory "$($Vm.Name)-serial.log"
    $arguments = @(
        '-name', $Vm.Name,
        '-machine', 'virt',
        '-cpu', 'cortex-a72',
        '-accel', 'tcg,thread=multi',
        '-smp', '4',
        '-m', '4096',
        '-bios', (Get-QuotedArgument $script:FirmwareImage),
        '-display', 'none',
        '-monitor', 'none',
        '-serial', "file:$serialLog",
        '-drive', "if=virtio,file=$($Vm.Disk),format=qcow2,cache=writeback,discard=unmap"
    )
    if ($Vm.DataDisk) {
        $arguments += @(
            '-drive', "if=virtio,file=$($Vm.DataDisk),format=qcow2,cache=writeback,discard=unmap"
        )
    }
    $arguments += @(
        '-drive', "if=virtio,file=$($Vm.Seed),format=raw,readonly=on",
        '-netdev', "user,id=management,hostfwd=tcp:127.0.0.1:$($Vm.SshPort)-:22",
        '-device', "virtio-net-pci,netdev=management,mac=$($Vm.ManagementMac)",
        '-netdev', "socket,id=cluster,connect=127.0.0.1:$($Vm.ClusterSwitchPort)",
        '-device', "virtio-net-pci,netdev=cluster,mac=$($Vm.ClusterMac)",
        '-qmp', "tcp:127.0.0.1:$($Vm.QmpPort),server=on,wait=off",
        '-no-reboot'
    )
    $arguments
}

function Get-ClusterSwitchQemuArguments {
    $arguments = @(
        '-name', $script:ClusterSwitchName,
        '-machine', 'none',
        '-nodefaults',
        '-display', 'none',
        '-monitor', 'none'
    )

    foreach ($vm in $script:VmDefinitions) {
        $linkId = 'link_' + $vm.Name.Replace('-', '_')
        $hubPortId = 'hub_' + $vm.Name.Replace('-', '_')
        $arguments += @(
            '-netdev', "socket,id=$linkId,listen=127.0.0.1:$($vm.ClusterSwitchPort)",
            '-netdev', "hubport,id=$hubPortId,hubid=0,netdev=$linkId"
        )
    }

    $arguments += @(
        '-qmp', "tcp:127.0.0.1:$($script:ClusterSwitchQmpPort),server=on,wait=off"
    )
    return $arguments
}
