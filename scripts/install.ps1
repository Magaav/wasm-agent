# wasm-agent installer for Windows.
#
#   powershell -c "irm https://raw.githubusercontent.com/<owner>/wasm-agent/main/scripts/install.ps1 | iex"
#
# Default: installs a `wa` command that talks to a wasm-agent host over SSH
# (no Python needed on Windows). Use -Local to pip-install the package on this
# machine instead.
param(
  [string]$HostAlias = "openclaw.ohana",
  [switch]$Local,
  [string]$Source = "git+https://github.com/Magaav/wasm-agent.git",
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "wasm-agent")
)
$ErrorActionPreference = "Stop"

function Add-UserPath([string]$Dir) {
  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($current -notlike "*$Dir*") {
    [Environment]::SetEnvironmentVariable("Path", ($current.TrimEnd(';') + ";" + $Dir), "User")
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

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$shim = Join-Path $InstallDir "wa.cmd"
$body = "@echo off`r`nssh -t $HostAlias wasm-agent %*`r`n"
Set-Content -Path $shim -Value $body -Encoding ASCII
Add-UserPath $InstallDir

Write-Host ""
Write-Host "wasm-agent installed."
Write-Host "  wa          -> ssh -t $HostAlias wasm-agent"
Write-Host ""
Write-Host "Open a NEW terminal, then run:  wa"
Write-Host "If you have not set up SSH yet, add this to ~/.ssh/config:"
Write-Host "  Host $HostAlias"
Write-Host "      HostName <server-ip>"
Write-Host "      User ubuntu"
Write-Host "      IdentityFile <path-to-key>"
