# Verify extracted candidate bytes, not behavior or publisher authenticity.
param([Parameter(Mandatory = $true)][string]$PackagePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/release-package.ps1')
try {
  $result = Test-WaReleasePackage $PackagePath
  Write-Output ("PASS integrity-only: {0} files, version {1}, source {2}" -f
    $result.files, $result.version, $result.source_commit)
  Write-Output 'NOT VERIFIED: binary behavior, clean installation, authority, UI, model tasks, or guest onboarding.'
} catch {
  Write-Error ("FAIL package integrity: " + $_.Exception.Message) -ErrorAction Continue
  exit 1
}
