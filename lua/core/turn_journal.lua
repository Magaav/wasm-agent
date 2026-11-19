-- The turn note's own store (mission change/turn-signal, #33: the operator's "ensure models output
-- their friction so we can focus and nail it").
--
-- The model ends every answer with a `<turn>` block - what hurt the reasoning, what removing it would
-- buy, and the one harness point to focus on. The block is the fleet's best evidence about its own
-- harness, and it must stay: what changes is where it lands.
--
-- Two facts decide the shape of this module:
--   1. the block is KEPT, every turn, and the harness REMOVES it from the visible answer. It therefore
--      never competes with an exact output format an operator asked for (`TOOLS_OK`, a JSON body, a
--      number): the answer is the answer, and the friction rides beside it.
--   2. it is STORED in the run journal with the run's own facts (session, mission, build, mode and the
--      three fields), so a reader can ask "what hurt, on which build, in which mode" without parsing
--      a transcript - and `wa turns --day` can print a day's themes and counts for docs/evolution.
--
-- The transcript keeps the block: lua/core/turnfeed.lua reads it from the message content and its
-- grouping is measured against that corpus. This module adds the journal row and answers the visible
-- text; it never rewrites the ledger.
local json = dofile("lua/vendor/json.lua")
local M = {}

M.SCHEMA_VERSION = 1
M.MAX_FIELD = 4000

-- The three fields, in the order the envelope asks for them. Kept here so the store, the reader and a
-- test name the same three things.
M.FIELDS = { "hurt", "buys", "focus" }

local deps = {}
local function dep(name)
  if not deps[name] then deps[name] = dofile("lua/core/" .. name .. ".lua") end
  return deps[name]
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Where the block starts, or nil. The tag has to OPEN A LINE: a message that mentions `<turn>` in a
-- sentence ("every session ends with a `<turn>` note") is talking about the section, not writing one.
-- (The same rule lua/core/turnfeed.lua measured on the real ledger; duplicated here rather than reached
-- for, because this module runs on every answer and must not load the grouping engine to do it.)
local function block_start(content)
  local from = 1
  while true do
    local at = content:find("<turn>", from, true)
    if not at then return nil end
    local line_start = (content:sub(1, at - 1):match(".*()\n") or 0) + 1
    if content:sub(line_start, at - 1):match("^%s*$") then return at end
    from = at + 1
  end
end

