# Parser and pre-effect validation only; never touches a real task/install.
param([string]$Helper=(Join-Path $PSScriptRoot 'bootstrap-sentinel-deploy.ps1'))
$ErrorActionPreference='Stop';$checks=0
function Check($v,$why){if(-not $v){throw $why};$script:checks++}
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$tokens,[ref]$errors)|Out-Null
Check ($errors.Count -eq 0) 'helper parser failed'
$text=[IO.File]::ReadAllText($Helper)
foreach($needle in @('bootstrap_task_action_mismatch','bootstrap_operator_sid_mismatch','bootstrap_prior_effect_unsettled','bootstrap_clean_published_source_required','scheduled-task.xml','bootstrap_launcher_restore_failed','bootstrap_candidate_changed','protocol bootstrap')){Check ($text.Contains($needle)) ('missing '+$needle)}
Check (-not $text.Contains('Register-ScheduledTask')) 'new task forbidden'
Check (-not $text.Contains('Stop-Process')) 'node/process stop forbidden in helper'
Check (-not $text.Contains('Start-Process')) 'ad hoc detachment forbidden'
Check ($text.IndexOf('Restore the original launcher') -lt $text.IndexOf('& $plan.candidate protocol')) 'launcher must restore before admission'
Check ($text.IndexOf('bootstrap_clean_published_source_required') -lt $text.IndexOf('Start-ScheduledTask')) 'source checked before task effect'
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ErrorActionPreference='Continue';$r=& $ps -NoProfile -NonInteractive -File $Helper -ExpectedSha 'bad' -ParentSession 'fixture' 2>&1;$code=$LASTEXITCODE;$ErrorActionPreference='Stop'
Check ($code -ne 0 -and ($r|Out-String).Contains('bootstrap_identity_invalid')) 'invalid identity refuses before task lookup'
@{ok=$true;checks=$checks;skipped=0;live_effects=0;scope='OS-task bootstrap parser and boundaries'}|ConvertTo-Json -Compress
