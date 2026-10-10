# Sentinel

The process outside the node.

## Why it exists

Every failure that mattered had one shape: **the only process that could act was the one that needed
acting on.**

- A node cannot restart itself. The run doing the restarting runs on the node it is stopping, so the
  stop is the last command it ever executes — the copy never happens, the start never happens, and the
  node stays down with nobody to bring it back. This happened twice in one day.
- A dead node cannot say why it died. Two outages left nothing in a file, which is why the cause had to
  be guessed.
- A node cannot be trusted to judge whether it should be woken: that spends money.

So the sentinel lives outside, watches, and acts on **declared requests** — a fixed verb list, never a
shell. The thing that can restart your agent must not be something your agent can talk into anything.

## Asking

### Exact-source deployment and deterministic return

The source-bound protocol uses the native watcher and its declared
`onSentinelReturn` Engine hook. From an authorized operator outside the installation
step, queue one immutable intent:

```text
wa-sentinel request deploy --expected-sha <full 40-character main SHA> \
  --owner <actual parent user_id> --session <actual parent conversation id> \
  --reason "why this reviewed source is requested"
```

The CLI returns a queue receipt. The watcher separately records `intent.json`,
`ack.json` and `state.json` under `sentinel/deploy-protocol/<request-id>/`.
An acknowledgement means the watcher observed the immutable request; it grants
neither effect authority nor installation success. Parent-owner HTTP/body failures
retain their underlying cause in durable refusal text (no credentials or body dump).
Only HTTP503 with the exact `read_capacity_busy` code at parent-owner or node-identity lookup defers the immutable claim
before an effect exists, with backoff. Other HTTP/identity failures remain failures.
A failed pre-admission request is not automatically replayed; preserve its original
record and prove no effect reservation/spawn before proposing any fresh intent.
A separate cheap intake lane observes new identities while health, source or verifier work is blocked. The
five-second observation policy is tested on the trusted local runtime, not a hard
real-time Windows guarantee. A malformed or changed identity produces a named
problem while preserving the original intent and acknowledgement.

`protocol target` is a read-only native ownership diagnostic (and may perform the
existing verified legacy lifecycle re-adoption). It reports pid/creation/idle and
preserves the underlying ownership refusal, never grants installation authority.

An effect waits for actual parent ownership, the enabled `onSentinelReturn` hook,
a clean primary `main` checkout exactly equal to both `origin/main` and the
remote's actual main, an idle node, and native target identity. It resolves the
canonical deployer from the installed runtime record. The request cannot select
a script or executable. A durable `effect.json` records full source/tree, script
hash, parent/owner and native generation before spawn. One installation reservation
survives watcher replacement; an unsettled earlier effect refuses another.
Only actual verified installation settles that reservation. Failed/unknown
effects are retained for explicit reconciliation and are never replayed.

A consumed terminal failure can leave the installation reservation held even after
finalization is separately repaired. From an external authorized executor use:

```text
wa-sentinel protocol reconcile <exact-request-id> --reason "why this recovery is authorized"
```

This is **verification only**, never installation retry. It revalidates the parent
owner, immutable intent and exact admitted reservation generation, current clean
published source, installed artifacts/UI/scripts, process creation identities and
fresh actual verifier. It archives original request/result/state/cursor/reservation
before checking, then marks only that exact reservation verified on success. It
preserves failed return journals and terminal delivery cursors, emits no new wake,
and cannot grant another attempt to an unknown effect. Missing/mismatched evidence
or verification failure leaves the reservation held; cached green packets do not
settle it. In-turn invocation refuses; queue an allowlisted operator script through
Sentinel `request run` for the external verification door. Repeat verification is
allowed but never replays the installer. The ordinary reconcile still requires
current main equal to the requested source.

When main has advanced but the old clean-built generation is still installed,
use `protocol reconcile-historical <id> --reason "..."` through the same external
door. It validates current clean published main, proves the old source is its
ancestor, compares installed UI/scripts/skills against retained Git blobs and raw
recorded aggregate hashes, rechecks result/binding/reservation identity, and brackets
native node/watcher image/creation/lifetime ownership. It retains original installed
process IDs while explicitly recording freshly proven replacement generations;
`installed.txt` is never edited. Historical Windows text-only CRLF copies require
exact LF-normalized blob equality AND the original raw digest for scripts/UI;
normalization is reported, never applied. Missing evidence/hash/identity fails.
Only that exact reservation settles; notification unknowns remain unknown.
A tested source-built Sentinel may perform this verification-only bootstrap via
an allowlisted `request run` without replacing the live watcher.

