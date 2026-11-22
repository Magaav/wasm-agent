# Native code-mode implementation contract

Native Rust/Wasmtime code mode is the default/preferred programmatic coding path for eligible runs. Eligibility is derived only from trusted native context: a MASTER (including legacy admin) operator with a nonempty session workspace binding, allocated when required; or the reserved, explicitly authorized `orchestration-worker` in such a workspace with codemode/read/write/edit/bash in its original approved tool set. No task classifier is used. Guest, read-only, specialized and unbound ordinary sessions are not automatically promoted. A worker wrapper never grants a missing primitive or delegation authority.

The setting and asset selection are pinned for each run, not each inference round. `WASM_AGENT_CODEMODE=off` disables declaration/admission for a new run; ordinary direct read/edit/write/Bash remain available even when native mode is enabled. Keep trivial calls and control-plane operations ordinary; prefer code mode for appropriate multi-step/programmatic coding workflows, not every call. `WASM_AGENT_CODEMODE=native` retains explicit MASTER opt-in compatibility (including unbound operator sessions); children still require the reserved coding-worker profile and its original tool ceiling. Unset/empty selects the scoped default; other settings refuse visibly. Pinning configuration never freezes authority: current role/profile/catalog/schema/workspace/effect checks still apply to nested calls.

One `codemode` declaration is added while retaining ordinary direct tools. JavaScript uses Pi1.2's unchanged prelude and QuickJS-WASI3.6.2's actual wasm artifact. Native Rust/Wasmtime provides VM/ABI/resource capabilities; all target policy remains Lua/native dispatch. V1 `benchmarks/codemode/node-reference.mjs` hosts Pi's actual VM driver for comparison only, never production fallback.

Pins: Pi-codemode1.2.0 npm integrity `sha512-UZF7IN0IIrf3bop2wTxrwoAakGctH6d3zdPwhPN+QHMECfoI5E6B6l6I17YGFZPj8cmGex6xX7mLCNJXRf7wsw==`; guest wasm SHA256 `d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9`; rendered Pi prelude SHA256 `57c8dc8c0e812117d82167fa751bc368f249d5aaee56d321066fc5280c785281`. MIT notices: licenses/pi-MIT.txt (Mario Zechner2025) and licenses/quickjs-wasi-MIT.txt (Vercel2026). The wasm uses12 imports: timezone, interrupt, promise rejection, module hooks, host bridge and six minimal WASI functions. No ambient filesystem, socket, environment or process access is imported (the fd stubs only discard diagnostic output). The `node_required:false` field describes the native implementation, not a process-counter measurement. Module loading is denied.

## Native boundary

`host.quickjs(action,json)` always returns one JSON value. Start verifies both pinned assets, initializes a fresh guest, passes only scoped tool descriptions/globals/store/code to the reused prelude and drains promise jobs. Host callbacks only queue protocol messages. They do not re-enter the VM with results or dispatch tools. Lua validates current role/profile/catalogue hash, supported exact JSON types and workspace/effect authority, then invokes the normal dispatcher and supplies each result. Native response IDs are unique/pending; wrong owner/duplicate/unrecognized responses refuse.

VMs/handles stay interpreter-thread local and require a scope hash for every action. Compiled modules may be shared immutably to avoid repeated compilation, but guest stores/contexts, tool data and session state are never shared. Deadline/cancellation and Wasmtime fuel bound CPU loops and pending-job loops; heap64MiB, linear memory128MiB, stack512KiB, cumulative output16MiB/100000 items and up to4 thread-local guest handles are safety limits, not agent run/round budgets. These explicit runtime safety limits may affect workloads; they do not establish performance benefits.

## Tool behavior

`tools.<name>(args)`, `text`, return, console, store/load, searchTools, describeTool, `results` and `parallel` are available. No classifiers/image generation, implicit paid models, arbitrary native host objects, Node or ambient network/filesystem are injected. Guest-local searchTools/describeTool describe only that guest's approved targets; discovery never calls or loads the ordinary envelope facade. Control-plane operations remain ordinary outside the guest. Guest profile/catalogue excludes recursion/delegation/integration/worktree-control facades. Image output is not yet enabled. All admitted effects are serial; simultaneous independent read execution is not claimed. A call still in flight when the script body ends is admitted and awaited (see *Natural promises*); a call queued by a script that **fails** is still reported unexecuted and never admitted, and completed earlier native effects are never rolled back/replayed after script failure.

Admission rechecks deadline/cancellation before every queued native call, including after a slow prior tool. A native dispatcher exception has an explicitly unknown effect and forbids replay. All call attempts, including refusals, retain raw argument/result references and a separate journal; admitted native tool spans remain distinguishable from attempts. Nested full originals are hash-addressed and nested tool start/end events are durable. Only selected script output enters the model-facing result; ordinary50KiB output projection remains. Filtering is an opt-in awareness risk, not lossless compression; hidden acceptance and late-caveat fixtures must demonstrate task outcomes. Stores are snapshot/scoped derived state and commit only on successful script completion.

