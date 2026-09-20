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
`GET /jobs` and `POST /jobs` (enable/disable). The Engine lists jobs **after tools**,
with toggles, source state, queued count, last outcome and the exact definition.
A toggle is not shown successful until the server confirms it.

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

## Sources

* **event**: explicit local CLI ingress, a named topic and stable event id.
* **schedule**: `every_seconds` (1–31536000). First observation establishes the
  next due time. A long downtime coalesces missed ticks, not an inference storm.
* **file**: absolute directory, optional filename substring. Existing files are
  baselined on enable; new/modified files are identified by path/mtime/size. This
  is polling, not guaranteed delivery of every intermediate filesystem write.
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

## Queue and recovery contract

`rust/wa-jobs` enforces durable deduplication on (job, revision, event id), atomic
claims and revision checks. The queue allows 128 pending deliveries globally and
8 per job. Full queues fail visibly and do not acknowledge ingestion. Four action
workers and eight CDP observers are the current limits; one delivery per job runs
at once. Schedules/files are polled by the watcher; CDP listens independently.

Wake admission is budgeted (`WA_SENTINEL_WAKE_BUDGET`, default 6/hour). Claims
reserve job budget; the common wake submission gate counts failed attempts too,
serializes reservations, and records before HTTP submission. A timeout/EOF without
`done` is not success. **Never retry an ambiguous model submission automatically.**

An exclusive OS runner lock prevents two watchers consuming/observing concurrently.
After acquiring it on restart, previously running deliveries become `unknown`,
not queued. The operator reconciles effects before deciding whether to retry.
Queued records survive restart. Definitions, delivery history, source cursors and
operation artifacts are retained; automatic retention/total disk quotas are not
implemented. Queue bounds are not storage-retention bounds.

Legacy `triggers.json` remains supported for existing installations. It is not
silently imported into jobs, does not appear as an approved enabled job, and
retains its legacy semantics. Prefer new jobs for new automations.

## Proof

`cargo test -p wa-jobs --offline` checks default-off, revision invalidation,
deduplication, queue limits, concurrent claims, budgets, deterministic actions,
schedule persistence and interrupted-delivery ambiguity. `scripts/test-jobs.cjs`
uses scratch homes, a fake local chat receiver and a real isolated Chrome page.
`scripts/test-ui.ps1` checks the jobs position, safe rendering, toggle request and
failure behavior in a real browser. None of these tests is a paid-model benchmark
or permission to send a real WhatsApp reply.
