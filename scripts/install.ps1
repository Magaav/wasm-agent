# wasm-agent installer for Windows.
#
#   powershell -c "irm https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.ps1 | iex"
#
# Installs a `wa` command that talks to your wasm-agent host over SSH. `wa` is
# put in a directory already on PATH, so it works immediately.
param(
  [string]$HostAlias = $(if ($env:WASM_AGENT_HOST) { $env:WASM_AGENT_HOST } else { "openclaw.ohana" }),
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "wasm-agent")
)
$ErrorActionPreference = "Stop"

function Write-Logo {
  Write-Host ""
  Write-Host "   wasm-agent" -ForegroundColor Cyan
  Write-Host "   a portable agent with organized memory" -ForegroundColor DarkGray
  Write-Host ""
}
function Step([string]$Text) {
  Write-Host "   " -NoNewline
  Write-Host "* " -ForegroundColor Cyan -NoNewline
  Write-Host $Text
}
function Ok([string]$Text) {
  Write-Host "     " -NoNewline
  Write-Host "ok " -ForegroundColor Green -NoNewline
  Write-Host $Text -ForegroundColor DarkGray
}
function Warn([string]$Text) {
  Write-Host "     " -NoNewline
  Write-Host "!  " -ForegroundColor Yellow -NoNewline
  Write-Host $Text -ForegroundColor DarkGray
}

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
  } catch { return $false }
}

Write-Logo
Step "finding a directory on PATH"

# Prefer a directory already on PATH (the npm bin, like pi): `wa` works with no
# PATH change and no terminal restart.
$appData = [Environment]::GetFolderPath("ApplicationData")
$localAppData = [Environment]::GetFolderPath("LocalApplicationData")
$onPath = ($env:Path -split ';') | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
$target = $null
foreach ($dir in @((Join-Path $appData "npm"), (Join-Path $localAppData "Microsoft\WindowsApps"))) {
  if (($onPath -contains $dir.TrimEnd('\')) -and (Test-Path $dir) -and (Test-WritableDir $dir)) { $target = $dir; break }
}
if (-not $target) {
  $target = $InstallDir
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Add-UserPath $target
}
Ok $target

Step "installing the wa command"
$shim = Join-Path $target "wa.cmd"
Set-Content -Path $shim -Value "@echo off`r`nssh -t $HostAlias wasm-agent %*`r`n" -Encoding ASCII
if (($env:Path -split ';') -notcontains $target) { $env:Path = "$target;$env:Path" }
$stale = Join-Path $InstallDir "wa.cmd"
if ((Test-Path $stale) -and ($stale -ne $shim)) { Remove-Item $stale -Force -ErrorAction SilentlyContinue }
Ok "wa -> ssh -t $HostAlias wasm-agent"

Step "checking the connection to $HostAlias"
if (Get-Command ssh -ErrorAction SilentlyContinue) {
  try {
    $version = (& ssh -o BatchMode=yes -o ConnectTimeout=8 $HostAlias "wasm-agent --version" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $version) { Ok "connected: $version" }
    else { Warn "not reachable yet - check ~/.ssh/config, then run: wa" }
  } catch { Warn "not reachable yet - check ~/.ssh/config, then run: wa" }
} else {
  Warn "ssh not found; install OpenSSH, then run: wa"
}

Write-Host ""
Write-Host "   ready." -ForegroundColor Green
Write-Host ""
Write-Host "   start chatting:" -ForegroundColor DarkGray
Write-Host "     wa" -ForegroundColor White
Write-Host ""
Write-Host "   then try:" -ForegroundColor DarkGray
Write-Host "     remember that Laura prefers invoices on the 5th" -ForegroundColor DarkGray
Write-Host "     what do you know about Laura?" -ForegroundColor DarkGray
Write-Host "     /exit" -ForegroundColor DarkGray
Write-Host ""
if (-not (Get-Command wa -ErrorAction SilentlyContinue)) {
  Write-Host "   (if 'wa' is not found, open a NEW terminal)" -ForegroundColor Yellow
}
