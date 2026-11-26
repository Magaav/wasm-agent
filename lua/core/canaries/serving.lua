-- WHO ANSWERS AN ACCOUNT QUESTION (26/11, Fable item 2b).
--
-- The account canaries used to call host.whatsapp_contacts / host.whatsapp_search directly. That is THIS
-- process own capability, so on a node whose account is served elsewhere the canary read the CLI emptiness and
-- answered not_proven (or, worse, a refusal) for a feature the node serves fine. The routed layer already
-- exists: lua/core/whatsapp.lua resolves the owner and every answer it brings back carries `served_by`.
--
-- So an account question goes through the door the agent itself uses, in this order:
--   1. host.canary_ask(tool, args) - the seam, which a node with a routed query installs and a row stubs;
--   2. whatsapp.invoke(tool, args) - the routed tool door (owner resolution + served_by) for WhatsApp;
--   3. the raw host capability - the same call the canary made before, kept for a process that has neither.
-- What answered is returned, never assumed: the canary says `served_by` when a node answered for another.
local json = dofile("lua/vendor/json.lua")

local M = {}

M.ROUTED = { whatsapp_contacts = true, whatsapp_search = true, whatsapp_read = true }

local function decode(answer)
  if type(answer) == "string" then
    local ok, parsed = pcall(json.decode, answer)
    return ok and parsed or nil
  end
  return type(answer) == "table" and answer or nil
end

-- <tool>, <args> -> ok, answer (a table), how ("seam" | "serving" | "local")
-- how says which door answered: "serving" means another node answered (the answer carries served_by).
function M.ask(tool, args, options)
  options = type(options) == "table" and options or {}
  args = type(args) == "table" and args or {}
  local encoded = json.encode(args)
  if type(host.canary_ask) == "function" then
    local ok, answer = pcall(host.canary_ask, tool, encoded)
    local table_answer = ok and decode(answer) or nil
    if table_answer then return true, table_answer, table_answer.served_by and "serving" or "seam" end
  end
  if M.ROUTED[tool] then
    local loaded, whatsapp = pcall(dofile, "lua/core/whatsapp.lua")
    if loaded and type(whatsapp) == "table" and type(whatsapp.invoke) == "function" then
      local ok, answer = pcall(whatsapp.invoke, tool, args)
      local table_answer = ok and decode(answer) or nil
      if table_answer then return true, table_answer, table_answer.served_by and "serving" or "local" end
    end
  end
  if type(host[tool]) == "function" then
    local ok, answer = pcall(host[tool], encoded)
    local table_answer = ok and decode(answer) or nil
    if table_answer then return true, table_answer, "local" end
    return false, { error = ok and "answer_unreadable" or "query_raised", detail = tostring(answer):sub(1, 160) }, "local"
  end
  return false, { error = "capability_missing", detail = "this process has no " .. tostring(tool) .. " and no routed door to ask" }, "none"
end

-- The one thing a canary must say out loud when a node answered for another: the question took a hop.
function M.detail(answer, detail)
  local served = type(answer) == "table" and tostring(answer.served_by or "") or ""
  if served == "" then return detail end
  return tostring(detail or "") .. " (asked " .. served .. ")"
end

return M
