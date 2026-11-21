# compact-pending - idle compaction never fires while work is pending

Mission `change/compact-pending`, worktree `/home/victor/Work/missions/compact-pending/wt`, branch
`change/compact-pending`, base `bfad4f8f`. Built and tested HERE on avell (x86_64, 16 cores) with
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-compact-pending`. Committed locally, **never pushed**.

## The rule and the commit that implements it

`6bfd0c55` "idle-compaction: refuse /compact on the idle path while the session has work pending".

Nothing else was needed: this is a Lua-only change (no Rust touched, no rebuild of a component).

* **The idle path is now identifiable by name.** `scripts/on-stale.sh:131` and `:141` post
  `{"idle":true,"min_percent":40}` and `{"idle":true,"min_percent":40,"session_id":...}`. It is the
  only caller of `POST /compact` in the tree (`rg -n "/compact" lua/ rust/ scripts/` shows on-stale.sh
  and the route itself), so an explicit operator request is exactly the request that carries no
  `idle`, and `6bfd0c55` leaves it unchanged.
* **The refusal** (`lua/core/server.lua`, `idle_pending_work` at :578 and the `if args.idle == true` branch at :638-649, just after
  the subagent refusal in `wa_compact`): `{"ok":false,"error":"work_pending","session_id":...
  ,"pending":[...],"unknown":[...],"note":...}`. It is decided BEFORE the agent is built, so a
  refused request neither measures nor summarizes anything (the test asserts `percent == nil`).
* **The three states**, each read from the store that owns it, none stubbed:
  1. a pending code-mode handle - `lua/core/codemode_pending.lua` gains
     `M.session_open(session_id)`, a read that counts the session's open handles across every scope
     from the records (`open_record`: state running/unknown/pending, or settled-and-unreported). It
     reads the index files rather than rebuilding the scope hash, because the route has the session
     and not the role/workspace/profile the hash is made of.
  2. a pending self-wake - `lua/core/selfloop.lua` `M.summary(session_id).total`, i.e.
     `self_wakes` rows with status `pending` or `dispatching` (the same read the footer uses).
  3. a child run queued/running - `lua/core/agent_control.lua` `M.children_of(session_id, ctx)`, the
     reader the control API answers `tree` from; states `queued`, `running`, `cancelling` count.
* **Unknown is not yes.** An index file whose contents cannot be decoded, a self-wake read that
  raises, or a child read that raises is NOT read as clear: it lands in `unknown` and refuses too,
  naming itself in the answer and in the note.
* **Nothing is remembered.** The check is a read, re-evaluated on every idle request, so the first
  idle request after the work settles compacts.
* **The job's side**: `scripts/on-stale.sh` treats `work_pending` the way it treats `node_busy` -
  a named deferral, exit 0, nothing installed or built.
* The Rust listener's node-wide `node_busy` gate (`rust/wa-capabilities/src/serve.rs:1026-1050`) is
  untouched: it is a different condition (a queued/running scheduler run anywhere on the node) and
  it still refuses both request shapes, as before.

## Premises re-measured before writing code (rule 9)

* The brief's reading of the idle path is correct: `onStale` is event-triggered on
  `node.run_finished` (jobs/on-stale.json, `"topic": "node.run_finished"`), it posts `/compact` with
  `min_percent:40`, and the doc paragraph is `docs/CONTEXT-COMPACTION.md:5-18`. No correction.
* `codemode_pending.lua` did NOT already have a session-scoped pending query: it has `M.open(scope)`
  and `M.list(dispatch, opts)`, both keyed by the scope hash. `session_open` is new
  (codemode_pending.lua:182-235).
* A correction to the doc's own wording, not acted on here: `docs/CONTEXT-COMPACTION.md:16` says
  "Subagents are out of scope: they neither trigger nor block this path", while
  `rust/wa-capabilities/src/serve.rs:653` and `:1025` say a queued/running subagent blocks. The code checks
  `scheduler::run_ids()`, so whichever of the two is true depends on whether a subagent run is a
  scheduler run - I did not settle that, and this change does not depend on it (the child condition
  is decided in Lua). Flagged as an open contradiction in the docs.
* One consequence the brief did not state, measured in the test: a wake scheduled for the future
  counts as `pending`, so a session holding a long-horizon wake does not idle-compact until that
  wake fires (the in-run 90-95% trigger is unaffected). That is the brief's rule applied literally;
  if the intent was "only work that is about to run", it needs a due-time filter, which is a
  decision for Victor, not a silent narrowing.

## Tests, and where they are wired

The new test is `scripts/test-compact-idle-pending.lua`, wired into `scripts/test.sh` on the line
right after `test-compact-idle-route.lua` (scripts/test.sh:1270-1275). `scripts/test-on-stale.sh`
(case 11, case 15 and the new case 15b) asserts the `idle:true` marker in the posted body and the
`work_pending` deferral of the job.

Evidence, all run on this node against the binary built from `bfad4f8f` + this branch's Lua:

| what | new tree | base `bfad4f8f` (separate worktree, same test files) |
|---|---|---|
| `scripts/test-compact-idle-pending.lua` | `compact idle pending ok (35 checks, 0 skipped)` | `lua error: ...:42: one pending code-mode handle refuses the idle compaction by name: nil` |
| `scripts/test-on-stale.sh` | `20 checks, 0 failed` | `20 checks, 3 failed` (event body, fallback body, case 15b) |
| `scripts/test-compact-idle-route.lua` | `compact idle route ok (17 checks, 0 skipped)` | unchanged file |
| `scripts/test-selfloop.lua` | `{"checks":109,"ok":true,"skipped":2}` | unchanged file |

The base runs use `git worktree add --detach /dev/shm/cp-base-... bfad4f8f` with only the test files
copied in - no `git stash` anywhere (rule 12). The test creates its own scratch home and refuses to
run otherwise (`scripts/lib/test-home-guard.lua`); it never touches the live fleet, a peer, or a
provider.

What the test asserts, in the order it asserts it: a clear session admits and measures the idle
request (baseline) -> one pending handle refuses it by name and the refusal names the session and
the reason -> `onStale`'s session-less fallback shape is refused the same way -> an explicit
`/compact` (no `idle`) is admitted, measures and is unchanged -> another session's handle does not
count -> a pending wake refuses it, then a `dispatching` wake refuses it, then cancelling the wake
admits it -> a running child refuses it and its own run settling clears it -> with all three clear
the same idle request is performed (admitted, session selected, context measured, `compacted:false`
at 95% so no model was called) -> a corrupt index file refuses it as `unknown` instead of reading as
clear, and repairing the file admits it again.

Full gate: `env -u CARGO_TARGET_DIR flock -o ~/Work/missions/.suite.lock bash scripts/test.sh` in this
worktree; the verdict is in the last section.

## Texts to approve (operator- and model-facing, verbatim)

1. The refusal's `note` field:

   `idle compaction is not performed while this session has work pending or a pending state it cannot see: <reasons>. Nothing was summarized; the next idle request after the work settles compacts it.`

   where `<reasons>` is a comma-joined list of `N code-mode handle(s)`, `N self-wake(s)`, `N child run(s)` and, for each unknown, `<what>, which is unknown and not clear`.
2. The onStale log line (stdout, plus the route's own JSON after `:`):

   `onStale: the session still has work pending - compaction deferred: {"ok":false,"error":"work_pending",...}`

3. The hook inventory's two sentences (`lua/core/hook_events.lua`, `node.stale` row):

   `one main run finished; /compact atomically reserves the idle node and is targeted at the session the event names; the idle request carries `idle:true` and is refused by name (`work_pending`) while that session has a pending code-mode handle, a pending self-wake or a queued/running child run; subagents are excluded`

   `The idle compaction is a deferral, never a rewrite under pending work: the route answers `work_pending` while the session still has a code-mode handle, a self-wake or a child run live, and the next idle request after they settle compacts.`

## What is NOT done, and the one thing to decide

* **The retry is the next `node.run_finished`, not a watcher.** `onStale` fires once per main run; if
the last handle settles and no further run starts, nothing posts `/compact` again - the compaction
then happens after the next run finishes. In Victor's own scenario the turn that reports the finished
command IS that run, so the observed sequence is "no compaction while `sleep 600` runs, compaction
after the model reports it". I did not add a scheduler-side retry or a self-wake for it: that would be
new orchestration, not this rule.
* **A pending wake of any horizon defers it** (see "Premises"). Decide if that is intended.
* No served-node probe was run: I did not start a node with a provider to watch a real `sleep 600`
from the chat side, so the chat-visible half of the brief's test ("`wa chat --resume` shows no
compaction note") is unverified by me; the route and the job's decision are verified.

## Gate

Both runs used the repo's suite lock (`flock -o ~/Work/missions/.suite.lock`) and full logs.

**`bash scripts/test.sh` (full gate): FAILED, on one check that is not this change.** Build 594 s, then the
`nativeRecovery` proof failed:

```
AssertionError: actual native source-only recovery positive:
  {"error":"recovery_source_private_fixture_root", ...}
  at scripts/test-wave-native-recovery.mjs:106
