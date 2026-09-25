# WhatsApp Copilot

One feature, two job records. It reads the operator's WhatsApp store, decides which messages are
waiting on them, and answers those — or records, durably, why it did not.

## One job, and why one

A job is exactly **one trigger + one action**, and this pipeline is one `pipeline` action with four
steps: the deterministic ones first, judgement last.

| # | step | kind | what it is |
| --- | --- | --- | --- |
| 1 | `scripts/whatsapp-source-ensure.sh` | `run` | keeps the source up: Chrome on the agent profile, DevTools on 9222, the WhatsApp page bound |
| 2 | `scripts/whatsapp-transcribe.sh` | `run` | local speech-to-text for voice notes, sent back to the source chat (no model) |
| 3 | `scripts/whatsapp-copilot-read.sh` | `run`, `returns: events` | reads the store, diffs it against the cursor, hands on the eligible messages |
| 4 | `foreach` → `subagent` (`whatsapp-responder`) | judgement | answers one message: read, decide, and at most one verified reply |

This is what the `pipeline` kind exists for, and it keeps the things a single `run` script that started
its own children would lose:

- **only judgement costs a turn.** A tick with nothing eligible spawns no child at all: the `foreach`
  iterates the list step 3 handed on, and an empty list is no children.
- **the per-message delivery is kept**: the idempotency key (`job:revision:message_id`), cancel-on-disable
  of a running child, the bounded `await`, and `unknown`-never-replayed on timeout.
- **the order is the order they must run in**: the source is up before anything reads it, and the
  transcript exists before a child decides what a voice note is asking.

It was four records (`whatsapp-ingest`, `whatsapp-message`, `whatsapp-source`, `whatsapp-transcribe`)
plus two retired rows. One trigger, one action, one place to look and to polish.

**Turn the copilot on and off with `whatsapp-copilot`** — there is nothing else to switch.

## The free stage: the token gate

The rule lives in `scripts/whatsapp-eligibility.mjs` and runs in the ingest — a script, no model. A
message becomes an event only if it passes:

- **direct chats**: any new incoming message;
- **groups**: only a **verified mention** of the operator's own ids. `WA_WHATSAPP_OPERATOR` is the local
  binding that makes that check possible; without it no group mention can be verified and every group
  message is refused (`group_without_operator_mention`). Measured on the live store: 439 group messages
  refused, 1 mention eligible.
- **refused outright**: not incoming, archived, `archived_unknown`, `left`, statuses, broadcasts, and any
  chat whose metadata cannot be verified.

`left` is **derived**, not read: this app build exposes no `isLeft/left/hasLeft/isExited`, so
`scripts/whatsapp-read-core.mjs` decides it from what the build does expose — an explicit flag if one
ever appears, a direct chat is never left, a group is decided by its participant list, else by its own
`canSend` — and stays `null` (refused) when nothing is available.

## The window: how old a message may be

A cursor says *position*, not *age*, and that is the whole of this rule's reason to exist. After a lag - a busy
node, the source down, the job off, a restart - everything since the cursor looks new, so a three-hour-old
voice note was decrypted, transcribed and answered as if it had just arrived. Measured live: the reply cursor
was 50 minutes behind and the transcribe cursor hours behind, and the copilot transcribed four group voice
notes in one tick whose messages were sent three hours earlier.

So the deterministic rule carries an age bound, in `scripts/whatsapp-eligibility.mjs`, measured on **epoch
seconds against one clock** - the store's own `sent_at` and the process's `Date.now()`/`os.time()`. Nothing in
this path converts to a local wall clock, which is what makes the verdict identical in every time zone (the
suite proves that with two child processes in two zones, not by inspection).

| age of the message | direct chat | group mention |
| --- | --- | --- |
| ≤ 300 s | `direct_chat` — answered promptly | `operator_mentioned` |
| 300–600 s | `direct_unanswered_grace` — the operator has had their five minutes | `stale_group_mention` — refused |
| > 600 s | `stale_message` — refused, and not transcribed either | `stale_message` |

