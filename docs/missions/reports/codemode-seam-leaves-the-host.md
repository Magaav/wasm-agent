# codemode-seam-leaves-the-host — report

Branch `change/codemode-seam-leaves-the-host`, base origin/main **522e12ae**, two commits:
**97e8fbf0** (the move + the repin) and **8c6aa6fe** (the golden and its row). Node avell, worktree
`/home/victor/Work/missions/codemode-seam-leaves-the-host/wt`,
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-codemode-seam-leaves-the-host`.

**Refactor-only: the seam's JSON control channel moved from the host into the component, and every
answer a model or the loop reads is unchanged — which is why this branch keeps every existing test green
unchanged rather than adding a test that fails on the base.**

## Verdict

The move-list row's premise is half stale. The code-mode seam's *protocol* has lived in
`rust/components/codemode` since **6e471463 (07/11)** — the same commit that created `codemode_seam.rs`
as its bridge — and the component path is the default one (`policies/default.json:6`: `"codemode": true`).
What was still host-only, and is now the component's, is the **JSON control channel**: the request decoded
into `wa:codemode`'s typed records and the answer rendered back. `codemode_seam.rs` went **906 → 717
lines** (97e8fbf0).

What remains in the host is what only the host can do, and it is a measured impossibility rather than a
preference: **the pinned VM** (`quickjs.rs` + its 127-line typed adapter — a component cannot host
wasmtime, so it *imports* `wa:kernel/quickjs`); **the component loader** (engine, artifact, `.cwasm`
cache, `Store`/`Linker`/instantiation — a component cannot instantiate itself); **the benchmark's
scripted sandbox peer** (131 lines, which the seam's own unit tests run on); and four sentences only the
host knows (`invalid_codemode_op`, `invalid_codemode_request:session_required`,
`component_session_unknown`, `component_not_installed`).

## Premises re-measured (brief facts that were wrong)

| brief | measured on 522e12ae |
|---|---|
| "codemode_seam.rs 906 lines + tests" | `codemode_seam.rs` 906, `codemode_seam/tests.rs` 401 — **correct** |
| "quickjs.rs 172" | 172 — **correct** |
| "17 commits in 30 days" | the *row* has 21 (`codemode_seam.rs` + tests + `quickjs.rs` + `rust/components/codemode` + `wit/codemode`); `codemode_seam.rs` itself has **4**, and 861 of its 906 lines are the 07/11 creation commit |
| "the seam glue moves" | it had already moved; the remaining movable glue was the JSON rendering (2 of those 4 commits, `f2d2c3cc` and `1c19bf5c`, were host-only edits to exactly it) |

## What `codemode_seam.rs` did per call, and where it went

| section | lines | what it is | now |
|---|---|---|---|
| engine (121–245) | 124 | engine + epoch ticks, artifact sha256, `.cwasm` cache, manifest cap | host (loader) |
| store (245–281) | 36 | `Store<Host>` + bindings per session, WASI view, limiter, deadline | host (loader) |
| `wa:kernel/quickjs` (281–408) | 127 | the one import: `start/admit/deliver/close` → `crate::quickjs::control` | host (the pinned VM) |
| stub peer (408–539) | 131 | scripted peer of that import, `WA_CODEMODE_SANDBOX_STUB=1` | host (tests and the bench run on it) |
| seam ops (539–777) | 238 | LIVE map, epoch re-arm, **the JSON request decode** | decode → `rust/components/codemode/src/channel.rs` |
| answer shape (777–906) | 129 | **the record → JSON rendering**, `trap_error`, the capability entry | rendering → `channel.rs`; `trap_error` stays host |

Callers: one — `rust/wa-capabilities/src/capabilities.rs:193` registers `codemode`, and
`lua/core/codemode.lua:232` is the only caller of the capability.

## The change

* `wit/codemode/codemode.wit` (97e8fbf0): the package gains
  `interface control { serve: func(request: string) -> string; }` and the world exports it beside the
  typed `codemode` interface. The typed records, the `refusal` variant and the three typed exports are
  untouched: the door renders that contract, it does not replace it.
* `rust/components/codemode/src/channel.rs` (97e8fbf0, 278 lines): the request decode (`catalogue`,
  `builtins`, `store`, `execution`, `optional`, `text_field`) and the answer render (`output_json`,
  `unexecuted_json`, `writes_json`, `outcome_json`, `refusal_json`, `step_json`, `opened_json`,
  `progress_json`, `report_json`), moved line for line, on top of the same `open`/`advance`/`finish`;
  `lib.rs` implements `control` by delegating to it.
* `rust/wa-capabilities/src/codemode_seam.rs`: those 278 lines leave; `dispatch` now names the op,
  resolves the session, hands the request to `wa_codemode_control().call_serve(...)` and adds only what
  is the host's (`ok`, `op`, `elapsed_ms`, the four host sentences). New named failure:
  `component_answer_invalid:<detail>` / `component_answer_invalid:no_error` — unknown is not yes.
* `components.lock` (97e8fbf0): `codemode 541bbba1ec2db6b71af48456a24544ab4ef9aa12d3bb724bb88cde9f8fdb1b26 242422`,
  built twice by `scripts/build-components.sh codemode` at the lock's toolchain (rustc 1.99.1) and build
  root (/tmp/wa-component-build/src), same sha256 both times.

## Numbers (all measured on this node)

| | before | after |
|---|---|---|
| `codemode_seam.rs` | 906 lines | **717** |
| `target/release/wa` (`cargo build --release -p wa-host`, same toolchain, back to back) | 79,701,736 B | **79,641,976 B** (**−59,760 B**) |
| incremental rebuild after `touch codemode_seam.rs` | 19 s | 20 s |
| `codemode.wasm` | 216,485 B (`35cfcfe1…`) | 242,422 B (`541bbba1…`) (**+25,937 B**) |
| the seam's own clock, one whole script (open + advances + finish), best of 5 | **8 ms** | **9 ms** |
| model-facing result bytes, 11-script task set | recorded | **identical, 11/11 lines** |

The +1 ms per script is the one extra wasm→wasm call per step; a script makes 2–4 capability calls.

## Gates

* `bash scripts/test-codemode-component.sh` — **green before and after**: boundary native, boundary
  component, session vars, the parity suite (**50 checks, 21 comparisons, 0 skipped**, and it asserts the
  component half did not fall back), the pending suite on both paths (**108 checks each**), plus the new
  bytes row. Unchanged except for the one added row.
* `bash scripts/gate-cargo-codemode.sh` — the seam's own 13 tests, **not one assertion changed**, green
  before and after. (They are what holds the channel's own fields; a mutation of `"kind": "call"` in
  `channel.rs` makes several of them fail.)
* `scripts/test-codemode-seam-bytes.lua` + `fixtures/codemode-seam-bytes.jsonl` (8c6aa6fe) — eleven
  scripts through `tools.dispatch(memory,'codemode',{code},...)`, the **result the model receives**
  compared byte for byte with a fixture recorded on the **pre-move binary and the pre-move pinned
  artifact**: 11 cases, 11 lines, identical. It fails when the channel renders a different item `type`
  (mutation-checked), and it refuses to pass when the capability does not answer (the guard) or when the
  loop falls back (the runner's `codemode_fallback` check).
* Mismatch, measured: the **new host served the old pinned artifact** answers
  `{"ok":false,"error":"component_instantiate:no exported instance named wa:codemode/control@0.1.0"}` — a
  named failure, after which `lua/core/codemode.lua` takes its native path *before a step is handed out*,
  which is the documented rule.

The node this was verified on runs `wasm-agent v0.1.2 · va1857d15 · tree 6b6afc72` (`wa --version`), so the v0.1.2
tag the landing order waits for exists.

### A finding that changes how these rows must be read

A scratch `WASM_AGENT_HOME` has **no component directory**, so this node's feature resolver answers
`component_missing` and `host.features` reports `active: "native"` — measured — even with
`WA_CODEMODE_COMPONENT=1` set. So the *component-path sub-rows* of `scripts/test-codemode-component.sh`
(boundary, session vars, pending) are the **native loop** answering in a scratch home, before and after
this change alike. The genuine component evidence is the **parity suite**, which pins both sides with
`M.seam_override` and asserts no fallback, and the new bytes row, which gives its run a components
directory holding the artifact and its pin (the two files a deploy writes) so the resolver answers
`active: "component"` — verified with `host.features` before the row was trusted.

## What I did not do / could not verify

* No live model turn: token and round counts cannot be measured here. They cannot change in principle —
  the move is host→component inside one capability call, the loop hands out the same steps and the
  model-facing bytes are identical — and the seam's own clock says +1 ms per script.
* No full `scripts/test.sh` on this node: other missions' fast suites held the suite lock for hours
  of this session, and a whole-tree run is not what this move names. What was run is every codemode row
  that can run here — the wrapper (four Lua suites on the paths it pins, plus the new bytes row) and
  eleven standalone `scripts/test-codemode-*.lua` rows in scratch homes under `~/.wasm-agent/tmp`:
  **11 of 11 pass**. `scripts/test-codemode-unprepared.lua` refuses to run on this binary by its own
  assertion ("default build honestly reports assets not embedded"), because this build embeds the
  code-mode assets on purpose; it refuses identically on the pre-move binary, so it is not a row this
  change moved.
* The typed `codemode` interface was deliberately not removed: with the door in place nothing on the host
  calls it, and deleting a reviewed contract is Fable's call, not a side effect of a move.
* `quickjs.rs`, `capabilities.rs`, `host.rs`, `lua/` — untouched (`git diff --stat 522e12ae..HEAD`
  lists only: `wit/codemode/codemode.wit`, `rust/components/codemode/src/{channel,lib}.rs`,
  `rust/wa-capabilities/src/codemode_seam.rs`, `components.lock`,
  `scripts/test-codemode-seam-bytes.lua`, `fixtures/codemode-seam-bytes.jsonl`,
  `scripts/test-codemode-component.sh`).

## Texts to approve

1. `component_answer_invalid:<detail>` — new capability error, operator-facing (a component that answered
   something this host could not parse; never seen on a healthy node).
2. `component_answer_invalid:no_error` — the same, for a refusal with no sentence.

No model-facing string is added or changed: the loop's own texts, the fence's sentences and the refusal
messages are the ones that were there, and the bytes golden holds them.

## Savings (measured, 26/11 — what this move takes off a landing)

Asked for by the orchestrator: a host build in minutes and the bytes a node downloads, before → after.

**Host build (`cargo build --release -p wa-host`, this node, 16 cores).** A change to the seam's JSON
channel used to be a change to `rust/wa-capabilities/src/codemode_seam.rs`, so it rebuilt and relinked the
host: **2 min 26 s cold** (146 s, fresh `CARGO_TARGET_DIR`, base worktree at 522e12ae) and **19 s** for a
touch-rebuild (measured back to back with the after side, same load). After 97e8fbf0 / 8c6aa6fe the same
change is a change to `rust/components/codemode`: **0 s of host build**, and a component build of
**10 s** and **18 s** in two measured runs (`cargo build --release --target wasm32-wasip2`).

**Bytes per landing.** Before, the artifact a node must take to get that change is the whole host binary:
**79,701,736 B** (`wa`). After, it is `codemode.wasm`: **242,422 B** — 0.30% of it — with the
`components.lock` pin moving beside it (the host binary is unchanged).

**30-day landings it applies to (measured, `git log --since=30.days`).** Of the codemode row's 22 commits,
**1** touched only `rust/components/codemode` + `wit/codemode` (a landing that already skipped the host
rebuild — the shape this move extends), and **0** touched `codemode_seam.rs` alone. So the honest reading
is that this move's saving is **prospective**: from here, a change to the channel lands in the component;
in the 30 days measured, no commit would have been spared a host rebuild, because every one of the seam
file's four also carried a loop or component change.
