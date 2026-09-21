# Actual extracted candidate, isolated HOME/ports, synthetic provider, no live credentials.
param([Parameter(Mandatory = $true)][string]$ArchivePath,
      [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/release-package.ps1')
. (Join-Path $PSScriptRoot 'lib/first-run.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('wa-package-runtime-' + [guid]::NewGuid())
$environment = @{}
$mock = $null
$server = $null
$checks = 0
$global:LASTEXITCODE = 0
function Check([bool]$Value, [string]$Label) {
  if (-not $Value) { throw "FAIL: $Label" }
  $script:checks++; Write-Output "PASS $Label"
}
function Wa([string[]]$Arguments) {
  $output = & (Join-Path $script:installed 'wa.exe') @Arguments
  if ($LASTEXITCODE -ne 0) { throw 'packaged_native_command_failed' }
  return ($output -join "`n")
}
try {
  $hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
  Check ($hash -eq $ExpectedSha256) 'archive matches independently supplied checksum'
  New-Item -ItemType Directory -Path $work | Out-Null
  foreach ($entry in @(Get-ChildItem Env: | Where-Object {
    $_.Name -like 'WASM_AGENT_*' -or $_.Name -like 'WA_*' -or $_.Name -in @('OPENAI_API_KEY', 'OPENCODE_GO_API_KEY')
  })) {
    $environment[$entry.Name] = $entry.Value
    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
  }
  $env:WASM_AGENT_HOME = Join-Path $work 'isolated home'
  $extracted = Join-Path $work 'extracted'
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extracted
  Test-WaReleasePackage $extracted | Out-Null
  $installed = Join-Path $work 'installed with spaces'
  & (Join-Path $extracted 'install.ps1') -InstallDir $installed
  Check ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) 'fresh installer completed'
  Test-WaReleasePackage $installed | Out-Null
  $checks++; Write-Output 'PASS installed inventory matches candidate'
  $before = (Get-FileHash -LiteralPath (Join-Path $installed 'wa.exe')).Hash
  $attempt = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Wait -PassThru -WindowStyle Hidden `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $extracted 'install.ps1') + '"'), '-InstallDir', ('"' + $installed + '"')) `
    -RedirectStandardOutput (Join-Path $work 'refusal.out') -RedirectStandardError (Join-Path $work 'refusal.err')
  Check ($attempt.ExitCode -ne 0 -and (Get-FileHash -LiteralPath (Join-Path $installed 'wa.exe')).Hash -eq $before) 'reinstall refuses without replacing existing bytes'
  $workspace = Join-Path $work 'workspace with spaces'
  New-Item -ItemType Directory -Path $workspace | Out-Null
  Push-Location $workspace
  try {
    Check ((Wa @('--version')) -match 'wasm-agent') 'native binary starts outside checkout'
    Check ((Wa @('help')) -match 'remember') 'embedded CLI loads without Lua/script overrides'
    $nodeBefore = Wa @('node')
    $marker = 'remember-' + [guid]::NewGuid().ToString('N')
    Wa @('remember', $marker) | Out-Null
    Check ((Wa @('recall', $marker)) -match $marker) 'memory survives a separate process'
    $portFile = Join-Path $work 'mock.port'
    $mock = Start-Process -FilePath (Get-Command node).Source -PassThru -WindowStyle Hidden `
      -ArgumentList @(('"' + (Join-Path $PSScriptRoot 'release-mock-provider.cjs') + '"'), ('"' + $portFile + '"')) `
      -RedirectStandardOutput (Join-Path $work 'mock.out') -RedirectStandardError (Join-Path $work 'mock.err')
    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $portFile)) { throw 'mock_provider_failed_to_start' }
    $url = 'http://127.0.0.1:' + [IO.File]::ReadAllText($portFile) + '/v1'
    $config = Get-WaConfigDirectory
    Write-WaPrivateText (Join-Path $config 'env') "WASM_AGENT_ONBOARDING_MODE=personal`nWASM_AGENT_LLM_API_KEY=fixture-key`n"
    $command = Join-Path $installed 'bin/wa.cmd'
    & $command setup -NonInteractive -Mode personal -Name 'Fixture Agent' -Workspace $workspace -BaseUrl $url -Model fixture -ValidateProvider
    Check ($LASTEXITCODE -eq 0) 'packaged setup validates mock provider'
    Check ((Wa @('node')) -eq $nodeBefore) 'setup preserves node identity'
    Check ((Wa @('recall', $marker)) -match $marker) 'setup preserves existing memory'
    $file = Join-Path $workspace 'result.txt'
    $content = 'written-' + [guid]::NewGuid().ToString('N')
    Wa @('chat', ('FIXTURE_WRITE|' + $file + '|' + $content)) | Out-Null
    Check ((Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -eq $content) 'mock model caused a real native write with exact requested bytes'
    Check ((Wa @('sessions')) -match 'answered') 'tool-backed run settled in the persisted transcript'
    & $command doctor
    Check ($LASTEXITCODE -eq 0) 'packaged doctor runs without changing package inventory'
    Test-WaReleasePackage $installed | Out-Null
    # Reserve/check a pair, then let the packaged launcher bind it. Its PID check
    # still catches a process that wins the small release/bind race.
    $one = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $one.Start(); $port = $one.LocalEndpoint.Port
    $two = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, ($port + 1))
    try { $two.Start() } finally { $one.Stop(); $two.Stop() }
    & $command ui -NoOpen -Port $port
    Check ($LASTEXITCODE -eq 0) 'packaged UI launcher starts and verifies its own server without opening a window'
    $owner = @(Get-NetTCPConnection -LocalPort $port -State Listen)[0].OwningProcess
    $server = Get-Process -Id $owner
    Check ($server.Path -eq (Join-Path $installed 'wa.exe')) 'scratch listener belongs to installed candidate'
    $page = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/" -TimeoutSec 5
    Check ($page.StatusCode -eq 200 -and $page.Content.Contains('app.js')) 'packaged UI assets served from installation with spaces'
    & $command ui -NoOpen -Port $port
    Check ($LASTEXITCODE -eq 0 -and @(Get-NetTCPConnection -LocalPort $port -State Listen)[0].OwningProcess -eq $owner) 'second launch reuses only its recorded server'
    Test-WaReleasePackage $installed | Out-Null
    $checks++; Write-Output 'PASS running server writes no mutable files into package'
    Stop-Process -Id $server.Id -ErrorAction Stop
    $server.WaitForExit(); $server = $null
    $values = Read-WaConfiguration $config
    $values['WASM_AGENT_LLM_API_KEY'] = 'wrong-fixture-key'
    $failure = ''
    try { Test-WaProvider $values | Out-Null } catch { $failure = $_.Exception.Message }
    Check ($failure -like 'provider_validation_failed:*' -and $failure -notmatch 'wrong-fixture-key|must never appear') 'bad credentials fail without echoing provider body or secret'
    & $command setup -NonInteractive -Mode guest -Name 'Guest' -Workspace $workspace
    Check ($LASTEXITCODE -eq 0 -and (Read-WaConfiguration $config).WASM_AGENT_RENDEZVOUS -eq '') 'guest setup remains disconnected'
  } finally { Pop-Location }
  Write-Output "packaged runtime: $checks passed (synthetic provider)."
  Write-Output 'NOT TESTED: unfamiliar clean Windows VM, real model quality, customer enrollment, or public release safety.'
} finally {
  if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
  if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -ErrorAction SilentlyContinue }
  foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'WASM_AGENT_*' -or $_.Name -like 'WA_*' })) {
    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
  }
  foreach ($key in $environment.Keys) { [Environment]::SetEnvironmentVariable($key, $environment[$key], 'Process') }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
