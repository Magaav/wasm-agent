# Native Windows SCM installation. Run externally as administrator; never from an agent run.
# -Check is read-only. Apply registers STOPPED/MANUAL first; only -Start consumes pending work.
param(
    [string]$Name = 'wasm-agent-sentinel',
    [string]$Install = (Join-Path $env:LOCALAPPDATA 'wasm-agent'),
    [string]$NodeHome = $env:USERPROFILE,
    [string]$WorkingDirectory = '',
    [System.Management.Automation.PSCredential]$Credential,
    [string]$OperatorSid = '',
    [switch]$ConfirmAccountProvisioned,
    [switch]$Check,
    [switch]$Start,
    [switch]$MigrateTask
)
$ErrorActionPreference = 'Stop'
if ($env:WASM_AGENT_IN_TURN -eq '1' -and -not $Check) { throw 'service installation must run outside the node turn' }
if ($Name -notmatch '^[A-Za-z0-9_-]{1,80}$') { throw 'invalid service name' }
foreach ($value in @($Install,$NodeHome)) {
    if (-not [IO.Path]::IsPathRooted($value) -or -not (Test-Path -LiteralPath $value -PathType Container)) { throw 'absolute existing install/home required' }
    if ($value.Contains('"') -or $value.Contains("`n") -or $value.Contains("`r")) { throw 'invalid service path' }
}
$Install = (Get-Item -LiteralPath $Install).FullName
$NodeHome = (Get-Item -LiteralPath $NodeHome).FullName
$Binary = Join-Path $Install 'wa-sentinel.exe'
if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) { throw 'installed sentinel binary missing' }
if (-not $WorkingDirectory) {
    $rootFile = Join-Path $Install 'runtime-worktree.txt'
    if (-not (Test-Path -LiteralPath $rootFile)) { throw 'explicit WorkingDirectory or runtime-worktree.txt required' }
    $WorkingDirectory = [IO.File]::ReadAllText($rootFile).Trim()
}
if (-not [IO.Path]::IsPathRooted($WorkingDirectory) -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw 'absolute native working directory required' }
$WorkingDirectory = (Get-Item -LiteralPath $WorkingDirectory).FullName
if ($WorkingDirectory.Contains('"')) { throw 'working directory quote refused' }
$Data = Join-Path $NodeHome '.wasm-agent'
$State = Join-Path $Data 'sentinel'
$Config = Join-Path $Install 'sentinel-service.json'
$Task = Get-ScheduledTask -TaskName 'wasm-agent-sentinel' -ErrorAction SilentlyContinue
$Service = Get-CimInstance Win32_Service -Filter "Name='$Name'"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$preflight = [ordered]@{schema=1;name=$Name;binary=$Binary;home=$NodeHome;cwd=$WorkingDirectory;elevated=$elevated;
    existing_service=($null -ne $Service);task_present=($null -ne $Task);task_state=if($Task){[string]$Task.State}else{$null};
    credential_required=$true;start_requested=[bool]$Start;pending_queue_preserved=$true}
