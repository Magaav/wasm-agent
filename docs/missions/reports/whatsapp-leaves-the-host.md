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

**None.** This slice adds, removes and rewords no model-facing and no operator-facing string: the
capability rows, their descriptions and the tool catalogue are byte-identical (§3) — `wa capabilities
--json` has the same sha256 on both sides. The only new prose is in Rust doc comments and the two test
files' headers, which no model and no operator reads.
