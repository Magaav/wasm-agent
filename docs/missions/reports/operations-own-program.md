# operations-own-program — the process runner becomes its own program (Fable 26/11, move order step 3)

**Verdict: measured, planned, and slice 1 landed — and the measurement says the brief's premise was right
for the wrong reason.** The runner is not one file that links OS calls; it is a facade (`operations.rs`,
3,305 lines of policy) in front of a library that already owns process groups, the env rule and a
per-boot ledger with cross-process reattach (`wa-operation`, 5,296 lines). That library half is why this
can't be a component (43 WIT worlds, none with process control), and its lease-file reattach is why a
supervisor program is safe to introduce: the adoption story already exists and is reused, not rebuilt.

Slice 1 (commit **f94e6d56**): `wa operations-supervisor` owns the children, `operations::control`
forwards to it when `WASM_AGENT_OPERATIONS_SUPERVISOR` names its rendezvous file, and the default (unset)
is exactly today's in-process path. Rows: `start`/`status`/`cancel`/`await` answered identically by two
real processes, cancellation reaching the child's process group in both, `GH_TOKEN` withheld from the
child in both.

## 1. Premises re-measured (rule 9: the brief's facts may be stale)

| premise | brief | measured in this tree (522e12ae) | verdict |
|---|---|---|---|
| `operations.rs` size | 3,305 lines | `wc -l` = 3,305 | right |
| commits touching it, 30 d | 39 | `git log --since=30.days --oneline -- rust/wa-capabilities/src/operations.rs \| wc -l` = **44** | **stale** |
| no WIT world carries process control | "15 worlds" | `ls wit` = 15 directories, `rg -n '^world '` = **43 worlds**; the only `exec` is SQL (`wit/kernel/deps/.../kernel.wit:101`), `spawn` in `wit/agent-control/types.wit` is an agent session | right, count corrected |
| rows that must stay green | 10 `test-*operation*` rows | `ls scripts \| grep -cE '^test-.*operation'` = 10 | right |

## 2. What the surface is, and what it needs

Entry points (all read in this tree): `host.operation` (`rust/wa-capabilities/src/host.rs:1772`, registered
`capabilities.rs:178`), `host.exec` → `operations::foreground` (`host.rs:1864`), `run_bounded`
(`host.rs:1751`), `POST /operation` / `GET /operations` (`serve.rs:4588-4589` → `lua/core/server.lua:837`),
`operations::health()` (`serve.rs:1678/1680/1686`, consumed by `rust/wa-sentinel/src/main.rs:588`),
`observe_owned_child` (`resources.rs:415`), and **55** `host.operation` references in 13 Lua files.
One verb table: `operations::control` (`operations.rs:1380`) with 15 actions, plus `foreground`, `health`.

