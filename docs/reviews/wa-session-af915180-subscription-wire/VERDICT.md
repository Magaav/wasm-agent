# VERDICT: `needs-change`

Independent review of `change/wa-session-childdispatchaf915180-d6da-4eb4-a505-b41a7a36a52f` at
`ea2f2011adae10e1c427c0eb75b5535fee94a302`. Reviewed, not authored. The delivery's branch was not
modified; findings live on branch `change/wa-session-childdispatchc5606d25-…`.

**Blocking change (one, small, its own delivery):** the delivery's new Rust unit tests
(`host::sse_line_tests`, 4 tests) are run by **no** `cargo test` line in `scripts/test.sh`, while the
status file's item 6 presents them under "Offline, **in the gate's own terms** - PROVEN". The tests
pass and cost ~0 ms (reviewer ran them: see `evidence/rust-tests-not-gated.txt`), so this is wiring,
not code. `scripts/test.sh` needs
`cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host sse_line_tests`, and the
status file's row must stop implying gate coverage of a check no gate executes - which is exactly the
rule the same file states for other suites ("a test nobody runs is a comment").

Everything the delivery was required to make true was independently reproduced, on real bytes and a
real endpoint, with Pi renamed aside. Details per item in `EVIDENCE-PER-ITEM.md`, raw evidence under
`evidence/`.

## The three specific answers

### 1. `host.http_sse` is a real streaming transport, not a shim

Read at `ea2f2011`, `rust/wa-host/src/host.rs`. The code path relied on:

* `:1818-1819` `let reader = std::io::BufReader::new(response.into_body().into_reader()); let
  outcome = read_sse_lines(reader, |line| call_lua_string(l, 5, line));` - the body is taken as a
  **streaming reader** and handed to the line loop. `read_to_string` appears on the streaming path
  nowhere; the only one is the bounded non-200 error body at `:1812`.
* `read_sse_lines` (`:1846-1868`) is `for line in reader.lines()`: `run_cancel_requested()` is checked
  **per line** (`:1853` -> `termination:"cancelled"`), a read error yields `read_failed`, and
  `on_line(&line)` is called inside the loop. An `Err` from the callback returns **immediately** with
  `termination:"line_callback_failed"` and the line count already delivered (`:1863-1865`) - the read
  ends at that line, not at EOF.
* `call_lua_string` (`:1877-1898`) runs the Lua callback under `lua_pcallk`, restores the stack on
  both paths, and converts a Lua error into `Err(redacted, ≤512)` rather than unwinding across the C
  boundary.

Confirmed behaviourally, not only by reading: on a real stream, deltas arrived and were timestamped
(`ttft_ms` 1.1-1.5 s against 2-3 s totals), and a 1 s deadline **raised from inside the callback** cut
the read after 6 lines (`subscription_timeout … stopped after 6 line(s)`) instead of at EOF.

One wording correction for the status file, not a defect: only cancellation is checked in Rust. The
*deadline* is checked in Lua (`subscription_wire.lua:894`) inside the same per-line callback, so the
status file's "checks cancellation and the deadline per line" is true of the pair and not of
`host.rs` alone.

### 2. Gate coverage: the receipt covers `f627a15`, the FINAL tree is NOT covered

* Receipt (`.git/worktrees/…af915180…/wa-finish-gate.json`): `head f627a158…`, `tree
  82ebb4caa6afa109787aeb0b1112b5b083f4cf56`, `passed true`, `skipped 2`, `gate_ms 1195856.394`,
  `gate_runs 1`, `gate_exit 0`, lane `slot #154 … waited 1108.5s`. Log sha256 matches the recorded
  `19d59d96…`, and the log really contains `subscription wire ok (132 checks)` (line 2385),
  `openai-sub levels ok (22 checks)` (2384), `native subscription operations ok (15 checks)` (2382),
  the nested fixture gate `parallel finish checks ok (26 checks, 0 skipped)` (150), and the verdict
  `smoke ok (2 skipped)` (2443). The 2 skips are named in the log and are host facts, not silent
  holes: `termux launcher: 8 passed, 1 skipped (POSIX mode semantics unavailable on Windows); Android
  build and runtime skipped on this non-Android host`.
