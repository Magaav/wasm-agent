# Read-only/negative proof. Never starts a task or changes installed scripts.
param([string]$Installer=(Join-Path $PSScriptRoot 'restore-sentinel-task.ps1'))
$ErrorActionPreference='Stop';$checks=0
function Check($value,$why){if(-not $value){throw $why};$script:checks++}
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($Installer,[ref]$tokens,[ref]$errors)|Out-Null
Check ($errors.Count -eq 0) 'restoration parse errors'
$text=[IO.File]::ReadAllText($Installer)
Check ($text.IndexOf('restore_sentinel_requires_external_executor') -lt $text.IndexOf('Get-ScheduledTask')) 'apply must refuse before runtime effects'
foreach($required in @('existing task action identity mismatch','task must retain limited interactive identity','prior protocol effect unsettled','scheduled-task.xml','launcher readback failed','pending_requests_preserved')){Check ($text.Contains($required)) ('missing boundary '+$required)}
Check (-not $text.Contains('Start-Process')) 'no detached bypass'
Check (-not $text.Contains('Register-ScheduledTask')) 'no new task or identity mutation'
Check (-not $text.Contains('Stop-Process')) 'no process termination'
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$old=$env:WASM_AGENT_IN_TURN;$env:WASM_AGENT_IN_TURN='1'
try{$ErrorActionPreference='Continue';$result=& $ps -NoProfile -NonInteractive -File $Installer -ExpectedSha ('a'*40) 2>&1;$code=$LASTEXITCODE;$ErrorActionPreference='Stop';Check ($code -ne 0 -and (($result|Out-String).Contains('restore_sentinel_requires_external_executor'))) 'in-turn apply not refused'}finally{$env:WASM_AGENT_IN_TURN=$old}
@{ok=$true;checks=$checks;skipped=0;live_effects=0;scope='restoration parser and pre-effect refusal'}|ConvertTo-Json -Compress
