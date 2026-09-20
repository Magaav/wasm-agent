# Hermetic configuration tests. No provider calls, live user state or installations.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/first-run.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('wa-first-run-' + [guid]::NewGuid())
$config = Join-Path $work '.wasm-agent'
$workspace = Join-Path $work 'workspace with spaces'
$oldEnvironment = @{}
$checks = 0
function Check([bool]$Value, [string]$Label) {
  if (-not $Value) { throw "FAIL: $Label" }
  $script:checks++; Write-Output "PASS $Label"
}
function Refuse([scriptblock]$Action, [string]$Reason) {
  $message = ''
  try { & $Action } catch { $message = $_.Exception.Message }
  Check ($message -like "*$Reason*") "refuses $Reason"
}
try {
  foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'WASM_AGENT_*' })) {
    $oldEnvironment[$entry.Name] = $entry.Value
    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
  }
  $env:WASM_AGENT_HOME = $work
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
  Check ((Get-WaConfigDirectory) -eq $config) 'native isolated config directory'
  $secret = ConvertTo-SecureString 'fixture-key-not-a-credential' -AsPlainText -Force
  Save-WaSetup -Config $config -Mode personal -Name 'My Agent' -Workspace $workspace `
    -BaseUrl 'https://provider.invalid/v1' -Model 'fixture' -ApiKey $secret
  $secret.Dispose()
  $values = Read-WaConfiguration $config
  Check ($values.WASM_AGENT_DISPLAY_NAME -eq 'My Agent') 'friendly name saved separately from node/branch'
  Check ($values.WASM_AGENT_LLM_API_KEY -eq 'fixture-key-not-a-credential') 'credential saved through masked-input path'
  Check ($values.WASM_AGENT_RENDEZVOUS -eq '' -and $values.WASM_AGENT_SYNC_TO -eq '') 'no implicit enrollment or sync'
  $acl = Get-Acl -LiteralPath (Join-Path $config 'env')
  Check $acl.AreAccessRulesProtected 'credential file disables inherited permissions'
  Check (@($acl.Access).Count -eq 1) 'only current user explicitly granted access to credential file'
  Check (-not (Test-Path -LiteralPath (Join-Path $config 'node.name'))) 'setup never renames a node'
  foreach ($file in @('node.key', 'memory.db', 'node.name', 'AGENTS.md')) {
    [IO.File]::WriteAllText((Join-Path $config $file), "preserve-$file")
  }
  Add-Content -LiteralPath (Join-Path $config 'env') -Value '# keep this comment'
  Add-Content -LiteralPath (Join-Path $config 'env') -Value 'CUSTOM_SETTING=keep-me'
  Save-WaSetup -Config $config -Mode personal -Name 'Renamed Display' -Workspace $workspace `
    -BaseUrl 'https://provider.invalid/v1' -Model 'fixture'
  $again = Read-WaConfiguration $config
  Check ($again.WASM_AGENT_LLM_API_KEY -eq 'fixture-key-not-a-credential') 'rerun preserves existing key'
  Check ($again.CUSTOM_SETTING -eq 'keep-me') 'rerun preserves unrelated configuration'
  Check ([IO.File]::ReadAllText((Join-Path $config 'env')).Contains('# keep this comment')) 'rerun preserves comments'
  foreach ($file in @('node.key', 'memory.db', 'node.name', 'AGENTS.md')) {
    Check ([IO.File]::ReadAllText((Join-Path $config $file)) -eq "preserve-$file") "rerun preserves $file bytes"
  }
  $before = (Get-FileHash -LiteralPath (Join-Path $config 'env')).Hash
  Refuse { Save-WaSetup -Config $config -Mode personal -Name "bad`nname" -Workspace $workspace -BaseUrl 'https://provider.invalid/v1' -Model fixture } 'invalid_name'
  Refuse { Assert-WaProviderUrl 'http://provider.invalid/v1' } 'provider_url_requires'
  Refuse { Assert-WaProviderUrl 'https://user:password@provider.invalid/v1' } 'provider_url_requires'
  Refuse { Assert-WaProviderUrl 'https://provider.invalid/v1?key=secret' } 'provider_url_requires'
  Refuse { Save-WaSetup -Config $config -Mode personal -Name 'Test' -Workspace (Join-Path $work 'missing') -BaseUrl 'https://provider.invalid/v1' -Model fixture } 'existing_native_workspace_required'
  Check ((Get-FileHash -LiteralPath (Join-Path $config 'env')).Hash -eq $before) 'refused setup does not change config'
  $env:WASM_AGENT_LLM_MODEL = 'other-model'
  Refuse { Save-WaSetup -Config $config -Mode personal -Name 'Test' -Workspace $workspace -BaseUrl 'https://provider.invalid/v1' -Model fixture } 'process_environment_overrides_config'
  Remove-Item Env:WASM_AGENT_LLM_MODEL
  Save-WaSetup -Config $config -Mode guest -Name 'Guest' -Workspace $workspace
  $guest = Read-WaConfiguration $config
  Check ($guest.WASM_AGENT_NODE_ROLE -eq 'guest' -and $guest.WASM_AGENT_RENDEZVOUS -eq '') 'guest staged offline, never implicitly authorized'
  Refuse { Start-WaLocalUi -Install $work -Config $config -Port 18990 -Browser } 'personal_setup_required'
  Check (-not (Test-Path -LiteralPath (Join-Path $config 'launchers'))) 'refused guest launch starts no server'
  Check (@(Get-ChildItem -LiteralPath $config -Filter '.setup-*' -Force).Count -eq 0) 'no temporary credential files remain'
  Write-Output "first run: $checks passed; no live provider or customer used"
} finally {
  foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'WASM_AGENT_*' })) {
    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
  }
  foreach ($key in $oldEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $oldEnvironment[$key], 'Process') }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
