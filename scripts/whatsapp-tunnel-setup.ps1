#Requires -Version 5.1
<#
.SYNOPSIS
  Register or update the per-machine WhatsApp tunnel keepalive task.

.DESCRIPTION
  The MCP binding reaches the connector at a numeric loopback URL. When the
  connector runs on the rendezvous, that loopback is an SSH forward. This task
  runs scripts/whatsapp-tunnel.sh, which reconnects whenever ssh exits.

  The scheduled task is machine state and cannot live in git; this script is the
  reproducible bootstrap. It backs up an existing task XML, creates or updates
  the task, starts it and checks the local port.

.PARAMETER TaskName
  Scheduled task name. Default wa-whatsapp-tunnel.

.PARAMETER RepoRoot
  Checkout root. Defaults to the parent of this script's directory.

.PARAMETER HostName
  SSH host of the rendezvous. Default openclaw.ohana.

.PARAMETER LocalPort
  Local loopback port the MCP binding uses. Default 28787.

.PARAMETER RemotePort
  Connector port on the rendezvous. Default 28787.
#>
[CmdletBinding()]
param(
    [string]$TaskName = "wa-whatsapp-tunnel",
    [string]$RepoRoot = "",
    [string]$HostName = "openclaw.ohana",
    [int]$LocalPort = 28787,
    [int]$RemotePort = 28787
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "windows_required"
}
$bash = Join-Path ${env:ProgramFiles} "Git\usr\bin\bash.exe"
if (-not (Test-Path -LiteralPath $bash)) {
    throw "git_bash_not_found: $bash"
}
$script = Join-Path $RepoRoot "scripts\whatsapp-tunnel.sh"
if (-not (Test-Path -LiteralPath $script)) {
    throw "tunnel_script_not_found: $script"
}

# git-bash needs a POSIX path for the script argument.
$posix = $script -replace '\\', '/'
if ($posix -match '^([A-Za-z]):') {
    $posix = "/" + $matches[1].ToLowerInvariant() + $posix.Substring(2)
}

$dir = Join-Path $env:LOCALAPPDATA "wasm-agent"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$cmd = Join-Path $dir "whatsapp-tunnel.cmd"
$lines = @(
    '@echo off',
    "set WA_WHATSAPP_TUNNEL_HOST=$HostName",
    "set WA_WHATSAPP_TUNNEL_LOCAL_PORT=$LocalPort",
    "set WA_WHATSAPP_TUNNEL_REMOTE_PORT=$RemotePort",
    "`"$bash`" -lc `"exec '$posix'`""
)
Set-Content -LiteralPath $cmd -Value $lines -Encoding ASCII

$backupDir = Join-Path $env:USERPROFILE ".wasm-agent\backups\tasks"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    try {
        Export-ScheduledTask -TaskName $TaskName |
            Set-Content -LiteralPath (Join-Path $backupDir "$TaskName.xml") -Encoding UTF8
    } catch {
        Write-Warning "task_backup_failed: $_"
    }
    # <nul avoids schtasks waiting for a run-as password on a non-interactive host.
    & cmd.exe /c "schtasks /Change /TN `"$TaskName`" /TR `"$cmd`" <nul" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks_change_failed: $LASTEXITCODE" }
} else {
    & cmd.exe /c "schtasks /Create /TN `"$TaskName`" /TR `"$cmd`" /SC ONLOGON /IT /F <nul" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks_create_failed: $LASTEXITCODE" }
    & cmd.exe /c "schtasks /Change /TN `"$TaskName`" /RI 2 /DU 9999:00 <nul" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks_repetition_failed: $LASTEXITCODE" }
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$state = (Get-ScheduledTask -TaskName $TaskName).State
$listening = Test-NetConnection -ComputerName 127.0.0.1 -Port $LocalPort -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Output "task=$TaskName state=$state listening=$listening script=$script"
if (-not $listening) {
    throw "tunnel_not_listening"
}
