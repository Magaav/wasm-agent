-- The LEDGER: one durable record of what happened to a branch, written by the thing that did it, and one
-- command that follows it.
--
-- WHY IT EXISTS (Victor, 22/11: "i like to start to make the landing built in ... so not need scripts, just
-- you subscribing to the events"). The landing loop of 21-22/11 was five shell scripts outside the product
-- (land-quick.sh, _quick/line.sh, install-local.sh, main-health.sh, and two sessions messaging each other
-- "it is green, land it"). Everything they knew lived in files one script wrote and another grepped, so
-- nothing could subscribe: an agent could only poll a log, and a session could only be told by a person.
--
-- This module is the product's half. A fact - a worker finished, a preflight went green, a landing merged,
-- pushed, installed, a main-health run came back red - is ONE ROW with ONE schema:
--
--   kind       whitelisted: "land" or "mission" (a typo is a refusal by name, never a second namespace)
--   mission    the branch's mission name (change/x -> x), or the mission the row is about
--   branch     the branch the row is about
--   sha        the commit the row is about (short or full, whatever the producer proved)
--   step       the step inside that kind: started, merged, pushed, installed, install-verified, main-health
--   result     the verdict: green, red, skipped, started, refused
--   at         epoch seconds, when the producer wrote it
--   detail     one sentence a human reads; never a model's claim about a step it did not run
--   source     who wrote it ("wa land", "wa events record", a script that names itself)
--
-- The row is stored in the node's own memory database beside the transcript, so it survives the process
-- that wrote it and is readable from another terminal, another session and another agent - which is the
-- whole point. `wa events` reads it and `wa events --follow` prints the new rows as they land.
--
-- SUBSCRIBING WITHOUT POLLING. Every row is also published on the bus as the topic `<kind>.<step>`
-- (selfloop.publish), which is the mechanism the wake table already has: a session asks once
-- (`wake {on = {"land.*"}}`) and is woken by the event, with the event's identity and never its text
-- (docs/SELF-LOOP.md). No new wake mechanism is built here; the existing rows do the work.
--
-- WHAT IT IS NOT. It is not a second journal: `wa land`'s journal is the state machine of ONE run (what
-- still has to happen), and this is the fact log of every run (what did happen). A landing step writes the
-- journal first and the ledger event after the step settled, so a row here is never a plan.

local json = dofile("lua/vendor/json.lua")

local M = {}

-- The kinds a producer may write. An allow-list, not a filter: an unknown kind is refused with its own
-- name, so a producer that misspells "land" gets `kind_unknown: lande` instead of an empty feed.
M.KINDS = { "land", "mission" }
local KIND = {}
for _, name in ipairs(M.KINDS) do KIND[name] = true end

-- The steps this product writes, per kind. A producer OUTSIDE this file (a script, another agent) may use
-- its own step name: the step is a free slug, because a new event in the loop must not wait for a release
-- of this list. It is the KIND that is closed, since that is what a subscriber filters on.
M.LAND_STEPS = { "started", "merged", "tests", "pushed", "main", "gate", "installed", "install-verified",
  "install-failed", "main-health", "done", "stopped", "refused" }

local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- The database, through the host's own sql capabilities: the same one memory.lua and selfloop.lua use, so a
-- row written here is in the ledger the operator's `wa` already reads.
local function sql(method, statement, params)
  local raw = host[method](statement, json.encode(params or {}))
  local value = raw
  if type(raw) == "string" then
    local ok, decoded = pcall(json.decode, raw)
    if not ok then error("event_ledger: unreadable answer from " .. method) end
    value = decoded
  end
  if type(value) ~= "table" then error("event_ledger: no answer from " .. method) end
  if value.error then error(tostring(value.error)) end
  return value
end
local function exec(statement, params) return sql("sql_exec", statement, params) end
local function query(statement, params) return sql("sql_query", statement, params) end

