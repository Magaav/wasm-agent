# seat-5-10-check - items 5 and 10, measured on a running node

Worktree `/home/victor/Work/missions/seat-5-10-check/wt`, branch `change/seat-5-10-check`, base
`e7bf6d56`. Node: avell. Commits on this branch:

| commit | what it does |
| --- | --- |
| `246137b2` | `wa counters`: the three counters on the command line, cumulative and per calendar day (`lua/core/counters.lua`, `lua/core/init.lua`) |
| `c4a46753` | pending work on EVERY wake, and each pending handle names its own state (`lua/core/handle_wake.lua`, `lua/core/selfloop.lua`) |
| this commit | the docs (`docs/CODEMODE.md`, two sections) and this report |

## The first table: is any deferred feature justified today?

| deferred feature (seat list, section B) | go now? | the number behind it |
| --- | --- | --- |
| durable scripts | **NO - not justified yet** | The two counters it is gated on exist and are readable (`wake_only_round`, `script_cut_at_cap`), but **no rate exists yet**: the store only began keeping per-day buckets at `246137b2` (22/11), so on the live ledger the last three days read `not recorded`, not three zeros. Until a few days of real use exist, "high" has nothing to be high against. |
| wake conditions | **NO - not justified, and not measurable yet** | Its gate is **wakes per fan-out**, and **no counter measures that**: `counters.M.NAMES` is `wake_only_round`, `script_cut_at_cap`, `handle_mishandled` (`lua/core/counters.lua`, added by the always-available landing). Nothing in this tree counts wakes per fan-out, so the gate has no number to read at all - that counter is the missing piece, not a high value. |

Neither answer is "the numbers are low": one is "the window has not been recorded yet", the other is
"the number does not exist". Section B names no thresholds (**see "Premises that were stale" 2**), so
both rows are honestly undecidable today and the decision rule has to be written before either
gate can fire.

## Item 5 - pending work on every wake: what the model actually receives

The measurement runs the real path with a stubbed provider (script outside the tree, so it cannot be
mistaken for a test):
`/home/victor/Work/missions/seat-5-10-check/measure-item5.lua`, run as
`WASM_AGENT_LUA_ROOT=<tree> WASM_AGENT_HOME=<scratch> WA_SCRIPT=<that file> wa --db <scratch>/t.db`.
Two calls answer handles (`sleep 300`), a timer wake is scheduled and claimed the way the node tick
and the CLI idle prompt claim one, then a third call settles and the sweep schedules its wake.

### A scheduled (timer) wake, two handles still pending - the message the provider received

```
[self-wake · the nightly check]
look at the build
Your earlier calls are still running; each one wakes this session when it settles:
Still pending (2): op-1795344774655687-3814664-1 (bash, running, 1s), op-1795344774703931-3814664-3 (bash, running, 1s)
wait(op) resumes one, cancel(op) stops one, results.get(op) re-reads an answer.
```

### A handle wake (a third call settled), the same two handles pending

```
[self-wake · a pending call settled]
bash op-1795344776699094-3814664-5 finished while no script was waiting for it (it is done).

Its answer, in the same shape the call itself answers:
{"cleanup":"terminated",..."state":"completed","status":200,...,"stdout":"A is done\n",...}

Still pending (2): op-1795344774655687-3814664-1 (bash, running, 4s), op-1795344774703931-3814664-3 (bash, running, 4s)
wait(op) resumes one, cancel(op) stops one, results.get(op) re-reads an answer.
```

(The answer block is one flat JSON object, quoted in full in the run log; elided above with `...` only
inside that object - no field is summarised away.)

**Verdict, item 5.** Every pending item is listed by its handle (`op-...`), its tool, its age and, after
`c4a46753`, its state (`running` / `unknown`; both open, not the same news). Before that commit the
measurement showed two real gaps:

1. **The state was not printed at all** - each handle read `op (bash, 4s)`, so a handle whose state was
   lost (`unknown`) looked exactly like a healthy one.
2. **A scheduled (timer, event or probe) wake listed nothing.** Its whole input, measured at base
   `e7bf6d56` with two handles pending, was:
   ```
   [self-wake · the nightly check]
   look at the build
   ```
   So "pending work listed on every wake" was true of settlement wakes only - and the brief's own
   scenario (two pending handles + one scheduled wake) was exactly the case that failed.

Both are fixed in `c4a46753` and pinned by `scripts/test-handle-wake-turn.lua` and
`scripts/test-handle-wake.lua` (test table below). The list lives in `handle_wake.prompt_for` (one wake
row) and `handle_wake.pending_text` (the block `selfloop.run_wake` appends for a wake that is not a
settlement, built from `handle_wake.pending_for`); a session with nothing open reads exactly as it did
before.

