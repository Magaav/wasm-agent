# serve-own-program — serve + core bridge as their own program (move-list row 8, slice 1)

**Verdict: measured, planned, and slice 1 landed — but row 8 is three tiers and only one of them can leave
the host today.** `serve.rs` is the inbound door (listener, admission, ~40 routes that call this process's
interpreter, the run worker, the scheduler, the SSE stream). `core_bridge.rs` is the door's interpreter seam
(`call_string` answered by native Lua or by a pooled wasm instance) and `core_component.rs` is that pool plus
the guest's CLI mode. The route tier and the run tier cannot move without the interpreter, which is exactly
why the row names all three. The **static tier** — the UI file bytes `static_reply` answers on the accept
thread *before* admission — needs no interpreter, no DB and no run state, so it is the first slice.

Slice 1 (commit **d3c627ed**): `wa serve-static` owns the UI files; `static_reply` forwards that branch when
`WASM_AGENT_SERVE_STATIC` names the program's rendezvous file, and the default (unset) is today's path byte
for byte.

## 1. Premises re-measured (rule 9)

| fact | move-list | measured (6b6afc72) | verdict |
|---|---|---|---|
| sizes | 5,248 / 590 / 2,452 | `wc -l`: **5,248 / 590 / 2,452** | right |
| commits touching the area, 30 d | 51 | serve.rs **48**, core_bridge.rs **3**, core_component.rs **10** = **61** | **disagrees** — recorded, not relied on |
| worlds | `wit/bus`, `wit/agent-control`; `wit/kernel-v2` for the core | 43 worlds exist; `bus` exports no `func` a request could ride, `agent-control`'s `control` is session children (`fork`, `spawn`, `events`, `collect`, `cancel`) | the row's worlds fit *events* and *children*, not an inbound request |
| entry point | — | `serve::run(first: Core, factory, port, ui, bridge)` (serve.rs:2624), called at `main.rs:848` | — |
| routes | — | ~40 `match` arms from serve.rs:4499, each `call("wa_*")` into this process's Lua core | — |
| the static tier | — | `static_reply` (serve.rs:4320), called at **serve.rs:2879 before admission**; UI files via `ui_file` (:4302) + `content_type` (:4784) | this is the slice |

## 2. The three tiers

