# whatsapp-leaves-the-host — the first slice: the op moves off the host's enum

Branch `change/whatsapp-leaves-the-host`, base `70eb209d`. Plan and the full measurement table:
`~/Work/missions/whatsapp-leaves-the-host/ready-whatsapp-move.md` (mission dir, not the repo).
The slice is commit **1fc54f29**: `rust/wa-capabilities/src/whatsapp_query.rs` +65/−6,
`whatsapp_query/tests.rs` +61, `rust/wa-whatsapp-index/src/lib.rs` +11/−2,
`scripts/test-whatsapp-reactions-op-data.lua` +104 (`git log -1 --numstat 1fc54f29`).

## 1. Why this op, and what actually forced a host rebuild

The brief's premise "the move must thin the glue (host.rs/capabilities.rs)" is half right, and the half
that is wrong is the important one:

- `rg -c -i whatsapp rust/wa-capabilities/src/host.rs` = **0**: `host.rs` carries no WhatsApp at all.
- The glue is **12 rows** in `capabilities.rs` (`:246-`:268) plus, for each row, a variant of the op
  enum in the shared crate and a one-line bind in a `whatsapp_*.rs`.
- Those rows are part of `capabilities::digest()` (`rust/wa-capabilities/src/capabilities.rs:373-385`),
  and `rust/wa-host/src/main.rs:127-129` refuses an installed `lua-core` tree whose capability digest
  differs. That fast path exists since **e5975c29** (05/11) and was hardened by **9b7ce95d** (10/11).

So a Lua-only WhatsApp change **already** ships without a host rebuild, contrary to `ready-map.md` §3;
what forces the rebuild is that the hub crate *names* the ops and any change to a row moves the digest.
The query family is already a forwarder: `whatsapp_query.rs` enqueues on `wa:queue`'s `whatsapp.query`
and the `wa-whatsapp` component settles (`rust/components/wa-whatsapp/src/guest.rs:2101-2145`).

Also measured, and missing from the brief: `whatsapp_archive.rs` is a **fourth** WhatsApp module in the
hub (**383** lines, `wc -l`) on top of the 1,760 the brief counted.

## 2. What the slice changes

`host.whatsapp_reactions` — a tool the model really calls (`mcp_whatsapp_reactions`,
`lua/core/whatsapp.lua:108`) — is the first op **named as data**:

- `reactions(l)` is now `answer_text(l, "reactions")` (1fc54f29). `answer_text` parses the arguments,
  builds the same `seam::Request` with the op as a string, and `Request::validate()` — the same function
  the component uses — parses and bounds it. Everything after validation is today's code path unchanged
  (`enqueue`, `settle`, `settled_answer`, `refused`), because `validate()` hands back the parsed
  `seam::Op`.
- `seam::refusal_text` is the enum-free twin of `seam::refusal`, and `seam::refusal` now **delegates**
  to it, so the two cannot drift (1fc54f29: `rust/wa-whatsapp-index/src/lib.rs`). `component_absent`
  delegates to `component_absent_text` for the same reason.
- The other eleven rows, every capability description and the model's tool catalogue are untouched.

## 3. The rows, and what each one can and cannot prove

**R1 — Rust, `the_op_named_as_data_answers_the_same_bytes_as_the_typed_op`** (1fc54f29,
`rust/wa-capabilities/src/whatsapp_query/tests.rs`). Drives the typed path and the data path against two
caller-owned queues (the existing fixture: the queue library itself at `wa_kernel_runtime::queue_host`,
one grant registered the way the component's manifest does it) and asserts: the same "still running"
answer bytes, the **same job payload** on the wire, the same `bad_chat` refusal, that an unknown op
writes **no** job (`stats(seam::QUEUE).ready` unchanged), and that a settled answer comes back as the
component wrote it. Run: `cargo test -p wa-capabilities --lib whatsapp` → **42 passed, 0 failed**.

**R2 — Lua, the product's interpreter** (`scripts/test-whatsapp-reactions-op-data.lua`, 15 checks,
1fc54f29). On a scratch `WASM_AGENT_HOME` (the row refuses the operator store by name), through the real
capability `host.whatsapp_reactions` and the tool facade's own `M.invoke`: the golden documents below
were captured from the **base binary** (`wasm-agent v0.1.2 · va1857d15 · tree 70eb209d`) and are asserted
verbatim after the change, plus the dedupe promise (the same question reads the same job — the one thing
the op-as-data path could have broken silently).