## A run block, and the fences that are only text

A turn acts by writing a fence: a line-initial `js run` (or `javascript run`) block, which the loop turns into one
code-mode call. Nothing else in a reply runs, and a reply that ends without one is the answer. `lua/core/raw_code.lua`
decides which fences are actions; everything else in a reply is the model's prose, and the loop must not fail an
answer because of a sample in it.

Three shapes are TEXT and are deliberately neither executed nor reported as a miss (review of 18/11, finding 4;
each is a case in `scripts/test-raw-code-answer.lua`):

1. **a fence inside a block the parser already read** - a `js run` example inside an `md` block is that block's
   content, so the answer is decided by `M.parse`, not by a line scan;
2. **a fence inside a list item** - valid CommonMark, where a block sits up to three spaces inside its container.
   The parser does not track containers, and `list_content_column` answers that question for the one reader that
   needs it;
3. **a plain `js` fence when the node's code mode is off** - nothing could run it, so it was never an action
   (`M.only(policy)`, not `M.mode()`).

**The list-item case is an accepted trade-off, stated so it is not a surprise.** A model that writes a list item
and then an indented `js run` block under it means the block as an action, and this loop will neither run it nor
flag it: the turn ends with that block as its answer. The other choice is worse - it fails every answer that
contains an indented example, which was the measured defect (a normal answer with an `md` sample was refused as
`run_block_not_executed`), and a sample is far more common in prose than an action is inside a list item. What is
still flagged is a fence the parser could have seen and did not: indented four or more spaces at the top level, or
never closed. That is the shape of a real miss, and it keeps its named refusal.

## Natural promises (11/11, #119)

A script is one async function, and the node wraps the model's text in a small ergonomics layer before
either loop sees it (`lua/core/codemode_harness.lua`: a prologue and an epilogue of **text**, prepended and
appended, so the native guest and the component's guest get the same behaviour without touching the
checksum-pinned Pi prelude or the host ABI). The layer costs one line of offset in a stack frame: a
script's own line 1 is line 2 of the compiled source.

* A returned Promise - and Promises inside arrays and objects, to a bounded depth - is settled before
  the script's value is reported. `return searchTools("*")` answers the list.
* Calls still in flight when the body ends are awaited, never reported
  `script_finished_before_admission`. This replaces the earlier rule that an unawaited call was simply
  not admitted: the calls a script has already made are the calls it meant to make.
* `text`, `store`, `console` and the returned value settle a pending value themselves, and keep the
  order the script wrote them in.
* A pending value used as if it had settled (`.map`, a property, `for…of`) throws a `TypeError` that
  names the call and what was used on it, instead of answering `undefined`. A call settles only while
  the script waits for it, so JavaScript's own rule still applies: to *use* a value in an expression,
  `await` it.
* Deliberate concurrency is unchanged and measurable: `Promise.all([...])` and `parallel([...])` hand
  every call to the loop in one round (asserted from the sandbox's own event stream in
  `scripts/test-codemode-promises.lua`), where two `await`s hand one each.
* `searchTools(...)` is ONE tool with one answer shape: every form returns a plain ARRAY of
  `{name, description, parameters, schema, execution, callable, route}` - the catalogue listing
  (`"*"`, `""` or nothing) paged with `{limit, offset}` and without `schema`,
  the keyword hits, and an exact batch (`{names:[...]}` or `"select:a,b"`) which adds each one's full
  `schema`. The guest's own names (`searchTools`, `results`, `showCall`) are selectable the same way and
  carry their help as the entry's `schema`. A name that is not there is a MEMBER of that array
  (`found:false`, its reason, the nearest permitted names), never a throw, so `.map` works on every
  form. A keyword search that matches nothing is a member too (found:false, its reason), and its
  reason names the command-line program the query means - with the path it lives at - when this machine
  has it installed (lua/core/cli_hints.lua, one PATH lookup at miss time): a turn that asks for
  "github" reads that gh runs through tools.bash instead of an empty list (22/11).
  The shape is documented where the model asks for it: `searchTools("select:searchTools")`.
  `describeTool(name)` survives only as a hidden compatibility alias for `searchTools("select:"..name)[0]`
  and is in no catalogue or guidance text.

## Always fresh, explicit reuse (11/11, #120)

Every call executes, every time - within a turn and across turns. There is no implicit cache anywhere,
because "sometimes models want to recheck if something turned out differently, so caching risks breaking
awareness" (the operator's decision, 11/11). Reuse happens only when a script asks for it:

* `results.get(sha256)` returns `{ok,hash,value}` with the full prior result behind a hash from
  `calls[]`/`attempts[]`, `results.last(n,{tool})` lists the newest journal rows, and
  `results.diff(a,b)` answers `{same,count,changed:[{path,before,after}]}` for two result hashes.
