# Shared candidate inventory and integrity checks. No packaged code is executed.
Set-StrictMode -Version Latest

function Get-WaReleaseFiles {
  @(
    'wa.exe', 'wa-window.exe', 'wa-sentinel.exe', 'WebView2Loader.dll',
    'ui/index.html', 'ui/style.css', 'ui/app.js', 'ui/components.js', 'ui/render.wasm',
    'scripts/upgrade.sh', 'LICENSE', 'README.md', 'AGENTS.runtime.md',
    'bin/wa.cmd', 'scripts/first-run.ps1', 'scripts/lib/first-run.ps1',
    'scripts/lib/release-package.ps1', 'scripts/lib/managed-guest.ps1', 'install.ps1'
  )
}

function Get-WaPackageFiles([string]$Directory) {
  foreach ($entry in Get-ChildItem -LiteralPath $Directory -Force) {
    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "package_reparse_point: $($entry.Name)"
    }
    if ($entry.PSIsContainer) { Get-WaPackageFiles $entry.FullName }
    else { $entry }
  }
}

function Test-WaReleasePackage([string]$PackagePath) {
  $root = (Get-Item -LiteralPath $PackagePath -ErrorAction Stop)
  if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'package_directory_required'
  }
  # Inventory before reading: refuse junctions/symlinks rather than traversing them.
  $actual = @(Get-WaPackageFiles $root.FullName)
  $manifestPath = Join-Path $root.FullName 'manifest.json'
  $manifestFile = Get-Item -LiteralPath $manifestPath -ErrorAction Stop
  if ($manifestFile.Length -gt 1MB) { throw 'manifest_too_large' }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($manifest.schema -ne 1 -or $manifest.status -cne 'candidate-unverified') {
    throw 'unsupported_manifest'
  }
  if ($manifest.version -cnotmatch '^\d+\.\d+\.\d+-[a-z0-9][a-z0-9.-]*$' -or
      $manifest.source_commit -cnotmatch '^[0-9a-f]{40}$' -or
      $manifest.target -cne 'x86_64-pc-windows-msvc') {
    throw 'invalid_candidate_identity'
  }
  $expected = @(Get-WaReleaseFiles)
  if (@($manifest.files).Count -ne $expected.Count) { throw 'manifest_file_count' }
  $seen = @{}
  foreach ($record in $manifest.files) {
    $name = [string]$record.path
    if ($expected -cnotcontains $name -or $seen.ContainsKey($name)) {
      throw "invalid_or_duplicate_asset: $name"
    }
    $seen[$name] = $true
    if ($record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $record.bytes -le 0) {
      throw "invalid_asset_record: $name"
    }
    $file = Get-Item -LiteralPath (Join-Path $root.FullName $name) -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -ne $record.bytes) {
      throw "asset_size_mismatch: $name"
    }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $record.sha256) { throw "asset_hash_mismatch: $name" }
  }
  $prefix = $root.FullName.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  foreach ($file in $actual) {
    $relative = $file.FullName.Substring($prefix.Length).Replace('\', '/')
    if ($relative -cne 'manifest.json' -and $expected -cnotcontains $relative) {
      throw "unexpected_asset: $relative"
    }
  }
  if ($actual.Count -ne ($expected.Count + 1)) { throw 'package_file_count' }
  [pscustomobject]@{
    status = 'integrity-only'; version = $manifest.version
    source_commit = $manifest.source_commit; files = $expected.Count
  }
}
