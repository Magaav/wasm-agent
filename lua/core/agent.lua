-- The agent turn loop: model + memory tools, persisted to the session ledger.
local json = dofile("lua/vendor/json.lua")
local tools = dofile("lua/core/tools.lua")
local provider = dofile("lua/core/provider.lua")
local memory = dofile("lua/core/memory.lua")

local M = {}
M.__index = M

local SYSTEM = table.concat({
  "You are wasm-agent, a concise, local-first assistant with durable memory.",
  "- When the user asks you to remember something, call `remember` and confirm briefly.",
  "- When the user asks about past conversations or facts, use `recall` (remembered facts)",
  "  and `search_messages`/`conversation` (the message ledger).",
  "- Never invent facts. If memory has nothing, say so plainly.",
  "- Keep replies short.",
}, "\n")

local MAX_TOOL_ROUNDS = 8

function M.new(session_id, on_event)
  return setmetatable({
    session_id = session_id or memory.start_session("cli", "interactive chat"),
    messages = { { role = "system", content = SYSTEM } },
    emit = on_event or function() end,
    stream = on_event ~= nil,
  }, M)
end

function M:turn(text)
  self.emit({ type = "status", text = "thinking" })
  if not provider.configured() then
    local reply = self:local_turn(text)
    self.emit({ type = "reply", text = reply })
    return reply
  end
  self.messages[#self.messages + 1] = { role = "user", content = text }
  local reply = ""
  for _ = 1, MAX_TOOL_ROUNDS do
    self.emit({ type = "status", text = "model" })
    local result = provider.complete(self.messages, tools.all(), self.stream)
    local calls = result.tool_calls
    local assistant = { role = "assistant", content = result.content or "" }
    if #calls > 0 then assistant.tool_calls = calls end
    self.messages[#self.messages + 1] = assistant
    if #calls == 0 then
      reply = result.content or ""
      break
    end
    for _, call in ipairs(calls) do
      local function_ = call["function"] or {}
      local args = {}
      if function_.arguments and function_.arguments ~= "" then
        local ok, decoded = pcall(json.decode, function_.arguments)
        if ok and type(decoded) == "table" then args = decoded end
      end
      self.emit({ type = "tool", name = function_.name, arguments = args })
      local ok, output = pcall(tools.dispatch, memory, function_.name, args)
      if not ok then output = { error = tostring(output) } end
      self.emit({ type = "tool_result", name = function_.name, result = output })
      self.messages[#self.messages + 1] = {
        role = "tool", tool_call_id = call.id or "", name = function_.name or "",
        content = json.encode(output),
      }
    end
  end
  if reply == "" then reply = "(tool loop limit reached)" end
  memory.record_run(host.uuid(), self.session_id, "completed", "completed", reply)
  self.emit({ type = "reply", text = reply })
  return reply
end

-- Deterministic fallback when no model provider is configured.
function M:local_turn(text)
  local lines = {}
  for _, row in ipairs(memory.recall(text, 5)) do lines[#lines + 1] = "- " .. row.content end
  for _, row in ipairs(memory.search_messages(text, nil, 5)) do
    lines[#lines + 1] = "- [" .. row.conversation_id .. "] " .. row.body
  end
  if #lines == 0 then return "No provider is configured and nothing in memory matched." end
  return "memory:\n" .. table.concat(lines, "\n")
end

function M:close()
  memory.finish_session(self.session_id)
end

return M
