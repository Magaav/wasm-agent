# Session watch: start and follow a session on another node

A master starts a session on a peer with a prompt and a working directory, gets its id back at once,
and follows it read-only as an ordered stream of events that resumes from a cursor. Two capabilities
(`session_start`, `session_watch`), two CLI verbs (`wa session start`, `wa watch`), one Lua module
(`lua/core/session_watch.lua`) and one test (`scripts/test-session-watch.lua`).

This exists because of a measured afternoon. On 2026-11-10 an orchestrator on `work` had to supervise
a session on another node and could do none of the three things it needed:

| what it tried | what happened | why |
| --- | --- | --- |
| `wa call <peer> operation '{"action":"start",…}'` | `capability_not_granted` | it had worked on 2026-11-04, on a node that was **not yet bound**. Binding is what switches `enrollment.managed()` on, and the managed allowlist in `lua/core/server.lua` did not name `operation`. It never had: the list was created whole in `6342ce8b` (2026-09-20). Restoring it is one line, below. |
| start a chat session on the peer and learn its id | nothing existed | a Windows scheduled task ran `wa chat "<prompt>"` with its output redirected to a file, and the id was found by reading the ledger afterwards. |
| follow the running session | nothing existed | a python script read `memory.db`'s `messages` table every minute over `wa call … bash`. |

## What is reused, not rebuilt

Nothing here adds a table, a scheduler, a queue or a second notion of a run. Every fact a watcher
reads is one the node was already writing:

| the fact | where it already lived | what `watch` does with it |
| --- | --- | --- |
| the session, its directory, its title | `sessions` (`memory.start_session`, `set_session_worktree`) | `start` writes the row first, with an id it chose; `watch` reports it |
| a prompt, an answer, a tool and whether it worked | `messages` (one row per stored turn, `seq` is the order) | one event per row, ordered by `seq`, which is the cursor |
| what the session is doing now | `memory.session_state` (the same classifier `wa resume` uses) | the tail state: `running`, `waiting`, `ended`, `unknown` |
| a run in flight, and for which boot | `steering_runs` (`lua/core/steering.lua`) | `running`, with the age of the last context boundary |
| a pending wake, including a deploy's continuation | `self_wakes` (`lua/core/selfloop.lua`; a settle deploy queues a wake whose reason is `deploy <outcome>: …`, `rust/wa-sentinel/src/deploy_outcome.rs`) | `waiting`, with `via=wake` and the deploy named from its own reason |
| the run's outcome | `runs` (`memory.record_run`) | the `ended` event's `outcome` |
| the supervised process | `host.operation` (`rust/wa-operation`, the `operation` tool) | `start` launches it; `watch` asks its state |
| the peer call, its signature and its transport | `nodes.remote_call` (mesh, direct, relay) | unchanged: the CLI is `wa call`'s sibling |
| who may call it | `verify_peer` + `nodes.author_of` + the managed allowlist | both capabilities are master-only, twice over |

## `session_start`

```
wa call <peer> session_start '{"action":"start","prompt":"…","cwd":"<absolute dir>","title":"…"}'
{"ok":true,"session_id":"1ce93a0d-…","node":"wasm_the_first-watch","cwd":"…","operation_id":"op-…",
 "started":true,"run_recorded":true,"watch":{"capability":"session_watch","session_id":"…","cursor":0}}
```

* The session id is chosen **before** anything runs (`memory.start_session` with `opts.id`), so the id
  the caller holds is the id the ledger holds. There is no round trip in which the node could answer
  "started" and hand back something else.
* The run is `wa chat --session <id> <prompt>` under the operation manager, in `cwd`, with the
  session's own binary (`runtime_info().binary_path` - never a `PATH` lookup, which could run a
  session with code the node does not have). That is the measured workaround, supervised instead of
  scheduled: a receipt with an id, its output kept by the manager, and cancellation that names the
  session (`owner = session:<id>`).
* The directory is stored on the session (`set_session_worktree`), because that is where every tool
  resolves a relative path from (`lua/core/tools.lua`, `session_cwd`). It must be absolute: a remote
  caller cannot know this node's working directory, so a relative one is refused rather than guessed.
