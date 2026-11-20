-- Items 2 and 3 of the harness-fixes mission (19/11): a turn that ends releases its run lease, and
-- the operations it started stay the SESSION's - visible, and awaitable by id, from the resumed turn.
--
-- Measured 19/11, rel-native 22:53Z: \`wa chat --resume\` answered \`run_resource_refused resource_busy\`
-- because a failed turn's still-running operation kept the session lease. And separately: an operation's
-- result was lost when the session that started it detached.
--
-- What this pins, through the real host (lua/core/resources.lua + the rust claim store + the operation
-- manager), never a fake:
--   1. a turn starts a supervised operation that outlives it, then ends (finish releases the RUN lease);
--   2. the next run of the SAME session is admitted - no resource_busy, no killed process;
--   3. that operation is still listed for the session, so the resumed turn sees what it left running;
--   4. it can be awaited by id and answers its real result (its own stdout), not "lost".
--
-- Run from the repo root, on a SCRATCH node only:
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-operation-survives-turn.lua \
--     wa --db <scratch>/t.db
local json = dofile('lua/vendor/json.lua')
local platform = dofile('lua/core/platform.lua')
local tools = dofile('lua/core/tools.lua')
local memory = dofile('lua/core/memory.lua')
local resources = dofile('lua/core/resources.lua')

-- ---- this script refuses to run anywhere but a scratch node ---------------------------------
-- It starts a supervised process and writes claims. On the real node that is the operator's own ledger.
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\]+$", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

memory.setup()

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL operation-survives-turn: " .. label)
  end
end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then
    failed = failed + 1
    print(string.format("FAIL operation-survives-turn: %s (got %s, want %s)", label,
      tostring(got), tostring(want)))
  end
end

local user = "operation-survives-turn"
local session = "survives-session"
if not memory.session(session) then
  memory.start_session("", "survives", { id = session, user_id = user, node_id = "" })
end

-- The shell that outlives its turn. It prints a marker, then stays alive long enough for the resumed run
-- to find it running; its output goes to the shell's null device on Windows via the platform shell.
local shell = tostring(platform.shell() or ""):lower()
local command = shell:find("cmd", 1, true) and "echo survived-turn-marker && ping -n 5 127.0.0.1 >NUL"
  or "echo survived-turn-marker; sleep 4 >/dev/null 2>&1"

-- ---- run 1: start the operation, then end the turn -----------------------------------------
local run1 = { session_id = session, user_id = user, run_id = host.uuid() }
local ctx1 = { session_id = session, user_id = user, run_id = run1.run_id }
local claimed = resources.begin(ctx1)
eq(claimed.ok, true, "run 1 is admitted")

local started = tools.dispatch(memory, "operation", { action = "start", command = command, timeout_seconds = 60 },
  "master", ctx1)
ok(type(started) == 'table' and type(started.operation_id) == 'string', "run 1 started a supervised operation")
local id = type(started) == 'table' and started.operation_id or nil
if not id then
  print(string.format("ok operation-survives-turn: %d checks, %d failed", checks, failed))
  os.exit(1)
end
-- The launch receipt does not echo the session; the operation's own record does. Read it back.
local owned = tools.dispatch(memory, "operation", { action = "status", id = id }, "master", ctx1)
eq(type(owned) == 'table' and owned.session, session,
  "the operation records the SESSION that asked, not only the run")

-- The turn ENDS while its operation is still running. finish is the unconditional release on every exit
-- path (a failed turn and an answered one take the same line).
local released = resources.finish(ctx1)
eq(released.ok, true, "the ended turn released its run claim")

-- ---- run 2: the resume ----------------------------------------------------------------------
local ctx2 = { session_id = session, user_id = user, run_id = host.uuid() }
local resumed = resources.begin(ctx2)
eq(resumed.ok, true, "the resumed run is admitted while that operation still runs (no resource_busy)")
if resumed.ok ~= true then
  print("  refusal: " .. tostring(json.encode(resumed)))
end

-- The resumed turn can SEE what it left running. A list answers the session's own operations.
local listed = tools.dispatch(memory, "operation", { action = "list" }, "master", ctx2)
local items = type(listed) == 'table' and (listed.operations or listed) or {}
local seen = false
if type(items) == 'table' then
  for _, entry in pairs(items) do
    if type(entry) == 'table' and entry.operation_id == id then seen = true end
  end
end
ok(seen, "the resumed run lists the operation its session left running")

-- And it can AWAIT it by id. The result survives the detach: the answer is the operation's own state,
-- with its own bytes, not an "owner not attached" and not a lost id.
local awaited = tools.dispatch(memory, "operation", { action = "await", id = id, wait_for = "settled" },
  "master", ctx2)
ok(type(awaited) == 'table', "await answered a record")
eq(type(awaited) == 'table' and awaited.operation_id, id, "the answer is that operation")
ok(type(awaited) == 'table' and awaited.error ~= "operation_not_yours",
  "the same session's resumed run may await it (it is the session's, not the dead run's)")
ok(type(awaited) == 'table' and awaited.settled ~= false, "the awaited operation settled")

-- The result itself: its own stdout, read back through the operation, carrying the marker the command
-- printed. That is the "the result survives" half of item 3.
local page = tools.dispatch(memory, "operation",
  { action = "read", id = id, stream = "stdout", offset = 0, limit = 4096 }, "master", ctx2)
local text = type(page) == 'table' and tostring(page.content or "") or ""
ok(text:find("survived-turn-marker", 1, true) ~= nil,
  "the operation's own output is readable after the turn that started it ended (got: " .. text:sub(1, 120) .. ")")

-- Nothing is left holding the session: a third run is admitted too, and it holds the claim itself.
eq(resources.finish(ctx2).ok, true, "the resumed run releases its own claim")

-- A DIFFERENT session still may not reach it. The ownership is the session's, not revoked by the resume.
local ctx3 = { session_id = "survives-session-other", user_id = user, run_id = host.uuid() }
if not memory.session("survives-session-other") then
  memory.start_session("", "survives", { id = "survives-session-other", user_id = user, node_id = "" })
end
resources.begin(ctx3)
local foreign = tools.dispatch(memory, "operation", { action = "status", id = id }, "master", ctx3)
eq(type(foreign) == 'table' and foreign.error, "operation_not_yours",
  "another session still may not read it")
resources.finish(ctx3)

-- ---- the shape that was actually measured (19/11 22:53Z): a FAILED turn -------------------
-- The resume was refused because the failed turn's lease was still held. The turn fails here the way it
-- did then - the provider stalls - while a supervised operation it started is still running, and the
-- next run of the same session must still be admitted.
local agentlib = dofile('lua/core/agent.lua')
local real_getenv = host.getenv
host.getenv = function(key)
if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
if key == 'WASM_AGENT_PROVIDER_RETRIES' then return '0' end
if key == 'WASM_AGENT_PROVIDER_RESPONSE_TIMEOUT_RETRIES' then return '0' end
return real_getenv(key)
end
local real_sleep = host.sleep
host.sleep = function() end

local failed_session = "survives-session-failed"
if not memory.session(failed_session) then
memory.start_session("", "survives", { id = failed_session, user_id = user, node_id = "" })
end
-- The operation this turn starts OUTLIVES the turn: the shell first announces a slower command that is
-- still running when the provider stalls below.
local long_command = shell:find("cmd", 1, true)
and "echo failed-turn-marker && ping -n 8 127.0.0.1 >NUL"
or "echo failed-turn-marker; sleep 6 >/dev/null 2>&1"
local turn = agentlib.new(failed_session, function() end, "master", user, "local")
turn.stream = true
local tool_rounds = 0
host.http_stream = function()
tool_rounds = tool_rounds + 1
if tool_rounds == 1 then
  -- The turn's one action: start the long operation. Then the provider stalls and the turn fails.
  return json.encode({ status = 200, content = "", finish_reason = "tool_calls",
    tool_calls = { { id = "c1", type = "function",
      ["function"] = { name = "operation", arguments = json.encode({ action = "start",
        command = long_command, timeout_seconds = 60 }) } } } })
end
return json.encode({ error = "timeout: receive response (provider_stalled: no response within 90s)" })
end
local turn_ok = pcall(turn.run, turn, "start that and then stall")
host.sleep = real_sleep
host.getenv = real_getenv
ok(not turn_ok, "the turn fails on the stalled provider")

local probe2 = { session_id = failed_session, user_id = user, run_id = host.uuid() }
local admitted = resources.begin(probe2)
eq(admitted.ok, true, "a failed turn's lease does not keep the session: the next run is admitted")
if admitted.ok ~= true then
  print("  refusal: " .. tostring(json.encode(admitted)))
end
eq(resources.finish(probe2).ok, true, "and the next run releases its own claim too")

print(string.format("ok operation-survives-turn: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
