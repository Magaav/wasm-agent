-- Interactive `wa` chat: model + memory, with local slash commands.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")

local M = {}

local HELP = [[commands:
  /remember <text>     store a memory
  /recall <query>      search memories
  /memories            list recent memories
  /search <query>      search the message ledger
  /conversation <id>   read a conversation
  /stats               database counts
  /help                this help
  /exit                quit
anything else is sent to the model.]]

local function each(rows, render)
  if #rows == 0 then print("(empty)") return end
  for _, row in ipairs(rows) do print(render(row)) end
end

local function memory_line(row)
  local tags = (#row.tags > 0) and (" [" .. table.concat(row.tags, ", ") .. "]") or ""
  return string.format("%s  %s%s  %s", row.id, row.scope, tags, row.content)
end

function M.run()
  local settings = provider.settings()
  local mode = provider.configured() and (settings.model .. " @ " .. settings.base_url)
    or "local mode (no model configured)"
  print("")
  print("  wasm-agent 0.1.0")
  print("  model   " .. mode)
  print("  memory  " .. (os.getenv("WASM_AGENT_DB") or "~/.wasm-agent/memory.db"))
  print("  /help for commands, /exit to quit")
  print("")
  local agent = agentlib.new()
  while true do
    io.write("wa> ")
    io.flush()
    local line = io.read("*l")
    if line == nil then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
      -- keep prompting
    elseif line == "/exit" or line == "/quit" then
      break
    elseif line == "/help" then
      print(HELP)
    elseif line == "/stats" then
      print(json.encode(memory.stats()))
    elseif line == "/memories" then
      each(memory.memories(nil, 50), memory_line)
    elseif line:sub(1, 10) == "/remember " then
      print(memory.remember(line:sub(11)))
    elseif line:sub(1, 8) == "/recall " then
      each(memory.recall(line:sub(9), 10), memory_line)
    elseif line:sub(1, 8) == "/search " then
      each(memory.search_messages(line:sub(9), nil, 20), function(row)
        return string.format("%s  %s  %s", row.conversation_id, row.sender_id or "-", row.body)
      end)
    elseif line:sub(1, 14) == "/conversation " then
      each(memory.conversation(line:sub(15), 50), function(row)
        return string.format("%s  %s  %s", row.conversation_id, row.sender_id or "-", row.body)
      end)
    else
      local ok, reply = pcall(agent.turn, agent, line)
      if ok then
        print(reply)
      else
        print("error: " .. tostring(reply))
      end
    end
  end
  agent:close()
  return 0
end

return M