The watcher observes returns natively. The shipped `sentinel-return-observe.sh`
and `sentinel-return-prepare.sh` invoke `protocol observe` and
`protocol compose <key-only-event-file>` respectively. General event ingress
accepts only request/event keys: parent, owner and instructions come from the
immutable binding and observer journal. The historical JavaScript classifier
and direct compose APIs remain inert and cannot manufacture completion authority.
The deterministic hook constructs instructions without a provider call; the
approved Engine wake then runs the ordinary parent conversation.

A check is due ten seconds after acknowledgement and recurs while updating.
The native observer validates the immutable ack's full source, request, parent,
owner, queue identity and integer timestamp (never future dated) before delivery.
Missing, corrupt, mismatched or unsupported acknowledgements are unknown: they
create no check, wake or effect authority. Check records retain the exact ack;
changed acknowledgements and legacy checks without that binding require explicit
reconciliation, with no fabricated queue-time fallback or automatic replay.
Observation, return resolution and instruction composition use the same native
current-check validator: exact request/source/parent and saved ack, supported
integer observation/deadline timestamps, ten-second cadence and attributable
due/coalescing revision. Missing established checks, corrupt or unsupported
checks revoke pending return authority and are never silently reset. Only an
initial observation may create a check after a genuine ack; earlier missing-ack
UNKNOWN evidence can remain intact while that first clock starts. Composition
requires the current check and cannot turn an invalid check's held journal into
an instruction. This does not add effect or replay authority.
Observation eligibility is checked under the request lock before owner HTTP or
ack/intent reads. Consumed terminal cursors do no further owner lookup. Pending
observations poll at ten-second intervals; failed observations retry after 10,
20, 40, then at most every 60 seconds, recorded separately in
`observation-poll.json`. That schedule grants no delivery or effect authority;
missing credentials/parents, changed owners and invalid acknowledgements still
refuse when due, and delivery/composition always revalidate independently.
`GET /session/owner?id=<parent>` resolves the ordinary authenticated/local account
and session ownership boundary but returns only `session.id` and
`session.user_id`, without loading messages or derived transcript state.
Installation observation is recorded independently of notification delivery.
An unknown submitted notification preserves its immutable journal/slot and is never
resent, but cannot prevent fresh result verification and exact reservation settlement.
Busy parents keep one pending event; due observations coalesce on disk rather
than spawning extra wakes. Revision cancellation before submission can emit the
same immutable key against the new revision. Before HTTP submission the watcher
writes a persistent per-event delivery record. A terminal return is confirmed
only after the root SSE `done` event is consumed; interrupted/ambiguous submission
is visible and cannot earn a second attempt, even after revision or restart.
This is the trusted runtime completion boundary, not a guarantee that an
arbitrary downstream external effect occurred.

Protocol deploys omit the legacy continuation wake. The request-bound installer
result, final clean-built installation record, and actual fresh verifier must
agree on full source/tree and actual node/sentinel/script/UI hashes, listener
and watcher identities, with zero failures or skips. The verifier derives UI
assets from the installer's declared served list, excluding source test fixtures
and recognizing only its named recovery backups. A cached green packet or a
synthetic predicate object cannot establish completion: a positive return reruns
the actual verifier at delivery. Only that result permits `I am updated`.

The state files and canonical source remain privileged local filesystem state,
not signed intents or an OS security sandbox. Reserve canonical source while
installing; a privileged writer racing the bracketed checks remains outside the
guarantee. Missing outcome after the bounded ten-minute observation becomes
unknown and must be reconciled without automatic effect retry. New/changed jobs
still install disabled; enabling the hook is a separate authorized action.

`scripts/test-sentinel-private-install.cjs`, under
`scripts/test-sentinel-owned-job.py`, exercises a new full private source clone,
real private bare remote, explicit private home/install/ports, source-built
binaries, actual deployer/verifier/native processes, and real Lua/SQLite parent.
Only inference is a labelled local mock. These tests never authorize production
installation or settle historical production claims.

```
wa-sentinel request restart  --reason "why"    # graceful; stays queued while busy
wa-sentinel request recover  --reason "why"    # explicit interruption; never waits for idle
wa-sentinel request upgrade  --binary /path/to/wa --reason "why"
wa-sentinel request upgrade  --binary /path/to/wa --session <id> --prompt "continue after upgrade" --reason "why"
wa-sentinel request deploy   [--session <id> --prompt "continue after deploy"] --reason "why"
wa-sentinel request spell    --file /path/to/plan.json --reason "why"
wa-sentinel request wake     --session <id> --prompt "..." --reason "why"
wa-sentinel request run      --script /path/to/script.sh --reason "why"
```

