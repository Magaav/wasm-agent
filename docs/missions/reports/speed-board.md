# speed-board: one speed table per commit, and a named red row when a number gets worse

change/speed-board, 22/11. Base 8862b600. Branch built in /home/victor/Work/missions/speed-board/wt.

## What the brief asked for, re-measured first (rule 9)

| premise | measured 22/11 | verdict |
| --- | --- | --- |
| `scripts/test-start-instant.lua` exists, measures start | 266 lines; it measures the turn's first model call (gap_ms) and asserts a hard `< 1000 ms` on ONE sample, with no load guard (lines 178-181, 225-227 before this change) | true, and its shape is the flake |
| `wa stalls` exists | `lua/core/stalls.lua`, `scripts/test-stalls.lua`, `wa stalls` CLI | true, untouched here |
| `scripts/main-health.sh` records per commit | it recorded `{sha, ok, failed, counts, seconds, at, log}` - no timings at all | true |
| land-quick keeps its own timings | **wrong**: land-quick.sh kept none. `_quick/line.log` has only HH:MM written by `line.sh`, not by land-quick, and nothing machine-readable | instrumented (see below) |
| the release gate's duration | the release journals already carry it: `gate[]` with `seconds` per check, and `created_at`/`updated_at` (release-20261122T183455Z: 1150 s cut -> published, of which `fast` 523 s, `cargo-codemode` 161 s, `cargo-wa-whatsapp` 62 s) | no instrumentation needed |
| status.sh shows a speed table | it did not | added |
| "test-start-instant stopped a release gate twice on 22/11" | **not confirmed as a gate stop**: no gate row naming start-instant failed in any `~/.wasm-agent/land/*/journal.json` on this machine. The flake is real and recorded in a worker's fast path: `~/Work/missions/whatsapp-finds-owner/out.log:14067` "FAIL lua scripts/test-start-instant.lua (exit 1): start-instant: 1 FAIL", green twice when run alone (line 14237) | the flake is real; the "twice, in a release gate" is not in the records I can read |

## What was built

All in the repo, cited by commit:

- **f31f4721** - the four live probes under `scripts/speed/`:
  `probe-cold-start.py` (pty, spawn -> prompt up), `probe-first-token.py` (Enter -> the first byte the model
  sends, against `fixture-model.cjs`), `probe-tool-roundtrip.lua` (one `tools.read` inside `run(code=...)`),
  `probe-remote.sh` (one signed peer call between two scratch nodes on loopback).
- **64e91cc1** - `scripts/lib/speed-stats.lua` (median, load comparability, the window, RED at 20%),
  `scripts/speed-board.sh` (`--measure`, `--print`, `--check`), and their two tests
  (`scripts/test-speed-stats.lua`, `scripts/test-speed-board.lua`).
- **55677d10** - `scripts/main-health.sh` writes the speed line for every commit it judges, and
  `scripts/test-start-instant.lua` measures the median of three turns on a machine under its load ceiling.

Outside the repo (they live in `~/Work/missions`, which is not a git checkout; backups in
`~/Work/missions/.speed-board-bak/`):

- `land-quick.sh`: `started_at` at the top and a `record_landing` helper (9 lines) called on both paths that
  say "Local is evolved"; it appends `{branch, sha, seconds, load, at}` to `_quick/landings.jsonl`.
- `status.sh`: 6 lines that print `== speed (installed <sha>)` and the table, when the checkout has
  `scripts/speed-board.sh`.

The exact diff of both is in `.speed-board-bak/` beside the originals; both were checked with `bash -n`.

## The table, and how a number is kept honest

One JSON line per commit in `~/Work/missions/speed-history.jsonl` (`WA_SPEED_HISTORY` overrides it), oldest
first, a re-measured commit replacing its own line. Each row carries `samples`, the `ms` median, the `load` it
was taken at, and `state`/`reason`:

    {"at":"2026-11-23T00:38:49Z","cores":16,"load":4.01,"sha":"8862b60085fb...","rows":{
      "start":{"samples":[380,365,373,388,380],"ms":373,"load":4.09,"state":"ok"}, ... }}

Stability, per the brief's item 5:

- **Median of the samples, never a single sample and never a mean** - one sample taken while something else
  started is exactly what flaked on 22/11.
- **A discarded warm-up** where the first call pays a process's own cold state (the first-token turn, the
  first code-mode call): measured, that first turn is why the row would otherwise be a second cold-start row.
- **The load beside every row**, and only comparable loads are compared (within 25% + 0.5, in
  `speed-stats.load_comparable`).
- **A ceiling**: above 1.5 load units per core the four live rows are recorded as `guarded` with the reason
  and no number at all.