* `tools.x(args,{reuse:"60s"})` returns the newest identical prior **read** younger than that age,
  marked `{reused_from, age_s}`, and otherwise runs fresh - nothing is dispatched when it hits.
* A fresh **read-only** call that repeats an identical earlier one carries `prior:{call, age_s, same}`,
  where `same` compares the result hashes: the answer a model needs in order to decide whether the
  world moved. "Read-only" is the node's own classifier (`orchestration_mode.effectful`), so an effect
  is never compared or reused - "the same result" would be a claim about the world.
* Both are backed by one bounded, per-scope journal in `memory.meta`
  (`lua/core/codemode_results.lua`, 200 rows of name + two hashes + time + verdict); the result bytes
  themselves are already retained by hash in the node's tool-results directory, so nothing here is a
  second copy of a result.
* Repeated identical reads are counted in telemetry (`codemode_repeat` with `same`, and `codemode_reuse`
  with `hit`), so the value of explicit reuse is measurable rather than asserted
  (`scripts/test-codemode-reuse.lua`).

## Session variables (15/11)

Each script runs in a fresh sandbox, so a long run re-fetched what an earlier script already had.
`vars.<name>` keeps plain data for the session, explicitly (a script assigns it) and visibly (every
observation lists it). It is the session store under the key `vars.<name>` - the same row `store`/`load`
use, scoped by session, user, role, workspace and profile and kept in `meta` - so there is one
persistence path, and it survives a fresh sandbox and a process restart. Both loops get it: the harness
text (`lua/core/codemode_harness.lua`) builds `vars` on the prelude's `store`/`load`, and the index is read
from the row in the shared `run_script` (`lua/core/codemode.lua`, `session_vars`).

* `vars.x = value` keeps a JSON-encodable value; a BigInt or cycle is a `TypeError` naming the key.
* `vars.f = (a) => ...` (or `function`) keeps the function's SOURCE (`{$fn: "..."}` in the row) and revives it in
  each later script with that script's `tools`, `console`, `vars`, `results`, `parallel` and `searchTools` in
  scope, so a helper is written once per session (17/11). Its closure is not kept; a built-in or tool function
  (no source) is a `TypeError`.
  `delete vars.x` (or `vars.x = null` / `undefined`) removes it. Names are identifiers of at most 64 characters.
* `vars.x` reads the kept value, or `undefined`; `Object.keys(vars)` and `"x" in vars` answer the session
  index. A value changed in place (`vars.list.push(item)`) is written back when the script ends.
* Limits: 64 KB of JSON per variable and 256 KB per session (UTF-8 bytes), each a `RangeError` that names
  the limit. The prelude's own store limits (256 KB per key, 1 MB per session) still apply around them.
* **Writes commit when the script succeeds, like every store write** (native: `done.ok`; component:
  `outcome.ok`). A script that throws keeps none of its variable writes or deletes, so a half-done script
  never leaves half its state, and the next script sees what the last successful one left.
* Every script observation lists the variables after line 1 and the `calls:` line:
  `vars: laura (30 B) · inbox (12 KB) · plan (400 B)` - names and sizes, never values, sorted by name, at
  most ten then `+N more`, absent when there are none. A view in the JSON form (a failure, a script with no
  call) carries the same text as the field `vars`. `tool_output.parse_view` reads either back as
  `vars = { {name, size} }` and `vars_more`.
* A delete is committed as JSON `null` and the core drops it from the row (`session_vars`), because the
  component seam refuses the prelude's bare `[key]` write - its spelling of `store(key, undefined)`, which
  therefore still fails on that path as `codemode_store_protocol_invalid` (a seam fix moves the component
  bytes, so it waits for a component publish).

`scripts/test-session-vars.lua` holds all of the above against the real sandbox.

## Pending calls (12/11)

A call that can outlive its wait is the general case, not an exception: a build, `scripts/fast.sh`, a
deploy, a download, a remote call, a long `bash`, an outbound message. The operator's decision (Victor,
12/11) is **one pattern for every code-mode call**, so a script is never asked to guess a timeout and
never told "still running" with nothing it can do about it.

* Any `tools.<name>(args)` still running after its wait answers
  `{state:"pending", op, operation_id, tool, waited_s, stdout_path, stderr_path, progress}` -
  one shape, whatever the tool. The handle names its log files as plain fields, because "which file do
  I read when this settles" is the first question a detached call raises: `stdout_path` for the
  answer, `stderr_path` for why it failed, absent when the executor has no files (never a guess). A
  call that finishes inside its wait answers exactly what it always answered; a script that names no
  `wait_s` and whose call finishes in time sees no change at all.
  The rest of the handle, field by field (`lua/core/codemode_pending.lua`, the local `handle`): `log_path` is
  `stdout_path` under the name a reader looks for first, so either spelling works; `output_bytes` is
  how many bytes the stream holds so far, which is what a later `operation read` pages through;
  `state_name` is the executor's own state word (`running`, `settled`) kept when `state` is already
  this handle's word; and `settled` is true the moment the work ended, even if the handle was formed
  before the result could be read. None of these is a guess: each is copied from the executor's own
  record, and a field the executor did not answer is simply absent.
