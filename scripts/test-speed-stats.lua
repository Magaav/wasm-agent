-- THE SPEED BOARD'S RULES, TESTED WITHOUT A MACHINE (change/speed-board, 22/11).
--
-- scripts/lib/speed-stats.lua is where a row becomes a number and where a number becomes RED, so this row
-- judges the rules themselves: the median, the load guard, the window, the RED threshold, and the two
-- things that must never happen - a row with no samples counted as fast, and a commit compared with a
-- machine that was doing something else.
--
-- It needs no binary, no network and no time: every entry here is a fixture. Run by the fast path and by
-- the gate like every other scripts/test-*.lua:
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-speed-stats.lua wa --db <scratch>/t.db
local stats = dofile('scripts/lib/speed-stats.lua')

local failures, checks = 0, 0
local function check(condition, label)
  checks = checks + 1
  if condition then print('ok   ' .. label) else print('FAIL ' .. label); failures = failures + 1 end
end
local function near(value, want, label)
  check(type(value) == 'number' and math.abs(value - want) < 0.001, label .. ' (' .. tostring(value) .. ' vs ' .. tostring(want) .. ')')
end

-- ---- the median ----------------------------------------------------------------------------------
near(stats.median({ 7 }), 7, 'one sample is its own median')
near(stats.median({ 5, 1, 3 }), 3, 'three samples: the middle one, not the mean')
near(stats.median({ 4, 1 }), 3, 'two samples: the mean of the pair, rounded')
near(stats.median({ 900, 100, 110, 105, 108 }), 108, 'one outlier at 900 does not move the median')
check(stats.median({}) == nil, 'no samples is nil, not zero')
check(stats.median({ 'x', nil, false }) == nil, 'a sample that is not a number is not a zero')

-- ---- the load guard ------------------------------------------------------------------------------
check(stats.load_comparable(1.0, 1.2), 'load 1.0 and 1.2 are comparable')
check(stats.load_comparable(0.6, 1.1), 'a quiet machine and a lightly busy one are comparable')
check(not stats.load_comparable(1.0, 12.0), 'load 1.0 and load 12.0 are NOT comparable')
check(not stats.load_comparable(nil, 1.0), 'an unknown load is not comparable with a known one')
near(stats.load_ceiling(16), 24, 'the ceiling is 1.5 load units per core (16 cores -> 24)')
near(stats.load_ceiling(nil), 1.5, 'a machine that cannot say how many cores it has gets the floor')

-- ---- the entry shape -----------------------------------------------------------------------------
local finished = stats.finish({ sha = 'a', rows = {
  start = { samples = { 300, 100, 200 }, load = 1.0 },
  landing = { state = 'unknown', reason = 'no landing recorded' },
} })
near(finished.rows.start.ms, 200, 'finish fills a row ms from its own samples')
check(finished.rows.landing.state == 'unknown' and finished.rows.landing.ms == nil,
  'finish leaves an unknown row unknown (never a zero that would read as fast)')

-- Twelve commits at a comparable load, each with the four live rows; the tenth-from-last is the floor.
local function entry(sha, load, value, extra)
  local rows = { start = { samples = { value }, load = load } }
  for name, row in pairs(extra or {}) do rows[name] = row end
  return stats.finish({ sha = sha, load = load, rows = rows })
end
local history = {}
for index = 1, 12 do
  history[index] = entry(string.format('c%02d', index), 1.0, 400)
end
-- The best of the window is 200 ms, six commits back: a commit 30% slower than that is RED, and the
-- verdict must name the commit that holds the floor.
history[6] = entry('c06', 1.0, 200)  -- a finished 200 ms row, six commits back

