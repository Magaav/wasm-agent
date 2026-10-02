# Jobs: events to deliberate automation

A **job** is a durable automation definition: trigger + action + enabled state.
A **trigger** matches an event or schedule. A **delivery** is one queued occurrence,
pinned to a job revision and stable source event id. An **operation** is supervised
external execution, not an automation rule. A wake starts an agent **run**; a
script need not start a run or call a model. See ARCHITECTURE.md section 6 and
[OPERATIONS.md](OPERATIONS.md).

## Ownership and scope

The sentinel observes sources and consumes a durable SQLite queue at
`<config>/sentinel/jobs.db`. The host exposes the same store through master-only
`GET /jobs` and `POST /jobs` (enable/disable, and a job's controls). The Engine lists jobs **after
tools**, with toggles, source state, queued count, last outcome and the exact definition; a job that
declares controls gets a field and a button per number. Neither a toggle nor a control is shown successful
until the server confirms it, and a refusal is shown in the store's own words.

Definitions are installed with `wa-sentinel job put <definition.json>`. New AND
edited definitions are disabled; an edit invalidates approval. Enable deliberately:

```
wa-sentinel job list
wa-sentinel job enable received-message
wa-sentinel job disable received-message
wa-sentinel job history
```

Disabling/re-enabling increments the revision and cancels pending deliveries.
Already admitted actions may have effects. Running scripts receive cancellation;
a submitted agent wake is not undone. Cancelled work is not replayed on re-enable.
The watcher must be running (`wa-sentinel watch` / the installed service).

This release is for an operator's own trusted local node. It is not a new customer
unattended-access grant. Broad local shell and CDP authority is still broad access.
No job is installed/enabled automatically and no real messaging account is touched
by the tests. The event sources never grant authority to their content.

## Example: a skill-backed agent wake

```json
{
  "id": "received-message",
  "name": "Review incoming messages",
  "trigger": {"kind": "event", "topic": "whatsapp.message"},
  "action": {
    "kind": "wake",
    "session": "the-agent-conversation-id",
    "skill": "review-message",
    "prompt": "Review the message under our approved policy. Draft a reply; do not send without approval."
  }
}
```

An adapter writes a JSON data file and submits it with its stable source id:

```
wa-sentinel job emit whatsapp.message message-unique-id payload.json
```

The sentinel puts the data in an explicitly untrusted block after the approved
instruction. `skill` asks the agent to load that named skill; it does not turn
untrusted message content into instructions or silently load memory.
The conversation goes in the chat body's `thread` field, not the authentication
session header. The distinction prevents wakes landing in the wrong conversation.
If local login requires authentication, `WA_SENTINEL_AUTH_SESSION` supplies that
separate credential; it is not taken from event data or logged.

## Deterministic execution without inference

```json
{
  "id": "new-document",
  "name": "Validate incoming document",
  "trigger": {"kind": "file", "path": "C:/approved/incoming", "pattern": ".json"},
  "action": {"kind": "run", "script": "C:/approved/procedures/validate.sh", "timeout_seconds": 60}
}
```

`WA_SENTINEL_SCRIPTS` must explicitly allow the script's canonical directory.
No shell text is accepted in an event, and event fields are never interpolated into
a shell command. `WA_JOB_EVENT_FILE` names the retained JSON event for the script.
The script runs as a bounded operation; its exit/output evidence is retained.
Scripts and their dependencies are operator-controlled files, not immutable signed
packages; editing them changes behavior. The allow-list is not an OS sandbox.
A successful exit is not a proof of business correctness: the reviewed script must
check its own postconditions.

## Controls: a named number a job carries

A deterministic step sometimes needs one number that is the operator's choice rather than the script's -
how old a message may be and still be answered, say. That is a **control**: a top-level `controls` object
on the definition, validated when the job is installed, and passed to every `run` step of the delivery as
an environment variable.

```json
{
  "id": "whatsapp-copilot",
  "name": "WhatsApp Copilot",
  "controls": {"grace_seconds": 300, "max_age_seconds": 600},
  "trigger": {"kind": "schedule", "every_seconds": 30},
  "action": {"kind": "pipeline", "steps": [
    {"kind": "run", "script": "<install>/scripts/whatsapp-copilot-read.sh", "timeout_seconds": 300}
  ]}
}
```

| control | whole seconds | floor | what it means to the WhatsApp pipeline |
| --- | --- | --- | --- |
| `grace_seconds` | 0–86400 | 0 | the operator's own answer window: how long a direct message is held before the copilot may take a turn (0 answers immediately), and the band after the prompt window in which a direct message the operator has not answered is still eligible |
| `max_age_seconds` | 1–86400 | 1 | the hard bound: past it nothing is answered and nothing is transcribed |

How it works, in four facts:

- **The name is the environment.** `grace_seconds` arrives in a step as `WA_JOB_CONTROL_GRACE_SECONDS`,
  `max_age_seconds` as `WA_JOB_CONTROL_MAX_AGE_SECONDS` (`wa_jobs::control_env`). The sentinel does not
  know what either number means; the step's own script decides.
- **Jobs may carry no others.** A name outside that pair is refused (`unknown_job_control:<name>`) rather
  than accepted and ignored: a job carrying a knob no step reads looks configured and is not. For the same
  reason a `wake` or `subagent` action - whose steps cannot read an environment - is refused
  (`job_controls_need_a_deterministic_action`).
- **The values are validated, not trusted.** A whole number in range, and `grace_seconds` may not exceed
  `max_age_seconds`: the prompt window is derived as what is left of the bound, so a grace band wider than
  the bound would make it silently empty. `max_age_seconds` of 0 is refused because a bound of zero refuses
  every message - a job that does nothing wearing the shape of one that works.
- **A delivery pins them with its revision.** The controls are carried in the delivery (`claimed["controls"]`),
  from the same definition row it was claimed against. Reading the current definition at execution time
  would apply a number that was never approved for that delivery.

They are portable with the job: `controls` survives export and import, and is re-validated on the way in
(see [ARTIFACTS.md](ARTIFACTS.md)).

### Setting them from the Engine

A control is the one part of a definition meant to be tuned, so the panel that lists jobs shows each
declared name with its value and a **Set controls** button, and
`POST /jobs` with `{"id":"whatsapp-copilot","action":"controls","controls":{...}}` moves them. Four rules
keep that surface from becoming a second, weaker way to edit a job:

- **The store is the only judge.** The panel sends what a field holds and copies no rule of its own: whole
  seconds, the ranges and the grace/bound relation are `validate_controls`' decisions, and a refusal travels
  back as `job_control_grace_exceeds_max_age_seconds` rather than a silent clamp. An empty field sends
  `null`, not a zero nobody typed, and is refused for the same reason a quoted number is.
- **It cannot touch anything else.** `Store::set_controls` re-reads the stored definition, replaces
  `controls` and writes it back: a route that shows two numbers cannot become a way to change an action, a
  trigger or a prompt.
- **It is an edit, and costs what an edit costs.** The revision moves, deliveries queued against the old
  revision are cancelled, and the job is left disabled. A bound the operator moved is a bound nobody
  re-approved, and the panel says so before the button is pressed. Setting the values the job already
  carries is a no-op, exactly as re-putting an identical definition is.
- **Master only, and it executes nothing.** The same route and role check as the toggle; what runs is the
  next delivery, in the pipeline's own step.

## Sources

* **event**: explicit local CLI ingress, a named topic and stable event id.
* **schedule**: `every_seconds` (1–31536000). First observation establishes the
  next due time. A long downtime coalesces missed ticks, not an inference storm.
* **file**: absolute directory, optional filename substring. Existing files are
  baselined on enable; new/modified files are identified by path/mtime/size. This
  is one-second polling, not guaranteed delivery of every intermediate filesystem
  write; a scan is limited to 10,000 entries. Filesystem reads run in independent
  observer threads, never on the control loop. A blocked OS read remains visibly
  `reading directory since ...` and consumes a source slot; safely replacing that
  thread requires an executor-process boundary not implemented here.
* **cdp**: an explicit loopback **page** WebSocket and a named Runtime binding:

```json
{
  "id": "page-events",
  "name": "Reviewed page adapter",
  "trigger": {
    "kind": "cdp",
    "websocket_url": "ws://127.0.0.1:9222/devtools/page/EXPLICIT-TARGET-ID",
    "binding": "wa_event"
  },
  "action": {"kind":"wake", "session":"conversation-id", "prompt":"Review this event as data."}
}
```

The sentinel enables Runtime and installs the named binding. A reviewed page
adapter calls:

```js
window.wa_event(JSON.stringify({id: sourceMessageId, data: {text: messageText}}));
```

Optional `setup_expression` is **operator-authored** JavaScript installing the
page-specific listener (e.g. a MutationObserver). It must be idempotent on reconnect.
There is deliberately no arbitrary-first-tab selection, injected universal scraper,
or claimed WhatsApp integration. Site adapters need stable identifiers, consent,
source-specific tests and review before enabling external effects. Navigation or
browser replacement may require reattaching the adapter/update of the explicit target.
CDP disconnects are visible; events during disconnection may be missed. For lossless
business events, the adapter needs a replayable source/outbox and acknowledgment;
raw browser notifications are not a durable message bus.

### The default path for page work is document start, not the UI

An adapter's job is to reach the page's own code, and the measurements now say plainly that driving the
UI is not a route: on WhatsApp Web the chat list is virtualised, its search box does not filter, its
`scrollTop` does nothing, and its keystrokes are dropped (of 112 backspaces, 56 landed; Enter timed out
while the message delivered). So a `setup_expression` should be a **document-start** script
(`Page.addScriptToEvaluateOnNewDocument`), which runs in the page's own world before the app's code -
the same layer a native DLL injection targets, without injection, a sandbox escape or a 32/64-bit
problem, and without putting a foreign library in the process holding the session. Three rules come
with it:

- **the script belongs to the CDP session.** Close the socket and it is gone before the app runs, which
  is why something persistent must hold the connection, and why a job turned on after being off has to
  rebind. `scripts/whatsapp-preflight.sh` is that check: browser reachable *by proof*, page present,
  hook bound - one line, with the reason when it cannot.
- **fail open.** The hook runs first, so a mistake breaks the page rather than the call.
- **verify by effect.** A call, a click or a keystroke can report failure while the effect happened.
  Ask the app's own state.

The names to call come from the app itself: wrap its module *define* call at document start and keep the
factories, so a module whose name cannot be guessed becomes known, and its factory source gives the call
shape. See `scripts/whatsapp-adapter.mjs` and the `automation-jobs` skill.

## Inference as a profile-scoped child run

A job that needs judgement uses a `subagent` action, not the operator's own chat:

```json
{
  "id": "whatsapp-message",
  "trigger": {"kind": "event", "topic": "whatsapp.message"},
  "action": {"kind": "subagent", "profile": "whatsapp-responder", "timeout_seconds": 900,
              "prompt": "Read the conversation, decide, and send only if the profile approves it."}
}
```

The sentinel POSTs the action to the node's local subagent service (`POST /subagents`), which owns the
child run and its **reserved capacity**. It never falls back to `/chat`: the point of the profile is that
the child cannot reach the operator's tools, and a fallback would hand it exactly those. The spawn is
idempotent on the delivery's stable source event id, so a restart reconciles the existing child instead of
starting a second one. A bounded wait that expires while the child is still running is recorded `unknown`
and never retried. A profile is a local approved config; artifact import installs it disabled, and the
profile's resources (the conversation, the destination, send approval) are bound locally before enable.
See [ARTIFACTS.md](ARTIFACTS.md).

Legacy `wake` remains a distinct action for the operator's own conversation. It is not a substitute for a
profile and never carries one's authority.

## The deterministic half of a wake: `prepare`

A `wake` may carry one extra field: a `prepare` script the sentinel runs **before** it submits the message.
What the script prints is parsed as JSON, and the `instruction` string it returns is injected into the
wake's own instructions - above the untrusted event block, never inside it. Nothing in the model turn then
has to re-derive what a diff and a set membership already decided.

```json
{
  "id": "onSubagentReturn",
  "name": "onSubagentReturn",
  "supersedes": "completion_wake",
  "trigger": {"kind": "event", "topic": "subagent.return"},
  "action": {
    "kind": "wake",
    "session": "COORDINATOR_SESSION_ID",
    "dedupe_key": "child_id",
    "prepare": {"script": "<install>/scripts/subagent-return-prepare.sh", "timeout_seconds": 120},
    "prompt": "...the fixed operating instruction..."
  }
}
```

Six rules keep it a step rather than a second action language:

- **It is a `run` step in everything the boundary cares about.** The script must be absolute and inside
  `WA_SENTINEL_SCRIPTS`, it is started through the same shell a `run` action uses, its timeout is bounded
  the same way, it receives the delivery's event as `WA_JOB_EVENT_FILE`, it is cancelled if the job is
  disabled or revised while it runs, and what it prints is its result. A step that prints no `instruction`,
  or no JSON at all, **fails the delivery**: a wake with an empty instruction in it is worse than no wake.
- **It exists only as a top-level `wake` action's own step, and that is refused at `job put`.** A
  `prepare` on a `run`, `subagent` or `pipeline` action - or inside a pipeline step - is refused by name
  (`prepare_is_only_for_a_wake_action`, `step_<n>_prepare_is_only_for_a_wake_action`) when the definition
  is installed, and again when it is executed. It used to be accepted at put and then silently ignored: the
  step's script never ran and the delivery reported success. `job import` is checked the same way.
- **It costs no model call.** The decidable half of the message is decided by a script; the wake that
  follows is the one budgeted turn, and it starts from the block instead of rebuilding it.
- **`dedupe_key` names the event field one message per subject is keyed on.** The store's own dedupe is
  `UNIQUE(job_id, revision, event_id)`, so editing a definition or re-enabling a job - both of which move
  the revision - starts a fresh, empty guarantee. With `"dedupe_key": "child_id"` the sentinel also keeps
  a ledger keyed on that field (`<sentinel>/wake-dedupe-<job id>.json`), and a delivery whose key is already
  in it completes without submitting a second message (`already_woken:<key>` in `job history`). The ledger
  is written only after a submission was confirmed, so the remaining window is a rare duplicate rather than
  a lost message; and it is **bounded to the newest 512 keys** (`WAKE_LEDGER_LIMIT`), so it is a file with
  a size rather than one entry per child ever woken. What the bound preserves: a child that settles again is
  still deduped while its key is inside the window - a continuation is a *new* child id, so a repeat of the
  same id is rare, and 512 woken children is far more than a node sees between two settles of one child.
  What it gives up: an id woken more than 512 wakes ago could be woken again if it somehow settled again.
  Like `prepare`, it is refused anywhere but a top-level `wake`.
- **`supersedes` is how a job replaces another notification path.** `"supersedes": "completion_wake"` makes
  the sentinel write `<sentinel>/completion-wake-superseded` (naming the enabled jobs, derived from the job
  store's own enabled state) and remove it when none is enabled. It is written by the watcher's tick **and
  by the `job enable`/`job disable` verbs themselves**, so the documented enable path has no window: a
  marker that only appeared on a tick left one in which a child settling between `job enable` and that tick
  was announced twice. `lua/core/completions.lua`'s `wa_completion_run` reads the marker and does **not**
  send its own `[Child completion notice]` wake for a settled child while it is present, recording
  `state='superseded'` on the outbox row instead. Without the marker nothing changes.

  The residual window is named rather than hidden: a toggle through the node's `/jobs` route (the Engine's
  switch) does not run the sentinel binary, so its marker arrives on the next watcher iteration -
  `std::thread::sleep(Duration::from_millis(200))` in `watch` (`rust/wa-sentinel/src/main.rs`), i.e. at most
  ~200 ms plus one tick's work, during which one settle could still be announced twice. Closing that too
  means the node's own toggle path writing the marker, which is `rust/wa-host`'s route and not this
  delivery's.
- **One place builds the message.** `wake_blocks` in `rust/wa-sentinel/src/jobs.rs` composes the
  instruction half of every wake. The child-return **notification** has moved into it: the hook's block
  carries a `notification:` line built from the same evaluation packet (state, session, model, provider,
  duration, usage, the outbox's own review verdict), so the message the hook sends *is* the notice, and the
  outbox one is suppressed rather than sent beside it.

### `onSubagentReturn`: the shipped hook, and what it decides

`jobs/on-subagent-return.json` is the hook: every settled child - completed, refused, cancelled, failed,
unknown - wakes the coordinator, with a block that names the child and its state, the notification facts,
its recorded branch, tip and worktree, the diff against `origin/main` measured in that worktree, a
**deploy verdict**, and the operating instruction for that verdict. `jobs/subagent-return-observe.json` is
its deterministic source: a 30-second `run` pass over the node's own record of its children
(`POST /subagents {action:"list"}` plus one `status` per settled child) that emits one `subagent.return`
event per child, keyed by the child's id. The pass writes a durable intent before each emission and
reconciles it afterwards through the store's own receipt (`wa-sentinel job receipt`), so a crash between
the two converges on the next pass instead of re-emitting that child for ever. Both definitions install
**disabled**, like every other definition: enabling is the operator's act.

The verdict is read from one declaration of what a deploy installs: `scripts/deploy-shipped.json`, which
`scripts/check-deploy-shipped.mjs` re-derives from `scripts/deploy.sh` and `scripts/upgrade.sh` on every
gate run and which the gate pins with a floor (`run_proof_fixture deployShipped 76`). The derivation reads
**every copy-like line** - `cp`, `cp -f`, `cp -R`, `install`, `mv`, and the `for source in` loops that feed
them - in every spelling the installers use (`"$ROOT/x"`, `"$ROOT"/x`, `$ROOT/x`), resolves the installer
variables whose value is a source path from the installer's own assignment, runs `scripts/ship-wave.mjs`
and checks every file it writes, and asserts a control set so the predicate cannot become "everything".

It refuses to pass a rule it cannot instantiate: a directory or glob with no example in the tree is
instantiated synthetically, and an exact path that neither exists nor is built by that same installer is a
**failure naming the path** - never a silent skip. A copied path under a `target/` directory is accepted
only for a crate the same installer builds (`cargo build --manifest-path "$ROOT/<crate>/Cargo.toml"`, with
comments stripped first), which is how the WhatsApp transcript plugin's build output is covered rather than
skipped. `node scripts/check-deploy-shipped.mjs --list` prints the whole derivation, rule by rule, for a
reviewer. This replaced a hand-written list that missed `jobs/**` and `scripts/upgrade.sh` - two classes a
deploy installs, both of which were answered `no install impact` - and then a first version of this check
that derived less than it claimed (the quote-then-slash spelling, plain `cp`/`install`, and absent paths
were invisible, so dropping `jobs/`, `scripts/whatsapp-*` or `scripts/subagent-return-*` from the manifest
stayed green). The suite falsifies all of those now: four manifest mutations and six installer mutations,
including a copy of a path that is not in the tree and a copy from a `target/` nobody builds.

A child that touched something a deploy ships (`ui/**`, `rust/**`, `lua/**`, `skills/**`, `jobs/**`,
`deploy/**`, or the `scripts/**` files a deploy copies) is `deploy required at the wave's end` - one deploy
at the end of the wave, never one per child, never from the child's branch; documentation and tests only is
`no install impact`. Everything that could not be measured is `cannot be computed`, never `no install
impact`: unreadable artifacts, a branch with no merge base against `origin/main` (there is no whole-tree
fallback), a checkout that reports uncommitted work the pass could not see, and a shipped-set manifest that
cannot be read. The uncommitted half counts: a child whose tip equals `main` and whose worktree holds an
uncommitted shipped change is deploy impact.
`scripts/test-subagent-return-hook.cjs` drives every state through a real sentinel, pins the dedupe key,
falsifies the manifest and the derivation, and shows the firing costs no provider call;
`scripts/test-completion-wake.cjs` shows the outbox going quiet while the hook's marker is present.

## Queue and recovery contract

`rust/wa-jobs` enforces durable deduplication on (job, revision, event id), atomic
claims and revision checks. The queue allows 128 pending deliveries globally and
8 per job. Full queues fail visibly and do not acknowledge ingestion: a **scheduled** tick whose queue is
full is backpressure instead - the interval is skipped, `source_status` says so, and the job's `next_at`
advances, because the deliveries already queued have not been consumed yet - while an external `emit`
still errors, so a message is never silently dropped. A queue that is full *because* nothing is being
claimed therefore no longer wedges the runner (live: the copilot's eight queued deliveries sat there,
every tick failing at the schedule step before either lane ran, until the job was disabled and enabled by
hand). Eight source observers (CDP/files
combined) are the current limit; one delivery per job runs at once.

**Two execution lanes, not one gate.** A deterministic `run` is claimed regardless of whether a person's
turn is in progress, so a scheduled ingest never stops because somebody is chatting
(`WA_SENTINEL_JOB_DETERMINISTIC_CONCURRENCY`, default 4). An inference action (`wake` or `subagent`) is
claimed only when its own lane has capacity (`WA_SENTINEL_JOB_WAKE_CONCURRENCY`, default 1): the subagent
service's reserved child capacity, or - until that is configured - an idle node, so a wake cannot queue a
person's turn behind it. The reservation is `WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY`: a scheduled task
cannot set a child's environment, so `scripts/install-sentinel-task.ps1` sets it in the launcher, and it
also writes it durably to `<sentinel>/child-capacity`, because the launcher is only how the value
*arrives*. `deploy.sh` restarts a watching sentinel with `wa-sentinel restart` and a hand-run
`wa-sentinel start` inherits the caller's shell; neither goes through the launcher, and a watcher that
reads the reservation from its own environment alone comes up idle-gated with nothing to say so (the
copilot's deliveries sat `queued` while a turn ran, runs 470-472). So the environment is consulted first
and the file is the installation's default, `wa-sentinel start` passes the resolved number to the watcher
it spawns, and `wa-sentinel status` prints it with its source (`jobs: reserved child capacity 1 (file)`).
**An inference delivery sitting `queued` while a turn is running is an unconfigured reservation, not the
design**: the lane is idle-gated only until the capacity is advertised. A wake without it waits in the
durable queue and is never failed for it.

Wake admission is budgeted (`WA_SENTINEL_WAKE_BUDGET`, default 6/hour). Claims
reserve job budget; the common wake submission gate counts failed attempts too,
serializes reservations, and records before HTTP submission. A timeout/EOF without
`done` is not success. Only a root `type: done` event indicates completion, never
matching text inside an event. Observation bounds each SSE line to 1 MiB and the
stream to 8 MiB; exceeding either reports an unknown outcome.
**Never retry an ambiguous model submission automatically.**

An exclusive OS runner lock prevents two watchers consuming/observing concurrently.
After acquiring it on restart, previously running deliveries become `unknown`,
not queued. The operator reconciles effects before deciding whether to retry.
Queued records survive restart. Definitions, delivery history, source cursors and
operation artifacts are retained; automatic retention/total disk quotas are not
implemented. Queue bounds are not storage-retention bounds.

Legacy `triggers.json` remains supported for existing installations. It is not
silently imported into jobs, does not appear as an approved enabled job, and
retains its legacy semantics. Prefer new jobs for new automations.

## Portable artifacts

A job can be exported as a versioned, machine-independent artifact and imported elsewhere with explicit
local bindings and approval. Importing installs the job disabled; an identical import is a revision no-op.
See [ARTIFACTS.md](ARTIFACTS.md).

## WhatsApp: eligibility before a model turn

The declared pipeline is deterministic first. `scripts/whatsapp-read.mjs` reads the app's own store,
attaches verified adapter metadata and applies `scripts/whatsapp-eligibility.mjs` to every message:

- the chat's kind comes from its **id suffix**, never from its title or a group label;
- direct chats are eligible; archived and left chats are excluded;
- a group is eligible only on a verifiable operator mention (the app's mention list, or a literal
  `@<bound number>`);
- if this build does not expose archived/left (or mention) metadata, the message **fails closed** with a
  reason. Unknown is not "no".

Only an eligible incoming message produces a `whatsapp.message` event, so the reply profile never spends a
turn on group chatter or a chat the operator has archived. The send itself is serialized across jobs and
processes by `scripts/whatsapp-sendlock.mjs`, prechecks a human draft (refusing to overwrite it), compares
the **whole** composer rather than a preview, and reconciles an ambiguous send against the store before
any retry - an ambiguous send is never retried.

## Proof

`cargo test --manifest-path rust/Cargo.toml -p wa-jobs --offline` checks default-off, revision
invalidation, deduplication, queue limits, concurrent claims, budgets, deterministic actions,
controls (the two names, their ranges, the refusal of a control no step could read, the delivery
carrying the values of the revision it was claimed against, and a control moved from the surface -
an edit's cost, the same refusals, and the rest of the definition unchanged), schedule persistence
and interrupted-delivery ambiguity.
`scripts/test-jobs.cjs`
uses scratch homes, a fake local chat receiver and a real isolated Chrome page.
`scripts/test-ui.ps1` checks the jobs position, safe rendering, toggle request and
failure behavior in a real browser, and that a declared control is shown with its value, posted as the
number the field holds, and that its refusal comes back in the store's words.
None of these tests is a paid-model benchmark or permission to send a real WhatsApp reply.
