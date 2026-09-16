-- Memory tools exposed to the head model (OpenAI function-calling schema).
local M = {}

M.schemas = {
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
  return { error = "unknown_tool:" .. tostring(name) }
end

return M