What it needs, with file:line, all of it outside a guest's reach: `process_group(0)` (`process.rs:65`),
`kill(-group, SIGKILL)` (`process.rs:124`), group liveness (`:134`), `PRIO_PGRP` (`:154`); `DENY_ENV`
(`lib.rs:36`) and `DENY_ENV_SUFFIXES` (`:54`) applied at `process.rs:74`, re-granted only by exact name
through `set_env_allow` (`lib.rs:115`, filled from `policy.json`'s `tool_env_allow` at `operations.rs:845`);
the ledger `$HOME/.wasm-agent/operations/` — per-id `state.json`, `index.sqlite`, and one lease file per
boot held `BEGIN EXCLUSIVE` for the life of the owning process (`index.rs:30-33`).

**The one fact that shaped the slice:** `Manager::cancel` (`lib.rs:1203`) sets a flag on an entry this
process holds, so a second process cannot cancel another's child. `Manager::snapshot` (`lib.rs:1069`) *can*
answer about a foreign id — `reattached: true, owner_live: true` while the owner's lease is held
(`lib.rs:1090-1110`), or `outcome_unknown` with the disk's output sizes when it is gone (`:1120-1165`).
So `start` and `cancel` must cross together, and adoption is already solved by the lease.

## 3. What landed (commit f94e6d56, 8 files, +989)

- `rust/wa-capabilities/src/operations_supervisor.rs` (new, 439 lines): the supervisor server, the
  forwarder, and 5 unit rows. One route, `POST /control {"action","args"}` → `{"ok":true,"value":…}` /
  `{"ok":false,"error":…}`; the answer is the same JSON `host.operation` returns. Token: 32 random bytes
  (ring `SystemRandom`) in a 0600 rendezvous file written by rename, checked with
  `ring::constant_time::verify_slices_are_equal` **before** the verb is read. `SERVING` makes the
  supervisor's own `control` calls run locally (no loop).
- `rust/wa-capabilities/src/operations.rs` (+6): the early branch in `control` — `if let Some(answer) =
  crate::operations_supervisor::forward(action, args) { return answer; }`. Unset env ⇒ `None` ⇒ the code
  below runs unchanged.
- `rust/wa-host/src/main.rs` (+20): `wa operations-supervisor [--port] [--rendezvous]`.
- `rust/wa-capabilities/src/lib.rs` (+3): `pub mod operations_supervisor;`.
- `scripts/test-operation-supervisor.cjs` (new) + `scripts/lib/operations-supervisor-row.lua` (new) +
  `scripts/test.sh` (+4: `gate_run node scripts/test-operation-supervisor.cjs "$BIN"` beside
  `test-operation-control.cjs`).
- `ready-operations-own-program.md` (new, the plan the brief asked for).

`lib.rs` and `main.rs` are touched only to place the mode (`pub mod operations_supervisor;` and the
subcommand block); the capability registration — `capabilities.rs:178` and `host.rs:1772` — is untouched,
so this cannot collide with the capability-registration-is-data worker.

## 4. Proof, and what each row actually ran

`scripts/test-operation-supervisor.cjs` starts **two real processes on one machine**: `wa
operations-supervisor` in its own scratch home (rendezvous 0600, pid matched against the process the
harness spawned) and `wa` running the Lua row twice — once in-process (switch unset) and once wired. The
assertions themselves run on the product's interpreter (`WA_SCRIPT`), through `tools.dispatch` like any
other tool call, and the harness compares the two answers:

1. **identical answers** — same key set and same values for `start`, `status`, `cancel`, `await`,
   `settled`, with a *named* list of per-process fields excluded (ids, boot, paths, timings,
   `output_streams_closed`), plus, for `cancel` only, the transient state a request reports;
2. **identical cancellation** — in both runs the child wrote its marker line before the cancel and none
   after it, and both records settle (`state: cancelled`);
3. **identical env withholding** — with `GH_TOKEN` in the supervisor's own environment, both children read
   `gh=[]` and both records name `GH_TOKEN` in `env_withheld` with the note naming `tool_env_allow`;
4. **the answer came from the other process** — the wired `identity` answers the supervisor's pid and its
   ledger boot, and differs from the in-process pid.

Verdicts: **42 checks, 4 of 4 consecutive runs green.** Against the base binary the row fails at "the
supervisor wrote its rendezvous" (installed base binary, so the failure is the missing mode, not a missing
build). The repo's own gate agrees: `flock -o ~/Work/missions/.suite.lock bash
scripts/test-discriminates.sh origin/main` on this branch answers `discriminates\tscripts/test-operation-supervisor.cjs`
— **1 discriminating, 0 blocking** — with its reason printed verbatim: the scratch base worktree has no
built binary at `base/rust/target/release/wa`, so that run failed on the binary rather than on the mode;
the stronger statement is the installed-binary one above. The 5 new unit rows pass
(`operations_supervisor::tests::*`). Existing rows re-run on this branch: `test-operation-survives-turn.lua`
16 checks, `test-operation-cwd.lua` 31 checks, `test-operation-reconcile-json.cjs` 27 checks — all green.

**How I checked the rows read real stores** (Fable 24/11): nothing is stubbed. The row builds its manager
through `wa`'s own `operations::manager()` in a scratch `HOME`; the supervisor writes the same
`$HOME/.wasm-agent/operations` layout the node writes, and the comparison runs the same Lua path
(`tools.dispatch`) the product runs. The harness refuses to be the node: its scratch root is `/tmp` even
when `TMPDIR` points inside `~/.wasm-agent`, and the Lua row refuses to run unless `WASM_AGENT_HOME` is a
scratch/temp directory and not `~/.wasm-agent`.

**Pre-existing failure on this node, not this change:** `scripts/test-operation-control.cjs` (both
invocations) fails with `timeout: real tool produced output` — and fails identically with the installed
base binary `~/.local/bin/wa` (built 25/11 08:06, before this branch). Named, not fixed here.

## 5. Before/after (rule: host build wall time and bytes)

Measured on this node (avell, 16 cores), `cargo build --release -p wa-host` with
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-operations-own-program`, code-mode assets resolved the
way `scripts/lib/fast-binary.sh` resolves them, **like for like**: `touch
rust/wa-capabilities/src/operations.rs` first, then the build, each tree warm.

| | wall | `release/wa` bytes |
|---|---|---|
| origin/main (`/tmp/base-ops`, warm) | 23.45 s | 79,712,792 |
| this branch (warm) | 28.40 s | 79,717,928 (+5,136) |