The two knobs are the job's own **controls** - `grace_seconds` (300) and `max_age_seconds` (600) - carried
in `jobs/whatsapp-copilot.json` and validated when the definition is installed
([JOBS.md](JOBS.md), "Controls"). The sentinel passes each of them to the pipeline's `run` steps as
`WA_JOB_CONTROL_GRACE_SECONDS` / `WA_JOB_CONTROL_MAX_AGE_SECONDS`; the reader resolves those first, then
the node's environment (`WA_WHATSAPP_GRACE_SECONDS` / `WA_WHATSAPP_MAX_AGE_SECONDS`, a machine-wide
override), then the constants in `scripts/whatsapp-eligibility.mjs`. The job record wins, because that is
the thing the operator edited and approved. The read step reports the window it applied and where each
number came from (the `window` field of its result, and one line on stderr), so which controls were in
force is read rather than inferred from a verdict - and a value that is not whole seconds is discarded in
favour of the next source instead of becoming a zero-second window. The prompt window is what is left of
the bound once the grace band is taken out of it, deliberately derived rather than a third knob that could
contradict the hard bound.
applies the same bound (`WA_WHATSAPP_TRANSCRIBE_MAX_AGE_SECONDS`, 600): audio past it is refused with a
durable `transcription_refused reason=stale_audio`, including notes queued in an earlier pass that have gone
stale since, and a refusal is what settles the message so the next pass cannot queue it again.

An unknown timestamp fails closed (`stale_unknown`), and a timestamp in the future is **skew**, not the
future: the sender's clock is ahead of ours, so the age floors at zero and a fresh message is never refused
because somebody else's phone is wrong. Both halves are asserted in `tests/whatsapp-eligibility.js`.

## The acted cursor: what may be consumed
`effect_decisions` row, a deterministic eligibility refusal, the operator having answered that
conversation first, or a media report. Handing a message *on* is not a decision — it used to be, and that
is how a message nobody acted on was lost: a child that failed before deciding left a message the cursor
had already passed.

So the reader keeps a durable list (`meta.whatsapp_handoffs`, keyed by message id) of what it has handed
on and how many times, and re-hands anything on that list without a decision — including messages *below*
the cursor. The child's idempotency key (`job:revision:message_id`) makes that a reconcile, not a second
child. The count is bounded (3), so a message that is never decided cannot pin the cursor for everything
behind it: it is reported to the operator's own inbox once and then let go.

Eligible `voice`, `ptt`, and `audio` messages are decrypted and transcribed locally with the native
`faster-whisper` engine before the reader records them or emits an event. `whatsapp_read` then supplies
the transcript in the conversation context before the child decides whether to reply. The transcript
is cached in the ledger so a rescan cannot replace it with `[voice]`. A temporary download or STT
failure fails the entire reader pass with the message id and step; the next tick retries before any
later message is handed to a responder. View-once audio, invalid media, and recordings with no speech
are reported as unanswerable. Images and other unsupported media are also reported, with no responder
event. See [local recognizer setup](WHATSAPP-TRANSCRIPTION.md) for the required Python environment and
offline model cache. Step 2 of the same job (`whatsapp-transcribe.sh`) sends each transcript back into
the source chat, deterministically and with no model. Because that reply is an outgoing message in that
conversation, the reader's operator-precedence rule makes step 4 stand down on it — so a voice note gets
the transcript rather than two messages.

**Standing down is reported too.** When the operator has taken a conversation over themselves, the copilot
does not answer — and that is a decision the operator cannot see: they observe no reply, and "the copilot
chose not to answer" is indistinguishable from "the copilot never saw the message". So every stand-down is
reported to the operator's own inbox, once per message (the stand-down clears the owed entry, so a later
pass cannot repeat it), naming the conversation, the message id and the moment the operator took over:
`did NOT answer the message in <conversation> (id <message id>) - you took that conversation over yourself`.
Bounded to three per pass, like every other report, and never sent to the sender.

## What the operator is told

A reply that goes out to somebody else is an effect on *their* conversation, and the operator reads their
own inbox, not the ledger — so every send is reported back to them, in one line, by the deterministic
step: `replied for you to <title> (id <message id>): "<what was said>"`. A send that did not confirm is
reported as **not sent** rather than not at all, which is the case that must never be quiet. The report is
bounded to three per pass, carries a **durable report cursor** (`meta.whatsapp_reported_at`) so the same
send is never announced twice, and is best-effort: a failed note does not fail the step.

It lives in the reader rather than in the child on purpose. A child's send budget is one, so a note home
would be a second send it is refused; and "what did the copilot send as me" is decidable from the effect
tables without a model. Child tokens are spent on judgement, never on bookkeeping.

`scripts/test-whatsapp-cursor.cjs` proves each of these against a mock store, the real ingest script and a
real ledger: no browser, no sentinel, no model.

## The paid stage: the child's envelope

Everything below is structural, not prompt-level.