* `route='remote'`, `objective='remote'` keeps it out of `memory.ensure_session`, so a bare `wa chat`
  on the peer does not adopt another master's work as "the newest open thread". It is still an
  ordinary session: `wa chat --session <id>` reaches it by name.
* A refused launch closes the session with the reason and returns `session_start_failed`: nothing is
  left looking live.

## `session_watch`

```
wa call <peer> session_watch '{"action":"watch","session_id":"…","after":0,"wait_ms":5000}'
{"ok":true,"events":[…],"next_cursor":4,"has_more":false,"done":true,"state":{…},"session":{…}}
```

Events, in order: `prompt` (what was asked), `assistant` (what was said), `tool` (`name`, `ok`, `ms`,
and `error` when it failed), `compacted`, and a final `state` event with `state`, `outcome`,
`witness`, `detail`, `waiting`, and the run's recorded outcome. Text is clipped per event (4000 bytes,
`truncated=true` and `bytes` when it was): a follow stream is lines of orientation, and the artifact
itself is already addressable (`tool_result`, `session`).

**The cursor is the transcript's own `seq`.** Three properties follow, and all three are tested:

* *Resumable*: everything at or before the cursor is not returned, everything after it is, so a
  watcher that lost its connection re-reads nothing and misses nothing.
* *The same tail from a mid cursor*: what a mid-cursor call returns is exactly the suffix of the
  full stream after that cursor. The final `state` event is a read-time projection of durable state,
  so it repeats on every call - deterministically, which is what makes a reconnect comparable.
* *Paged*: `limit` bounds one page, `has_more` says to read on, and the tail is appended only on the
  page that ends the stream.

`wait_ms` (0-10000) makes the answering node wait briefly for a change before answering, so a
follower costs one peer call every few seconds rather than one per second. The peer asks the cheap
question every tick (is there a new row?) and the five-query tail once a second.

A session with a pending wake is `waiting`, not `ended`: a run whose turn finished by queueing a
deploy has more to say, and the point of watching it is the deploy's outcome. `wa watch` therefore
keeps following until the wake fires, and its `--timeout` (default 1800 s) is what bounds that - a
watch that has not ended says so, names the cursor, and exits 3.

### Watch cannot write

The watch path issues queries only. It does not dispatch a tool, append a message, move a cursor,
schedule a wake, create a workspace or touch the operation - and the test proves it by making every
`host.sql_exec` raise during a watch (including a request that carries `prompt` and `text` fields),
then asserting the transcript is unchanged. That is a property of the code, not of a flag: there is
no write call in `M.watch` to disable.

### What it says when it does not know

| state | witness | when |
| --- | --- | --- |
| `running` | `operation` | the process `start` launched is still accepted/running/draining |
| `running` | `steering` | a run's last context boundary is under 90 s old |
| `waiting` | `wake` | a `self_wakes` row is pending; `kind=deploy` when a deploy's continuation is queued |
| `ended` | `transcript` | the last message is an assistant answer; `outcome` from `runs` |
| `ended` | `operation` | the process settled without an answer - `outcome=failed`, with its exit code |
| `unknown` | `steering` | a run was in flight and has not settled: the process that ran it may have been replaced (`outcome=interrupted`) |
| `unknown` | `none` | no witness at all: no live process, no run in flight, no answer, no wake |

`done` is true exactly for the `terminal` states, so `wa watch` exits when the run ends - and a run
whose node went away ends with an `interrupted` outcome rather than hanging:

```
1 prompt Write four paragraphs, about 300 words in total, on why lighthouses matter. No tools.
1 state running - a run is in flight on this node (last context boundary 39s ago)
1 state unknown outcome=interrupted - a run was in flight and has not settled; the process that ran it may have been replaced
wa watch: 3ef6274b-… ended (interrupted) after 1 message(s)
```

## Authority: masters only, twice

1. **The peer gate.** `verify_peer` refuses a caller whose role is not master (`forbidden_role`), and
   `nodes.author_of` refuses one that is not a master for this node.
2. **The handler.** `session_watch.serve` refuses a non-master context itself
   (`session_capability_requires_master`, `effect=none`), because a mesh-attested call is admitted by
   a roster decision that sets `role="master"`, and a future caller must not inherit this capability
   from a decision that did not name it.
