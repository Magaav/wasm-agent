-- A model tool call with no name must not brick the thread (11/11).
--
-- Measured, gate.log session 50f2c555: a step emitted a call whose `function.name` was empty. Dispatch
-- answered it `plugin_not_found:` (there was no name to look up), the assistant message was stored
-- exactly as it arrived, and EVERY later request of that session was rejected
-- `provider_http_400 ... [invalid_parameter]` - an OpenAI-compatible API refuses a function name that is
-- empty, so one wrong call made the thread unusable and ended the run. A resumed session then kept
-- imitating its own unusable call shape, and every dispatch came back `plugin_not_found:` again.
--
-- What this row asserts, through the real request/parse path (host.http_stream), not a mock of it:
--   1. the run survives a call with no name: it is answered with a tool error the model can act on,
--      and nothing runs (the arguments are echoed, never executed);
--   2. the request the provider receives next is VALID: every assistant tool_call has a non-empty id
--      and a legal name, every tool result answers a declared id, and every tool result has a name;
--   3. a session already bricked by an older binary (rows stored with an empty name) is replayed
--      validly - the repair is in the provider view, so `--resume` fixes the thread instead of
--      inheriting the 400.
--
-- Run: WA_SCRIPT=scripts/test-tool-call-name.lua wa --db /tmp/wa-tool-call-name.db
local env = {}
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return "test-only" end
  -- The vault route is the operator's: a fixture must never be answered by it (11/11, speed.log).
  if key == "WASM_AGENT_VAULT_URL" or key == "WASM_AGENT_VAULT_DIR"
      or key == "WASM_AGENT_VAULT_KEYSTORE" or key == "WASM_AGENT_VAULT_PASSPHRASE" then return nil end
  if env[key] ~= nil then return env[key] end
  return real_getenv(key)
end
host.sleep = function() end
host.http = function() error("network forbidden") end

