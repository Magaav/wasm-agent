$ErrorActionPreference='Stop'
$root=(Get-Location).Path
$ev=Join-Path $root 'review-evidence'
$env:WASM_AGENT_HOME=Join-Path $ev 'home'
New-Item -ItemType Directory -Force $env:WASM_AGENT_HOME | Out-Null
$env:WASM_AGENT_LUA_ROOT=$root
$env:WA_FINAL_EVENTS=Join-Path $ev 'events.json'
$exe=Join-Path $env:LOCALAPPDATA 'wasm-agent/wa.exe'
foreach($name in @('test-final-answer','test-final-answer-loop')) {
 $env:WA_SCRIPT=Join-Path $root ('scripts/'+$name+'.lua')
 $null | & $exe --db (Join-Path $ev ($name+'.db')) *> (Join-Path $ev ($name+'.log'))
 Write-Output "$name exit=$LASTEXITCODE"
 Get-Content (Join-Path $ev ($name+'.log'))
}
