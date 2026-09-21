# Build a candidate archive only. Never install, enroll, publish or touch live processes.
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+-[a-z0-9][a-z0-9.-]*$')][string]$Version,
  [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/release-package.ps1')
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$target = 'x86_64-pc-windows-msvc'
$stage = $null
$build = $null
$published = $false

function Git-Value([string[]]$Arguments) {
  $text = & git -C $root @Arguments
  if ($LASTEXITCODE -ne 0) { throw 'git_failed' }
  return ($text -join "`n").Trim()
}
function Assert-Clean {
  if (Git-Value @('status', '--porcelain', '--untracked-files=normal')) {
    throw 'dirty_source: commit the candidate source before packaging'
  }
}
function Copy-Asset([string]$Source, [string]$Relative) {
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "missing_build_asset: $Relative" }
  $destination = Join-Path $stage $Relative
  New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $destination
}

try {
  if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'requires_64_bit_windows_powershell'
  }
  Assert-Clean
  $commit = Git-Value @('rev-parse', 'HEAD')
  $output = [IO.Path]::GetFullPath($OutputDirectory)
  $name = "wasm-agent-$Version-windows-x64"
  $destination = Join-Path $output $name
  $archive = "$destination.zip"
  foreach ($path in @($destination, $archive, "$archive.sha256")) {
    if (Test-Path -LiteralPath $path) { throw "output_exists: $path" }
  }
  # No existing/stale binaries as inputs. Separate build directories also prevent
  # artifact-name collisions between the three independent Cargo workspaces.
  New-Item -ItemType Directory -Force -Path $output | Out-Null
  $nonce = [guid]::NewGuid().ToString('N')
  $stage = Join-Path $output ".stage-$nonce"
  $build = Join-Path $output ".build-$nonce"
  New-Item -ItemType Directory -Path $stage | Out-Null
  $cargo = (& cargo --version)
  if ($LASTEXITCODE -ne 0) { throw 'cargo_unavailable' }
  $crates = @(
    @{ name = 'host'; manifest = 'rust/Cargo.toml'; binary = 'wa.exe' },
    @{ name = 'sentinel'; manifest = 'rust/wa-sentinel/Cargo.toml'; binary = 'wa-sentinel.exe' },
    @{ name = 'window'; manifest = 'rust/wa-window/Cargo.toml'; binary = 'wa-window.exe' }
  )
  foreach ($crate in $crates) {
    $targetDir = Join-Path $build $crate.name
    & cargo build --release --locked --offline --target $target --target-dir $targetDir `
      --manifest-path (Join-Path $root $crate.manifest)
    if ($LASTEXITCODE -ne 0) { throw "build_failed: $($crate.name)" }
    Copy-Asset (Join-Path $targetDir "$target/release/$($crate.binary)") $crate.binary
  }
  $loaders = @(Get-ChildItem -LiteralPath (Join-Path $build "window/$target/release/build") `
    -Filter WebView2Loader.dll -Recurse | Where-Object {
      $_.FullName -match '[\\/]out[\\/]x64[\\/]WebView2Loader\.dll$'
    })
  if ($loaders.Count -ne 1) { throw 'expected_one_x64_webview_loader' }
  Copy-Asset $loaders[0].FullName 'WebView2Loader.dll'
  foreach ($asset in @('ui/index.html', 'ui/style.css', 'ui/app.js', 'ui/components.js',
                       'ui/render.wasm', 'scripts/upgrade.sh', 'LICENSE')) {
    Copy-Asset (Join-Path $root $asset) $asset
  }
  Copy-Asset (Join-Path $root 'docs/release/RUNTIME.md') 'README.md'
  foreach ($asset in @('first-run.ps1', 'install.ps1', 'wa.cmd', 'AGENTS.runtime.md')) {
    $relative = switch ($asset) {
      'first-run.ps1' { 'scripts/first-run.ps1' }
      'wa.cmd' { 'bin/wa.cmd' }
      default { $asset }
    }
    Copy-Asset (Join-Path $root "scripts/release/$asset") $relative
  }
  foreach ($asset in @('first-run.ps1', 'release-package.ps1', 'managed-guest.ps1')) {
    Copy-Asset (Join-Path $root "scripts/lib/$asset") "scripts/lib/$asset"
  }
  Assert-Clean
  if ((Git-Value @('rev-parse', 'HEAD')) -cne $commit) { throw 'source_changed_during_build' }
  $records = @(foreach ($asset in Get-WaReleaseFiles) {
    $file = Get-Item -LiteralPath (Join-Path $stage $asset)
    [ordered]@{
      path = $asset; bytes = $file.Length
      sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  })
  $manifest = [ordered]@{
    schema = 1; version = $Version; status = 'candidate-unverified'
    source_commit = $commit; target = $target; cargo = "$cargo"
    created_utc = [DateTime]::UtcNow.ToString('o'); files = $records
  }
  $utf8 = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'),
    (($manifest | ConvertTo-Json -Depth 5) + "`n"), $utf8)
  Test-WaReleasePackage $stage | Out-Null
  # Archive is assembled before the candidate directory becomes visible. Keep a
  # failed partial archive from masquerading as the output of a successful build.
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive
  $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText("$archive.sha256", "$hash  $name.zip`n", $utf8)
  Move-Item -LiteralPath $stage -Destination $destination
  $stage = $null
  $published = $true
  Write-Output "CANDIDATE ONLY: $archive"
  Write-Output "SHA256: $hash"
  Write-Output 'Integrity verified. Behavior, installation and customer release gates NOT VERIFIED.'
} catch {
  Write-Error ("package: " + $_.Exception.Message) -ErrorAction Continue
  exit 1
} finally {
  if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
  if ($build -and (Test-Path -LiteralPath $build)) { Remove-Item -LiteralPath $build -Recurse -Force }
  # Only outputs this invocation created may be removed. Pre-existing output
  # refusals happen before stage creation and must preserve the existing package.
  if (-not $published -and $stage) {
    foreach ($path in @($archive, "$archive.sha256")) {
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
  }
}