-- The note's own parse, by heading. Deliberately simpler than turnfeed's grouping: this answers the
-- three fields of one note, never whether two notes are about the same thing.
local HEADINGS = {
  { key = "hurt", label = "what hurt" },
  { key = "buys", label = "what it buys" },
  { key = "focus", label = "focus" },
}
local function heading(line)
  local bare = trim(line)
  for _ = 1, 3 do
    local stripped = bare:gsub("^[%-%*%+•–—]%s*", ""):gsub("^#+%s*", ""):gsub("^%d+[%.)]%s*", "")
    if stripped == bare then break end
    bare = stripped
  end
  local lower = bare:lower()
  for _, entry in ipairs(HEADINGS) do
    if lower:sub(1, #entry.label) == entry.label then
      local rest = bare:sub(#entry.label + 1)
      if rest == "" or rest:match("^[%*_%s]") or rest:match("^[—%-–:]") then
        local tail = rest
        for _ = 1, 4 do
          local stripped = tail:gsub("^[%*_%s]+", ""):gsub("^[—%-–:]+", "")
          if stripped == tail then break end
          tail = stripped
        end
        return entry.key, trim(tail)
      end
    end
  end
  return nil
end

-- Split one answer into the text a reader sees and the note it carried.
--   { visible = <answer without the block>, note = {hurt,buys,focus} | nil, block = <the raw block> }
--
-- Item 3 (review 19/11): the split keeps EVERY byte of answer text, before and after the block. The
-- first version cut the answer at the opening tag and dropped everything after the closing one, so
-- an answer of "<turn>..</turn>\n\n42" lost its 42 and a postscript after the block vanished - the
-- exact text the operator asked for, deleted to hide a note. The rule now:
--   * a CLOSED block is removed whole, wherever it sits, and the text on both sides is kept as it
--     was (blank lines the removal leaves behind are collapsed, so an answer that was only the block
--     reads as empty rather than as leftover whitespace);
--   * an UNCLOSED <turn> is NOT stripped: a model that ran out of output wrote text, not a section,
--     and guessing where that text ends is how an answer gets truncated. It stays in the visible
--     answer and carries no note.
-- Several blocks: every closed one is removed and its fields are collected in order.
function M.split(content)
  local text = type(content) == "string" and content or ""
  local visible, blocks, fields = {}, {}, { hurt = {}, buys = {}, focus = {} }
  local order = {}
  local cursor = 1
  while true do
    local start = block_start(text:sub(cursor))
    if not start then break end
    start = cursor + start - 1
    local body_at = start + 6
    local stop = text:find("</turn>", body_at, true)
    if not stop then break end -- unclosed: the rest is answer text, never a note
    local inner = text:sub(body_at, stop - 1)
    visible[#visible + 1] = text:sub(cursor, start - 1)
    blocks[#blocks + 1] = text:sub(start, stop + 6)
    local current = nil
    for line in (inner .. "\n"):gmatch("([^\n]*)\n") do
      local key, first = heading(line)
      if key then
        current = key
        if fields[key][1] == nil then order[#order + 1] = key end
        if first and first ~= "" then fields[key][#fields[key] + 1] = first end
      elseif current and trim(line) ~= "" then
        fields[current][#fields[current] + 1] = trim(line)
      end
    end
    cursor = stop + 7
  end
  visible[#visible + 1] = text:sub(cursor)
  local joined = table.concat(visible, "")
  local block = #blocks > 0 and table.concat(blocks, "\n") or nil
  local note = nil
  if block then
    if #order == 0 then
      -- One line and no headings - the shape the section itself asks for when nothing hurt.
      local flat = trim(block:gsub("<[^>]->", " "))
      if flat ~= "" then fields.hurt[1] = flat end
    end
    note = {
      hurt = trim(table.concat(fields.hurt, " ")),
      buys = trim(table.concat(fields.buys, " ")),
      focus = trim(table.concat(fields.focus, " ")),
    }
    if note.hurt == "" and note.buys == "" and note.focus == "" then note = nil end
    for _, key in ipairs(M.FIELDS) do
      if note and #note[key] > M.MAX_FIELD then note[key] = note[key]:sub(1, M.MAX_FIELD) end
    end
  end
  -- The blank lines a removed block leaves are the block's whitespace, not the answer's: a run of
  -- blank lines collapses to one, and the ends are trimmed. The answer's own bytes, before and
  -- after the block, are otherwise untouched.
  joined = joined:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
  return { visible = joined, note = note, block = block }
end

-- ---------------------------------------------------------------- the journal row

local ready = false
local SCHEMA = {
  [[CREATE TABLE IF NOT EXISTS turn_notes (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    run_id TEXT NOT NULL DEFAULT '',
    message_id TEXT NOT NULL DEFAULT '',
    mission TEXT NOT NULL DEFAULT '',
    build TEXT NOT NULL DEFAULT '',
    mode TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    hurts TEXT NOT NULL DEFAULT '',
    buys TEXT NOT NULL DEFAULT '',
    focus TEXT NOT NULL DEFAULT '',
    block TEXT NOT NULL DEFAULT '',
    at REAL NOT NULL
  )]],
  [[CREATE INDEX IF NOT EXISTS turn_notes_at_idx ON turn_notes(at)]],
  [[CREATE INDEX IF NOT EXISTS turn_notes_session_idx ON turn_notes(session_id, at)]],
}

local function sql(method, statement, params)
  local raw = host[method](statement, json.encode(params or {}))
  local value = raw
  if type(raw) == "string" then
    local ok, decoded = pcall(json.decode, raw)
    if not ok then error("turn_journal_store: unreadable answer") end
    value = decoded
  end
  if type(value) ~= "table" then error("turn_journal_store: no answer from " .. method) end
  if value.error then error(tostring(value.error)) end
  return value
end

function M.setup()
  if ready then return true end
  for _, statement in ipairs(SCHEMA) do sql("sql_exec", statement, {}) end
  ready = true
  return true
end

-- The build this run is a run OF: the release's own commit when the node can say, else empty. Read
-- once per note, and never guessed - an unknown build is empty, not "the node's HEAD".
function M.build_of()
  local ok, raw = pcall(function() return host.runtime_info and host.runtime_info() or nil end)
  if not ok or type(raw) ~= "string" then return "" end
  local decoded_ok, info = pcall(json.decode, raw)
  if not decoded_ok or type(info) ~= "table" then return "" end
  for _, key in ipairs({ "build", "build_commit", "commit", "version" }) do
    if type(info[key]) == "string" and info[key] ~= "" then return info[key] end
  end
  return ""
end

-- The mode the run worked in: code mode's own spelling (`only`, `first`, `codemode`...) because that
-- is the switch every friction note about the harness is really about.
function M.mode_of()
  local ok, mode = pcall(function() return dep("raw_code").mode() end)
  if not ok then return "" end
  return type(mode) == "string" and mode or ""
end

-- The mission, when the session has one: its objective or its title, first line only, bounded. Empty
-- when the session is a plain conversation - a note about a chat is not a note about a mission.
function M.mission_of(session_id)
  local ok, session = pcall(function() return dep("memory").session(session_id) end)
  if not ok or type(session) ~= "table" then return "" end
  local text = tostring(session.objective or "")
  if text == "" or text == "subagent" then text = tostring(session.title or "") end
  return (trim(text:match("^[^\n]*") or "")):sub(1, 200)
end

-- Record one note. Answers the row id, or nil and a named reason: a journal write that failed is
-- reported, never silently dropped, and never fails the answer it is about.
function M.record(note, ctx)
  ctx = ctx or {}
  if type(note) ~= "table" then return nil, "turn_note_missing" end
  local ok, id = pcall(function()
    M.setup()
    local row_id = host.uuid()
    sql("sql_exec", [[INSERT INTO turn_notes(id,session_id,run_id,message_id,mission,build,mode,model,
        hurts,buys,focus,block,at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)]], {
      row_id, tostring(ctx.session_id or ""), tostring(ctx.run_id or ""), tostring(ctx.message_id or ""),
      tostring(ctx.mission or ""), tostring(ctx.build or ""), tostring(ctx.mode or ""),
      tostring(ctx.model or ""), tostring(note.hurt or ""), tostring(note.buys or ""),
      tostring(note.focus or ""), tostring(ctx.block or ""), host.now(),
    })
    return row_id
  end)
  if not ok then return nil, "turn_journal_store: " .. tostring(id) end
  return id
end

-- Recent notes, newest last. `day` is a `YYYY-MM-DD` in this node's own zone; without one, the last
-- `limit` notes.
function M.recent(opts)
  opts = opts or {}
  M.setup()
  local limit = math.max(1, math.min(tonumber(opts.limit) or 20, 500))
  local rows
  if opts.day and opts.day ~= "" then
    local from, to = M.day_bounds(opts.day)
    if not from then return {} end
    rows = sql("sql_query", "SELECT * FROM turn_notes WHERE at>=? AND at<? ORDER BY at ASC LIMIT ?",
      { from, to, limit })
  elseif opts.session_id and opts.session_id ~= "" then
    rows = sql("sql_query", "SELECT * FROM turn_notes WHERE session_id=? ORDER BY at DESC LIMIT ?",
      { tostring(opts.session_id), limit })
    local reversed = {}
    for index = #rows, 1, -1 do reversed[#reversed + 1] = rows[index] end
    rows = reversed
  else
    rows = sql("sql_query", "SELECT * FROM turn_notes ORDER BY at DESC LIMIT ?", { limit })
    local reversed = {}
    for index = #rows, 1, -1 do reversed[#reversed + 1] = rows[index] end
    rows = reversed
  end
  for _, row in ipairs(rows) do row.at = tonumber(row.at) or 0 end
  return rows
end

-- Days since 1970-01-01 for a civil date, by arithmetic (Howard Hinnant's civil_from_days inverse).
-- Used instead of os.time: os.time reads a table in the PROCESS's zone, so a native node on -03 and a
-- guest on UTC would put the same "day" at two different instants. A day boundary must not depend on
-- which interpreter is asking.
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- The half-open bounds of one local day, as epoch seconds. Refuses a malformed day by name: a reader
-- who typed a date must not silently get "the last N notes" instead.
function M.day_bounds(day)
  local y, m, d = tostring(day or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil, "turn_day_must_be_YYYY-MM-DD" end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 or d < 1 or d > 31 then return nil, "turn_day_must_be_YYYY-MM-DD" end
  local utc_midnight = days_from_civil(y, m, d) * 86400
  -- The node's own zone, asked the way every other clock in this harness asks it, for the middle of
  -- the day in question: the offset of that instant, so a DST change is a different answer.
  local offset_minutes = 0
  local ok, clock = pcall(function() return dep("platform").local_clock(utc_midnight + 43200) end)
  if ok and type(clock) == "table" and tonumber(clock.utc_offset_minutes) then
    offset_minutes = tonumber(clock.utc_offset_minutes)
  end
  -- Local midnight = UTC midnight minus the offset (the offset says local = UTC + offset).
  local from = utc_midnight - offset_minutes * 60
  return from, from + 86400
end

return M
