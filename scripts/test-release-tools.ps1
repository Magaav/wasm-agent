# Hermetic mutation tests. Synthetic files prove the verifier, not a working agent.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/release-package.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('wa-release-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$checks = 0

function New-Fixture([string]$Name) {
  $folder = Join-Path $work $Name
  New-Item -ItemType Directory -Path $folder | Out-Null
  $records = @(foreach ($asset in Get-WaReleaseFiles) {
    $path = Join-Path $folder $asset
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, "synthetic fixture: $asset`n", $utf8)
    [ordered]@{
      path = $asset; bytes = (Get-Item -LiteralPath $path).Length
      sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  })
  $manifest = [ordered]@{
    schema = 1; version = '0.1.0-test.1'; status = 'candidate-unverified'
    source_commit = ('a' * 40); target = 'x86_64-pc-windows-msvc'; files = $records
  }
  [IO.File]::WriteAllText((Join-Path $folder 'manifest.json'),
    ($manifest | ConvertTo-Json -Depth 5), $utf8)
  return $folder
}

function Change-Manifest([string]$Folder, [scriptblock]$Change) {
  $path = Join-Path $Folder 'manifest.json'
  $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  & $Change $manifest
  [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 5), $utf8)
}

function Reject([string]$Name, [scriptblock]$Mutate, [string]$Expected) {
  $folder = New-Fixture $Name
  & $Mutate $folder
  $caught = $null
  try { Test-WaReleasePackage $folder | Out-Null }
  catch { $caught = $_.Exception.Message }
  if (-not $caught -or $caught -notlike "*$Expected*") {
    throw "negative_control_failed: $Name expected $Expected; got $caught"
  }
  $script:checks++
  Write-Output "PASS refuses $Name"
}

try {
  $good = New-Fixture 'valid package with spaces'
  $result = Test-WaReleasePackage $good
  if ($result.files -ne 12 -or $result.status -cne 'integrity-only') { throw 'positive_control_failed' }
  $checks++
  Write-Output 'PASS complete synthetic candidate (integrity only)'

  Reject 'changed-bytes-same-size' {
    param($p)
    $path = Join-Path $p 'wa.exe'
    $bytes = [IO.File]::ReadAllBytes($path); $bytes[0] = 88
    [IO.File]::WriteAllBytes($path, $bytes)
  } 'asset_hash_mismatch'
  Reject 'truncated-file' {
    param($p); [IO.File]::WriteAllText((Join-Path $p 'ui/app.js'), 'x', $utf8)
  } 'asset_size_mismatch'
  Reject 'missing-asset' { param($p); Remove-Item -LiteralPath (Join-Path $p 'WebView2Loader.dll') } 'does not exist'
  Reject 'unexpected-config' {
    param($p); [IO.File]::WriteAllText((Join-Path $p 'env'), 'not-a-real-secret', $utf8)
  } 'unexpected_asset'
  Reject 'maintainer-instructions' {
    param($p); [IO.File]::WriteAllText((Join-Path $p 'AGENTS.md'), 'developer-only', $utf8)
  } 'unexpected_asset'
  Reject 'missing-manifest-entry' {
    param($p); Change-Manifest $p { param($m); $m.files = @($m.files | Select-Object -Skip 1) }
  } 'manifest_file_count'
  Reject 'duplicate-manifest-entry' {
    param($p); Change-Manifest $p { param($m); $m.files[1] = $m.files[0] }
  } 'invalid_or_duplicate_asset'
  Reject 'path-traversal' {
    param($p); Change-Manifest $p { param($m); $m.files[0].path = '../wa.exe' }
  } 'invalid_or_duplicate_asset'
  Reject 'absolute-path' {
    param($p); Change-Manifest $p { param($m); $m.files[0].path = 'C:/wa.exe' }
  } 'invalid_or_duplicate_asset'
  Reject 'malformed-hash' {
    param($p); Change-Manifest $p { param($m); $m.files[0].sha256 = 'unknown' }
  } 'invalid_asset_record'
  Reject 'unproven-release-status' {
    param($p); Change-Manifest $p { param($m); $m.status = 'release-ready' }
  } 'unsupported_manifest'
  Reject 'unknown-schema' {
    param($p); Change-Manifest $p { param($m); $m.schema = 2 }
  } 'unsupported_manifest'
  Reject 'unknown-source' {
    param($p); Change-Manifest $p { param($m); $m.source_commit = 'unknown' }
  } 'invalid_candidate_identity'
  Reject 'wrong-target' {
    param($p); Change-Manifest $p { param($m); $m.target = 'aarch64-unknown-linux-gnu' }
  } 'invalid_candidate_identity'
  Reject 'stable-release-label' {
    param($p); Change-Manifest $p { param($m); $m.version = '1.0.0' }
  } 'invalid_candidate_identity'

  # Archive extraction must preserve the same bytes/inventory. No bundled code runs.
  $zip = Join-Path $work 'candidate.zip'
  Compress-Archive -Path (Join-Path $good '*') -DestinationPath $zip
  $extracted = Join-Path $work 'extracted'
  Expand-Archive -LiteralPath $zip -DestinationPath $extracted
  Test-WaReleasePackage $extracted | Out-Null
  $checks++
  Write-Output 'PASS synthetic archive round trip'
  Write-Output "release tools: $checks passed; runtime and user journeys NOT TESTED"
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force
}
