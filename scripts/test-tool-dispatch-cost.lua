-- A TOOL DISPATCH DOES NOT BUILD WHAT IT NEVER READS, NOR RECOMPILE WHAT IT ALREADY LOADED.
--
-- Brief (23/11): the remote round trip's peer half was 6 tools.dispatch calls at ~35 ms each, and the
-- measuring showed where those 35 ms went - not into the tool, into the dispatcher:
--   * `M.all(role, ctx, memory)` rebuilt every tool schema (11-18 ms) on EVERY dispatch, including an
--     `operation await` and a model's `bash`, neither of which reads the catalogue;
--   * `dofile('lua/core/orchestration_mode.lua')` re-read and re-compiled that module - whose own header
--     loads json, memory, users and the 1,969-line nodes.lua - on every dispatch (9 ms).
--
-- This row pins both, and pins that the catalogue is still SERVED where it is read:
--   * the first two dispatches of this process load orchestration_mode ONCE between them;
--   * an `operation` dispatch asks for no catalogue at all;
--   * `capabilities` still gets a full one (laziness, not removal).
--
-- Hermetic: a scratch home, no network, no live node.
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

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

local sid = memory.start_session("", "dispatch cost", { user_id = "master" })
local ctx = { session_id = sid, user_id = "master" }

-- 1. ORCHESTRATION MODE IS COMPILED ONCE PER PROCESS, NOT ONCE PER DISPATCH. `dofile` is a global the
--    dispatcher looks up at each call, so counting it here counts the loads. Wrapped BEFORE any dispatch,
--    so the first one is included.
local real_dofile = dofile
local orchestration_loads = 0
_G.dofile = function(path, ...)
  if tostring(path) == "lua/core/orchestration_mode.lua" then orchestration_loads = orchestration_loads + 1 end
  return real_dofile(path, ...)
end
local started = tools.dispatch(memory, "operation", { action = "start", command = "printf dc-ok",
  background = true, timeout_seconds = 30 }, "master", ctx) or {}
local id = tostring(started.operation_id or "")
check(id ~= "", "the operation started, so the dispatch really ran: " .. json.encode(started):sub(0, 200))
tools.dispatch(memory, "operation", { action = "await", id = id, wait_ms = 5000 }, "master", ctx)
_G.dofile = real_dofile
check(orchestration_loads == 1,
  "two dispatches load orchestration_mode once, loaded " .. orchestration_loads)

-- 2. THE CATALOGUE IS NOT BUILT FOR A DISPATCH THAT NEVER READS IT. `M.all` is looked up on the module
--    table at the moment it is needed, so counting the field counts the fetch.
local real_all = tools.all
local all_calls = 0
tools.all = function(...)
  all_calls = all_calls + 1
  return real_all(...)
end
local second = tools.dispatch(memory, "operation", { action = "start", command = "printf dc-ok2",
  background = true, timeout_seconds = 30 }, "master", ctx) or {}
local id2 = tostring(second.operation_id or "")
check(id2 ~= "", "a second operation started: " .. json.encode(second):sub(0, 200))
check(all_calls == 0, "an operation dispatch built no tool catalogue, built " .. all_calls)
tools.dispatch(memory, "operation", { action = "await", id = id2, wait_ms = 5000 }, "master", ctx)
check(all_calls == 0, "and neither did the await, built " .. all_calls)
tools.dispatch(memory, "bash", { command = "printf dc-ok" }, "master", ctx)
check(all_calls == 0, "and neither did a bash call, built " .. all_calls)

-- 3. AND IT IS STILL SERVED WHERE IT IS READ. `capabilities` answers the permitted catalogue, which it
--    can only do from a real one.
local caps = tools.dispatch(memory, "capabilities", {}, "master", ctx) or {}
check(all_calls > 0, "a capabilities dispatch asks for the catalogue, built " .. all_calls)
check(type(caps.capabilities) == "table" and #caps.capabilities > 10,
  "and answers the permitted tool list, got " .. tostring(type(caps.capabilities)) .. " "
    .. tostring(type(caps.capabilities) == "table" and #caps.capabilities or "?"))
local found = false
for _, name in ipairs(caps.capabilities or {}) do if name == "bash" then found = true end end
check(found, "with the real names in it (bash among them)")
tools.all = real_all
tools.dispatch(memory, "operation", { action = "cancel", id = id2 }, "master", ctx)
print("tool dispatch cost ok (" .. checks .. " checks)")
