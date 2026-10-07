# Native Windows Sentinel service

Implemented preparation; **not a live SCM migration or universal uptime guarantee**.
The existing Windows logon-task procedure remains available until the service is
proved under a properly provisioned identity. Linux/systemd behavior is unchanged.

## Why and boundary

The 2026-10-07 Windows logon task exited `0xC000013A` with `^C` in its launcher output,
then stayed down because restart-on-failure was 0. The sender cannot be reconstructed:
Task Scheduler history was disabled. A native SCM process has no user-console lifetime;
Windows owns its startup, stop/shutdown controls, status and failure recovery.
No additional polling watcher, inference agent, periodic job or node auto-restart.
Recovery restarts **the Sentinel process**, not an unrequested node or unknown effect.

The code is `rust/wa-sentinel/src/windows_service.rs`, using existing windows-sys
SCM APIs. No third-party service wrapper/download or `sc create` console workaround.

- `service --name NAME --config ABSOLUTE_JSON` enters the SCM dispatcher; a console
  invocation refuses instead of silently falling back to `watch`.
- Config is bounded to 16 KiB/strict schema, exact name, absolute existing home/install/cwd,
  exact installed sentinel image, and an allowlisted environment. Credentials and
  Lua-root injection are refused. It is local trusted installer state, not a sandbox
  against privileged source/config writers.
- Status transitions: StartPending -> Running only after existing watcher/runner
  lifetime locks are owned; StopPending -> Stopped on SCM stop/shutdown.
- Stop callbacks signal admission fences, write local stop intent and update status;
  the watcher checks those fences before subsequent request/trigger work. In-flight threads/owned operations can be interrupted by
  process exit; original uncertainty survives and is never replayed on recovery.
  Concurrent in-flight admissions and filesystem/OS stalls remain limits, not drain proof.
- Manual SCM stop writes a persistent intentional stop marker at control observation
  and orderly exit; OS shutdown does not.
  A startup with that marker exits cleanly without consuming the queue. Explicit
  validated CLI start/restart clears it; failure recovery cannot override intent.
- `windows:<name>` is the watcher manager identity. CLI start/stop/restart asks SCM,
  validates exact service executable/config/home before effects, waits bounded30s for
  observed state and never falls back after refusal/access denied. Missing/mismatched
  service does not become a detached competitor. SCM stop requires lifecycle rights.
- Runtime rejects elevated service tokens, including LocalSystem/elevated administrator.
- `sentinel.log` records lifecycle/refusal facts; `service.log` records ordinary watcher
  output without requiring stdout/console. SCM events supply process exits. Error
  messages are private local evidence; no inference is needed to collect them.

## Identity provisioning: do not guess

Registration needs an external elevated administrator; running needs an explicitly
chosen **non-administrator local service-logon account**. Installer accepts PSCredential
in memory, never a password in argv/files/receipts. It refuses privileged/builtin admin
accounts or unresolved nested local administrator-group membership. No LocalSystem default.

Provision only the required rights before invoking apply:
- Log on as a service for that account;
- read/execute installed binaries, Git/Node/Git Bash and approved scripts;
- narrowly scoped writes to Sentinel state, operation/job stores and authorized install
  paths; explicit working tree/build/deployment access if those operations are needed;
- permission to control the exact user-owned node, or an intentional node identity
  migration. A different account cannot automatically stop the operator's existing process;
- credential/DPAPI identity: do not expose/copy the operator's profile or OAuth store to
  a new account as an automatic fix. Choose account continuity or reviewed migration.

Service sessions run in Windows Session 0. Desktop window/browser control does not move
there; the user client remains in the interactive session. User-specific filesystem,
SSH, Git and credential access must be explicitly tested. A service that merely answers
Running but cannot perform its authorized deployment is not ready.
The installer `-ConfirmAccountProvisioned` is explicit operator attestation, not an ACL,
logon-right or DPAPI proof; live service checks are still required.

## External installer

`scripts/install-sentinel-service.ps1` ships beside the Sentinel, but is never
run automatically by deploy. `-Check` is read-only and allowed inside a turn.
Apply refuses `WASM_AGENT_IN_TURN=1`, missing elevation and missing identity inputs
before any config/service/task mutation. Do not remove the run marker or bypass it.

