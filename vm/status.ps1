[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

$switchProcesses = @(Get-LabVmProcess -Name $script:ClusterSwitchName)
Write-Host "Cluster switch: running=$($switchProcesses.Count -gt 0) pid=$($switchProcesses.ProcessId -join ',')"

$rows = foreach ($vm in $script:VmDefinitions) {
    $processes = @(Get-LabVmProcess -Name $vm.Name)
    [pscustomobject]@{
        Name = $vm.Name
        Role = $vm.Role
        Running = $processes.Count -gt 0
        PID = if ($processes.Count -gt 0) { $processes.ProcessId -join ',' } else { '' }
        SSH = if (Test-LabVmSsh -Vm $vm) { "ready ($($vm.SshPort))" } else { "not-ready ($($vm.SshPort))" }
        SwitchPort = $vm.ClusterSwitchPort
        ClusterIP = $vm.ClusterAddress
    }
}

$rows | Format-Table -AutoSize
