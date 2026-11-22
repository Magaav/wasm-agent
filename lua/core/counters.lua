-- The three numbers that decide the next mission (21/11; docs/CODEMODE.md, "The three counters").
--
-- Telemetry, not policy: each is one increment on a path that already runs, stored in one
-- `memory.meta` document so /stats can read it without a schema change, and nothing here changes a
-- decision the node makes.
--
--   wake_only_round     a model step whose only input was a settled handle. Counted where a handle
--                       wake runs its turn (lua/core/selfloop.lua), which is exactly that step.
--   script_cut_at_cap   a script that got a `pending` answer - its work outlived the wait it was
--                       given - or hit its deadline with lines still to run. This build measures the
--                       first half at the script's own end (one increment per script, never per
--                       call); the deadline half is NOT counted yet and is named here rather than
--                       silently folded in.
--   handle_mishandled   a script that used a pending answer as a result (the harness's
--                       pending-value TypeError) or that ended on the wait-never-settles bound
--                       because it polled one handle instead of ending its step.
--
-- WHERE IT IS, AND HOW TO READ IT (22/11, seat-5-10-check items 2 and 3). One row of the node's own
-- ledger's `meta` table, named M.KEY, and `wa counters` prints it: the three totals, and for each of
-- the last N calendar days what that day counted. A script that wants the numbers says
-- `wa counters --json` and reads the same document.
--
-- A DAY BOOK, because "high" is a rate and not a total: a cumulative number cannot tell an operator
-- whether the last three days produced three wake-only rounds or one, so every bump also increments
-- that day's bucket on the node's own clock, the newest M.DAYS_KEPT days are kept, and a day the
-- store never saw is reported as NOT RECORDED - never as 0. The three names and read() are unchanged:
-- the day book is added beside the totals, never in place of them.
local json = dofile("lua/vendor/json.lua")
local M = {}

-- One document, one version: a later mission that redefines a counter writes a new key instead of
-- reinterpreting this one. Adding `days` beside the counts is not a redefinition - a reader of the old
-- shape (the three names) sees exactly what it saw before.
M.KEY = "codemode.counters.v1"
M.NAMES = { "wake_only_round", "script_cut_at_cap", "handle_mishandled" }
-- What each number means, in the words the operator reads in `wa counters`.
M.LABEL = {
  wake_only_round = "a model step whose only input was a settled handle",
  script_cut_at_cap = "a script was told \"not yet\" (its work outlived the wait) - the pending half only",
  handle_mishandled = "a script used a pending answer as a result, or ended on the wait-never-settles bound",
}
-- The day book is bounded so the document stays small: the newest N calendar days.
M.DAYS_KEPT = 30
M.DAYS_SHOWN = 3

local memory
local function store()
  if not memory then memory = dofile("lua/core/memory.lua"); memory.setup() end
  return memory
end

local function known(name)
  for _, candidate in ipairs(M.NAMES) do if candidate == name then return true end end
  return false
end

-- The whole document as stored. Absent, unreadable or the wrong shape is an EMPTY document, not an
-- error: a counter nothing has bumped is 0 (see read), and a call site must never fail a turn because
-- telemetry could not be decoded.
local function document()
  local raw = store().meta_get(M.KEY)
  if type(raw) == "string" and raw ~= "" then
    local ok, value = pcall(json.decode, raw)
    if ok and type(value) == "table" then return value end
  end
  return {}
end

-- A calendar day, on the node's own clock: the zone the operator reads the report in. Noon-anchored
-- arithmetic in window() below keeps a daylight-saving hour from renaming a day.
function M.day_of(now)
  local seconds = tonumber(now) or host.now()
  return os.date("%Y-%m-%d", math.floor(seconds))
end

-- The three counts, always three numbers: a counter nothing has bumped is 0, not absent. The day book
-- is deliberately NOT in this answer - every existing reader wants the three numbers.
function M.read()
  local decoded = document()
  local out = {}
  for _, name in ipairs(M.NAMES) do
    out[name] = tonumber(decoded[name]) or 0
  end
  return out
end

-- day -> { the three numbers }. Only days this store actually wrote are present.
function M.book()
  local decoded = document()
  local stored = type(decoded.days) == "table" and decoded.days or {}
  local out = {}
  for day, counts in pairs(stored) do
    if type(day) == "string" and day:match("^%d%d%d%d%-%d%d%-%d%d$") and type(counts) == "table" then
      local one = {}
      for _, name in ipairs(M.NAMES) do one[name] = tonumber(counts[name]) or 0 end
      out[day] = one
    end
  end
  return out
end

