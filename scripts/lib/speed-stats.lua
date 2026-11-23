-- The one place that decides a speed number (change/speed-board, 22/11).
--
-- Every row of the speed board is ONE NUMBER PER COMMIT, and this module is what turns a handfull of
-- samples into it and what calls a number RED. It is a plain Lua library with no host and no network so
-- that the decision can be tested on its own (scripts/test-speed-stats.lua): a rule that lives in a
-- shell pipeline is a rule nobody can test.
--
-- The rules, and why each one is here:
--
--   * MEDIAN, not mean, of the samples: one sample taken while a build started is not the row's cost,
--     and a mean is exactly the number such a sample moves. The 22/11 flakes were single samples with
--     an absolute bound (scripts/test-start-instant.lua, gap < 1 s) failing under load.
--   * LOAD IS RECORDED WITH EVERY ROW, and a number is only compared with numbers taken at a
--     COMPARABLE load (within 25% of the baseline's load, plus half a unit of slack, so 0.6 against
--     1.1 still compares and 1.1 against 12 does not). A row measured at load 12 on a 16-core machine
--     is a property of the machine, not a regression of the commit.
--   * RED IS "more than 20% slower than the BEST of the last 10 commits at comparable load", never
--     "slower than the commit before it": a single noisy neighbour would otherwise name every second
--     commit. The best is the floor the code has already reached; drifting above it is the regression.
--   * NOTHING IS EVER GREEN BY ABSENCE (rule 1). A row with no samples is `unavailable` or `unknown`
--     and is printed with its reason; it is never counted as passing, and it never makes a RED row
--     disappear.
--   * A LIVE ROW WITH NO NUMBER IS A RED ROW (23/11). The four live rows are what main must have a number
--     for: when a probe could not measure, or the machine was too busy to try, the board names that row
--     RED with its reason instead of letting a table of dashes read as fine. The two RECORD rows are
--     different: no landing has happened since the record started, and that is not a red board.
--   * THE WINDOW IS TEN MEASURED COMMITS. A commit with no number for a row is not a baseline and does
--     not consume the window: otherwise a run of holes hides the last real numbers (23/11: eight commits
--     of `unavailable` after 8862b600 would have hidden its 321 ms start from every comparison).
--
-- The history file (one JSON line per commit on main, oldest first) is the record:
--   {"schema":1,"sha":"<40>","at":"2026-11-22T21:20:00Z","load":1.2,"cores":16,
--    "rows":{"start":{"ms":412,"samples":[430,412,405],"load":1.2,"state":"ok"}, ...}}
local M = {}

M.SCHEMA = 1
-- The window and the threshold are the brief's: the best of the last ten commits, more than 20% slower
-- is red.
M.WINDOW = 10
M.RED_PCT = 20
-- A load is comparable to another when it is within this share of it, plus this much slack.
M.LOAD_SHARE = 0.25
M.LOAD_SLACK = 0.5
-- A row measured while the machine is above this many load units per core is not measured at all: the
-- harness records `guarded` and the reason instead of a number nobody can compare (1.5 per core: the
-- 19/11 incident reached 105 on 16 cores and every timing row failed at random).
M.LOAD_CEILING_PER_CORE = 1.5

-- The rows, in the order a reader wants them: the things Victor feels first, then the two records.
M.ROWS = { 'start', 'first_token', 'tool_roundtrip', 'remote_roundtrip', 'landing', 'release' }
-- The rows that are MEASURED on this machine, and therefore must have a number on every commit: a hole
-- in one of these is a RED row of the board (M.rows below). The other two are records of events.
M.LIVE = { start = true, first_token = true, tool_roundtrip = true, remote_roundtrip = true }
M.LABELS = {
  start = 'cold start (process -> key accepted, pty)',
  first_token = 'first token (Enter -> first model byte)',
  tool_roundtrip = 'tool round trip (run(code) -> read a file)',
  remote_roundtrip = 'remote round trip (scratch peer, local)',
  landing = 'landing (branch approved -> Local is evolved)',
  release = 'release (cut -> published)',
}

local function number(value)
  local n = tonumber(value)
  if n == nil or n ~= n then return nil end
  return n
end
M.number = number