local slow = stats.judge(history, entry('now', 1.0, 500))
local row = slow.rows[1]
check(row.name == 'start', 'the verdict keeps the board row order')
check(row.red == true, 'a row 150% slower than the best is RED')
check(row.best_sha == 'c06' and row.best_ms == 200, 'the verdict names the commit that holds the floor (' .. tostring(row.best_sha) .. ')')
check(#slow.red == 1, 'exactly one red row is reported')

local mild = stats.judge(history, entry('now', 1.0, 230))
check(mild.rows[1].red == false, 'a row 15% slower than the best is not RED (the threshold is 20%)')

-- The same numbers taken while the machine was at load 12 must NOT be called a regression.
local busy = stats.judge(history, entry('busy', 12.0, 900))
check(busy.rows[1].red == nil and busy.rows[1].state == 'no_baseline',
  'a row measured at load 12 has no comparable baseline and is never RED')
check(#busy.red == 0, 'nothing is red on an incomparable load')

-- The window is the last ten commits: a floor older than that is not the floor any more.
local wide = {}
for index = 1, 12 do wide[index] = entry(string.format('w%02d', index), 1.0, 400) end
wide[1].rows.start.samples = { 100 }
local outside = stats.judge(wide, entry('now', 1.0, 400))
check(outside.rows[1].best_ms == 400 and outside.rows[1].red == false,
  'a floor 12 commits back is outside the window of 10')

-- A row the commit does not have, or could not measure, is named with its reason and is not red.
local holes = stats.judge(history, stats.finish({ sha = 'holes', load = 1.0, rows = {
  start = { samples = { 400 } },
  remote_roundtrip = { state = 'unavailable', reason = 'no binary to measure' },
} }))
local remote
for _, candidate in ipairs(holes.rows) do if candidate.name == 'remote_roundtrip' then remote = candidate end end
check(remote and remote.state == 'unavailable' and remote.reason == 'no binary to measure',
  'an unavailable row is printed with its reason')
check(holes.rows[3] and holes.rows[3].state == 'unknown', 'a row the commit has no number for is unknown')

-- ---- the change against the previous commit -------------------------------------------------------
local with_previous = { entry("before", 1.0, 400), entry("after", 4.0, 500) }
local deltas = stats.deltas(with_previous, with_previous[2])
check(#deltas == 1 and math.abs(deltas[1].delta_pct - 25) < 0.001, 'the delta against the previous commit is 25%')
check(deltas[1].comparable == false, 'a delta across two different loads says the loads differ')

-- ---- one line per commit --------------------------------------------------------------------------
local path = os.tmpname()
os.remove(path)
local first = stats.finish({ sha = 'sha-one', load = 1.0, cores = 16, at = 'now', rows = { start = { samples = { 400 } } } })
stats.write_history(path, first)
stats.write_history(path, stats.finish({ sha = 'sha-two', load = 1.0, cores = 16, at = 'now', rows = { start = { samples = { 410 } } } }))
-- A re-measured commit REPLACES its own line: two runs of main-health on one tip must not produce two
-- lines, or the "last 10 commits" window would be ten runs of the same commit.
stats.write_history(path, stats.finish({ sha = 'sha-one', load = 1.0, cores = 16, at = 'again', rows = { start = { samples = { 300 } } } }))
local reread = stats.read_history(path)
check(#reread == 2, 'the history holds one line per commit after a re-measure (' .. #reread .. ')')
check(reread[1].sha == 'sha-one' and reread[1].rows.start.ms == 300, 'the re-measured line replaced the old one in place')
check(reread[2].sha == 'sha-two', 'and the other line kept its place')

local table_text = stats.format_table(reread, 'sha-two')
check(table_text:find('start', 1, true) ~= nil, 'the table names the row')
check(table_text:find('no speed line', 1, true) == nil, 'the table found the commit')
check(stats.format_table(reread, 'nope'):find('no speed line', 1, true) ~= nil,
  'a commit with no line says so instead of printing dashes as a verdict')
os.remove(path)

if failures > 0 then
  print(string.format('speed-stats: %d FAIL of %d', failures, checks))
  os.exit(1)
end
print(string.format('speed-stats ok (%d checks)', checks))
