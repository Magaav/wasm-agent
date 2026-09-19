# Local regression only: stubbed model calls, durable HTTP reads, and a scratch
# installation upgrade. Never uses the installed node, its DB, or its ports.
param([int]$Port=8993, [string]$WaExe="", [string]$Bash="C:/Program Files/Git/bin/bash.exe", [switch]$FullDeploy)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if (-not $WaExe) { $WaExe=Join-Path $root 'rust/target/release/wa.exe' }
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('wa-observe-restart-'+[Guid]::NewGuid().ToString('N'))
$install=Join-Path $scratch 'install'
$saved=@{}
$names=@('WASM_AGENT_HOME','WASM_AGENT_LUA_ROOT','WA_SCRIPT','WASM_AGENT_PROVIDER','WASM_AGENT_LLM_MODEL','WASM_AGENT_LLM_API_KEY','WA_INSTALL_DIR','WA_PORT','WA_CLIENT_PORT','WA_RUNTIME_WORKTREE')
foreach ($name in $names) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$owned=@()
function Check($value,$label) { if (-not $value) { throw $label } }
function Wait-Node {
  for ($i=0; $i -lt 100; $i++) {
    try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2).ok) { return } } catch {}
    Start-Sleep -Milliseconds 100
  }
  throw 'scratch node did not answer'
}
try {
  foreach ($p in @($Port,($Port+1),($Port+3),($Port+4),($Port+40),($Port+41))) {
    Check (-not (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)) "test port $p is already in use"
  }
  New-Item -ItemType Directory -Path $install | Out-Null
  $env:WASM_AGENT_HOME=$scratch
  $env:WASM_AGENT_LUA_ROOT=$root
  $env:WASM_AGENT_PROVIDER='opencode-go'
  $env:WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash'
  $env:WASM_AGENT_LLM_API_KEY='test-only'
  $env:WA_SCRIPT=Join-Path $root 'scripts/test-observability.lua'
  Push-Location $root
  try { $seed=& $WaExe; Check ($LASTEXITCODE -eq 0) 'fixture failed' } finally { Pop-Location }
  $session=($seed | Where-Object { $_ -like 'observability_fixture_session=*' }) -replace '^observability_fixture_session=',''
  Check ($session -and $session.Count -eq 1) 'fixture session missing'
  $env:WA_SCRIPT=$null
  $env:WASM_AGENT_LUA_ROOT=$null # Prove the embedded release, not source overrides.
  $initialHash=(Get-FileHash $WaExe).Hash
  Copy-Item -LiteralPath $WaExe -Destination (Join-Path $install 'wa.exe')
  Copy-Item -LiteralPath (Join-Path $root 'ui') -Destination (Join-Path $install 'ui') -Recurse
  # A historical failure must not override ownership of the new listener.
  [IO.File]::WriteAllText((Join-Path $install 'node.log'),"[serve] bind 127.0.0.1:$Port failed: historical fixture`n")
  $child=Start-Process -FilePath (Join-Path $install 'wa.exe') -ArgumentList @('serve','--port',$Port,'--client-port',($Port+1),'--ui',(Join-Path $install 'ui')) -WorkingDirectory $root -WindowStyle Hidden -PassThru
  $owned+=$child.Id
  Wait-Node
  $before=Invoke-RestMethod "http://127.0.0.1:$Port/models?session_id=$session"
  Check ($before.observability.total.calls -eq 2 -and $before.observability.total.input -eq 400) 'durable usage missing after seed process exit'
  Check ($before.observability.runtime.lua_mode -eq 'embedded') 'not testing the embedded release'
  $selected=Invoke-RestMethod "http://127.0.0.1:$Port/reasoning" -Method Post -ContentType 'text/plain' -Body 'low'
  Check ($selected.reasoning.selected -eq 'low') 'reasoning selection failed'
  $env:WA_INSTALL_DIR=$install
  $env:WA_PORT=[string]$Port
  $env:WA_CLIENT_PORT=[string]($Port+1)
  $env:WA_RUNTIME_WORKTREE=$root
  Push-Location $root
  try {
    if ($FullDeploy) { & $Bash scripts/deploy.sh --reason 'isolated deployment regression; no external model calls' }
    else { & $Bash scripts/upgrade.sh $WaExe }
    Check ($LASTEXITCODE -eq 0) 'scratch upgrade failed'
  } finally { Pop-Location }
  $newPid=[int](Get-Content -LiteralPath (Join-Path $install 'serve.pid'))
  $owned+=$newPid
  Check ($newPid -ne $child.Id) 'upgrade did not replace process'
  $listener=Get-NetTCPConnection -LocalPort $Port -State Listen
  Check ($listener.OwningProcess -eq $newPid) 'recorded PID is not the listener'
  $after=Invoke-RestMethod "http://127.0.0.1:$Port/models?session_id=$session"
  Check ($after.reasoning.selected -eq 'low') 'reasoning did not persist across upgrade'
  Check ($after.observability.total.calls -eq 2 -and $after.observability.total.input -eq 400) 'usage changed across upgrade'
  Check ($after.observability.runtime.native.process_id -eq $newPid) 'runtime fingerprint belongs to the wrong process'
  $events=Invoke-RestMethod "http://127.0.0.1:$Port/observability/events?id=$session"
  Check ($events.events.Count -eq $after.observability.events) 'session export does not match durable ledger'
  $all=Invoke-RestMethod "http://127.0.0.1:$Port/observability/events?id=*"
  Check ($all.events.Count -gt $events.events.Count) 'node export omitted other fixture sessions'
  $missing=Invoke-RestMethod "http://127.0.0.1:$Port/observability/events?id=does-not-exist"
  Check ($missing.error -eq 'unknown_session') 'unknown session was reported as a successful empty export'
  foreach ($asset in @('index.html','app.js','components.js','style.css','render.wasm')) {
    Check ((Get-FileHash (Join-Path $install "ui/$asset")).Hash -eq (Get-FileHash (Join-Path $root "ui/$asset")).Hash) "installed UI differs: $asset"
    Check (Test-Path (Join-Path $install "ui/$asset.pre-upgrade")) "UI recovery backup missing: $asset"
  }
  Check ((Get-FileHash (Join-Path $install 'wa.exe.pre-upgrade')).Hash -eq $initialHash) 'recovery binary differs from the pre-deployment install'
  if ($FullDeploy) {
    Check (Test-Path (Join-Path $install 'installed.txt')) 'deployment record missing'
    $record=Get-Content (Join-Path $install 'installed.txt')
    $recordedHash=($record | Where-Object { $_ -like 'sha256=*' }) -replace '^sha256=',''
    Check ($recordedHash -eq (Get-FileHash (Join-Path $install 'wa.exe')).Hash) 'recorded hash is not the installed binary hash'
    Check ((Get-Content (Join-Path $install 'runtime-worktree.txt')) -eq $root) 'runtime worktree marker differs'
  }
  Write-Host 'observability restart + scratch upgrade ok; zero external model calls'
} finally {
  # The script owns only processes it launched or upgrade.sh recorded in its
  # unique scratch installation. Do not kill other wa processes by image name.
  $pidFile=Join-Path $install 'serve.pid'
  if (Test-Path $pidFile) { $owned += [int](Get-Content -LiteralPath $pidFile) }
  foreach ($ownedId in ($owned | Select-Object -Unique)) {
    $process=Get-Process -Id $ownedId -ErrorAction SilentlyContinue
    if ($process -and $process.Path -eq (Join-Path $install 'wa.exe')) { Stop-Process -Id $ownedId -Force }
  }
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
  Write-Host "scratch evidence retained: $scratch"
}
