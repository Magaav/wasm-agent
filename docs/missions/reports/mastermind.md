# change/mastermind - one agent-control API, the orchestration built into wa

Base 7ddbfa98. Branch change/mastermind, worktree /home/victor/Work/missions/mastermind/wt.
Every claim below cites the commit that implements it. Nothing here was pushed.

## 1. What existed before this round (inventory, run for real)

Every path to fork / spawn / cancel / collect a child, and what each is:

| path | entry point | what it does | measured |
| --- | --- | --- | --- |
| native subagent tool | `subagent` action=start, lua/core/subagents.lua M.start | one child, own session, own checkout, budgets, depth | runs (scripts/test-orchestration-mode.lua: 76 checks) |
| HTTP control | POST /subagents -> wa_subagents -> M.control | the same facade, owner derived from the session | runs (scripts/test-orchestration-e2e.cjs: 33 checks on the base) |
| placement | lua/core/orchestrator.lua enqueue/tick | a child on THIS node or a peer, ordered, idempotent | runs (scripts/test-orchestrator*.cjs) |
| fork | POST /fork -> wa_session_fork -> memory.fork_session + workspaces.ensure | a copy of the context up to a boundary, new session | ran, refused by name in a scratch repo (workspace_wave_admission_refused) |
| CLI mission loop | scripts/mission.sh stage/start/status/report/verify/clean | a mission in its own worktree, one fresh session per launch | runs (scripts/test-mission.sh) |
| shell launchers | ~/Work/missions/{launch,start,resume,prebuild}.sh | the operator's wrappers over the above | READ ONLY (the brief says do not run, do not edit) |

Duplicates found and CONVERGED (one implementation each):

- **two fork paths**: POST /fork (server.lua) built its own session+workspace. Both it and the new
  `fork` verb now go through memory.fork_session + workspaces.ensure; agent-control adds only the
  parent->child control row (`f082459f`).
- **two child-inspection shapes**: the native `status` action deliberately REMOVES `result`
  (rust/wa-capabilities/src/subagents.rs:1149), so a caller that wanted the answer had to guess which
  action to use. `collect` asks for `result` and reports the absence explicitly (`18c75227`).
- **two cancel semantics**: HTTP /subagents cancel returned the native receipt, in which state stays
  `running` after the cancel was accepted. `agent_control.cancel` now reports `cancelling` vs
  `cancelled` and keeps every native field (`18c75227`).

## 2. The API (`f082459f`)

wit/agent-control/agent-control.wit + wit/agent-control/types.wit. The fabric's own vocabulary is
REUSED, not redeclared: `use fabric.types.{error, node-id}` and a `deps/fabric` symlink, so a
refusal or a node id means the same thing on both seams. `node scripts/wit-lint.sh` reports
`wit-lint ok (27 wit files ...), 0 new` violations.

One implementation: lua/core/agent_control.lua (`f082459f`), reached by the CLI, by
POST /subagents (fork/spawn/collect/tree/events/cancel/message_to_child, `c4527b77` `18c75227`),
and by `wa mission`.

### WIT function -> fabric-bridge tool -> what Fleet View needs

| WIT (agent-control) | bridge tool (docs/missions/fabric-bridge.md) | Fleet View need (docs/missions/fleet-view.md) | state |
| --- | --- | --- | --- |
| `fork(session, before-seq)` | `session_fork` | a forked session under its node, linked to its parent | served here; the bridge face lands in change/fabric-bridge |
| `spawn(brief, node)` | `worker_spawn(node, brief, base)` | a worker under its node with title, state, rounds, tokens, age | served; peer placement goes through orchestrator.enqueue and is refused by name (`node_not_in_approved_policy`) when the policy does not hold the node |
| `events(after)` | none yet - **gap**: the bridge manifest has no event subscription | live state without polling | served as the session stream (POST /subagents action=events with no id); a bridge tool must be added in that mission |
| `collect(id)` | `worker_collect(answer, commits, files, failures)` | the selected session's result | served |
| `cancel(id)` | `worker_cancel`, `session_cancel` | state changes to cancelled | served, with cancelling vs cancelled |
| `resume(id, message, key)` | `worker_resume`, `session_resume` | a resumed child keeps its identity | served; the key is REQUIRED |
| `message(id, text)` | `session_send` | - (sending into another session is a later step in fleet-view.md) | served |
| `list(session)` | `sessions_list` | every session plus its parent->child links | served; also returns a one-line `summary` for the parent's status bar |
| - | `fabric_nodes`, `fabric_status`, `node_health` | the node headers | NOT this API: they are wa:fabric (wit/fabric/fabric.wit), reused unchanged |
| - | `session_follow` | enter a session read-only | NOT this API: lua/core/session_view.lua already serves it |
| - | `mission_stage/start/status/report/verify/clean` | missions in the tree | `wa mission` (`c4527b77`): launch/start/resume/status/stop. **Gap**: no report/verify/clean verb yet |
| - | `land_*`, `deploy_*`, `node_update`, `review_*` | - | out of scope of this package |