local json = dofile("lua/vendor/json.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()

local checks = 0
local function check(cond, what) checks = checks + 1; if not cond then error(what, 2) end end

-- The API's own rule, spelled here so this row fails for the measured reason on a tree that has no
-- repair at all: `^[a-zA-Z0-9_-]{1,64}$`. The fix must agree with it (`provider.call_name_valid`).
local function legal_name(name)
  return type(name) == "string" and #name > 0 and #name <= 64 and name:match("^[%w_%-]+$") ~= nil
end

-- ------------------------------------------------------------------ the API's own rule
-- Not a paraphrase: this is the rule the upstream gateway enforced as `[invalid_parameter]` on the
-- measured session. A request that breaks it is the 400, so the row asserts the real contract and not
-- a shape it invented here.
local function request_problem(body)
  local declared = {}
  for index, message in ipairs(body.messages or {}) do
    if message.role == "assistant" then
      for _, call in ipairs(message.tool_calls or {}) do
        local function_ = type(call["function"]) == "table" and call["function"] or {}
        if type(call.id) ~= "string" or call.id == "" then
          return string.format("message %d: assistant tool_call with no id", index)
        end
        if not legal_name(function_.name) then
          return string.format("message %d: assistant tool_call %s has an illegal name (%q)",
            index, tostring(call.id), tostring(function_.name))
        end
        if type(function_.arguments) ~= "string" then
          return string.format("message %d: assistant tool_call %s has no argument string",
            index, tostring(call.id))
        end
        declared[tostring(call.id)] = true
      end
    elseif message.role == "tool" then
      if type(message.tool_call_id) ~= "string" or message.tool_call_id == "" then
        return string.format("message %d: tool result with no tool_call_id", index)
      end
      if not declared[tostring(message.tool_call_id)] then
        return string.format("message %d: tool result %s answers no declared call",
          index, tostring(message.tool_call_id))
      end
      if not legal_name(message.name) then
        return string.format("message %d: tool result %s has an illegal name (%q)",
          index, tostring(message.tool_call_id), tostring(message.name))
      end
    end
  end
  return nil
end

local function exists(path)
  local ok_read, content = pcall(host.read_file, path)
  return ok_read and type(content) == "string"
end

-- ------------------------------------------------------------------ a live run
local bodies, script = {}, {}
host.http_stream = function(...)
  -- The request body is one of the string arguments (method, url, headers, body, options); keep the
  -- object that carries `messages`, so every assertion below reads the exact bytes the provider sees.
  local body = ""
  for _, value in ipairs({ ... }) do
    if type(value) == "string" and value:sub(1, 1) == "{" then
      local ok_decode, decoded = pcall(json.decode, value)
      if ok_decode and type(decoded) == "table" and decoded.messages then body = value break end
    end
  end
  bodies[#bodies + 1] = body
  local answer = table.remove(script, 1) or { status = 200, content = "done", finish_reason = "stop", tool_calls = {} }
  return json.encode(answer)
end

local session_id = memory.ensure_session("tool-call-name", "local", "a call with no name")
local agent = agentlib.new(session_id, function() end, "master", "tool-call-name", "local")
agent.stream = true
local marker = "/tmp/wa-tool-call-name-marker-" .. tostring(math.random(1e9))

bodies, script = {}, {
  -- The measured shape: a bash call whose name did not arrive. The command would leave a marker if
  -- it ever ran, so "nothing executed" is checked against an effect, not against a sentence.
  { status = 200, content = "Let me check that.", finish_reason = "tool_calls", stream_complete = true,
    tool_calls = { { id = "call_malformed", type = "function",
      ["function"] = { name = "", arguments = json.encode({ command = "touch " .. marker }) } } } },
  { status = 200, content = "the call was malformed, rewritten by name", finish_reason = "stop",
    stream_complete = true, tool_calls = {} },
}
local ok, reply = pcall(agent.run, agent, "leave a marker")
check(ok, "a call with no name must not end the run: " .. tostring(reply))
check(tostring(reply):find("rewritten by name", 1, true) ~= nil, "the run continues and answers")
check(#bodies == 2, "exactly two requests (the malformed call, then the answer), got " .. tostring(#bodies))
check(not exists(marker), "a malformed call must not execute its arguments")

local first_problem = request_problem(json.decode(bodies[1]))
check(first_problem == nil, "the first request is already valid: " .. tostring(first_problem))
local second_problem = request_problem(json.decode(bodies[2]))
check(second_problem == nil,
  "the request that used to be rejected provider_http_400 invalid_parameter is valid: " .. tostring(second_problem))

-- The answer the model got names the fault and keeps its own arguments, so it can correct itself.
local second = json.decode(bodies[2])
local result_row
for _, message in ipairs(second.messages or {}) do
  if message.role == "tool" and message.tool_call_id == "call_malformed" then result_row = message end
end
check(result_row ~= nil, "the malformed call is answered with a tool result (the protocol needs one per id)")
local result_text = tostring(result_row and result_row.content or "")
check(result_text:find("tool_call_name_missing", 1, true) ~= nil,
  "the tool error names the fault: " .. result_text:sub(1, 200))
check(result_text:find("no tool name", 1, true) ~= nil,
  "the tool error says what was wrong in words: " .. result_text:sub(1, 200))
check(result_text:find("touch " .. marker, 1, true) ~= nil,
  "the arguments the model sent are echoed back so it can re-issue them: " .. result_text:sub(1, 300))

-- The stored transcript is valid on its own: a later rebuild (a resume, a compaction) must not
-- reintroduce the illegal name.
local stored
for _, row in ipairs(memory.session_messages(session_id, { all = true }) or {}) do
  if row.role == "assistant" and type(row.tool_calls) == "table" and #row.tool_calls > 0 then stored = row end
end
check(stored ~= nil, "the assistant step with its call is recorded")
local stored_call = stored and stored.tool_calls[1] or {}
local stored_function = type(stored_call["function"]) == "table" and stored_call["function"] or {}
check(legal_name(stored_function.name),
  "the stored call carries a legal name, not the empty one that was received: " .. tostring(stored_function.name))
check(type(stored_call.id) == "string" and stored_call.id ~= "", "the stored call carries an id")
check((memory.session_state(session_id) or {}).state == "answered", "the thread settles as answered")

-- ------------------------------------------------------------------ an already-bricked session
-- Rows written by the older binary: an assistant message whose call has no name and a tool result
-- whose name is empty. Rebuilding the context must produce a request the API accepts, or `--resume`
-- inherits the 400 forever.
local legacy = memory.ensure_session("tool-call-name", "local", "bricked by an older binary")
memory.append_turn(legacy, { role = "user", content = "check the tree" })
memory.append_turn(legacy, { id = "assistant-legacy", role = "assistant", content = "",
  tool_calls = { { id = "call_legacy", type = "function",
    ["function"] = { name = "", arguments = json.encode({ command = "git status" }) } } } })
memory.append_turn(legacy, { role = "tool", tool_call_id = "call_legacy", tool_name = "",
  content = '{"error":"plugin_not_found:"}' })
memory.append_turn(legacy, { role = "assistant", content = "the tree is clean" })
local resumed = agentlib.new(legacy, function() end, "master", "tool-call-name", "local")
local rebuilt = resumed:build_context()
local legacy_problem = request_problem({ messages = rebuilt })
check(legacy_problem == nil, "a resumed bricked session is sent a valid request: " .. tostring(legacy_problem))
local replayed
for _, message in ipairs(rebuilt) do
  if message.role == "tool" and message.tool_call_id == "call_legacy" then replayed = message end
end
check(replayed ~= nil, "the legacy tool result is kept, not dropped")
check(legal_name(replayed and replayed.name),
  "the replayed tool result carries a legal name: " .. tostring(replayed and replayed.name))

-- The rule the fix ships is the rule this row enforced.
for _, sample in ipairs({ "bash", "read_many", "mcp_whatsapp_send", "", "a b", "x" }) do
  check(provider.call_name_valid(sample) == legal_name(sample),
    "provider.call_name_valid agrees with the API rule for " .. string.format("%q", sample))
end

print(string.format("tool call name: %d checks", checks))
