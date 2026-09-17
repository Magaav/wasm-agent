# wasm-agent installer for Windows.
#
#   powershell -c "irm https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.ps1 | iex"
#
# Installs a `wa` command that talks to your wasm-agent host over SSH. `wa` is
# put in a directory already on PATH, so it works immediately.
param(
  [string]$HostAlias = $(if ($env:WASM_AGENT_HOST) { $env:WASM_AGENT_HOST } else { "openclaw.ohana" }),
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "wasm-agent"),
  [string]$RemoteBin = "/local/projects/wasm-agent/target/windows-x64/x86_64-pc-windows-gnu/release"
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

Step "installing the local node"
# wa.exe is the whole agent: Rust host, embedded Lua, SQLite and the tool
# runtime. The host cross-builds it for Windows, so fetch that build rather than
# the remote shim: the node then runs here, with no SSH in the path.
$nodeDir = Join-Path $localAppData "wasm-agent"
New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
$localExe = Join-Path $nodeDir "wa.exe"
$haveExe = $false
if (Get-Command scp -ErrorAction SilentlyContinue) {
  try {
    & scp -q -o BatchMode=yes "${HostAlias}:$RemoteBin/wa.exe" $localExe 2>$null
    if ((Test-Path $localExe) -and ((Get-Item $localExe).Length -gt 5MB)) { $haveExe = $true }
  } catch { }
}
if ($haveExe) {
  Ok "wa.exe  -> $localExe"
} else {
  Warn "could not fetch wa.exe from $HostAlias; 'wa' will use the host over SSH"
}

Step "installing the wa command"
$shim = Join-Path $target "wa.cmd"
if ($haveExe) {
  $body = @"
@echo off
if /I "%~1"=="ui" (
  rem `start` detaches the launcher so `wa ui` returns to the prompt; the
  rem server and window would otherwise hold this console open.
  start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0wa-ui.ps1" %2 %3 %4 %5 %6 %7 %8 %9
  exit /b
)
"$localExe" %*
"@
  Set-Content -Path $shim -Value $body -Encoding ASCII
  Ok "wa     -> local node"
  # Keep the host path available for when the local binary is not what you want.
  $remoteShim = Join-Path $target "wa-remote.cmd"
  Set-Content -Path $remoteShim -Value "@echo off`nssh -t $HostAlias wasm-agent %*" -Encoding ASCII
  Ok "wa-remote -> $HostAlias over SSH"
} else {
  $body = @"
@echo off
if /I "%~1"=="ui" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wa-ui.ps1" %2 %3 %4 %5 %6 %7 %8 %9
  exit /b
)
ssh -t $HostAlias wasm-agent %*
"@
  Set-Content -Path $shim -Value $body -Encoding ASCII
  Ok "wa     -> ssh -t $HostAlias wasm-agent"
}
if (($env:Path -split ';') -notcontains $target) { $env:Path = "$target;$env:Path" }
$stale = Join-Path $InstallDir "wa.cmd"
if ((Test-Path $stale) -and ($stale -ne $shim)) { Remove-Item $stale -Force -ErrorAction SilentlyContinue }

Step "provisioning the local node"
# Everything the node needs to think and remember: model config, instructions
# and a memory database that is created on first use.
$waHome = Join-Path $env:USERPROFILE ".wasm-agent"
New-Item -ItemType Directory -Force -Path $waHome | Out-Null
$envFile = Join-Path $waHome "env"
if (Test-Path $envFile) {
  Ok "kept the existing model config"
} else {
  try {
    $lines = @(& ssh -o BatchMode=yes $HostAlias "cat ~/.wasm-agent/env")
    # Test the *content*, not $LASTEXITCODE: when ssh resolves to Git's MSYS
    # ssh.exe, PowerShell reads its exit code as -1 even on success, so an exit
    # code check silently skips provisioning.
    if (($lines -join "`n") -match 'WASM_AGENT_LLM') {
      # Rename this node: copying the host config would otherwise make two nodes
      # with the same name, which is confusing in the fabric view.
      $nodeName = $env:COMPUTERNAME.ToLower()
      $lines = @($lines | ForEach-Object {
        if ($_ -match '^WASM_AGENT_NODE_NAME=') { "WASM_AGENT_NODE_NAME=$nodeName" } else { $_ }
      })
      if (-not ($lines -match '^WASM_AGENT_NODE_NAME=')) { $lines += "WASM_AGENT_NODE_NAME=$nodeName" }
      Set-Content -Path $envFile -Value $lines -Encoding ASCII
      Ok "model config -> $envFile"
    } else {
      Warn "could not read the model config from $HostAlias"
    }
  } catch { Warn "could not read the model config from $HostAlias" }
}
foreach ($doc in @("AGENTS.md", "AGENTS.guest.md")) {
  $dest = Join-Path $waHome $doc
  if (-not (Test-Path $dest)) {
    try {
      Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/Magaav/wasm-agent/main/$doc" -OutFile $dest -ErrorAction Stop
    } catch { Warn "could not fetch $doc (instructions will come from the working directory)" }
  }
}
# The local server serves ui/ from disk, so the window has no network dependency.
# Prefer this checkout's copy when the installer runs from one: GitHub raw is
# CDN-cached, and a stale UI is invisible until something looks wrong.
$uiDir = Join-Path $nodeDir "ui"
New-Item -ItemType Directory -Force -Path $uiDir | Out-Null
$localUiDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot "../ui" } else { $null }
$uiNames = @("index.html", "style.css", "app.js", "components.js", "render.wasm")
if ($localUiDir -and (Test-Path $localUiDir)) {
  foreach ($name in $uiNames) {
    $source = Join-Path $localUiDir $name
    if (Test-Path $source) { Copy-Item $source (Join-Path $uiDir $name) -Force }
  }
  Ok "ui files -> $uiDir (from this checkout)"
} else {
  $uiMissing = @($uiNames | Where-Object { -not (Test-Path (Join-Path $uiDir $_)) })
  if ($uiMissing.Count -eq 0) {
    Ok "ui files present"
  } else {
    $fetched = 0
    foreach ($name in $uiMissing) {
      try {
        Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/Magaav/wasm-agent/main/ui/$name" -OutFile (Join-Path $uiDir $name) -ErrorAction Stop
        $fetched++
      } catch { }
    }
    if ($fetched -eq $uiMissing.Count) { Ok "ui files -> $uiDir" }
    else { Warn "could not fetch $($uiMissing.Count - $fetched) ui file(s); 'wa ui' will retry on first run" }
  }
}
if ($haveExe) {
  $version = (& $localExe --version 2>$null | Select-Object -First 1)
  if ($version) { Ok "local node ready: $version" } else { Warn "wa.exe did not run; try: $localExe --version" }
}

