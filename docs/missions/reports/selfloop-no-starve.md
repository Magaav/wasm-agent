# selfloop-no-starve - a row this tick cannot dispatch never takes the plan's slot

Mission `deploy-hold-r8a4`, STEP 0 (Fable 24/11 12:55Z). Worktree
`/home/victor/Work/missions/deploy-hold-r8a4/no-starve`, branch `change/selfloop-no-starve` from
`origin/main` (`caa1a936`, NOT on top of r8a3), base `caa1a936`. Built and tested HERE on avell
(x86_64, 16 cores) with `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-deploy-hold-r8a4`.
Committed locally, **never pushed**.

## The commits

| commit | what |
| --- | --- |
| `d17ac6a5` | `selfloop: a row this tick cannot dispatch never takes the plan's slot` - the fix, on both paths, plus `scripts/test-selfloop-no-starve.lua` |
| `7da20968` | `features: the self-wake canary exercises the node's own tick (red on the 24/11 code)` - the post-install canary |
| `89ef378f` | `build: a switched tree must not reuse another tree's component artifacts` - the shared build root handed the gate another tree's wasm, plus the `selfloop` repin |
| this file | the report itself (its own commit) |

All of them are on `change/selfloop-no-starve`, in this order, and the first two land alone (the fix, then
the canary). The third exists because the land gate could not go green without it - see "A build trap" -
and the fourth is this report. `git -C <wt> log -1
--stat` after each showed the commit is this session's (author `Victor <vic.scar@gmail.com>`, the
configured identity) and touched exactly these files:

* `d17ac6a5`: `lua/core/selfloop.lua`, `rust/components/selfloop/src/lib.rs`,
  `rust/components/selfloop/manifest.json`, `wit/selfloop/selfloop.wit`, `scripts/test-selfloop-no-starve.lua`
  (new), `docs/SELF-LOOP.md` - 6 files, +327/-11.
* `7da20968`: `lua/core/canaries/tasks/self-wake.lua`, `lua/core/canaries/self-wake.lua`,
  `config/features/features.json`, `docs/SELF-LOOP.md` - 4 files, +90/-2.

## The cause, re-measured before writing code

The brief's file:line facts hold on `caa1a936`:

* `rust/components/selfloop/src/logic.rs:31` - `pub const DUE_LIMIT: i64 = 8;`
* `rust/components/selfloop/src/lib.rs:555-558` - `SELECT * FROM self_wakes WHERE status='pending' AND
  due_at IS NOT NULL AND due_at<=? ORDER BY due_at LIMIT ?`
* `lua/core/selfloop.lua:1603` (the held set) and `:1679` (the skip that consumed the whole page) - on
  `caa1a936` the loop skipped every row of a held session AFTER the plan had already been cut to 8.

So a parked session with 13 overdue rows made every page of every tick 8 held rows, and nothing later
in due order was ever reached. `out.paused` reported 8 on each of those ticks, which is why the number
looked healthy while nothing fired.

## The fix (`d17ac6a5`)

The hold is part of the plan's own query, on both paths:

* `rust/components/selfloop/src/lib.rs` `plan`: `AND session_id NOT IN (SELECT session_id FROM
  self_wake_pauses)` before `ORDER BY due_at LIMIT ?`.
* `rust/components/selfloop/manifest.json`: `self_wake_pauses` added to the component's `read` grant -
  the `wa:kernel/sql` host authorises per table through SQLite's authorizer
  (`rust/wa-kernel-runtime/src/sql_host.rs`, `reads/writes/covers`), so a subquery naming an ungranted
  table is refused, and the grant is READ ONLY: the component writes no pause. The grant list stays an
  allow-list, one table longer.
* `lua/core/selfloop.lua`: the native row query excludes it the same way (`:1690-1694`), and
  `out.paused` is now ONE count over the ledger
  (`SELECT COUNT(*) ... session_id IN (SELECT session_id FROM self_wake_pauses)`) instead of a number
  that depended on which rows happened to land in the page - the same value the old code reported when
  every held row fit in the page, and the true one when it did not.
* The loop's `held[...]` skip stays as the guard for a node whose INSTALLED component predates this
  query: such a row is still skipped, never dispatched, and the row is already counted.

Nothing is dropped or rewritten: a held row keeps its id, its `due_at`, its reason and its prompt, and a
resume fires it once - the property `scripts/test-session-park.lua` and `scripts/test-selfloop-pause.lua`
already pin, both still green here.

### The four shapes, and what each one is

`scripts/test-selfloop-no-starve.lua` seeds 9 rows (more than `DUE_LIMIT = 8`) of one shape, all due
EARLIER than one free due row, and asserts ONE tick, ONE dispatch:

