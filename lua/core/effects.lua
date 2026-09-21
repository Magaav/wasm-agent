-- Durable effect reservations for a subagent's external side effects.
--
-- A send is not safe to replay: "the reservation may have had an effect" is a
-- different fact from "nothing happened", and only a durable record written
-- *before* the effect can tell them apart. This module is the SQLite adapter the
-- whatsapp-responder profile resolves as `ctx.effects`; the runtime builds one per
-- child session, so the per-run send budget is persistent and per-child.
--
-- Contract (what lua/core/whatsapp.lua calls):
--   effects.reserve({message_id, conversation_id, body, limit})
--     -> {status="reserved", record}   a new reservation was created atomically
--     -> {status="already_sent", record}
--     -> {status="ambiguous", record}  a prior reservation without a confirmation
--     -> {status="budget_exceeded"}
--   effects.confirm({message_id, conversation_id, message}) -> boolean
--   effects.record(decision_record) -> boolean          -- never touches a send
--   effects.reconcile({message_id,...}) -> {status="sent"|"not_sent"|"unknown", record?}
--   effects.release({message_id}) -> boolean            -- only when no effect happened
--   effects.unknown({message_id, detail}) -> boolean    -- ambiguous, never replayed
--   effects.find(message_id) -> record|nil
local json = dofile("lua/vendor/json.lua")

local M = {}

local function decode(raw)
  local ok, value = pcall(json.decode, raw or "")
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function exec(sql, params)
  return decode(host.sql_exec(sql, json.encode(params or {})))
end

local function query(sql, params)
  return decode(host.sql_query(sql, json.encode(params or {})))
end

-- One send record, or nil. Never creates one.
local function find_send(message_id)
  local rows = query("SELECT * FROM effect_sends WHERE message_id=? LIMIT 1", { message_id })
  return rows and rows[1] or nil
end

-- The adapter bound to one child session. `session_id` is the budget key: the
-- limit counts this child's pending, sent and unknown sends together, so a crash
-- cannot hand out a fresh budget on retry.
function M.new(session_id)
  session_id = tostring(session_id or "")
  local adapter = { session_id = session_id }

  function adapter.find(message_id)
    message_id = tostring(message_id or "")
    if message_id == "" then return nil end
    return find_send(message_id)
  end

  -- Atomic reserve + budget: a single INSERT..SELECT so two threads cannot both
  -- reserve the same message id or overrun the limit. `changes` is 1 only for the
  -- row that was actually inserted.
  function adapter.reserve(args)
    args = args or {}
    local message_id = tostring(args.message_id or "")
    if message_id == "" then return { status = "refused", error = "message_id_required" } end
    local limit = tonumber(args.limit) or 1
    if limit < 0 then limit = 0 end
    local now = host.now()
    local result = exec(
      "INSERT INTO effect_sends(message_id,session_id,conversation_id,body,state,message,detail,created_at,updated_at) " ..
      "SELECT ?,?,?,?,'pending','{}','',?,? " ..
      "WHERE NOT EXISTS(SELECT 1 FROM effect_sends WHERE message_id=?) " ..
      "AND (SELECT COUNT(*) FROM effect_sends WHERE session_id=? AND state IN ('pending','sent','unknown')) < ?",
      { message_id, session_id, tostring(args.conversation_id or ""), tostring(args.body or ""),
        now, now, message_id, session_id, limit })
    if not result or result.error then
      return { status = "refused", error = tostring(result and result.error or "reserve_failed") }
    end
    if tonumber(result.changes) == 1 then
      return { status = "reserved", record = find_send(message_id) }
    end
    local existing = find_send(message_id)
    if not existing then return { status = "budget_exceeded" } end
    if existing.state == "sent" then return { status = "already_sent", record = existing } end
    -- pending or unknown: a prior attempt may have had an effect.
    return { status = "ambiguous", record = existing }
  end

  -- Confirmation only advances a pending reservation and only when the caller
  -- names the same conversation the reservation was made for; a terminal record is
  -- never rewritten by a later call.
  function adapter.confirm(args)
    args = args or {}
    local message_id = tostring(args.message_id or "")
    if message_id == "" then return false end
    local result = exec(
      "UPDATE effect_sends SET state='sent', message=?, updated_at=? " ..
      "WHERE message_id=? AND state='pending' AND conversation_id=?",
      { json.encode(args.message or {}), host.now(), message_id, tostring(args.conversation_id or "") })
    return result ~= nil and not result.error and tonumber(result.changes) == 1
  end

  -- A decision is durable and lives in its own table, so it can never erase the
  -- pending/sent send record that `reserve` relies on.
  function adapter.record(record)
    if type(record) ~= "table" or tostring(record.message_id or "") == "" then return false end
    local now = host.now()
    local result = exec(
      "INSERT INTO effect_decisions(message_id,session_id,conversation_id,decision,reason,created_at,updated_at) " ..
      "VALUES(?,?,?,?,?,?,?) " ..
      "ON CONFLICT(message_id) DO UPDATE SET decision=excluded.decision, reason=excluded.reason, updated_at=excluded.updated_at",
      { tostring(record.message_id), session_id, tostring(record.conversation_id or ""),
        tostring(record.decision or ""), tostring(record.reason or ""), now, now })
    return result ~= nil and not result.error
  end

  -- Read-only reconciliation. This adapter cannot see the app's store, so a
  -- pending reservation is `unknown`, never `not_sent`: proving nothing happened
  -- needs the store, and guessing would replay a send.
  function adapter.reconcile(args)
    args = args or {}
    local record = find_send(tostring(args.message_id or ""))
    if not record then return { status = "not_sent" } end
    if record.state == "sent" then return { status = "sent", record = record } end
    return { status = "unknown", record = record }
  end

  -- Clear a reservation ONLY when the route proved no effect happened; otherwise
  -- the reservation stays and a retry is refused.
  function adapter.release(args)
    args = args or {}
    local message_id = tostring(args.message_id or "")
    if message_id == "" then return false end
    local result = exec("DELETE FROM effect_sends WHERE message_id=? AND state='pending'", { message_id })
    return result ~= nil and not result.error
  end

  -- Record an ambiguous outcome so the message is never replayed as if it were new.
  function adapter.unknown(args)
    args = args or {}
    local message_id = tostring(args.message_id or "")
    if message_id == "" then return false end
    local result = exec(
      "UPDATE effect_sends SET state='unknown', detail=?, updated_at=? WHERE message_id=? AND state='pending'",
      { tostring(args.detail or ""), host.now(), message_id })
    return result ~= nil and not result.error
  end

  -- The persistent per-child counter, computed from the durable rows rather than
  -- a value that can drift after a restart.
  function adapter.count()
    local rows = query(
      "SELECT COUNT(*) AS n FROM effect_sends WHERE session_id=? AND state IN ('pending','sent','unknown')",
      { session_id })
    return tonumber(rows and rows[1] and rows[1].n) or 0
  end

  return adapter
end

return M
