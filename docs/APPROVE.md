# Operator approval of outgoing WhatsApp drafts

The switch the owner asked for on 13/11: an outgoing WhatsApp message can **stop before it is queued**
and wait for a person to send it as it is, edit it, or reject it — so "let the agent talk on its own"
becomes a decision taken with evidence instead of a guess.

Two facts shape everything below:

* **The model is not told to ask.** There is no sentence in any prompt that says "request approval".
  The gate is in code, at the one place a send arrives, and it applies to a model that has never heard
  of it — including one inside a code-mode script and one on a different node.
* **The gate is one choke point.** It is the account node's enqueue
  (`rust/wa-capabilities/src/whatsapp_send.rs`), which is where a send from anywhere in the fleet ends
  after routing to the node that holds the account. Not a user hook (a node without the hook config
  would bypass it) and not a per-caller setting (a second node would keep sending).

```text
tool mcp_whatsapp_send {chat, text}          (any node, any script, any model)
  -> routed to the node that holds the account
  -> validate the exact JID and the text      (wa-whatsapp-outbox, unchanged)
  -> this node runs no wa-whatsapp?           (unchanged: nothing is drafted where nothing can send)
  -> approval::gate(chat)                     OFF: the send continues exactly as before
                                              ON : NOTHING is queued. The answer is
                                                   {state:"pending", draft:"d-…", approval:"waiting"}
                                                   and the caller waits on that handle
operator: /approve send|edit|reject <handle>
  -> the policy check and the enqueue, once   (whatsapp_send::commit - the same path as any send)
  -> the draft settles, and the caller's handle answers it
```

## The switch

Per node, under the node's one root (`docs/ONEROOT.md`): `<state root>/approve/policy.json`.

```json
{"version":1,"on":false,"mode":"all","chats":[],"updated_at":0}
```

| `mode` | what it gates |
| --- | --- |
| `all` | every chat |
| `only` | nothing but the chats in `chats` |
| `except` | every chat except the chats in `chats` |

**The default is `on: false`** — today's behaviour — and a file that is absent, unreadable or not JSON
reads as OFF. That is the one direction a broken switch may fail in: a message the operator wanted to
approve going out is a surprise, one that waits for a decision is not. A mode a hand edit left
unreadable reads as `all` for the same reason.

`chats` holds **exact JIDs**, not names: the rule that decides a send is the outbox's own exact-JID
rule, and a name is resolved to a JID by the operator's command before it is written (the ranking is
`mcp_whatsapp_contacts`; an ambiguous name is refused with its candidates, never picked).

The policy lives on the **account node** — the one whose `whatsapp_send` reads it — so `/approve` on
any node writes it there, through the ordinary routed call. A policy on a node that holds no account
is read by nobody and would be a false promise.

## The drafts

`<state root>/approve/drafts/<handle>.json`, one atomic file each (write, then rename):

```json
{"handle":"d-6602d4c5917781bfac80","state":"pending","chat":"5511999999999@lid","text":"bom dia",
 "created_at":1794597530,"job":null,"message_id":null,"outcome":null,"final":null,"note":null}
```

`state` is `pending`, then `sent`, `rejected`, `cancelled` — or `failed` when the decision itself was
refused (a spent policy budget, a bad edit). `outcome` is what the *operator* did: `unchanged`,
`edited`, `rejected`, `cancelled`. `final` is the exact text that was sent.

Why files and not jobs on the queue: the queue's contract is "the producer wrote it, the worker settles
it, nobody edits it", and a draft is exactly the thing a person edits. It also has to survive a restart,
be readable by an operator while no worker runs, and never look like a message somebody already asked to
send.

A draft does not expire. "Never sent until decided" is the whole promise, so nothing in this feature
sends on a timer; a draft an operator never looks at stays `pending` and says so in `/approve list`.

## What the agent sees

`mcp_whatsapp_send({chat, text})` under approval answers, instead of a job:

```json
{"ok":true,"state":"pending","draft":"d-6602d4c5917781bfac80","approval":"waiting",
 "chat":"5511999999999@lid","effect":"none",
 "note":"approval is on for this chat: nothing was queued. The message is a draft until the operator decides it.",
 "resume":"mcp_whatsapp_send({draft:\"d-6602d4c5917781bfac80\", wait_s:60})"}
```

The handle settles one of four ways, and `effect: "none"` on the pending answer is true: nothing was
queued.

| what the operator did | what the agent reads |
| --- | --- |
| sent it as it was written | `{state:"done", outcome:"unchanged", message_id, draft, id}` |
| sent their edit | `{state:"done", outcome:"edited", message_id, draft, id, text:<final>}` |
| rejected it | `{state:"rejected", outcome:"rejected", draft, note:<the operator's words>}` |
| cancelled it | `{state:"cancelled", outcome:"cancelled", draft}` |
| has not decided yet | `{state:"pending", draft, approval:"waiting", waited_s, resume}` |