| shape | how it is seeded | verdict on `caa1a936` | verdict here |
| --- | --- | --- | --- |
| held session | 9 overdue wakes + `selfloop.park` (a real `self_wake_pauses` row of `kind='park'`) | **RED** - `held: one tick dispatches the free row: expected 1, got 0` | green |
| backoff not yet elapsed | 9 wakes due at `now+300` | green (pin) | green |
| claimed by another process | 9 wakes claimed through `selfloop.claim_due` (`status='dispatching'`, fresh `updated_at`) | green (pin) | green |
| deploy waiting or installing | 9 due rows + the free row, with the installer's REAL marker `<data>/deploy-pending.json` written | not a slot shape - see below | green |

The two "pin" shapes are already excluded by the query's own predicates (`due_at<=now`,
`status='pending'`); they are in the row so that a future change to how the page is cut cannot start
reading rows the tick must not dispatch, and the row says so.

**The deploy gate is NOT fixed by this change and is not claimed to be.** While the installer's marker
is there, the tick starts no turn AT ALL - the 22/11 rule that a deploy is not starved by a turn - so the
free row waits, bounded by the marker's own declared bound (`M.DEFAULT_BOUND = 900s`, and the sentinel's
request bound while only a request is waiting). What the row does assert is that the gate strands
nothing: with the marker removed, three ticks dispatch all 10 rows exactly once (`SEED + 1`), the free
one among them, in due order. That is the known limit with its bound, stated rather than hidden.

The last block of the row seeds every slot shape at once (9 held + 9 claimed + 9 not due, one free row
400s ahead): one tick, one dispatch.

## Both paths, and how it is proven

The plan's query is the component's and the row query is the native loop's, so the row runs both: the
native instance is pinned (`M.seam_override` -> `false`), the component instance pinned `true`, and the
component half FAILS the row if any call logged `served natively` during it - a fallback would compare
the native path with itself. With no reachable component the half is SKIPPED and says so, unless the
runner promised one (`WA_SELFLOOP_COMPONENT_WASM`), where a missing component is a failure, not a skip.
Because the row's text names `WA_SELFLOOP_COMPONENT_WASM`, `scripts/fast.sh` builds and installs the
component into the row's own home (`scripts/lib/fast-row-exec.sh` `lua_run`), and the row is picked up
by the `scripts/test-*.lua` inventory - that is where it is wired into the fast path, and
`scripts/fast-path.exclude` does not list it.

Isolating the component's half: with the LUA fixed and the BASE component wasm installed, the shape-1
case still dispatches 0 - the lua guard alone cannot save a page that is already all held rows. That is
why both queries changed.

## The canary (`7da20968`)

The `self-wake` canary was green on a node where no self-wake fired for two hours, because it never
called `selfloop.tick`. It now ends on two stages: `tick` (a wake due now is dispatched by ONE call of
`M.tick`) and `no-starve` (the same 9-held-rows-ahead-of-one-free-row shape). `wa features canary
self-wake`, run here in a scratch home:

* this tree: `self-wake PASS delivered`
* `caa1a936` with the same task file: `FAIL no-starve: one tick dispatched 0 wake(s) [] behind 9 overdue
  rows of a parked session ... {"dispatched":0,"paused":8}` - the live failure in one line, which is what
  a release's per-node canary step would have caught on every fleet node.

The child node spawned by the canary has no serve loop and no run scheduler, so the tick is handed the
counted scheduler the tick's own rows take (`opts.dispatch`); the stub is the capability this process
does not have, and the canary says so in its own comment. What it proves is the half that failed: a due
wake REACHES the node's scheduler within one tick.

## What was run, on this node, in scratch homes

Every row below ran with this tree's binary
(`/home/victor/wasm-agent/target/m-deploy-hold-r8a4/release/wa`), `WASM_AGENT_LUA_ROOT` = the tree,
its own `WASM_AGENT_HOME` under `GATE_ROOT`, and the vault/provider variables cleared
(`WASM_AGENT_VAULT_URL`, `WASM_AGENT_OPENCODE_GO_VAULT_URL`, `WASM_AGENT_VAULT_DIR`,
`OPENAI_API_KEY`, ...). No row reached a real provider, no row touched the live node, and the ledger row
refuses to run outside a scratch home (`scripts/lib/test-home-guard.lua`).

