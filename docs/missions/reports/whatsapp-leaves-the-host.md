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

## 7. Texts to approve

**None.** This slice adds, removes and rewords no model-facing and no operator-facing string: the
capability rows, their descriptions and the tool catalogue are byte-identical (§3) — `wa capabilities
--json` has the same sha256 on both sides. The only new prose is in Rust doc comments and the two test
files' headers, which no model and no operator reads.
