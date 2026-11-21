-- A settled pending handle wakes its session (21/11). docs/CODEMODE.md, "A settled handle wakes the
-- session".
--
-- WHY. A script that hands back a handle is telling the model "this work outlives my budget". The
-- work then finishes while the model is idle, and until 21/11 the answer reached it only by luck: the
-- next script in the same scope announced it (pending_settled), so a model that had nothing else to
-- do never learned its build was done. Victor's rule (21/11, copying Claude Code) is that a settled
-- handle starts a model step by itself - with the terminal open OR with only the node serving.
--
-- HOW, and nothing new: the node already has one way to start a turn with nobody typing - a
-- self_wakes row claimed by the node's placement tick (lua/core/selfloop.lua) or by the interactive
-- CLI's idle prompt (lua/core/chat.lua). A settled handle creates one such row, once, with
-- schedule_settled's derived id, and the two surfaces that already claim wakes do the rest. So this
-- module is only the SWEEP: for every scope of pending handles whose records name a live session,
-- poll each open handle with no wait (codemode_pending.wake_settled), and schedule one durable wake
-- per settle.
--
-- EXACTLY ONCE. Two writers are ordinary here (a node serving the session and a terminal on it, or
-- two processes after a restart): the row's id is derived from the operation id, so the second insert
-- is a no-op, and the handle record is marked woke_at only after the insert answered. A process that
-- dies between the two leaves a reconcile case, never a lost answer or a second turn for one settle.
--
-- WHAT THE ROW SAYS. The answer itself, in the same flat shape wait(op) answers (docs/CODEMODE.md,
-- "one result shape"), and the list of handles that are STILL pending with their age - so a model
-- that restarts or has its context compacted needs no memory of what it left running.
local json = dofile("lua/vendor/json.lua")
local M = {}

-- The core modules this file calls, cached per interpreter (the sweep runs on a 2 s tick).
local deps = {}
local function dep(name)
  if not deps[name] then deps[name] = dofile("lua/core/" .. name .. ".lua") end
  return deps[name]
end

-- How much of a settled answer the wake row carries. The full stdout can be 24 KiB and the row is a
-- turn's first user message; past this the row names the handle and the way to read the rest.
M.PROMPT_BYTES = 8 * 1024

local function clip(text, limit)
  limit = limit or M.PROMPT_BYTES
  text = tostring(text or "")
  if #text <= limit then return text end
  return text:sub(1, limit) .. string.format("\n[clipped at %d bytes of %d; the whole answer is the handle's own, read it with results.get(op)]", limit, #text)
end

-- The words of one wake row: the answer, then what is still running. Read-only and pure, so a test can
-- hold it without a node, a model or a tick.
function M.prompt_for(record, value, still)
  record, still = type(record) == "table" and record or {}, type(still) == "table" and still or {}
  local lines = {}
  lines[#lines + 1] = string.format("%s %s finished while no script was waiting for it (it is %s).",
    tostring(record.tool or "a call"), tostring(record.op or "?"), tostring(record.state or "settled"))
  lines[#lines + 1] = ""
  if value ~= nil then
    lines[#lines + 1] = "Its answer, in the same shape the call itself answers:"
    lines[#lines + 1] = clip(json.encode(value))
  else
    lines[#lines + 1] = string.format(
      "Its answer could not be read back (%s). The handle is kept: results.get(%s) may still answer it.",
      tostring(record.result_error or record.error or "no_retained_result"), tostring(record.op or "op"))
  end
  lines[#lines + 1] = ""
  if #still == 0 then
    lines[#lines + 1] = "No handle is pending any more."
  else
    local parts = {}
    for _, handle in ipairs(still) do
      parts[#parts + 1] = string.format("%s (%s, %ds)", tostring(handle.op), tostring(handle.tool or "call"),
        tonumber(handle.age_s) or 0)
    end
    lines[#lines + 1] = string.format("Still pending (%d): %s", #still, table.concat(parts, ", "))
    lines[#lines + 1] = "wait(op) resumes one, cancel(op) stops one, results.get(op) re-reads an answer."
  end
  return table.concat(lines, "\n")
end

-- Schedule the one durable wake for one settled handle. Answers true when the wake exists (this
-- process made it, or an earlier one already had).
function M.schedule(session_id, scope, record, value)
  local memory, pending, selfloop = dep("memory"), dep("codemode_pending"), dep("selfloop")
  local session = memory.session(session_id)
  if not session then return false end
  local still = pending.open_handles(scope)
  local prompt = M.prompt_for(record, value, still)
  local ok, answer = pcall(selfloop.schedule_settled, record.op, session.user_id, session_id,
    "a pending call settled", prompt)
  if not ok or type(answer) ~= "table" or answer.error then
    pcall(host.log, "handle wake: " .. tostring(type(answer) == "table" and answer.error or answer))
    return false
  end
  return true
end

-- The sweep: one poll per open handle, one wake per settle. Answers
-- {scopes, settled, skipped} so a caller (or a test) can see what it did.
function M.sweep(opts)
  opts = opts or {}
  local pending, memory, tools = dep("codemode_pending"), dep("memory"), dep("tools")
  local out = { scopes = 0, settled = 0, skipped = 0 }
  local listing = host.list_dir and host.list_dir(pending.dir()) or nil
  if type(listing) == "string" then
    local decoded_ok, decoded = pcall(json.decode, listing)
    listing = decoded_ok and decoded or nil
  end
  local entries = type(listing) == "table" and (listing.entries or {}) or {}
  for _, item in ipairs(entries) do
    local name = tostring(type(item) == "table" and item.name or "")
    if name:match("%.json$") then
      local scope = name:gsub("%.json$", "")
      local index = pending.open(scope)
      -- Which session this scope's open handles belong to: a record carries it, and a scope whose
      -- handles name no session (a caller that could not be named) is not woken - there is nobody to
      -- tell, and inventing a session would be a turn in somebody else's conversation.
      local session_id
      for _, record in pairs(index.ops or {}) do
        if record.woke_at == nil and (record.state == "running" or record.state == "unknown")
          and tostring(record.session or "") ~= "" then
          session_id = tostring(record.session)
        end
      end
      local session = session_id and memory.session(session_id) or nil
      if session and tostring(session.objective or "") ~= "subagent" and session.parent_session_id == nil then
        local role = session.role or "master"
        local ctx = { session_id = session_id, user_id = session.user_id, role = role }
        local function dispatch(tool_name, args, raw)
          return tools.dispatch(memory, tool_name, args, role, ctx, raw)
        end
        out.scopes = out.scopes + 1
        local woken = pending.wake_settled(dispatch,
          { scope = scope, session = session_id, ctx = ctx, dispatch = dispatch }, scope,
          function(record, value) return M.schedule(session_id, scope, record, value) end)
        out.settled = out.settled + (tonumber(woken) or 0)
      else
        out.skipped = out.skipped + 1
      end
    end
  end
  return out
end

return M
