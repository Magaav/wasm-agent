-- Session isolation (mission change/session-isolation, 18/11): every surface belongs to the session
-- that created it, and another session reaches it only through the explicit node scope.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-session-isolation.lua \
--     wa --db <scratch>/t.db
--
-- TWO SESSIONS ON ONE SCRATCH NODE, never the real ~/.wasm-agent. What is pinned here is the pair of
-- findings the rest of this mission hangs on:
--
--   * finding 1 - a long call's progress row is the OWNING session's. Another session draws no row of
--     it (not the tool, not the clock, above all not the last line of its output) and is told one
--     count: `node: N ops elsewhere`. This row used to be one file per node with no owner, so every
--     session's reader drew whatever had been written last.
--   * finding 2 - the `operation` tool's actions are the owning session's. `list` answers with that
--     session's operations, and `status`/`read`/`wait`/`await`/`cancel` on another session's id are
--     refused by name (`operation_not_yours`). The owner was stamped and never compared, and the ids
--     are guessable.
--   * the one way past it: `scope:"node"` - an operator SURFACE's (Fleet View, the window's route) or a
--     session the OPERATOR marked mastermind, audited with the surface named. Not a role's: every session
--     carries the operator's credential, so a role check refused nothing (item 7, round 2).
-- ---- item 6: this script refuses to run anywhere but a scratch node ----------------------
--
-- It writes sessions, memories, operations and workspace bindings. Run against the REAL node it would
-- write the operator's own ledger - the exact class of accident this mission exists to stop, committed by
-- its own test. So the first thing it does is look at WASM_AGENT_HOME: a path that says scratch or temp,
-- and never the node's own ~/.wasm-agent.
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\]+$", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
  local real_node = trimmed:match("[/\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

local json = dofile('lua/vendor/json.lua')
local platform = dofile('lua/core/platform.lua')
local tp = dofile('lua/core/tool_progress.lua')
local tools = dofile('lua/core/tools.lua')
local memory = dofile('lua/core/memory.lua')
local scope_lib = dofile('lua/core/session_scope.lua')
-- The served node's own resolver (wa_admission/wa_operation): loaded once, here, so the admission half of
-- item 3 can be driven through the same function a served run is admitted by.
dofile('lua/core/server.lua')
-- A scratch database has no tables until the node's own setup runs it (`wa serve` and `wa chat` call it at
-- boot); this script drives the memory module directly, so it does the same thing here.
memory.setup()

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end
local function decode(raw)
  local ok_decode, value = pcall(json.decode, raw or '')
  return ok_decode and type(value) == 'table' and value or nil
end

-- Two sessions of the same operator. They are the ordinary case the leak was measured on: the operator
-- runs two conversations at once, and every session carries the operator's own role.
local ctx_a = { session_id = "iso-session-a", user_id = "master" }
local ctx_b = { session_id = "iso-session-b", user_id = "master" }
-- The two conversations exist in the ledger: a session id that names no row is not a conversation, and the
-- operator's own mark (item 7) is a column on that row.
for _, known in ipairs({ "iso-session-a", "iso-session-b" }) do
  if not memory.session(known) then
    memory.start_session("", "isolation", { id = known, user_id = "master", node_id = "" })
  end
end