* `wait_s` is a property of the call's *wait*, taken out of the arguments before the tool's own schema
  sees them: default 60 s, 0..300 s, and effectively `min(wait_s, 300, the script's remaining time minus
  a margin)`. A wait never outlives the script that started it; a `wait_s` that is not a number is
  refused by name (`invalid_wait_s`), never quietly replaced with the default.
* `wait(op | [ops], {wait_s, until:"all"|"any"})` is the one resume: 1..20 ops, one entry per op in the
  order asked, **in the same shape a direct call answers** (21/11, "one result shape"). A settled entry
  carries the tool's own result fields at the top level - `stdout`, `code`, `ok`, ... - with the
  handle's facts beside them: `op`, `tool`, `state:"done"` (or `state:"failed"` plus `reason`), and
  `state_name` when the tool's own result also used the word `state` (an operation says "completed").
  There is no `result` key to reach through: the same call settles inline as `{stdout, code, ok, ...}` and
  collected as `{stdout, code, ok, ..., op, state}` - which is the whole point. A pending entry has no
  result to flatten and stays `{state:"pending", op, tool, waited_s, progress}`.
  A failed entry carries `reason`, never `error`: news about a call is an answer a script branches on,
  not a refusal that throws. It is a **read** - it dispatches nothing, holds no lock or lease - so the
  guest batches it with anything: `Promise.all([wait(a), tools.read({path}), wait(b)])`.
* `pending()` is a read of the whole pool: `{ok, ops:[{op, tool, state, kind, age_s, progress}], count,
  limit, shown, truncated}`, oldest first. A later step or turn asks it instead of remembering handles.
* `until:"any"` stops *waiting* at the first op that settled and still answers **every** op it was
  asked about, finished or not. That is the pool: `const open = (await pending()).ops.map(o => o.op)`,
  wait `{until:"any"}`, drop the finished ones, start new calls, wait again - a batch that grows and
  shrinks across steps, with every outcome arriving exactly once.
* Handles outlive the script. `cancel(op)` is the one stop; where the effect cannot be stopped it
  answers `not_cancellable` with the reason, because a sent message stays sent. At most 16 pending calls
  per session, refused by name past that; a settled result stays in `results`, so `results.get(op)`
  re-reads it without re-running anything.
* Nothing holds a lock: every wait is a bounded slice of its executor's own wait (<= 1 s) plus a status
  read, so a stop/steer aborts it at once with `pending` and a reason, an unreachable executor answers
  `pending` with the reason rather than hanging or claiming `failed`, and a resume never re-runs an
  effect.
* No orphans: an op nobody resumed still settles, and is reported **once**, on the next script of that
  scope (`pending_settled`), the same exactly-once idea the Sentinel's deploy outcome uses. Each row is
  the answer itself in that same flat shape, with `result_sha256` beside it for a later
  `results.get(op)` - the model reading an announced handle never has to reach through a hash either.

**The executors** (`M.EXECUTORS` in `lua/core/codemode_pending.lua`) are how a call becomes a handle,
and they are the whole difference between "can be resumed" and "cannot":

* `operation` - the managed operations (`docs/OPERATIONS.md`). The handle *is* the operation id, so the
  record on disk, `operation read`, `/operations` and the supervisor's deadline are the ones already
  documented; `bash` starts one through the tool's own serial path (path guard included, which now
  covers `operation start` too), and `operation await` becomes a bounded wait on the id the caller has.
* `outbox` - a WhatsApp send's durable queue job (land6). The id the connector answers is the handle
  (`msg-<id>`), a wait reads the queue through the connector's own bounded loop, and `cancel` answers
  `not_cancellable` with `a sent message stays sent`. Inside a script the send's `wait_s` is the same
  knob every call has; the connector's `{id}`/`{ids}` resume stays as a hidden alias for a call made
  outside a script, and the answer's `resume` field names it there.

**A remote call is never killed for waiting.** A relayed `bash` that outlives the relay's hold is
*adopted*, not stopped: the peer starts it as a managed operation on itself and answers
`{state:"pending", op, node, ...}` inside the relay's own deadline. The handle names the peer's operation
id and the node it lives on, and `wait(op)`/`cancel(op)`/`pending()` route back to that node through
short relayed `operation await` calls - the relay never carries a long wait, so no call depends on
holding a connection open. A command that fits its budget answers its own result, exactly as before. The
call is either still running (a handle), finished (a result) or cancelled by name; a resume never re-runs
it, so a command that appends a line appends it once. The budget travels in the signed body
(`nodes.lua RELAY_PEER_BUDGET_MS`), so a peer adopts by the caller's own number and nothing on the path
can raise it. `scripts/test-remote-pending.lua` pins the adoption, the resume, the cancel and the
exactly-once append.