| | |
| --- | --- |
| tools | `whatsapp_read`, `whatsapp_decide`, `whatsapp_send` — no bash, read, write, client, operation; `subagent` recursion is refused |
| scope | the conversations in the profile; a call may act only on the conversation its trusted event names, and a foreign argument is refused (`event_conversation_immutable`) |
| what it may see | the ledger conversation (messages **and its own title**), never the operator's other tools, memory or session |
| limits | 20 context messages, 1024-byte body, 1 send per run, 600 s, 60k tokens |
| model | `deepseek-v4.1-flash`, reasoning `low` — measured ≈ $0.000279 per decision (243 reasoning tokens vs 394 at `high`) |

The child is started by the **sentinel**, not by the agent: it calls the node's `/subagents` with the
profile, the prompt, `event: {message_id}` (the id only — the runtime resolves the conversation from the
ledger row) and `idempotency_key: <job>:<revision>:<event_id>`. A re-run reconciles the existing child
instead of spawning a second; a timeout is `unknown` and is never replayed; a job disabled or revised
mid-child cancels it.

**Durable effects.** A send is `reserve → send → confirm`. A crash between reserve and confirm leaves a
pending row, which returns `ambiguous` and is refused or reconciled — never retried. Decisions live in
their own table (`effect_decisions`), keyed by message id, so recording one can never erase a
reservation.

**Sending.** `send_path: ui` is the only route proven for a third-party chat, and it **opens the chat**,
which clears that chat's unread marker — accepted explicitly by the operator (`allow_mark_read: true`).
The route refuses to overwrite a draft, refuses a non-self send without that approval, and verifies the
sent message in the app's store: a keystroke's acknowledgement is not evidence (it has reported
`timeout: Input.dispatchKeyEvent` while the message verifiably delivered).

**Every reply announces itself.** The send tool puts the marker (`M.REPLY_PREFIX` in
`lua/core/whatsapp.lua`) at the very beginning of the body *before* it is reserved, sent and verified, so
the marker cannot be forgotten by a model, skipped by a route or dropped by a caller — and because the
store check compares the prefixed text, an unmarked reply cannot pass verification either. The marker is
an icon, the word `Copiloto` in WhatsApp's *italic* markup (`_Copiloto_`), and a newline, so it reads as a
header above the message rather than as the first words of it:

```
🤖 _Copiloto_
<what the copilot wrote>
```

A body that
already carries the prefix is left alone, never doubled. The wording is one constant and deliberately not a
profile field: a knob would be a second way for the marker to be absent.

## Operating it

```
wa-sentinel job list                 # one job: whatsapp-copilot (schedule, 30 s, pipeline)
wa-sentinel job enable|disable <id>  # the operator's switch; a changed definition needs re-approval
wa-sentinel job history              # one row per delivery
```

- **The source** is Chrome on the agent profile (`%LOCALAPPDATA%\AgentBrowserChromeProfile`) with
  `--remote-debugging-port=9222`; the reader and the reply script default to loopback `9222`
  (`WA_CDP_PORT` overrides). `bash scripts/whatsapp-preflight.sh` answers "is the chain up" in one line.
- **The source must be started by a task, not by a memory.** `scripts/install-whatsapp-chrome-task.ps1`
  writes the wrapper (`<install>/whatsapp-chrome.cmd`) and registers `wasm-agent-whatsapp-chrome` at
  logon; without it, a reboot leaves the job **enabled** (that flag is durable) while every delivery
  fails `no_cdp_endpoint` - the reader has nothing to read, and `job history` fills with
  `step 1 printed no JSON result` rather than with a reason. Run the installer once per machine, then
  `schtasks /Run /TN wasm-agent-whatsapp-chrome` (the wrapper is a no-op when 9222 is already listening).
