# Register the sentinel as a logon task, so it comes back by itself.
#
# Why: the sentinel is the only process that can restart the node, so it must not die with it - and it
# must not depend on an agent or an operator remembering to start it. `deploy.sh` restarts a watching
# sentinel and starts one that is missing, but nothing survives a reboot or a logoff; a stopped watcher
# is exactly the state where "a run cannot revive it" bites. This is the Windows half of
# deploy/wa-sentinel.service.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-sentinel-task.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-sentinel-task.ps1 -Remove
#
# The action is a launcher .cmd beside the binary, not `wa-sentinel.exe watch` directly, because a
# scheduled task does not let you set child environment and the sentinel reads its `run` allow-list from
# WA_SENTINEL_SCRIPTS - a task that cannot execute an allow-listed script is a supervisor that silently
# refuses every `run` job (the failure that made whatsapp-ingest red).
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$TaskName = 'wasm-agent-sentinel'
$Install  = if ($env:WA_INSTALL_DIR) { $env:WA_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'wasm-agent' }
$Sentinel = Join-Path $Install 'wa-sentinel.exe'
$Launcher = Join-Path $Install 'sentinel-task.cmd'
$LogDir   = Join-Path $env:USERPROFILE '.wasm-agent\sentinel'

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "removed scheduled task $TaskName"
    } else {
        Write-Host "no scheduled task $TaskName"
    }
    exit 0
}

if (-not (Test-Path $Sentinel)) { throw "no sentinel at $Sentinel - install the node first" }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# `%~dp0` keeps the launcher portable; the env lines are the whole point of having one.
$launcherText = @"
@echo off
set "WA_SENTINEL_SCRIPTS=$Install\scripts"
set "WASM_AGENT_HOME=$env:USERPROFILE"
set "WA_SENTINEL_WAKE_BUDGET=6"
rem Reserved child capacity for job inference, so a job's child does not have to wait for an idle
rem node. Unset, the inference lane is idle-gated and every child sits in the queue while a turn
rem runs - which reads like the design and is really the fallback (docs/JOBS.md).
set "WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY=1"
"%~dp0wa-sentinel.exe" watch >> "$LogDir\sentinel.out" 2>&1
"@
Set-Content -Path $Launcher -Value $launcherText -Encoding ASCII
Write-Host "wrote launcher $Launcher"

$action  = New-ScheduledTaskAction -Execute $Launcher
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force | Out-Null
Write-Host "registered scheduled task $TaskName (at logon, limited)"
Write-Host "start it now without logging off:  schtasks /Run /TN $TaskName"
