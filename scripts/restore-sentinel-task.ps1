# Restore the existing verified logon task. Bootstrap may run in-turn; deploy remains external.
param([switch]$Check,[switch]$RestoreOnly,[Parameter(Mandatory=$true)][string]$ExpectedSha,
 [string]$Install=(Join-Path $env:LOCALAPPDATA 'wasm-agent'),
 [string]$NodeHome=$env:USERPROFILE,
 [string]$Source=(Join-Path $env:USERPROFILE 'orca\projects\wasm-agent'),
 [string]$ParentSession='', [string]$Owner='master')
$ErrorActionPreference='Stop'
if(-not $Check -and -not $RestoreOnly -and $env:WASM_AGENT_IN_TURN -eq '1'){throw 'restore_sentinel_deploy_requires_external_executor: use -RestoreOnly for watcher bootstrap from a node turn'}
if($ExpectedSha -notmatch '^[a-f0-9]{40}$'){throw 'full expected source SHA required'}
$sentinel=Join-Path $Install 'wa-sentinel.exe'
$launcher=Join-Path $Install 'sentinel-task.cmd'
if(-not (Test-Path $sentinel) -or -not (Test-Path $launcher)){throw 'existing installed sentinel/task launcher required'}
$task=Get-ScheduledTask -TaskName 'wasm-agent-sentinel' -ErrorAction Stop
if($task.Actions.Count -ne 1 -or [IO.Path]::GetFullPath($task.Actions[0].Execute) -ne [IO.Path]::GetFullPath($launcher) -or $task.Actions[0].Arguments){throw 'existing task action identity mismatch'}
if([string]$task.Principal.RunLevel -ne 'Limited' -or [string]$task.Principal.LogonType -ne 'Interactive'){throw 'task must retain limited interactive identity'}
$taskAccount=[Security.Principal.NTAccount]::new($task.Principal.UserId)
$taskSid=$taskAccount.Translate([Security.Principal.SecurityIdentifier]).Value
$currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($taskSid -ne $currentSid){throw 'existing task principal differs from current operator identity'}
if($task.State -eq 'Running'){throw 'existing task already running; inspect rather than launch competitor'}
if(@(Get-CimInstance Win32_Service|Where-Object {$_.PathName -match 'wa-sentinel'}).Count){throw 'SCM installation exists; use its native lifecycle instead'}
$env:WASM_AGENT_HOME=$NodeHome
$env:WA_INSTALL_DIR=$Install
function Native([string[]]$Arguments){$raw=& $sentinel @Arguments;if($LASTEXITCODE -ne 0){throw ('sentinel refusal: '+($raw -join "`n"))};return ($raw -join "`n")}
$pre=(Native -Arguments @('preflight'))|ConvertFrom-Json
if($pre.watcher -ne 'not_running' -or -not $pre.inventory_verified -or $pre.stop_file){throw 'watcher, inventory or intentional-stop boundary refuses restoration'}
function InvokeSourceGit([string[]]$Arguments){$raw=& git.exe -C $Source @Arguments;if($LASTEXITCODE -ne 0){throw 'canonical Git inspection failed'};return ($raw -join "`n").Trim()}
if((InvokeSourceGit -Arguments @('branch','--show-current')) -ne 'main' -or (InvokeSourceGit -Arguments @('status','--porcelain'))){throw 'clean canonical main required'}
if((InvokeSourceGit -Arguments @('rev-parse','HEAD')) -ne $ExpectedSha -or (InvokeSourceGit -Arguments @('rev-parse','origin/main')) -ne $ExpectedSha -or ((InvokeSourceGit -Arguments @('ls-remote','origin','refs/heads/main')) -split '\s+')[0] -ne $ExpectedSha){throw 'canonical/local/remote source mismatch'}
$box=Join-Path $NodeHome '.wasm-agent\sentinel'
$effect=Join-Path $box 'protocol-effect.json'
$effectState=if(Test-Path $effect){(Get-Content $effect -Raw)|ConvertFrom-Json}else{$null}
if(-not $RestoreOnly -and $effectState -and $effectState.phase -ne 'verified'){throw 'prior protocol effect unsettled; reconcile, never replay'}
$text=[IO.File]::ReadAllText($launcher)
$needle='"%~dp0wa-sentinel.exe" watch'
$already=$text.Contains('"%~dp0wa-sentinel.exe" start')
if(-not $already -and ($text.Split(@($needle),[StringSplitOptions]::None).Count -ne 2)){throw 'launcher shape unknown; no guessed edit'}
if($Check){@{ok=$true;check_only=$true;external_required=(-not $RestoreOnly);restore_only=[bool]$RestoreOnly;unsettled_effect=if($effectState -and $effectState.phase -ne 'verified'){$effectState.id}else{$null};watcher='not_running';pending_deploys=@($pre.pending_deploys);launcher_change_required=(-not $already);expected_sha=$ExpectedSha}|ConvertTo-Json -Compress;exit 0}
if(-not $RestoreOnly -and -not $ParentSession){throw 'parent session required for exact-source deployment'}
$backup=Join-Path $box ('task-restoration\'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
New-Item -ItemType Directory -Path $backup | Out-Null
[IO.File]::WriteAllText((Join-Path $backup 'scheduled-task.xml'),(Export-ScheduledTask -InputObject $task))
Copy-Item -LiteralPath $launcher -Destination (Join-Path $backup 'sentinel-task.cmd')
if(-not $already){$new=$text.Replace($needle,'"%~dp0wa-sentinel.exe" start');$staged=$launcher+'.restore';[IO.File]::WriteAllText($staged,$new,[Text.Encoding]::ASCII);Move-Item -LiteralPath $staged -Destination $launcher -Force}
if(-not ([IO.File]::ReadAllText($launcher).Contains('"%~dp0wa-sentinel.exe" start'))){throw 'launcher readback failed'}
# Preserve immutable prior requests. Reuse a matching queued request, otherwise write
# one fresh source-bound intent. Old source refusals are not effect replay authority.
$matching=@(Get-ChildItem (Join-Path $box 'requests') -Filter '*.json' | Where-Object {
 $r=(Get-Content $_.FullName -Raw)|ConvertFrom-Json
 $r.verb -eq 'deploy' -and $r.expected_sha -eq $ExpectedSha -and $r.session -eq $ParentSession -and $r.owner -eq $Owner
})
if(-not $RestoreOnly -and -not $matching.Count){Native -Arguments @('request','deploy','--expected-sha',$ExpectedSha,'--owner',$Owner,'--session',$ParentSession,'--reason','Human-authorized external stopped-watcher restoration and installation of published graph/history/Sentinel fixes; preserve original unknowns; no full release gate')|Out-File (Join-Path $backup 'request.log')}
Start-ScheduledTask -InputObject $task
$end=[DateTime]::UtcNow.AddSeconds(15);$ready=$false
while([DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 100;$observed=(Native -Arguments @('preflight'))|ConvertFrom-Json;if($observed.watcher -eq 'running'){$ready=$true;break}}
if(-not $ready){throw ('task start did not prove watcher readiness; retain '+$backup+'; do not blindly retry')}
$result=@{ok=$true;restored=$true;watcher_pid=$observed.watcher_pid;expected_sha=$ExpectedSha;deployment_complete=$false;restore_only=[bool]$RestoreOnly;unsettled_effect=if($effectState -and $effectState.phase -ne 'verified'){$effectState.id}else{$null};backup=$backup;pending_requests_preserved=$true;task_identity_preserved=$true}
$result|ConvertTo-Json -Compress|Set-Content (Join-Path $backup 'receipt.json');$result|ConvertTo-Json -Compress
