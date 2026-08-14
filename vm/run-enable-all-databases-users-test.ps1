[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$key = Join-Path $PSScriptRoot 'keys\lab_rsa'
$rootPasswordFile = Join-Path $PSScriptRoot 'keys\root-password.txt'
$entrypoint = Join-Path $projectRoot 'enable-all-databases-users.sh'
$payload = Join-Path $projectRoot 'packages\payload\sshpass-1.10-aarch64-kylin-v10.tar.gz'
foreach ($required in @($key, $rootPasswordFile, $entrypoint, $payload)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "缺少测试文件：$required"
    }
}

$runId = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + $PID
$probeRole = 'pgpool_probe_' + [DateTime]::UtcNow.ToString('HHmmss')
$remoteDir = "/var/tmp/pg-rw-all-users-e2e-$runId"
$probeSecretFile = Join-Path $env:TEMP "pg-rw-all-users-$runId.secret"
$randomBytes = [byte[]]::new(24)
[Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
[IO.File]::WriteAllText(
    $probeSecretFile,
    [Convert]::ToHexString($randomBytes).ToLowerInvariant(),
    [Text.UTF8Encoding]::new($false)
)

$commonOptions = @(
    '-i', $key,
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL'
)
$kylinSsh = @($commonOptions + @('-p', '22021', 'labadmin@127.0.0.1'))
$kylinScp = @($commonOptions + @('-P', '22021'))
$primarySsh = @($commonOptions + @('-p', '22011', 'labadmin@127.0.0.1'))
$primaryScp = @($commonOptions + @('-P', '22011'))

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)] [string[]] $SshOptions,
        [Parameter(Mandatory)] [string] $Script
    )
    [Text.Encoding]::UTF8.GetBytes($Script.Replace("`r", '')) | & ssh @SshOptions 'bash -s'
    if ($LASTEXITCODE -ne 0) {
        throw "远端脚本执行失败，退出码=$LASTEXITCODE"
    }
}

try {
    & ssh @kylinSsh "mkdir -p '$remoteDir/packages/payload'"
    if ($LASTEXITCODE -ne 0) { throw '麒麟测试目录创建失败。' }

    & scp @kylinScp $entrypoint "labadmin@127.0.0.1:$remoteDir/enable-all-databases-users.sh"
    & scp @kylinScp $payload "labadmin@127.0.0.1:$remoteDir/packages/payload/sshpass-1.10-aarch64-kylin-v10.tar.gz"
    & scp @kylinScp $rootPasswordFile "labadmin@127.0.0.1:$remoteDir/root.secret"
    & scp @kylinScp $probeSecretFile "labadmin@127.0.0.1:$remoteDir/probe.secret"
    & scp @primaryScp $probeSecretFile "labadmin@127.0.0.1:/var/tmp/$probeRole.secret"
    if ($LASTEXITCODE -ne 0) { throw '测试文件上传失败。' }

    $createProbe = @'
set -Eeuo pipefail
role=__PROBE_ROLE__
secret="/var/tmp/${role}.secret"
sudo chmod 600 "${secret}"
password="$(tr -d '\r\n' <"${secret}")"
role_count="$(sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "select count(*) from pg_roles where rolname='${role}'")"
database_count="$(sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "select count(*) from pg_database where datname='${role}'")"
[[ "${role_count}|${database_count}" == '0|0' ]]
sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "create role ${role} login password '${password}'"
sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "create database ${role} owner ${role}"
unset password
sudo rm -f -- "${secret}"
'@.Replace('__PROBE_ROLE__', $probeRole)
    Invoke-RemoteScript -SshOptions $primarySsh -Script $createProbe

    $applyAndVerify = @'
set -Eeuo pipefail
remote_dir=__REMOTE_DIR__
role=__PROBE_ROLE__

sudo chown -R root:root "${remote_dir}"
sudo chmod 700 "${remote_dir}" "${remote_dir}/packages" "${remote_dir}/packages/payload"
sudo chmod 600 "${remote_dir}/root.secret" "${remote_dir}/probe.secret"
sudo sed -i 's/\r$//' "${remote_dir}/enable-all-databases-users.sh"
sudo bash -n "${remote_dir}/enable-all-databases-users.sh"

sudo bash -c '
  root_password="$(tr -d "\r\n" <"$1/root.secret")"
  printf "APPLY\n" | bash "$1/enable-all-databases-users.sh" \
    --pgpool-host 192.168.80.140 \
    --primary-host 192.168.80.110 \
    --standby-host 192.168.80.120 \
    --postgresql-port 5432 \
    --pgpool-port 5432 \
    --ssh-port 22 \
    --root-ssh-password "${root_password}"
' bash "${remote_dir}"

log_file="$(sudo bash -c 'ls -1t /var/log/pg-readwrite-proxy-lab/enable-all-databases-users-*.log | head -n 1')"
pgpool_backup="$(sudo sed -n 's/^.*Pgpool 备份=//p' "${log_file}" | tail -n 1)"
primary_backup="$(sudo sed -n 's/^.*Primary 备份=//p' "${log_file}" | tail -n 1)"
standby_backup="$(sudo sed -n 's/^.*Standby 备份=//p' "${log_file}" | tail -n 1)"
[[ "${pgpool_backup}" == /var/backups/pg-readwrite-proxy-lab/all-databases-users-*-pgpool ]]
[[ "${primary_backup}" == /var/backups/pg-readwrite-proxy-lab/all-databases-users-*-primary ]]
[[ "${standby_backup}" == /var/backups/pg-readwrite-proxy-lab/all-databases-users-*-standby ]]
printf '%s\n%s\n%s\n' "${pgpool_backup}" "${primary_backup}" "${standby_backup}" | sudo tee "${remote_dir}/backups" >/dev/null
sudo chmod 600 "${remote_dir}/backups"

password="$(sudo cat "${remote_dir}/probe.secret" | tr -d '\r\n')"
psql=/opt/pgpool-client-12.0/bin/psql
runtime=/opt/pgpool-runtime-kylin-v10/lib

for _ in $(seq 1 60); do
  set +e
  correct="$(PGPASSWORD="${password}" LD_LIBRARY_PATH="${runtime}" "${psql}" -XAtq -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -p 5432 -U "${role}" -d "${role}" \
    -c 'select current_user,current_database(),pg_is_in_recovery()' 2>/dev/null)"
  status=$?
  set -e
  [[ "${status}" == 0 && "${correct}" == "${role}|${role}|t" ]] && break
  sleep 1
done
[[ "${correct:-}" == "${role}|${role}|t" ]]

postgres_database="$(PGPASSWORD="${password}" LD_LIBRARY_PATH="${runtime}" "${psql}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p 5432 -U "${role}" -d postgres -c 'select current_database()')"
[[ "${postgres_database}" == postgres ]]

