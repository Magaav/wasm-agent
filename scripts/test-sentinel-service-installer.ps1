# Parser/negative/read-only checks. No SCM registration, task change, credentials or live watcher.
param([string]$Installer = (Join-Path $PSScriptRoot 'install-sentinel-service.ps1'), [string]$Scratch = '')
$ErrorActionPreference='Stop'
$checks=0
function Check($value,$why){if(-not $value){throw $why};$script:checks++}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Installer,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'installer parse errors'
$text=[IO.File]::ReadAllText($Installer)
foreach($required in @('administrator registration authority required','never default to LocalSystem','ConfirmAccountProvisioned',
  'registered-stopped','scheduled-task.xml','service-config-check','RestartCount','failureflag','pending_requests_preserved')) {
 if($required -eq 'RestartCount'){Check ($text.Contains('restart/5000/restart/15000/restart/60000')) 'missing recovery actions'}
 else{Check ($text.Contains($required)) ('missing boundary '+$required)}
}
Check (-not $text.Contains('Start-Process')) 'installer must not detach service from its manager'
Check ($text.IndexOf('SCM did not prove running service') -lt $text.IndexOf('Disable-ScheduledTask')) 'legacy task disabled before readiness'
Check ($text.IndexOf('watcher manager binding mismatch') -lt $text.IndexOf('Disable-ScheduledTask')) 'legacy task disabled before exact watcher binding'
Check ($text.Contains('final SCM readback mismatch')) 'missing final live/config readback'
Check ($text.Contains('legacy task disable readback failed')) 'missing legacy task final readback'
Check ($text.IndexOf('administrator registration authority required') -lt $text.IndexOf('New-Item -ItemType Directory')) 'registration effects before authority check'
Check ($text.Contains('StartupType Manual')) 'service registration must be stopped/manual'
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if(-not $Scratch){$Scratch=Join-Path $env:TEMP ('wa-service-installer-check-'+[Guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $Scratch -Force | Out-Null
$fixtureHome=Join-Path $Scratch 'home';$install=Join-Path $Scratch 'install';$cwd=Join-Path $Scratch 'source'
foreach($dir in @($fixtureHome,$install,$cwd)){New-Item -ItemType Directory -Path $dir | Out-Null}
[IO.File]::WriteAllText((Join-Path $install 'wa-sentinel.exe'),'not executable; read-only check must not launch it')
$read=& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Installer -Check -Install $install -NodeHome $fixtureHome -WorkingDirectory $cwd
Check ($LASTEXITCODE -eq 0) 'read-only preflight failed'
$result=($read -join "`n") | ConvertFrom-Json
Check ($result.schema -eq 1 -and $result.pending_queue_preserved -and $result.credential_required) 'read-only result incomplete'
Check (-not (Test-Path (Join-Path $install 'sentinel-service.json'))) 'read-only check wrote config'
$originalTurn=$env:WASM_AGENT_IN_TURN
$env:WASM_AGENT_IN_TURN='1'
try {
 $ErrorActionPreference='Continue'
 $refused=& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Installer -Install $install -NodeHome $fixtureHome -WorkingDirectory $cwd 2>&1
 $refusedCode=$LASTEXITCODE;$ErrorActionPreference='Stop'
 Check ($refusedCode -ne 0 -and (($refused|Out-String).Contains('outside the node turn'))) 'in-turn registration must refuse'
}finally{$env:WASM_AGENT_IN_TURN=$originalTurn}
Check (-not (Test-Path (Join-Path $install 'sentinel-service.json'))) 'refusal wrote config'
@{ok=$true;checks=$checks;skipped=0;scm_effects=0;scope='installer parser and read-only/negative boundaries';evidence=$Scratch}|ConvertTo-Json -Compress