**What R2 cannot prove, stated plainly:** it is a *parity* row. It passes on the base by construction —
and I ran it against the installed base binary (`~/.local/bin/wa`, `va1857d15`) to prove the golden is
really the base's output: `whatsapp reactions op data ok (15 checks)` there too. R1 is the row that
discriminates (on the base the functions it drives do not exist).

**MODEL-AGNOSTIC RULE, measured both sides:**
| what | base binary | this commit |
|---|---|---|
| `wa capabilities --json` (operator inventory) | sha256 `cee0c602…911e0d28` | **same** (diff empty) |
| `whatsapp.schemas()` — the tool catalogue the model reads | sha256 `2a17427d…65e8c111b` | **same** (diff empty) |
| `mcp_whatsapp_reactions` answer, three shapes | golden documents (§4) | byte-identical |
| rounds, tokens, wall time | — | untouched: no prompt text, no description, no argument changed |

The inventory digest is the load-bearing one: because it did not move, an installed `lua-core` tree keeps
running on a binary from this branch (`main.rs:127`), and the sandbox's `capabilities()` and effect
classes are unchanged.

## 4. The golden bytes (captured from the base binary, asserted after)

    {"detail":"one message: pass chat and id","effect":"none","error":"whatsapp_reactions_chat_and_id_required","ok":false,"op":"reactions"}
    {"detail":"chat JID contains whitespace or a control character","effect":"none","error":"whatsapp_reactions_bad_chat","ok":false,"op":"reactions"}
    {"detail":"the wa-whatsapp component has not answered yet; the same call reads the same job","effect":"none","error":"whatsapp_reactions_slow","id":1,"ok":false,"op":"reactions","retry":true,"state":"queued"}

The first two documents are asserted **as bytes**; the third is asserted field by field, because its
`id` is the job's number and the row's promise there is the one the queue makes: the id is a positive
number, and a repeated identical call reads the **same** job (that is the dedupe key surviving the move).
`15550000001@lid` is a synthetic 555 number: no account, no phone, and the row never reaches the network
(with no `wa-whatsapp` component on a scratch node, the third answer is a job on that node's own queue
that nothing settles).

## 5. The count: commits that would stop rebuilding the host

Method: one row per commit (`git log --since=30.days --format='@@%H' --name-only`); a commit counts as
kept out when every file it touches is in the removable set and no file is a host-rebuild trigger (any
`rust/wa-*` crate, but **not** `rust/components/*` — wasm, reached through `components.lock` — and not
`lua/`, which the Lua-tree path ships).

| tier | removable set | kept out (30 d) | of the 19 in-hub WhatsApp commits |
|---|---|---|---|
| **A**, this slice's target | `whatsapp_query{,.d/tests}.rs` + `wa-whatsapp-index` | **4**: 626a3339, d598dd92, 14bd0013, 514a1c41 (+86863aa8 repo-wide) | 4 of 19 |
| B, needs the policy/fs/approval gap closed | + `whatsapp_send/approve/archive.rs`, `wa-whatsapp-outbox/-archive` | 7 more qualify today | 7 of 19 |

The brief's "2" and the carve's "2 of 19" are both low for this tree; the carve's "25 commits repo-wide
touch only this area" is right but 26 of the 31 already do **not** rebuild the host (17 component-only,
5 docs-only, 2 Lua-only, 2 component+wit). The structural payoff the slice buys is not in those counts: a
new op now costs the component, its manifest and a Lua row, and **no** hub file — and no new row means no
digest change, so no binary is needed for the Lua half.