3. **The managed allowlist** (`lua/core/server.lua`) names both capabilities, so a managed node
   admits them by name - and, being unclassified in `MESH_VERBS`, a mesh attestation grades them
   `call`, the strongest grant, rather than inheriting `read` or `control`.

Two capability names rather than one action-multiplexed name is deliberate: watching is a read and
starting is control, and one name would be graded by one verb for both.

`operation` is named in the same list again, so a master can start and collect a long remote
operation on a managed node. The cause was measured before it was changed: the list never contained
it, and the 2026-11-04 call went to an unbound node where this list does not run at all (`wa access`
on the node shows the binding accepted 2026-11-10 06:59, and `git log -S 'operation=true' -- lua/core/server.lua`
is empty). The `operation` *tool* is master-only in dispatch (`forbidden_for_role`), so admitting the
name admits masters only.

## What survives a node being replaced, and what does not

The **session** survives: it is a ledger row with an id, and every event it produced is in the
transcript. After the peer process was replaced, the same id and the same cursor answered from a new
process, which is the measurement in the last table row above.

The **run** does not, on Windows. `host.operation` contains its child in a job object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (`rust/wa-operation/src/windows.rs`), so a node that is
terminated takes the running session with it - measured: after the node was killed, no `wa chat
--session 3ef6274b…` process remained. The watch then says `unknown`/`interrupted`, and the session
can be resumed by name. On POSIX the operation's containment is a process group, which the node's
death does not by itself kill, so a run there may outlive the node; that direction is **not**
measured here and is not claimed.

## Live check (measured 2026-11-10)

Peer: the branch build run as a scratch node on the `wasm_the_first` machine
(`WASM_AGENT_LUA_ROOT` at this worktree, its own home and port, name `wasm_the_first-watch`), because
the installed node on that machine serves the *deployed* Lua and this branch is not deployed (the
operator's instruction). Caller: node `work`, running this branch's CLI from a copied Lua root and a
scratch `--db`. No `bash` capability call is involved in either step.

```
$ wa call wasm_the_first-watch session_start '{"action":"start","prompt":"…echo live-check…","cwd":"…"}'
{"ok":true,"session_id":"1ce93a0d-c79b-406a-931f-747ab8c38714", …}

$ wa watch wasm_the_first-watch 1ce93a0d-c79b-406a-931f-747ab8c38714
1 prompt Run the bash tool exactly once with: echo live-check. Then reply with just its output.
1 state running - the run started for this session is still executing (operation running)
3 tool bash ok 0ms
4 assistant live-check
4 state ended outcome=completed - the last message is an assistant answer
wa watch: 1ce93a0d-… ended (completed) after 4 message(s)

$ wa watch wasm_the_first-watch 1ce93a0d-… --from 2
3 tool bash ok 0ms
4 assistant live-check
4 state ended outcome=completed - the last message is an assistant answer
wa watch: 1ce93a0d-… ended (completed) after 4 message(s)
```

Two facts about that run, said out loud: `work` runs a pinned mesh roster that does not contain a
scratch node, so those commands were run with `WA_MESH=0` (the gate's documented per-process
override, `rust/wa-mesh/src/gate.rs`) and took the direct/relay path. And nothing about the *managed*
allowlist is proved by it - the scratch node has no binding, so its gate is the fallthrough. The
allowlist and the guest refusal are proved in `scripts/test-session-watch.lua` against the real
`wa_node_call` with the enrollment module replaced.

## Limits

* Not a streaming transport: `wa watch` long-polls the peer (bounded at 10 s per call). If the fleet
  ever wants sub-second delivery, the seam is `nodes.remote_call`'s SSE path (`/node/chat`), and the
  capability's cursor contract would not change.
* No steering, by design: watching cannot send input to or alter the session. Steering already exists
  (`lua/core/steering.lua`, the `subagent` capability's `steer`), and it is a separate, effectful
  capability - not something a read-only follower should be able to reach.
* The started run's execution budget is the operation's (`timeout_seconds`, 1-86400, default 3600);
  a session that runs longer is ended by that budget, visibly.
* `wa session start` and `wa watch` are added to the CLI next to `call`; the prompt-doc blocks are
  unchanged because no tool was added or removed.
