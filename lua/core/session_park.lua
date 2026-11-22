-- `wa session park <id> [--reason <text>]`, `wa session release <id>`, `wa session status [<id>]`
-- (22/11).
--
-- WHY. A mission was stopped on purpose - its unit stopped, a HOLD file written in its mission
-- directory - and its session kept working: 196 messages at the stop, 263 an hour later. Each install
-- had written a "deploy pending: resume after the node swap" wake (lua/core/deploy_pause.lua) and the
-- node's tick performed it, in a session that was running a 64-wide load test and saturating the
-- laptop during two landings. A stopped unit and a HOLD file are outside this program, so nothing in
-- it knew the session was parked, and there was no verb that could say so: `wa mission stop` is the
-- mission loop's, and it stops pids.
--
-- So a session can be PARKED. The state is the kernel's (`selfloop.park`: a `self_wake_pauses` row of
-- kind `park`), which is what makes every reader honour it without a second rule - the node's tick
-- dispatches none of that session's wakes and counts them held, the CLI's idle claim takes none, and
-- `selfloop.resume` (the door `wa chat --resume`, `wa resume --session` and a user message all go
-- through) lifts nothing but says it is parked. ONLY `wa session release <id>` lifts it, which is the
-- one promise a stop needs: a hold the session's own next visit undid is not a stop.
--
-- WHAT IT DOES NOT DO, said plainly so nobody reads more into it: it does not kill a run that is
-- already in flight (that turn's effects are unknown, and nothing here may claim to have stopped it),
-- it does not touch a subagent child's own schedule, and it does not cancel a wake - the wake keeps
-- its time, its order, its target and its prompt, and fires once after the release.
--
-- This file is the verb only: which session, the words an operator reads, and the exit code. Every
-- decision is `selfloop`'s.
local json = dofile("lua/vendor/json.lua")

local M = {}

M.USAGE = "usage: wa session park <id> [--reason <text>] | wa session release <id> | wa session status [<id>]"

local function short(id)
  return tostring(id or ""):sub(1, 8)
end

-- Local wall clock, the node's own zone: an operator reads "since 00:10" and not an epoch.
local function at(seconds)
  if not tonumber(seconds) then return "?" end
  return os.date("%Y-%m-%d %H:%M", math.floor(tonumber(seconds)))
end

-- Which session a word means. An exact id first (an allow-list of one: the answer `wa sessions`
-- printed is the answer this takes), then a UNIQUE prefix, because an operator reads and types eight
-- characters. Two matches are refused by name with both ids: guessing which thread a stop meant is the
-- one mistake this verb must not make.
local PREFIX_SCAN = 500
local function resolve(memory, wanted)
  local word = tostring(wanted or "")
  if word == "" then return nil, "no_session_id" end
  local session = memory.session(word)
  if session then return session end
  local matches, seen = {}, {}
  for _, row in ipairs(memory.list_sessions(nil, PREFIX_SCAN) or {}) do
    local id = tostring(row.id or "")
    if id ~= "" and id:sub(1, #word) == word and not seen[id] then
      seen[id] = true
      matches[#matches + 1] = { id = id, title = tostring(row.title or "") }
    end
    if #matches > 1 then break end
  end
  if #matches == 1 then return memory.session(matches[1].id) end
  if #matches > 1 then
    local ids = {}
    for _, match in ipairs(matches) do ids[#ids + 1] = match.id end
    return nil, "ambiguous_session", ids
  end
  return nil, "no_such_session"
end

local function count_line(wakes, parked)
  local total = tonumber(wakes) or 0
  return tostring(total) .. (total == 1 and " wake " or " wakes ") .. (parked and "held" or "pending")
end

-- Park. Answers `{ ok, code, lines }` plus the facts, so a caller (the CLI, or a test) prints nothing
-- it did not measure.
function M.park(opts)
  opts = opts or {}
  local memory, selfloop = dofile("lua/core/memory.lua"), dofile("lua/core/selfloop.lua")
  local owner = tostring(opts.user_id or "master")
  local id, why, ids = opts.session_id, nil, nil
  if not id or id == "" then id, why, ids = resolve(memory, opts.wanted) end
  if not id then
    if why == "ambiguous_session" then
      return { ok = false, code = 2, error = why, matches = ids, lines = {
        "that is not one session: " .. table.concat(ids or {}, ", "),
        "name it in full: wa session park <id>",
      } }
    end
    return { ok = false, code = 2, error = why or "no_such_session", lines = {
      "no such session: " .. tostring(opts.wanted or ""),
      "list them with: wa sessions",
    } }
  end
  local session_id = tostring(id.id or id)
  local answer = selfloop.park(session_id, owner, opts.reason, opts)
  if type(answer) ~= "table" or answer.error then
    return { ok = false, code = 1, error = tostring(type(answer) == "table" and answer.error or answer),
      lines = { "could not park " .. session_id .. ": " .. tostring(type(answer) == "table" and answer.error or answer) } }
  end
  if answer.parked ~= true then
    -- The hold row was written and gone again inside this call (a release in another process). Saying
    -- "parked" here would be a claim this call cannot stand behind.
    return { ok = false, code = 1, error = "park_raced", session_id = session_id, lines = {
      session_id .. " was released while this call ran, so it is NOT parked; run it again",
    } }
  end
  local lines = {}
  lines[#lines + 1] = (answer.already and "already parked " or "parked ") .. session_id
  lines[#lines + 1] = "  since " .. at(answer.since)
  lines[#lines + 1] = "  reason: " .. (tostring(answer.reason or "") ~= "" and tostring(answer.reason) or "no reason given")
  lines[#lines + 1] = "  " .. count_line(answer.pending, true)
    .. ((tonumber(answer.overdue) or 0) > 0 and (" (" .. tostring(answer.overdue) .. " already due, fires once on release)") or "")
  lines[#lines + 1] = "  no turn runs for this session; release it with: wa session release " .. session_id
  return { ok = true, code = 0, parked = true, already = answer.already and true or false,
    upgraded = answer.upgraded and true or false,
    session_id = session_id, since = answer.since, reason = answer.reason,
    pending = answer.pending, overdue = answer.overdue, lines = lines }
end

-- Release. The wakes were never touched, so what is due is due again - once.
function M.release(opts)
  opts = opts or {}
  local memory, selfloop = dofile("lua/core/memory.lua"), dofile("lua/core/selfloop.lua")
  local id, why, ids = opts.session_id, nil, nil
  if not id or id == "" then id, why, ids = resolve(memory, opts.wanted) end
  if not id then
    if why == "ambiguous_session" then
      return { ok = false, code = 2, error = why, matches = ids, lines = {
        "that is not one session: " .. table.concat(ids or {}, ", "),
        "name it in full: wa session release <id>",
      } }
    end
    return { ok = false, code = 2, error = why or "no_such_session", lines = {
      "no such session: " .. tostring(opts.wanted or ""),
      "list them with: wa sessions",
    } }
  end
  local session_id = tostring(id.id or id)
  local answer = selfloop.release(session_id, opts)
  if type(answer) ~= "table" or answer.error then
    if type(answer) == "table" and answer.error == "session_held_by_interrupt" then
      -- Not a refusal of the operator's intent: an interrupt hold is lifted by coming back to the
      -- session, and deleting it here would re-arm a schedule the user stopped with Esc.
      return { ok = false, code = 1, error = "session_held_by_interrupt", session_id = session_id,
        held_kind = answer.held_kind, since = answer.since, lines = {
        session_id .. " is held by an interrupted run since " .. at(answer.since) .. ", not by a park:",
        "  there is nothing to release; coming back to the session re-arms it: wa chat --resume " .. session_id,
      } }
    end
    return { ok = false, code = 1, error = tostring(type(answer) == "table" and answer.error or answer),
      lines = { "could not release " .. session_id .. ": " .. tostring(type(answer) == "table" and answer.error or answer) } }
  end
  if answer.released ~= true then
    return { ok = false, code = 1, error = "not_parked", session_id = session_id, lines = {
      session_id .. " is not parked; nothing to release (" .. count_line(answer.pending, false) .. ")",
    } }
  end
  local lines = {
    "released " .. session_id,
    "  " .. count_line(answer.pending, false) .. " again"
      .. ((tonumber(answer.overdue) or 0) > 0
        and (" (" .. tostring(answer.overdue) .. " already due, fires once)")
        or (tonumber(answer.overdue_at) and (" (next due " .. at(answer.overdue_at) .. ")") or "")),
  }
  return { ok = true, code = 0, released = true, session_id = session_id, since = answer.since,
    reason = answer.reason, pending = answer.pending, overdue = answer.overdue, lines = lines }
end

-- What a reader -- `wa-sentinel status`, a stop recipe, an operator -- asks: is this session parked,
-- how many of its wakes are held, and since when. With no id: every parked session, which is the one
-- question "did anything get parked on this node" has.
function M.status(opts)
  opts = opts or {}
  local memory, selfloop = dofile("lua/core/memory.lua"), dofile("lua/core/selfloop.lua")
  local wanted = tostring(opts.wanted or "")
  local function one(session_id)
    local hold = selfloop.hold(session_id)
    local summary = selfloop.summary(session_id, opts) or {}
    -- What a hold is keeping, from the wake rows themselves: `summary` counts them the same way the
    -- tick does, so a reader here and a reader there cannot disagree.
    return { session_id = session_id, parked = (hold ~= nil and hold.kind == "park") or false,
      held = hold ~= nil, kind = hold and hold.kind or nil, since = hold and hold.since or nil,
      reason = hold and hold.reason or nil, pending = tonumber(summary.pending) or 0 }
  end
  if wanted ~= "" then
    local session, why, ids = resolve(memory, wanted)
    if not session then
      if why == "ambiguous_session" then
        return { ok = false, code = 2, error = why, matches = ids, lines = {
          "that is not one session: " .. table.concat(ids or {}, ", "),
          "name it in full: wa session status <id>",
        } }
      end
      return { ok = false, code = 2, error = why or "no_such_session", lines = {
        "no such session: " .. wanted, "list them with: wa sessions",
      } }
    end
    local id = tostring(session.id or session)
    local fact = one(id)
    local line
    if fact.parked then
      line = id .. "  parked since " .. at(fact.since)
        .. "  " .. count_line(fact.pending, true)
        .. "  reason: " .. (tostring(fact.reason or "") ~= "" and tostring(fact.reason) or "no reason given")
    elseif fact.held then
      line = id .. "  held by an interrupted run since " .. at(fact.since)
        .. "  " .. count_line(fact.pending, true)
    else
      line = id .. "  not parked  " .. count_line(fact.pending, false)
    end
    return { ok = true, code = 0, sessions = { fact }, lines = { line },
      parked = fact.parked, session_id = id, pending = fact.pending, since = fact.since }
  end
  -- Every parked session, from the one table that holds them: no scan of the transcript, and a session
  -- that is held by an interrupt is NOT in this answer (the verb's own word is `parked`).
  local rows = host.sql_query("SELECT session_id, reason, paused_at FROM self_wake_pauses WHERE kind='park' ORDER BY paused_at",
    json.encode({}))
  if type(rows) == "string" then
    local decoded_ok, decoded = pcall(json.decode, rows)
    rows = decoded_ok and decoded or {}
  end
  local out, lines = {}, {}
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    local id = tostring(row.session_id or "")
    if id ~= "" then
      local fact = one(id)
      out[#out + 1] = fact
      lines[#lines + 1] = id .. "  parked since " .. at(fact.since)
        .. "  " .. count_line(fact.pending, true)
        .. "  reason: " .. (tostring(fact.reason or "") ~= "" and tostring(fact.reason) or "no reason given")
    end
  end
  if #lines == 0 then lines[1] = "no session is parked" end
  return { ok = true, code = 0, sessions = out, count = #out, lines = lines }
end

-- `--mission <name>`: the factory's stop recipe writes a HOLD file and stops a unit; the session id is
-- the one the mission directory already recorded (`wa mission status <name>` prints it), so the line
-- the recipe runs names the mission and not an id nobody has to hand.
local function from_mission(name)
  local mission = dofile("lua/core/mission.lua")
  local status = mission.status({ name = name })
  if type(status) ~= "table" or status.error then
    return nil, tostring(type(status) == "table" and (status.error or status.detail) or "mission_unreadable")
  end
  local session = tostring(status.session or "")
  if session == "" or session == "-" then
    return nil, "mission_no_session"
  end
  return session
end

-- The verb. `argv` is the words after `session park`/`session release`/`session status` as the CLI
-- passes them (no flags named twice, `--flag value` pairs). It prints the answer and returns the exit
-- code, and it prints NOTHING about a park it did not observe: `--json` carries the same facts.
function M.cli(verb, argv, ctx)
  argv = argv or {}
  local opts = { user_id = tostring((ctx or {}).user_id or "master"), reason = nil, json = false }
  local words, index = {}, 1
  while index <= #argv do
    local word = tostring(argv[index])
    if word == "--reason" then
      opts.reason = tostring(argv[index + 1] or "")
      index = index + 2
    elseif word == "--mission" then
      local name = tostring(argv[index + 1] or "")
      local session, why = from_mission(name)
      if not session then
        print("no session for mission " .. name .. ": " .. tostring(why))
        print("  a mission records its session in run.lock (SESSION=) or in its out.log (wa: session <id>)")
        return 2
      end
      opts.session_id = session
      index = index + 2
    elseif word == "--json" then
      opts.json = true
      index = index + 1
    elseif word == "--help" or word == "-h" then
      print(M.USAGE)
      return 0
    else
      words[#words + 1] = word
      index = index + 1
    end
  end
  if verb == "status" then
    opts.wanted = words[1]
  else
    if not opts.session_id then opts.wanted = words[1] end
    if not opts.wanted and not opts.session_id then
      print(M.USAGE)
      return 2
    end
  end
  local answer
  if verb == "park" then answer = M.park(opts)
  elseif verb == "release" then answer = M.release(opts)
  elseif verb == "status" then answer = M.status(opts)
  else
    print(M.USAGE)
    return 2
  end
  if opts.json then
    local facts = {}
    for key, value in pairs(answer) do if key ~= "lines" then facts[key] = value end end
    print(json.encode(facts))
  else
    for _, line in ipairs(answer.lines or {}) do print(line) end
  end
  return tonumber(answer.code) or (answer.ok and 0 or 1)
end

M.resolve = resolve

return M