if sudo grep -Eq "^${role}:" /etc/pgpool-II/pool_passwd; then
  printf '测试角色意外存在于 pool_passwd。\n' >&2
  exit 1
fi

set +e
PGPASSWORD="wrong-${password}" LD_LIBRARY_PATH="${runtime}" "${psql}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p 5432 -U "${role}" -d "${role}" -c 'select 1' \
  >/var/tmp/pg-rw-all-users-wrong-password.$$.out 2>&1
wrong_status=$?
set -e
[[ "${wrong_status}" -ne 0 ]]
grep -Eiq 'password authentication failed|md5 authentication failed' /var/tmp/pg-rw-all-users-wrong-password.$$.out

PGPASSWORD="${password}" LD_LIBRARY_PATH="${runtime}" "${psql}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p 5432 -U "${role}" -d "${role}" \
  -c 'create table route_probe(id integer primary key)' >/dev/null
PGPASSWORD="${password}" LD_LIBRARY_PATH="${runtime}" "${psql}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p 5432 -U "${role}" -d "${role}" \
  -c 'insert into route_probe values (1)' >/dev/null
for _ in $(seq 1 60); do
  row="$(PGPASSWORD="${password}" LD_LIBRARY_PATH="${runtime}" "${psql}" -XAtq -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -p 5432 -U "${role}" -d "${role}" \
    -c 'select id from route_probe' 2>/dev/null || true)"
  [[ "${row}" == 1 ]] && break
  sleep 1
