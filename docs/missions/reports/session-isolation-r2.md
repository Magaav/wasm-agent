# session-isolation, round 2 - where round 1's answers did not hold

Mission `change/session-isolation`, branch `change/session-isolation`, worktree
`/home/victor/Work/missions/session-isolation/wt`, based on `e5ba9089` plus round 1 (`d4953bf3`).
Built and tested HERE on avell (x86_64, 16 cores) with
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-session-isolation`; committed locally, **never pushed**.

Round 1 is `docs/missions/reports/session-isolation.md`. This file does not repeat it: it says, per item,
**what round 1 claimed, what was actually true, what the code does now, and which test pins it**. Every
claim below was measured on this branch with a scratch `HOME`/`WASM_AGENT_HOME` and
`WASM_AGENT_LUA_ROOT` = this worktree; the real `~/.wasm-agent` was never written.

The runner is `/home/victor/Work/missions/session-isolation/run-lua-test.sh <scratch> <script>` (scratch
home, scratch `--db`, four secret canaries, and now the deny-shape canaries too). A scratch path must be
absolute: a relative `WASM_AGENT_HOME` is refused by the node itself (`session_cwd_must_be_absolute`).

## 1. MUST - `forget` never refused: the allow-answer collapsed to true

**Claimed** (round 1, finding 10): `memory.may_delete(id, caller_scope)` decides, and the tool refuses.

**True**: `lua/core/tools.lua` read

    local allowed, why = memory.may_delete and memory.may_delete(args.id, guest_scope) or true, nil

which is `(a and b) or (true, nil)`: the comma binds the `or true, nil` part, so the assignment is
`may_delete(...) or true`, `nil` - `allowed` is **true** whenever `may_delete` answers false. The
rule was right, the module test passed, and the tool could not refuse anything. A precedence bug in the one
line the finding rested on, invisible to the unit test that called the module directly.

**Now**: the exact form the mission asked for, in `lua/core/tools.lua`:

    local allowed, why = true, nil
    if memory.may_delete then allowed, why = memory.may_delete(args.id, guest_scope) end

**Test**: `scripts/test-session-isolation.lua`, section "item 1", **through `tools.dispatch`**:
an unknown id answers `error = "memory_not_found"` (the refusal that could never fire), `forgotten` is
nil rather than true, the fact survives, a guest is still refused by the role gate, the scope arm itself
still refuses another scope by name, and the operator's own forget still goes through.

**Still unreachable through the tool, and said plainly**: the *other-scope* arm (`forget_forbidden_scope`)
cannot be reached through `tools.dispatch` at all, because the pre-existing role gate refuses every
non-master caller before the scope check runs (`forbidden_for_role:guest`, asserted in the same section).
The scope arm is pinned at the module boundary and the gate at the tool boundary; there is no role that is
allowed to call `forget` and carries a guest scope, so no test can reach both walls from one place.

## 2. MUST - item 8 regressed to unsafe (and the recording was the reason)

**Claimed** (round 1, finding 8): an empty-cwd operation is relevant only to the session that ran it.

**True, three ways**: `Index::relevant` skipped every empty-cwd row for a caller **with no session**, so the
workspace release path - which called `relevant()` with no session at all in four places - was told "no
blocker" about rows it could not evaluate; and a `bash` whose directory was the session's own worktree
recorded `cwd: ""`, because the *requested* directory was empty and the resolved one was thrown away.

**Now**:

* `rust/wa-operation/src/lib.rs` records the **resolved** directory when the shell ran in the session's own
  worktree (`cwd_source == "session_workspace"`), so the row names a path a release can be decided about.
  A call that named no directory and ran in the node's own cwd still records `""` - that contract
  (`scripts/test-start-directory.lua`) is unchanged.
* `rust/wa-operation/src/index.rs`: a row with no directory is relevant only to a caller that **is** a
  session and did not run it; a caller that is **not** a session keeps the old conservative answer (relevant
  to every path). The fence is never talked out of a refusal by an empty field.
* `lua/core/workspaces.lua`: all four fences (`release`, `reconcile_park`, `reconcile_release`,
  `quarantine_park`) pass `session=id` - the session whose tree is being released.

**Test**: `scripts/test-session-isolation.lua` section "item 2" - a long `bash` in session A's worktree
records that worktree; the release's own query, asked **as A**, returns A's unresolved operation, and the
same row is gone once it is cancelled. `scripts/test-workspace-release.lua` asserts the fence request
names the releasing session (`request.session == id`, real git worktree, real release).
`wa-operation`'s `an_operation_that_recorded_no_directory_is_relevant_only_to_its_session` now pins both
halves: a sessionless caller sees an empty-cwd row, another session does not.

## 3. MUST - item 6 did not work under `wa serve`: a pid is not a run

**Claimed** (round 1, finding 6): a run never resumes a thread a live process is serving.

**True**: `memory.ensure_session` compared the presence row's **pid** with its own. Every run inside one
`wa serve` shares one pid, so the row of *another run of the same server* looked like the caller's own
thread and was resumed - two conversations in one transcript, the leak itself, under the only runtime this
node serves conversations with. The round-1 test inserted a presence row from`pid 999999`, i.e. from
another process: it could not see this at all.

**Now**: a presence row carries a **lease** - the run's own name - and `ensure_session(user, node, title,
opts)` compares leases, not pids:

* `lua/core/schema.sql` / `memory.presence_begin`: the row has `lease`, written by the run that holds it;
  a row from before this column has `''` and falls back to the old pid+boot rule (documented tolerance).
* `lua/core/agent.lua` mints one lease per agent (one per run's interpreter) and passes it to both
  `ensure_session` and `presence_begin`.
* `lua/core/server.lua`'s admission resolver mints a lease **per request** (`"admission:<uuid>"`), which is
  what makes two unnamed runs in one server two runs.

**Test**: `scripts/test-session-isolation.lua` section "item 3": two agents built in ONE process (same
pid) get two different threads, the second says `thread_busy`, the presence row carries a lease, and the
node's own admission resolver (`wa_admission`, the function a served run is admitted by, asked before any
run exists) answers an unnamed request with a conversation the live run is **not** serving and says why.
Round 1's cross-process case is still pinned by the same file's finding-6 section.

**String** (`thread_busy`, extended, never shortened):

    thread_busy: the newest open conversation <id> is being served by run <lease>, so this run started <new id>
    thread_busy: the newest open conversation <id> is being served by pid <pid>, so this run started <new id>   (a row with no lease)

## 4. MUST - a grandchild was unreachable

**Claimed** (round 1, finding 4): a session controls its own descendants, including a grandchild.

**True**: `in_session_tree` climbed with `tasks.get(&cursor)`, where `cursor` is a **session** id and
`tasks` is keyed by **subagent** id. The first step off a child never resolved, so a session could reach
its own child and never a grandchild - and the round-1 test was one level deep, so it passed.

**Now**: the parent of the chain is the task **whose child session is the cursor**
(`tasks.values().find(|parent| parent.session_id == cursor && parent.owner_user == owner)`), still bounded
to 64 steps.

**Test**: `rust/wa-capabilities`'s `a_grandchild_is_reachable_from_the_session_at_the_root`: three levels,
the root session **lists** both, **finds** and **awaits** and **cancels** the grandchild, the child reaches
its own child but not its parent, and a sibling session sees neither.

## 5. MUST - item 7 had no reserved slots, and sessionless starts bypassed the cap

**Claimed** (round 1, finding 7): a session's share is 6 of 8, and two slots stay free for the node's own
control calls and short reads.

**True**: only the share existed. Nothing kept the last two slots: two sessions at four operations each fill
all eight while neither is over its share, and then "cancel the runaway" is refused for want of a slot. And a
start that named no session (the two MCP read paths pass `owner` but no session) was counted against
nobody, so it bypassed the share entirely.

**Now** (`rust/wa-operation/src/lib.rs`, an admission check - the queue is untouched):

* `CONTROL_RESERVE = 2`: a start that is **not** marked control is refused while only two slots are left
  (`operation_capacity_control_reserved`); a start marked control is admitted into them. The flag is set by
  the node's own read paths (`lua/core/mcp.lua` for a connector read, `lua/core/mcp_session.lua` for the
  read session) and **cleared by `lua/core/tools.lua` on every tool call**, so no model argument can claim
  the reserve.
* the share is counted against a **cap key**: the session when there is one, otherwise the runtime **owner**
  the caller named. A sessionless start now counts.
* the comment that claimed the reserve exists was wrong and now describes (`a`) the share and (`b`) the
  reserve as two separate rules.

**Test**: `scripts/test-session-isolation.lua` section "item 5": session C starts four, session D is refused
its third with `operation_capacity_control_reserved`, a control start is admitted while every workload slot
is full, a model-supplied `control: true` does **not** get in, and the round-1 share test (one session
refused with `operation_capacity_shared` after six) still holds.

**Honest limit**: with `PER_SESSION_MAX == MAX_ACTIVE - CONTROL_RESERVE` the per-key share and the node
reserve answer at the same live count for a non-control start, so the two rules are distinguishable by
**whose** refusal it is (a session's own share says `operation_capacity_shared`; anyone else says
`operation_capacity_control_reserved`) rather than by a separate number.

**Strings**:

    operation_capacity_control_reserved: <live> of 8 operation slots are in use and 2 of them are kept for control calls (status, list, cancel, short reads); settle or cancel an operation, or wait for it to finish

## 6. MUST - the test could run against the real node

**Now**: `scripts/test-session-isolation.lua` starts with a guard: `WASM_AGENT_HOME` must be set, must
say scratch/tmp/temp, and must not end in `/.wasm-agent`; otherwise it prints one sentence and exits 2
before touching a ledger. The gate's own home (`/tmp/wa-gate-home-*`) passes it.

**Test**: it is the first thing the script does; a run with `WASM_AGENT_HOME=~/.wasm-agent` refuses (the
refusal was observed by running it).

## 7. Decision - `scope:"node"` belongs to a SURFACE, not to a role

**Claimed** (round 1, findings 2 and 3): `scope:"node"` is the operator role's alone, and it is audited.

**True**: every session on this node carries the operator's credential, so "the operator role" was true of
**every model tool call**: any session could ask for the node scope and reach every other session's
operations - the leak the mission exists to close, re-opened one layer up.

**Now** (`lua/core/session_scope.lua`): the node scope needs the operator role **and** one of

* a **surface**: `fleetview`, `mastermind`, `window`, `cli` - named in the surface's own `ctx`,
  which a model tool call cannot set. `lua/core/fleetview.lua` asks as `"fleetview"` for the operations it
  reports, and `lua/core/server.lua`'s operation route asks as `"window"` (the window's own UI);
* or a session the **operator** marked mastermind: a new `sessions.mastermind` column, set only by the
  human control `/mastermind [off]` in the node's own UI (`wa_mastermind_control`), journalled as
  `session_mastermind` with who set it.

Anything else is refused by name, and the refusal says how to get it. `scope` is in the operation tool's
schema, and its description names the rule. An invented surface name is refused
(`scope_surface_unknown`) rather than honoured.

**Test**: `scripts/test-session-isolation.lua` section "item 7": a model call asking for the node scope is
refused `scope_node_forbidden` and told about `/mastermind`; marking the conversation mastermind makes the
same call succeed; unmarking takes it away; `fleetview` and `window` surfaces are granted; an invented
surface is refused; and the Fleet View grant is found in the journal **with its surface named**.
`ui/app.js` sends `scope: "node"` on its operation read (the window is an operator surface).

**Strings**:

    scope:"node" is not a model tool call: it reaches every session on this node and belongs to an operator surface (Fleet View, the mastermind window, the terminal CLI with --node) or to a session the operator has marked mastermind. To get it for this conversation, ask the operator to run /mastermind here; to read your own work, call again without a scope.
    the node scope belongs to a surface this node implements: fleetview, mastermind, window, cli
    mastermind: only the operator may mark a conversation
    mastermind: name the conversation: send this from the conversation you mean (its thread), not from a nameless run
    mastermind: no such conversation <id>
    mastermind: the mark was not recorded
    mastermind: conversation <id> may hold the node scope (audited)
    mastermind: conversation <id> may not hold the node scope (audited)

**Not verified**: no `wa operation` CLI subcommand exists in this tree (the mission's "terminal CLI
`wa operation list --node`" does not exist to be wired), so `"cli"` is an accepted surface name with no
caller yet; the window change is a JS edit that was not run in a browser here.

## 8. LOW item 7 - a sessionless caller is not a node-wide caller

**Now**:

* `operations::Caller` carries the runtime **owner**. A sessionless caller owns the rows its own owner
  started (a read-MCP session, a user id, a `worker:<n>` foreground shell that named no session) and no
  session's row at all. Round 1 answered "every operation that recorded no session is mine", which is the
  same node-wide answer with an empty session.
* `relevant` with `cwd:"*"` and `reconcile` now need the node scope for **every** caller, sessionless
  included; the node's own reconciler process passes `node_scope` itself
  (`scripts/test-operation-reconcile-json.lua`, `scripts/wave-observe.lua`).
* the `/operation` POST route takes its conversation from the **authenticated request context**
  (`serve.rs` passes the resolved routing session; `wa_operation(body, session, routing)`) and **ignores**
  `session_id` in the body. The window asks for the node scope instead.

**Test**: `scripts/test-session-isolation.lua` section "item 8": a sessionless start sees itself and not
another owner; a body naming `iso-session-a` reaches nothing; `relevant cwd:"*"` and `reconcile` are
refused by name without the scope.

## 9. Decision - the environment deny-list is a shape, and the policy can re-grant a name

**Now** (`rust/wa-operation/src/lib.rs`): the deny rule is the exact names (now including
`ANTHROPIC_AUTH_TOKEN`) **plus every name ending** `_API_KEY`, `_TOKEN`, `_SECRET` or `_PASSWORD`.
The node's own policy re-grants exact names: `"tool_env_allow": ["GH_TOKEN"]` in `policy.json`, read once
by `rust/wa-capabilities` (`wa_features::policy_path`) and handed to `wa-operation`. An allow-list entry
is an exact name - allowing `GH_TOKEN` does not allow every `*_TOKEN`.

Every operation record says what was withheld and where to allow it:
`env_withheld: ["GH_TOKEN"]`, `env_withheld_note: "withheld_from_tool_children: ..."` (the note names the
variable and the `tool_env_allow` key). `docs/OPERATIONS.md` documents the rule and the openclaw case:
that node publishes releases with `gh`, so its policy must list `GH_TOKEN`.

**Test**: `scripts/test-tool-env-allow.sh <wa>` runs the same script twice - without a policy
(**)11 checks, 0 failed**) and with `"tool_env_allow": ["GH_TOKEN"]` (**9 checks, 0 failed**) - proving
both that the shapes are withheld and that a listed name is handed over, with the note in the record when it
is not. `scripts/test-session-isolation.lua` section "item 9" pins the shapes and the note inside the
two-session test.

## 10. LOW - what stays readable by design (no change, one honest paragraph)

**"node: N ops elsewhere" counts operations, not progress files.** It is the count of *other sessions'
unsettled operations* this process holds (`operations_elsewhere` on the tool's `list`,
`tp.elsewhere` for the status row). It is not a count of progress rows: several operations of one session
share that session's row, a settled operation leaves no row, and an operation another **process** runs is not
in this process's map at all - so the number is "somebody else is working here", never a census.

**What stays readable by design**: everything this node writes lives under one root, owned by the user the
node runs as, with file modes the operator's own account can read. A tool child - `bash`, a build, a test -
runs as that same uid, so it can read another session's operation state, its transcript rows, its output
files and this ledger's database, whatever the surfaces above it decide. Per-session files, per-session keys
and the ownership checks in this mission decide what a *tool call* is served; they are not a sandbox against
a process that can open the same files. Closing that needs a uid boundary (a per-session user, a container, a
mount namespace) and is not something this branch pretends to have: on a single-operator node the account
that runs the node is trusted, and the honest statement of the boundary is "same uid, same files", not "two
sessions cannot see each other".

## 11. LOW - a test for the peer path

The peer branch was the one thing round 1 implemented with no test, because a peer call needs a signed
caller on the mesh and nothing on this node fabricates one. It is a **named function** now
(`wa_peer_dispatch(capability, args, caller, author)` in `lua/core/server.lua`, called by the verified
path), so the same code a verified peer reaches can be driven with a caller table.

**Test**: `scripts/test-session-isolation.lua` section "item 11": a peer call dispatches; the operation it
starts belongs to `"peer:<node id>"` and not to a session the request names; a peer that passes
`session_id` in its arguments cannot adopt that conversation; and a peer asking for `"scope":"node"` is
refused `peer_node_scope_not_granted`.

## 12. Corrected in round 1's report (read that file with these in mind)

| round 1 said | what was true |
| --- | --- |
| `forget` refuses by scope | the tool could never refuse: `a and f() or true, nil` is true whenever f() is false |
| an empty-cwd operation is relevant only to its session | the release path asked with no session and was told "nothing blocks you"; and a `bash` in a session worktree recorded `cwd: ""` |
| a run never resumes a thread a live process serves | it did under `wa serve`: one pid, many runs |
| a session controls its descendants, including a grandchild | only its child: the climb looked a session id up in a map keyed by child id |
| two slots stay free for control calls | there was no reserve at all, and sessionless starts bypassed the share |
| `scope:"node"` is the operator role's alone | the operator role is every session's role, so every model call had it |
| a sessionless caller keeps the node's own tooling working | it was node-wide with an empty session |

## 13. What is not verified

* **The model-call side of `/mastermind`**: the control is answered before the prompt reaches the agent
  (`wa_reply` -> `wa_served_control`), and the flag is pinned at the ledger and the grant boundary; no
  end-to-end served conversation was typed into a browser here.
* **The window's `scope: "node"`** (`ui/app.js`) was not exercised in a browser. The route half
  (`wa_operation(body, session, routing)`) is tested from Lua.
* **The peer signature path**: the *dispatch* half has the test above; `wa_verify_peer` and the signed
  round trip still have none, because nothing here fabricates a peer key.
* **A `wa operation` CLI**: no such subcommand exists in this tree, so no CLI caller passes the
  `cli` surface.
* **`presence_end`/`presence_beat`** still match on pid+boot, not on the lease: two runs of one process
  serving the **same** named thread would let either one clear the row. Named threads are the caller's own
  choice, and this is the residual the same-pid case leaves behind.


## 14. The rows that were run, and their verdicts

Lua, each on its own scratch node (absolute scratch `HOME`/`WASM_AGENT_HOME`, scratch `--db`):

    scripts/test-session-isolation.lua                 103 checks, 0 failed   (44 in round 1)
    scripts/test-tool-env-allow.sh <wa>                 withheld 11/0, granted 9/0  (new)
    scripts/test-thread-selection.lua                   thread selection ok (0 skipped)
    scripts/test-session-worktree.lua                   session worktree ok (17 checks)
    scripts/test-session-title.lua                      session title ok (10 checks)
    scripts/test-memory-window.lua                      memory window ok (13 checks)
    scripts/test-session-watch.lua                      session-watch: 107 checks passed
    scripts/test-tool-progress.lua                      95 checks, 0 failed
    scripts/test-tool-progress-live.lua                 22 checks, 0 failed
    scripts/test-cli-view.lua                           cli view ok (368 checks)
    scripts/test-start-directory.lua                    start directory ok (18 checks)
    scripts/test-bash-long-command.lua                  bash long command ok (10 checks)
    scripts/test-run-claim-release-live.lua             ok run-claim-release: 7 checks
    scripts/test-control-pending-bound.lua              13 checks, ok
    scripts/test-tool-schema-fidelity.lua               69 check(s), 0 failed
    scripts/test-hooks-tools.lua                        hooks tools ok (25 checks)
    scripts/test-session-worktree-status.lua            15 checks, ok
    scripts/test-efficiency.lua                         efficiency ok (117 checks)
    scripts/test-wave-operator-session.lua              35 checks, ok
    scripts/test-fleetops.lua                            fleetops layers: 147 checks, 0 failed
    scripts/test-fleetops-guard.lua                       fleetops guard: 63 checks, 0 failed
    scripts/test-mcp-registry-state.lua                 24 checks passed
    scripts/test-mcp-retired-connector.lua              mcp retired connector ok (17 checks)
    scripts/test-exec-timeout.lua (WASM_AGENT_EXEC_TIMEOUT_SECONDS=2)  exec timeout ok (39 checks)
    scripts/test-mcp.lua (MCP_TEST_SOURCE/WA_NODE, as the gate runs it)  mcp native ok (48 checks)

Node runners:

    node scripts/test-session-workspaces.cjs <wa>       session workspaces integration ok (13 checks; real git
                                                        worktrees, two concurrent processes, restart)
                                                        - inside it: workspace release ok (38 checks, was 37)
    node scripts/test-operation-reconcile-json.cjs <wa> 27 checks, ok
    node scripts/test-quarantined-retirement.cjs <wa>   quarantined retirement native ok (20 checks)

Rust (`cargo test -p wa-operation -p wa-capabilities -p wa-term -p wa-tool-progress --lib`):

    wa-capabilities    289 passed; 0 failed; 0 ignored
    wa-operation        41 passed; 0 failed; 1 ignored
    wa-term            133 passed; 0 failed; 0 ignored
    wa-tool-progress    17 passed; 0 failed; 0 ignored

**Not run**: the whole `scripts/test.sh` gate (it is a landing gate and a later round lands this branch),
and `scripts/fast.sh`'s complete row list. Every failure quoted above was run again with the environment
its own gate row gives it before being called pre-existing or fixed: `test-exec-timeout` and
`test-mcp` refuse to run without it, and `test-workspace-release`, `test-workspace-cwd` and
`test-session-workspaces` need the private fixture repository their `.cjs` runners build.


## 15. How it was run

    # the binary
    cd rust && WA_CODEMODE_ALLOW_EMPTY=1 \
      CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-session-isolation \
      cargo build --release -p wa-host

    # the two-session test (absolutely-path scratch HOME, never the real node)
    /home/victor/Work/missions/session-isolation/run-lua-test.sh \
      /home/victor/Work/missions/session-isolation/scratch/iso-r7 scripts/test-session-isolation.lua

    # both halves of the environment rule
    scripts/test-tool-env-allow.sh /home/victor/wasm-agent/target/m-session-isolation/release/wa

    # the Rust half
    cd rust && WA_CODEMODE_ALLOW_EMPTY=1 \
      CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-session-isolation \
      cargo test -p wa-operation -p wa-capabilities -p wa-term -p wa-tool-progress --lib