* `f627a15^{tree}` = `82ebb4c…` = the receipt's tree. **`ea2f201^{tree}` = `3457564…` ≠ `82ebb4c…`.**
  The only difference between the two revisions is `docs/SUBSCRIPTION_WIRE_STATUS.md`, but a tree is
  what the receipt holds.
* Run at the tip, `node skills/parallel-evolution/scripts/finish.mjs verify "$PWD" ea2f2011…` returns
  `repository_ready: true` (all eight checks ok: revision, source_tree, branch, clean,
  fresh_remote_refs, current, pushed, merge_proof) and **`gate_verified: false`,
  `gate_error: "no passing gate evidence for this source tree"`.** So the "closing check agrees" claim
  in the status file is true of the gated revision, not of the branch tip; read at the tip it is
  false, and the status file should say which revision it was read at.
* Consequence for the batch: the merge gate covers the *merged candidate*. If the batch lands
  `ea2f201` by fast-forward without a gate on that tree, the shipped tree is ungated (docs-only, but
  ungated). Nothing was queued for the gate in this review.

### 3. Mergeability, as facts about the branches

| merge (`git merge-tree --write-tree`) | exit | result |
| --- | --- | --- |
| `origin/main` × `ea2f201` (delivery) | 0 | clean; tree `34575647569ab7e5210f5c33adadfbbf4d746c84` |
| `origin/main` × `a6e111d` (auth tip `…8ad3ecc6…`) | 0 | clean; tree `b0ba92b603124baf40e5bc80b80fdf632368f804` |
| `ea2f201` × `a6e111d` (**together**) | **1** | **CONFLICT**: `rust/wa-host/src/main.rs`, `scripts/test.sh` |

Exactly the two predicted files, no third, and nothing was resolved. (`…95d6189a…` = `24fb23c` is an
ancestor of `a6e111d`.) Both conflicts are the same two insertion points: `main.rs`'s `EMBEDDED` list,
where the delivery registers `openai_sub_catalogue.lua` + `subscription_wire.lua` and the auth lane
registers `openai_sub_auth.lua`, and `test.sh`'s subscription block, where the delivery adds its wire
suite and the auth lane adds its credential suite. Facilitating fact for whoever resolves them: the
auth lane's `EMBEDDED` entry is for `openai_sub_auth.lua`, so even after a merge a deployed binary
would carry the credential at a path `subscription_wire.lua:112` does not `dofile` - the seam-name
decision has to move both the seam and that registry line.

**Does the delivery add a suite to `scripts/test.sh`?** Yes, one:
`WA_SCRIPT=scripts/test-subscription-wire.lua "$BIN" --db "$DB.sub-wire" | grep "subscription wire ok"`
(test.sh:1578). **Cost: 82 ms** measured standalone with the delivered binary (start 1790777153219 ->
end …301), on a suite that reports 132 checks. Against a gated 1 195 856 ms that is ~0.007 % - not a
tax worth naming. (`test-openai-sub.cjs` at test.sh:1564 was already in the tree and is unchanged.)
The two network checks (`check-subscription-wire-live.lua`, `check-subscription-wire-parity.lua`) are
**not** wired in, and say so.

## Item verdicts