## Item 10 - the counters: what exists, where it is stored, and the one command

| counter | what it counts | bumped at |
| --- | --- | --- |
| `wake_only_round` | a model step whose only input was a settled handle (a `handle:` wake) | `lua/core/selfloop.lua:1262`, in `run_wake` |
| `script_cut_at_cap` | a script that was told "not yet" (a pending answer), once per script | `lua/core/codemode.lua:1023` (`finish`); the flag is set at `codemode_pending.lua:1009` |
| `handle_mishandled` | a script that used a pending answer as a result, or ended on the wait-never-settles bound | `lua/core/codemode.lua`, same `finish` block |

All three were added by the always-available landing: `lua/core/counters.lua` exists from **`ed220211`**
(`git log --diff-filter=A -- lua/core/counters.lua`), which also added the `/stats` rows
(`lua/core/chat.lua`). `lua/core/handle_wake.lua` exists from **`d8e8f8e5`** - not `a61d3ad1`, the hash
`docs/missions/reports/always-available.md` cites: that branch was rebased, so its hashes no longer name
these files.

**Storage.** One row of the node's own ledger - `meta['codemode.counters.v1']`, written through
`memory.meta_get/meta_set`; `wa counters` prints the resolved ledger path on its first line. Since
`246137b2` the same document also carries `days`: one bucket per calendar day, the newest 30 kept and
pruned on every bump, beside the three totals. `read()` still answers the three numbers and nothing
else, so `/stats` and every other reader see exactly what they saw before.

**The one command** (`lua/core/init.lua`, the `counters` arm; `wa stalls` is the model it follows):

```
wa counters                 # cumulative + the last 3 calendar days
wa counters --days 7        # any window it keeps (1..30)
wa counters --json          # the same document, for a script
```

Before `246137b2` there was **no command**: the three numbers were printable only from inside the
interactive chat (`/stats`), as a paged balloon - nothing an operator or a shell could run
(`git log -S 'command == "counters"' -- lua/core/init.lua` names only that commit). `wa stats` prints
`memory.stats()` only (`lua/core/init.lua`, the `stats` arm).