1. **static** — UI files. No interpreter, no DB, no run state. Landed as slice 1. (`/health`, `/version`,
   `/log` are host facts — they answer from this process's own statics — so only the file branch may leave.)
2. **routes** — ~40 handlers, each `call("wa_*")` on the node's interpreter. Moves only with the core.
3. **runs** — admission, node threads, the scheduler, the journal, the SSE sink and the per-run cancel flag.
   Moves with tier 2 or not at all.

## 3. What landed (d3c627ed, 7 files, +808/-40)

- `rust/wa-capabilities/src/serve_static.rs` (new, 442 lines): the program (`serve`), the host side
  (`fetch`/`fetch_from`), and **`ui_file` + `content_type` moved here** so the traversal guard travels with
  the bytes it guards. Wire: `POST /static {"schema":1,"path":…}` on the loopback address the door uses, a
  32-byte token in a 0600 rendezvous file checked constant-time before any file is read; answers are
  `200 + bytes`, `400 + "bad path"` (the guard's own refusal), `404 + x-wa-not-mine` ("ask the agent
  thread"), or `403 serve_static_token_required`.
- `rust/wa-capabilities/src/serve.rs`: the two definitions leave; both UI-file branches gain the forwarder,
  which returns **the program's own status** (a 400 stays a 400) and answers `503` + `serve_static_*` when
  the program cannot answer.
- `rust/wa-host/src/main.rs`: `wa serve-static [--root] [--port] [--rendezvous]`.
- `rust/wa-capabilities/src/lib.rs`: `pub mod serve_static;`.
- `scripts/test-serve-static.cjs` (new) + `scripts/test.sh` (+4, wired beside the serve rows).
- `ready-serve-own-program.md` (the plan the brief asked for).

## 4. Proof

`scripts/test-serve-static.cjs`: **two real processes** (`wa serve-static` in its own scratch home, and
`wa serve` with the switch on), plus the in-process door as the reference. 14 checks, **3 consecutive runs
green**:

- `index.html` answers the same **status**, the same **content-type** and the same **sha256** as the file on
  disk, on both paths;
- a path the UI does not hold **falls through identically** on both (the route table still decides);
- `/../etc/passwd` is refused with the host's own word — `400 bad path` — **on both paths**;
- and the decisive step: the program is stopped, and the same door request now answers **503** naming
  `serve_static`. That is what proves the bytes came from the program, not from the door reading the file.

Rust rows: `serve_static::tests::*` **4 passed** (guard on the wire, bytes + not-mine, token refusal, the
switch reads off as in-process). Existing UI-area row re-run unchanged: `scripts/test-web.mjs` **34/34**.
Against the base binary the new row cannot pass: there is no `serve-static` mode.

## 5. Before/after

`cargo build --release -p wa-host`, warm, same command, `rust/wa-capabilities/src/serve.rs` touched first,
same `CARGO_TARGET_DIR`:

| | wall | `release/wa` bytes |
|---|---|---|
| origin/main (`/tmp/base-serve`, warm) | 33.90 s | 79,713,672 |
| this branch (warm) | 28.56 s | 79,784,536 (+70,864) |

**Request bytes of a healthy call, measured**: the model-facing catalogue built through
`tools.all('master', ctx, memory)` with `WASM_AGENT_LUA_ROOT` fixed to this tree is **66 tools**, canonical
sha256 `a79260f6af9bcb2cf1fcafd24572f61ae1ccf71e121d626dd06a324659d6ad85`, on the base binary and on this
branch alike. Nothing this slice did reaches a prompt.

## 6. Named gap, and what stays

- **The gap**: neither `wit/bus` nor `wit/agent-control` carries an inbound HTTP request and its answer, so
  the wire is the repo's local-seam pattern (loopback + token), as the operations supervisor uses. Tiers 2
  and 3 are planned, not moved: they need the interpreter to travel with them.
- **Stays in the host**: `serve::run`, the accept loop, admission, every route, the run worker, the
  scheduler, the journal, `/health`, `/version`, `/log`, the client bridge, the bind address, and the
  credential decision.
- **A second artifact** is a release hunk (Fable's). This slice ships as a mode of the existing `wa` binary;
  nothing was installed, and `installed.txt`, the installer and `components.lock` are untouched (a move out
  of the host has no component to pin).

## 7. Texts to approve (new operator-facing strings, verbatim)

1. `usage: wa serve-static [--root <ui dir>] [--port 8792] [--rendezvous <file>]`
2. `  serve the web UI files as their own program (blocks until stopped)`
3. `  the node reaches it through WASM_AGENT_SERVE_STATIC=<the rendezvous file>`
4. `[serve-static] serving <root> on <ip>:<port> pid <pid> rendezvous <path>`
5. `serve-static: <error>` (startup failure, then exit 1)
6. `serve_static_already_running: <file> answers at <address>:<port>`
7. `serve_static_root_not_a_directory: <path>`
8. `serve_static_bind: <address>:<port>: <error>`
9. `serve_static_unavailable: read|parse <file>: <error>`
10. `serve_static_unreachable: <address>:<port>: <error>` (what the door answers as 503, body `{"error":…}`)
11. `serve_static_token_required` (403) / `serve_static_request_unreadable: <error>` (400)
12. `serve_static_answered_<status>` (a status the host does not know how to carry)
13. row texts: `serve static ok: <n> checks`, `FAIL serve-static: <label>`

## 8. What I did not do

- Tiers 2 and 3 are not moved: the ~40 routes, admission, the run worker, the scheduler and the journal are
  still in the host. This slice moves the bytes and the guard that goes with them.
- No second program artifact, no deploy or installer change.
- No row for a restart of the program mid-request; the static tier holds no state, so a restart is a lost
  connection — the 503 step covers the observable half (the door refuses by name until it is back).
- `serve.rs`'s second UI-file site (the 404-`not found` fallback) is forwarded too, but only the main door's
  behaviour is exercised by the row.