| # | required | verdict | evidence |
| --- | --- | --- | --- |
| 1 | real request end to end, Pi package renamed aside | **verified** | reproduced live, exit 0, deltas + tool call + usage; `evidence/live-runs.txt` |
| 2 | no node, no pi at runtime | **verified** | process tree of the request's own `wa.exe` had **zero descendants** in all 7 in-flight samples; sampler proven non-blind by a control; `evidence/process-tree.txt` |
| 3 | credentials only from the seam | **verified for this lane** | `M.credential()` -> `dofile('lua/core/subscription_auth.lua')`, `M.credential_provider = M.credential`, no `~/.pi` read in the wire; live run with no stand-in line. **Cross-lane gap stands:** `a6e111d` ships `lua/core/openai_sub_auth.lua`, not the seam name, so as both branches stand the wire cannot find a credential - disclosed by the producer, and the coordinator's cutover item |
| 4 | event contract preserved, not flattened | **verified except `reasoning`** | emission sites and `session.result` field-for-field equal to the Pi bridge's `result` (`openai_sub_bridge.lua:250-263`); `ui/app.js:1226,1266` consumes the vocabulary; live `pending_delta`->`commentary` (8->1), `decision` x2, `delta` for a streamed final answer. **`reasoning` is exercised nowhere**: no `response.reasoning_*` event in either fixture and none in any live run of mine |
| 5 | cancellation, `WASM_AGENT_SUBSCRIPTION_TIMEOUT`, truncation-is-an-error | **verified** | live `subscription_timeout … stopped after 6 line(s)` (anchored name, no path leaked), `invalid_subscription_timeout` for `0`; truncation and cancel asserted offline by the suite I ran (132 checks) |
| 6 | fixture real bytes, bounded, redactions named, parser tested offline | **verified** | re-recorded both streams live and diffed: identical after normalising only the named redactions; 7 407 / 11 218 bytes against a loud 1 MiB bound; suite exit 0 |
| 7 | a catalogue we own, nil-not-`{}`, no `~/.pi` at request time | **verified** | `unknown=nil` (`is_table=false`) with the store unreachable, `configured()=true` with Pi's auth unreachable, import reproduces the committed file byte-for-byte and reports a tampered block instead |

## Non-blocking observations

* `M.request_timeout` raises `invalid_subscription_timeout` without `error(..., 0)`, so that message
  carries `…/subscription_wire.lua:148:` - the same class of leak the delivery fixed for the two
  documented names.
* `docs/HOST.md` typo: "`lua/core/subscription_wire.lua` **ows** the endpoint" (owns).
* `scripts/import-openai-sub-catalogue.lua` header: "Exit is non-zero when nothing was written" -
  the unchanged path exits 0 (observed). The useful half of the sentence is true: an unreadable store
  fails loudly and writes nothing.
* `opts.timeout_seconds` overrides `WASM_AGENT_SUBSCRIPTION_TIMEOUT` (`subscription_wire.lua:872`).
  That matches the Pi path, but it means the environment bound is only in force when the caller passes
  none - worth a line of documentation.

## What I could NOT verify

* **`reasoning`**: not producible in my live runs (effort `low` and `medium`, two prompts) and absent
  from both fixtures - so the `reasoning` stream event and result field are untested by anyone.
* **A live cancellation mid-stream** (I verified the deadline half live, and cancellation offline
  against recorded bytes) and **a live truncated stream** (needs an endpoint that cuts the response;
  neither the delivery nor I built one).
* **`M.limits()`** (the `wham/usage` windows) was not called live by me or by the producer.
* **The producer's operational records**: the 900 s lane refusal at #150, the "free space 68 G at the
  start" figure, and the parity run's two wall-clock samples. The receipt side of the gate claim I did
  verify (receipt, log hash, skip count, lane slot, one run, no reuse). Free space today is 64-67 G of
  477 G; the historical value is unobservable.
* **The two branches as a pair** cannot be exercised by me either: they conflict in
  `rust/wa-host/src/main.rs` and `scripts/test.sh`, and the seam name does not match.

## Method, so the verdict can be re-tested

Scratch source tree `git archive ea2f201`; the delivery's own `rust/target/release/wa.exe`; every
`--db` and `WASM_AGENT_HOME` in scratch; the operator's credential store named explicitly. `@earendil-works`
was renamed aside and restored (verified on disk) inside one `trap`-guarded run; the sibling's
credential module was copied read-only into the scratch tree only. No gate slot was taken, no merge
was made, `main` was not pushed, and the delivery's branch was not modified.