-- The last `count` calendar days, today first: { { day=, recorded=, <name>=<number>, ... }, ... }.
-- `recorded` is what makes "not recorded" sayable: a day with no bucket is unknown, and reporting it
-- as three zeros would claim three quiet days that nobody measured.
function M.window(count, now)
  local days = math.max(1, math.floor(tonumber(count) or M.DAYS_SHOWN))
  local book = M.book()
  local anchor = type(now) == "table" and now or os.date("*t", math.floor(tonumber(now) or host.now()))
  local out = {}
  for back = 0, days - 1 do
    local probe = os.date("*t", os.time(anchor))
    probe.hour, probe.min, probe.sec = 12, 0, 0
    local day = os.date("%Y-%m-%d", os.time(probe) - back * 86400)
    local row = { day = day, recorded = book[day] ~= nil }
    for _, name in ipairs(M.NAMES) do row[name] = book[day] and book[day][name] or 0 end
    out[#out + 1] = row
  end
  return out
end

-- One increment. An unknown name is refused by returning nil rather than creating a key nobody reads.
-- `opts.now` exists for a test that has to name the day it is counting into.
function M.bump(name, by, opts)
  if not known(name) then return nil end
  local amount = tonumber(by) or 1
  local decoded = document()
  local counts = {}
  for _, candidate in ipairs(M.NAMES) do counts[candidate] = tonumber(decoded[candidate]) or 0 end
  counts[name] = counts[name] + amount
  local book = type(decoded.days) == "table" and decoded.days or {}
  local day = M.day_of(type(opts) == "table" and opts.now or nil)
  local today = type(book[day]) == "table" and book[day] or {}
  today[name] = (tonumber(today[name]) or 0) + amount
  book[day] = today
  -- Bound the book: the newest M.DAYS_KEPT days, oldest dropped first (a bounded document forever).
  local dated = {}
  for key in pairs(book) do
    if type(key) == "string" and key:match("^%d%d%d%d%-%d%d%-%d%d$") then dated[#dated + 1] = key end
  end
  table.sort(dated)
  while #dated > M.DAYS_KEPT do book[table.remove(dated, 1)] = nil end
  decoded[name] = counts[name]
  for _, candidate in ipairs(M.NAMES) do decoded[candidate] = counts[candidate] end
  decoded.days = book
  store().meta_set(M.KEY, json.encode(decoded))
  return counts[name]
end

-- Where the document lives, for the report's own first line: the ledger path the host resolved.
function M.where()
  return "meta[" .. M.KEY .. "] in " .. tostring(host.getenv("WASM_AGENT_DB") or "")
end

-- The whole document, for `--json`.
function M.snapshot(opts)
  opts = opts or {}
  local totals = M.read()
  local days = M.window(opts.days or M.DAYS_SHOWN, opts.now)
  local book = M.book()
  local out = { key = M.KEY, where = M.where() }
  for _, name in ipairs(M.NAMES) do out[name] = totals[name] end
  out.window = days
  out.days = book
  out.kept_days = M.DAYS_KEPT
  return out
end

function M.report(opts)
  opts = opts or {}
  local totals = M.read()
  local days = M.window(opts.days or M.DAYS_SHOWN, opts.now)
  print("counters - the three numbers the next mission is planned from (docs/CODEMODE.md)")
  print("  stored in " .. M.where())
  print("")
  print("cumulative, since this store was first written:")
  for _, name in ipairs(M.NAMES) do
    print(string.format("  %-18s %8d   %s", name, totals[name], M.LABEL[name] or ""))
  end
  print("")
  print(string.format("last %d calendar day(s), on this node's own clock:", #days))
  local any = false
  for _, row in ipairs(days) do
    if row.recorded then
      any = true
      local parts = {}
      for _, name in ipairs(M.NAMES) do parts[#parts + 1] = string.format("%s %d", name, row[name]) end
      print(string.format("  %s  %s", row.day, table.concat(parts, "  ")))
    else
      print(string.format("  %s  not recorded (this store kept no day before it learned to; nothing"
          .. " is claimed about that day)", row.day))
    end
  end
  if not any then
    print("  (no day recorded yet: nothing was counted in this window)")
  end
  return 0
end

-- `wa counters [--days N] [--json]`. READ-ONLY: it opens no wake, spends no model call, changes no
-- decision - it prints the document the counters already wrote.
function M.cli(args)
  local opts, as_json = {}, false
  for index = 2, #args do
    local word = tostring(args[index] or "")
    local days = word:match("^%-%-days=(.+)$")
    if days then opts.days = tonumber(days)
    elseif word == "--days" and args[index + 1] then opts.days = tonumber(args[index + 1])
    elseif word == "--json" then as_json = true
    elseif word == "--help" or word == "-h" then
      print("wa counters [--days N] [--json]   the three counters, cumulative and per calendar day")
      return 0
    end
  end
  if opts.days and (opts.days < 1 or opts.days > M.DAYS_KEPT) then
    print(string.format("counters: --days must be 1..%d (the store keeps %d days)", M.DAYS_KEPT, M.DAYS_KEPT))
    return 2
  end
  if as_json then print(json.encode(M.snapshot(opts))); return 0 end
  return M.report(opts)
end

return M