local ready = false
local SCHEMA = {
  [[CREATE TABLE IF NOT EXISTS ledger_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    at REAL NOT NULL,
    mission TEXT NOT NULL DEFAULT '',
    branch TEXT NOT NULL DEFAULT '',
    sha TEXT NOT NULL DEFAULT '',
    step TEXT NOT NULL DEFAULT '',
    result TEXT NOT NULL DEFAULT '',
    detail TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '',
    session TEXT NOT NULL DEFAULT '',
    data TEXT NOT NULL DEFAULT ''
  )]],
  -- The feed's own index: `--kind land --since 42` is one range scan, and the follow loop is the cheapest
  -- query this node runs (once every poll, for the length of a landing).
  [[CREATE INDEX IF NOT EXISTS ledger_events_kind_idx ON ledger_events(kind, id)]],
}

function M.setup()
  if ready then return true end
  for _, statement in ipairs(SCHEMA) do exec(statement, {}) end
  ready = true
  return true
end

local function slug(value) return tostring(value or ""):gsub("%s+", "-") end

-- HOW MANY WAKES ARE WAITING FOR AN EVENT (the subscription, docs/SELF-LOOP.md). A table that does not exist
-- (a ledger nobody has woken in) answers 0, and 0 is not an error: nothing is subscribed.
function M.subscribers()
  local ok, rows = pcall(query, "SELECT COUNT(*) AS n FROM self_wakes WHERE status='pending' AND due_at IS NULL AND on_topics<>'[]'", {})
  if not ok or type(rows) ~= "table" then return 0 end
  return tonumber(rows[1] and rows[1].n) or 0
end

-- WRITE ONE FACT. Answers the row it wrote (with the id the feed uses as a cursor), or a refusal table
-- (`{error = ...}`), which the caller decides what to do with: a step that cannot be recorded must not
-- pretend it was.
--
-- `fields.at` is the producer's clock when it has one; the host's clock otherwise.
function M.record(fields)
  fields = type(fields) == "table" and fields or {}
  local kind = trim(fields.kind)
  if not KIND[kind] then
    return { error = "kind_unknown: " .. (kind ~= "" and kind or "(empty)"),
      note = "the kinds this ledger carries are " .. table.concat(M.KINDS, " ") }
  end
  -- THE STEP IS VALIDATED, NOT REPAIRED. Slugging "not a slug" into "not-a-slug" would accept the producer's
  -- mistake and store a step nobody can filter on (measured 22/11 by this row's own case 2, which wrote the
  -- fact it exists to refuse).
  local step = trim(fields.step)
  if step == "" or step:find("[^%w%._%-]") then
    return { error = "step_invalid: " .. (step ~= "" and step or "(empty)"),
      note = "a step is one slug: letters, digits, dot, dash and underscore, with no spaces" }
  end
  local result = trim(fields.result)
  if result == "" then return { error = "result_required", note = "a fact with no verdict is not a fact" } end
  M.setup()
  -- WHOLE SECONDS: the host clock is a float in this build, and os.date refuses a fractional epoch
  -- (measured 22/11: the first row ever written crashed the text line on %d).
  local at = math.floor(tonumber(fields.at) or tonumber(host.now()) or 0)
  local row = {
    kind = kind, at = at,
    mission = trim(fields.mission) ~= "" and trim(fields.mission) or slug(fields.branch),
    branch = trim(fields.branch),
    sha = trim(fields.sha),
    step = step, result = result,
    detail = tostring(fields.detail or ""),
    source = trim(fields.source),
    session = trim(fields.session),
    data = type(fields.data) == "table" and json.encode(fields.data) or tostring(fields.data or ""),
  }
  exec([[INSERT INTO ledger_events(kind, at, mission, branch, sha, step, result, detail, source, session, data)
    VALUES(?,?,?,?,?,?,?,?,?,?,?)]],
    { row.kind, row.at, row.mission, row.branch, row.sha, row.step, row.result, row.detail,
      row.source, row.session, row.data })
  local inserted = query("SELECT last_insert_rowid() AS id", {})
  row.id = tonumber(inserted[1] and inserted[1].id) or 0
  -- THE EVENT WAKE (the rows that exist, docs/SELF-LOOP.md): the topic is `<kind>.<step>`, so a session
  -- that asked for `land.*` is woken by every landing fact and one that asked for `land.installed` by
  -- that one. Best effort by design: a wake layer that breaks must never lose the fact, which was already
  -- written above.
  --
  -- A PUBLISH WITH NO SUBSCRIBER IS NOT FREE: selfloop.publish walks the pending event wakes and, when the
  -- selfloop component is not installed, logs `publish served natively: component_missing` on the CLI's
  -- stderr - for every row of a landing. So the subscription is read first (one indexed query) and the
  -- publish happens only when a wake is actually waiting for it. A wake row is the subscription; a ledger
  -- with no subscriber needs no topic.
  local published = false
  if M.subscribers() > 0 then
    pcall(function()
      local selfloop = dofile("lua/core/selfloop.lua")
      local answer = selfloop.publish(row.kind .. "." .. row.step,
        { id = row.id, kind = row.kind, step = row.step, result = row.result, sha = row.sha,
          mission = row.mission, branch = row.branch }, { session_id = row.session })
      published = type(answer) == "table" and tonumber(answer.matched or 0) or 0
    end)
  end
  row.woke = tonumber(published) or 0
  return row
