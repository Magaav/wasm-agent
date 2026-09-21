# Fresh, per-user installation from an extracted candidate. No downloads or live updates.
param([string]$InstallDir, [switch]$RegisterCommand)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'scripts/lib/release-package.ps1')
$stage = $null
try {
  $candidate = Test-WaReleasePackage $PSScriptRoot
  if (-not $InstallDir) { $InstallDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'wasm-agent-preview' }
  $destination = [IO.Path]::GetFullPath($InstallDir)
  if (Test-Path -LiteralPath $destination) {
    throw 'installation_exists: fresh installer never overwrites an install; use the external upgrade procedure'
  }
  $parent = Split-Path $destination -Parent
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $stage = Join-Path $parent ('.wa-install-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage | Out-Null
  foreach ($asset in (@(Get-WaReleaseFiles) + @('manifest.json'))) {
    $to = Join-Path $stage $asset
    New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $asset) -Destination $to
  }
  Test-WaReleasePackage $stage | Out-Null
  # A same-volume rename publishes only the completely verified directory.
  [IO.Directory]::Move($stage, $destination)
  $stage = $null
  Write-Output "Installed developer preview $($candidate.version) into $destination"
  if ($RegisterCommand) {
    $bin = Join-Path $destination 'bin'
    $previous = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($previous -split ';' | Where-Object { $_ -and $_ -ne $bin })
    [Environment]::SetEnvironmentVariable('Path', ((@($bin) + $entries) -join ';'), 'User')
    Write-Output 'User PATH updated. Open a new terminal; use the full path below if another wa command takes precedence.'
  }
  Write-Output "Next: & '$destination\bin\wa.cmd' setup"
  Write-Output 'No services were started, no existing user state was copied, and no operator was authorized.'
} catch {
  Write-Error $_.Exception.Message -ErrorAction Continue
  exit 1
} finally {
  if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