**The limitation, named.** Work that runs *inside* this interpreter cannot be moved off it, so a call
becomes pending only where the node has an executor. Today that is `bash`, `operation`, the WhatsApp
send and a relayed `bash`. Every other tool without one is answered synchronously and cannot be
resumed - it is never turned into a handle that cannot settle.
`scripts/test-codemode-pending.lua` asserts all of the above on both loops,
`scripts/test-codemode-component.sh` runs that same suite through the component and compares the check
counts, and `scripts/test-host-return-docs.lua` keeps the `host.*` encodings honest.

## A settled handle wakes the session (21/11)

A script that hands back a handle is telling the model "this work outlives my budget". Until 21/11
the answer to that work reached the model only if it happened to run another script in the same
scope, so a model with nothing else to do never learned its build had finished. The operator's rule
(21/11, copying Claude Code) is that a settled handle starts a model step by itself - with the
terminal open, or with only the node serving.

* **The sweep** (`lua/core/handle_wake.lua`) is a read: for every scope of pending handles whose
  records name a live session, it polls each open handle with no wait
  (`codemode_pending.wake_settled`) and, for each one that just settled, schedules ONE durable wake.
* **The wake** is a `self_wakes` row - the table the model's own wakes live in, claimed by the node's
  placement tick (`wa_orchestrator_tick`) and by the interactive CLI's idle prompt
  (`lua/core/chat.lua`). Nothing new claims it: the two surfaces that already start a turn with
  nobody typing do the work, so a session no terminal is on still wakes as soon as a node serves it.