That list is the whole set of verbs, and it is enforced at both doors that can write a request. `request
--help` (and `-h`, and `help`) prints the usage and writes **nothing**, and a verb outside the list is
refused by name before any file exists — a request whose only possible outcome is the worker's `unknown
verb` refusal is durable state created by a question or a typo, not by an effect that was attempted
(measured 2026-10-02: `request --help` wrote a real request with `verb: "--help"`, which the worker then
filed under `failed/`). A **trigger** is judged by the same list: `triggers.json` decides *when*, never
*what*, so a trigger naming a verb this sentinel cannot perform is recorded as `triggers-bad-verb` and
fires no request at all — the trigger stays in the file, visible and fixable.

### More than one node on a machine

A node's home, key, database, ports and supervisor records are per **instance**, so one machine can
host an operator's master node beside a guest node bound to another master. Select one with
`--instance NAME` (or `WASM_AGENT_INSTANCE=NAME`); with no name the ambient/default node behaves
exactly as before. `wa-sentinel instance add|list|show|remove|start|stop|status` manages them, and
the sentinel will not stop a listener it cannot prove it started. This is **application home
isolation, not an OS sandbox**: instances run as the same operating-system account, so a guest
process can still read what that account can read. See [INSTANCES.md](INSTANCES.md).

A node restarted by the gate (`deploy.sh` -> `upgrade.sh`) is started outside the sentinel, which
writes only `serve.pid`; the lifecycle record then names the previous pid. The next stop or
restart re-adopts the live node when `serve.pid` names the listener and the identity proves out,
rewriting the record - so a gate deploy no longer leaves `request restart` permanently refused. A
stale record whose `serve.pid` does not name the listener is still refused: a port is not an
identity, and a recycled pid is not this node.

### `deploy` is not `upgrade`, and the difference matters

`upgrade` installs the node and the UI. It **cannot** install a *sentinel*: `upgrade.sh` copies the node
binary, the UI, itself and the self-update skill, and only ever *reads* the sentinel's hash. So a fix in
the sentinel — the process that supervises everything else — had no path from inside a run, and needed a
human at a shell running `deploy.sh`.

`deploy` closes that: it runs `scripts/deploy.sh` (the gate: clean tree, not behind `main`, the binary
proved on a scratch port, install, rollback if the new node does not answer), which installs the node,
the UI **and** the sentinel. Two properties make it work, and both are deliberate:

- **it waits for idle before it starts.** `deploy` is in the same group as `restart`/`upgrade`/`spell`:
  the watcher holds the request until no turn is running. Without that, the script's own idle wait would
  be waiting for the very turn that asked for it, and the supervised child's 302 s deadline would turn
  that deadlock into a kill — which is exactly how the first attempt failed.
- **it runs detached.** Every other verb is a supervised child whose output is evidence; this one must
  outlive its parent, because the parent is the process being replaced, and on Windows only a *different*
  process can overwrite the image of a running one. Nothing is lost by that: `deploy.sh` proves the new
  node before it goes near the live one, records `installed.txt` and `deploy.log`, and rolls back on its
  own. The completion signal is the continuation wake, queued by the script once the new node answers
  `/health` and performed by the **new** watcher.

Two details that decide whether a *requested* deploy can work at all:

- **it must find the tree to build from.** `request deploy` runs the copy of `deploy.sh` installed beside
  the supervisor, so `dirname $0/..` is the *install* directory, not a worktree. It resolves the tree as
  `WA_DEPLOY_ROOT`, else `..` if that is really a git work tree, else the runtime worktree recorded in
  `<install>/runtime-worktree.txt` — the same file `upgrade.sh` reads. The first self-driven deploy failed
  on exactly this: it read `unknown` for the commit, built in the install directory and reported "the
  build failed", with the tree it should have used recorded in a file nothing read.
- **a failure answers the requester.** The request is `done` as soon as the script is *spawned*, so for a
  deploy that is a launch receipt and nothing more: a deploy that refused before the swap left the node
  untouched and told nobody. `deploy.sh` now wakes the requesting session on its failure path too, naming
  the refusal and where the evidence is; a hand-run deploy passes no `--session` and wakes nobody.

`scripts/verify-install.sh` is the one-command check afterwards: installed vs built hashes, shipped
scripts vs the repo, the recorded pid vs the listener, the watcher alive - PASS/FAIL, `--json` if you want
it as data. `deploy.sh` also writes `<install>/deploy-result.json` and puts a one-line verdict in the
continuation wake, so the outcome is read once instead of re-derived. `request run --script` executes only
from directories in `WA_SENTINEL_SCRIPTS` (the install's `scripts/`, set by the gate, the unit and
`scripts/install-sentinel-task.ps1`); use it for work that must happen outside a turn.
On Windows an approved `.ps1` script uses the native system PowerShell executable
with `-NoProfile -NonInteractive -File` and a native path, never Bash or an
inline command. The same canonical allowlist check precedes interpreter selection;
script errors are failed supervised operations. Only `run` requests validate and
queue the legacy run-result continuation; protocol deploys carry a parent without
requiring a legacy prompt and must not produce a spurious run-continuation error.
A `.ps1` on other platforms refuses with no shell fallback. Approved `.js`, `.mjs` and `.cjs` files (case
insensitive) run directly through Node with a separate native script argument,
never through Bash or an inline command. Node is resolved to an absolute
executable before admitting an operation: explicit `WA_SENTINEL_NODE`, else the
watcher's absolute PATH entries, then standard Windows Program Files Node installs.
An invalid explicit override or missing runtime refuses as
`node_runtime_unavailable`, with no shell fallback and no script effect. No npm
install/download or arbitrary runtime from event fields occurs. Empty/relative
PATH entries are ignored. This is the trusted local executable boundary, not a
binary-signature guarantee. Job `run`, pipeline `run` and wake `prepare` share this
same dispatch after canonical allowlisting. Script dependency PATH remains the
script/operator's responsibility; selecting Node does not make `rg` or other
child executables available. Other script interpreter behavior is unchanged.

A stopped watcher cannot hear a queued request. Restore its existing validated
OS task through the restore-only procedure below, which an authorized operator
agent may invoke via node-side shell even during a turn. Node replacement still
belongs outside the run and waits for idle. Keep the supervisor in a service or
logon task (`deploy/wa-sentinel.service`; `scripts/install-sentinel-task.ps1`).

`request` **writes a file** and returns. `watch` (or `once`) performs it. That split is the whole
point: the writer may die immediately afterwards, and the request still lands.
An upgrade with both `--session` and `--prompt` wakes that session only after a
successful upgrade, avoiding a race between separately queued upgrade and wake
requests. `installed.txt` records the exact hash even for sentinel upgrades;
their source commit remains explicitly unverified unless built by the clean
deployment gate. The detailed upgrade transcript is in `sentinel/upgrade.log`. The upgrade script
runs under the existing `wa-operation` process-tree supervisor (default 1,800 s;
`WA_SENTINEL_UPGRADE_TIMEOUT_SECONDS` selects the budget). Original state/output
are retained in sentinel operations, not colliding temporary filenames. Timeout
terminates owned descendants; unknown cleanup refuses success and replay. Killing
only the shell is not completion of the installer.

### `/update`: the node asking, on a human's behalf

The same request can be written from inside the node — `/update` in the composer, or in `wa chat` —
because the operator should not have to leave the window to say "install the build in your own
tree". It is the same box and the same verb:

```
/update          # the window (POST /update) and the CLI both run lua/core/update.lua
```

That module verifies there is a clean runtime tree (`runtime-worktree.txt`) and an installed sentinel,
then writes one gated deploy request and reports **queued** — never "updated", because the record that
settles it is in `sentinel/done/` or `failed/`. A refusal is also an answer: `no_runtime_tree` names
what it looked for, `no_sentinel` says which path is missing, and `tree_dirty` explains why the gate
would refuse the checkout. The node never installs anything itself. When `/update` comes from a chat,
the request carries that session and a fixed continuation prompt; the sentinel wakes it only after
replacement settles, so reconnecting the window is not the update's continuation protocol.

The box is `<config>/sentinel/requests/*.json` — `~/.wasm-agent/sentinel/requests` by default. A file
survives the death of whoever wrote it, needs no socket, and works **when the node is down**, which is
when you need it most.

## What it guarantees

- **Maintenance and recovery are distinct.** `restart` remains queued while the node is busy,
  without blocking the watcher. `recover` interrupts by the listener PID without asking Lua to go
  idle; use it only for deliberate recovery. Direct `wa-sentinel recover "reason"` is the independent
  escape path even if legacy maintenance is occupying the request processor. `upgrade` proves the new binary answers on a
  scratch port before it goes near the running node.
- **Stop by pid, never by image name.** Another `wa` on the machine may be somebody's session.
- **Every action is logged with its reason** in `<config>/sentinel/sentinel.log`, including refusals.
  Nothing here happens silently.
- **Waking is budgeted.** `WA_SENTINEL_WAKE_BUDGET` per hour (6 by default) because it is the only verb
  that costs money. Over budget, it refuses and says so.
- **`run` is disabled** unless `WA_SENTINEL_SCRIPTS` names the directories it may execute from.
- **A kill switch:** `wa-sentinel stop`. Where a service manager owns the watcher it is the *manager*
  that stops it (`systemctl stop wa-sentinel.service`), because `Restart=always` turns a stop file into a
  restart five seconds later. Managing a system unit needs the manager's authority: on a machine whose
  unit user is not authorised by polkit for `org.freedesktop.systemd1.manage-units` (measured on this
  project's node: `pkcheck` answers "Authorization requires authentication" for an ssh shell), run
  `sudo wa-sentinel stop`. A refusal is loud and names the manager's reason and the unit - never a quiet
  stop file.

A non-root deploy whose system watcher needs administrator authority may explicitly
set `WA_DEPLOY_SENTINEL_SUDO=1` (default 0). It validates noninteractive sudo
before installation and invokes only the installed sentinel's verified `restart`
through `sudo -n env`, passing its exact home/install and declared supervisor.
The rest of the deployment remains the service user; no polkit rule or root-owned
agent is created. A sudo refusal is terminal, not permission to spawn a watcher
or retry with weaker ownership. Invalid values refuse before installation.

### Bounded idle I/O observation (Windows)

Queue the shipped `scripts/measure-sentinel-io.ps1` with sentinel `request run`
using `--session <id> --prompt <collect instruction>`, then end the turn. Request
dispatch is concurrent: two separately queued run/wake requests are NOT a serial
completion guarantee. The run continuation is created only after the original
known-settled success/failure record is durable, using a deterministic per-request
wake key; a consumed/claimed/queued wake is never duplicated. Unknown execution
or a crash between record and continuation requires inspection, not effect replay. It waits at most 180 seconds for empty native run/child/operation
inventories and records three eight-second samples of process read counters and
CPU time, binding each sample to the original process creation generation. Busy,
changed or unavailable evidence is a refusal/invalid sample, never idle success.
Receipts are under `<data>/sentinel/io-idle-*.json`; no recurrent job is created.
An old sample during an active wake is not a matched idle baseline. OS counters
include cached/network I/O; this diagnostic does not measure fan causation.

## Direct Git shell environment and early installer outcomes

Direct Git `usr/bin/bash.exe` remains console-quiet, but is not a login shell.
`wa-operation::shell_env` validates the selected absolute Git installation layout
and prepends that installation's `usr/bin`, `cmd` and MinGW tools only to the child
PATH. Host foreground/background operations and detached Sentinel deployments
share it. Existing PATH entries/explicit shell choices remain; unrelated shells
are untouched. No profile, global PATH mutation, elevation or new watcher.
Missing essential bundled utilities refuse before spawn; deploy/upgrade scripts
also use builtin preflight before source resolution, preventing false dirty-tree
errors when `dirname`/`wc` are missing. Real ordinary-Windows-PATH positive and
old-environment negative tests cover the actual utility commands.

For source-bound detached installers, the owning child wait writes native
`process-exit.json` bound to the full admitted effect. Nonzero exit with no script
result is reported `failed`, not perpetual `updating`. Exit zero without a result
is `unknown`, never installed; malformed/foreign evidence remains unknown. Neither
exit nor failure releases an installation reservation, and watcher death can still
leave an unknown outcome. Raw capture and original journals stay intact.

For the narrow historical PATH failure, external-only `protocol retire-preinstall
<id> --reason <text>` validates immutable parent/effect/source, exact unique failed
capture, unchanged live target PID+creation+binary, and the retained script's early
clean-check boundary. It archives originals and writes `aborted_preinstall` plus a
retirement receipt; it does not claim installation, reset return cursors or replay
the old request. Any partial-install/changed-target/unknown evidence refuses.
Admission/bootstrap recognize only a receipt-bound released reservation. Use a
fresh exact-source intent via the supported task bootstrap for an old observer;
unknown effects remain blocked. Private capture mutations prove those refusals.

## Quiet Windows observation

Captured Sentinel probes and Git/Node verification commands use explicit
`CREATE_NO_WINDOW`: a detached observer must never repeatedly allocate consoles
or default-terminal windows merely to inspect state. The detached installer and
watcher keep their distinct lifetime flags. Windows liveness/IPv4+IPv6 listener
ownership use native handle/TCP-table APIs instead of spawning `tasklist`/`netstat`;
no PID/port success is cached. Superseded installed-source results refuse from
the fresh `installed.txt` identity before invoking the expensive verifier. Old
outcomes and unknown notification records remain intact, not silently settled.
Private regression compares an actual no-console child with a deliberately
console-creating negative control and native TCP listener/PID ownership.

## Console-independent Windows watcher start

The supported unmanaged `start`/`restart` path now uses native Win32 detached
process creation, not a PowerShell `Start-Process` hop. The watcher has no inherited
console, a separate process group, no inherited handles, and the existing lifetime
lock/readiness proof. This prevents an ordinary Ctrl-C in the launcher's console
from terminating the watcher; it is not crash recovery or a live SCM certification.
Direct `watch` remains a foreground diagnostic mode. The logon-task launcher uses
`start` and exits after readiness, instead of hosting a foreground watcher in CMD.

General in-turn `start`/`restart` still refuse; they can replace a live watcher.
**Restoring a proven stopped supervisor is different from replacing the node.**
An authorized operator agent must retain a recovery route even with a bound
workspace and stopped watcher: use the node-side shell and
`scripts/restore-sentinel-task.ps1 -RestoreOnly -ExpectedSha <main-sha>`.
`-Check` performs the same read-only preflight. No client, unbinding or run-marker
removal is needed. This starts ONLY the existing validated limited logon task,
under the same operator SID, after backing up its task/launcher. The task runs
outside the node's supervised process tree and executes installed supported
`start`; the helper never detaches a watcher itself or installs a binary.
Unknown/live watcher identity, SCM binding, intentional stop, unexpected task,
source drift or access denial still refuse. Such factual OS/identity failures
are exact blockers, not a blanket instruction to wait for a human.

`-RestoreOnly` creates no new deployment intent, clears no reservation and treats
unsettled installation records as preserved evidence—not a reason to forbid
restoring the observer that can reconcile them. Existing approved queue intake
may proceed; native installation admission still blocks an unsettled effect.
Without `-RestoreOnly`, the combined restore/deploy helper remains external and
requires `-ParentSession <id>` plus no unsettled prior installation reservation.
It preserves/backups the task/launcher, replaces foreground `watch` with supported
`start`, and queues exact new source when needed. It never registers a new task,
elevates, copies a binary or calls the installer. Intentional stop markers,
manager identity, queue contents and historical effect reservations remain binding.
After restoring the exact task, the normal queue installs published source while
idle. Existing queued source-bound requests remain immutable; if source changed
before any effect reservation, preserve their refusal and issue a fresh intent.

## Existing-task exact-source bootstrap

If the installed observer predates fixes required to admit the current published
build, use `scripts/bootstrap-sentinel-deploy.ps1 -Check -ExpectedSha <main>
-ParentSession <id>` first, then the same call without `-Check`. This reuses ONLY
the existing limited interactive logon task under the same SID: no registration,
elevation, binary copy, node stop, claim deletion or new recurring wake. It refuses
SCM/unknown task/action/active task, pending deploys, intentional stop, unsettled
reservation and source drift. Task XML and launcher are backed up; a one-shot
launcher restores its original bytes before calling the hash-pinned source-built
Sentinel. No installed UI or binaries are instrumented.

`protocol bootstrap --expected-sha <main> --owner <owner> --session <parent>
--reason <text>` is external-only. It waits for positive native idle evidence,
revalidates parent/hook/source/native target, reserves a fresh effect generation,
and launches only canonical `scripts/deploy.sh` through the same supported detached
path. A participating bootstrap lock and global effect reservation prevent a second
installer. Prior failed requests are not replayed. Admission or detached spawn is
not installation; raw receipt, installer result and fresh verifier remain required.
The observer remains live and is replaced only by the supported installer. The
bootstrap cannot start inside the node or a supervised run that it would wait on.
Failure restores the launcher but leaves all effects/unknowns for inspection.
Typed parent-owner/node-identity read-capacity refusal before `effect.json` waits
with backoff under the same intent ID. The bootstrap holds only that request's
observation lock during admission, preventing a held notice from waking its own
parent into the idle gap. On admission/failure it releases notification observation
normally. No other refusal, reserved effect or spawn is retried.

## Operating

```
wa-sentinel status   # the node, the watcher, who owns the watcher's lifecycle, the box, the wake budget, the job lanes' reservation, the last actions
wa-sentinel start    # start watching; where a unit owns the watcher this is the manager's restart of it
wa-sentinel stop     # stop it: the manager's stop when a unit owns the watcher, the stop file otherwise
wa-sentinel restart  # replace the running image: the manager's restart when a unit owns the watcher
wa-sentinel once     # handle the box once and exit - for tests and for cron
```

It is started by the installer. On a machine that runs a node for other people, run it under the
service manager alongside the node — it is the thing that has to survive the node, so it should not be
a child of it.

### Who owns the watcher

A lifecycle verb asks **who owns the running watcher**, never where the command was typed. The facts are
the running watcher's own control group (`/proc/<pid>/cgroup` for the pid in
`<config>/sentinel/sentinel.pid`), what the watcher recorded about itself when it took the role
(`<config>/sentinel/supervisor`), and `WA_SENTINEL_SUPERVISOR` — which states the fact when none of that
can be seen: `none` for a watcher started by hand on a machine that happens to run systemd, `user:<unit>`
for a user unit, a unit name, or `windows:<exact-service-name>` for Windows SCM.
Windows lifecycle verifies the configured image/name/home and never falls back to
an unmanaged watcher after access-denied or a mismatched binding.
So `wa-sentinel stop` in an operator's shell stops the *unit's* watcher,
and `wa-sentinel restart` there asks the manager instead of spawning a second watcher beside the unit's
own.

The unit is matched by what it is — the unit that owns the sentinel process — and never by its name: a
sentinel installed under any name is found, and `wa-supervisor.service` is not adopted for sounding
supervisory. A verb that finds itself inside a unit it cannot show owns the watcher **refuses**, names the
unit and changes nothing (a competitor watcher inside somebody else's control group is the flap this
exists to avoid); `WA_SENTINEL_SUPERVISOR=<unit>` hands that unit the role, and
`WA_SENTINEL_SUPERVISOR=none` says nothing outside owns the watcher. For the same reason a deploy is never
started inside the control group it must restart: it is started as a unit of its own, or it is refused
with the reason in its capture.

The **stop file** is the other mechanism, and it is a *request* rather than a stop: the running watcher
reads it and exits. Under `Restart=always` that is a restart, not a stop - the manager brings the watcher
back within `RestartSec` and the fresh watcher deletes the file as it starts. Reach for the file for a
watcher nothing outside owns (a `nohup`, a logon task); use `wa-sentinel stop` for a unit. It is also what
`deploy.sh` reads before deciding whether to start a watcher nobody asked for (`docs/JOBS.md`).

## What it deliberately does not do

- **No model, no Lua, no ledger.** It executes declared intents; it does not converse, decide, or write
  to the transcript. It is a supervisor, not a second agent.
- **No automatic node restarts.** An auto-restart nobody asked for fights the operator every time they stop
  a node on purpose. It reports an outage and waits to be asked. Explicitly configured OS recovery may
  restart the Sentinel itself after an unexpected failure; intentional stops remain respected.
- **No shell verbs.** A verb list, not a command line.

## For an agent

If you are running inside a run, **you cannot restart the node you are running on** — the stop kills
your run before your next command runs. Ask instead:

```bash
wa-sentinel request restart --reason "picking up the binary I just built"
```

Your run will die as `unfinished` when the node stops; that is expected, and the request is already on
disk. Write a `wake` request too if you want to be brought back to continue:

```bash
wa-sentinel request wake --session "$MY_SESSION" --prompt "the node restarted; carry on" --reason "self-update"
```

Both requests are durable, so the order you write them in is the order they will be performed.

## Managed jobs

For new automations use [JOBS.md](JOBS.md): durable definitions, default-off approval,
revision-pinned queues, enabled/disabled Engine controls after tools, file/schedule/event/CDP
sources, and either a skill-backed wake or deterministic allow-listed execution.
External process executions are **operations**, never jobs ([OPERATIONS.md](OPERATIONS.md)).
The runner holds an exclusive OS lock; interrupted deliveries are unknown and not replayed.

## Waking the model on an event (legacy triggers)

A trigger is a rule in `<config>/sentinel/triggers.json`. The trigger decides **when**; the verbs decide
what, and they are the same fixed list as everywhere else — so a trigger can never do anything an
operator could not ask for directly.

```json
[
  { "kind": "file", "path": "C:/Users/me/Downloads", "pattern": ".png",
    "session": "<session id>",
    "prompt": "a new file appeared in the download folder: {name}. Say what it is and whether it needs anything.",
    "reason": "download watcher" },

  { "kind": "health", "when": "down", "verb": "restart", "reason": "the node fell over" },

  { "kind": "schedule", "every_seconds": 21600, "session": "<session id>",
    "prompt": "summarise what happened in the ledger since the last check",
    "reason": "six-hourly summary" }
]
```

`{name}`, `{path}` and `{event}` are substituted into the prompt, so the model is told what happened
rather than asked to guess. Every firing goes through the same wake budget as a manual request: an event
storm must not be able to spend money quietly, which is the only thing here that costs anything.

The first pass after startup only *records* state — a sentinel started while the node is down must not
decide the node just fell over, and a directory full of old files must not fire once per file.

Three kinds are implemented: `file` (a directory, optionally filtered by a substring), `health` (the node
going down or coming up), and `schedule` (every N seconds). CDP, a webhook and the rendezvous events are
the obvious next ones and take the same shape — a watcher that calls `fire()`.

## Running it as a service

`deploy/wa-sentinel.service` is the systemd unit. Native Windows SCM integration,
least-privilege identity, failure recovery, intentional stops, external installer and
live-proof limits are in [WINDOWS-SENTINEL-SERVICE.md](WINDOWS-SENTINEL-SERVICE.md).
The existing logon task remains the fallback until SCM migration is actually proved;
no console executable is blindly registered as a service. It must not be a child of
the node: a supervisor that dies with the thing it supervises is decoration.

## Self-update — the `spell` verb

A plan the agent wrote, executed here because the node cannot execute it. `spells.lua` exports a
spell as portable JSON (`spell_export`, or `POST /spell/export`), and this verb runs it while the
node is being replaced — the one moment the node is the least able to act.

```
spell_export(name: "self-update", binary: "...")     # -> a path
wa-sentinel request spell --file <path> --reason "..."
```

A plan is **untrusted input**: the agent writes it, and this process is the thing that can restart
the node. So a step names a verb from a fixed list — `wait-idle | upgrade | restart | wait-health` —
and everything else is refused before a single step runs:

* an unknown verb, or **`run`** (the operator's script escape hatch);
* a `kind` other than `sentinel` (a client action belongs to the node; dropping it silently would
  make the plan do less than it says);
* an empty `steps`, an empty `post`, a missing `binary` on `upgrade`, a `binary` on a verb that
  takes none, or a `binary` path that does not exist.

`post` is required here for the same reason it is required in `spells.lua`: a plan that cannot state
its success condition cannot be settled, and "reported success while doing nothing" is the failure
mode both exist to prevent. The sentinel settles it with its own `/health` check — the assertion an
in-run agent cannot make about itself.

A refused plan is refused **whole**: nothing runs, so a half-executed plan is impossible.

### What the agent cannot do

An agent inside a run cannot restart the node it is running on, and cannot run a spell about that
node (`spell_run` returns `needs_sentinel`). It cannot read the result either: `/client`, `/spell`,
`/health`'s busy state and everything else that needs the interpreter queues behind the run
holding the worker, so a call the agent makes to its own node waits on itself. The route out is
always the same: **write a request and let this process do it.**

`run` is disabled unless `WA_SENTINEL_SCRIPTS` names the directories it may execute from — and note
that `spell` deliberately does not go through `run`, so enabling `run` does not widen what a plan
can do.

### Update-path speed, not release gating

Routine deployment does not run the private E2E fixture or full release gate.
The update still owns source provenance, idle safety, scratch startup, rollback,
artifact equality and fresh final verification; speed removes duplicate work,
not those boundaries. Exact-source proof brackets the verifier with two current
source/remote observations, instead of four identical nested checks. Windows
listener/watcher identities are observed in one native PowerShell invocation per
snapshot. Verifier JSON uses shell builtins rather than at least 525 formatting
subprocesses for 75 rows; all rows/counts and ordinary details are identical,
with control-character details preserved by JSON escaping.

Matched three-sample offline Windows measurements (`test-install-speed.mjs`):
75-row serialization median 10,840 ms -> 57 ms; native process pair median
468 ms -> 231 ms. Sample order alternates, but this is a microbenchmark, not a
full update or outage guarantee. Actual build/idle/install timing remains separate.
No production test/wake/job or extra default release gate is added.

### Historical upgrade timing

Measured on this machine, not estimated. The numbers matter because "seamless" is a claim about
seconds, so it should be a claim about *measured* seconds:

| what | cost |
| --- | --- |
| cold start (spawn → `/health` ok) | ~55 ms |
| kill → process gone | ~150 ms |
| `/health` round trip | ~0.6 ms |
| **whole cached upgrade command** | **~750 ms** |
| **node unreachable during it** | **~235 ms** |

The whole `upgrade.sh` run is ~750ms once the binary is known-good, and the *outage* — the window in
which the node answers nothing — is about a quarter of a second. That is what the window's version
poll (once a second, reconnecting by itself) turns into an unbroken transcript rather than a dead
page.

Four things were removed to get there, each found by timing the phase rather than guessing:

1. **A fixed `sleep 2` after the kill.** The process is gone in ~150 ms, so ~1.8 s per upgrade was
   spent asleep for nothing. It now polls the port until it is free, which also cannot be too short
   on a loaded machine.
2. **Polling with PowerShell.** `Get-NetTCPConnection` costs ~600 ms to start; `netstat -ano` costs
   ~40 ms for the same answer. Every port question — the free-port scan, the port-free wait — now
   goes through `netstat`, except the two that genuinely need Windows APIs (stop and start).
3. **A fixed 5 s idle tick.** Fine while a long run is in flight, ruinous at the moment it ends, because the
   swap cannot begin until a poll notices. It polls at 5 s while the node is known-busy, then at
   0.5 s.
4. **Re-proving the same binary every time.** A build that answered once answers forever — the same
   bytes cannot un-start. The verdict is cached by SHA-256 in `<install>/.upgrade-proof` (last 20
   hashes), which removes the ~20 s worst-case scratch-port proof from every upgrade after the
   first. Only *positive* verdicts are cached: a build that failed to answer is retried, because the
   failure may have been a busy machine rather than the binary.

What is left is two `powershell.exe` calls — one to stop by pid, one to start — because there is no
shell equivalent, and each carries a fixed ~600 ms of process start. That is the floor for this
approach, and it is why the outage is ~235 ms rather than ~55 ms: the start is fast, the *way we
start* is not.