-- The shell command only has to outlive this test's own polling; its output goes to the shell's null
-- device, which follows the SHLL the host runs (Windows' `sh` writes a file called NUL otherwise).
local shell = tostring(platform.shell() or ""):lower()
local null_device = shell:find("cmd", 1, true) and "NUL" or "/dev/null"
local command = shell:find("cmd", 1, true) and ("ping -n 8 127.0.0.1 >" .. null_device)
  or ("sleep 8 >" .. null_device .. " 2>&1")

-- ---- finding 2: the operation tool is the owning session's -------------------------------

-- A starts a supervised operation. Its record carries the session that asked.
local started = tools.dispatch(memory, "operation", { action = "start", command = command, timeout_seconds = 60 },
  "master", ctx_a)
ok(type(started) == 'table' and type(started.operation_id) == 'string', "session A started an operation")
local id = type(started) == 'table' and started.operation_id or nil
if not id then
  print(string.format("%d checks, %d failed", checks, failed))
  os.exit(1)
end

-- `list` answers with the caller's own operations. The runtime used to answer with every operation on
-- the node, and the window/Lua shape used to be a bare array: accept either, ask the same question.
local function listed(value, operation_id)
  local items = type(value) == 'table' and (value.operations or value) or {}
  if type(items) ~= 'table' then return false end
  for _, entry in pairs(items) do
    if type(entry) == 'table' and entry.operation_id == operation_id then return true end
  end
  return false
end
local mine = tools.dispatch(memory, "operation", { action = "list" }, "master", ctx_a)
ok(listed(mine, id), "A's own operation is in A's list")
local theirs = tools.dispatch(memory, "operation", { action = "list" }, "master", ctx_b)
ok(not listed(theirs, id), "B's list does not contain A's operation")

-- Every id-carrying action refuses another session's operation, by name.
local actions = { { "status", {} }, { "read", { stream = "stdout", limit = 64 } }, { "wait", { wait_ms = 1 } },
  { "await", { wait_for = "command" } }, { "cancel", {} } }
for _, action in ipairs(actions) do
  local request = { action = action[1], id = id }
  for key, value in pairs(action[2]) do request[key] = value end
  local answer = tools.dispatch(memory, "operation", request, "master", ctx_b) or {}
  eq(answer.error, "operation_not_yours", "B's " .. action[1] .. " of A's operation is refused by name")
end
-- A itself can do all of it: the refusal is about whose it is, not about the operation.
local state = tools.dispatch(memory, "operation", { action = "status", id = id }, "master", ctx_a) or {}
eq(state.operation_id, id, "A can read its own operation")
ok(state.session == "iso-session-a", "and the record says which session owns it: " .. tostring(state.session))
local page = tools.dispatch(memory, "operation", { action = "read", id = id, stream = "stdout", limit = 64 },
  "master", ctx_a) or {}
eq(page.operation_id, id, "and can read its own output")

-- The one way past it: `scope:"node"`, the operator's, audited.
-- The node scope exists, and a MODEL CALL cannot take it any more (item 7, round 2): the operator role is
-- not the grant, a surface or the operator's own mark is. What it reaches, once granted, is item 7's
-- section below.
local node_refused = tools.dispatch(memory, "operation", { action = "status", id = id, scope = "node" }, "master", ctx_b) or {}
eq(node_refused.error, "scope_node_forbidden", "a model call does not get the node scope, even on an id it can name")
-- ... and only the operator's role gets it.
local grant, refusal = scope_lib.grant(nil, { scope = "node" }, ctx_b, "guest", "guest", "operation")
ok(grant == nil, "a non-operator cannot take the node scope")
eq(type(refusal) == 'table' and refusal.error, "scope_node_forbidden", "and is refused by name")
local other, other_refusal = scope_lib.grant(nil, { scope = "global" }, ctx_a, "master", "master", "operation")
ok(other == nil, "an invented scope is not a scope")
eq(type(other_refusal) == 'table' and other_refusal.error, "scope_unknown", "and it is named too")

-- ---- finding 1: the progress row is the owning session's ---------------------------------

-- The row is published by whoever is waiting on the operation, so a bounded wait is what makes it
-- appear. It is A's row and it stays A's.
local waited = decode(host.operation("wait", json.encode({ id = id, wait_ms = 3000, session = "iso-session-a" })))
ok(type(waited) == 'table', "the wait on A's own operation answered")
local clock = os.time()
local row_a = tp.status({ session = "iso-session-a", now = clock, refresh = true })
ok(type(row_a) == 'table' and type(row_a.text) == 'string' and row_a.text ~= "",
  "the owning session draws its own live row: " .. tostring(row_a and row_a.text))
local row_b = tp.status({ session = "iso-session-b", now = clock, refresh = true })
ok(row_b == nil, "another session draws NO row of it: " .. tostring(row_b and row_b.text))
-- The count is all B may learn about A's work.
if type(tp.elsewhere) == 'function' then
  local count = tp.elsewhere({ session = "iso-session-b", now = clock })
  ok(tonumber(count) and tonumber(count) >= 1, "and is told one count: " .. tostring(count))
  eq(tp.elsewhere_text(1), "node: 1 op elsewhere", "the aggregate says a number and nothing else")
  -- The owning session's own work is not "elsewhere" to itself.
  eq(tonumber(tp.elsewhere({ session = "iso-session-a", now = clock })), 0, "and A's own work is not elsewhere to A")
else
  ok(false, "the module has no per-session aggregate (tp.elsewhere)")
end
-- Nothing about another session's row is readable from the file it lives in: the module resolves the
-- path from the reader's own session.
if type(tp.path) == 'function' then
  local path_a = tp.path({ session = "iso-session-a" })
  local path_b = tp.path({ session = "iso-session-b" })
  ok(path_a ~= path_b, "two sessions, two files: " .. tostring(path_a) .. " / " .. tostring(path_b))
else
  ok(false, "the module cannot name a per-session file (tp.path with a session)")
end

-- ---- finding 5: a tool child never inherits the node's own secrets ------------------------

-- The canaries are exported by `run-lua-test.sh` (scripts/test-session-isolation.sh in CI): the node
-- itself holds them, and `env` inside a bash child is how a model would read them.
-- The canaries are the SUBJECT of this section: a runner that exports none of them has nothing to test
-- here, so it is a named SKIP and never a pass. scripts/test-session-isolation.sh exports them, and the
-- fast path runs that wrapper.
local function canaries_ready(names, control)
  if host.getenv(control) == nil then return false end
  for _, name in ipairs(names) do if host.getenv(name) == nil then return false end end
  return true
end
local finding5_ready = canaries_ready({ "OPENAI_API_KEY", "WASM_AGENT_LLM_API_KEY", "WA_VAULT_ADMIN_TOKEN", "GH_TOKEN" },
  "WA_TEST_CANARY_VISIBLE")
if not finding5_ready then
  print("SKIP finding 5: this runner exported no canaries to withhold (scripts/test-session-isolation.sh does)")
end
if finding5_ready then
local probe = tools.dispatch(memory, "bash", { command = "env" }, "master", ctx_a) or {}
local environment = tostring(probe.stdout or "")
ok(environment ~= "", "the bash child ran and printed its environment: " .. tostring(probe.error))
for _, name in ipairs({ "OPENAI_API_KEY", "WASM_AGENT_LLM_API_KEY", "WA_VAULT_ADMIN_TOKEN", "GH_TOKEN" }) do
  ok(not environment:find(name .. "=", 1, true), "a bash child cannot see " .. name)
end
-- The control: the child DID get the rest of the node's environment, so the checks above are not
-- passing because `env` printed nothing.
ok(environment:find("WA_TEST_CANARY_VISIBLE=", 1, true) ~= nil,
  "and the rest of the environment still reaches it (the control) ")
end

-- ---- finding 6: a thread a live process is serving is never resumed -----------------------

-- A presence row is the claim a live interpreter takes. A row from ANOTHER pid is another process serving
-- that conversation, and the run must not write into it.
local busy = memory.start_session("", "isolation-busy", { id = "iso-busy-thread", user_id = "master", node_id = "" })
ok(busy == "iso-busy-thread", "a thread to keep busy exists")
local stamped = host.now()
pcall(host.sql_exec, "INSERT OR REPLACE INTO session_presence(session_id,pid,boot,role,started_at,heartbeat_at) VALUES(?,?,?,?,?,?)",
  json.encode({ "iso-busy-thread", 999999, "boot-other", "master", stamped, stamped }))
local chosen, note = memory.ensure_session("master", "", "chat")
ok(chosen ~= "iso-busy-thread", "the newest open thread is not resumed while a live process serves it: " .. tostring(chosen))
ok(type(note) == 'string' and note:find("thread_busy", 1, true) ~= nil,
  "and the answer says which one was busy: " .. tostring(note))
-- A thread nobody is serving is still resumed: the rule is about a live claim, not about age.
pcall(host.sql_exec, "DELETE FROM session_presence WHERE session_id=?", json.encode({ "iso-busy-thread" }))
local again = memory.ensure_session("master", "", "chat")
ok(type(again) == 'string' and again ~= "", "with nobody holding it, a thread is resumed as before")

-- ---- finding 7: one session cannot take every operation slot ------------------------------

-- `wa-operation` admits 8 at once and one session used to be able to hold all 8. Its share is 6, and the
-- refusal names the share instead of saying the node is full.
local held = {}
local long = shell:find("cmd", 1, true) and ("ping -n 40 127.0.0.1 >" .. null_device)
  or ("sleep 30 >" .. null_device .. " 2>&1")
local refusal = nil
for index = 1, 7 do
  local answer = tools.dispatch(memory, "operation", { action = "start", command = long, timeout_seconds = 120 },
    "master", ctx_a) or {}
  if type(answer.operation_id) == 'string' then
    held[#held + 1] = answer.operation_id
  else
    refusal = tostring(answer.error or "none")
    break
  end
end
ok(#held >= 1, "the session started operations: " .. #held)
ok(refusal ~= nil, "and was refused before it took every slot on the node")
ok(refusal ~= nil and refusal:find("operation_capacity_shared", 1, true) ~= nil,
  "the refusal names the session's share, not the node: " .. tostring(refusal))
for _, operation in ipairs(held) do
  tools.dispatch(memory, "operation", { action = "cancel", id = operation }, "master", ctx_a)
end

-- ---- finding 10: forget needs an owner, not an id -----------------------------------------

local fact_id = memory.remember("isolation canary fact", "global", {})
ok(type(fact_id) == 'string', "a shared fact exists to try to delete")
-- The tool refuses a guest outright (the role gate that predates this mission), and the scope rule behind
-- it is what stops an id from being an authorization: asked directly, both sides.
local guest_delete = tools.dispatch(memory, "forget", { id = fact_id }, "guest", { user_id = "iso-guest" }) or {}
eq(guest_delete.error, "forbidden_for_role:guest", "a guest cannot call forget at all")
local scoped, why = memory.may_delete(fact_id, "user:iso-guest")
eq(scoped, false, "a scoped caller may not delete another scope's fact")
eq(why, "forget_forbidden_scope", "and the refusal has a name")
eq(memory.may_delete(fact_id, nil), true, "the operator, who holds no scope, may delete it")
eq(memory.may_delete("no-such-id", "user:iso-guest"), false, "and an unknown id deletes nothing")
local owner_delete = tools.dispatch(memory, "forget", { id = fact_id }, "master", ctx_a) or {}
eq(owner_delete.forgotten, true, "the operator's delete goes through")

-- A's call ends; nothing of it is left for anyone.
local cancelled = tools.dispatch(memory, "operation", { action = "cancel", id = id }, "master", ctx_a) or {}
ok(cancelled.operation_id == id, "A cancels its own operation")

-- ---- item 1: forget's allow answer can be NO ----------------------------------------------------
--
-- The rule was right and the line that applied it collapsed to true: "memory.may_delete and
-- memory.may_delete(...) or true" answers true whenever may_delete() returns false, so the tool could
-- never refuse. Called THROUGH the tool this time, because that is where the collapse lived.
local canary = memory.remember("isolation forget item-1 canary", "global", {})
ok(type(canary) == 'string', "a fact exists to try to forget (item 1)")
local unknown_forget = tools.dispatch(memory, "forget", { id = "no-such-memory-id" }, "master", ctx_a) or {}
eq(unknown_forget.error, "memory_not_found", "forget through the tool refuses an unknown id by name (item 1)")
ok(unknown_forget.forgotten == nil, "and answers no deletion, not true")
local guest_forget = tools.dispatch(memory, "forget", { id = canary }, "guest", { user_id = "iso-guest" }) or {}
eq(guest_forget.error, "forbidden_for_role:guest", "a guest still cannot call forget at all")
ok(type(memory.scope_of(canary)) == 'string', "the fact survives a refused forget")
local scoped_arm, scoped_why = memory.may_delete(canary, "user:iso-guest")
eq(scoped_arm, false, "the scope arm itself still refuses another scope")
eq(scoped_why, "forget_forbidden_scope", "and names it, so the tool's refusal has words to print")
local forgot = tools.dispatch(memory, "forget", { id = canary }, "master", ctx_a) or {}
eq(forgot.forgotten, true, "the operator's own forget still goes through")

-- ---- item 2: a session's own work blocks its own release -----------------------------------
--
-- The release fence asks the operation index what is still unresolved under a path. A call that named no
-- directory but ran in the session's worktree recorded cwd="" and (round 1) an empty-cwd row was skipped
-- for a sessionless caller - so the fence could not see the very work it was meant to wait for.
local worktree = tostring(host.paths().temp) .. "/iso-item2-tree-" .. tostring(os.time())
host.exec("mkdir -p '" .. worktree .. "'", '')
local wsid = memory.start_session("", "isolation-worktree", { id = "iso-worktree-session", user_id = "master", node_id = "" })
ok(wsid == "iso-worktree-session", "a session to own a worktree exists")
memory.set_session_worktree(wsid, worktree)
local ctx_w = { session_id = wsid, user_id = "master" }
local in_tree = tools.dispatch(memory, "operation", { action = "start", command = command, timeout_seconds = 60 }, "master", ctx_w) or {}
ok(type(in_tree.operation_id) == 'string', "a long bash in the session's worktree started (item 2)")
local function plain(path) return tostring(path or ""):gsub("\\", "/"):gsub("/+$", "") end
eq(plain(in_tree.cwd), plain(worktree), "and the record names the RESOLVED worktree, not an empty cwd")
local fence = decode(host.operation("relevant", json.encode({ cwd = worktree, limit = 1, session = wsid }))) or {}
ok(fence.ok == true and type(fence.operations) == 'table' and #fence.operations == 1,
  "the release fence, asked AS THAT SESSION, sees its own unresolved work: " .. json.encode(fence))
local fence_rows = fence.operations or {}
eq(fence_rows[1] and fence_rows[1].operation_id, in_tree.operation_id, "and the row is the operation that is running")
if type(in_tree.operation_id) == 'string' then
  tools.dispatch(memory, "operation", { action = "cancel", id = in_tree.operation_id }, "master", ctx_w)
end

-- ---- item 3: two runs in ONE process are two runs ------------------------------------------
--
-- Inside one `wa serve` every run shares one pid, so a presence row compared by pid answered "mine" to
-- every run of the server and two unnamed runs wrote one transcript. The lease is the run's own name.
local agent = dofile('lua/core/agent.lua')
local first_run = agent.new(nil, nil, "master", "master", "", {})
local second_run = agent.new(nil, nil, "master", "master", "", {})
ok(type(first_run) == 'table' and type(second_run) == 'table', "two runs built in ONE process (item 3)")
if type(first_run) == 'table' and type(second_run) == 'table' then
  ok(first_run.session_id ~= second_run.session_id,
    "the second unnamed run gets its own thread, not the first run's: " .. tostring(first_run.session_id) .. " / " .. tostring(second_run.session_id))
  ok(tostring(second_run.session_note or ""):find("thread_busy", 1, true) ~= nil,
    "and says which run held the newest thread: " .. tostring(second_run.session_note))
  local presence = memory.presence(first_run.session_id) or {}
  ok(tostring(presence.lease or "") ~= "", "the presence row carries the run's lease, not only a pid")
  -- ... and the same question through the node's own admission resolver, which is what `wa serve` asks
  -- BEFORE a run exists. An unnamed request while another run holds the newest thread is its own thread.
  local admitted = decode(wa_admission("", "", "{}")) or {}
  ok(type(admitted.conversation) == 'string' and admitted.conversation ~= "",
    "admission names the conversation an unnamed run will write: " .. tostring(admitted.conversation))
  ok(admitted.conversation ~= second_run.session_id,
    "and it is not the thread the live run is serving: " .. tostring(admitted.conversation))
  ok(tostring(admitted.thread_note or ""):find("thread_busy", 1, true) ~= nil,
    "and admission says why it started one: " .. tostring(admitted.thread_note))
end

-- ---- item 5: two slots no workload may take, and a sessionless start counts -----------------
--
-- Round 1 administered a per-session share of 6 of 8 and nothing else: two sessions at four each filled
-- all eight while neither was over its share, and then "cancel the runaway" was refused for want of a
-- slot. The reserve is two slots a CONTROL start may take and a workload may not - and after the
-- round-3 rebase it lives in the node's QUEUE (harness-next-a's Slot), not in an admission refusal:
-- a workload that finds only the reserve left is admitted and WAITS, it is not turned away, and the
-- operation records queue_limit=6 and queue_reserve=2 while it waits.
local long_command = shell:find("cmd", 1, true) and ("ping -n 40 127.0.0.1 >" .. null_device)
  or ("sleep 30 >" .. null_device .. " 2>&1")
-- Nothing of this test's own is left running: the count below is about what THIS section starts.
tools.dispatch(memory, "operation", { action = "cancel", id = id }, "master", ctx_a)
local ctx_c = { session_id = "iso-session-c", user_id = "master" }
local ctx_d = { session_id = "iso-session-d", user_id = "master" }
local held_c = {}
for _ = 1, 7 do
  local answer = tools.dispatch(memory, "operation", { action = "start", command = long_command, timeout_seconds = 120 }, "master", ctx_c) or {}
  if answer.operation_id then held_c[#held_c + 1] = answer.operation_id
  else
    ok(tostring(answer.error or ""):find("operation_capacity_shared", 1, true) ~= nil,
      "the seventh start by one session is refused by its share: " .. tostring(answer.error))
    break
  end
end
eq(#held_c, 6, "one session takes its whole share - six of the node's eight slots: " .. #held_c)
-- A second session is NOT refused: its start is admitted and waits behind the reserve.
local held_d = {}
for _ = 1, 2 do
  local answer = tools.dispatch(memory, "operation", { action = "start", command = long_command, timeout_seconds = 120 }, "master", ctx_d) or {}
  if answer.operation_id then held_d[#held_d + 1] = answer.operation_id else break end
end
eq(#held_d, 2, "a second session's starts are admitted, not refused: " .. #held_d)
local queued_d = nil
for _ = 1, 60 do
  local status = tools.dispatch(memory, "operation", { action = "status", id = held_d[1] }, "master", ctx_d) or {}
  if status.state == "queued" then queued_d = status break end
  if status.state == "running" or status.settled == true then break end
  host.sleep(50)
end
ok(queued_d ~= nil and tonumber(queued_d.queue_limit) == 6,
  "and they WAIT for a workload slot instead of filling the node: " .. json.encode(queued_d or {}):sub(1, 300))
ok(queued_d ~= nil and tonumber(queued_d.queue_reserve) == 2,
  "behind the two slots no workload may take: " .. json.encode(queued_d or {}):sub(1, 300))
-- A CONTROL start (the node's own short read) is admitted into the reserve...
local control_start = decode(host.operation("start", json.encode({ command = "echo control", timeout_seconds = 60,
  owner = "mcp-read-session", control = true }))) or {}
ok(type(control_start.operation_id) == 'string',
  "a control start is admitted while every workload slot is full: " .. json.encode(control_start):sub(1, 200))
local control_ran = nil
for _ = 1, 40 do
  local status = decode(host.operation("status", json.encode({ id = control_start.operation_id, owner = "mcp-read-session" }))) or {}
  if status.state == "running" or status.settled == true then control_ran = status break end
  host.sleep(50)
end
ok(control_ran ~= nil, "and it RUNS while the workloads wait: "
  .. json.encode(control_ran or {}):sub(1, 300))
-- ...and a workload still is not, and a MODEL cannot mark itself as control.
local after_control = tools.dispatch(memory, "operation", { action = "start", command = long_command, timeout_seconds = 120, control = true }, "master", ctx_c) or {}
eq(after_control.operation_id, nil, "a model-supplied control flag does not make a workload a control call")
ok(tostring(after_control.error or ""):find("operation_capacity", 1, true) ~= nil,
  "and the refusal is a capacity one: " .. tostring(after_control.error))
for _, operation_id in ipairs(held_c) do
  tools.dispatch(memory, "operation", { action = "cancel", id = operation_id }, "master", ctx_c)
end
for _, operation_id in ipairs(held_d) do
  tools.dispatch(memory, "operation", { action = "cancel", id = operation_id }, "master", ctx_d)
end
if type(control_start.operation_id) == 'string' then
  decode(host.operation("cancel", json.encode({ id = control_start.operation_id, owner = "mcp-read-session" })))
end

-- ---- item 7: the node scope is a SURFACE's, not a role's -----------------------------------
--
-- Every session carries the operator's credential, so "operator role" was true of every model call: round
-- 1's grant let any tool call reach every other session's operations. A surface names itself in its own
-- ctx, which a model call cannot set, and the operator can mark one conversation mastermind.
local model_ask = tools.dispatch(memory, "operation", { action = "list", scope = "node" }, "master", ctx_a) or {}
eq(model_ask.error, "scope_node_forbidden", "a model call asking for the node scope is refused by name (item 7)")
ok(tostring(model_ask.note or ""):find("/mastermind", 1, true) ~= nil,
  "and the refusal says how to get it: " .. tostring(model_ask.note))
local marked, mark_why = memory.set_session_mastermind("iso-session-a", true, "master")
eq(marked, true, "the operator can mark a conversation mastermind: " .. tostring(mark_why))
local marked_ask = tools.dispatch(memory, "operation", { action = "list", scope = "node" }, "master", ctx_a) or {}
ok(marked_ask.error == nil and type(marked_ask.operations) == 'table',
  "and that conversation may hold the node scope: " .. tostring(marked_ask.error))
memory.set_session_mastermind("iso-session-a", false, "master")
local unmarked_ask = tools.dispatch(memory, "operation", { action = "list", scope = "node" }, "master", ctx_a) or {}
eq(unmarked_ask.error, "scope_node_forbidden", "unmarking takes it away again")
-- The surfaces the node itself owns keep the scope, and they say which one they are.
local fleet_grant = scope_lib.grant(memory, { scope = "node" }, { surface = "fleetview", session_id = "" }, "master", "", "fleetview")
ok(type(fleet_grant) == 'table' and fleet_grant.node == true and fleet_grant.surface == "fleetview",
  "Fleet View's own surface gets the node scope")
local window_grant = scope_lib.grant(memory, { scope = "node" }, { surface = "window", session_id = "" }, "master", "", "operation")
ok(type(window_grant) == 'table' and window_grant.node == true, "so does the window's operation route")
local bogus_grant, bogus_refusal = scope_lib.grant(memory, { scope = "node" }, { surface = "not-a-surface" }, "master", "", "operation")
ok(bogus_grant == nil, "an invented surface is not a surface")
eq(type(bogus_refusal) == 'table' and bogus_refusal.error, "scope_surface_unknown", "and it is refused by name")
-- The grant is audited, with the surface named: a node-wide read leaves a line an operator can find.
local audited = false
for _, row in ipairs(memory.journal_since(0, 2000)) do
  if row.kind == "session_scope" and tostring(row.payload and row.payload.surface or "") == "fleetview" then audited = true end
end
ok(audited, "the Fleet View grant is written to the journal with its surface")
-- The tool schema offers the scope, and the sentence says who may use it.
local operation_tool
local catalogue = tools.all('master') or {}
for _, item in ipairs(catalogue) do
  if type(item) == 'table' and item['function'] and item['function'].name == 'operation' then operation_tool = item['function'] end
end
ok(operation_tool ~= nil and operation_tool.parameters and operation_tool.parameters.properties
  and operation_tool.parameters.properties.scope ~= nil, "the operation tool's schema names the scope")
ok(operation_tool ~= nil and tostring(operation_tool.parameters.properties.scope.description or ""):find("mastermind", 1, true) ~= nil,
  "and says how a session gets it")

-- ---- item 8: a sessionless caller is not a node-wide caller --------------------------------
--
-- Round 1 answered "every operation that recorded no session is mine" to a sessionless caller: the same
-- node-wide answer, spelled with an empty session. It owns what it started, under its own owner.
local sessionless_op = decode(host.operation("start", json.encode({ command = command, timeout_seconds = 60,
  owner = "iso-owner-x" }))) or {}
ok(type(sessionless_op.operation_id) == 'string', "a sessionless start names its owner and is admitted")
local seen_x = decode(host.operation("list", json.encode({ owner = "iso-owner-x" }))) or {}
local seen_y = decode(host.operation("list", json.encode({ owner = "iso-owner-y" }))) or {}
local seen_none = decode(host.operation("list", json.encode({}))) or {}
eq(#(seen_x.operations or {}), 1, "it sees the work it started")
eq(#(seen_y.operations or {}), 0, "and none of another owner's")
-- A caller that names neither a session nor an owner is the node's own tooling in this process: it may
-- see the rows nobody named (its own foreground shells record worker:<n>), and never a session's.
ok(not listed(seen_none, id), "and no session's operations either, with no owner named")
for _, entry in ipairs(seen_none.operations or {}) do
  eq(tostring(entry.session or ""), "", "a row it does see recorded no session: " .. tostring(entry.operation_id))
end
if type(sessionless_op.operation_id) == 'string' then
  decode(host.operation("cancel", json.encode({ id = sessionless_op.operation_id, owner = "iso-owner-x" })))
end
-- Relevance for the whole node and reconciliation are the node scope's, for a sessionless caller too.
local star = decode(host.operation("relevant", json.encode({ cwd = "*" }))) or {}
eq(star.error, "relevant_node_scope_required", "relevant cwd:* needs the node scope, sessionless or not")
local rec = decode(host.operation("reconcile", json.encode({ id = "op-not-here", expected = "{}", evidence = "x" }))) or {}
eq(rec.error, "reconcile_node_scope_required", "reconcile needs it too, sessionless or not")
-- The /operation route takes its session from the authenticated request, never from the body.
dofile('lua/core/server.lua')
local route_named = decode(wa_operation(json.encode({ action = "list", session_id = "iso-session-a" }), "", "")) or {}
eq(#(route_named.operations or {}), 0, "a body that names another session does not reach it")
local route_none = decode(wa_operation(json.encode({ action = "list" }), "", "")) or {}
eq(#(route_none.operations or {}), 0, "a scope-less route call is a sessionless caller, and sees no session's work")
local route_node = decode(wa_operation(json.encode({ action = "list", scope = "node" }), "", "")) or {}
ok(type(route_node.operations) == 'table', "the window's own surface asks for the node scope and is answered")

-- ---- item 9: the deny rule is a shape, and the record says what was withheld ----------------
local item9_ready = canaries_ready({ "ISOLATION_TEST_TOKEN", "ISOLATION_TEST_SECRET", "ISOLATION_TEST_PASSWORD",
  "ANTHROPIC_AUTH_TOKEN", "GH_TOKEN" }, "ISOLATION_TEST_PLAIN")
if not item9_ready then
  print("SKIP item 9: this runner exported no canaries to withhold (scripts/test-session-isolation.sh does)")
end
if item9_ready then
local env_probe = tools.dispatch(memory, "bash", { command = "env" }, "master", ctx_a) or {}
local env_text = tostring(env_probe.stdout or "")
for _, name in ipairs({ "ISOLATION_TEST_TOKEN", "ISOLATION_TEST_SECRET", "ISOLATION_TEST_PASSWORD", "ANTHROPIC_AUTH_TOKEN" }) do
  if host.getenv(name) == nil then
    print("note: " .. name .. " was not exported by the runner; the deny-shape check cannot fail this way")
  end
  ok(not env_text:find(name .. "=", 1, true), "a bash child cannot see " .. name .. " (the deny shape)")
end
ok(env_text:find("ISOLATION_TEST_PLAIN=", 1, true) ~= nil,
  "and a name no rule matches still arrives (the control)")
local withheld_probe = tools.dispatch(memory, "operation", { action = "start", command = command, timeout_seconds = 60 }, "master", ctx_a) or {}
if type(withheld_probe.operation_id) == 'string' then
  local state9 = tools.dispatch(memory, "operation", { action = "status", id = withheld_probe.operation_id }, "master", ctx_a) or {}
  local names = state9.env_withheld or {}
  local named = false
  for _, entry in ipairs(type(names) == 'table' and names or {}) do if tostring(entry) == "GH_TOKEN" then named = true end end
  ok(named, "the operation record names GH_TOKEN as withheld: " .. json.encode(names))
  ok(tostring(state9.env_withheld_note or ""):find("tool_env_allow", 1, true) ~= nil,
    "and says where to allow it: " .. tostring(state9.env_withheld_note))
  tools.dispatch(memory, "operation", { action = "cancel", id = withheld_probe.operation_id }, "master", ctx_a)
end
end

-- ---- item 11: the peer path ------------------------------------------------------------------
--
-- A peer call needs a signed caller on the mesh and nothing on this node fabricates one, so the branch was
-- never exercised (round 1 said so). It is a named function now: called with a caller table it is the same
-- code a verified peer reaches, and what it must do is derive the peer's SESSION from the caller.
local peer_start = wa_peer_dispatch("operation", { action = "start", command = command, timeout_seconds = 60 },
  { node_id = "iso-peer-node", role = "master" }, "master")
ok(type(peer_start) == 'table', "a peer call dispatches: " .. json.encode(peer_start or {}):sub(1, 160))
if type(peer_start) == 'table' and type(peer_start.operation_id) == 'string' then
  local peer_state = tools.dispatch(memory, "operation", { action = "status", id = peer_start.operation_id },
    "master", { session_id = "peer:iso-peer-node", user_id = "master" }) or {}
  eq(peer_state.session, "peer:iso-peer-node", "the work a peer asks for belongs to that peer's own session")
  local forged = wa_peer_dispatch("operation", { action = "list", session_id = "iso-session-a" },
    { node_id = "iso-peer-node", role = "master" }, "master") or {}
  ok(not listed(forged, id), "a peer that names a session in its arguments cannot adopt it")
  tools.dispatch(memory, "operation", { action = "cancel", id = peer_start.operation_id }, "master",
    { session_id = "peer:iso-peer-node", user_id = "master" })
end
local peer_scope = wa_peer_dispatch("bash", { command = "echo hi", scope = "node" },
  { node_id = "iso-peer-node", role = "master" }, "master") or {}
eq(peer_scope.error, "peer_node_scope_not_granted", "a peer asking for the node scope is refused by name")

-- ---- item 1 round 4: the Fleet View's read is node-scoped AND audited -------------------------
--
-- Round 3 asked the node scope with a hard-coded role and a NIL memory module, then read `operations list`
-- with no node scope at all. Both failures were silent: session_scope.audit returns early without a store,
-- so a node-wide read left no line; and a sessionless list is not a node-wide list (item 7 round 2) - it
-- answers with the rows that named no owner, so the view printed a fraction of the node's work as the
-- node's. This drives the real reader against the real operation manager: a stub passed the round-3 code.
local fleetview = dofile('lua/core/fleetview.lua')
ok(type(fleetview.node_operations) == 'function', 'the Fleet View exposes its node-operations read')
local fv_ids = {}
for _, who in ipairs({ ctx_a, ctx_b }) do
  local started_one = tools.dispatch(memory, 'operation', { action = 'start', command = command, timeout_seconds = 60 },
    'master', who) or {}
  if type(started_one.operation_id) == 'string' then fv_ids[#fv_ids + 1] = started_one.operation_id end
end
ok(#fv_ids == 2, 'two sessions each started one operation for the Fleet View to see')
local function fleet_lists(operations, operation_id)
  for _, entry in ipairs(type(operations) == 'table' and (operations.operations or operations.list or {}) or {}) do
    if type(entry) == 'table' and entry.operation_id == operation_id then return true end
  end
  return false
end
-- Counted BEFORE the read and after it: an audit row from an earlier section of this script would let a
-- version that writes nothing pass this check (measured - the round-3 code passed it).
local function fleet_audit_rows()
  local count = 0
  for _, row in ipairs(memory.journal_since(0, 4000)) do
    if row.kind == 'session_scope' and tostring(row.payload and row.payload.surface or '') == 'fleetview' then
      count = count + 1
    end
  end
  return count
end
local fv_audit_before = fleet_audit_rows()
local seen, fv_refusal = fleetview.node_operations({ memory = memory, role = 'master', user_id = 'master', session = '' })
ok(type(seen) == 'table', 'the Fleet View reads the node operations: ' .. tostring(fv_refusal))
for index, operation_id in ipairs(fv_ids) do
  ok(fleet_lists(seen, operation_id), 'and it contains session ' .. (index == 1 and 'A' or 'B')
    .. ' operation, not only the caller\'s')
end
local refused, why_refused = fleetview.node_operations({ memory = memory, role = 'guest', user_id = 'master', session = '' })
ok(refused == nil, 'a non-operator caller gets no node operations at all')
eq(why_refused, 'node_scope_not_granted', 'and the reason is the grant, named')
local fv_audit_after = fleet_audit_rows()
ok(fv_audit_after > fv_audit_before, 'the Fleet View node-scope read wrote its own audit line with its '
  .. 'surface (' .. fv_audit_before .. ' -> ' .. fv_audit_after .. ')')
for _, operation_id in ipairs(fv_ids) do
  for _, who in ipairs({ ctx_a, ctx_b }) do
    tools.dispatch(memory, 'operation', { action = 'cancel', id = operation_id }, 'master', who)
  end
end

-- ---- item 2 round 4: session_watch observes the run it started, as its owner ----------------
--
-- `M.start` launches the run with owner = 'session:<id>'. The runtime decides ownership by exactly that
-- field for a caller that is not a session, so `status` and the read that followed had to name it. They
-- named only the id, the manager answered `operation_not_yours`, and `operation_state` turned that into
-- nil: the watcher said `unknown` about a run it had started and could see. Driven against the REAL
-- operation manager, not a stub.
local watch_lib = dofile('lua/core/session_watch.lua')
ok(type(watch_lib.watch) == 'function', 'session_watch is loadable for the ownership test')
local watch_session = 'iso-session-watch'
if not memory.session(watch_session) then
  memory.start_session('', 'isolation', { id = watch_session, user_id = 'master', node_id = '' })
end
local watch_run = decode(host.operation('start', json.encode({ command = command, timeout_seconds = 60,
  owner = 'session:' .. watch_session }))) or {}
ok(type(watch_run.operation_id) == 'string', 'a run owned by session:<id> was started: ' .. tostring(watch_run.error))
if type(watch_run.operation_id) == 'string' then
  host.sql_exec('INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    json.encode({ 'session.run.v1:' .. watch_session, json.encode({ operation_id = watch_run.operation_id,
      owner = 'session:' .. watch_session, program = 'test', cwd = '', started_at = host.now() }) }))
  local nameless = decode(host.operation('status', json.encode({ id = watch_run.operation_id })))
  ok(nameless ~= nil and nameless.error == 'operation_not_yours',
    'the same id with no owner is refused by name (what round 3 sent): ' .. tostring(nameless and nameless.error))
  local watched = watch_lib.watch({ session_id = watch_session, after = 0, wait_ms = 0 },
    { user_id = 'master', role = 'master' }) or {}
  local state = type(watched.state) == 'table' and watched.state or {}
  eq(state.state, 'running', 'the watcher sees the run it started as running, not unknown')
  eq(state.witness, 'operation', 'and names the operation manager as its witness')
  ok(type(state.operation) == 'table' and state.operation.id == watch_run.operation_id,
    'and reports the operation id it is watching')
  decode(host.operation('cancel', json.encode({ id = watch_run.operation_id, owner = 'session:' .. watch_session })))
  host.sql_exec('DELETE FROM meta WHERE key=?', json.encode({ 'session.run.v1:' .. watch_session }))
end

-- ---- item 4 round 4: only SHORT control calls take the reserved slots -------------------
--
-- The two reserved slots keep the node able to ask a short question while every workload slot is busy.
-- Round 3 marked the read-MCP session `control=true` and it lives 3600 s, so one connector could park the
-- whole reserve for an hour. The rule now has a bound, and a long start that asks is DEMOTED AND TOLD.
local short_control = decode(host.operation('start', json.encode({ command = 'echo short', timeout_seconds = 60,
  owner = 'iso-control-short', control = true }))) or {}
ok(type(short_control.operation_id) == 'string', 'a short control start is admitted: ' .. tostring(short_control.error))
ok(short_control.control_refused == nil, 'and no reserve was refused from it')
local long_control = decode(host.operation('start', json.encode({ command = 'echo long', timeout_seconds = 3600,
  owner = 'iso-control-long', control = true }))) or {}
ok(type(long_control.operation_id) == 'string', 'a 3600 s start is admitted: ' .. tostring(long_control.error))
ok(tostring(long_control.control_refused or ''):find('reserved slots', 1, true) ~= nil,
  'but it is TOLD it is a workload, not a control call: ' .. tostring(long_control.control_refused))
for _, started in ipairs({ short_control, long_control }) do
  if type(started.operation_id) == 'string' then
    pcall(host.operation, 'cancel', json.encode({ id = started.operation_id,
      owner = started == short_control and 'iso-control-short' or 'iso-control-long' }))
  end
end
-- The read-MCP session no longer asks for the reserve at all: it is a workload with its own share.
local lua_root = tostring(host.getenv('WASM_AGENT_LUA_ROOT') or '')
local session_source = lua_root ~= '' and (host.read_file(lua_root .. '/lua/core/mcp_session.lua') or '') or ''
-- The LAUNCH LINE, not the prose: it must carry no `control=` field at all. (The comment above it
-- explains the old rule and names the field, which is why this reads the line, not the file.)
local launch_line = ''
for line in tostring(session_source):gmatch('[^\n]+') do
  if line:find("host.operation('start'", 1, true) then launch_line = line end
end
ok(launch_line ~= '' and not launch_line:find('control=', 1, true),
  'the read-MCP session launch claims no reserved slot: ' .. launch_line:sub(1, 120))

-- ---- item 6 round 4: /health takes the session from the CREDENTIAL, not the query ---------
--
-- The route used to answer `?session_id=<anything>` with that session's operations, so the query string
-- was an identity. `wa_health_scope` decides from the request's own credential: a session it may see, its
-- own owner's work, or - with no credential at all - the node supervisor's view the sentinel polls.
local users_lib = dofile('lua/core/users.lua')
local credential = users_lib.login('master') or ''
ok(credential ~= '', 'a credential was minted for this test')
local function scope_of(caller_credential, requested)
  return decode(wa_health_scope(caller_credential, requested)) or {}
end
-- The sentinel's poll: no credential, no session named, the whole node.
local sentinel_scope = scope_of('', '')
eq(sentinel_scope.node_wide, true, 'with no credential at all the answer is the node supervisor\'s view')
-- An authenticated caller naming NO session gets its OWN view, never the node's.
local own_scope = scope_of(credential, '')
eq(own_scope.node_wide, false, 'an authenticated caller with no session named is not node-wide')
ok(tostring(own_scope.owner or '') ~= '', 'and is scoped to its own owner')
-- A session the credential may see is answered; one it may not is REFUSED BY NAME, never served empty.
local visible = scope_of(credential, 'iso-session-a')
eq(visible.session, 'iso-session-a', 'the credential may read a conversation it owns')
local unknown = scope_of(credential, 'no-such-conversation')
eq(unknown.refused, 'health_unknown_session', 'an id that names nothing is refused by name')
local bogus = scope_of('not-a-real-credential', '')
eq(bogus.refused, 'health_credential_unresolved', 'a credential that does not resolve is nobody, and refused')

print(string.format("%d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end