Gaps, named not papered over:

1. **No event tool in the bridge manifest.** The API has `events`; the bridge's tool list in
   docs/missions/fabric-bridge.md does not. It must be added there before the bridge is a full face.
2. **`wa mission` is not the same verb set as the bridge's mission tools**: this round ships
   launch/start/resume/status/stop (the brief's five); stage/report/verify/clean remain
   scripts/mission.sh only. `launch` does what the script's `stage` does - the brief names the verb
   `launch`, the script names it `stage`.
3. **Peer spawn is placement, not a second fork path.** `spawn(brief, node)` with a node goes through
   orchestrator.enqueue, which requires the owner's placement policy to hold that node; without it the
   refusal is `node_not_in_approved_policy` and nothing runs elsewhere.
4. **`files` in a collected answer is always empty today.** The child's own record carries commits and
   the workspace facts; the written paths are not recorded per run. Reported as an empty list rather
   than guessed from the diff of an unrelated worktree.
5. **A fork is not a run.** `collect` on a fork answers `fork_has_no_run` by name; a fork is a
   conversation whose turns are read through the session view.

## 3. Tests, each red on the base

| row | checks | red on 7ddbfa98 because | wired in |
| --- | --- | --- | --- |
| scripts/test-agent-control.lua | 34 | lua/core/agent_control.lua does not exist: `lua_root_unreadable` | scripts/fast.sh (row inventory picks every scripts/test-*.lua) |
| scripts/test-mission-verb.sh | 23 | `unknown command: mission` | scripts/fast.sh:880 `check mission-verb` |
| scripts/test-agent-control-e2e.cjs | 23 | `unknown_subagent_action` | scripts/test.sh:2549 `run_proof_fixture agent-control` |

Verified red on the base with a separate worktree (`git worktree add ... 7ddbfa98`), never a stash.
No existing orchestration row regressed: scripts/test-orchestration-mode.lua 76 checks and
scripts/test-orchestrator-defaults.lua both pass after the change.

## 4. Properties of mastermind.md item 2, and where each is proven

| property | proof | commit |
| --- | --- | --- |
| fork: same context, new session id, appears at once as a child | test-agent-control.lua "a fork is a new session / names its parent / appears in list at once" | `f082459f` |
| spawn: fresh worker, own brief, own session folder, this or another node | test-agent-control.lua (grounds, depth, policy refusals) and the e2e (three real children) | `f082459f` `18c75227` |
| supervise without burning tokens: started/commit/failure/done+rc arrive as events | e2e "events carry named kinds", "a cursor returns only later events"; the stream is read from the ledger with no model call | `18c75227` |
| collect: answer, commits, failures as data | e2e "a settled worker answers as data" + "carries commits, files and failures"; test-agent-control.lua unmeasured-usage case | `18c75227` |
| control: cancel a child cleanly and the run really ends | e2e waits for `settled:true, state:cancelled` AND for the provider call to be closed | `18c75227` |
| control: resume, message | test-agent-control.lua (key required, refusal keeps its word) | `f082459f` |
| a child that outlives its parent, or whose CLI exits, is never a silent second writer | test-mission-verb.sh "a second start is refused while a run is live" + the runner's depth guard (94) | `c4527b77` `80206874` |

## 5. The end-to-end proof (one local node, stub provider)

`node scripts/test-agent-control-e2e.cjs <wa>` -> `agent-control e2e ok (23 checks, one local node,
mock provider)`. What it does, in order: a master session answers; three workers are spawned through
the one API with a profile that has no tools; all three genuinely hold an inference request open at
once; the tree reports three running children with ages and a one-line summary; the event stream
answers from the ledger; the third worker is cancelled mid-run and the test waits for the runtime to
say `settled:true state:cancelled` and for its provider socket to close; the other two are answered by
the mock and collected as data with their commits, failures, rounds and tokens; a second event read
with a cursor returns only later events. Two nodes are NOT covered - there is no live fleet here.

## 6. wa mission (`c4527b77`, test `80206874`)

`wa mission launch NAME BASE | start NAME | resume NAME [--msg TEXT] | status [NAME] | stop NAME`,
on the same behaviour as scripts/mission.sh:

- the worktree is `change/NAME` under `MISSION_ROOT/NAME/wt` (root: MISSION_ROOT, then MISSIONS_DIR,
  then ~/Work/missions - a test always sets its own root);
- the prompt is the marker line first, then the brief, then "Where you are";
- a launch is a detached setsid runner, recorded in launch.pid before it can write anything,
  with a DEPTH GUARD (exit 94), a timeout that signals only the CLI pid it started, and `ulimit`
  for core files and descriptors;
- the session id is read from STDERR in the exact CLI shape, 36 characters of [0-9a-f-], and bound
  in run.lock; done carries the rc;
- `stop` signals only the pids the mission recorded (run.pid, then launch.pid), never a pattern.

Measured in the fixture: launch writes worktree/env/prompt.md/run.sh; the second launch refuses
`already_staged`; start reports the session id and records the launcher pid; a second start refuses
`launch_refused ... second writer`; stop leaves no CLI process and done carries `rc=143`.

**Divergence to note**: scripts/mission.sh names the first verb `stage`; the brief names it
`launch`. Both do the same work.

## 7. Prompt changes for Victor

**None.** `git diff --name-only 7ddbfa98..HEAD | grep -E 'agent.lua|prompt|instructions|AGENTS'`
prints nothing, so no orchestrator or subagent prompt text changed in this round. The only text this
round adds that a reader sees is listed below.

## 8. Texts to approve (new operator-facing strings)

1. `wa mission launch <name> <base> | start | resume [--msg] | status | stop  the mission loop, on the agent-control API` (CLI help line).
2. `usage: wa mission launch <name> <base> | start <name> | resume <name> [--msg <text>] | status [name] | stop <name>`
3. `launch_refused` with `state` one of `launcher|active|unknown|released`, and the sentence "the node's word about session <id> is <verdict> (<why>)".
4. `force_not_supported`: "a launch is refused on the node's word; a stuck mission is cleared by hand (docs/MISSIONS.md)".
5. `launcher_ended`: "the runner ended before it wrote run.pid, so this was NOT a launch (94 depth guard, 95 wrong node, 96 cannot cd, 97 no mission dir, 98 no env)".
6. `not_a_hiccup`: "this session did not stop on a resumable fault (force overrides)".
7. `fork_has_no_run`: "A fork answers on its own turns; read its session, or continue it with wa chat --resume."
8. `fork_is_not_a_run`: "Continue a fork with wa chat --resume <its session>; a fork is a conversation."
9. `subagent_recursion_forbidden`, `node_not_in_approved_policy`, `child_running`, `idempotency_key_required`, `session_required`, `forbidden_parent_session` - the refusal words of the new API.

## 9. What is not done

- Two-node runs and the live fleet: not run, not claimed.
- `wa mission report|verify|clean`: not implemented (scripts/mission.sh still owns them).
- A bridge event tool: named above as a gap.
- `files` in a collected answer: always empty, named above.
- The tree binary at /home/victor/wasm-agent/target/m-mastermind was not left built: every row here ran
  against the installed wa (7ddbfa98, the same base) with `WASM_AGENT_LUA_ROOT` pointing at this tree,
  which is the path a Lua change takes. A Rust change would need the build; this round has none.
