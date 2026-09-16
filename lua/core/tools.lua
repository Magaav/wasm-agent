-- Tools exposed to the head model: built-in memory tools plus WASM plugins.
local json = dofile("lua/vendor/json.lua")
local M = {}

M.builtin = {
  { type = "function", ["function"] = {
      name = "remember",
      description = "Store a fact the user asked you to remember, so it can be recalled later.",
      parameters = { type = "object", properties = {
        content = { type = "string", description = "The fact to remember, in full." },
        scope = { type = "string", description = "Optional scope, e.g. global or a conversation id." },
        tags = { type = "array", items = { type = "string" } } },
        required = { "content" } } } },
  { type = "function", ["function"] = {
      name = "recall",
      description = "Search remembered facts (the memories store).",
      parameters = { type = "object", properties = {
        query = { type = "string" },
        scope = { type = "string" },
        limit = { type = "integer", minimum = 1, maximum = 50 } },
        required = { "query" } } } },
  { type = "function", ["function"] = {
      name = "search_messages",
      description = "Search the message ledger (WhatsApp/chat history) for literal text.",
      parameters = { type = "object", properties = {
        query = { type = "string" },
        conversation_id = { type = "string" },
        limit = { type = "integer", minimum = 1, maximum = 50 } },
        required = { "query" } } } },
  { type = "function", ["function"] = {
      name = "conversation",
      description = "Read the most recent messages of one conversation, oldest first.",
      parameters = { type = "object", properties = {
        conversation_id = { type = "string" },
        limit = { type = "integer", minimum = 1, maximum = 200 } },
        required = { "conversation_id" } } } },
  { type = "function", ["function"] = {
      name = "list_conversations",
      description = "List conversations known to the ledger, most recently active first.",
      parameters = { type = "object", properties = {
        limit = { type = "integer", minimum = 1, maximum = 200 } } } } },
}

local function wasm_plugins()
  local ok, raw = pcall(host.plugins)
  if not ok or not raw then return {} end
  local decoded = json.decode(raw)
  return decoded or {}
end

-- Built-in schemas plus every WASM plugin's declared tool.
function M.all()
  local list = {}
  for _, schema in ipairs(M.builtin) do list[#list + 1] = schema end
  for _, plugin in ipairs(wasm_plugins()) do
    list[#list + 1] = { type = "function", ["function"] = {
      name = plugin.name,
      description = plugin.description or "",
      parameters = plugin.parameters or { type = "object" } } }
  end
  return list
end

function M.dispatch(memory, name, args)
  args = args or {}
  if name == "remember" then
    if not args.content or args.content == "" then return { error = "content_required" } end
    local id = memory.remember(args.content, args.scope or "global", args.tags or {})
    return { ok = true, id = id }
  elseif name == "recall" then
    return memory.recall(args.query or "", args.limit or 10, args.scope)
  elseif name == "search_messages" then
    return memory.search_messages(args.query or "", args.conversation_id, args.limit or 20)
  elseif name == "conversation" then
    return memory.conversation(args.conversation_id or "", args.limit or 50)
  elseif name == "list_conversations" then
    return memory.conversations(args.limit or 50)
  end
  -- Fall back to a WASM plugin. Unknown tools surface as a typed error.
  local ok, result = pcall(host.invoke, name, json.encode(args))
  if not ok then return { error = tostring(result) } end
  local decoded = json.decode(result)
  if type(decoded) ~= "table" then return { result = result } end
  return decoded
end

return M
