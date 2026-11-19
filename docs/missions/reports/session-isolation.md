# session-isolation - surfaces belong to the session that created them

Mission `change/session-isolation`, branch `change/session-isolation`, base `origin/main` `e5ba9089`
(18/11). Built and tested HERE on avell (16 cores); committed locally, **never pushed**.

The audit (18/11, main `e5ba9089`) found ten places where one session could see or act on another
session's surface. This report says, per finding, what the code did, what it does now, which test pins it,
and - for the parts that are **not** done - exactly what is missing. Every test below was run with two
sessions on ONE scratch node (`WASM_AGENT_HOME`/`HOME` = a scratch directory,
`WASM_AGENT_LUA_ROOT` = this worktree, `WA_SCRIPT` = the test, `wa --db <scratch>/t.db`); the real
`~/.wasm-agent` is never touched. The runner is
`/home/victor/Work/missions/session-isolation/run-lua-test.sh <scratch> <script>`.

## 0. The rule, in one module

`lua/core/session_scope.lua` (new) is the one place that answers "which session is asking, and may it
reach past it". Every surface that takes a session argument asks it:

* no `scope` -> the caller's own session, and nothing else;
* `scope:"node"` -> the whole node, for the operator role (`users.is_master`, which `admin` normalizes
  onto) **only**, and written to the audit journal (`memory.journal("session_scope", ...)`) before the
  call is served - a node-wide read leaves a line an operator can find afterwards;
* any other scope -> refused by name (`scope_unknown`);
* an owner that cannot be named is **not** yours (unknown is not yes).

## 1. HIGH - the progress row is per session, and its file has an owner

**Was** (`rust/wa-capabilities/src/tool_progress.rs:41-42,74-116`, `rust/wa-tool-progress/src/lib.rs:186-192`,
`rust/wa-term/src/tool_progress.rs:103-109`): ONE live slot and ONE throttle per process, published to ONE
file, `<data>/tool-progress.json`, with no owner. `lua/core/tool_progress.lua:59-71,297-345`, the editor row
(`wa_term::tool_progress::current`) and `/health` all read that file as "my row". The row carries the last
line of the owner's stdout, so this was a **content** leak, and `finish` blanked every reader's row.

