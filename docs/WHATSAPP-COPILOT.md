# WhatsApp Copilot

One feature, two job records. It reads the operator's WhatsApp store, decides which messages are
waiting on them, and answers those — or records, durably, why it did not.

## Why two records and not one

A job is exactly **one trigger + one action**, and this pipeline has two stages with different triggers:

| record | trigger | action | what it is |
| --- | --- | --- | --- |
| `whatsapp-ingest` — "WhatsApp Copilot - reader (local audio, every 30 sec)" | `schedule`, 30 s | `run` → `scripts/whatsapp-ingest-emit.sh` | reads the store, transcribes eligible audio locally, and emits an event only after its ledger row contains the transcript |
| `whatsapp-message` — "WhatsApp Copilot" | `event`, topic `whatsapp.message` | `subagent`, profile `whatsapp-responder` | answers one message: read, decide, and at most one verified reply |

Collapsing them is not possible without losing something real:

- A single schedule-triggered child would spend a model turn every tick even when nothing arrived, and a
  child's tools are bound to **one** message by a trusted event — it cannot answer several.
- A single `run` script that started children itself would lose the per-message delivery: the
  idempotency key (`job:revision:event_id`), the cancel-on-disable of a running child, the bounded
  `await`, and `unknown`-never-replayed on timeout.

So: **turn the feature on and off with `whatsapp-message`.** The reader is the free stage; leave it on
while the copilot is on. With the copilot off, `emit` finds no enabled subscriber and enqueues nothing,
so the paid stage stops cleanly.

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

The cursor (`whatsapp_cursor`) means a restart does not replay the backlog: only messages newer than the
last pass emit. The first pass after a long outage therefore imports without answering — it adopts the
newest message as the cursor and hands nothing on, which in the pipeline mode is also the only thing that
moves the cursor off zero.

## The acted cursor: what may be consumed

The cursor moves past a message only when a **durable decision** exists for it: a child's
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
offline model cache. The standalone `whatsapp-transcribe` job additionally sends transcripts directly
to source chats; leave it disabled when using the copilot's inference path to avoid duplicate replies.

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
wa-sentinel job list                 # ON: whatsapp-message (the copilot), whatsapp-ingest (the reader)
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
and the keeper job `whatsapp-source` (schedule, 120 s, action `run`) re-runs this script on the
**deterministic lane** — so a person's turn never delays it and it costs no tokens. The agent's own surface
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
   all 677 chats were `left_unknown`: `eligible=0`, zero events, a pipeline that was enabled and silent.
   Fixed by deriving `left` (`scripts/whatsapp-read-core.mjs`); live result `eligible=0 → 267`.
3. **A running operation starved the child lane** (see above) — the fix is not to create one.
4. **A child could not name the conversation it answered.** `whatsapp_read` returned the id and the
   messages and no title, so labels were inferred from content: a group was reported as
   "futebol/bet" whose title is "A Casa Lar | 🏠", and "vizinhos" was really "Os Menezes". Fixed by
   returning the ledger's own `title` and `kind`.
5. **The reader's script must ship with the node.** `deploy.sh` ships `scripts/whatsapp-*` and
   `jobs/whatsapp-*.json` into the install; a reader that exists only in a checkout is not deployed.

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