if ($Check) { $preflight | ConvertTo-Json -Compress; exit 0 }
if (-not $elevated) { throw 'administrator registration authority required; no changes made' }
if (-not $Credential) { throw 'explicit non-administrator service Credential required; never default to LocalSystem' }
if (-not $ConfirmAccountProvisioned) { throw 'confirm scoped filesystem rights, Log on as a service, DPAPI/credential and node-control identity provisioning before registration' }
if ($Service) { throw 'existing service requires explicit reconciliation; not overwritten or restarted' }
if (Test-Path -LiteralPath $Config) { throw 'existing service config requires reconciliation; not overwritten' }
if (-not (Test-Path -LiteralPath $State -PathType Container)) { throw 'existing sentinel state required; install node first' }
if ($Task -and $Task.State -eq 'Running') { throw 'legacy task still running; stop externally and prove drain before migration' }
if ($Task -and -not $MigrateTask) { throw 'legacy task present; explicit -MigrateTask required' }
$Account = $Credential.UserName
if ($Account -notmatch '^[A-Za-z0-9_.-]+\\[A-Za-z0-9_.-]+$') { throw 'explicit local DOMAIN\account required' }
$localName = $Account.Split('\')[-1]
if ($Account.Split('\')[0] -notin @('.',$env:COMPUTERNAME)) { throw 'domain/cloud accounts need separately verified service logon policy; local account required' }
$User = Get-LocalUser -Name $localName
if (-not $User.Enabled) { throw 'service account disabled' }
$accountSid = $User.SID.Value
if ($accountSid -match '-500$') { throw 'built-in administrator refused' }
$admin = Get-LocalGroup -SID 'S-1-5-32-544'
$members = @(Get-LocalGroupMember -Group $admin.Name)
if ($members | Where-Object {$_.SID.Value -eq $accountSid -or $_.ObjectClass -eq 'Group'}) {
    throw 'administrator or nested administrator-group membership unresolved; least-privilege account required'
}
# Do not grant broad access to the operator profile. Existing explicit permissions must suffice.
# Read/write rights and Log on as a service must be provisioned externally for the chosen account.
# DPAPI/current-user credentials and user-owned node control require deliberate identity migration.
if (-not $OperatorSid) { $OperatorSid = $identity.User.Value }
if ($OperatorSid -notmatch '^S-1-5-[0-9-]+$') { throw 'invalid explicit operator SID' }
$env:WASM_AGENT_HOME = $NodeHome
$env:WA_INSTALL_DIR = $Install
$env:WA_INSTANCE_BASE_HOME = $NodeHome
$env:WA_INSTANCE_OPERATOR_INSTALL = $Install
Remove-Item Env:WASM_AGENT_INSTANCE -ErrorAction SilentlyContinue
$probe = & $Binary preflight
if ($LASTEXITCODE -ne 0) { throw 'sentinel preflight failed; no service created' }
$watcher = $probe | ConvertFrom-Json
if ($watcher.watcher -ne 'not_running' -or $watcher.stop_file -or -not $watcher.inventory_verified) {
    throw 'watcher live/unverified or intentionally stopped; preserve intent and reconcile externally'
}
# Durable backup BEFORE the task/config/SCM mutation. No credentials enter the evidence.
$generation = Join-Path $State ('service-install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $generation | Out-Null
if ($Task) {
    [IO.File]::WriteAllText((Join-Path $generation 'scheduled-task.xml'),(Export-ScheduledTask -TaskName $Task.TaskName),[Text.UTF8Encoding]::new($false))
}
foreach ($file in @('supervisor','sentinel.pid','stop')) {
    $source = Join-Path $State $file
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $generation $file) }
}
$configValue = [ordered]@{schema=1;name=$Name;home=$NodeHome;install=$Install;cwd=$WorkingDirectory;
    environment=[ordered]@{WA_SENTINEL_SCRIPTS=(Join-Path $Install 'scripts');WA_SENTINEL_WAKE_BUDGET='6';
        WA_SENTINEL_JOB_WAKE_BUDGET='6';WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY='1';
        PATH=($env:PATH);CARGO_BUILD_JOBS='2';WA_GATE_JOBS='2'}}
$configText = $configValue | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($Config,$configText,[Text.UTF8Encoding]::new($false))
# Protect executable configuration against unrelated unprivileged writers. This is cooperative
# local protection, not a sandbox against administrator/operator source modifications.
$acl = [Security.AccessControl.FileSecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544',$OperatorSid)) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))
}
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($User.SID,'ReadAndExecute','Allow'))
Set-Acl -LiteralPath $Config -AclObject $acl
$originalOwner=$env:WA_SENTINEL_SUPERVISOR
$env:WA_SENTINEL_SUPERVISOR='none'
# Old installed binaries do not understand this door; refusal occurs BEFORE service registration.
& $Binary service-config-check --name $Name --config $Config
$validatedExit=$LASTEXITCODE
$env:WA_SENTINEL_SUPERVISOR=$originalOwner
if ($validatedExit -ne 0) { throw "installed binary cannot validate service config; config/evidence retained at $generation; no service registered" }
$command = '"' + $Binary + '" service --name ' + $Name + ' --config "' + $Config + '"'
New-Service -Name $Name -DisplayName 'wasm-agent Sentinel' -BinaryPathName $command -StartupType Manual -Credential $Credential | Out-Null
# SCM recovery does not start a deliberately stopped service. Non-crash failures are also covered.
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'
& $sc failure $Name reset= 86400 actions= restart/5000/restart/15000/restart/60000
if ($LASTEXITCODE -ne 0) { throw 'SCM recovery configuration failed; service remains stopped/manual' }
& $sc failureflag $Name 1
if ($LASTEXITCODE -ne 0) { throw 'SCM non-crash recovery configuration failed; service remains stopped/manual' }
# Exact operator/service-account lifecycle rights, not SERVICE_ALL_ACCESS for Everyone.
$dacl = 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)' +
    '(A;;CCLCRPWPLO;;;' + $OperatorSid + ')(A;;CCLCRPWPLO;;;' + $accountSid + ')'