done
[[ "${row:-}" == 1 ]]
PGPASSWORD="${password}" LD_LIBRARY_PATH="${runtime}" "${psql}" -XAtq -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p 5432 -U "${role}" -d "${role}" -c 'drop table route_probe' >/dev/null
unset password
rm -f -- /var/tmp/pg-rw-all-users-wrong-password.$$.out
printf 'ALL_DATABASES_USERS_E2E_PASS role=%s database=%s select_node=standby wrong_password=rejected\n' "${role}" "${role}"
'@.Replace('__REMOTE_DIR__', $remoteDir).Replace('__PROBE_ROLE__', $probeRole)
    Invoke-RemoteScript -SshOptions $kylinSsh -Script $applyAndVerify
}
finally {
    Remove-Item -LiteralPath $probeSecretFile -Force -ErrorAction SilentlyContinue

    $cleanupErrors = [Collections.Generic.List[string]]::new()
    $backupPaths = @()
    try {
        $backupPaths = @(& ssh @kylinSsh "sudo cat '$remoteDir/backups' 2>/dev/null")
    }
    catch {
        $cleanupErrors.Add("无法读取测试备份路径：$($_.Exception.Message)")
    }

    if ($backupPaths.Count -eq 3) {
        $pgpoolBackup, $primaryBackup, $standbyBackup = $backupPaths
        $expectedPrefix = '/var/backups/pg-readwrite-proxy-lab/all-databases-users-'
        if (-not $pgpoolBackup.StartsWith($expectedPrefix) -or
            -not $primaryBackup.StartsWith($expectedPrefix) -or
            -not $standbyBackup.StartsWith($expectedPrefix)) {
            $cleanupErrors.Add('测试备份路径不在预期目录，拒绝自动恢复。')
        }
        else {
            try {
                $restorePgpool = @'
set -Eeuo pipefail
backup=__BACKUP__
sudo test -f "${backup}/pool_hba.conf.before"
sudo cp -a -- "${backup}/pool_hba.conf.before" /etc/pgpool-II/pool_hba.conf
sudo systemctl reload pgpool
'@.Replace('__BACKUP__', $pgpoolBackup)
                Invoke-RemoteScript -SshOptions $kylinSsh -Script $restorePgpool
            }
            catch {
                $cleanupErrors.Add("Pgpool 配置恢复失败：$($_.Exception.Message)")
            }

            foreach ($backend in @(
                @{ Ssh = $primarySsh; Backup = $primaryBackup; Label = 'Primary' },
                @{ Ssh = @($commonOptions + @('-p', '22012', 'labadmin@127.0.0.1')); Backup = $standbyBackup; Label = 'Standby' }
            )) {
                try {
                    $restoreBackend = @'
set -Eeuo pipefail
backup=__BACKUP__
hba_path="$(sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "select current_setting('hba_file')")"
sudo test -f "${backup}/pg_hba.conf.before"
sudo cp -a -- "${backup}/pg_hba.conf.before" "${hba_path}"
sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c 'select pg_reload_conf()' >/dev/null
'@.Replace('__BACKUP__', [string]$backend.Backup)
                    Invoke-RemoteScript -SshOptions ([string[]]$backend.Ssh) -Script $restoreBackend
                }
                catch {
                    $cleanupErrors.Add("$($backend.Label) 配置恢复失败：$($_.Exception.Message)")
                }
            }
        }
    }

    try {
        $cleanupStandby = @'
set -Eeuo pipefail
role=__PROBE_ROLE__
sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "select pg_terminate_backend(pid) from pg_stat_activity where usename='${role}' and pid<>pg_backend_pid()" >/dev/null
'@.Replace('__PROBE_ROLE__', $probeRole)
        $standbySsh = @($commonOptions + @('-p', '22012', 'labadmin@127.0.0.1'))
        Invoke-RemoteScript -SshOptions $standbySsh -Script $cleanupStandby
    }
    catch {
        $cleanupErrors.Add("Standby 测试会话清理失败：$($_.Exception.Message)")
    }

    try {
        $dropProbe = @'
set -Eeuo pipefail
role=__PROBE_ROLE__
sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "select pg_terminate_backend(pid) from pg_stat_activity where usename='${role}' and pid<>pg_backend_pid()" >/dev/null
sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "drop database if exists ${role}"
sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 -c "drop role if exists ${role}"
sudo rm -f -- "/var/tmp/${role}.secret"
'@.Replace('__PROBE_ROLE__', $probeRole)
        Invoke-RemoteScript -SshOptions $primarySsh -Script $dropProbe
    }
    catch {
        $cleanupErrors.Add("临时角色和数据库清理失败：$($_.Exception.Message)")
    }

    try {
        & ssh @kylinSsh "sudo rm -rf -- '$remoteDir'"
        if ($LASTEXITCODE -ne 0) { throw "退出码=$LASTEXITCODE" }
    }
    catch {
        $cleanupErrors.Add("麒麟临时目录清理失败：$($_.Exception.Message)")
    }

    if ($cleanupErrors.Count -gt 0) {
        throw ($cleanupErrors -join [Environment]::NewLine)
    }
}

Write-Host "测试通过且已恢复原配置。临时角色和数据库已删除：$probeRole。"
