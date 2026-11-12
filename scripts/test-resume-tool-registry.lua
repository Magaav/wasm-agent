-- A resumed run has the same tools as a fresh one, and a run with none refuses by name (11/11).
--
-- Evidence, gate.log tail: after the empty-name incident the resumed run dispatched nothing for the
-- rest of the night - bash, codemode, time and tool_call all answered `plugin_not_found:`. The empty
-- name was the trigger (change/tool-call-empty-name), and the measured registry was NOT empty: this row
-- proves the parity half against the real catalogue, so a resumed thread can never quietly come back
-- with a different (or absent) loadout and look like the same bug again.
--
-- The second half is the refusal. A tool list is frozen with the session's prompt prefix
-- (lua/core/prompt_cache.lua), so ONE turn that resolved no tools freezes "no tools" for that thread,
-- and every later `--resume` of it is a run that cannot dispatch anything: the model asks, the harness
-- answers plugin_not_found, the reader sees a dead agent. Built here through the real freeze path
-- (`prompt_cache.enforce` with an empty list), so the record under test is the record a bad first turn
-- would have written.
--
-- Run: WA_SCRIPT=scripts/test-resume-tool-registry.lua wa --db /tmp/wa-resume-tools.db
local env = {}
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return "test-only" end
  if key == "WASM_AGENT_VAULT_URL" or key == "WASM_AGENT_VAULT_DIR"
      or key == "WASM_AGENT_VAULT_KEYSTORE" or key == "WASM_AGENT_VAULT_PASSPHRASE" then return nil end
  if env[key] ~= nil then return env[key] end
  return real_getenv(key)
end
host.sleep = function() end
host.http = function() error("network forbidden") end

local json = dofile("lua/vendor/json.lua")
local agentlib = dofile("lua/core/agent.lua")
local memory = dofile("lua/core/memory.lua")
local prompt_cache = dofile("lua/core/prompt_cache.lua")
local tools = dofile("lua/core/tools.lua")
memory.setup()

local checks = 0
local function check(cond, what) checks = checks + 1; if not cond then error(what, 2) end end