| run | result |
| --- | --- |
| `scripts/test-selfloop-no-starve.lua`, native | `selfloop no-starve: the native path ok (174 checks)`, `selfloop no-starve ok: 174 checks, native (component SKIPPED)` |
| `scripts/test-selfloop-no-starve.lua`, native + component (wasm built from this tree, sha256 `949c657d...`) | `selfloop no-starve ok: 349 checks, native + component`, zero `served natively` lines |
| the same row on `caa1a936` (lua) | RED: `held: one tick dispatches the free row: expected 1, got 0` |
| the same row, this tree's lua + the `caa1a936` component wasm (`880aef08...`) | RED at the component half's shape 1 |
| `scripts/test-selfloop.lua` | `{"checks":119,"ok":true,"skipped":1}` |
| `scripts/test-selfloop-pause.lua` | `self-loop pause: 191 checks passed` (including the held-row count `out.paused`) |
| `scripts/test-session-park.lua` | `session park ok (68 checks)` |
| `scripts/test-deploy-pause.lua` | `deploy claim wait ok (101 checks)` |
| `scripts/test-feature-canary.lua` (runs the shipping canaries through the runner) | `feature-canary ok (62 checks)` |
| `node scripts/check-features-registry.mjs` | `features-registry ok (14 rows, ...)` |
| `scripts/test-component-pins.sh` (artifact in `build/components-pinned/`) | `selfloop: source and pin moved together`, `11 of 11 pinned component(s) verified` |
| `scripts/fast.sh`, narrowed to the touched rows | `fast path FAILED (2 of 137 checks, 0 skipped, 610s)`: the two pre-existing rows below; everything else green, this change's row included |
| `wa features canary self-wake`, this tree / `caa1a936` | PASS `delivered` / FAIL `no-starve` (quoted above) |

**Pre-existing failure, not this branch's.** `scripts/test-selfloop-component.lua` fails on `caa1a936`
AND on this branch, identically: `PARITY: schedule a time wake differs`, the native answer carrying
`"inherited":false` where the component's carries no such field. Verified by running the row on a
separate worktree of `caa1a936` with the component built from that same commit (`880aef08...`), so it is
not caused by this change and is left alone here; it is a real native/component drift on `main` for the
next mission to fix.

## A build trap, fixed

`scripts/build-components.sh` builds in the shared root `/tmp/wa-component-build/src` and Cargo decides
what to recompile by MTIME, while the copy keeps the mtimes of the checkout it came from. Building the
component from a SECOND worktree and coming back made Cargo answer `warm, nothing to compile` for the
first tree while the artifacts in the target directory were the second tree's - same size, another
sha256. Measured twice here:

* a "base component" build that silently produced this tree's fixed bytes (`949c657d`, with
  `self_wake_pauses` in them), which is why the base half of the red proof was re-taken after
  `touch`ing the base tree's sources; and
* the FAST PATH installing `selfloop.wasm` `880aef08` (the other tree's bytes, no
  `self_wake_pauses`) into the row's own home while `/tmp/wa-component-build/src/lib.rs` held this tree's
  source - my row passed alone and failed inside the gate, at `held: one tick dispatches the free row`.

`89ef378f` fixes it: the tree is compared with the one the build root last held (the hash is kept BESIDE
the directory, so it cannot describe itself); the same tree keeps every mtime and the cache stays warm, a
DIFFERENT tree is installed and then touched, so every input is newer than any artifact built from the
tree before it. Verified by switching three times in a row: base `->` `880aef08`, this tree `->`
`949c657d`, this tree again (warm) `->` `949c657d`.

The same commit repins `components.lock`: `selfloop 949c657d... 247835` (was `880aef08... 247771`).
`scripts/test-component-pins.sh` (with the built artifact placed in this worktree's
`build/components-pinned/`, so the check judges real bytes and not a skip) answers
`selfloop: source and pin moved together (949c657d... 247835)`, `source and pins agree`,
`11 of 11 pinned component(s) verified`.

## The gate run

`scripts/fast.sh` narrowed to the rows this change touches (`WA_FAST_ROWS`), under
`flock -o ~/Work/missions/.suite.lock`, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-deploy-hold-r8a4`:

```
fast path FAILED (2 of 137 checks, 0 skipped, 610s)
  check-esc-stops-pty       FAIL - bash: Esc gives back a usable prompt at once (300 ms idle, ...)
  test-selfloop-component   PARITY: schedule a time wake differs
```

Both are PRE-EXISTING and were measured on a separate worktree of `caa1a936` (the base):

* `check-esc-stops-pty` - `scripts/test-esc-stops-pty.mjs` run twice against the base tree here: "17 ok,
  1 failed" both times (and "15 ok, 3 failed" on a second run in THIS tree), i.e. a timing row on this
  machine, on a path this change does not touch.
* `test-selfloop-component.lua` - the same `inherited` parity failure on base, quoted above.

Everything else in that run is green, including `scripts/test-selfloop-no-starve.lua` (both halves),
`scripts/test-selfloop.lua`, `scripts/test-selfloop-pause.lua`, `scripts/test-session-park.lua`,
`scripts/test-deploy-pause.lua`, `scripts/test-feature-canary.lua`, `scripts/test-features-gate.lua` and
`check-component-pins`.

## Unknowns, stated

* The live node was not touched: the 24/11 premise (no dispatch since 10:27Z, canary `c8a15d15` pending)
  was taken from the brief and re-read in the tree, not measured again on the node from this session.
* The canary's tick stage proves the wake reaches the node's scheduler; it does not run a model turn. The
  served-turn path stays covered by `scripts/test-serve-turn-all-on.sh` and the follower rows.
* `host.sleep`-based waiting gives the canary's free wake a strictly later `due_at`; if the machine's
  clock stands still for 2.4s the stage fails by name rather than passing.