* **The row says** the answer itself, in the same flat shape `wait(op)` answers (see "one result
  shape" above), and the list of handles that are STILL pending with their op, tool and age - so a
  model that restarts or is compacted needs no memory of what it left running. It is labelled as
  automated node state (`[self-wake · a pending call settled]`), never as the operator's words.
* **Exactly once.** The wake's id is derived from the operation id (`handle:<op>`), so a second sweep
  - in this process, in another, or after a restart - is an `INSERT OR IGNORE` no-op; the handle
  record is marked `woke_at` only after the insert answered, and `reported` with it so the next
  script's `pending_settled` does not repeat the same news. No effect is ever re-run: a wake reads
  the retained result.
* `scripts/test-handle-wake.lua` pins the sweep, the row's words, the still-pending list, the
  exactly-once behaviour across a reloaded module, and that the row is claimable by the same route
  both surfaces use.

**A line typed during a run** is queued unless the reader says otherwise: plain Enter is delivered at
the next context boundary and ends nothing, and Ctrl+Enter (or Ctrl+G where the terminal cannot tell
the two apart) is "now" - it ends the run's wait and the reader's line is the model's next input.
`docs/HOST.md`, "A line typed during a run: queued or now", has the rule and the chords.

## The three counters (21/11)

`/stats` shows three numbers, and they decide the next mission (`lua/core/counters.lua`):

| counter | what it counts | where it is counted |
| --- | --- | --- |
| `wake_only_round` | a model step whose only input was a settled handle | `selfloop.run_wake`, on a `handle:` wake |
| `script_cut_at_cap` | a script that was told "not yet" (a pending answer) | `codemode`'s end, once per script |
| `handle_mishandled` | a script that used a pending answer as a result, or ended on the wait-never-settles bound | `codemode`'s end |

They are telemetry and nothing else: no decision reads them. `script_cut_at_cap` measures the
pending-answer half only - the "hit its deadline with lines still to run" half is NOT counted yet and
is named rather than folded in silently. `scripts/test-codemode-counters.lua` holds the two
script-side counters (one increment per script, never per call) and the read/write half of the third.

## Peers and discovery (29/10)

Where that policy lives - keep these four in step, and `scripts/test-codemode-boundary.lua` asserts both the
behaviour and the wording: the refused-name list and the multi-action seam are `lua/core/codemode.lua`
(`forbidden`, `action_refusal`); the peer fence for the `calls` batch is `tools.remote_read_refusal` with
`REMOTE_READ` in `lua/core/tools.lua`; the model-facing copy of the rule is the guidance text in
`lua/core/codemode_policy.lua`; and the behaviour is exercised by `scripts/test-codemode-boundary.lua`
(callable/refused sets, the peer path, both suites' routing hint) and `scripts/test-federation.lua`
(a nested remote effect runs, a batch still refuses one). A change that touches one of them and not the
others is a stale promise to the model, which is what happened on 31/10.

Discovery never hides a tool: `searchTools`/`describeTool` also return the catalogue entries a script cannot call (`callable:false`, with the schema and a `route` saying where it runs). Refused inside code mode, and unchanged: delegation/authority/recursion (`subagent`, `integrate`, `session_worktree`, `resume_session`), session shaping (`session_debug`, `session_fixture`), the internal autoflush, and the outer facades (`codemode`, `tool_call`, `tool_search`, `capabilities`) that have in-sandbox equivalents. Everything else runs from a script with exactly the per-call permission, effect, workspace and binding checks an ordinary call gets (31/10): connectors, the user's own `shell`/`client`, spell save/run/compose/forget/export, every `operation`/`resource` action, and every `remote` capability - a script may now change a peer as well as read it, and the peer's own binding/role authorization is the gate. `remote` with `capability:"batch", calls:[...]` stays reads-only: 1-8 reads in one signed round trip, each entry re-fenced on the peer under its own authorization, and a peer that predates `batch` gets the entries one call each (`fallback` says so). History is per node: `search_messages`, `sessions` and `session` take `node`, routed through `remote` and never forwarded a second hop (`peer_call`). `sessions {all_owners, path}` answers "the last agent session on that repo" from the ledger: sessions bound to a worktree/source under the path, or whose recorded file changes are under it, newest first. Nothing is written into the repository.

Measured 29/10 against `openclaw` (direct, signed): ~350 ms per raw call, ~600 ms through the tool layer (registry binding lookup); a script with nodes + 3 peer reads + a refused write took ~4.6 s in one model round, against five outer rounds each paying a model call. Peers keep only what they run: `path`/`all_owners` and `batch` need the peer on this build.

## Structured native presentation (opt-in)

Use `await showCall({version:1,call:N})` to present an admitted native result as
structured JSON without `text(result)` double escaping. Exact receipts and typed
originals remain retained; encoded-budget overflow explicitly labels unread coverage
and exact retrieval, while an existing batch cursor still resumes cached pages.
See [CODEMODE-PRESENTATION.md](CODEMODE-PRESENTATION.md) and the on-demand
`codemode-output` skill, including fresh reread/edit after formatting. Raw/default
output, global budgets, asset pins, authority checks and no-replay rules are unchanged.

## Present readiness

Default eligibility performs checksum-verified native asset readiness before advertising the tool; host.quickjs presence alone is insufficient. Missing/corrupt assets fail visibly with the ordinary-tools/off escape, never Node V1 or Pi transport fallback. A plain build without prepared assets is usable in off mode but is not a supported default-code-mode shipping candidate. The supported shipping build contract is `node scripts/codemode-build.mjs build <absolute-source-root>`: it resolves the durable prepared asset location from common Git metadata, verifies pinned bytes/tarballs/receipt/notices, passes a fresh verified native snapshot path explicitly to Cargo, retains raw build logs, then executes the real embedded VM checker before any installer step. `deploy.sh` uses this exact non-installing helper; an ambient `WA_CODEMODE_BUILD_ASSETS` is never its source of truth. See the coordinator preparation/preflight procedure in [SENTINEL.md](SENTINEL.md#offline-native-build-preflight-before-a-deployment-request). No Node/npm installation is needed; provisioning may reuse verified retained package tarballs. Runtime is Node/npm/network-free.

The guest ABI smoke and real native dispatcher source/embedded cases execute with Node absent from the child PATH. Actual Node-unavailable evidence and sandbox/profile/type/store/no-unawaited-effect/error/loop tests must remain separately recorded. Bindings can embed prepared assets at build time with `WA_CODEMODE_BUILD_ASSETS=<fresh-assets-dir>`. Runtime then needs no asset paths, Node, npm or network. `WASM_AGENT_CODEMODE_ASSETS` is an explicit checksum-fenced external override, not a fallback; missing assets in a build without embedding refuse visibly. Provision with `node scripts/provision-codemode-assets.mjs <fresh-absolute-dir> [verified-package-cache]`, retain its pinned tarballs/receipt/notices, then build with that environment variable. The benchmark-only Node VM now has a private native-broker client and real source/embedded/restart tool proof, not only mock tools. All four framework loops also pass a deterministic two-round fixture through the common model-free socket route, including Pi1.2 zstd requests. See [CODEMODE-BENCHMARK-WIRING.md](CODEMODE-BENCHMARK-WIRING.md). This does not qualify the real provider, isolated per-arm images/runtime pins, experiment spending controls or autonomous comparison; paid admission remains refused.
## Focused proof and retained postcheck

```
node scripts/test-codemode-default.mjs <absolute-native-binary> <fresh-evidence>
node scripts/test-codemode-default.mjs --post <absolute-native-binary> <same-evidence>
node scripts/test-codemode-native.mjs <absolute-native-binary> <fresh-evidence> [external-assets]
node scripts/test-codemode-native.mjs --post <absolute-native-binary> <same-evidence>
```

The collector removes Node from the child PATH and confirms `ENOENT`, retains complete source/embedded logs and hashes, and separately identifies embedded/external assets. It is model-free, not a security theorem or autonomous solver result. A source proof never substitutes for an embedded one. Interruption/heap failures preserve completed effects and pending-call nonadmission; the long delivery case checks transient handle recycling. Failed proof generations remain evidence, not overwritten destinations.

## Default-promotion evidence and risks

The default proof executes an actual agent with a deterministic mock provider, checks runtime guidance/declarations, performs real native read/edit/read in a private workspace and retains every nested original. Source and standalone embedded runs are separate; the old source at `72a7d8f1` must fail the same positive declaration expectation. This is not live autonomous-model quality evidence.

This human-directed default is not justified by the prior Node reference live A/B screen: 6/6 accepted, 52→27 calls, 149.991→86.151 seconds, but uncached input +13.2%, one pair per task and Node reference only. It proves neither general quality/dollars nor native benefit. No universal speed/token savings are claimed. Named risks include added VM startup/asset provisioning, unmeasured native autonomous behavior, script filtering/aggregation hiding acceptance criteria or late caveats, and unknown completed effects after failure. Complete retained originals do not make filtered model awareness lossless. Global 50KiB/8MiB projection budgets are unchanged. Bash/write retain OS authority and native workspace policy: the VM is not an OS security boundary. Never retry an entire failed effectful script to recover; reconcile unknown effects explicitly. See [PROGRESSIVE-ENVELOPE.md](PROGRESSIVE-ENVELOPE.md), [SUBAGENTS.md](SUBAGENTS.md), [ORCHESTRATION-MODE.md](ORCHESTRATION-MODE.md) and [CODEMODE-WORTH-SCREEN.md](CODEMODE-WORTH-SCREEN.md).

## Code mode as a component (07/11)

The guest's *protocol* is a component behind `wa:codemode` (`wit/codemode/codemode.wit`,
`rust/components/codemode`), reached from this checkout with `WA_CODEMODE_COMPONENT=1`; the native loop
above stays the default and is byte for byte the code it always ran. `docs/CORE-SPLIT.md` sets the seam
rules and the reason code mode is the second extraction.

**What the component owns.** The fence (the `forbidden` set and the three `route_of` sentences), the
guest's identifier mapping (`tools.<js-name>`) and its collision refusal, the guest's tool table, the
two guest globals that are code mode's own (`searchTools`, `describeTool`), the admit/deliver order
(the native loop's: deliver, drain, check `done`, admit, take the next call), duplicate and stall
detection, the named loop failures, and the script's report (output items, return value, `store` writes,
the calls the script finished without admitting).

**What stays in the loop, because it needs the living turn.** The sandbox itself — a component cannot
host wasmtime, so `wa:kernel/quickjs` is an *import* the kernel serves from the existing
checksum-pinned QuickJS capability (same asset pins, same fuel/epoch bounds, same owner check, same
callback protocol; `rust/wa-capabilities/src/quickjs.rs` gained one word, `pub(crate)`, and no
behaviour) — plus `codemode_policy.admit`, the tool dispatcher with the current
profile/catalog/workspace/effect checks, the strict JSON contract against the live schema, the
definition recheck (`tool_definition_changed`), the retained originals and their evidence references,
the telemetry spans, the presentation (`showCall`, `capabilities()`, `describe()`, and
`describeTool("showCall")`, which read the node's registry and retained evidence and come back as a
`host-global` step) and the session `store` row in `meta`.

**Three calls, one script.** `open` starts the guest and drains its first events; `advance` delivers the
loop's answer and hands back one step (`call`, `host-global`, `finished`, or `aborted`); `finish` closes
the sandbox and reports what the script did. A guest global the component answers costs the loop *no*
step: `searchTools("*")` is answered and delivered inside `advance`.

**A live script is never replayed.** A component that is missing or cannot answer *before the first
step* falls back to the native path with one log line per (operation, reason). After that a failure is
reported with `effect: "unknown"` and `replay_allowed: false`: calls already handed out may have had
effects, which is the same rule a failed `pcall` in the native loop already states.

**Nothing on the seam is a JSON document.** Every argument and answer is a record or a variant from
`wit/codemode`; a refusal is a `refusal` case, not a string to parse. Three values are JSON because
they *are* JSON: `tool-facts.schema-json` (the model's own parameter schema, opaque to the seam),
`args-json`/`payload-json`/`outcome.value` (the user's own JavaScript values) and `output-item.text` (a
rendering). The guest ABI documents inside `wa:kernel/quickjs` are the prelude's, unchanged.

**A failed script names its failure on both paths.** The guest reports a script's value and its
failure in two different fields, chosen by `ok` (`wa-capabilities/src/quickjs.rs`, the `done` event);
the seam's `done-event` carries both, `value` and `error`, and the component reads `error` (falling back
to `value` for a host built before the field existed). Reading only `value` left every failed script
through the component answering `{ok: false}` with no reason at all while the native loop still named
it - one script, two different answers to the model.

**The journal is the loop's, on both paths.** A guest call the seam answers itself (`searchTools`,
`describeTool`, `capabilities`, `showCall`, `describe`) is reported to the loop (`progress.answered`) and
written there as one `attempt` with `target: "global"`, `admitted: false` and the argument/result
references - exactly the row the native loop writes for the same call. A seam that answered silently
left the two journals disagreeing about which calls happened.

**The guest ABI is the native loop's.** `tools-json` carries `{name, jsName, description}` per callable
tool - the tool's own name AND the identifier the guest's `tools` proxy exposes - and `globals-json`
carries the five globals with their `spread` flag. A shorter globals list is not a smaller surface: it
is a `ReferenceError` for a script that runs natively, which is how the parity suite found it.

### Cost (measured)

`bash scripts/bench-codemode.sh` on this machine (Windows, release build, median and p95 of 30
in-process runs per scenario, one process per path, `wa` = this checkout's build):

| path | scenario | median ms | p95 ms | Lua→host crossings | sandbox crossings | peak RSS |
| --- | --- | --- | --- | --- | --- | --- |
| native | (a) `return 1` | 1.45 | 2.09 | 2 | 2 | 19,688 KB |
| component | (a) `return 1` | 3.56 | 5.65 | 3 | 2 | 28,908 KB |
| native | (b) one tool call | 5.49 | 6.77 | 4 | 4 | 19,688 KB |
| component | (b) one tool call | 5.29 | 6.85 | 4 | 4 | 28,908 KB |
| native | (c) 10 parallel calls | 41.01 | 45.56 | 22 | 22 | 19,688 KB |
| component | (c) 10 parallel calls | 19.16 | 26.73 | 13 | 22 | 28,908 KB |
| native | (d) 200 KB result | 51.77 | 118.74 | 4 | 4 | 19,688 KB |
| component | (d) 200 KB result | 72.52 | 208.08 | 4 | 4 | 28,908 KB |
| native | (e) cold start | 1.79 | — | 2 | 2 | 19,688 KB |
| component | (e) cold start | 255.06 | — | 3 | 2 | 28,908 KB |

**The guest VM is not in these numbers**, and that is the honest limit of this table: `quickjs.wasm` and
`prelude.js` are provisioned, not vendored, and this checkout has not been provisioned, so neither path
can run a script at all (`host.quickjs('ready')` refuses, visibly). Both paths are therefore driven by
the same scripted protocol peer — the native path by patching `host.quickjs` inside the bench, the
component path by the named `WA_CODEMODE_SANDBOX_STUB=1` host backend. The peer is identical work on
both sides, so the difference the table shows is the seam. With the assets provisioned the same script
measures the real guest.

Read it as: where the cost is *crossings*, the component wins — ten parallel calls are 22 Lua→host
round trips natively (each with a JSON encode, a decode and a pending-call set in Lua) and 13 through the
component, which is why (c) is about half, and (b) is a wash because one call is four crossings either
way. Where the cost is *copies*, it loses: (d)'s 200 KB answer crosses the component boundary twice on
top of what the native path pays, and a script is one instance, so (a) pays instantiation for a script
that does nothing. The cold start is the real cost to plan for: 255 ms is Cranelift compiling the
component in the first process that touches it; the compiled module is cached beside the component
(`codemode-<sha16>-<engine>.cwasm`, owner-only, keyed by the engine's compatibility hash) and the next
process opens a script in 4.6 ms. RSS is +9.2 MB per process for the component path: an engine, an
instance and its memory.

Caveats. (1) An earlier run of this same bench on a busier machine reported the native rows 2–3×
higher (e.g. (c) 115 ms against today's 41 ms): the numbers are machine-dependent, so compare the two
paths from *one* run, not across runs. (2) The p95/median gap on (d) is the 200 KB copy meeting the
allocator, on both paths. (3) Nothing here measures a *model* turn: a script costs one tool round either
way. (4) `in-process` means the sandbox *session* is real but its guest is the peer; the VM's own 2.6 s
first compile and ~1–5 ms per guest call are the same on both paths and are measured by the existing
code-mode proof, not here.

### Parity and proof

```
bash scripts/test-codemode-component.sh                 # build the component, run both paths
cargo test -p wa-capabilities codemode_seam             # 11 tests against the built component
cargo test -p codemode                                  # the component's own rules (12 unit tests)
bash scripts/bench-codemode.sh                          # the table above
```

`scripts/test-codemode-component.sh` runs `scripts/test-codemode-boundary.lua` — unchanged — on the
native path and again routed through the component, then runs `scripts/test-codemode-component.lua`,
which compares the two loops field for field (value, output items, calls, attempts, unexecuted) over 15
scripts: the trivial one, one call, ten parallel calls, the fence, discovery, a batch with a miss, a
keyword search, a 200 KB result, a script that throws, `showCall`, the capability registry, an unknown
global and a fenced call. Every field is compared, including a failed script's `error` and the journal
row of a global the seam answered in place: there is no field this suite agrees not to look at. All of
it needs the pinned assets, because both paths run the real guest; in an unprovisioned checkout the
wrapper reports SKIPPED with the reason and exits 0 — a skip is never a pass. A node whose binary
predates `done-event.error` gets one named SKIP from the fast path for the same reason, and the suite
returns in full as soon as that binary is installed. The Rust tests above cover the same seam without a
guest (see the note in their header).
