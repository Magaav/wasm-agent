# Windows first-run shell. Native CLI, configuration and UI remain the runtime.
# This script never enables remote enrollment or replaces a running installation.
param(
  [Parameter(Position = 0)][ValidateSet('setup', 'doctor', 'ui')][string]$Command = 'doctor',
  [ValidateSet('personal', 'guest')][string]$Mode,
  [string]$Name,
  [string]$Workspace,
  [string]$BaseUrl,
  [string]$Model,
  [switch]$NonInteractive,
  [switch]$ValidateProvider,
  [switch]$Browser,
  [ValidateRange(1024, 65534)][int]$Port = 8799
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$install = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lib/first-run.ps1')

try {
  $config = Get-WaConfigDirectory
  switch ($Command) {
    'setup' {
      $current = Read-WaConfiguration $config
      if (-not $Mode) {
        if ($NonInteractive) { throw 'mode_required: personal or guest' }
        $Mode = Read-Host 'Choose personal (your model) or guest (await assisted enrollment)'
        if ($Mode -notin @('personal', 'guest')) { throw 'invalid_mode' }
      }
      if (-not $Name) {
        if ($NonInteractive) { throw 'name_required' }
        $Name = Read-Host 'Your agent display name (does not rename a Git branch)'
      }
      if (-not $Workspace) {
        if ($NonInteractive) { throw 'workspace_required' }
        $Workspace = Read-Host 'Full path to an existing workspace'
      }
      if ($Mode -eq 'personal') {
        if (-not $BaseUrl) {
          $BaseUrl = $current['WASM_AGENT_LLM_BASE_URL']
          if (-not $BaseUrl -and -not $NonInteractive) { $BaseUrl = Read-Host 'Compatible provider URL (for example https://provider.example/v1)' }
        }
        if (-not $Model) {
          $Model = $current['WASM_AGENT_LLM_MODEL']
          if (-not $Model -and -not $NonInteractive) { $Model = Read-Host 'Model name' }
        }
      }
      # A key is never accepted as an argument. Interactive input is masked;
      # automation may reuse a key already in the isolated config, not echo it.
      $secret = $null
      if ($Mode -eq 'personal' -and -not $NonInteractive) {
        Write-Output 'API key: leave empty to preserve an existing key. It is stored in a private local file.'
        $secret = Read-Host 'API key' -AsSecureString
      }
      try {
        Save-WaSetup -Config $config -Mode $Mode -Name $Name -Workspace $Workspace `
          -BaseUrl $BaseUrl -Model $Model -ApiKey $secret
        $instructionFile = Join-Path $config $(if ($Mode -eq 'guest') { 'AGENTS.guest.md' } else { 'AGENTS.md' })
        if (-not (Test-Path -LiteralPath $instructionFile)) {
          Write-WaPrivateText $instructionFile ([IO.File]::ReadAllText((Join-Path $install 'AGENTS.runtime.md')))
        }
      } finally { if ($secret) { $secret.Dispose() } }
      Write-Output "Configuration saved for $Name. Existing identity, memory and sessions were preserved."
      if ($Mode -eq 'guest') {
        Write-Output 'GUEST DISCONNECTED: no operator is authorized and no network enrollment occurred.'
        Write-Output 'Customer invitations and grants are not enabled in this preview. Do not connect through the legacy installer.'
      } elseif ($ValidateProvider) {
        Test-WaProvider (Read-WaConfiguration $config)
      } else {
        Write-Output 'Provider NOT VALIDATED. Run wa doctor -ValidateProvider to make one small model request.'
      }
      Write-Output 'Native tools have this Windows user account authority; the workspace is not a sandbox.'
      Write-Output 'A running node keeps its startup configuration; do not restart it mid-task.'
    }
    'doctor' {
      . (Join-Path $PSScriptRoot 'lib/release-package.ps1')
      $check = Test-WaReleasePackage $install
      Write-Output "Package integrity: OK ($($check.version), source $($check.source_commit))"
      $current = Read-WaConfiguration $config
      Write-Output ('Configuration: ' + $(if (Test-Path -LiteralPath (Join-Path $config 'env')) { 'present' } else { 'missing; run wa setup' }))
      Write-Output "Data directory: $config"
      Write-Output ('Memory database: ' + $(if (Test-Path -LiteralPath (Join-Path $config 'memory.db')) { 'present (not opened or modified)' } else { 'not created yet' }))
      $mode = $current['WASM_AGENT_ONBOARDING_MODE']
      if ($current['WASM_AGENT_DISPLAY_NAME']) { Write-Output ('Agent display name: ' + $current['WASM_AGENT_DISPLAY_NAME']) }
      Write-Output ('Mode: ' + $(if ($mode) { $mode } else { 'not configured' }))
      if ($mode -eq 'guest') { Write-Output 'Operator access: DISCONNECTED; enrollment not enabled in this preview' }
      Write-Output ('WebView2 Runtime: ' + $(if (Test-WaWebView) { 'detected' } else { 'not detected; use wa ui -Browser or install Microsoft WebView2 Runtime' }))
      Write-Output 'Native tool isolation: user-account authority, not a workspace sandbox'
      if ($ValidateProvider) {
        if ($mode -ne 'personal') { throw 'provider_validation_requires_personal_setup' }
        Test-WaProvider $current
      } else { Write-Output 'Provider: NOT VALIDATED (read-only diagnostics; use -ValidateProvider for a model request)' }
      if (-not $mode) { exit 2 }
    }
    'ui' {
      . (Join-Path $PSScriptRoot 'lib/release-package.ps1')
      Test-WaReleasePackage $install | Out-Null
      Start-WaLocalUi -Install $install -Config $config -Port $Port -Browser:$Browser
    }
  }
} catch {
  # Never echo provider response bodies or configuration values containing keys.
  Write-Error $_.Exception.Message -ErrorAction Continue
  exit 1
}
