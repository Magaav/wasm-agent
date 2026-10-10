# Checked one-shot reuse of the existing limited logon task; no task registration or binary copy.
param([switch]$Check,[Parameter(Mandatory=$true)][string]$ExpectedSha,[Parameter(Mandatory=$true)][string]$ParentSession,
 [string]$Owner='master',[string]$Install=(Join-Path $env:LOCALAPPDATA 'wasm-agent'),[string]$NodeHome=$env:USERPROFILE,
 [string]$Source=(Join-Path $env:USERPROFILE 'orca\projects\wasm-agent'))
$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[a-f0-9]{40}$' -or $ParentSession -notmatch '^[a-zA-Z0-9-]+$' -or $Owner -notmatch '^[a-zA-Z0-9-]+$'){throw 'bootstrap_identity_invalid'}
$task=Get-ScheduledTask -TaskName 'wasm-agent-sentinel'
$launcher=Join-Path $Install 'sentinel-task.cmd';$installed=Join-Path $Install 'wa-sentinel.exe';$candidate=Join-Path $Source 'rust\wa-sentinel\target\release\wa-sentinel.exe'
if($task.Actions.Count -ne 1 -or [IO.Path]::GetFullPath($task.Actions[0].Execute) -ne [IO.Path]::GetFullPath($launcher) -or $task.Actions[0].Arguments){throw 'bootstrap_task_action_mismatch'}
if([string]$task.Principal.RunLevel -ne 'Limited' -or [string]$task.Principal.LogonType -ne 'Interactive' -or $task.State -eq 'Running'){throw 'bootstrap_task_identity_or_state_refused'}
$sid=([Security.Principal.NTAccount]::new($task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
if($sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'bootstrap_operator_sid_mismatch'}
if(@(Get-CimInstance Win32_Service|Where-Object {$_.PathName -match 'wa-sentinel'}).Count){throw 'bootstrap_scm_present; use native service'}
$env:WASM_AGENT_HOME=$NodeHome;$env:WA_INSTALL_DIR=$Install
$pre=(& $installed preflight)|ConvertFrom-Json
if($LASTEXITCODE -ne 0 -or $pre.watcher -ne 'running' -or $pre.stop_file -or -not $pre.inventory_verified -or @($pre.pending_deploys).Count){throw 'bootstrap_live_owner_or_queue_refused'}
$box=Join-Path $NodeHome '.wasm-agent\sentinel';$effect=Join-Path $box 'protocol-effect.json'
if(Test-Path $effect){
 $prior=(Get-Content $effect -Raw)|ConvertFrom-Json
 if($prior.phase -ne 'verified'){
  if($prior.phase -ne 'aborted_preinstall'){throw 'bootstrap_prior_effect_unsettled'}
  $retired=(& $candidate protocol retirement-status)|ConvertFrom-Json
  if($LASTEXITCODE -ne 0 -or -not $retired.released -or $retired.id -ne $prior.id){throw 'bootstrap_prior_effect_unsettled'}
 }
}
function Git([string[]]$Arguments){$raw=& git.exe -C $Source @Arguments;if($LASTEXITCODE -ne 0){throw 'bootstrap_source_git_failed'};return ($raw -join "`n").Trim()}
if((Git @('branch','--show-current')) -ne 'main' -or (Git @('status','--porcelain')) -or (Git @('rev-parse','HEAD')) -ne $ExpectedSha -or (Git @('rev-parse','origin/main')) -ne $ExpectedSha -or ((Git @('ls-remote','origin','refs/heads/main')) -split '\s+')[0] -ne $ExpectedSha){throw 'bootstrap_clean_published_source_required'}
if(-not(Test-Path $candidate)){throw 'bootstrap_candidate_missing'}
$text=[IO.File]::ReadAllText($launcher)
if(-not $text.Contains('"%~dp0wa-sentinel.exe" start') -or $text.Contains('bootstrap')){throw 'bootstrap_launcher_unknown_or_already_prepared'}
if($Check){@{ok=$true;check_only=$true;expected_sha=$ExpectedSha;watcher_pid=$pre.watcher_pid;task_sid=$sid;no_binary_copy=$true}|ConvertTo-Json -Compress;exit}
$generation=Join-Path $box ('task-bootstrap\'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'));New-Item -ItemType Directory $generation|Out-Null
Copy-Item -LiteralPath $launcher -Destination (Join-Path $generation 'sentinel-task.cmd')
[IO.File]::WriteAllText((Join-Path $generation 'scheduled-task.xml'),(Export-ScheduledTask -InputObject $task))
$runner=Join-Path $generation 'run.ps1';$candidateHash=(Get-FileHash $candidate -Algorithm SHA256).Hash.ToLower();$originalHash=(Get-FileHash $launcher -Algorithm SHA256).Hash.ToLower()
$body=@'
$ErrorActionPreference='Stop'
if($env:WASM_AGENT_IN_TURN -eq '1'){throw 'bootstrap_requires_os_task'}
$generation=Split-Path $PSCommandPath
$plan=Get-Content (Join-Path $generation 'plan.json') -Raw|ConvertFrom-Json
# Restore the original launcher BEFORE native execution, even if subsequent checks refuse.
Copy-Item -LiteralPath (Join-Path $generation 'sentinel-task.cmd') -Destination $plan.launcher -Force
if((Get-FileHash $plan.launcher -Algorithm SHA256).Hash.ToLower() -ne $plan.original_hash){throw 'bootstrap_launcher_restore_failed'}
if((Get-FileHash $plan.candidate -Algorithm SHA256).Hash.ToLower() -ne $plan.candidate_hash){throw 'bootstrap_candidate_changed'}
$env:WASM_AGENT_HOME=$plan.home;$env:WA_INSTALL_DIR=$plan.install
$env:WA_SENTINEL_SCRIPTS=Join-Path $plan.install 'scripts'
$env:PATH='C:\Program Files\Git\cmd;C:\Program Files\Git\usr\bin;C:\Program Files\nodejs;'+$env:PATH
Set-Location $plan.source
$ErrorActionPreference='Continue'
& $plan.candidate protocol bootstrap --expected-sha $plan.expected_sha --owner $plan.owner --session $plan.parent --reason 'Human-authorized existing-task bootstrap of current exact-source installer; installed observer predates native admission fixes; preserve old refusal/unknown records; no full release gate' 1> (Join-Path $generation 'stdout') 2> (Join-Path $generation 'stderr')
$code=$LASTEXITCODE
$ErrorActionPreference='Stop'
@{exit=$code;at=[DateTime]::UtcNow.ToString('o');launcher_restored=$true;installation_complete=$false}|ConvertTo-Json -Compress|Set-Content (Join-Path $generation 'result.json')
exit $code
'@
[IO.File]::WriteAllText($runner,$body,[Text.Encoding]::UTF8)
@{candidate=$candidate;candidate_hash=$candidateHash;source=$Source;expected_sha=$ExpectedSha;parent=$ParentSession;owner=$Owner;home=$NodeHome;install=$Install;launcher=$launcher;original_hash=$originalHash}|ConvertTo-Json -Compress|Set-Content (Join-Path $generation 'plan.json')
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oneShot="@echo off`r`nrem bootstrap one-shot; runner restores original launcher before native effects`r`n`"$ps`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runner`"`r`nexit /b %errorlevel%`r`n"
[IO.File]::WriteAllText($launcher+'.bootstrap',$oneShot,[Text.Encoding]::ASCII);Move-Item -LiteralPath ($launcher+'.bootstrap') -Destination $launcher -Force
Start-ScheduledTask -InputObject $task
@{ok=$true;os_task_started=$true;installation_complete=$false;generation=$generation;task_identity_preserved=$true;no_binary_copy=$true}|ConvertTo-Json -Compress