**The request bytes of a healthy call, measured before and after** (the rule the brief names first):
a dump script builds the model-facing catalogue through the product's own `tools.all('master', ctx,
memory)` with `WASM_AGENT_LUA_ROOT` fixed to this tree, canonically encodes it and hashes it. Both the
base binary (`~/.local/bin/wa`) and this branch answer **66 tools**, canonical sha256
`a79260f6af9bcb2cf1fcafd24572f61ae1ccf71e121d626dd06a324659d6ad85`, and the `operation` tool's own spec
`210b6b65484295d41cbb1e9306f1b831ae1deaea8c501fe26168faa863d0f5b7`. Identical: nothing this move did is
visible to the model's prompt.

One measurement each, so the +5 s is within the noise of a link plus one module; the +5,136 bytes is the
module. **Nothing moved out of the host in slice 1**, so this is the expected shape — the build win is
slice 2 (§6), exactly as `ready-operations-own-program.md` §2.1 says. A healthy call's request bytes are
unchanged: no capability description, no schema, no Lua file was touched (`git show --stat f94e6d56`).

## 6. The rest of the plan (in `ready-operations-own-program.md`)

- **Protocol**: a named gap, not a WIT world — `wit/kernel` is guest→host, `wit/queue` carries a job not a
  blocking `await`, `wit/agent-control`'s `spawn` is an agent session. The repo's existing pattern for
  "another program talks to the node" is loopback HTTP (`client_bridge.rs:353-400`), which is what the
  supervisor follows, plus a token because `start` is a process launch on a machine where loopback is
  every local user.
- **Slice 2** (not started): move `operations.rs` into the supervisor's own crate so `wa-capabilities`
  drops `wa-operation`; that is the commit that pays the build claim and that gives `health()`,
  `foreground` and the node-wide listing one owner. Until then those three stay in the node — named here,
  not claimed.
- **Shipping a second artifact is a release hunk** (Fable owns it). Slice 1 therefore ships as a mode of
  the existing `wa` binary: no installer, deploy or `installed.txt` change (FACTORY rule 12 respected —
  nothing was installed).

## 7. Texts to approve (new operator-facing strings, verbatim)

1. `usage: wa operations-supervisor [--port 8791] [--rendezvous <file>]`
2. `  own this node's supervised operations (blocks until stopped)`
3. `  the node reaches it through WASM_AGENT_OPERATIONS_SUPERVISOR=<the rendezvous file>`
4. `[operations-supervisor] listening on <ip>:<port> pid <pid> rendezvous <path>`
5. `operations-supervisor: <error>` (startup failure, then exit 1)
6. `operations_supervisor_already_running: <file> answers at <address>:<port>`
7. `operations_supervisor_bind: <address>:<port>: <error>`
8. `operations_supervisor_ledger: <error>`
9. `operations_supervisor_unavailable: read|parse <file>: <error>`
10. `operations_supervisor_unreachable: <address>:<port>: <error>`
11. `operations_supervisor_token_required` (403, checked before the verb is read)
12. `operations_supervisor_post_only` (405) / `operations_supervisor_unknown_route` (404)
13. `operations_supervisor_too_many_connections` (503) / `operations_supervisor_request_unreadable: <error>` (400)
14. `operations_supervisor_head_too_long` / `operations_supervisor_body_too_large` / `operations_supervisor_no_request`
15. `operations_supervisor_token_unavailable` / `operations_supervisor_root: <path>: <error>` / `operations_supervisor_rendezvous: <path>: <error>`
16. row texts: `operation supervisor ok: <n> checks`, `FAIL operation-supervisor: <label>`

## 8. What I did not do, and one mistake of mine

- Not done: slice 2 (the crate move), the separate supervisor artifact, and any deploy/install change.
- Not done: `power`/`quarantine` verbs beyond the ones the row exercises; the forwarder carries every
  action but only `start`/`status`/`cancel`/`await` are proven by a row. Said plainly rather than implied.
- Not claimed: behaviour of the wired path under a supervisor restart (the lease/`outcome_unknown` path is
  read in the code and planned in §2.4 of the ready file, but no row exercises it — that is slice 2's row).
- **My mistake:** once, while checking the rendezvous mode by hand, I stopped the supervisor I had just
  started with `pkill -f "<unique temp path>"` instead of the pid from its own log. It matched only my
  own process, but rule 17 says stop the pid you started; the harness itself kills `supervisor.pid`.
- The commit trailer names `wa worker (wasm-agent)`: this harness does not report a model id, and inventing
  one would be a false record. If the fleet wants a specific id there, it needs to be corrected by hand.