`mcp_whatsapp_send({draft})` is the resume: it reads, it never sends, and the resumed call is what the
sandbox's `wait(op)` uses. Inside a script the op is `draft-<handle>`, so `wait`, `pending` and
`cancel` all work — and **a draft can be cancelled**, because nothing was sent yet. A queued message
keeps the old answer (`a sent message stays sent`).

## Deciding

`/approve` in `wa chat`, `wa approve` on the CLI. Both talk to the account node; both print what it
answered.

```
/approve                       the switch, the rule, and how many drafts wait
/approve on | off              every chat waits / sends go out as written
/approve on only <chat>,...    only these chats wait
/approve on except <chat>,...  every chat but these waits
/approve only <chat>,...       the same, and switches approval ON
/approve any                   back to every chat, leaving the switch as it is
/approve list                  every draft, its state, its chat and its text
/approve review                the balloon, one draft at a time
/approve show <handle>         one draft
/approve send <handle>         send it as it is
/approve edit <handle>         send the operator's text (the balloon asks for it)
/approve reject <handle> [note]  nothing is sent; the note goes back to the agent
/approve cancel <handle>       drop it: nothing is sent and nobody has to decide it
```

`<chat>` is an exact JID (`<digits>@s.whatsapp.net`, `@lid`, `@g.us`) or a name this index knows.

**The balloon** (`lua/core/balloon.lua`, the shared overlay) shows the draft — chat by name and JID,
the text, the first link when there is one, and how long it has waited — with three keys:

| key | option | what it does |
| --- | --- | --- |
| `Enter` | Send as is | the first option, so Enter is the decision |
| `e` | Edit the text | a field with **the draft in it**: an edit in place, not a retype |
| `r` | Reject with a note | a field for the words the agent gets back |

The letters are named **by the page** (`keys` in the panel spec), so no other balloon grows them; the
numbers work too, and so do the arrows. Esc leaves the draft unsent — a reader who is not sure is never
made to decide.

The edit field is one line (`input: "line"`, which keeps a sentence's spaces; the older `text` field
strips whitespace and is unchanged). A multi-line draft is edited as one line: what the operator types
is the text that is sent.

**No terminal attached** (a self-wake, an agent on another node): nothing is drawn and nothing is
asked. The draft waits in the queue, `/approve list` shows it, and it is never sent until a person
decides. The pages are also published mid-run (`host.local_view`), so a run in flight can show the draft
and queue the decision as a line for the next turn instead of interrupting the stream.

## The evaluation record

Each decision is one line in the harness evaluator's own store (gitignored, never published, never
logged anywhere else):

`<evaluator state>/approve/decisions.jsonl`

```json
{"at":1794597530,"draft_handle":"d-6602…","chat_hash":"<sha256 of the JID>","outcome":"edited",
 "edit_distance":12,"decided_after_ms":41000,"draft":"…","final":"…"}
```

`wa eval report` prints the approval section after the runs:

```
approval decisions (3 recorded)
  9f2c1a77d0e4  3 drafts: 33% unchanged, 67% edited, 0% rejected, median edit 12 chars
```

Per chat, how often the draft went out as written, how often it was edited and how far, and how often
it was rejected — the number the decision "full autonomy or not" is taken on. The chat is a **digest**,
never the JID; the draft and the final text are kept, because they are the evidence.

## Bounds, and what this does not do

* The send is charged, audited and rate-limited **when the operator decides**, not when the draft was
  written: `commit` is the policy check and the enqueue, and it runs once per message.
* A decision that the policy refuses settles the draft `failed` with the policy's own word — never a
  silent drop.
* The outbox carries **text** (and a quote/mentions). "Media/link preview" in the balloon is therefore
  a link found in the text plus an explicit `media none: this send carries text only` line, not a
  claim about an attachment.
* `wa approve` and `/approve` are the CLI and the console's; the web window does not list `/approve`
  yet (the command parity check allows the CLI to offer more than the window does).
* Approval is per node and per chat. There is no per-agent or per-script switch: one gate, one rule.

## Tests

* `rust/wa-capabilities/src/whatsapp_approve.rs` — the modes, the default, the draft store, a handle
  that is a name and never a path, the three decisions, the refusals, the switch written where the
  gate reads it.
* `rust/wa-term/src/terminal_editor.rs` — a line field that keeps spaces and starts from its value, and
  letter keys only where a page names them.
* `scripts/test-approve.lua` — over the real capabilities in a scratch home: off/on, per-chat rules, a
  send from a second node, a send from inside a code-mode script (and its op's wait/pending/cancel),
  the queue without a terminal and across a restart, the three outcomes and their exact strings, and
  the evaluation record.