end

-- READ THE FEED. <opts>: `kinds` (array), `step`, `since` (an id: strictly newer), `limit` (newest last),
-- `newest` (the current cursor).
function M.read(opts)
  opts = type(opts) == "table" and opts or {}
  M.setup()
  local where, params = {}, {}
  local kinds = {}
  for _, kind in ipairs(type(opts.kinds) == "table" and opts.kinds or {}) do
    if not KIND[tostring(kind)] then return nil, "kind_unknown: " .. tostring(kind) end
    kinds[#kinds + 1] = "?"
    params[#params + 1] = tostring(kind)
  end
  if #kinds > 0 then where[#where + 1] = "kind IN (" .. table.concat(kinds, ",") .. ")" end
  if trim(opts.step) ~= "" then where[#where + 1] = "step = ?"; params[#params + 1] = slug(opts.step) end
  if tonumber(opts.since) then where[#where + 1] = "id > ?"; params[#params + 1] = tonumber(opts.since) end
  if trim(opts.sha) ~= "" then where[#where + 1] = "sha = ?"; params[#params + 1] = trim(opts.sha) end
  local clause = #where > 0 and (" WHERE " .. table.concat(where, " AND ")) or ""
  local limit = tonumber(opts.limit) or 50
  if limit < 1 then limit = 1 end
  params[#params + 1] = limit
  -- The newest `limit` rows, answered OLDEST FIRST: a feed is read forwards, and a follow loop that got a
  -- reversed page would print a landing's steps backwards.
  local rows = query("SELECT * FROM ledger_events" .. clause .. " ORDER BY id DESC LIMIT ?", params)
  local list = {}
  for index = #rows, 1, -1 do
    local row = rows[index]
    if type(row) == "table" then
      row.id = tonumber(row.id) or 0
      row.at = math.floor(tonumber(row.at) or 0)
      list[#list + 1] = row
    end
  end
  return list
end

-- The cursor `--follow` starts from: the newest id in the ledger now, so a follower prints what happens
-- NEXT and no history it did not ask for.
function M.newest(kinds)
  M.setup()
  local where, params = "", {}
  local list = {}
  for _, kind in ipairs(type(kinds) == "table" and kinds or {}) do
    list[#list + 1] = "?"
    params[#params + 1] = tostring(kind)
  end
  if #list > 0 then where = " WHERE kind IN (" .. table.concat(list, ",") .. ")" end
  local rows = query("SELECT MAX(id) AS id FROM ledger_events" .. where, params)
  return tonumber(rows[1] and rows[1].id) or 0
end

-- ONE ROW, TWO SHAPES: a text line for a person watching a terminal, one JSON object per line for an
-- outside agent. Neither drops a field: the text line names the time, the kind, the step, the verdict, the
-- branch, the sha and the detail, in that order, and the JSON is the row itself.
function M.text(row)
  local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(tonumber(row.at) or 0))
  local parts = { stamp, tostring(row.kind), tostring(row.where or row.step), tostring(row.result) }
  if tostring(row.branch or "") ~= "" then parts[#parts + 1] = "branch=" .. tostring(row.branch) end
  if tostring(row.sha or "") ~= "" then parts[#parts + 1] = "sha=" .. tostring(row.sha) end
  local line = table.concat(parts, "  ")
  local detail = trim(row.detail)
  if detail ~= "" then line = line .. "  " .. detail end
  return line
end

function M.json_line(row)
  return json.encode({
    id = tonumber(row.id) or 0, kind = tostring(row.kind or ""), at = math.floor(tonumber(row.at) or 0),
    step = tostring(row.step or ""), result = tostring(row.result or ""),
    mission = tostring(row.mission or ""), branch = tostring(row.branch or ""),
    sha = tostring(row.sha or ""), detail = tostring(row.detail or ""),
    source = tostring(row.source or ""),
  })
end

-- FOLLOW: print every new row, in order, until the deadline (a test's bound) or forever (a terminal).
-- <opts>: kinds, since, poll (seconds), seconds (stop after), as_json, limit, out (a printer function),
-- sleep (the seam a test replaces so a follow costs no wall clock).
function M.follow(opts)
  opts = type(opts) == "table" and opts or {}
  local print_row = opts.out or function(line) print(line) end
  local pause = opts.sleep or function(seconds) host.sleep(math.max(1, math.floor(seconds * 1000))) end
  local poll = tonumber(opts.poll) or 0.5
  if poll < 0.05 then poll = 0.05 end
  local budget = tonumber(opts.seconds)
  local polls = tonumber(opts.polls)
  local started = tonumber(host.now()) or 0
  local cursor = tonumber(opts.since) or M.newest(opts.kinds)
  local printed = 0
  local rounds = 0
  while true do
    local rows, why = M.read({ kinds = opts.kinds, step = opts.step, since = cursor, limit = tonumber(opts.limit) or 100 })
    if not rows then return nil, why end
    for _, row in ipairs(rows) do
      cursor = row.id
      printed = printed + 1
      print_row(opts.as_json and M.json_line(row) or M.text(row))
    end
    rounds = rounds + 1
    -- TWO WAYS TO END, both named: a wall-clock budget (--seconds, a test and a script that must finish) and
    -- a poll count (this file's own seam). Neither is a guess about when a landing is over: a follower that
    -- ends because it saw "installed" would miss the main-health row that follows it.
    if polls and rounds >= polls then return { printed = printed, cursor = cursor, rounds = rounds } end
    if budget and ((tonumber(host.now()) or 0) - started) >= budget then
      return { printed = printed, cursor = cursor, rounds = rounds }
    end
    pause(poll)
  end
end

-- ---------------------------------------------------------------- the CLI (`wa events`)
local function split(value)
  local rows = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    local name = trim(item)
    if name ~= "" then rows[#rows + 1] = name end
  end
  return rows
end

local USAGE = {
  "wa events [--kind land,mission] [--step <name>] [--since <id>] [--limit N] [--backlog N] [--json]",
  "          [--follow] [--seconds N]   read the ledger; --follow prints new rows as they land",
  "wa events record --kind <land|mission> --step <name> --result <verdict> [--mission m] [--branch b]",
  "          [--sha s] [--detail text] [--source who]   write one fact (a script's own step)",
  "Kinds: " .. table.concat(M.KINDS, ", ") .. ". Steps are free slugs; the landing writes " ..
    table.concat(M.LAND_STEPS, " ") .. ".",
}

local function usage()
  for _, line in ipairs(USAGE) do print(line) end
end

-- Returns an exit code. 0 read/wrote, 1 refused, 2 usage.
function M.cli(argv)
  argv = type(argv) == "table" and argv or {}
  if argv[1] ~= "events" then return nil end
  local options = { kinds = {} }
  local index = 2
  local function value(flag)
    local next_value = argv[index + 1]
    if type(next_value) ~= "string" or next_value == "" or next_value:sub(1, 2) == "--" then
      print("wa events: " .. flag .. " needs a value")
      return nil
    end
    return next_value
  end
  while argv[index] do
    local flag = tostring(argv[index])
    if flag == "record" then options.record = true; index = index + 1
    elseif flag == "--kind" then
      local given = value(flag); if not given then return 2 end
      for _, name in ipairs(split(given)) do options.kinds[#options.kinds + 1] = name end
      index = index + 2
    elseif flag == "--step" then
      local given = value(flag); if not given then return 2 end
      options.step = given; index = index + 2
    elseif flag == "--result" then
      local given = value(flag); if not given then return 2 end
      options.result = given; index = index + 2
    elseif flag == "--mission" then
      local given = value(flag); if not given then return 2 end
      options.mission = given; index = index + 2
    elseif flag == "--branch" then
      local given = value(flag); if not given then return 2 end
      options.branch = given; index = index + 2
    elseif flag == "--sha" then
      local given = value(flag); if not given then return 2 end
      options.sha = given; index = index + 2
    elseif flag == "--detail" then
      local given = value(flag); if not given then return 2 end
      options.detail = given; index = index + 2
    elseif flag == "--source" then
      local given = value(flag); if not given then return 2 end
      options.source = given; index = index + 2
    elseif flag == "--since" then
      local given = value(flag); if not given then return 2 end
      if not tonumber(given) then print("wa events: --since takes an event id (a number), not " .. given); return 2 end
      options.since = tonumber(given); index = index + 2
    elseif flag == "--limit" then
      local given = value(flag); if not given then return 2 end
      if not tonumber(given) then print("wa events: --limit takes a number"); return 2 end
      options.limit = tonumber(given); index = index + 2
    elseif flag == "--backlog" then
      local given = value(flag); if not given then return 2 end
      if not tonumber(given) then print("wa events: --backlog takes a number"); return 2 end
      options.backlog = tonumber(given); index = index + 2
    elseif flag == "--seconds" then
      local given = value(flag); if not given then return 2 end
      if not tonumber(given) then print("wa events: --seconds takes a number"); return 2 end
      options.seconds = tonumber(given); index = index + 2
    elseif flag == "--poll" then
      local given = value(flag); if not given then return 2 end
      if not tonumber(given) then print("wa events: --poll takes seconds"); return 2 end
      options.poll = tonumber(given); index = index + 2
    elseif flag == "--follow" then options.follow = true; index = index + 1
    elseif flag == "--json" then options.as_json = true; index = index + 1
    elseif flag == "--help" or flag == "-h" then usage(); return 0
    else
      print("wa events: unknown option " .. flag .. "; nothing was read")
      return 2
    end
  end
  for _, kind in ipairs(options.kinds) do
    if not KIND[kind] then
      print("wa events: refused(kind_unknown): " .. kind .. " - the kinds are " .. table.concat(M.KINDS, ", "))
      return 2
    end
  end
  if options.record then
    if not options.kinds[1] then print("wa events record: --kind is required (land or mission)"); return 2 end
    if not options.step or not options.result then
      print("wa events record: --step and --result are required"); return 2
    end
    local row = M.record({ kind = options.kinds[1], step = options.step, result = options.result,
      mission = options.mission, branch = options.branch, sha = options.sha, detail = options.detail,
      source = options.source ~= nil and options.source or "wa events record" })
    if row.error then
      print("wa events record: refused(" .. tostring(row.error) .. ")" .. (row.note and (" - " .. tostring(row.note)) or ""))
      return 1
    end
    print(options.as_json and M.json_line(row) or M.text(row))
    return 0
  end
  if options.follow then
    -- WHAT A FOLLOWER SEES FIRST. With no --since it starts at the ledger's current end: a follower prints
    -- what happens next, and a terminal opened beside a landing is about that landing. --backlog n prints
    -- the n rows before the cursor first, for the terminal that opened one landing too late.
    local print_row = function(line) print(line) end
    if options.backlog and options.backlog > 0 then
      local rows = M.read({ kinds = options.kinds, step = options.step, limit = options.backlog })
      if not rows then print("wa events: refused(kind_unknown)"); return 2 end
      for _, row in ipairs(rows) do print_row(options.as_json and M.json_line(row) or M.text(row)) end
    end
    local ok, answer = M.follow({ kinds = options.kinds, step = options.step, since = options.since,
      limit = options.limit, seconds = options.seconds, poll = options.poll, as_json = options.as_json,
      out = print_row })
    if not ok and answer then
      print("wa events: refused(" .. tostring(answer) .. ")")
      return 1
    end
    return 0
  end
  local rows, why = M.read({ kinds = options.kinds, step = options.step, since = options.since,
    limit = options.limit or 20 })
  if not rows then
    print("wa events: refused(" .. tostring(why) .. ")")
    return 2
  end
  for _, row in ipairs(rows) do print(options.as_json and M.json_line(row) or M.text(row)) end
  return 0
end

return M