From an external administrator PowerShell, after published-source supported deployment
has installed a sentinel supporting `service-config-check`:

```powershell
# Read-only preparation. Pass the operator's real home, not the admin account's default.
.\scripts\install-sentinel-service.ps1 -Check -Install 'C:\path\wasm-agent' `
  -NodeHome 'C:\Users\operator' -WorkingDirectory 'C:\path\canonical-main'

# Obtain credentials interactively, never via command-line password.
$serviceIdentity = Get-Credential 'MACHINE\non-admin-service-account'
.\scripts\install-sentinel-service.ps1 -Install 'C:\path\wasm-agent' `
  -NodeHome 'C:\Users\operator' -WorkingDirectory 'C:\path\canonical-main' `
  -Credential $serviceIdentity -OperatorSid 'S-1-5-21-...' `
  -ConfirmAccountProvisioned -MigrateTask -Start
```

Use native Windows paths, never `/c/...`. Do not run this example with placeholders.
The service binary must already be installed through supported external deploy/sentinel
procedure; the installer never copies over a running binary or restarts the node.
The stopped-watcher bootstrap still requires external authorized execution.

Apply stages:
1. Refuse existing service/config, live/unverified watcher, intentional stop and live
   legacy task. Pending queue contents remain untouched; `-Start` authorizes normal
   queue intake, not retry of historical unknown effects.
2. Back up task XML, manager/pid/stop records under a unique service-install generation.
3. Write/protect config, check exact installed binary/config through its model-free CLI.
4. Register Manual/Stopped with explicit identity; configure SCM recovery 5s/15s/60s,
   reset interval 86400s and non-crash failure flag. Lifecycle ACL grants only exact
   operator/account query/start/stop rights, not Everyone/service-all-access.
5. Verify exact SCM registration. Without `-Start`, leave service Manual/Stopped and
   legacy task enabled; registration is not active migration.
6. With `-Start`, prove Running plus actual watcher `windows:<name>` binding, then
   disable (not delete) legacy task and set delayed Automatic startup. Persist readback.

No blind reapply: any partial error keeps config/service/backups/evidence. Inspect exact
SCM/config/task state; script refuses overwriting an existing generation/registration.
Failure before readiness leaves the old task enabled; if failure occurs after actual
start, normal queue work may already have happened. Never claim rollback or replay it.
The service recovery setting is OS lifecycle support, not an additional Engine job.

## Stop, update and recovery

Use installed `wa-sentinel stop|start|restart` from an authorized external shell.
Intentional stop stays stopped; restart refuses an existing stop marker until explicit
start resumes. Service status/readiness failure never permits a console fallback.
Node/window stop/replacement rules remain unchanged; do not stop by image name.

Supported deploy runs detached from the service, so an SCM stop of the old watcher
cannot kill its binary replacement installer. Windows sentinel replacement now refuses
on a failed stop/copy/start instead of ignoring those errors. Wait for idle/exact-source
provenance and final installed hashes through the existing deploy procedure. An SCM
service cannot be registered using an older sentinel that lacks these lifecycle verbs.
Service installation does not confer broader filesystem/deployment privileges.

## Verification and remaining live proof

Focused Rust tests cover name/command/config/environment limits and owner routing;
private CLI fixtures cover valid config, malformed/mismatched config, console dispatcher
refusal and nonexistent-service lifecycle with **no queue mutation/fallback**.
`test-sentinel-service-installer.ps1` covers parser/read-only/negative staging; it does
not simulate a successful SCM installation. Entire native sentinel focused regression
suite is distinct from a full repository release gate.

To certify a live migration, an external administrator must additionally observe:
- exact non-elevated identity/config/image/SCM PID, no interactive console;
- private unexpected process exit -> one SCM restart with recorded generation/exit;
- explicit stop stays stopped, shutdown/start resumes without deleting intentional stops;
- no duplicate watcher alongside the retained task;
- existing approved script/deployment execution under that exact account;
- supported self-upgrade stop/swap/start/readback and clean provenance;
- unchanged job approvals, original queues/unknown dispositions and backups.

The current assistant process is non-elevated and no suitable service credential has
been supplied. **Registration, live recovery and production self-upgrade remain unverified**;
source/fixture success must not be reported as an installed service.
