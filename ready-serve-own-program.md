# ready-serve-own-program — serve + core bridge as their own program (move-list row 8)

**Verdict: measured, and the row is three tiers, not one file set.** `serve.rs` is the node's inbound door
(5,248 lines: listener, admission, ~40 routes, the run worker, the scheduler, the SSE stream), `core_bridge.rs`
is its interpreter seam (590 lines: `call_string` answered by native Lua or by a pooled wasm instance), and
`core_component.rs` is that pool plus the guest's CLI mode (2,452 lines). The door and its interpreter are one
program's worth of state — which is why the row names all three — but the door's **static tier**
(`static_reply`, serve.rs:4320, called on the accept thread at serve.rs:2879 **before** admission) answers
without the interpreter at all. That tier is the first slice: it can leave the host process today without
taking the Lua core with it, and its answers can be compared byte for byte.

## 1. Measurement (this tree, branch change/serve-own-program at 6b6afc72)

| fact | measured |
|---|---|
| sizes | `wc -l`: serve.rs **5,248**, core_bridge.rs **590**, core_component.rs **2,452** = **8,290** (move-list row 8: same) |
| commits, 30 d | serve.rs **48**, core_bridge.rs **3**, core_component.rs **10** = **61** (move-list says 51 — stale or a different window; noted, not relied on) |
| files beside them | `serve/journal.rs`, `serve/scheduler.rs` (the door's own submodules) |
| entry | `serve::run(first: Core, factory, port, ui, bridge)` (serve.rs:2624), called by `rust/wa-host/src/main.rs:848` |
| the seam | `core_bridge::CoreMode` (`:57/:66/:81`), `CoreBridge::open` (`:172`), `lease` (`:195`), `call_string` (`:258`); main.rs:789-848 picks native or component |
| the guest mode | `core_component::run_cli` (main.rs:662) and `CoreComponentPool` (the pool `core_bridge` leases from) |
| routes | ~40 `match` arms from serve.rs:4499 on, each a `call("wa_*")` into the Lua core in-process |
| the static tier | `static_reply` (serve.rs:4320): `/health` (host state), `/version`, `/log`, and **the UI files** via `ui_file` (`:4302`) + `content_type` (`:4784`), answered before admission |
| what the door holds in-process | the accept thread, admission (credential + conversation resolved in Lua *before* a node thread is reserved, serve.rs:2652-2680), node threads (`READ_RESERVED`, `READ_READY`), the run sink/cancel per run, `RUN_EVENTS`, the scheduler and the journal |
| what it needs from the OS | `TcpListener::bind` on `bind_address()` (loopback unless `WASM_AGENT_BIND`), one thread per connection, and the interpreter's `call_string` |

## 2. The three tiers, and why they move in this order

1. **static tier** — `/health` (no session/credential), `/version`, `/log`, and the UI files. No interpreter, no
   DB, no run state. **This is slice 1.** (`/health`, `/version` and `/log` are *host facts* — they read this
   process's statics — so only the UI-file branch may leave; moving them would answer from the wrong process.)
2. **route tier** — the ~40 routes: each one is `call("wa_*")` on the node's own interpreter. It can only
   move together with the core (tier 3's interpreter), which is exactly why row 8 names `core_bridge.rs`.
3. **run tier** — admission, node threads, the scheduler, the journal, the SSE stream. It owns the run's socket
   and cancel flag, so it moves with tier 2 or not at all.

So the row's real unit is "the door + `call_string` in one program", and slice 1 is the piece that proves the
wire, the switch and the forwarding discipline without moving any state that can disagree.

## 3. The program, the protocol, and the named gap

The program: this binary in a mode — `wa serve-static --root <ui> [--port] [--rendezvous <file>]` — owning the
UI bytes. It is a program, not a component: the door must bind a socket and hold file handles (no WIT world
offers either to a guest).

**The gap, named.** `wit/bus` is the node's event bus and `wit/agent-control`'s `control` interface is agent
sessions (`fork`, `spawn`, `events`, `collect`, `cancel`) — neither carries an inbound HTTP request and its
answer. Measured: `rg '^\s+[a-z-]+: func' wit/bus/bus.wit` finds no such export, and `control`'s functions
are all about children of a session. So slice 1's wire is the repo's existing local-seam pattern — loopback
HTTP with a token in a 0600 rendezvous file, exactly as the operations supervisor does (client_bridge.rs:353
is the precedent) — and the plan for the full move is the same seam carrying the request/answer envelope,
not a new world.

## 4. What the host keeps (unchanged)

`serve::run`, the accept loop, admission, every route, the run worker, the scheduler, the journal, `/health`,
`/version`, `/log`, the client bridge, the bind address and the credential decision. The switch only decides
**who reads the UI file bytes**: `WASM_AGENT_SERVE_STATIC=<rendezvous file>`; unset — today's path, and the
default on every node — leaves `static_reply` exactly as it is.

## 5. Restart and security

- **Restart**: the static tier holds no state, so a restart of either side is a lost connection, not a
  disagreement. The forwarder answers a named refusal when the program is unreachable, never a silent fall-back
  to reading the file itself (a door that quietly changed which process answered would hide the move).
- **Security**: the UI files are public on the door today (answered before admission), so forwarding them adds
  no credential path; `ui_file`'s traversal guard (serve.rs:4302-4315: no `..`, no `\\`, no `:`, components all
  `Normal`, canonicalised under the root) **moves with the bytes** and is re-checked in the program, and the row
  proves a traversal attempt is refused identically on both paths. The program binds the same `bind_address()`
  and only the host's port is public; the program's own port carries a token, so another local process cannot
  use it as a bypass of the door's admission.

## 6. First slice (to land)

- mode `wa serve-static`, the forwarder at the UI-file branch of `static_reply`, switch `WASM_AGENT_SERVE_STATIC`
  (default off), and a fall-through rule: a path the program does not hold answers `not_mine`, and the host
  continues to the agent thread exactly as today, so the route table stays in one place.
- rows (`scripts/test-serve-static.cjs`, wired into `scripts/test.sh` beside the `/ui` rows): two real
  processes; for `index.html`, one real asset, a missing path and a traversal attempt (`../etc/passwd`),
  status + content-type + sha256 of the body are identical on the in-process and forwarded paths, and the
  traversal is refused on both.

## 7. What I have not done yet

- No slice code yet (this file is the measurement and the plan, as the brief orders).
- `/health`, `/version`, `/log` deliberately stay; they are host facts (§2.1).
- Tiers 2 and 3 are planned, not scheduled: they move together with the interpreter, and that is the bulk of
  row 8 (8,290 lines), which this slice does not pretend to have moved.
