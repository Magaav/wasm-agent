-- wasm-agent CLI, in Lua. Capabilities come from the host (`host.*`).
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

memory.setup()

local function line(item)
  if item.content then
    local tags = ""
    if item.tags and #item.tags > 0 then tags = " [" .. table.concat(item.tags, ", ") .. "]" end
    return string.format("%s  %s%s  %s", item.id, item.scope or "", tags, item.content)
  elseif item.body then
    return string.format("%s  %s  %s", item.conversation_id, item.sender_id or "-", item.body)
  end
  return json.encode(item)
end

local function limit_of(value, fallback)
  return tonumber(value) or fallback
end

local function each(rows)
  if #rows == 0 then print("(empty)") return end
  for _, row in ipairs(rows) do print(line(row)) end
end

local command = args[1] or "help"
if command == "init" then
  print(json.encode({schema = "ok"}))
elseif command == "remember" then
  print(memory.remember(args[2], "global", {}))
elseif command == "recall" then
  each(memory.recall(args[2], limit_of(args[3], 10)))
elseif command == "memories" then
  each(memory.memories(nil, limit_of(args[2], 50)))
elseif command == "forget" then
  print(json.encode({forgotten = memory.forget(args[2])}))
elseif command == "search" then
  each(memory.search_messages(args[2], args[3], limit_of(args[4], 20)))
elseif command == "conversation" then
  each(memory.conversation(args[2], limit_of(args[3], 50)))
elseif command == "conversations" then
  each(memory.conversations(limit_of(args[2], 50)))
elseif command == "stats" then
  print(json.encode(memory.stats()))
elseif command == "help" then
  print("wa: init | remember <text> | recall <query> | memories | forget <id>")
  print("    search <query> | conversation <id> | conversations | stats")
else
  print("unknown command: " .. tostring(command))
  os.exit(2)
end
