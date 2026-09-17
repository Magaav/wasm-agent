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

local function each(rows)
  if #rows == 0 then print("(empty)") return end
  for _, row in ipairs(rows) do print(line(row)) end
end

local function limit_of(value, fallback)
  return tonumber(value) or fallback
end

local command = args[1]
if command == nil or command == "chat" then
  -- Propagate the REPL's status: `wa chat --session <bogus>` exits non-zero so a
  -- script can tell a rejected session from a successful one.
  local code = dofile("lua/core/chat.lua").run(args)
  if code and code ~= 0 then os.exit(code) end
  return
end

if command == "init" then
  print(json.encode({ schema = "ok" }))
elseif command == "remember" then
  print(memory.remember(args[2], "global", {}))
elseif command == "recall" then
  each(memory.recall(args[2], limit_of(args[3], 10)))
elseif command == "memories" then
  each(memory.memories(nil, limit_of(args[2], 50)))
elseif command == "forget" then
  print(json.encode({ forgotten = memory.forget(args[2]) }))
elseif command == "search" then
  each(memory.search_messages(args[2], args[3], limit_of(args[4], 20)))
elseif command == "conversation" then
  each(memory.conversation(args[2], limit_of(args[3], 50)))
elseif command == "conversations" then
  each(memory.conversations(limit_of(args[2], 50)))
elseif command == "stats" then
  print(json.encode(memory.stats()))
elseif command == "sessions" then
  local rows = memory.list_sessions(nil, limit_of(args[2], 20))
  if #rows == 0 then print("(no sessions)") end
  for _, row in ipairs(rows) do
    print(string.format("%s  %-14s turns=%-3d %s", row.id, row.user_id or "",
      tonumber(row.turn_count) or 0, row.title or ""))
  end
elseif command == "nodes" then
  local nodes = dofile("lua/core/nodes.lua")
  print(json.encode({ node_id = (nodes.identity() or {}).node_id, nodes = nodes.list() }))
elseif command == "call" then
  local nodes = dofile("lua/core/nodes.lua")
  local payload = {}
  if args[4] and args[4] ~= "" then
    local ok, decoded = pcall(json.decode, args[4])
    if ok and type(decoded) == "table" then payload = decoded end
  end
  print(json.encode(nodes.remote_call(args[2], args[3], payload)))
elseif command == "help" then
  print("wa: chat [--continue|--session <id>] [prompt]  |  remember <text> | recall <query>")
  print("    memories | forget <id> | search <query> | conversation <id> | conversations")
  print("    sessions | stats | nodes | call <node> <capability> [args-json]")
else
  print("unknown command: " .. tostring(command))
  os.exit(2)
end
