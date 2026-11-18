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
--   * the one way past it: `scope:"node"`, the operator role's alone, which is audited.
local json = dofile('lua/vendor/json.lua')
local platform = dofile('lua/core/platform.lua')
local tp = dofile('lua/core/tool_progress.lua')
local tools = dofile('lua/core/tools.lua')
local memory = dofile('lua/core/memory.lua')
local scope_lib = dofile('lua/core/session_scope.lua')
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
local node_view = tools.dispatch(memory, "operation", { action = "status", id = id, scope = "node" }, "master", ctx_b) or {}
eq(node_view.operation_id, id, "an explicit node scope reaches another session's operation")
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

print(string.format("%d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end