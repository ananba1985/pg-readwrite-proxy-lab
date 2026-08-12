[CmdletBinding()]
param(
    [string]$PasswordFile = (Join-Path $PSScriptRoot 'keys\root-password.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

$PasswordFile = [IO.Path]::GetFullPath($PasswordFile)
if (-not (Test-Path -LiteralPath $PasswordFile -PathType Leaf)) {
    throw "缺少 root 密码文件：$PasswordFile"
}
foreach ($vm in $script:VmDefinitions) {
    if (-not (Test-LabVmSsh -Vm $vm)) {
        throw "[$($vm.Name)] labadmin SSH 尚未就绪，无法建立验证跳板。"
    }
}

function Invoke-RootPasswordPeerTest {
    param(
        [Parameter(Mandatory)][pscustomobject]$Source,
        [Parameter(Mandatory)][object[]]$Targets,
        [Parameter(Mandatory)][string]$Secret
    )

    $verifierPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'tools\verify-root-password-login.py'))
    $verifierSource = [IO.File]::ReadAllText($verifierPath)
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($verifierSource))
    $targetAddresses = ($Targets.ClusterAddress -join ' ')
    $remoteCommand = "python -c 'import base64;exec(base64.b64decode(`"$encodedScript`"))' $($Source.ClusterAddress) $targetAddresses"

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command ssh.exe -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-T',
        '-i', $script:LabSshPrivateKey,
        '-p', [string]$Source.SshPort,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=8',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        'labadmin@127.0.0.1',
        $remoteCommand
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardInput.Write($Secret + "`n")
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "[$($Source.Name)] 固定 IP root 密码互登失败：$stderr"
    }
    if ($stdout) {
        Write-Host $stdout.TrimEnd()
    }
}

$rootPassword = [IO.File]::ReadAllText($PasswordFile).TrimEnd("`r", "`n")
if ([string]::IsNullOrWhiteSpace($rootPassword)) {
    throw "密码文件为空：$PasswordFile"
}
foreach ($source in $script:VmDefinitions) {
    $targets = @($script:VmDefinitions | Where-Object Name -ne $source.Name)
    Invoke-RootPasswordPeerTest -Source $source -Targets $targets -Secret $rootPassword
}
$rootPassword = $null
Write-Host '六个方向的固定 IP root 密码登录全部通过。'
