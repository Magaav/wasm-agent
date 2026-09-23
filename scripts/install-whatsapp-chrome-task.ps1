# Keep the WhatsApp source reachable across reboots: the wrapper that opens Chrome on the agent profile
# with DevTools on loopback:9222, and the logon task that starts it.
#
# Why this file exists: the copilot's job is a *durable* flag, so after a reboot it still says it is on
# while every delivery fails `no_cdp_endpoint` - the reader has nothing to read. The wrapper alone is not
# a trigger, and a wrapper that lives only in one machine's install directory is not deployed, so both
# halves are written and registered here. `scripts/whatsapp-preflight.sh` answers the question in one
# line: with no CDP endpoint, nothing is read and the deliveries fail, visibly, forever.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-whatsapp-chrome-task.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-whatsapp-chrome-task.ps1 -Remove
#
# Registering a task for the logged-on user needs no elevation on a default Windows policy; if this
# refuses with "access denied", run it from an elevated prompt.
#
# It is deliberately NOT a node operation and never started by one: a running operation makes the
# sentinel treat the node as busy forever, which starves the inference lane - no job child is ever
# claimed. The task scheduler owns this process, so it also survives the turn that started it.
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$TaskName = 'wasm-agent-whatsapp-chrome'
$Install  = if ($env:WA_INSTALL_DIR) { $env:WA_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'wasm-agent' }
$Wrapper  = Join-Path $Install 'whatsapp-chrome.cmd'

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Write-Host "FAILED: $TaskName is still registered after Unregister-ScheduledTask."
            Write-Host "Remove it from an ELEVATED prompt:  schtasks /delete /tn $TaskName /f"
            exit 1
        }
        Write-Host "removed scheduled task $TaskName"
    } else {
        Write-Host "no scheduled task $TaskName"
    }
    Write-Host "the wrapper is left in place: $Wrapper"
    exit 0
}

New-Item -ItemType Directory -Force -Path $Install | Out-Null

# The paths are derived, not hardcoded: an install directory carrying one machine's user name is a
# wrapper that silently does nothing on the next machine (and `%LOCALAPPDATA%` is the profile the docs
# name - docs/WHATSAPP-COPILOT.md, docs/SPELLS.md).
$wrapperText = @"
@echo off
rem Keep the WhatsApp source reachable: Chrome on the agent profile with DevTools on loopback:9222.
rem Written and registered by scripts/install-whatsapp-chrome-task.ps1; launched by a scheduled task,
rem NOT as a node operation - a running operation makes the sentinel treat the node as busy forever.
set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
set "PROFILE=%LOCALAPPDATA%\AgentBrowserChromeProfile"
rem Already listening? then nothing to do (a second Chrome would just hand off to this one).
netstat -ano | findstr /r /c:"127.0.0.1:9222 .*LISTENING" >nul 2>&1 && exit /b 0
if not exist "%CHROME%" (
  echo whatsapp-chrome: no Chrome at "%CHROME%" 1>&2
  exit /b 1
)
start "" "%CHROME%" --remote-debugging-port=9222 --user-data-dir="%PROFILE%" --no-first-run --no-default-browser-check https://web.whatsapp.com
exit /b 0
"@
Set-Content -Path $Wrapper -Value $wrapperText -Encoding ASCII
Write-Host "wrote wrapper $Wrapper"

$action  = New-ScheduledTaskAction -Execute $Wrapper
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# -ExecutionTimeLimit Zero: the wrapper exits as soon as Chrome is launched, and a task the scheduler
# decides to kill is a source that disappears mid-session.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force | Out-Null
# Verify what the machine actually has, because a refused registration is a *non-terminating* error: with
# $ErrorActionPreference = 'Stop' it did not stop this script, so it printed "registered scheduled task"
# while nothing was registered (measured: the node's token is refused with 0x80070005). A script that says
# it installed something it did not is worse than one that fails: the operator reads "registered", logs
# off, and the copilot comes back blind.
if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    Write-Host "FAILED: $TaskName is NOT registered - this process was refused the task store."
    Write-Host "The wrapper is in place; register the task from an ELEVATED prompt:"
    Write-Host "  schtasks /create /tn $TaskName /tr `"$Wrapper`" /sc onlogon /rl LIMITED /f"
    exit 1
}
Write-Host "registered scheduled task $TaskName (at logon, limited)"
Write-Host "verified: Get-ScheduledTask returns it"
Write-Host "start it now without logging off:  schtasks /Run /TN $TaskName"
Write-Host "then check the chain with:         bash scripts/whatsapp-preflight.sh"