- **Do not start that Chrome as a node operation.** A running operation makes the sentinel read the node
  as busy forever, which starves the inference lane — no child is ever claimed. Start it outside the node
  (the wrapper `%LOCALAPPDATA%\wasm-agent\whatsapp-chrome.cmd`, or the operator's own browser).
- **The sentinel must be running**, or no delivery executes at all (and its history will show the reader
  "completing" while nothing is read).
- **Children wait for idle.** The inference lane is only claimed when the node is idle, deliberately, so a
  child never pushes a person's turn aside.

## The source keeps itself up (deterministic)

`scripts/whatsapp-source-ensure.sh` starts the browser, and it starts it the only way that survives
**through the logon task**, because a browser spawned by an operation dies with the operation. One JSON
object on stdout (the `run` contract), human lines on stderr, exit 0 only when the chain answers by proof.
Idempotent: with the source up it is a single HTTP probe (~0.2 s), so a 120-second keeper is free.

| what is wrong | what it does | how it fails |
| --- | --- | --- |
| nothing on 9222 | starts the task, waits for DevTools | `cdp_never_answered` |
| 9222 held, DevTools dead, holder is **our** Chrome | kills that pid (its command line names the agent profile), starts fresh | — |
| 9222 held by anything else | refuses; the port is not ours to take | `port_held_by_other`, naming the pid |
| DevTools up, no WhatsApp page | opens the page over CDP (`/json/new`) | `no_whatsapp_page` |
| page up, store unreadable | waits, then reports | `store_unreadable_chats_zero` — needs a human: scan the QR once |
| the logon task is missing | refuses | `task_not_registered`, printing the installer command |

Nothing has to remember it. The **logon task** `wasm-agent-whatsapp-chrome` starts the wrapper at logon,
and step 1 of `whatsapp-copilot` re-runs this script on the **deterministic lane** on every tick — so a
person's turn never delays it and it costs no tokens. The agent's own surface
is the spell `whatsapp-source-up`: one `run` step with `expect {ok:true}` and a post-assertion that reads
`location.hostname` in the page, so a replay ends with the page *observed* rather than assumed.

Measured on this machine: with the source up, `already-up` in 0.18 s; after `taskkill` killed the browser,
one replay of the spell restored it in **68 s** and its post-assertion read `web.whatsapp.com`; a foreign
listener on 9222 was refused with its pid; a missing task was refused with the installer command; and the
installed wrapper, with no Chrome under `%ProgramFiles%`, printed the missing path and started nothing.
What is **not** covered by that matrix: a logged-out WhatsApp. It is detected and reported as such, but
reviving it needs a human with a phone — which is why the report says so instead of retrying.

## Failure modes this pipeline has already had

Each of these was found live, with evidence, and fixed. They are the reason the checks above exist.

1. **Every child was offered zero tool schemas.** `agent.lua` passed the profile's `allowed_tools`
   *list* to `tools.all_for`, which filters by *set*; the child's dispatch re-check read the set and
   passed. The model, told in prose which tool to use, emitted DeepSeek DSML markup as text, made no tool
   call, and the run ended having done nothing. Fixed by one tested derivation
   (`agent.subagent_tool_list`).
2. **The eligibility rule refused every chat.** `left` was read from fields this build does not have, so
5. **The reader's script must ship with the node - and so must what it imports.** `deploy.sh` ships
   `scripts/whatsapp-*` and `jobs/whatsapp-*.json` into the install; a reader that exists only in a
   checkout is not deployed. The second half of that sentence was paid for: `5cc38d1` moved the WebSocket
   runtime into `scripts/lib/websocket-runtime.mjs`, the install received the new `whatsapp-read.mjs` and
   no `lib/`, and every delivery then died at step 3 with `ERR_MODULE_NOT_FOUND` - 26 in a row, one per
   30 s tick - while `job history` was the only place that said so. The ship list now derives the modules
   from the shipped scripts' own imports, checks the install is import-closed, and refuses by name when it
   is not; `scripts/test-deploy-ship.sh` runs that block on a scratch tree, including both refusals.
6. **Old audio was transcribed and answered.** Nothing bounded the *age* of a message: the reader selects by
   cursor position, so a lag turned the backlog into "new", and the copilot transcribed four group voice
   notes in one tick whose messages were three hours old (the transcribe cursor was hours behind, the reply
   cursor 50 minutes behind). Fixed by the window above, applied to the reply rule and to the transcriber.

## Retired

Two job records are kept, **disabled**, labelled `(retired)` so the list is honest — the job CLI has no
delete verb (`list|history|put|enable|disable|export|import|emit|requirements`):

- **`whatsapp-events`** — a CDP page-event job (`wake` on a `wa_event` binding plus a document-start hook).
  Rejected as the source: the store route opens nothing and marks nothing read, while a UI-driven route
  clears unread markers, and the CDP hook drifts on every page reload (the preflight reports the pin as
  stale). The store reader replaced it. `whatsapp-ingest` needs no page hook.
- **`whatsapp-wake-selftest`** — a wake self-test on a `whatsapp.message` event, from the era when the
  ingest emitted on the wrong topic (`app.message`), which is why the reply job had never once been woken.
  The real pipeline supersedes it.

## What is proven, and what is not

- **Proven**: the reader reads the live store (`chats=677`) and eligibility passes; the scoped read
  returns real titles and kinds; a child gets real tool schemas and completes; a child records a durable
  decision (`effect_decisions`); the send route is store-verified end to end (notes-to-self); the gate is
  green.
- **Not proven**: a reply to a real third party. Nothing has been sent to anyone but the operator.