& $sc sdset $Name $dacl
if ($LASTEXITCODE -ne 0) { throw 'SCM lifecycle ACL failed; service remains stopped/manual' }
$verify = Get-CimInstance Win32_Service -Filter "Name='$Name'"
if ($verify.PathName -cne $command -or $verify.State -ne 'Stopped' -or $verify.StartName -notlike ('*\'+$localName)) { throw 'SCM registration readback mismatch; migration not finalized' }
$registration = [ordered]@{ok=$true;phase='registered-stopped';name=$Name;command=$command;account_sid=$accountSid;
    binary_sha256=(Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash;config_sha256=(Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash;
    pending_requests_preserved=$true;backup=$generation;live_scm_proven=$false}
[IO.File]::WriteAllText((Join-Path $generation 'registration.json'),($registration|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
if ($Start) {
    # Same validated lifecycle door as deploy, not an ad hoc detached watcher.
    # Until real readiness, leave the old task enabled and service manual/stopped on failure.
    $previousSupervisor=$env:WA_SENTINEL_SUPERVISOR
    try {
        $env:WA_SENTINEL_SUPERVISOR='windows:'+$Name
        & $Binary start
        if ($LASTEXITCODE -ne 0) { throw 'SCM start/readiness failed; inspect service logs, no fallback/replay' }
    } finally { $env:WA_SENTINEL_SUPERVISOR=$previousSupervisor }
    $verify = Get-CimInstance Win32_Service -Filter "Name='$Name'"
    if ($verify.State -ne 'Running' -or $verify.ProcessId -eq 0) { throw 'SCM did not prove running service' }
    # The verified watcher records windows:<name> itself after acquiring lifetime ownership.
    if ([IO.File]::ReadAllText((Join-Path $State 'supervisor')).Trim() -ne ('windows:'+$Name)) { throw 'watcher manager binding mismatch' }
    if ([IO.File]::ReadAllText((Join-Path $State 'sentinel.pid')).Trim() -ne [string]$verify.ProcessId) { throw 'SCM process does not match watcher PID; migration remains partial' }
    if ($Task) { Disable-ScheduledTask -TaskName $Task.TaskName | Out-Null }
    Set-Service -Name $Name -StartupType Automatic
    & $sc config $Name start= delayed-auto
    if ($LASTEXITCODE -ne 0) { throw 'delayed startup configuration failed; do not claim complete migration' }
    $serviceRegistry=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$Name)
    if ($serviceRegistry.DelayedAutoStart -ne 1) { throw 'delayed automatic startup readback failed; migration remains partial' }
    $final = Get-CimInstance Win32_Service -Filter "Name='$Name'"
    if ($final.State -ne 'Running' -or $final.ProcessId -ne $verify.ProcessId -or $final.StartMode -ne 'Auto' -or $final.PathName -cne $command) { throw 'final SCM readback mismatch; migration remains partial' }
    if ($Task -and (Get-ScheduledTask -TaskName $Task.TaskName).State -ne 'Disabled') { throw 'legacy task disable readback failed; migration remains partial' }
    $registration.phase='running';$registration.live_scm_proven=$true;$registration.process_id=$final.ProcessId
}
[IO.File]::WriteAllText((Join-Path $generation 'result.json'),($registration|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$registration | ConvertTo-Json -Compress
