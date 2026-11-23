-- A PEER BASH CALL PAYS FOR THE WORK, NOT FOR SIX BOOKKEEPING DISPATCHES.
--
-- Brief (23/11, measured on scratch nodes): one signed peer call carrying 'printf ok' took ~210-460 ms,
-- and the peer's own side of it was 6 tools.dispatch calls - reap (operation list), start, await, status
-- and two reads - at ~35 ms each (the dispatcher's guards plus a full schema catalogue rebuilt per call).
-- Two of those six repeated work the call already held:
--   * the reap's `operation list` is only ever intersected with THIS peer session's adopted ids, so with
--     none recorded there is nothing to reap;
--   * the settled record was read TWICE - once by `await`, once by a `status` the answer already was.
--
-- This row pins the bound and the two promises the cut must not break:
--   * a short peer bash costs at most FOUR host.operation calls (start, await, read, read);
--   * its answer carries what the local synchronous bash answers (code, ok, stdout, stderr);
--   * the moment a handle IS adopted, the housekeeping is back: the next short call performs the reap's
--     `list` again - laziness must not have disabled the rule, only its idle cost.
--
-- Hermetic: two scratch node halves in one process, no network, no live node. The peer half is the real
-- wa_peer_dispatch this node runs for a verified peer.
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\]+$", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own "
      .. "~/.wasm-agent (got " .. tostring(home) .. ")")
    os.exit(2)
  end
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")
dofile("lua/core/server.lua")

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

local peer_caller = { node_id = "rcb-scratch-peer", role = "master" }
local peer_ctx = { session_id = "peer:rcb-scratch-peer", user_id = "master" }
local sid = memory.start_session("", "remote call bound", { user_id = "master" })
local caller_ctx = { session_id = sid, user_id = "master" }

-- COUNT the host.operation calls a peer bash makes. `host.operation` is the one door every operation
-- action goes through (tools.lua calls it by name on the host table), so the count is the peer's own.
local real_operation = host.operation
local seen = {}
host.operation = function(action, body)
  seen[#seen + 1] = tostring(action)
  return real_operation(action, body)
end
local function counted_peer_bash(command, budget_ms)
  seen = {}
  local answer = wa_peer_dispatch("bash", { command = command, budget_ms = budget_ms },
    peer_caller, "master")
  return answer, seen
end

-- 1. A short command that fits the budget: the bound is FOUR.
local answer, calls = counted_peer_bash("printf rcb-ok", 30000)
check(type(answer) == "table", "the peer answered something")
check(answer.error == nil, "the short peer bash succeeded: " .. json.encode(answer):sub(1, 240))
check(tonumber(answer.code) == 0, "and its exit code is the command's, got " .. tostring(answer.code))
check(answer.stdout == "rcb-ok", "and it carries the command's output, got " .. tostring(answer.stdout))
check(#calls <= 4, "a short peer bash costs at most 4 host.operation calls, got " .. #calls
  .. ": " .. table.concat(calls, ","))
check(#calls >= 3, "and it still starts, waits for and reads the command, got " .. #calls
  .. ": " .. table.concat(calls, ","))

-- 2. Parity with the LOCAL synchronous bash: the adopted path promises "its own result, exactly as the
--    synchronous path did", so every field the local answer carries for this command is here too.
local local_answer = tools.dispatch(memory, "bash", { command = "printf rcb-ok" }, "master", caller_ctx) or {}
check(type(local_answer) == "table" and local_answer.error == nil, "the local bash ran for comparison")
for _, key in ipairs({ "code", "ok", "stdout", "stderr" }) do
  check(answer[key] ~= nil, "the peer answer carries '" .. key .. "' like the local one")
  check(tostring(answer[key]) == tostring(local_answer[key]),
    "and '" .. key .. "' agrees with the local answer: " .. tostring(answer[key]) .. " vs " .. tostring(local_answer[key]))
end

-- 3. A second short call in the same peer session is bounded the same way: the saving is not a first-call
--    effect, and nothing grows per call.
local again, calls2 = counted_peer_bash("printf rcb-again", 30000)
check(again.stdout == "rcb-again", "the second peer bash answered its own output")
check(#calls2 <= 4, "the second short peer bash also costs at most 4, got " .. #calls2
  .. ": " .. table.concat(calls2, ","))

-- 4. THE HOUSEKEEPING IS NOT DISABLED. A command that outlives its budget is ADOPTED; from then on the
--    adopted index is not empty, so the next short call must run the reap's list again (that is what
--    stops an outlived command that is still running). Five calls, and 'list' among them.
local adopted = wa_peer_dispatch("bash", { command = "sleep 3; printf rcb-slow", budget_ms = 1000 },
  peer_caller, "master")
check(type(adopted) == "table" and adopted.state == "pending",
  "a command past its budget answers a handle: " .. json.encode(adopted):sub(0, 200))
local short, calls3 = counted_peer_bash("printf rcb-after", 30000)
check(short.stdout == "rcb-after", "the call after an adoption answers its own output")
check(#calls3 > 4, "with a handle open the reap asks the node what is running, got " .. #calls3
  .. ": " .. table.concat(calls3, ","))
local listed = false
for _, action in ipairs(calls3) do if action == "list" then listed = true end end
check(listed, "and the reap's own list is the call it makes: " .. table.concat(calls3, ","))
-- Stop the adopted command so this row leaves nothing running behind it.
tools.dispatch(memory, "operation", { action = "cancel", id = adopted.op or adopted.operation_id }, "master", peer_ctx)

host.operation = real_operation
print("remote call bound ok (" .. checks .. " checks)")