local bodies = {}
host.http_stream = function(...)
  local body = ""
  for _, value in ipairs({ ... }) do
    if type(value) == "string" and value:sub(1, 1) == "{" then
      local ok_decode, decoded = pcall(json.decode, value)
      if ok_decode and type(decoded) == "table" and decoded.messages then body = value break end
    end
  end
  bodies[#bodies + 1] = body
  return json.encode({ status = 200, content = "answered", finish_reason = "stop", tool_calls = {} })
end
local function session(title)
  return memory.start_session("", "chat", { user_id = "master", node_id = "", title = title })
end
local function fresh_agent(session_id, title)
  local sid = session_id or session(title)
  local agent = agentlib.new(sid, function() end, "master", "master", "")
  agent.stream = true
  return agent, sid
end
local function names(list)
  local set = {}
  for _, item in ipairs(list or {}) do set[tostring((item["function"] or {}).name)] = true end
  local out = {}
  for name in pairs(set) do out[#out + 1] = name end
  table.sort(out)
  return out
end

-- --------------------------------------------------------------- 1. a resumed run's loadout
-- Through the request bodies, because that is the registry the model is offered: `tools` is what it
-- may call, and the tool list in the harness must be the same set. A session is run once in this
-- build (which pins its envelope mode and freezes its prefix), then resumed, and the second request
-- must offer exactly what the first did.
local first, first_id = fresh_agent(nil, "a thread that will be resumed")
local first_answer = first:run("check the tree")
check(tostring(first_answer):find("answered", 1, true) ~= nil, "the first turn answers: " .. tostring(first_answer))
local first_names = names(json.decode(bodies[1] or "{}").tools)
check(#first_names > 0, "a fresh run offers tools at all (this node's catalogue)")

bodies = {}
local resumed, resumed_sid = fresh_agent(first_id, "a thread that will be resumed")
check(resumed_sid == first_id, "the resumed agent continues the same thread")
local resumed_answer = resumed:run("carry on")
check(tostring(resumed_answer):find("answered", 1, true) ~= nil, "the resumed turn answers: " .. tostring(resumed_answer))
local resumed_names = names(json.decode(bodies[1] or "{}").tools)
check(#resumed_names == #first_names and table.concat(resumed_names, ",") == table.concat(first_names, ","),
  "a resumed run is offered exactly the tools a fresh run was\n  fresh:   " .. table.concat(first_names, ",")
    .. "\n  resumed: " .. table.concat(resumed_names, ","))
local catalog = names(tools.all("master"))
for _, name in ipairs(resumed_names) do
  local found = false
  for _, offered in ipairs(catalog) do if offered == name then found = true break end end
  check(found, "every tool the resumed run offers is in the catalogue dispatch reads: " .. name)
end

-- The legacy rule stays as designed: a conversation that predates the envelope key keeps its original
-- surface (lua/core/envelope.lua, "existing conversations retain their original surface"), so a thread
-- with history and no recorded mode is offered the full catalogue - and never nothing.
local legacy_id = session("a conversation older than this build")
memory.append_turn(legacy_id, { role = "user", content = "check the tree" })
memory.append_turn(legacy_id, { role = "assistant", content = "it is clean" })
bodies = {}
local legacy, _ = fresh_agent(legacy_id)
legacy:build_context()
local legacy_names = names(legacy.tool_list)
check(#legacy_names > 0, "a conversation with history is offered its full catalogue, not an empty list")
for _, name in ipairs(legacy_names) do
  local found = false
  for _, offered in ipairs(catalog) do if offered == name then found = true break end end
  check(found, "every tool offered to a legacy conversation is dispatchable: " .. name)
end

-- --------------------------------------------------------------- 2. a run with zero tools refuses
-- The freeze path, exactly as a first turn that resolved nothing would have written it.
local bricked_id = session("frozen with no tools")
local frozen = prompt_cache.enforce({ session_id = bricked_id, user_id = "master", role = "master" },
  { system = "a prompt frozen by a turn that resolved no tools", tools = {} })
check(type(frozen) == "table" and type(frozen.tools) == "table" and #frozen.tools == 0,
  "the frozen prefix holds an empty tool list (the record this row is about)")

bodies = {}
local bricked, _ = fresh_agent(bricked_id)
bricked:build_context()
check(#(bricked.tool_list or {}) == 0, "the resumed run resolves the frozen empty list, as a resumed run would")

bodies = {}
local ok, reply = pcall(bricked.run, bricked, "are you there?")
check(ok, "the refusal is a named outcome, not a crash: " .. tostring(reply))
check(tostring(reply):find("no_dispatchable_tools", 1, true) ~= nil,
  "a run with zero dispatchable tools refuses by name: " .. tostring(reply):sub(1, 200))
check(tostring(reply):find("frozen", 1, true) ~= nil,
  "the refusal names why the list is empty: " .. tostring(reply):sub(1, 300))
check(#bodies == 0, "nothing is sent to the provider for a run that cannot dispatch: " .. tostring(#bodies) .. " request(s)")
local state = memory.session_state(bricked_id) or {}
check(state.state == "failed", "the refused run is recorded as failed, not as an answer: " .. tostring(state.state))
local rows = memory.session_messages(bricked_id, { all = true }) or {}
local last = rows[#rows] or {}
check(last.role == "assistant" and tostring(last.content):find("no_dispatchable_tools", 1, true) ~= nil,
  "the refusal is in the transcript, so it can be read after the fact")

-- A child whose profile names no tool is NOT refused. Its loadout is its own profile's decision, and a
-- call it should not make is answered `capability_not_in_profile` - corrective, not the dead end this
-- row is about. Measured while building this: a blanket refusal also refused the tool-less child that
-- `scripts/test-provider-connection-abort-recovery.lua` runs, and that row failed by name.
bodies = {}
local child_sid = session("a child with no tools by design")
local child = agentlib.new(child_sid, function() end, "master", "master", "", { subagent = { limits = {} } })
child.stream = true
local child_ok, child_reply = pcall(child.run, child, "answer without tools")
check(child_ok, "a tool-less child run is not refused: " .. tostring(child_reply))
check(not tostring(child_reply):find("no_dispatchable_tools", 1, true), "and it is not the refusal")
check(#bodies == 1, "it reaches the provider, got " .. tostring(#bodies) .. " request(s)")

-- A healthy thread is untouched by the guard: the same run shape answers normally.
bodies = {}
local healthy, healthy_id = fresh_agent(nil, "a healthy thread")
local answered = healthy:run("is your registry there?")
check(tostring(answered):find("answered", 1, true) ~= nil, "a run with tools still runs: " .. tostring(answered))
check(#bodies == 1, "exactly one request for one answered turn, got " .. tostring(#bodies))
check((memory.session_state(healthy_id) or {}).state == "answered", "the healthy thread settles as answered")

print(string.format("resume tool registry: %d checks", checks))