## 6. What this branch does **not** do

- It does not move the other eleven rows, and it does not drop a workspace dep yet: the enum-free entry
  exists and one op uses it (1fc54f29), but `wa-capabilities` still depends on `wa-whatsapp-index`
  while `request_of_text` calls `Request::validate`. Deleting the per-op enum from the host for the
  remaining seven read ops is mechanical (eleven one-line delegations) and is the next slice; the three
  deps leave when the send/approval/archive host halves move, which the plan argues must stay (no
  governance/policy world and no bounded-fs world exist in `wit/`).
- It does not measure a *host build wall time* before/after (the premise of "a rebuild is expensive" is
  not re-measured here); the build of this branch was 26.5 s incremental release, base 57.9 s cold, which
  is not a comparison of anything.
- It does not run the full `scripts/test.sh` gate or `scripts/fast.sh` under `flock` (main is frozen for
  the v0.1.2 cut and this branch must not hold the suite lock); the rows above were run directly,
  single-file, as rule 15 allows. The Lua row is wired by the fast path's own discovery:
  `scripts/lib/fast-rows.sh:95-103` runs every `scripts/test-*.lua` the exclude file does not name, and
  this row is not in `scripts/fast-path.exclude` (`grep -c whatsapp-reactions-op-data` = 0).
- No account was read: no live component, no phone, no peer, no `wa call`.

## 6b. Pre-existing failures in the full suite (not this branch's)

`cargo test -p wa-capabilities -p wa-whatsapp-index` on this branch: **408 passed, 5 failed**. The same
five fail on the **base** commit, run in a worktree of its own (`git worktree add /tmp/wt-base-70eb
70eb209d`, its own `CARGO_TARGET_DIR`, only those five tests selected): **0 passed, 5 failed, same panic
sites**.

| test | base | this branch | cause |
|---|---|---|---|
| `capabilities::tests::documented_inventory_matches_the_live_registry` | FAILED | FAILED | `registered but undocumented in docs/HOST.md: ["run_state"]` — a registry row the doc lacks; neither file is touched by 1fc54f29 (`git diff --stat 70eb209d HEAD -- docs/HOST.md rust/wa-capabilities/src/capabilities.rs` is empty) |
| `operations::await_returns_at_its_own_wait::a_relayed_await_answers_at_wait_ms_and_never_holds_the_relay` | FAILED | FAILED | operations.rs:3149, same on both |
| `operations::await_returns_at_its_own_wait::a_cancelled_shell_returns_before_its_settle_finishes` | FAILED | FAILED | operations.rs:3149 |
| `operations::adoption_survives_the_relay_deadline::an_adopted_operation_survives_the_relay_deadline_and_runs_once` | FAILED | FAILED | operations.rs:3072 |
| `operations::promotion_says_so::a_promoted_shell_says_in_the_same_result_that_it_moved_to_the_background` | FAILED | FAILED | operations.rs:3265 |

The count is also the arithmetic of this branch: the base run selects 412 tests under that filter, this
branch 413 — exactly the one test 1fc54f29 adds.

## 8. Move 3, continued: every read op on the seam (72b37107 .. f333068f)

Eight commits, one per op plus the door it needs and the test fallout:

