# Open the wasm-agent desktop window.
#
# Ensures `wa serve` is running on the host, opens an SSH tunnel, and launches
# the native WebView2 companion: frameless, translucent, always-on-top, and
# collapsed to a round avatar that expands into the chat panel on click. Falls
# back to an Edge --app window when the native shell is unavailable. Invoked by
# `wa ui`.
param(
  [string]$HostAlias = $(if ($env:WASM_AGENT_HOST) { $env:WASM_AGENT_HOST } else { "openclaw.ohana" }),
  [int]$Port = 8799,
  [string]$RemoteUi = "/local/projects/wasm-agent/ui",
  [string]$RemoteBin = "/local/projects/wasm-agent/target/windows-x64/x86_64-pc-windows-gnu/release"
)
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "   wasm-agent ui" -ForegroundColor Cyan
Write-Host ""

# Health-check the port (a pgrep here would match this very command).
$health = (& ssh -o BatchMode=yes $HostAlias "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$Port/health" 2>$null) | Select-Object -First 1
if ($health -ne "200") {
  Write-Host "   * starting the server on $HostAlias" -ForegroundColor DarkGray
  & ssh -o BatchMode=yes $HostAlias "setsid nohup wasm-agent serve --port $Port --ui $RemoteUi >/tmp/wa-ui.log 2>&1 </dev/null & sleep 1; echo started" | Out-Null
  Start-Sleep -Seconds 2
} else {
  Write-Host "   * server already running" -ForegroundColor DarkGray
}

# Open the tunnel. Reuse an existing one if the port is already forwarded.
$listening = (netstat -ano | Select-String "127.0.0.1:$Port\s+0.0.0.0:0\s+LISTENING") -ne $null
if (-not $listening) {
  Start-Process ssh -ArgumentList @("-N", "-o", "BatchMode=yes", "-L", "${Port}:127.0.0.1:${Port}", $HostAlias) -WindowStyle Hidden
  Start-Sleep -Seconds 1
}

$url = "http://127.0.0.1:$Port/"
$dir = Join-Path $env:LOCALAPPDATA "wasm-agent"
$localExe = Join-Path $dir "wa-window.exe"
$localDll = Join-Path $dir "WebView2Loader.dll"

# Fetch the native companion (rebuilding it is `scripts/build-window.sh`).
try {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Write-Host "   * fetching the window" -ForegroundColor DarkGray
  & scp -q -o BatchMode=yes "${HostAlias}:${RemoteBin}/wa-window.exe" $localExe
  & scp -q -o BatchMode=yes "${HostAlias}:${RemoteBin}/WebView2Loader.dll" $localDll
} catch {
  Remove-Item $localExe, $localDll -ErrorAction SilentlyContinue
}

if ((Test-Path $localExe) -and (Test-Path $localDll)) {
  $env:WASM_AGENT_UI_URL = $url
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
