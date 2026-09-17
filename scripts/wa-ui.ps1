# Open the wasm-agent desktop window.
#
# Local-first: the window talks to the wasm-agent node running on *this* machine,
# over localhost. Remote nodes are an optional execution target, not a
# dependency of the UI - `wa ui --remote` uses the host over SSH instead.
#
# The window itself is the native WebView2 companion: frameless, translucent,
# always-on-top, collapsed to a round avatar that expands into the chat panel.
# Falls back to an Edge --app window when the native shell is unavailable.
param(
  [Parameter(Position = 0)][string]$Mode,
  [string]$HostAlias = $(if ($env:WASM_AGENT_HOST) { $env:WASM_AGENT_HOST } else { "openclaw.ohana" }),
  [int]$Port = 8799,
  [string]$RemoteUi = "/local/projects/wasm-agent/ui",
  [string]$RemoteBin = "/local/projects/wasm-agent/target/windows-x64/x86_64-pc-windows-gnu/release",
  [int]$ClientPort = 8800,
  [switch]$Remote
)
$ErrorActionPreference = "Stop"

# `wa ui --remote` from cmd reaches PowerShell as a positional string, so accept
# both spellings.
if ($Mode -and $Mode -match '^--?remote$') { $Remote = $true }

$dir = Join-Path $env:LOCALAPPDATA "wasm-agent"
$localWa = Join-Path $dir "wa.exe"
$uiDir = Join-Path $dir "ui"
$repoRaw = "https://raw.githubusercontent.com/Magaav/wasm-agent/main/ui"

Write-Host ""
Write-Host "   wasm-agent ui" -ForegroundColor Cyan
Write-Host ""

function Test-Health([int]$p) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:$p/health"
    return ($response.StatusCode -eq 200)
  } catch { return $false }
}

function Invoke-Ssh([string]$RemoteCommand) {
  # A remote node is optional: a failed ssh must never abort the launcher, and
  # under $ErrorActionPreference = "Stop" native stderr becomes terminating.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & ssh -o BatchMode=yes -o ConnectTimeout=8 $HostAlias $RemoteCommand 2>$null
    return ($output | Select-Object -First 1)
  } catch { return $null } finally { $ErrorActionPreference = $previous }
}

function Get-UiFiles {
  # The local server serves ui/ from disk (so it hot-reloads); fetch it once.
  $needed = @("index.html", "style.css", "app.js", "components.js", "render.wasm")
  $missing = $needed | Where-Object { -not (Test-Path (Join-Path $uiDir $_)) }
  if (-not $missing) { return $true }
  New-Item -ItemType Directory -Force -Path $uiDir | Out-Null
  foreach ($name in $missing) {
    try {
      Invoke-WebRequest -UseBasicParsing "$repoRaw/$name" -OutFile (Join-Path $uiDir $name) -ErrorAction Stop
    } catch {
      Write-Host "   !  could not fetch ui/$name" -ForegroundColor Yellow
      return $false
    }
  }
  return $true
}

$useLocal = (-not $Remote) -and (Test-Path $localWa)
if ($useLocal) {
  # --- local node: no SSH anywhere in this path -------------------------------
  if (-not (Get-UiFiles)) { Write-Host "   !  the local server needs its ui files" -ForegroundColor Yellow }

  if (Test-Health $Port) {
    Write-Host "   * local server already running" -ForegroundColor DarkGray
  } else {
    Write-Host "   * starting the local server" -ForegroundColor DarkGray
    Start-Process -FilePath $localWa `
      -ArgumentList @("serve", "--port", "$Port", "--ui", $uiDir, "--client-port", "$ClientPort") `
      -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $dir "serve.log") `
      -RedirectStandardError (Join-Path $dir "serve.err.log") | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
      Start-Sleep -Milliseconds 250
      if (Test-Health $Port) { break }
    }
  }
  if (-not (Test-Health $Port)) {
    Write-Host "   !  the local server did not come up; see $dir\serve.err.log" -ForegroundColor Yellow
  } else {
    Write-Host "   ok  local node -> http://127.0.0.1:$Port" -ForegroundColor Green
  }
  $url = "http://127.0.0.1:$Port/"
} else {
  # --- remote node (opt-in) ---------------------------------------------------
  $health = Invoke-Ssh "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$Port/health"
  if ($health -ne "200") {
    Write-Host "   * starting the server on $HostAlias" -ForegroundColor DarkGray
    # A failed ssh must not abort the launcher: the remote node is a target, not a
    # dependency. Under $ErrorActionPreference = "Stop" native stderr is fatal.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      & ssh -o BatchMode=yes -o ConnectTimeout=8 $HostAlias "setsid nohup wasm-agent serve --port $Port --ui $RemoteUi >/tmp/wa-ui.log 2>&1 </dev/null & sleep 1; echo started" 2>$null | Out-Null
    } catch { }
    $ErrorActionPreference = $previous
    Start-Sleep -Seconds 2
  } else {
    Write-Host "   * server already running on $HostAlias" -ForegroundColor DarkGray
  }
  $listening = (netstat -ano | Select-String "127.0.0.1:$Port\s+0.0.0.0:0\s+LISTENING") -ne $null
  if (-not $listening) {
    Start-Process ssh -ArgumentList @("-N", "-o", "BatchMode=yes", "-L", "${Port}:127.0.0.1:${Port}", "-L", "$ClientPort`:127.0.0.1:$ClientPort", $HostAlias) -WindowStyle Hidden
    Start-Sleep -Seconds 1
  }
  Write-Host "   ok  remote node -> http://127.0.0.1:$Port (tunnel to $HostAlias)" -ForegroundColor Green
  $url = "http://127.0.0.1:$Port/"
}

# --- the window ---------------------------------------------------------------
$localExe = Join-Path $dir "wa-window.exe"
$localDll = Join-Path $dir "WebView2Loader.dll"

# Only refresh the window from the host when it is missing or remote was asked
# for: a local UI should not need the network at all.
if ((-not (Test-Path $localExe) -or -not (Test-Path $localDll)) -and (Get-Command scp -ErrorAction SilentlyContinue)) {
  try {
    Write-Host "   * fetching the window" -ForegroundColor DarkGray
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & scp -q -o BatchMode=yes -o ConnectTimeout=8 "${HostAlias}:${RemoteBin}/wa-window.exe" $localExe 2>$null
    & scp -q -o BatchMode=yes -o ConnectTimeout=8 "${HostAlias}:${RemoteBin}/WebView2Loader.dll" $localDll 2>$null
    $ErrorActionPreference = $previous
  } catch {
    Write-Host "   !  could not fetch the window from $HostAlias" -ForegroundColor Yellow
  }
}

if ((Test-Path $localExe) -and (Test-Path $localDll)) {
  $env:WASM_AGENT_UI_URL = $url
  $env:WASM_AGENT_CLIENT_PORT = "$ClientPort"
  Start-Process $localExe
  Write-Host "   ok  native window -> $url" -ForegroundColor Green
  Write-Host "   (click the avatar to expand, drag to move, collapse with the top-right arrow)" -ForegroundColor DarkGray
  Write-Host ""
  return
}

Write-Host "   ! native window unavailable; opening a browser" -ForegroundColor Yellow
$edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($edge) {
  Start-Process $edge -ArgumentList @("--app=$url", "--window-size=980,780")
} else {
  Start-Process $url
}

Write-Host "   ok  $url" -ForegroundColor Green
Write-Host ""