Sample output on a scratch ledger, after four bumps (one into yesterday's bucket):

```
counters - the three numbers the next mission is planned from (docs/CODEMODE.md)
  stored in meta[codemode.counters.v1] in <scratch ledger>

cumulative, since this store was first written:
  wake_only_round           2   a model step whose only input was a settled handle
  script_cut_at_cap         3   a script was told "not yet" (its work outlived the wait) - the pending half only
  handle_mishandled         1   a script used a pending answer as a result, or ended on the wait-never-settles bound

last 3 calendar day(s), on this node's own clock:
  2026-11-22  wake_only_round 2  script_cut_at_cap 3  handle_mishandled 0
  2026-11-21  wake_only_round 0  script_cut_at_cap 0  handle_mishandled 1
  2026-11-20  not recorded (this store kept no day before it learned to; nothing is claimed about that day)
```

`script_cut_at_cap` still measures the pending-answer half only: "hit its deadline with lines still to
run" is **not** counted, and `wa counters` says so in that row's own label rather than folding it in.

## Item 3 - the last three days on the live ledger: what I could not do

I could not read the live ledger: the node's own agent tooling refuses it by name before any command
runs -

```
tools.bash failed: lua/core/secret_guard.lua refused bash: secret path denied (secret_path_denied).
this is the node's own store: it holds the MCP registry, every connector's approval and the session
ledger, so an agent tool neither reads nor writes it (wa show / wa vault are the surfaces)
```

So the live numbers are **not in this report**, and I did not guess them. The orchestrator runs one of
these on the node once this branch is installed (the Lua reaches a node through the tree deploy; a
checkout's Lua is refused against the operator's own ledger by `lua/core/init.lua`):

```
wa counters --days 3
```

and adds the three lines it prints to the first table above. What it will show today, measured here on
a scratch ledger: the cumulative totals, and `not recorded` for every day before `246137b2` was
installed - which is the correct answer (nobody measured those days) and the reason the first table
says "not justified yet" rather than "low".

## Tests, and where they are wired

| row | what it holds | wired |
| --- | --- | --- |
| `scripts/test-codemode-counters.lua` (extended, 11 -> 29 checks) | `read()` still answers three names (no `days` leak); a bump lands in today's bucket and moves the total by one; a bump that names a time lands in THAT day only; an unseen day is `recorded=false` and claims nothing; the book keeps exactly 30 days and drops the oldest; **the command, cross-process**: `wa counters --json` in this row's own home prints this ledger's numbers and the same window, `wa counters` exits 0 and names all three, `wa counters --days 0` is refused | fast path (globbed by `scripts/fast.sh`, not in `scripts/fast-path.exclude`) |
| `scripts/test-handle-wake.lua` (extended, 16 -> 17) | each still-pending handle names its own state, not only its tool and age | fast path |
| `scripts/test-handle-wake-turn.lua` (extended, 10 -> 20) | two handles pending, a settlement claimed and run, then a **scheduled** wake whose provider input keeps its old two lines and lists BOTH handles with their state, once (never two lists), and is not counted as a wake-only round | fast path |

Discrimination, measured on a separate worktree of `e7bf6d56` with only these test files copied in:

* `test-codemode-counters` : `attempt to call a nil value (field 'day_of')`
* `test-handle-wake` : fails on the state word (`op (bash, running, ...)` absent at base)
* `test-handle-wake-turn` : `and it lists BOTH handles the session still holds: [self-wake ...]`

No pre-existing failure was found: 19 rows that mention `selfloop`, `self_wakes` or `handle_wake` were
run on this branch with the new Lua and all are green (two of them, `test-compact-idle-pending` and
`test-session-park`, refuse a home that is not under `GATE_ROOT`/`TMPDIR`; they pass with `TMPDIR` set,
which is what their own guard asks for). The full gate was not run - that is the landing gate's job, and
this branch adds a command, a day book and a wake block.

## Texts to approve (new or changed, operator- or model-facing)

1. `counters - the three numbers the next mission is planned from (docs/CODEMODE.md)`
2. `  stored in meta[codemode.counters.v1] in <ledger path>`
3. `cumulative, since this store was first written:`
4. `last %d calendar day(s), on this node's own clock:`
5. `  %s  not recorded (this store kept no day before it learned to; nothing is claimed about that day)`
6. `  (no day recorded yet: nothing was counted in this window)`
7. `counters: --days must be 1..30 (the store keeps 30 days)`
8. `wa help`: `counters [--days N] [--json]  the three counters (wake_only_round, script_cut_at_cap, handle_mishandled), cumulative and per calendar day`
9. The three labels printed beside the totals: `a model step whose only input was a settled handle` /
   `a script was told "not yet" (its work outlived the wait) - the pending half only` /
   `a script used a pending answer as a result, or ended on the wait-never-settles bound`
10. Wake block (model-facing): `Your earlier calls are still running; each one wakes this session when it settles:`
11. Wake list line (model-facing, changed): `Still pending (2): <op> (bash, running, 4s), <op> (bash, running, 4s)`
    (was `Still pending (2): <op> (bash, 4s), <op> (bash, 4s)`)

## Premises of the brief that were stale (re-measured here)

1. **"items 5 and 10 landed inside always-available"** - true, but the hashes that report cites no longer
   name the files: `lua/core/counters.lua` is `ed220211` and `lua/core/handle_wake.lua` is `d8e8f8e5` in
   this tree (`git log --diff-filter=A`), not `821d2395`/`a61d3ad1`.
2. **"the thresholds in seat-list section B"** - section B states none. It says "Go when
   `wake_only_round` and `script_cut_at_cap` are high" and "go when wakes per fan-out are high", with no
   number for "high". A gate with no threshold cannot fire, so one has to be agreed; a starting point
   offered as a proposal, not a measurement: durable scripts when `script_cut_at_cap` >= 5/day for three
   days AND `wake_only_round` >= 5/day - i.e. five model rounds a day exist whose only input was a
   settled handle, the rounds a resumed script would have saved.
3. **"the one command that prints them"** - there was none: only `/stats` inside the chat. Added in
   `246137b2`.
4. **"pending work listed on every wake"** - true of settlement wakes only at base. Timer/event/probe
   wakes carried nothing; fixed in `c4a46753`.
5. **the wake-conditions gate ("wakes per fan-out")** - no counter for it exists at all, so that gate
   cannot be read today. Named here rather than folded into `wake_only_round`.

## Not done, and why

* **The live numbers** (item 3): refused by `secret_guard`, quoted above. Command delivered instead.
* **Back-filling the day book from the ledger** for days before `246137b2`: no ledger row carries the
  same event as `script_cut_at_cap`/`handle_mishandled` (they are bumped at a script's end, not written
  as harness events), so a back-fill would be a different number wearing the same name. The window says
  `not recorded` instead.
* **A `wakes per fan-out` counter**: it needs an agreed definition of a fan-out (handles opened by one
  run?), which this mission was not asked to fix; it is the missing piece for the wake-conditions gate.
* **The full gate** (`scripts/test.sh`): not run here - the targeted rows above were, on this branch.

