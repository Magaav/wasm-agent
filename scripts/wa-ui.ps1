# Open the wasm-agent chat window.
#
# Ensures `wa serve` is running on the host, opens an SSH tunnel, and launches an
# app window (Edge --app, i.e. no browser chrome). Invoked by `wa ui`.
param(
  [string]$HostAlias = $(if ($env:WASM_AGENT_HOST) { $env:WASM_AGENT_HOST } else { "openclaw.ohana" }),
  [int]$Port = 8799,
  [string]$RemoteUi = "/local/projects/wasm-agent/ui"
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

$tunnel = Start-Process ssh -ArgumentList @("-N", "-o", "BatchMode=yes", "-L", "${Port}:127.0.0.1:${Port}", $HostAlias) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 1

$url = "http://127.0.0.1:$Port/"
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
Write-Host "   (close the window when done; the tunnel exits with this terminal)" -ForegroundColor DarkGray
Write-Host ""