$uiScript = Join-Path $target "wa-ui.ps1"
# Prefer the copy beside this script when running from a checkout: GitHub raw is
# CDN-cached, so a one-liner install can serve a launcher minutes out of date.
$localUi = if ($PSScriptRoot) { Join-Path $PSScriptRoot "wa-ui.ps1" } else { $null }
if ($localUi -and (Test-Path $localUi)) {
  Copy-Item $localUi $uiScript -Force
  Ok "wa ui  -> desktop window (from this checkout)"
} else {
  try {
    Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/wa-ui.ps1" -OutFile $uiScript -ErrorAction Stop
    Ok "wa ui  -> desktop window"
  } catch {
    Warn "could not fetch wa-ui.ps1; 'wa ui' will not work until it is present"
  }
}

Step "creating the desktop icon"
try {
  $icon = Join-Path $target "wa.ico"
if (-not (Test-Path $icon)) {
  $localIcon = if ($PSScriptRoot) { Join-Path $PSScriptRoot "../rust/wa-window/assets/wa.ico" } else { $null }
  if ($localIcon -and (Test-Path $localIcon)) { Copy-Item $localIcon $icon -Force }
  else { Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/Magaav/wasm-agent/main/rust/wa-window/assets/wa.ico" -OutFile $icon -ErrorAction Stop }
}
  $desktop = [Environment]::GetFolderPath("Desktop")
  $linkPath = Join-Path $desktop "wasm-agent.lnk"
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($linkPath)
  $shortcut.TargetPath = (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uiScript`""
  $shortcut.WorkingDirectory = $target
  $shortcut.IconLocation = "$icon,0"
  $shortcut.Description = "wasm-agent"
  $shortcut.Save()
  Ok "desktop icon -> opens the wasm-agent avatar"
} catch {
  Warn "could not create the desktop icon"
}

Step "checking the connection to $HostAlias"
if (Get-Command ssh -ErrorAction SilentlyContinue) {
  try {
    $version = (& ssh -o BatchMode=yes -o ConnectTimeout=8 $HostAlias "wasm-agent --version" 2>$null | Select-Object -First 1)
    # Match the version string rather than trusting $LASTEXITCODE (see above).
    if ($version -match 'wasm-agent\s+\d') { Ok "host reachable: $version" }
    else { Warn "host not reachable - the local node still works offline" }
  } catch { Warn "host not reachable - the local node still works offline" }
} else {
  Warn "ssh not found; the local node still works, only 'wa-remote' and 'wa ui' need it"
}

Write-Host ""
Write-Host "   ready." -ForegroundColor Green
Write-Host ""
Write-Host "   start chatting:" -ForegroundColor DarkGray
Write-Host "     wa        chat with the local node (no SSH, no latency)" -ForegroundColor White
Write-Host "     wa ui     open the desktop window against the local node" -ForegroundColor White
Write-Host "     wa-remote run the same commands on $HostAlias" -ForegroundColor DarkGray
Write-Host "     wa ui --remote   point the window at $HostAlias instead" -ForegroundColor DarkGray
Write-Host ""
Write-Host "   then try:" -ForegroundColor DarkGray
Write-Host "     remember that Laura prefers invoices on the 5th" -ForegroundColor DarkGray
Write-Host "     what do you know about Laura?" -ForegroundColor DarkGray
Write-Host ""
Write-Host "   memory lives in $env:USERPROFILE\.wasm-agent\memory.db" -ForegroundColor DarkGray
Write-Host ""
if (-not (Get-Command wa -ErrorAction SilentlyContinue)) {
  Write-Host "   (if 'wa' is not found, open a NEW terminal)" -ForegroundColor Yellow
}