-- ---- the samples ---------------------------------------------------------------------------------
function M.median(values)
  local sorted = {}
  for _, value in ipairs(values or {}) do
    local n = number(value)
    if n then sorted[#sorted + 1] = n end
  end
  if #sorted == 0 then return nil end
  table.sort(sorted)
  local middle = math.floor(#sorted / 2)
  if #sorted % 2 == 1 then return sorted[middle + 1] end
  -- An even count: the mean of the two middle samples, rounded. Never the first or the last of them,
  -- which is what a single outlier would become.
  return math.floor((sorted[middle] + sorted[middle + 1]) / 2 + 0.5)
end

function M.load_comparable(a, b)
  local left, right = number(a), number(b)
  if not left or not right then return false end
  local reference = math.max(left, right)
  return math.abs(left - right) <= M.LOAD_SHARE * reference + M.LOAD_SLACK
end

function M.load_ceiling(cores)
  local n = number(cores) or 1
  if n < 1 then n = 1 end
  return M.LOAD_CEILING_PER_CORE * n
end

-- ---- one entry -----------------------------------------------------------------------------------
-- A row takes the shape { samples = {...}, ms = <median>, load = <number>, state = 'ok'|'unavailable'
-- |'guarded'|'unknown', reason = '<why>' }. `finish` derives ms from the samples so no caller can write
-- a median of its own choosing.
function M.row(samples, load, state, reason)
  local row = { load = number(load), state = state or 'ok' }
  if reason then row.reason = tostring(reason) end
  if row.state == 'ok' then
    row.samples = {}
    for _, sample in ipairs(samples or {}) do
      local n = number(sample)
      if n then row.samples[#row.samples + 1] = n end
    end
    row.ms = M.median(row.samples)
    if row.ms == nil then row.state = 'unknown'; row.reason = row.reason or 'no samples' end
  end
  return row
end

-- The harness collects samples and hands the entry here: the MEDIAN IS THIS FILE'S (see M.median for why),
-- so no caller can write a number of its own choosing - and a row without samples becomes 'unknown' with a
-- reason instead of a zero that would read as a fast row (rule 1).
function M.finish(entry)
  if type(entry) ~= 'table' then return entry end
  entry.rows = entry.rows or {}
  for name, row in pairs(entry.rows) do
    if type(row) == 'table' then
      if row.state == nil then row.state = 'ok' end
      if row.state == 'ok' then
        local ms = M.median(row.samples or {})
        if ms then
          row.ms = ms
        else
          row.state = 'unknown'
          row.reason = row.reason or ('the row has no samples: ' .. tostring(name))
        end
      end
    end
  end
  return entry
end

-- ---- the judgement -------------------------------------------------------------------------------
-- `history` is the entries from the file, oldest first, and MUST NOT contain `entry` itself (the caller
-- holds the file, so replacing a commit's own line is the caller's job - see write_history).
function M.judge(history, entry)
  local verdict = { schema = M.SCHEMA, sha = entry.sha, at = entry.at, load = number(entry.load),
    cores = number(entry.cores), rows = {}, red = {}, notes = {} }
  local mine = entry.rows or {}
  local previous = {}
  for _, past in ipairs(history or {}) do
    if past and past.sha and past.sha ~= entry.sha then previous[#previous + 1] = past end
  end
  for _, name in ipairs(M.ROWS) do
    local row = mine[name]
    local out = { name = name, label = M.LABELS[name] or name }
    if type(row) ~= 'table' or row.state ~= 'ok' or not number(row.ms) then
      out.state = (type(row) == 'table' and row.state) or 'unknown'
      out.reason = (type(row) == 'table' and row.reason) or 'the commit has no number for this row'
      out.ms = type(row) == 'table' and number(row.ms) or nil
      out.load = type(row) == 'table' and number(row.load) or nil
      -- A LIVE ROW WITH NO NUMBER IS RED (23/11): the reason is named and the row is in verdict.red, so
      -- main-health prints it and status.sh shows it as RED. A record row (landing, release) may
      -- legitimately be unknown - no landing has happened for a new commit - and is NOT red.
      if M.LIVE[name] then
        out.hole = true
        out.red = true
        verdict.red[#verdict.red + 1] = out
      end
      verdict.rows[#verdict.rows + 1] = out
    else
      out.state = 'ok'
      out.ms = number(row.ms)
      out.load = number(row.load) or number(entry.load)
      -- The window is the last WINDOW commits, THEN the comparable loads among them, in that order: a
      -- quiet baseline after a storm of busy commits is still the baseline.
      local best_ms, best_sha, comparable = nil, nil, 0
      for index = #previous, 1, -1 do
        if comparable >= M.WINDOW then break end
        local past = previous[index]
        local old = (past.rows or {})[name]
        if type(old) == 'table' and old.state == 'ok' and number(old.ms) then
          local old_load = number(old.load) or number(past.load)
          if M.load_comparable(out.load, old_load) then
            comparable = comparable + 1
            if best_ms == nil or number(old.ms) < best_ms then best_ms, best_sha = number(old.ms), past.sha end
          end
        end
      end
      out.comparable = comparable
      if best_ms == nil then
        out.state = 'no_baseline'
        out.reason = 'no commit in the last ' .. M.WINDOW .. ' has this row at a comparable load'
      else
        out.best_ms = best_ms
        out.best_sha = best_sha
        out.delta_pct = ((out.ms - best_ms) / best_ms) * 100
        out.red = out.delta_pct > M.RED_PCT
        if out.red then verdict.red[#verdict.red + 1] = out end
      end
      verdict.rows[#verdict.rows + 1] = out
    end
  end
  return verdict
end

-- The change against the commit before this one in the file, per row: the second line Victor reads
-- ("the speed table for the installed commit and the change against the previous one").
function M.deltas(history, entry)
  local previous = nil
  for index = #(history or {}), 1, -1 do
    local past = history[index]
    if past and past.sha == entry.sha then
      previous = history[index - 1]
      break
    end
  end
  if previous == nil and #(history or {}) > 0 and history[#history].sha ~= entry.sha then
    previous = history[#history]
  end
  local out = {}
  for _, name in ipairs(M.ROWS) do
    local now = (entry.rows or {})[name]
    local before = ((previous or {}).rows or {})[name]
    if type(now) == 'table' and now.state == 'ok' and number(now.ms) then
      local row = { name = name, ms = number(now.ms), load = number(now.load) or number(entry.load),
        previous_sha = (previous or {}).sha }
      if type(before) == 'table' and before.state == 'ok' and number(before.ms) then
        row.previous_ms = number(before.ms)
        row.previous_load = number(before.load) or number(previous.load)
        row.delta_pct = ((row.ms - row.previous_ms) / row.previous_ms) * 100
        -- The delta is printed even when the two loads are not comparable, and then it SAYS so: a
        -- change measured against a machine that was doing something else is not a change.
        row.comparable = M.load_comparable(row.load, row.previous_load)
      end
      out[#out + 1] = row
    end
  end
  return out
end

-- ---- the history file ----------------------------------------------------------------------------
local function json_module()
  if M._json then return M._json end
  local ok, module = pcall(dofile, 'lua/vendor/json.lua')
  if not ok or type(module) ~= 'table' then return nil end
  M._json = module
  return module
end
M.json_module = json_module

function M.parse_jsonl(text)
  local json = json_module()
  if not json then return {} end
  local entries = {}
  for line in tostring(text or ''):gmatch('[^\r\n]+') do
    if line:match('^%s*{') then
      local ok, decoded = pcall(json.decode, line)
      if ok and type(decoded) == 'table' and decoded.sha then entries[#entries + 1] = decoded end
    end
  end
  return entries
end

function M.read_history(path)
  local file = io.open(path, 'r')
  if not file then return {} end
  local text = file:read('a')
  file:close()
  return M.parse_jsonl(text)
end

function M.encode(entry)
  local json = json_module()
  if not json then return nil end
  local ok, encoded = pcall(json.encode, entry)
  if not ok then return nil end
  return encoded
end

-- ONE LINE PER COMMIT: a commit measured twice (a re-run of main-health on the same tip) replaces its
-- own line instead of growing a second one, and every other line keeps its place, oldest first.
function M.write_history(path, entry)
  local history = M.read_history(path)
  local replaced = false
  for index, past in ipairs(history) do
    if past.sha == entry.sha then history[index] = entry; replaced = true end
  end
  if not replaced then history[#history + 1] = entry end
  local json = json_module()
  if not json then return nil, 'no json module' end
  local lines = {}
  for _, past in ipairs(history) do
    local ok, encoded = pcall(json.encode, past)
    if ok then lines[#lines + 1] = encoded end
  end
  local tmp = path .. '.tmp'
  local file = io.open(tmp, 'w')
  if not file then return nil, 'cannot write ' .. tmp end
  file:write(table.concat(lines, '\n') .. '\n')
  file:close()
  local moved, why = os.rename(tmp, path)
  if not moved then os.remove(tmp); return nil, tostring(why) end
  return #lines
end

function M.find(history, sha)
  for _, entry in ipairs(history or {}) do
    if entry.sha == sha then return entry end
  end
  return nil
end

function M.short(sha) return tostring(sha or ''):sub(1, 12) end

local function fmt_ms(ms)
  local n = number(ms)
  if not n then return '-' end
  if n >= 60000 then return string.format('%.1f min', n / 60000) end
  if n >= 1000 then return string.format('%.2f s', n / 1000) end
  return string.format('%d ms', math.floor(n + 0.5))
end
M.fmt_ms = fmt_ms

-- ---- what status.sh prints -----------------------------------------------------------------------
function M.format_table(history, sha)
  local entry = M.find(history, sha)
  if not entry then
    return 'no speed line for ' .. M.short(sha) .. ' yet (scripts/main-health.sh writes one after every landing)'
  end
  local verdict = M.judge(history, entry)
  local deltas = M.deltas(history, entry)
  local by_name = {}
  for _, row in ipairs(deltas) do by_name[row.name] = row end
  local lines = {}
  lines[#lines + 1] = string.format('measured %s at load %s on %s cores', tostring(entry.at or '?'),
    entry.load and string.format('%.2f', entry.load) or '?', entry.cores and tostring(entry.cores) or '?')
  lines[#lines + 1] = string.format('  %-24s %10s %8s %10s  %s', 'row', 'this', 'load', 'vs previous', 'verdict')
  for _, row in ipairs(verdict.rows) do
    local delta = by_name[row.name]
    local change = '-'
    if delta and delta.delta_pct then
      change = string.format('%+.1f%%', delta.delta_pct)
      if delta.comparable == false then change = change .. ' (load differs)' end
    end
    local state
    if row.state == 'ok' then
      state = row.red and string.format('RED: %.1f%% slower than best (%s)', row.delta_pct, M.short(row.best_sha))
        or (row.comparable == 0 and 'ok (no comparable baseline)' or 'ok')
    else
      -- A hole in a live row is RED here too: the table must not read as fine because a probe could not
      -- run (23/11), and the reason it carries is what the reader acts on.
      state = (row.red and 'RED ' or '') .. row.state .. (row.reason and (': ' .. row.reason) or '')
    end
    lines[#lines + 1] = string.format('  %-24s %10s %8s %10s  %s', row.name,
      row.ms and fmt_ms(row.ms) or '-', row.load and string.format('%.2f', row.load) or '-', change, state)
  end
  return table.concat(lines, '\n')
end

-- ---- the command line the shell harness calls ----------------------------------------------------
-- `lua5.4 scripts/lib/speed-stats.lua <verb> <history> [<sha>|<entry.json>]`
--   judge <history> <entry.json>   the verdict as JSON (the harness keeps it beside the history)
--   table <history> <sha>          the table status.sh prints
--   last  <history>                the newest entry's sha
local function cli(argv)
  local verb, history_path, argument = argv[1], argv[2], argv[3]
  local history = M.read_history(history_path or '')
  -- finish <entry.json>: fill every row's ms from its samples (the median is this file's).
  if verb == 'finish' then
    -- finish takes ONE argument (the entry), so the file is the second word, not the third.
    local target = argument or history_path
    local file = io.open(target or '', 'r')
    if not file then print('speed-stats: refused(entry_missing): ' .. tostring(target)); return 2 end
    local text = file:read('a')
    file:close()
    local json = json_module()
    if not json then print('speed-stats: refused(no_json)'); return 2 end
    local ok, entry = pcall(json.decode, text)
    if not ok or type(entry) ~= 'table' then print('speed-stats: refused(entry_invalid)'); return 2 end
    local encoded = M.encode(M.finish(entry))
    if not encoded then print('speed-stats: refused(encode_failed)'); return 2 end
    print(encoded)
    return 0
  end
  if verb == 'table' then
    print(M.format_table(history, argument))
    return 0
  end
  if verb == 'last' then
    print(history[#history] and history[#history].sha or '')
    return 0
  end
  -- append <history> <entry.json>: one line per commit, a re-measured commit replaces its own line.
  if verb == 'append' then
    local file = io.open(argument or '', 'r')
    if not file then print('speed-stats: refused(entry_missing): ' .. tostring(argument)); return 2 end
    local text = file:read('a')
    file:close()
    local json = json_module()
    if not json then print('speed-stats: refused(no_json)'); return 2 end
    local ok, entry = pcall(json.decode, text)
    if not ok or type(entry) ~= 'table' or type(entry.sha) ~= 'string' then
      print('speed-stats: refused(entry_invalid): ' .. tostring(argument)); return 2
    end
    local count, why = M.write_history(history_path, entry)
    if not count then print('speed-stats: refused(write_failed): ' .. tostring(why)); return 2 end
    print(count)
    return 0
  end
  if verb == 'judge' then
    local file = io.open(argument or '', 'r')
    if not file then print('speed-stats: refused(entry_missing): ' .. tostring(argument)); return 2 end
    local text = file:read('a')
    file:close()
    local json = json_module()
    if not json then print('speed-stats: refused(no_json): lua/vendor/json.lua is not readable from here'); return 2 end
    local ok, entry = pcall(json.decode, text)
    if not ok or type(entry) ~= 'table' then print('speed-stats: refused(entry_invalid): ' .. tostring(argument)); return 2 end
    local encoded = M.encode(M.judge(history, entry))
    if not encoded then print('speed-stats: refused(encode_failed)'); return 2 end
    print(encoded)
    return 0
  end
  print('usage: speed-stats.lua judge <history> <entry.json> | append <history> <entry.json> | table <history> <sha> | last <history>')
  return 2
end

if arg and arg[0] and tostring(arg[0]):match('speed%-stats%.lua$') then
  os.exit(cli(arg))
end

return M
