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
