-- /sessions: the sessions as a balloon. Pages built here, opened by lua/core/chat.lua, switched
-- from there (sessions-is-a-balloon, Victor + Fable 26/11).
--
-- THE SHAPE IS THE MISSION'S:
--   * page 1 is THIS session (name, short id, state), then the others: running first, then most
--     recently used; each row is name (or the first words of its first message), state, last activity,
--     message count, node;
--   * the factory's mission/worker sessions go under their own heading, collapsed to a count;
--   * a row carries its FULL id in `copy` - a click copies it, and the caller's key does the same;
--   * nothing here leaves this node: the local list only, never another node's.
-- The budget is Victor's: first paint under 100 ms with 200 sessions, so the whole page is built from
-- ONE list read (memory.list_sessions, which already carries each session's derived state) plus ONE
-- read of the unnamed sessions' first lines - never a query per row.
local memory = dofile("lua/core/memory.lua")
local view = dofile("lua/core/cli_view.lua")

local M = {}

-- The mission's first-paint budget, in milliseconds. The row asserts it; this module records how long
-- it took so the assertion is about the page, not about a guess.
M.BUDGET_MS = 100

-- A session's name: its title, or the first words of its first message, or its short id.
local function clip(text, cells)
  local out, used = {}, 0
  for _, ch in utf8.codes(tostring(text or "")) do
    local width = view.cell and view.cell(utf8.char(ch)) or 1
    if used + width > cells then break end
    out[#out + 1] = utf8.char(ch)
    used = used + width
  end
  return table.concat(out)
end

function M.short_id(id)
  id = tostring(id or "")
  return #id > 8 and (id:sub(1, 8) .. "-\u{2026}") or id
end

-- "just now" / "3 min ago" / "2 h ago" - the same words the status panel's age uses.
function M.since_text(seconds)
  local s = tonumber(seconds) or 0
  if s < 45 then return "just now" end
  if s < 5400 then return string.format("%d min ago", math.floor((s + 30) / 60)) end
  if s < 129600 then return string.format("%d h ago", math.floor(s / 3600 + 0.5)) end
  return string.format("%d d ago", math.floor(s / 86400 + 0.5))
end

-- A session with an objective other than the chat's own is the factory's: a mission or a worker.
local function is_worker(row)
  local objective = tostring(row.objective or "")
  if objective ~= "" and objective ~= "chat" then return true end
  return tostring(row.mode or "default") ~= "default"
end

local function state_text(row)
  local state = tostring(row.state or "")
  if state == "" or state == "empty" then return "no messages yet" end
  if state == "unfinished" then return "waits for a person" end
  return state
end

-- The rows, ordered: this session first, then the others running-or-recent, then the workers.
-- `filter` (lower case) keeps only rows whose name matches.
function M.rows(opts)
  opts = opts or {}
  local now = tonumber(opts.now) or (host.now and host.now()) or os.time()
  local listed = memory.list_sessions(opts.user_id or "master", opts.limit or 200, { states = true }) or {}
  local here, chat, workers = nil, {}, {}
  for _, row in ipairs(listed) do
    if row.id == opts.session_id then here = row
    elseif is_worker(row) then workers[#workers + 1] = row
    else chat[#chat + 1] = row end
  end
  local running_first = function(a, b)
    local ar = tostring(a.state or "") == "running" and 0 or 1
    local br = tostring(b.state or "") == "running" and 0 or 1
    if ar ~= br then return ar < br end
    return (tonumber(a.updated_at) or 0) > (tonumber(b.updated_at) or 0)
  end
  table.sort(chat, running_first)
  table.sort(workers, running_first)
  local rows = {}
  if here then rows[#rows + 1] = { row = here, here = true } end
  for _, row in ipairs(chat) do rows[#rows + 1] = { row = row } end
  if #workers > 0 then rows[#rows + 1] = { worker_heading = #workers } end
  for _, row in ipairs(workers) do rows[#rows + 1] = { row = row, worker = true } end
  if opts.filter and opts.filter ~= "" then
    local needle = tostring(opts.filter):lower()
    local kept = {}
    for _, entry in ipairs(rows) do
      if entry.worker_heading then kept[#kept + 1] = entry
      elseif tostring(entry.row.title or ""):lower():find(needle, 1, true) then kept[#kept + 1] = entry end
    end
    rows = kept
  end
  return rows, #listed, now
end

-- The page the balloon shows: one option per session, its hint carrying state, age, count and node,
-- and its label the name. The full id rides in `copy`, which is what a click copies.
function M.page(opts)
  local started = os.clock()
  local rows, total, now = M.rows(opts)
  local options = {}
  -- The session the reader came from, marked and FIRST: one key (Enter) goes back to it.
  if opts.back and opts.back ~= "" and opts.back ~= opts.session_id then
    local from = memory.session(opts.back)
    local from_name = from and tostring(from.title or "") or ""
    if from_name == "" then from_name = "(unnamed) " .. M.short_id(opts.back) end
    options[#options + 1] = {
      label = "\u{2190} back to " .. clip(from_name, 40),
      hint = "where you came from",
      session = opts.back,
      origin = true,   -- NOT `back`: the balloon reads that as "pop a page" and Enter would cancel.
    }
  end
  for _, entry in ipairs(rows) do
    if entry.worker_heading then
      options[#options + 1] = { label = string.format("  %d mission session%s", entry.worker_heading,
        entry.worker_heading == 1 and "" or "s"), hint = "under this heading", action = "collapse" }
    else
      local row = entry.row
      local name = tostring(row.title or "")
      if name == "" then name = "(unnamed) " .. M.short_id(row.id) end
      local age = M.since_text(math.max(0, now - (tonumber(row.updated_at) or now)))
      options[#options + 1] = {
        label = (entry.here and "* " or "  ") .. clip(name, 44),
        hint = string.format("%s  %s  %d msg  %s", state_text(row), age,
          tonumber(row.message_count) or 0, tostring(row.node_id or "") ~= "" and row.node_id or "this node"),
        copy = row.id,
        session = row.id,
        worker = entry.worker or nil,
      }
    end
  end
  local page = {
    title = string.format("Sessions (%d%s)", #options, total > #options and (" of " .. total) or ""),
    options = options,
    per = 14,
  }
  return page, os.clock() - started
end

-- Open the page (a balloon) or, for a pipe, print the plain list. The answer is the balloon's:
-- {action = "select", index, session?} with the chosen row, {action = "run", line} for a row that
-- queued a line, or {action = "cancel"}. Nil when there was no balloon to open.
function M.run(io, opts)
  local page = M.page(opts)
  if io and io.show then
    local answer = io.show({page})
    if type(answer) == "table" then return answer end
    return nil
  end
  if io and io.print then
    -- A pipe gets one line per session, the way `wa sessions` prints them: the id first, then the
    -- name, so the output is greppable and pastable.
    for _, option in ipairs(page.options) do
      if option.session then
        io.print(string.format("%s  %s", option.session, (tostring(option.label):gsub("^%s*%*?%s*", ""))))
      end
    end
  end
  return nil
end

return M