**Now**: one file per owner, `<data>/tool-progress/<key>.json`, where the key is the owning session's id
percent-encoded (`wa_tool_progress::owner_key` / `tool_progress.key` - the same algorithm, pinned against
one table on both sides). The publisher is keyed per session (`tool_progress::tick(..., owner)` publishes to
that session's file; the `LIVES`/`LAST` maps replaced the single slot and the single throttle), an
operation carries the session that asked (`Spec::session`, recorded in `state.json`), and a **reader draws
only its own file** - `wa_term::tool_progress::current(width, session)` and `tool_progress.status{session=}`.
What a session may learn about the others is one dim count, `node: N ops elsewhere`, and nothing else: the
count is taken from the directory listing by age alone (`count_elsewhere`), so no other session's file is
ever opened. `finish` removes **that** session's file. The CLI's session-status row shows the aggregate when
it has no notice of its own (`cli_view`'s `elsewhere_row`, kind `progress`).

**Test**: `scripts/test-session-isolation.lua` (finding 1 section) and `scripts/test-tool-progress-live.lua`
(one session's row appears; another session's is nil). Rust: `wa-tool-progress`'s
`an_owners_key_is_its_session_id_and_two_sessions_never_share_a_file` and `the_aggregate_is_a_count_...`,
`wa-term`'s `the_reader_counts_other_sessions_and_needs_no_word_of_them`, and
`scripts/test-tool-progress.lua`'s key table (the Lua half of the same pin).

## 2. HIGH - the operation tool only serves the session that owns the operation

**Was** (`lua/core/tools.lua:1543-1565` stamping `owner`, `rust/wa-capabilities/src/operations.rs:444-528`
never comparing it, `rust/wa-operation/src/lib.rs:599-640`): `list` answered with every operation on the
node, and `status`/`read`/`wait`/`await`/`cancel` answered for **any** id - and the ids are guessable
(`op-<micros>-<pid>-<n>`, `lib.rs:423-430`). `read` returns the operation's stdout, so this was another
content leak.

**Now**: the session travels with every action (`args.session`, set in `tools.lua` from
`session_scope.grant`). `operations::Caller` decides: an operation is yours when the caller IS a session and
the record names the same session; two nameless callers (a script, the node's own supervisor at a terminal)
are not two sessions and keep working. `list` filters and reports `operations_elsewhere`;
`status`/`read`/`wait`/`await`/`cancel` refuse by name (`operation_not_yours`, with the sentence that
says whose it is and that `scope:"node"` is the only way in); `read` refuses **before** opening the file;
`relevant` with `cwd:"*"` and `reconcile` need the node scope **for a session**; a sessionless caller
(the workspace release path, the node's own reconciler process, a script) is not a session and keeps both,
which is what the two-process reconciliation test (`scripts/test-operation-reconcile-json.cjs`, 27 checks)
pins. The engine route
(`lua/core/server.lua`'s `wa_operation`) now reads ONE session's operations - the conversation it is
told - and the node's only through `scope:"node"`; the window passes its session.

**Test**: the "`finding 2`" section of `scripts/test-session-isolation.lua` (A starts, B's five actions are
refused by name, A's own still work, `scope:"node"` reaches it, a non-operator cannot take the node scope,
an invented scope is named). Base run: 6 FAILs, quoted below.

## 3. HIGH - a peer acts in its own peer-session scope (partly done)

**Was** (`lua/core/server.lua:977-982`): a verified peer's capability call was dispatched with **no session**
and the caller's (master) role, so everything it asked for on this node was recorded with no session at all.

**Now**: the dispatch carries `session_id = "peer:<verified node id>"`, derived from the **verified** caller
and never from the request - a peer that names a `session_id` in its arguments cannot adopt another
conversation on this node. The peer chat thread per peer is unchanged and is by design.

**Not done**: "node scope over the mesh only if the target's policy grants it to that peer explicitly". No
grant surface on this node expresses "peer X may hold the node scope", so a peer that asks for one is
**refused by name** (`peer_node_scope_not_granted`) rather than served. Serving it would mean inventing a
policy, which this mission was not asked to do.

**Test**: no test - see "What is not verified" (a peer call needs a signed peer on the mesh; nothing on this
node fabricates one).

## 4. HIGH - a child agent belongs to the session tree that started it

**Was** (`rust/wa-capabilities/src/subagents.rs:666,678,702,734,782`; `lua/core/subagents.lua:655-800`): every
action was authorized by `owner_user = ctx.user_id` alone, so one session could read, list, message, steer
or cancel another session's child whenever both ran as the same user - which is EVERY session on this node,
because they all carry the operator's credential. The user was never the right key: the conversation is.

**Now**: the record already carried `parent_session_id` (`subagents.lua` has been writing
`parent_session_id = ctx.session_id` at start all along); what was missing was the use of it.
`in_session_tree(tasks, task, owner, session)` is the one rule: the task's user must match, and the caller's
session must be the task's parent session or an ancestor of it, so a session controls its own descendants
(a child, and a grandchild that child started) and nothing else. It is applied by `find` (status/result/
events), `list`, `lookup_session`, `continue_session`, `await_task` and `cancel`, bounded to 64 steps so a
malformed chain answers "no" instead of looping. `lua/core/subagents.lua` passes `session = ctx.session_id`
on every action. A caller that names no session keeps the user scope (a script, the node's control routes
and the peer capability's own path are not sessions); the operator's node scope over the mesh is the item
below that still needs a grant surface.

**Test**: `wa-capabilities`'s
`a_child_belongs_to_the_session_that_started_it` - one child, ownered by `alice` and parented by
`session-a`: `session-a` reads, lists and cancels it; `session-b` (the SAME user) can do none of the three;
a sessionless caller still can; a different user cannot.

## 5. HIGH - a tool child never inherits the node's own secrets

**Was**: `Command` inherits the environment, and `wa-operation` only *adds* `spec.env`
(`operations.rs:185`, `host.rs:4992`), so a `bash` child could print `WASM_AGENT_LLM_API_KEY`,
`OPENCODE_GO_API_KEY`, `OPENAI_API_KEY`, `WA_VAULT_ADMIN_TOKEN`, `GH_TOKEN` with `env` - into a transcript.

**Now**: `wa_operation::DENY_ENV` is a named policy applied at the one boundary every tool child crosses:
`denied_env(name)` matches the exact names below plus every `*_API_KEY` (so a new provider is covered
without editing the list), and both platform spawns remove those names from the inherited environment
**before** `spec.env` is applied - which is what keeps "a tool explicitly granted a name still gets it"
true. The list:

    WA_VAULT_ADMIN_TOKEN, WASM_AGENT_VAULT_ADMIN_TOKEN, WASM_AGENT_PROMPT_CACHE_KEY,
    WASM_AGENT_LLM_API_KEY, GH_TOKEN, GITHUB_TOKEN, API_KEY, *_API_KEY

Nothing else about a child's environment changed.

**Test**: the "finding 5" section of `scripts/test-session-isolation.lua`: a `bash` child prints `env`, the
four canaries (exported by the runner) are absent, and the control proves the rest of the environment still
arrives (`WA_TEST_CANARY_VISIBLE`). Base run: 4 FAILs.

## 6. HIGH - a run never resumes a thread a live process is serving

**Was** (`memory.ensure_session`, `memory.lua:664-672`; callers `agent.lua:873`, `server.lua:203`): a run
with no thread id took the newest open session, whether or not another process was writing it - two
conversations in one transcript, each one's tool results under the other's turns.

**Now**: `ensure_session` asks `presence_live` (the claim a live interpreter already takes) and, when
another pid holds the newest thread, starts a new one and returns a second value saying so:
`thread_busy: the newest open conversation <id> is being served by pid <pid>, so this run started <new id>`.
The caller's own process keeps its thread (a second turn in the same interpreter is not a second writer).
The CLI prints that sentence on its session line; `wa_admission` returns it as `thread_note`.

**Test**: the "finding 6" section of `scripts/test-session-isolation.lua` (a presence row from pid 999999 on
the newest thread; the run does not resume it and says why; with the row gone the thread is resumed again).

**The tolerance, said out loud**: the row is believed for 900 s, the same window `finish_session` already
uses for "this session is live". That is a real trade-off and not a hidden one: a process that is killed
without `presence_end` keeps its claim for up to fifteen minutes, so an anonymous run in that window starts
a new thread (and says so) instead of resuming the orphaned one. The alternative - trusting no row at all -
is the leak this finding is about. The original thread is still reachable by name: `wa chat --session <id>`.

## 7. MEDIUM - one session cannot take every operation slot

**Was** (`wa-operation/src/lib.rs:27,404-415`): `MAX_ACTIVE = 8` node-wide, so one session could hold all
eight and every other session's shell was refused `operation_capacity` until one settled (a read-MCP session
holds a slot for up to 3600 s).

**Now**: `PER_SESSION_MAX = MAX_ACTIVE - 2` (6 of 8): an admission check on the per-session count, with the
two spare slots being what keeps the node's own short reads and control paths able to run while a session
holds its share. The refusal names the share: `operation_capacity_shared: ...`. **The queue itself is
untouched** (harness-next-a owns it; this is an admission check, not a scheduler).

**Test**: the "finding 7" section of `scripts/test-session-isolation.lua`: one session starts operations until
it is refused, and the refusal is `operation_capacity_shared`. Base run: 2 FAILs.

## 8. MEDIUM - an empty-cwd operation is relevant only to its own session

**Was** (`wa-operation/src/index.rs:98-102`, `lib.rs:401`): the relevance query treated `cwd=''` as
relevant to every path, so an operation that recorded no directory blocked another session's worktree
release.

**Now**: `Index::relevant` selects the recorded `cwd` too and skips an empty-cwd row unless the caller is
the session that ran it (or holds the node scope). `wa-capabilities` passes the caller's session and node
scope through.

**Test**: `wa-operation`'s `an_operation_that_recorded_no_directory_is_relevant_only_to_its_session`
(two sessions' unresolved empty-cwd operations; A sees its own, not B's; the node scope sees both; an
unnamed caller sees neither).

## 9. MEDIUM - `/health` and the window status are the caller's session's

**Was** (`operations.rs:533-535`, `server.lua:1744-1746`): `/health` listed every node operation as the
view's, and the window's status fell back to the user's newest session - which on this node is always
somebody's, so a window that named no conversation was shown another session's telemetry.

**Now**: `/health?session_id=<id>` answers with **that** session's operations (`operations`, each carrying
`session`), the count of the rest (`operations_elsewhere`) and which view it is (`operations_scope:
"session"|"node"`); no session named is the node supervisor's node-wide view (the sentinel reads it, and the
overdue question is asked node-wide either way). The window sends its session and matches its operation by
`session` first. `wa_model`'s telemetry observation no longer falls back to `latest_session`: with no
conversation named it says `scope: "no session"`.

**Test**: the Rust half is `operations::health_scope` (unit-level shape, exercised through the two-session
Lua test's operation records); the window/route half is verified by reading the code paths above, not by an
end-to-end `/health` request - see "What is not verified".

## 10. MEDIUM - codemode's and `forget`'s ownership

**codemode** (`codemode.lua:910`): the scope key was `{session=ctx.session_id, ...}`, and a **nil** session
simply vanished from the encoded table, so every sessionless call shared one store and one pending index.
Now a call with no session gets its own key (`no-session:<uuid>:<clock>`): it can neither read nor collide
with anybody else's, and its own state does not survive the call - the honest answer for a caller that
cannot be named.

**forget** (`tools.lua:1667-1669`, `memory.lua:577-586`): an id was the whole authorization. Now
`memory.may_delete(id, caller_scope)` decides: a scoped caller deletes only from its own scope, an unknown id
deletes nothing, and the operator (no scope) may delete anything. The role gate that already refused a guest
stays in front of it.

**Test**: the "finding 10" section of `scripts/test-session-isolation.lua` (`may_delete` both ways, an
unknown id, and the operator's delete going through). The codemode half has no end-to-end test: this build
has empty code-mode assets (`WA_CODEMODE_ALLOW_EMPTY=1`), so the guest cannot run here.

## 11. By design - unchanged, documented only

These are shared on purpose and this branch does not change them: shared memory scopes (`global`, `user:<id>`),
master search across sessions (`search_messages`), one `TMPDIR` under the node root, vault operator signing
rights, node-wide MCP approvals, and the peer chat thread per peer (`server.lua:837-843`).

## 12. What is not verified, and what is not done

* **Finding 3's grant surface** - the peer scope is implemented; the explicit mesh grant does not exist, so a
  peer asking for the node scope is refused. Nothing on this node fabricates a signed peer, so the peer path
  has no test.
* **Finding 4's node scope** - a session controls its own descendants; the operator's node-wide view of every
  child on the node is the same missing grant surface, not a second hole.
* **`/health` end to end** - the filtering is a Rust function with a unit-level shape and the route passes
  `session_id`; no HTTP request was made in this session's tests.
* **codemode's nil-session key** - implemented, not exercised (empty code-mode assets in this build).
* **`ui/app.js`** - changed (session on the health request, `session_id` on the operation read, match by
  session); not run in a browser here. It is a JS change with no test in this branch.

## 13. The tests, quoted

Runner: `/home/victor/Work/missions/session-isolation/run-lua-test.sh <scratch dir> <script>` - scratch
`HOME` and `WASM_AGENT_HOME`, `WASM_AGENT_LUA_ROOT` = this worktree, its own `--db`, and four secret
canaries for finding 5. Binary: `/home/victor/wasm-agent/target/m-session-isolation/release/wa`
(`CARGO_TARGET_DIR` as the mission named it).

### Before: the same test on the base (`e5ba9089`, sources stashed, same scratch-node runner)

    FAIL B's list does not contain A's operation
    FAIL B's status of A's operation is refused by name (got nil, wanted operation_not_yours)
    FAIL B's read of A's operation is refused by name (got nil, wanted operation_not_yours)
    FAIL B's wait of A's operation is refused by name (got nil, wanted operation_not_yours)
    FAIL B's await of A's operation is refused by name (got nil, wanted operation_not_yours)
    FAIL B's cancel of A's operation is refused by name (got nil, wanted operation_not_yours)
    FAIL and the record says which session owns it: nil
    FAIL the owning session draws its own live row: nil
    FAIL the module has no per-session aggregate (tp.elsewhere)
    FAIL two sessions, two files: .../home/.wasm-agent/tool-progress.json / .../home/.wasm-agent/tool-progress.json
    FAIL a bash child cannot see OPENAI_API_KEY
    FAIL a bash child cannot see WASM_AGENT_LLM_API_KEY
    FAIL a bash child cannot see WA_VAULT_ADMIN_TOKEN
    FAIL a bash child cannot see GH_TOKEN
    FAIL the newest open thread is not resumed while a live process serves it: iso-busy-thread
    FAIL and the answer says which one was busy: nil
    FAIL and was refused before it took every slot on the node
    FAIL the refusal names the session's share, not the node: nil
    lua error: [string "scripts/test-session-isolation.lua"]:211: attempt to call a nil value (field 'may_delete')

### After: on this branch

    $ run-lua-test.sh scratch/iso2 scripts/test-session-isolation.lua
    [lua] memory: forget served natively: component_missing
    44 checks, 0 failed

    $ run-lua-test.sh scratch/tp2 scripts/test-tool-progress.lua
    95 checks, 0 failed

    $ run-lua-test.sh scratch/live scripts/test-tool-progress-live.lua
    22 checks, 0 failed

    $ run-lua-test.sh scratch/x scripts/test-cli-view.lua
    cli view ok (368 checks)

    $ run-lua-test.sh scratch/x scripts/test-thread-selection.lua
    thread selection ok (0 skipped)

    $ run-lua-test.sh scratch/x scripts/test-session-worktree.lua
    session worktree ok (17 checks)

    $ run-lua-test.sh scratch/x scripts/test-memory-window.lua
    memory window ok (13 checks)

    $ run-lua-test.sh scratch/x scripts/test-run-claim-release-live.lua
    ok run-claim-release: 7 checks

### Rust (`cargo test -p wa-operation -p wa-term -p wa-tool-progress --lib`)

    test result: ok. 41 passed; 0 failed; 1 ignored
    test result: ok. 133 passed; 0 failed; 0 ignored
    test result: ok. 17 passed; 0 failed; 0 ignored

### Rust, `wa-capabilities` (the subagent manager's own tests, finding 4)

    $ cargo test -p wa-capabilities --lib subagents
    test result: ok. 24 passed; 0 failed; 0 ignored

`scripts/test-subagents-profiles.lua` refuses to run without its isolated wrapper
(`policy_fixture_requires_isolated_wrapper`) - a pre-existing requirement of that row, not a failure of this
branch.

## 14. Texts to approve

Every new or changed model- or operator-facing string, verbatim.

Rows and the aggregate (finding 1):

    node: 1 op elsewhere
    node: N ops elsewhere

Operation ownership (finding 2), as `error` and `note`:

    operation_not_yours
    operation <id> is not your operation: another session owns it. Only an explicit node scope (scope:"node",
      operator only) may read or act on it.
    <N> other operation(s) on this node belong to other sessions; an explicit node scope (scope:"node",
      operator only) is the only way to see them
    relevant_node_scope_required
    relevant with cwd:"*" asks about every path on the node: it needs an explicit node scope
      (scope:"node", operator only)
    reconcile_node_scope_required
    reconciling settles an operation whose owner process is gone, so the request names no live session: it
      needs an explicit node scope (scope:"node", operator only)

The scope itself:

    scope_invalid
    a scope is the string "node" or nothing at all
    scope_unknown
    the only scope a tool takes is scope:"node" (the whole node, operator only)
    scope_node_forbidden
    scope:"node" is the operator role's alone: it reaches every session on this node

Peers (finding 3):

    peer_node_scope_not_granted
    a node-wide scope over the mesh needs this node's explicit grant to that peer; none is configured, so the
      request is refused rather than served

Capacity (finding 7):

    operation_capacity_shared: this session already holds <n> operation slots (its share is 6 of 8); settle
      or cancel one, or wait for it to finish

A busy thread (finding 6):

    thread_busy: the newest open conversation <id> is being served by pid <pid>, so this run started <new id>

Deleting (finding 10):

    forget_forbidden_scope
    this memory is not in a scope you may delete from; a scoped caller deletes only its own facts
    memory_not_found

`/health` (finding 9), new fields and their values:

    operations_scope: "session" | "node"
    operations_elsewhere: <count>
    session: <id>            (on each entry of operations[])
    observability.scope: "no session"      (was: another session's id, via latest_session)

## 15. How to run it

    # the binary (release, empty code-mode assets: this build cannot run the code-mode guest)
    cd rust && WA_CODEMODE_ALLOW_EMPTY=1 \
      CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-session-isolation \
      cargo build --release -p wa-host

    # the two-session test, on one scratch node
    /home/victor/Work/missions/session-isolation/run-lua-test.sh /tmp/iso scripts/test-session-isolation.lua

    # the Rust half
    cd rust && WA_CODEMODE_ALLOW_EMPTY=1 \
      CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-session-isolation \
      cargo test -p wa-operation -p wa-term -p wa-tool-progress --lib

# Round 4 (review 19/11 02:20)

Base of this round: `5f7a7931` (round 3). Every item below is a separate local commit; nothing was pushed.
Test runner: `/home/victor/Work/missions/session-isolation/run-lua-test.sh <scratch> <script>` (scratch
`HOME`/`WASM_AGENT_HOME`, its own `--db`, the real operation manager).

## Item 1 - the Fleet View's node-scope read (MUST)

**Was** (`lua/core/fleetview.lua:41-52`): `session_scope.grant(nil, ...)` - the memory module was `nil`, so
`session_scope.audit` returned early and a node-wide read left NO journal line - and the role was the
hard-coded `'master'`, so any caller was answered as the operator. The `host.operation('list', ...)` that
followed carried **no** `node_scope`, and a sessionless list is not a node-wide list (item 7 round 2): the
view printed the rows that named no owner as "the node's operations".

**Now**: `NODE_OPERATIONS(opts)` takes the caller's real `memory`, `role`, `user_id` and `session`; the grant
is asked with them (so it is audited, and a non-operator is refused), and the granted scope travels to the
runtime as `node_scope = grant.node` with the same session. A refusal is named on the node row
(`operations_refused`), never served as an empty list. `lua/core/tools.lua` passes `memory/role/user_id/
ctx.session_id`, and `fleetview.node_operations` is exported so the test drives THIS function.

**Test**: `scripts/test-session-isolation.lua`, section "item 1 round 4" (two sessions start one operation
each through `tools.dispatch`; the reader's answer contains BOTH; a `guest` caller gets `nil` +
`node_scope_not_granted`; the fleetview audit rows are counted before/after the read and must grow).
Measured both ways: **5 FAILs** on the round-3 code (the two expressions reverted in place), 0 with the fix.
**Wiring**: this script is the one in the fast path - `scripts/fast.sh:721`
`WA_BIN="$bin" check session-isolation bash scripts/test-session-isolation.sh` - so every item tested there
(1, 2, 4, 6, 7) runs on every fast check. The two OTHER scripts changed this round are NOT in `fast.sh`
(pre-existing): `scripts/test-tool-progress.lua` (item 3) and `scripts/test-thread-selection.lua`, run by
hand with the runner above; `scripts/test.sh` does not name them either. Wiring them is not done here and is
said rather than implied.

**Strings**: `node_scope_not_granted` (reason on `operations_refused`), `operation_manager_unavailable`,
`operation_list_unreadable`.

## Item 2 - session_watch observes its own run (MUST)

**Was** (`lua/core/session_watch.lua:221-226, 324`): `M.start` launches with `owner = 'session:' .. id`, but
`operation_state` called `host.operation('status', {id=...})` with NO owner. The runtime decides ownership by
`owner` for a caller that is not a session, so it answered `operation_not_yours`, `operation_state`
returned nil, and the watcher said `unknown` about a run it had started - `witness='none'`.

**Now**: `run_owner(session_id)` is the one spelling (`session:<id>`), the launch records that owner in the
durable run record, and `operation_state(record, session_id)` sends `owner` on the `status` call.

**Test**: same script, section "item 2 round 4": a real operation started with `owner='session:<id>'`; the
same id **without** the owner is refused by name (`operation_not_yours`, which is what round 3 sent); the
watcher then reports `state=running`, `witness=operation` and the operation id. Measured both ways: **3 FAILs**
on the round-3 line, 0 with the fix.

## Item 3 - "node: N ops elsewhere" counts operations (MUST)

**Was**: `tool_progress.elsewhere` (`lua/core/tool_progress.lua:360`) and `wa_term::tool_progress::
count_elsewhere` counted **live per-session progress FILES**, i.e. sessions with a row - four unsettled
operations in one session read as `node: 1 op elsewhere`.

**Now**: the count is the runtime's own `operations_elsewhere`, and `split_elsewhere` (one rule, used by
`list` and `health_scope`) counts **UNSETTLED** operations the caller does not own: 4 in one session = 4, a
settled one = 0. Lua: `M.elsewhere` asks `host.operation('list', ...)` and returns `nil` (not 0) when the
node cannot answer. Rust: `wa_term::tool_progress::current(width, session, elsewhere)` takes the number;
`operations::elsewhere_count` supplies it from `host.rs`.

**Test**: `scripts/test-tool-progress.lua` starts FOUR real operations in one other session and asserts
`tp.elsewhere(...) == 4`; the file fixtures now assert 0 (files are not the count). Rust:
`operations::elsewhere_count_tests::a_settled_operation_is_not_counted_elsewhere` and
`a_node_wide_caller_still_counts_only_unsettled_work_elsewhere`.

**Strings**: unchanged (`node: 1 op elsewhere` / `node: N ops elsewhere`).

## Item 4 - only short control calls take the reserved slots (MUST)

**Was**: `lua/core/mcp_session.lua:141` started the read-MCP session with `control=true` and
`timeout_seconds=3600`: a workload of one hour parked in the two slots kept for control calls.

**Now**: that start no longer claims the reserve (it is a workload with its own owner and share), and the
runtime enforces the rule so no other caller can either: `wa_operation::CONTROL_MAX_SECONDS = 60` and
`operations::reserve_refused(asked_control, seconds)` demote a longer start to a workload **and say so**
(`control_refused` on the receipt). Renamed string: `operation_capacity_control_reserved` ->
`queue_reserve_note` (round 3), unchanged here.

**Test**: `operations::elsewhere_count_tests::a_long_start_cannot_take_the_reserved_control_slots` (measured
failing when `reserve_refused` is stubbed to false), and the Lua section "item 4 round 4": a 60 s control start
is admitted with no refusal, a 3600 s one carries `control_refused`, and the read-MCP launch line carries no
`control=` field.

## Item 6 - /health takes its session from the credential (MUST)

**Was** (`rust/wa-capabilities/src/serve.rs:3409, 3579`): both `/health` routes answered
`health_body(query_value(query,"session_id"))` - the query string WAS the identity, so any caller could read
any session's operations.

**Now**: `lua/core/server.lua` `wa_health_scope(credential, requested)` decides from `x-wa-session`: a
session only when the credential owns it (or is master), otherwise the caller's OWN owner's work, no
credential = the node supervisor's view (the sentinel's unchanged route), and a credential that does not
resolve or a session that names nothing is **refused by name** (403), never served as an empty view. The
accept-thread route answers only the credential-less sentinel poll; everything else goes to the agent thread
where the credential is resolved.

**Test**: same script, section "item 6 round 4": no credential -> `node_wide=true`; authenticated with no
session -> not node-wide, own owner; own conversation visible; unknown id ->
`health_unknown_session`; bogus credential -> `health_credential_unresolved`.

**Strings**: `health_credential_unresolved`, `health_unknown_session`, `health_session_forbidden` and their
`note` sentences (`/health` section of "Texts to approve" below).

## Item 7 - the LOW items

* `wa_admission` now **mints the presence claim with the lease**: `memory.ensure_session` is a wrapper over
  `ensure_session_choose` that calls `presence_begin(chosen, {lease})`, so two unnamed admissions can no
  longer both see "nobody is in it" and share one thread. Test: "item 7 round 4" (two leases, two threads,
  `thread_busy`; the same lease keeps its thread).
* `workspaces.lua:731` vs `index.rs`: they now agree - an **ownerless legacy row still blocks release**
  for a session caller (`index.rs` skips only a row that names ANOTHER session). Test:
  `wa-operation`'s `an_operation_that_recorded_no_directory_is_relevant_only_to_its_session` gained the
  `op-legacy` assertion (measured failing against the round-3 rule).
* Test guard accepts macOS scratch: `^/var/folders/` added to `scripts/test-session-isolation.lua`'s refusal.
* `ENV_ALLOW`: it is a process-wide `OnceLock` filled when the manager is built, so a policy edit needs a
  node restart - **documented** in `docs/OPERATIONS.md` rather than silently promised otherwise.
* `DENY_ENV_SUFFIXES` gained `_SECRET_ACCESS_KEY` and `_PRIVATE_KEY` (allow-list still wins); documented.

## Item 8 - rebase-ready (not done unless asked)

`rust/wa-operation/src/lib.rs`'s `Spec` fields collide additively with `change/vault-one`; nothing was
resolved here. When asked: keep both field sets, no assertion touched.

## Deployment (for the release)

`openclaw`'s `policy.json` must list `GH_TOKEN` under `tool_env_allow` before this ships there - and the
policy edit only takes effect on the next start of that node (documented above, item 7).

## Texts to approve (round 4 additions)

    node_scope_not_granted
    operation_manager_unavailable
    operation_list_unreadable
    a start of <n>s is a workload, not a control call: the two reserved slots are kept for short calls
      (status, list, cancel, short reads, at most 60s)
    health_credential_unresolved
    this credential does not resolve, so /health cannot say whose work this is; log in again
    health_unknown_session
    no conversation on this node has that id, so there is no work of its to report
    health_session_forbidden
    that conversation is not yours to read; ask with a credential that owns it

## Tests, this round

    run-lua-test.sh scratch/iso13 scripts/test-session-isolation.lua   ->  136 checks, 0 failed
    run-lua-test.sh scratch/tp5   scripts/test-tool-progress.lua       ->   97 checks, 0 failed
    run-lua-test.sh scratch/th1   scripts/test-thread-selection.lua    ->  thread selection ok (0 skipped)
    cargo test -p wa-operation --lib                                   ->   45 passed, 1 ignored
    cargo test -p wa-term -p wa-capabilities -p wa-tool-progress --lib ->  green (17 / 325 / ...)

# Round 5 (review 19/11 03:10)

Base: `e4e40405` (release 1c). Branch rebased onto it first, clean, 15 commits replayed with no conflict;
no assertion was loosened. Four items, one commit each.

A note on where this report lives: the round brief asked for a `REPORT.md` in the worktree root. The
quality rules say a report lives in `docs/missions/reports/<name>.md` and never as a root `REPORT.md`,
so that rule wins and this section is the report.

## Where the brief's facts were stale, re-measured

* `split_elsewhere` is at `operations.rs:1086` (brief: ~1085), the `"list"` handler at `:1248`
  (brief: ~1248) - both correct in substance.
* Item 7's ownership block is `operations.rs:1039-1065` (brief: ~1050-1060).
* `scripts/test-tool-progress.lua:214` really was `os.remove` (brief correct).
* The brief asked to "grep your branch for any other io./os. use in Lua tests and port them". Measured
  on the branch diff (`git diff origin/main...HEAD`, plus the working tree): **exactly one** such call
  is mine - the `os.remove` above. The other 40 rows that still use `os.getenv`/`io.open`/`require`/
  `debug` are not added by this branch, and `change/vault-one` already ports 25 of them in its own
  branch; porting them here would conflict on landing and is not this mission's change.
* Item 1's real defect was narrower than "the list skips settled rows": the Fleet View incident also read
  `entry.id`, and an operation row has never carried `id` (it carries `operation_id`), so every real
  failure was announced as `operation ? settled as failed`.

## Item 1 - the caller's own settled operations (MUST)

    rust/wa-capabilities/src/operations.rs | 68 ++++++++++++++++++++++++++++++----
    lua/core/fleetview.lua                 |  8 +++-
    scripts/test-session-isolation.lua     | 39 +++++++++++++++++++

`split_elsewhere` decided *settlement first, ownership second*: every settled row was skipped before
the caller was asked about it, so a caller's own **failed** operation vanished from its own `list` the
moment it settled - the one row a caller most needs to read back. Now ownership decides `mine` (settled
or not) and settlement narrows **only the count**:

```rust
if caller.owns(state) { mine.push(state.clone()); }
else if state["settled"] != true { elsewhere += 1; }
```

`/health` stays a **now-view** and filters settled rows at its own call site, so a health page still
answers "what is this node doing" and not "what has it done".

Also fixed: `fleetview.lua`'s incident read the row's `id`, which an operation row does not have.

Tests (both drive the real manager, not a stub):

* Rust `the_callers_own_failed_operation_stays_in_its_list` - a failed, settled row is in its owner's
  list with its `state`; another session's settled row is not counted elsewhere.
* Rust `a_settled_operation_row_names_its_id_as_operation_id`.
* Lua, `scripts/test-session-isolation.lua` "ITEM 1 (round 5)": session A starts `exit 3`, waits for it,
  and asserts the settled failure is still in A's list, that B still cannot see it, and that
  `fleetview.telemetry_incidents` reports it as `operation_failed` **naming the operation's own id**.

Predicted-by-reading and then measured: reverting both source changes turns the row red with exactly
5 failures (list, row state, incident present, incident id, incident sentence) - the negative test.

## Item 2 - a caller with no session and no owner owns nothing (MUST, implemented narrower)

    rust/wa-capabilities/src/operations.rs | 34 +++++++++++++++++++++++++++++++++-

The brief's rule, implemented literally, breaks three real rows: `host.exec` starts a sessionless
operation owned by `worker:<node-thread>`, and the *same* script must then read it back, cancel it and
await its settlement (`test-exec-timeout` line 8, `test-bash-long-command` line 8,
`test-workspace-cwd`). Measured with the literal rule: 3 of 3 red.

So the rule is: **a sessionless, ownerless caller owns a `worker:<n>` row only when `<n>` is the node
thread it is itself running on.** Rounds 2-4 matched `worker:*`, so one sessionless script owned *every*
thread's foreground shell. This is narrower, not wider - the identity is the caller's own and no caller
can choose it. Rows a session named, and rows another *named* owner started, remain out of reach.

    before: runtime_owner.is_empty() || (runtime_owner.starts_with("worker:") && owner.is_empty())
    after:  runtime_owner.is_empty() || (starts_with("worker:") && owner.is_empty() && runtime_owner == own_thread)

Test: Rust `a_sessionless_caller_owns_only_its_own_threads_worker_row` (own thread owned; sibling
`worker:424242` not; a named owner not; a session's row not). Negative test: restoring the wide rule fails
that row; restoring the narrow rule passes it, and the three dependent rows are green again
(`test-exec-timeout` 39 checks, `test-bash-long-command` 10, isolation row 141).

The fast path, in a scratch home (`HOME=/home/victor/wasm-agent/tmp/iso-r5/fast`):

    fast result ok (294 checks, 0 failed, 0 skipped)
    fast path ok (294 checks, 0 skipped, 396s)

An earlier fast run on this node reported 2 failures, both `Disk quota exceeded (os error 122)` - `/tmp`
is a 16 GB tmpfs and it was at 80%. That run overlapped my edits and is not a baseline; after moving
scratch off `/tmp` the same tree ran 294/0.

## Item 3 - forward compatibility with change/vault-one (MUST)

    scripts/test-tool-progress.lua | 10 +++++++++-

`change/vault-one` strips `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`, `os.execute`,
`io.open/lines/popen/tmpfile/input/output/close`, plus `dofile`, `loadfile`, `require`,
`package.loadlib` and `debug` in **both** interpreters (measured in its
`SANDBOX_LUA`, `wa-host-support/src/lua.rs:130`). `scripts/test-tool-progress.lua:214` used `os.remove`.

Ported to the host door that survives the sandbox (`host.exec`), and the removal is **asserted** rather
than fired and hoped for - a port that silently stopped deleting would still pass the count check that
follows it, because that count comes from the operation manager and was already 0:

```lua
local removed_ok, removed_raw = pcall(host.exec, "rm -f '" .. removed_path .. "'", "", 30, "{}")
ok(removed_ok, "the live file was removed through the host: " .. tostring(removed_raw))
eq(host.path_kind(removed_path), "missing", "and it is really gone from the disk")
```

Test: the row itself, in the fast path (`scripts/fast.sh` runs every `scripts/test-*.lua` not in
`scripts/fast-path.exclude`) - 99 checks, 0 failed. Negative test: replacing `rm -f` with a no-op gives
`FAIL and it is really gone from the disk (got file, wanted missing)`; with the host call it is green.

## Item 4 - the LOW items

    lua/core/fleetview.lua             | 24 ++++++++++++++++++++++--
    scripts/test-session-isolation.lua | 30 ++++++++++++++++++++++++++++++

* **No journal, no node-wide read.** `session_scope.audit` returns early without a store, so a Fleet View
  that arrived with a nil `memory` read every session's operations and left no line - the same unaudited
  node read round 4 removed, reachable again by a caller that forgot the store. `NODE_OPERATIONS` now
  refuses by name: `fleetview_requires_a_journal`.
* **The misleading comment is fixed** (`lua/core/fleetview.lua:38-40`): it now says, verbatim, that
  `surface = 'fleetview'` is a name **this file** sets and the tool's schema has no `surface` field, that
  this is why the Fleet View TOOL - a model tool call - is granted the node scope at all, that it is an
  **audited exception** rather than a hole, and that the audit is enforced twice (grant writes the line;
  `NODE_OPERATIONS` refuses without a journal).
* **The row now names why operations are missing.** `M.node` dropped `observation.operations_refused`,
  so a guest's row carried `missing: ["operations"]` and nothing else - "nothing is running" and "you may
  not see it" read the same, which is the failure the Fleet View's own header promises never to make.
* **The tools.lua wiring has a test.** The isolation row drives `tools.dispatch(memory, 'fleetview', …)`
  as a **guest** (row present, `operations` absent, `operations_refused = 'node_scope_not_granted'`) and as
  the **operator** (`operations` is a table), instead of only calling the module.

Tests: `test-session-isolation.lua` "ITEM 4 (round 5)" - 4 checks for the journal refusal (nil memory,
and a memory whose `journal` is not callable), 6 for the tool wiring through the dispatcher. Negative
test: deleting the journal refusal fails exactly those 4 checks and the row reports `141 checks, 4 failed`.

## Texts to approve (round 5 additions)

    fleetview_requires_a_journal

That is the only new operator- or model-facing string this round. The guest's existing reason
(`node_scope_not_granted`) is reused, not reworded.

## Tests, this round (all measured here, on avell)

    cargo test -p wa-capabilities --lib            -> 328 passed, 0 failed
    cargo test -p wa-operation                    ->  45 passed, 0 failed, 1 ignored
    bash scripts/fast.sh (scratch HOME)           -> fast result ok (294 checks, 0 failed, 0 skipped), 396s
    test-session-isolation.lua                    -> 141 checks, 0 failed
    test-fleetops.lua                             -> 147 checks, 0 failed
    test-session-watch.lua                        -> 107 checks passed
    test-tool-progress.lua                        ->  99 checks, 0 failed
    test-exec-timeout.lua                         ->  39 checks, 0 failed
    test-bash-long-command.lua                    ->  10 checks, 0 failed
    test-changeset.lua                            ->  40 checks, 0 failed
    test-done-gate.lua                            ->  58 checks, 0 failed
    test-hooks-tools.lua                          ->  25 checks, 0 failed
    test-redact-secrets.lua                       ->  23 checks, 0 failed

What I could NOT verify: no independent review - the self-review is labelled as such. Nothing was pushed;
commits are local. `test-workspace-cwd.lua` refuses to run here without `WA_CWD_SOURCE` and a wave
registration for this repository, so it is named as a dependency of item 2 measured green only through
the two rows above; it is in `scripts/fast-path.exclude` and is not part of the fast path.

DEPLOY NOTE stands: `openclaw`'s `policy.json` must list `GH_TOKEN` under `tool_env_allow`, and the policy
edit only takes effect on the next restart of that node.