- **Fewer than three samples is `unknown`**, and a probe that refuses writes its own reason: never a zero,
  never green (rule 1).
- **test-start-instant**: same treatment, and the 1 s bound is unchanged. The quiet row is now the median of
  three turns taken only while the machine is at or under one load unit per core; a machine that stays
  busier than that for 60 s makes the row SKIP with the load in the reason. Measured after the change:
  "quiet ledger: the model call starts in under 1 s (median 643 ms of 652, 347, 643)" - note the spread,
  which is why one sample was the wrong instrument.

The rule for RED (item 3): the median is RED when it is more than 20% above the **best** of the last ten
commits **at a comparable load**, and the verdict names the row and the commit that holds the floor.
`--measure` exits 3 and prints `speed-board: RED <row>: ...`; main-health copies those lines to its own
stderr; `status.sh` prints them in the table. Nothing blocks a landing: main-health runs after it, and its speed
call is `|| true`.

## Measured on this node, 22/11 (avell, 16 cores)

Two full board runs, the second at load 4.01 (the machine was busy with other missions' suites):

| row | run 1 (load 4.76) | run 2 (load 4.01) | how |
| --- | --- | --- | --- |
| start | 362 ms | 373 ms (median of 380,365,373,388,380) | pty, spawn -> "memory:" header up |
| first_token | 236 ms | 236 ms | Enter -> the fixture's first SSE byte |
| tool_roundtrip | 127 ms | 127 ms | `tools.dispatch(memory,'codemode',{code="await tools.read(...)"})` |
| remote_roundtrip | 411 ms | 411 ms | `wa call peer bash` over a local rendezvous |
| landing | unknown | unknown | no landing recorded yet (the record starts with the next landing) |
| release | unknown | unknown | the newest journal on this machine is a release still running |

A third run on a quiet machine (load 1.97, 23/11 01:02Z, written to the real\n`~/Work/missions/speed-history.jsonl` as the first line): start 321 ms, first_token 223 ms, tool_roundtrip\n116 ms, remote_roundtrip 397 ms, landing unknown, **release 24.6 min** (1475 s cut -> published, from\n`release-20261123T003145Z-ee79b7c9`; the journal records no load, so the row carries the board's own and\nsays so).

The four live rows took 10.3 s of wall time together, so running the board after each health run costs about
that.

## Verified here

- **The fast path, whole, under the suite lock** (`flock -o ~/Work/missions/.suite.lock`, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-speed-board`):
  `fast result ok (399 checks, 0 failed, 0 skipped)` / `fast path ok (399 checks, 0 skipped, 662s)`, with
  `scripts/test-speed-board.lua pass`, `scripts/test-speed-stats.lua pass`, `scripts/test-start-instant.lua pass`
  in its own result file. The two new rows are wired by **being `scripts/test-*.lua` and not being in
  `scripts/fast-path.exclude`** - the fast path discovers them; the gate runs the same files.
- **Discrimination** (`WA_BIN=~/.local/bin/wa bash scripts/test-discriminates.sh 8862b600`, the installed binary
  being exactly the base commit), verbatim rows:
  `discriminates  scripts/test-speed-board.lua  speed-board: 21 FAIL of 23` /
  `new-symbol     scripts/test-speed-stats.lua  it died on code the base does not have: .../scripts/lib/speed-stats.lua` /
  `unchanged-verdict scripts/test-start-instant.lua  a modified test that still passes proves nothing about the fix, and does not block`.
  Nothing blocks. The hardening of test-start-instant is deliberately NOT a new assertion: its bounds are unchanged,
  so it cannot discriminate, and the report says so instead of pretending otherwise.
- **`--measure`, `--print`, `--check`** run for real on this node four times (loads 4.76, 4.09, 4.01, 1.97); the
  numbers above are from those runs.

## The three slowest things found while building this (candidate briefs; nothing fixed here)

1. **A non-interactive `wa chat` prints no prompt at all for 4 s, where a pty prints it in 0.36 s.**
   Measured 23/11 on 8862b600: `printf 'hi\n' | wa chat` with stdout on a pipe/redirect produced no
   `memory:` header within 4 s (twice), while the same command in a pty printed it at 329-383 ms. Everything
   that drives `wa` from a script (missions, agents, CI, this mission's own first probe version) waits on a
   path that is at least 10x slower to become usable, and the harness had to be rewritten around a pty to
   measure anything at all.
2. **A remote round trip is ~460 ms and it needs the caller to be a running node.** 411-477 ms (median 461) for
   one signed peer call carrying `printf ok` between two `wa` processes on loopback - about 5x the cold
   start of the process itself. Worse, with only the peer serving, every attempt answered
   `roster_unavailable` (240 attempts over 120 s): the rendezvous answers `GET /nodes` only to a node it can
   verify, and it learns a key when that node registers - so a node that never serves cannot call anybody, and
   the failure reads as a roster problem rather than "you are not registered".
3. **One tool round trip inside `run(code=...)` costs ~100-127 ms for a local file read**, which is the floor
   every tool call of every turn pays on this machine (five calls in a turn is over half a second). The cold
   start itself is 321-373 ms, and one call across the fabric is 397-411 ms.

And one thing that is not slow but is in the way, found while measuring (a candidate brief of its own):

4. **`secret_guard` refuses EVERY file under the tree's own `scripts/`.** `configured()` adds
   `WASM_AGENT_LUA_ROOT .. '/scripts'` as a secret root (`lua/core/secret_guard.lua:59-66`), so on a node
   running a tree, `tools.read` of `scripts/lib/speed-stats.lua`, `scripts/main-health.sh` and
   `scripts/speed/probe-common.py` all answer `secret_path_denied` (measured 23/11 on 8862b600: 3 of 4
   paths refused, `lua/core/memory.lua` allowed). An agent cannot read the repo's own test, bench or probe
   scripts through a tool, which is why this mission's tool round trip reads `lua/core/memory.lua`.

## Texts to approve (new or changed, verbatim)

1. `speed-board: <sha12> start=373ms@4.09 first_token=236ms@4.09 tool_roundtrip=127ms@4.09 remote_roundtrip=411ms@4.09 landing=unknown release=unknown (load 4.01)`
2. `speed-board: RED start: 900 ms, 800% slower than the best of the last 10 commits at a comparable load (100 ms at c0001ab12cd3)`
3. `speed-board: refused(unknown_argument): <arg>` / `speed-board: refused(no_mode): say --measure, --print or --check` / `speed-board: refused(tool_missing): <tool> is not on PATH, so nothing can be judged` / `speed-board: refused(no_commit): no --sha, nothing installed and no HEAD in <root>` / `speed-board: refused(history_write_failed)`
4. `unavailable: <reason>` (a probe's refusal, carried into the row) and `guarded: the machine was at load <x> on <n> cores (ceiling <c>)`
5. status.sh: `== speed (installed <sha>)` and the table heading `measured <at> at load <x> on <n> cores` / `  row   this   load  vs previous  verdict` / `no speed line for <sha> yet (scripts/main-health.sh writes one after every landing)`
6. main-health, on stderr: `main-health: speed-board: ...`
7. start-instant: `SKIP start-instant: the machine stayed at load <x> on <n> cores (ceiling <n>): a timing row cannot tell code from load`
8. the refusal that finding 4 measures, verbatim: `tools.read failed: lua/core/secret_guard.lua refused read: secret path denied (secret_path_denied).`
9. land-quick's record (a file line, not a printed string): `{"branch":"change/x","sha":"<12>","seconds":123,"load":4.5,"at":"2026-11-23T00:00:00Z"}`

## What I did not verify

- **A real main-health run**: the speed block was verified by running `scripts/speed-board.sh` with exactly the
  arguments that block builds (`--measure --root <tree> --sha <sha> --bin <installed>`), not by running a whole
  health cycle (which runs the whole fast path, ~10 min). The block is guarded by `[ -f .../speed-board.sh ]`
  and `|| true`, and `bash -n` passes.
- **A real landing record**: no landing has run since `land-quick.sh` was instrumented, so `landing` is
  `unknown` ("no landing recorded ... yet") in both runs above. The reader and its test are green against a
  fixture line, and the writer is 9 lines, but the two ends have not met on a real landing yet.
- **A finished release**: the newest release journal on this machine (release-20261123T003145Z) was still
  running while this was measured, so the row says so. The reader is tested against a fixture journal
  (`result: done`, `updated_at - created_at`).
- **The release row's load**: the journal carries no load, so that row carries the load at the time the board
  ran and says so in its reason. A release measured on a busy night will therefore compare against a quiet
  baseline; the reason field is the mitigation, not a fix.
- **Other machines**: the cold-start and remote probes are Linux-specific in places (pty, `/proc/loadavg`,
  `/dev/tcp`); on Windows the rows would be `unavailable` with the reason rather than wrong.

## How Victor tests it

    bash ~/Work/missions/status.sh

prints `== speed (installed <sha>)` with one row per number, the load it was measured at, the change against
the previous commit, and `RED` with the commit that holds the floor when a row is more than 20% slower.
