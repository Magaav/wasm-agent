# ready-operations-own-program — the process runner becomes its own program

**Verdict: the move is feasible without a new WIT world, and the hard half is already built.** The
operations surface has exactly one choke point (`operations::control` + `operations::manager()`, both in
`rust/wa-capabilities/src/operations.rs`), and the cross-process half of ownership — a second process
reading an operation it did not spawn, with a lease that says whether the owner is alive — already exists
inside `rust/wa-operation` (`Manager::snapshot`'s disk fallback, `lib.rs:1090-1165`). What is missing is
(a) a program that hosts the manager, (b) a wire, (c) the forwarder. This file measures all three premised
facts again, plans the program, and defines the first slice.

## 0. Premises re-measured (the brief's numbers, checked)

| premise | brief | measured (this tree, 522e12ae) | ok? |
|---|---|---|---|
| `operations.rs` size | 3,305 lines | `wc -l` = **3,305** | yes |
| commits touching it, 30 days | 39 | `git log --since=30.days --oneline -- rust/wa-capabilities/src/operations.rs` = **44** | **no, stale** |
| the crate it leans on | `rust/wa-operation` | 5,296 lines / 10 files: lib 1,707, tests 1,750, windows 431, blocked 292, index 254, redact 222, process 214, shell_env 195, quarantine 135, legacy 96 | yes |
| no WIT world carries OS process control | "15 worlds, none" | `ls wit` = **15 world directories**, but `rg -n '^world '` = **43 worlds**; none exposes a process: the only `exec` is SQL (`wit/kernel/deps/.../kernel.wit:101`, `wit/kernel/sql.wit:77`), and `spawn` in `wit/agent-control/types.wit` is an agent session, not a program | yes, count corrected |
| rows that must stay green | "10 `test-*operation*` rows" | `ls scripts | grep -cE '^test-.*operation'` = **10** | yes |

Nothing in this mission was built from a guess: every line below was read in this tree.

## 1. The surface, with file:line

### 1.1 Entry points (who calls the runner)

| entry | file:line | shape |
|---|---|---|
| `host.operation(action, args_json)` — the Lua capability | `rust/wa-capabilities/src/host.rs:1772` (registered `capabilities.rs:178`, `plain!("operation", RunsProcess, crate::host::operation, ...)`) | JSON text in, JSON text out |
| `host.exec` (the `bash` tool's execution) | `host.rs:1864` → `operations::foreground` | foreground, blocks |
| `run_bounded` (a child's own shell call) | `host.rs:1751`, calls `foreground` at `:1767` | foreground, bounded by the child's budget |
| `POST /operation`, `GET /operations` (the node's HTTP surface) | `serve.rs:4588-4589` → Lua `wa_operation` (`lua/core/server.lua:837`, which ends in `host.operation`) | same JSON |
| `operations::health()` (`/health`, the executor's busy signal) | `serve.rs:1678`, `:1680`, `:1686`; consumed by `rust/wa-sentinel/src/main.rs:588` | node-wide list of unsettled operations |
| `observe_owned_child` (a claimed resource's process) | `rust/wa-capabilities/src/resources.rs:415` | attach, not spawn |
| Lua callers | **55** `host.operation` references in **13** files: `nodes.lua` 10, `accepted.lua` 8, `workspaces.lua` 7, `mcp_session.lua` 7, `idle_reads.lua` 5, `mcp.lua` 4, `session_watch.lua` 3, `fleetview.lua` 3, `tool_progress.lua` 2, `server.lua` 2, `land.lua` 2, `tools.lua` 1, `chat.lua` 1 | `pcall(host.operation, action, json)` |

### 1.2 The verbs (one `control()`, `operations.rs:1380`)

`start` (:1383), `list` (:1543), `relevant` (:1555), `index` (:1573), `reconcile` (:1574),
`quarantine_retire` (:1589), `legacy_adjudicate` (:1593), `allocation_safety` (:1597), `identity`
(:1598), `status` (:1600), `background` (:1608), `await` (:1612), `cancel` (:1667), `wait` (:1677),
`read` (:1692); plus `foreground` (:1125) and `health`/`health_scope`/`health_scope_for`/`elsewhere_count`
(:1717/:1728/:1739/:1768).

### 1.3 What the runner actually needs (the reasons it cannot be a component)

- **Process groups**: `rust/wa-operation/src/process.rs:65` `process_group(0)`; `:124`
  `libc::kill(-group, SIGKILL)` (the whole tree, not the shell); `:134` `kill(-group, 0)` liveness;
  `:154` `PRIO_PGRP` setpriority. Windows: `windows.rs` Job Objects.
- **The env rule**: `DENY_ENV` (`lib.rs:36`: `WA_VAULT_ADMIN_TOKEN`, `WASM_AGENT_VAULT_ADMIN_TOKEN`,
  `WASM_AGENT_PROMPT_CACHE_KEY`, `WASM_AGENT_LLM_API_KEY`, `GH_TOKEN`, `GITHUB_TOKEN`,
  `ANTHROPIC_AUTH_TOKEN`) and `DENY_ENV_SUFFIXES` (`lib.rs:54`: `_API_KEY`, `_TOKEN`, `_SECRET`,
  `_PASSWORD`, `_SECRET_ACCESS_KEY`, `_PRIVATE_KEY`) minus the node's allow-list (`set_env_allow`
  `lib.rs:115`; filled from `policy.json`'s `tool_env_allow` by `operations.rs:845` at manager construction,
  `operations.rs:853`). Applied once, at `process.rs:74`.
- **The ledger**: `$HOME/.wasm-agent/operations/` — one directory per id with `state.json`, plus
  `index.sqlite` (`index.rs:25-40`: `operations`, `meta`, `reconciliation`, `legacy_quarantine`,
  `risk_quarantine`, `history`) and **per-boot lease files** `<boot>.lease.sqlite` held under
  `BEGIN EXCLUSIVE` for exactly as long as the owning process lives (`index.rs:30-33`).
- **Admission glue that is policy, not spawn**: staged scripts over the Windows 8192-byte `-c` cut
  (`operations.rs:890-925`), `cap_guard` (disk cap, `:1073`), the vault approval + request seal
  (`:550-790`), `REFUSED_WRAPPERS` (`:320`), the 17 wrappers a command may not hide behind.
- **Already cross-process**: `Manager::snapshot` (`lib.rs:1069`) falls back to disk for an id it does not
  track and answers `reattached: true, owner_live: true` when the owner's lease is still held, or
  `state: "outcome_unknown"` with the disk's output sizes when the owner is gone (`lib.rs:1090-1165`).
  **Not** cross-process: `Manager::cancel` (`lib.rs:1203`) sets an in-memory flag on an entry it holds —
  a foreign process cannot cancel another process's child. This one fact decides the first slice.

## 2. Plan

### 2.1 The program

**As built (slice 1, commit f94e6d56): `wa operations-supervisor`** — this binary in a second mode, so a
supervisor is a process with its own lifetime, its own ledger lease and its own process groups, while
nothing is installed and no release hunk is touched (a second **artifact** would be a release change, and
those go to Fable). It hosts exactly one thing: `Manager` + the verb surface, built with the same
`policy.json` allow-list and the same `$HOME/.wasm-agent/operations` root the node uses today. It is a
program, not a component, because 43 WIT worlds offer no process control (§1.3) and because ownership must
outlive an interpreter and a node restart.

The crate split that makes the supervisor a *smaller* artifact, and lets the host stop depending on
`wa-operation`, is **slice 2**: it moves `operations.rs` into the supervisor's own library crate and gives
`health()`, `foreground` and the node-wide listing the same owner. That is the commit that pays the
build-time claim ("5 of 42 wa-capabilities commits kept out", ready-carve.md §2); slice 1 pays nothing there
and is not to be read as the move being done.

### 2.2 The protocol (a named gap, and why)

The brief asks whether `wit/kernel`, `wit/queue` or `wit/agent-control` fit. They do not, and this is the
named gap:

- `wit/kernel` is the guest→host import surface (SQL, clock); a host→program call is the other direction.
- `wit/queue` is a durable producer/consumer with double-settle refusal (`queue.wit:167`); it carries a
  job, not a *blocking* `await`, and no request/reply pair with a JSON answer and a cancel flag.
- `wit/agent-control`'s `spawn` is an agent session behind the supervisor interface, not an OS program.

What the repository does have for "another program talks to the node" is a **loopback HTTP client**
(`rust/wa-capabilities/src/client_bridge.rs:353-400`: bind-retry, one thread per connection, a connection
cap, a `/health` status line), and `wa-window` polls it (`rust/wa-window/src/client.rs:43-91`). So the
supervisor speaks **loopback HTTP, one route**, with the same JSON in and out as `host.operation`:

    POST http://127.0.0.1:<port>/control   {"action":"start","args":{...}}  ->  <the exact JSON answer>

with two additions that exist for a security reason, not for style:
1. a **token** (`$HOME/.wasm-agent/operations-supervisor.json`, mode 0600, random 32 bytes hex) that every
   request must carry in `x-wa-operations-token`; the port is on loopback, but loopback is every local
   user and every other process of this node, and `start` is a process launch.
2. the listener binds `crate::serve::bind_address()` — the same address the node's own surface uses, so a
   node configured to stay on `127.0.0.1` does not get a supervisor on `::`.

### 2.3 What the host keeps

`host.operation` (`host.rs:1772`), `host.exec`/`run_bounded` (`host.rs:1864`/`:1751`), the `/operation`
routes (`serve.rs:4588-4589`), `health()` (`serve.rs:1678`) and the Lua callers (§1.1) — unchanged. Behind
them, `operations::control` gains one early branch:

    if supervisor_mode() { return forward(action, args) }   // same JSON in, same JSON out
    ... today's path, unchanged ...

`WASM_AGENT_OPERATIONS_SUPERVISOR` (unset = **in-process**, today's behaviour byte for byte). The forwarder
is one function with no verb knowledge: it posts `{action,args}` and returns the answer, or returns
`{"ok":false,"error":"operations_supervisor_unreachable: <why>"}` — a named refusal, never a silent
fall-back to in-process (an operation whose owner silently changed is a second copy of the work).

### 2.4 Restart and adoption (what happens when one side restarts)

The property that makes this safe already exists; the plan is to use it, not to invent a second mechanism.

| reboot | today (one process) | with the supervisor |
|---|---|---|
| **host restarts, supervisor and children alive** | the host re-reads `state.json`; the supervisor's lease is held ⇒ `reattached: true, owner_live: true` (`lib.rs:1090-1110`) | identical answer, and `cancel` is **forwarded** to the supervisor (which holds the entry) instead of failing |
| **supervisor restarts, host alive** | n/a | same lease rule from the supervisor's side: the old boot's lease is gone ⇒ every unsettled record answers `outcome_unknown` with the disk's output sizes (`lib.rs:1120-1165`); the forwarder's first call after the restart refuses by name until the new rendezvous file is read (one retry, then refuse) |
| **both restart, children orphaned by SIGKILL** | `outcome_unknown`, never replayed (`index.rs` `reconcile`/`quarantine`) | unchanged — the new supervisor's boot is a new lease, and the old records are settled or quarantined by the same code |

The one new failure mode is "two supervisors": the lease file is per boot, but nothing prevents a second
supervisor from starting on a second port. Slice 2 therefore takes an exclusive lock on
`operations-supervisor.json`'s companion lock file before it writes a rendezvous; slice 1 refuses to start
when the rendezvous file names a live supervisor (proven by the same lease trick).

### 2.5 The security line

`DENY_ENV` stays in `wa-operation` (`lib.rs:36`/`:54`), applied at the one boundary every child crosses
(`process.rs:74`) — the supervisor imports it because it hosts `Manager`, it does not re-implement it. Two
consequences the review must hold me to:
1. **the host no longer constructs the env**: in supervisor mode the child is spawned by a process whose own
   environment is the supervisor's, so the supervisor's `DENY_ENV` result is the child's env. The env
   withholding row (§3) is therefore *the* row, and it must run on the wired path.
2. **the wire must not become a way around admission**: the token is checked before `control` runs, the
   listener is loopback-only, and the supervisor never accepts a `program`/`command` that the host's own
   admission would have refused — slice 1 gets that for free by reusing `operations::control`
   (admission *and* execution in the same code); slice 2 must keep it when the glue moves.

## 3. First slice (this mission) — **landed in f94e6d56**

Measured result: the row is green 4 of 4 consecutive runs (42 checks) and fails on the base binary;
five unit rows green; `cargo build --release -p wa-host` warm with `operations.rs` touched: origin/main
23.45 s / 79,712,792 bytes, this branch 28.40 s / 79,717,928 bytes. The report is
`docs/missions/reports/operations-own-program.md`.

One switch, one forwarder, one program, and rows that prove the three properties the brief names.

- **Switch**: `WASM_AGENT_OPERATIONS_SUPERVISOR` = address of the supervisor (`127.0.0.1:<port>`) + token
  file; **unset means in-process**, which is what every node runs today.
- **Verbs that cross**: `start`, `status`, `cancel` (the lifecycle of one id: `cancel` cannot stay
  in-process while `start` does not — §1.3, `lib.rs:1203`). The forwarder carries any action, but only
  these three are claimed, and the report names which are not exercised by a row.
- **Rows** (`scripts/test-operation-supervisor.lua`, on the product's interpreter via `WA_SCRIPT`, wired
  into the fast path):
  1. **identical answers** — the same `start` request answered in-process and through the supervisor:
     every field equal except the id/boot/timing fields, listed by name, and the two answers compared
     canonicalised;
  2. **identical cancellation** — a child started through the supervisor, cancelled through the host's
     `cancel`, then its own marker file is absent/present exactly as the in-process run leaves it, and the
     answer says `settled` for both;
  3. **identical env withholding** — with `GH_TOKEN` present in the supervisor's own environment, the child
     reads it back empty through the wired path, and the record names it in `env_withheld` exactly as the
     in-process row does.
- **Wire row with two real processes** (Fable 24/11): scratch HOME A runs `wa-operations-supervisor`,
  scratch HOME B runs `wa` with the switch on; the row proves the two are different processes and that the
  answer came from the supervisor (its own `process_id` in `identity`, its own boot in the record).
- **Before/after**: `cargo build --release -p wa-host` wall time and `wa` bytes, same command both sides.

## 4. What I did not do

- No WIT world was written: §2.2 names the gap and the reason it stays a gap for this move.
- Nothing is installed, nothing is deployed, `installed.txt` is untouched (FACTORY rule 12).
- Slice 2 (moving `operations.rs` into the supervisor's own crate, and dropping `wa-capabilities`'s
  `wa-operation` dependency) is planned here and **not** implemented: slice 1 keeps the glue in the host on
  purpose, so a failure has one cause.
