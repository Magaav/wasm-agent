# wasm-agent installer for Windows.
#
#   powershell -c "irm https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.ps1 | iex"
#
# Installs a `wa` command that talks to a wasm-agent host over SSH (no Python
# needed on Windows). Like pi, it installs into a directory that is already on
# PATH, so `wa` works immediately in the current and new terminals.
# Use -Local to pip-install the package on this machine instead.
param(
  [string]$HostAlias = "openclaw.ohana",
  [switch]$Local,
  [string]$Source = "git+https://github.com/Magaav/wasm-agent.git",
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "wasm-agent")
)
$ErrorActionPreference = "Stop"

function Add-UserPath([string]$Dir) {
  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($current -notlike "*$Dir*") {
    [Environment]::SetEnvironmentVariable("Path", ($current.TrimEnd(';') + ";" + $Dir), "User")
  }
}

function Test-WritableDir([string]$Dir) {
  try {
    $probe = Join-Path $Dir (".wa-write-{0}.tmp" -f $PID)
    Set-Content -Path $probe -Value "" -ErrorAction Stop
    Remove-Item -Path $probe -Force -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

if ($Local) {
  if (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 -m pip install --user --upgrade $Source
  } elseif (Get-Command python -ErrorAction SilentlyContinue) {
    & python -m pip install --user --upgrade $Source
  } else {
    throw "Python 3.10+ is required for -Local. Install it from python.org, or run this installer without -Local."
  }
  Write-Host "wasm-agent installed locally. Run: wa"
  return
}

# Prefer a directory already on PATH (pi does this via the npm bin): `wa`
# becomes available without touching PATH or reopening the terminal.
$appData = [Environment]::GetFolderPath("ApplicationData")
$localAppData = [Environment]::GetFolderPath("LocalApplicationData")
$pathDirs = ($env:Path -split ';') | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
$candidates = @((Join-Path $appData "npm"), (Join-Path $localAppData "Microsoft\WindowsApps"))
$target = $null
$managed = $false
foreach ($dir in $candidates) {
  if (($pathDirs -contains $dir.TrimEnd('\')) -and (Test-Path $dir) -and (Test-WritableDir $dir)) {
    $target = $dir
    break
  }
}
if (-not $target) {
  $target = $InstallDir
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Add-UserPath $target
  $managed = $true
}

$shim = Join-Path $target "wa.cmd"
$body = "@echo off`r`nssh -t $HostAlias wasm-agent %*`r`n"
Set-Content -Path $shim -Value $body -Encoding ASCII
if (($env:Path -split ';') -notcontains $target) { $env:Path = "$target;$env:Path" }

# Remove a shim from the fallback directory if we installed somewhere on PATH.
if (-not $managed) {
  $stale = Join-Path $InstallDir "wa.cmd"
  if (Test-Path $stale) { Remove-Item $stale -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "wasm-agent installed."
Write-Host "  wa   ->  ssh -t $HostAlias wasm-agent   ($shim)"
Write-Host ""
if (Get-Command wa -ErrorAction SilentlyContinue) {
  Write-Host "Run:  wa"
} else {
  Write-Host "Open a NEW terminal, then run:  wa"
  Write-Host "(or, in this terminal:  `$env:Path += `";$target`")"
}
Write-Host ""
Write-Host "If SSH is not set up yet, add this to ~/.ssh/config:"
Write-Host "  Host $HostAlias"
Write-Host "      HostName <server-ip>"
Write-Host "      User ubuntu"
Write-Host "      IdentityFile <path-to-key>"
