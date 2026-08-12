[CmdletBinding()]
param(
    [string]$PasswordFile = (Join-Path $PSScriptRoot 'keys\root-password.txt'),
    [switch]$Rotate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vm-common.ps1')

function New-StrongLabPassword {
    $groups = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789'
    )
    $all = ($groups -join '')
    $characters = [Collections.Generic.List[char]]::new()
    foreach ($group in $groups) {
        $characters.Add($group[[Security.Cryptography.RandomNumberGenerator]::GetInt32($group.Length)])
    }
    while ($characters.Count -lt 28) {
        $characters.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    for ($index = $characters.Count - 1; $index -gt 0; $index--) {
        $swapIndex = [Security.Cryptography.RandomNumberGenerator]::GetInt32($index + 1)
        $temporary = $characters[$index]
        $characters[$index] = $characters[$swapIndex]
        $characters[$swapIndex] = $temporary
    }
    return -join $characters
}

function Protect-PasswordFile {
    param([Parameter(Mandatory)][string]$Path)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path '/inheritance:r' '/grant:r' "${identity}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "无法限制密码文件 ACL：$Path"
    }
}

function Invoke-LabSshWithSecretInput {
    param(
        [Parameter(Mandatory)][pscustomobject]$Vm,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][string]$RemoteScript
    )

    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RemoteScript))
    # Pass the script through bash -c so SSH stdin remains available for the
    # secret. Piping decoded source into bash would make read consume source.
    $remoteCommand = 'bash -c "$(echo ' + $encodedScript + ' | base64 -d)"'
    $sshExecutable = (Get-Command ssh.exe -ErrorAction Stop).Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $sshExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-T',
        '-i', $script:LabSshPrivateKey,
        '-p', [string]$Vm.SshPort,
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
    # SSH 标准输入必须明确使用 LF；PowerShell/Windows 的 WriteLine 会发送 CRLF，
    # Bash read 会把 CR 保留为密码的一部分。
    $process.StandardInput.Write($Secret + "`n")
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "[$($Vm.Name)] root 密码认证配置失败。远端错误：$stderr"
    }
    if ($stdout) {
        Write-Host $stdout.TrimEnd()
    }
}

Assert-LabVmPrerequisites
foreach ($vm in $script:VmDefinitions) {
    if (-not (Test-LabVmSsh -Vm $vm)) {
        throw "[$($vm.Name)] labadmin SSH 尚未就绪，拒绝修改认证策略。"
    }
}

$PasswordFile = [IO.Path]::GetFullPath($PasswordFile)
$keysDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'keys'))
if (-not $PasswordFile.StartsWith($keysDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw '密码文件必须位于 vm\keys 目录内。'
}

if ((Test-Path -LiteralPath $PasswordFile) -and -not $Rotate) {
    $rootPassword = [IO.File]::ReadAllText($PasswordFile).TrimEnd("`r", "`n")
    if ([string]::IsNullOrWhiteSpace($rootPassword)) {
        throw "密码文件为空：$PasswordFile"
    }
    Protect-PasswordFile -Path $PasswordFile
    Write-Host '复用现有本地 root 密码文件。'
}
else {
    New-Item -ItemType Directory -Path $keysDirectory -Force | Out-Null
    $rootPassword = New-StrongLabPassword
    [IO.File]::WriteAllText(
        $PasswordFile,
        $rootPassword + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    Protect-PasswordFile -Path $PasswordFile
    Write-Host '已生成新的共用 root 密码并保存到受保护的本地文件（未输出密码）。'
}
$remoteScript = @'
set -Eeuo pipefail
IFS= read -r ROOT_PASSWORD
# Windows OpenSSH may normalize redirected stdin to CRLF. Bash read removes LF
# but retains CR, so strip exactly one trailing CR before setting the password.
ROOT_PASSWORD="${ROOT_PASSWORD%$'\r'}"
test -n "${ROOT_PASSWORD}"

STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_DIR="/var/backups/pg-readwrite-proxy-lab/root-ssh-${STAMP}"
sudo install -d -m 700 "${BACKUP_DIR}"
sudo cp -a /etc/ssh/sshd_config /etc/shadow "${BACKUP_DIR}/"

rollback() {
  sudo cp -a "${BACKUP_DIR}/sshd_config" /etc/ssh/sshd_config
  sudo cp -a "${BACKUP_DIR}/shadow" /etc/shadow
  sudo /usr/sbin/sshd -t && sudo systemctl reload sshd || true
}
trap rollback ERR

printf 'root:%s\n' "${ROOT_PASSWORD}" | sudo /usr/sbin/chpasswd
ROOT_HASH="$(sudo getent shadow root | cut -d: -f2)"
if ! printf '%s\n%s\n' "${ROOT_PASSWORD}" "${ROOT_HASH}" | python -c 'import crypt, sys; password=sys.stdin.readline().rstrip("\n"); hashed=sys.stdin.readline().rstrip("\n"); sys.exit(0 if crypt.crypt(password, hashed) == hashed else 1)'; then
  echo 'root password hash verification failed' >&2
  exit 1
fi
echo 'password_hash_verification=pass'
unset ROOT_HASH

if sudo grep -Eq '^[[:space:]#]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config; then
  sudo sed -ri 's|^[[:space:]#]*PermitRootLogin[[:space:]]+.*$|PermitRootLogin yes|' /etc/ssh/sshd_config
else
  printf '\nPermitRootLogin yes\n' | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi
if sudo grep -Eq '^[[:space:]#]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config; then
  sudo sed -ri 's|^[[:space:]#]*PasswordAuthentication[[:space:]]+.*$|PasswordAuthentication yes|' /etc/ssh/sshd_config
else
  printf 'PasswordAuthentication yes\n' | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

sudo /usr/sbin/sshd -t
sudo systemctl reload sshd
sudo /usr/sbin/sshd -T | grep -E '^(permitrootlogin|passwordauthentication) '
sudo passwd -S root | cut -d' ' -f1,2
printf 'backup=%s\n' "${BACKUP_DIR}"
trap - ERR
unset ROOT_PASSWORD
'@

foreach ($vm in $script:VmDefinitions) {
    Write-Host "[$($vm.Name)] 正在配置 root 密码认证……"
    Invoke-LabSshWithSecretInput -Vm $vm -Secret $rootPassword -RemoteScript $remoteScript
}

$rootPassword = $null
Write-Host "三台虚拟机的 root 密码认证配置完成。密码保存在：$PasswordFile"