```

Measured on the base, not assumed: the same command (`node scripts/test-wave-native-recovery.mjs`, same
binary, same build log) run in a separate worktree at `bfad4f8f` fails with the identical assertion at the
identical line - so this failure is the branch's inheritance, not its effect. It is the fence in
`scripts/lib/wave-recovery-source.mjs:38` (`underTemp`) meeting a fixture root inside this node's own temp
root (`docs/ONEROOT.md`), the same family as the 21/11 `private_fixture_root` incident that
`scripts/lib/temp-roots.mjs` was added for. My change touches no file that proof reads, and the proof runs
at `scripts/test.sh:415`, before the line my test is wired to (1275), so the gate never reached it.

**`bash scripts/fast.sh`: 353 checks, 352 passed, 1 failed.** The one failure is
`scripts/test-refusal-contract.lua`: `lua/core/refusal_codes.lua is stale`. Also measured on the base:
`lua5.4 scripts/gen-refusal-codes.lua --check` in the `bfad4f8f` worktree prints the same STALE line, and
regenerating there produces the same diff (missing `agent_control.lua` codes) as here - pre-existing, and
not touched by this branch. I checked it was not mine to register: the generator walks `tools.lua`,
`codemode.lua` and `agent.lua`, and `server.lua` is not in that closure - `node_busy` is not in the
registry either, and neither is `work_pending`. I reverted the regeneration I had made while checking
this, so the generated file is byte-identical to the base (`git checkout lua/core/refusal_codes.lua`).

My own rows in that same fast run:

```
scripts/test-compact-idle-pending.lua  pass  4048 ms
scripts/test-compact-idle-route.lua    pass  1048 ms
```

`scripts/test-compact-idle-pending.lua` runs as a fast-path row automatically (every `scripts/test-*.lua`
not in `scripts/fast-path.exclude`), so it is wired in two places: `scripts/test.sh:1275` and the fast path.

Cost, measured: the idle refusal reads one small JSON per code-mode scope on the node
(`scripts/test-compact-idle-pending.lua` completes in ~4 s including the whole fixture), plus two SQL reads
(`self_wakes`, the children rows). It never runs a model.