| commit | what | row |
|---|---|---|
| **72b37107** | `host.whatsapp_index({op, ...args})` — one ReadOnly row carrying every read op; `answer_with`/`index_op`/`ask_index_in`; `M.invoke` hands the op from the catalogue row | Rust: generic vs named, byte-identical, for all six ops + payload identity + a no-op refusal; 18 passed |
| **cb27c3d4** | `mcp_whatsapp_search` -> `whatsapp_index` | Lua 17 checks |
| **268fc5bb** | `mcp_whatsapp_read` -> `whatsapp_index` | Lua 21 |
| **0130cc5a** | `mcp_whatsapp_contacts` -> `whatsapp_index` | Lua 25 |
| **329d17e0** | `whatsapp_message` on the seam (it has no tool door: the component points at it) | Lua 26 |
| **aa9042e0** | `mcp_whatsapp_media` -> `whatsapp_index` | Lua 30 |
| **437fdee5** | `mcp_whatsapp_reactions` -> `whatsapp_index` | Lua 34 |
| **f333068f** | four rows that stubbed a capability by its old per-op name now follow the catalogue | 16 of 16 WhatsApp-adjacent Lua rows green, check counts unchanged |

The per-op row is `scripts/test-whatsapp-reads-op-data.lua` (renamed from the reactions slice): for every
op it compares the generic door's BYTES with the named row's still being there - a live before/after, not
a remembered golden - plus the tool door's document and that the row's `capability` is `whatsapp_index`.
`f333068f` is the finding of running them rather than reading them: repointing a tool row changes WHICH
host capability the tool calls, and four rows in the tree had installed their stand-in under the old
name, so they stopped stubbing the door that was actually called. Each now resolves through
`whatsapp.by_verb[verb].capability`, and `test-whatsapp-route.lua` takes the op from the request the way
the real door does. No assertion was deleted or loosened (32/59/207/140 checks, the base's numbers).

### The defect the move introduced, and its fix (d1266ca8)

What 72b37107 bought at a price nobody audited: `whatsapp_index` is declared ReadOnly but carried ANY op,
so a sandbox that joined it as a read could reach `backfill` (the primary phone is asked) and `download`
(a decrypted file is written). Found by probing on a scratch node, not by reading the code:

    whatsapp_index({op:"backfill", count:5})  -> whatsapp_backfill_slow, id 1, state queued
    whatsapp_index({op:"download", ...})      -> whatsapp_download_slow, id 2, state queued

The effect class belongs to the QUESTION, so d1266ca8 put it beside the op set (`seam::Op::effect()`:
ReadOnly | Network | WritesFiles, in the shared contract) and the read door refuses any op whose class is
not ReadOnly, by name, with the row to use instead (`whatsapp_backfill_use_its_own_door`). Rows:
`the_generic_door_carries_only_the_reads_and_refuses_a_network_or_file_op` walks `seam::Op::ALL` and
asserts both halves; the Lua row went 34 -> 40 checks; the model catalogue is unchanged
(2a17427d...65e8c111b) and no capability row moved, so the inventory digest is 72b37107's.

### The stop condition, measured

**`host.rs` never carried WhatsApp** (`rg -c -i whatsapp rust/wa-capabilities/src/host.rs` = 0, section 1),
so the only file the condition could bite was `capabilities.rs`, and it no longer does: a read op - added
or changed - is now a component change plus a Lua row, and the row it rides is `whatsapp_index`, whose
name, description and effect class never move. The one-time price is visible and was paid once in
72b37107: 12 WhatsApp rows -> 13, inventory sha256 `cee0c602...911e0d28` -> `393ffdfc...ae2614e`, and the
tool catalogue the model reads did NOT move (`2a17427d...65e8c111b` on every commit since).

What still forces a host rebuild for a WhatsApp change, stated so nobody reads the above as more than it
is: `rust/wa-capabilities/src/whatsapp_query.rs` (the forwarder: enqueue, settle, the download writer,
the absent answer) and the crate behind it, `wa-whatsapp-index` (the request/answer contract, a
`wa-capabilities` dependency). The effectful rows - `whatsapp_send`, `_send_status`, `_approve`,
`_archive`, `_download`, `_backfill` - stay per op on purpose: their effect class is what the sandbox
joins and serializes on, and no WIT world exists to carry the policy, the operator's drafts or a bounded
file write (section 2).

### The 30-day count, re-measured under this design

Method: the 19 commits in the window that touch `rust/wa-capabilities` and a WhatsApp file, each diffed
for what it did to `capabilities.rs` (`+` lines) and which rust files it touched.

| what it changed | commits | under this design |
|---|---|---|
| added read-op rows | **2** (297b2d86: 4 rows, 384b2b4d: 2 rows) -> 6 `plain!("whatsapp_...")` lines | those 6 lines are **no longer hub edits**: an op rides `whatsapp_index` |
| added an effectful row | 4 (63a4fc68 send, 820d9b4c approve, b8b3ee10 archive, 9ca1d494 backfill) | still a row, by design |
| changed the forwarder or the shared contract | 12 of 19 (whatsapp_query.rs, wa-whatsapp-index) | still rebuilds the host |
| **whole commits that would now stay out of a host rebuild** | **0** | each commit that added a read row also changed `wa-whatsapp-index` or `whatsapp_query.rs`, which stay |

That 0 is the honest number and it is smaller than the 4 the plan hoped for (section 5): making
`capabilities.rs` stop naming ops is necessary but not sufficient, because the same commits also touched
the contract crate and the forwarder. The next slice that would move whole commits is dropping
`wa-whatsapp-index` from `wa-capabilities` (the component validates; the host forwards and bounds) plus
making the forwarder op-agnostic. Three commits in the window (626a3339, 14bd0013, 514a1c41) touch only
the contract crate, the component and Lua besides the forwarder - an **upper bound**, not a promise, and
the number to measure on that branch, not here.

## 7. Texts to approve

**One, from 72b37107** - a new capability row, which `wa capabilities` and `/health` print to an operator
(the model never sees it: it is not in `M.schemas()`, and the tool catalogue's sha256 is unchanged):

    whatsapp_index   read-only

and its description, verbatim:

    Ask the WhatsApp index one read-only question the wa-whatsapp component knows: {op, ...args}, op
    being search, read, contacts, message, reactions or media; the answer is the one whatsapp_<op> gives

**Nothing model-facing changed** in the whole of move 3: the tool catalogue (`whatsapp.schemas()`) has
the same sha256, `2a17427d...65e8c111b`, at every commit from 1fc54f29 to f333068f, because `capability`
is not a field `M.schemas()` emits - which is exactly why a tool row may be repointed without moving a
request byte. The other new prose is Rust doc comments and test headers that no model and no operator
reads.

## 9. The count, measured from git; and the send/approve plan (no code)

### 9.1 How the number is computed

One script, three rules, run over every commit in the 30-day window that touches a WhatsApp file
(`git log --since=30.days --format=@@%H`, then `--name-only` per commit; 183 commits):

  * a commit **needs a host rebuild now** when it touches `rust/Cargo.toml`, `rust/Cargo.lock`,
    `rust/wa-host/**`, any crate `wa-capabilities` depends on (23, read from its `Cargo.toml`), or a
    `wa-capabilities` file other than the two the move made data. Test files (`/tests.rs`, `/tests/`) are
    excluded: they do not build the release binary.
  * `rust/wa-capabilities/src/capabilities.rs` and `whatsapp_query.rs` are judged by their **hunks**: a
    commit whose changes there are only read-op rows/binds (a line naming `whatsapp_search|read|contacts|
    message|reactions|media` and no queue/settle/enqueue/download word) is free now, because an op rides
    `whatsapp_index` and needs no row.
  * everything else (component, `wit/`, `lua/`, docs, scripts) never rebuilt the host.

### 9.2 The numbers

| | commits (30 days) |
|---|---|
| touch a WhatsApp file | **183** |
| needed a host rebuild BEFORE this branch | **52** |
| need one AFTER | **52** |
| **would now have stayed out of a host rebuild because of this branch** | **0** |
| would stay out if `wa-whatsapp-index` were dropped from the hub | **9** |

Why 0, stated plainly: every commit in the window that added or changed a read-op row also changed
`wa-whatsapp-index` (the request/answer contract, still a `wa-capabilities` dependency) or the forwarder.
Removing the row from the hub removes one of its two hub files, not both. The nine that only
`wa-whatsapp-index` stands in front of are the measured size of the next slice: `1fc54f29`, `d1266ca8`,
`626a3339`, `1b008d78`, `14bd0013`, `514a1c41`, `384b2b4d`, `69f84802`, `18aad90c`.

### 9.3 Do `host.rs` / `capabilities.rs` still change for a WhatsApp-only change?

* **`host.rs`: no, and never did.** `git log -S'whatsapp' -- rust/wa-capabilities/src/host.rs` returns
  **0 commits** in the whole history, not only the window. The two window commits whose file set includes
  `host.rs` (`fc581ca2`, `cd6d3aa5`) are the chat-start-guard merge and the codemode pending pool: they
  changed `host.rs` for reasons that have nothing to do with WhatsApp.
* **`capabilities.rs`: not for a read op - yes for an effectful one.** 11 of the 52 commits change it,
  and exactly 2 of them change it only to add read-op rows (`384b2b4d`: 2 rows, `297b2d86`: 4 rows) - that
  is the part a read op no longer pays. The other 9 name an effect class (send, send_status, approve,
  backfill, download, archive, and the three generic doors), which stays on purpose: that class is what the
  sandbox joins and serializes on, and the repository has no WIT world to carry the policy, the drafts or
  a bounded write.

### 9.4 The send/approve ops: a plan, not code

Three ops are left, and they are one family: `whatsapp_send` (Network), `whatsapp_send_status` (ReadOnly)
and `whatsapp_approve` (Network). **No code was written for them: a send touches the live account, and
that is Fable's read.** What each needs today, measured from the code:

| need | where it lives now | can a component do it? |
|---|---|---|
| the `whatsapp.send` policy: rate limit, daily cap, audit | `wa-grant-policy` / governance, called from `whatsapp_send.rs` | **no world**: `wit/` has no governance interface |
| the outbox request: exact JID, reply shape, dedupe key | `wa-whatsapp-outbox` (shared with the component) | yes, already shared |
| the queue the account node owns | `wa:queue`, `whatsapp.outbox` | yes, the component already consumes it |
| the operator's drafts and `policy.json` | files under the node's components dir, read by `wa approve` and the CLI | **no world**: no bounded-fs interface for a guest |
| the answer shapes (`done`/`failed`/`pending`, the draft's `approval:"waiting"`) | `lua/core/whatsapp.lua` + `whatsapp_send.rs` | the waiting and the shapes are Lua's already |

Three ways to move it, in the order I would try them:

**B (recommended): a `wa:governance` world.** One interface - `decide(policy, request) -> allow |
refuse(code)`, plus an audit sink - lets the component ask the policy where the account is, which is
where the limits must be enforced anyway (a forwarded send already runs under the owner's guards). Host
keeps the queue producer and nothing else; `whatsapp_send.rs`'s policy half leaves. Rows that would
prove it: the `scripts/test-approve*` row, the send rows (`test-whatsapp-send.lua`,
`test-whatsapp-send-waits.lua`, `test-whatsapp-cancel.lua`), and one row that only Fable can run - a
real send on the live account, whose answer bytes are compared before/after exactly as the read rows
were.

**D (needed for approve/archive whichever way): a bounded-fs world.** `list/read/write` inside one
declared directory per component, so the drafts and the sealed archives can live where the operator's
CLI still finds them. Without it, `whatsapp_approve` cannot leave the host at all.

**A (do nothing): the current state.** Costs what section 9.2 measures: 1 of 52 commits a month changes
`capabilities.rs` for an effectful op, and every send change rebuilds the host.

What I would NOT do: give the generic door a `send` op. A send names a chat and text from a model, so it
must keep a door whose effect class is `Network` and whose policy runs on the account node - the effect
gate I added in `d1266ca8` exists exactly so a read door cannot be made to send.
