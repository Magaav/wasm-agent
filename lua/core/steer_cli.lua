-- `wa steer <session> "<note>"`: put a note into a RUNNING session's durable inbox, from a shell.
--
-- WHY THIS EXISTS. Steering already exists and is durable (`lua/core/steering.lua`,
-- `docs/ORCHESTRATOR-WORKSPACE.md` "Live steering"): a queued note is consumed by the run that owns the
-- session at its next context boundary, atomically with its read receipt, and it lands in the
-- transcript as a user row. What did not exist was a way to do it from a shell: the capability was
-- reachable from the `subagent` tool action `steer_session` (a model turn) and from the window, so an
-- orchestrator supervising a `wa chat` it started had one lever - kill the process - and killing it is
-- what left sessions claimed (measured 2026-11-11: five kills in one night, sessions on
-- `resource_busy`).
--
-- WHAT IT IS NOT. It is not a second queue: the row is `steering_inbox`, written by
-- `steering.control`, and the reader of that row is the run itself. This module is the door and the
-- report, and it decides nothing about delivery: `queued` means accepted into a run that is in flight
-- ("read means durable context, not verified compliance", as the receipt says), and `no_active_steering_target`
-- means the session is between turns - the honest answer, not a note that goes nowhere.
--
-- The owner is the session's own `user_id` (the CLI runs as `master`), so the ownership check inside
-- `steering.control` is the real one and this door cannot steer a session that is not this user's.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local steering = dofile("lua/core/steering.lua")

local M = {}

local USAGE = [[
usage: wa steer <session> "<note>"          queue a note for a running session's next context boundary
       wa steer <session> --status [--after <n>]   the run in flight and its receipts
       wa steer <session> --status --json   the same, as JSON

The note is durable before it is delivered: it is a `steering_inbox` row owned by the run in flight, the
run consumes it at its next context boundary (the next model round, or with the results of a read-only
call already in flight), and it appears in the session's transcript as a user row. A session that is
between turns has no run to receive it and refuses `no_active_steering_target` - that is not a failure to
retry, it is the answer.]]

-- Steering takes text, not a command line: everything after the session id is the note, so a note with
-- spaces needs no quoting discipline beyond the shell's own.
function M.run(argv)
  argv = argv or {}
  local session_id, text, status, as_json, after = nil, {}, false, false, 0
  local index = 1
  while argv[index] do
    local arg = argv[index]
    if arg == "--status" then status = true; index = index + 1
    elseif arg == "--json" then as_json = true; index = index + 1
    elseif arg == "--after" then after = tonumber(argv[index + 1]) or 0; index = index + 2
    elseif arg == "--help" or arg == "-h" then print(USAGE); return 0
    elseif not session_id and not arg:match("^%-%-") then session_id = arg; index = index + 1
    else text[#text + 1] = arg; index = index + 1 end
  end
  text = table.concat(text, " ")
  if not session_id or session_id == "" then print(USAGE); return 2 end
  local session = memory.session(session_id)
  if not session then
    print("steer: no such session: " .. session_id)
    print("       list them with: wa sessions")
    return 2
  end
  local ctx = { user_id = session.user_id or "master", role = "master", session_id = "" }
  if status then
    local result = steering.control({ action = "steering_status", session_id = session_id, after = after }, ctx)
    if result.error then
      print("steer: " .. tostring(result.error))
      if result.target then print("       run " .. tostring(result.target.run_id or "?") .. " is " .. tostring(result.target.state or "unknown")) end
      return 1
    end
    if as_json then print(json.encode(result)) return 0 end
    local target = result.target
    if target then
      print(string.format("  run %s  %s  updated %ss ago", tostring(target.run_id or "?"),
        tostring(target.state or "unknown"), tostring(math.max(0, host.now() - (tonumber(target.updated_at) or host.now())))))
    else
      print("  no run recorded for this session")
    end
    local receipts = result.receipts or {}
    if #receipts == 0 then print("  no steering receipts") end
    for _, row in ipairs(receipts) do
      print(string.format("  %s  %s  %s%s", tostring(row.id), tostring(row.state), tostring(row.run_id or ""),
        row.message_seq and ("  seq " .. tostring(row.message_seq)) or (row.detail and ("  " .. tostring(row.detail)) or "")))
    end
    return 0
  end
  if text:match("^%s*$") then print(USAGE); return 2 end
  if #text > 32768 then print("steer: the note is longer than 32768 bytes"); return 2 end
  -- One invocation is one note. The key is unique to this request (a retried command is a second note,
  -- visibly, rather than a silent duplicate suppression of a different sentence).
  local result = steering.control({ action = "steer_session", session_id = session_id, text = text,
    idempotency_key = "cli:" .. tostring(host.uuid()) }, ctx)
  if result.error then
    print("steer: " .. tostring(result.error))
    if result.error == "no_active_steering_target" then
      local target = result.target
      print("       " .. (target
        and ("the last run for this session is " .. tostring(target.state or "unknown") .. "; a note reaches a run that is in flight, at its next context boundary")
        or "no run is recorded for this session, so there is no boundary to deliver at"))
      print("       to give it a turn now: wa chat --session " .. session_id .. " --once \"<note>\"")
    end
    return 1
  end
  if as_json then print(json.encode(result)) return 0 end
  print(string.format("steer: queued %s for run %s (%s)", tostring(result.id), tostring(result.run_id or "?"),
    result.deduplicated and "already queued" or "at its next context boundary"))
  return 0
end

return M
