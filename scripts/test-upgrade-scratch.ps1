param([int]$Port = 18999)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$candidate = Join-Path $root 'rust/target/release/wa.exe'
$sentinel = Join-Path $root 'rust/wa-sentinel/target/release/wa-sentinel.exe'
if (-not (Test-Path -LiteralPath $candidate)) { throw "build wa.exe first: $candidate" }
if (-not (Test-Path -LiteralPath $sentinel)) { throw "build wa-sentinel.exe first: $sentinel" }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw "port $Port is busy" }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wa-upgrade-fixture-' + [Guid]::NewGuid().ToString('N'))
$install = Join-Path $scratch 'install'
$homeDir = Join-Path $scratch 'home'
$installed = Join-Path $install 'wa.exe'
$initial = $null
try {
  New-Item -ItemType Directory -Path $install,$homeDir -Force | Out-Null
  Copy-Item -LiteralPath $candidate -Destination $installed
  $env:WASM_AGENT_HOME = $homeDir
  $env:WA_INSTALL_DIR = $install
  $env:WA_RUNTIME_WORKTREE = $root
  $env:WA_PORT = [string]$Port
  $env:WA_CLIENT_PORT = [string]($Port + 1)
  $env:WA_UPGRADE_VIA = 'sentinel'
  $env:WA_UPGRADE_REASON = 'scratch self-update verification'
  $env:WA_UPGRADE_SCRIPT = Join-Path $root 'scripts/upgrade.sh'
  Remove-Item Env:WASM_AGENT_LUA_ROOT -ErrorAction SilentlyContinue
  $initial = Start-Process -FilePath $installed -ArgumentList @('serve','--port',[string]$Port,'--client-port',[string]($Port+1),'--ui',(Join-Path $root 'ui')) -WorkingDirectory $root -WindowStyle Hidden -PassThru
  $ready = $false
  for ($i=0; $i -lt 100; $i++) {
    try { $ready = (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).ok; if ($ready) { break } }
    catch { Start-Sleep -Milliseconds 100 }
  }
  if (-not $ready) { throw 'initial scratch node did not answer' }
  & $sentinel request upgrade --binary $candidate --reason 'scratch self-update verification' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "scratch upgrade request failed: $LASTEXITCODE" }
  & $sentinel once
  if ($LASTEXITCODE -ne 0) { throw "scratch sentinel failed: $LASTEXITCODE" }
  $done = @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.wasm-agent/sentinel/done') -Filter '*.json')
  if ($done.Count -ne 1 -or -not ((Get-Content -LiteralPath $done[0].FullName -Raw | ConvertFrom-Json).ok)) { throw 'sentinel did not settle exactly one successful upgrade' }
  $listener = (Get-NetTCPConnection -LocalPort $Port -State Listen | Select-Object -First 1).OwningProcess
  $recorded = [int]([IO.File]::ReadAllText((Join-Path $install 'serve.pid')).Trim())
  if ($listener -ne $recorded -or $listener -eq $initial.Id) { throw 'scratch listener does not match the new recorded pid' }
  $record = [IO.File]::ReadAllText((Join-Path $install 'installed.txt'))
  $hash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()
  if (-not $record.Contains("sha256=$hash")) { throw 'exact installed binary hash missing from sentinel record' }
  if (-not $record.Contains('source_provenance=unverified-binary') -or -not $record.Contains('via=sentinel')) { throw 'sentinel provenance is not honest' }
  if (-not (Test-Path -LiteralPath (Join-Path $install 'scripts/upgrade.sh'))) { throw 'upgrade script not shipped' }
  if (-not (Test-Path -LiteralPath (Join-Path $homeDir 'skills/self-update/SKILL.md'))) { throw 'self-update skill not shipped' }
  if ((Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 5).StatusCode -ne 200) { throw 'upgraded UI did not answer' }
  Write-Output 'scratch self-update ok: sentinel request, exact record, script, skill, pid, and UI'
}
finally {
  $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  foreach ($item in $listeners) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.OwningProcess)" -ErrorAction SilentlyContinue
    if ($process -and [IO.Path]::GetFullPath($process.ExecutablePath).Equals([IO.Path]::GetFullPath($installed),[StringComparison]::OrdinalIgnoreCase)) {
      Stop-Process -Id $item.OwningProcess -Force -ErrorAction SilentlyContinue
    }
  }
  if ($initial -and (Get-Process -Id $initial.Id -ErrorAction SilentlyContinue)) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($initial.Id)" -ErrorAction SilentlyContinue
    if ($process -and [IO.Path]::GetFullPath($process.ExecutablePath).Equals([IO.Path]::GetFullPath($installed),[StringComparison]::OrdinalIgnoreCase)) {
      Stop-Process -Id $initial.Id -Force -ErrorAction SilentlyContinue
    }
  }
  $resolvedScratch = [IO.Path]::GetFullPath($scratch)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedScratch.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedScratch) -match '^wa-upgrade-fixture-[0-9a-f]{32}$') {
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force -ErrorAction SilentlyContinue
  }
}
