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
-- A MEASURED commit has a number for all four live rows: a real entry always does, because the harness
-- writes a row even when it could not measure. `value` moves the start row, which is the row these
-- checks judge; the other three sit still at 300 ms, so only the subject of each check can be red - a
-- fixture that left them out would now be a commit with three holes, and that is RED for a reason this
-- file does not mean to test.
local function entry(sha, load, value, extra)
  local rows = { start = { samples = { value }, load = load } }
  for _, name in ipairs({ 'first_token', 'tool_roundtrip', 'remote_roundtrip' }) do
    rows[name] = { samples = { 300 }, load = load }
  end
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
local holes_entry = stats.finish({ sha = 'holes', load = 1.0, rows = {
  start = { samples = { 400 } },
  remote_roundtrip = { state = 'unavailable', reason = 'no binary to measure' },
} })
local holes = stats.judge(history, holes_entry)
local remote
for _, candidate in ipairs(holes.rows) do if candidate.name == 'remote_roundtrip' then remote = candidate end end
check(remote and remote.state == 'unavailable' and remote.reason == 'no binary to measure',
  'an unavailable row is printed with its reason')
check(holes.rows[3] and holes.rows[3].state == 'unknown', 'a row the commit has no number for is unknown')

-- A LIVE ROW WITH NO NUMBER IS RED (23/11). The four live rows are what main must have a number for, so a
-- hole in one is a red row of the board, named with its reason - never a table of dashes that reads as
-- fine. The two records are different: an unknown landing is not a red board.
check(remote and remote.red == true and remote.hole == true,
  'an unavailable live row is RED, not merely printed')
-- This entry is judged against the twelve commits above, so `start` is red for its own reason (400 ms
-- against the 200 ms floor). What this check is about is the HOLES: each live row without a number is a
-- red row, and neither record row is.
local red_state = {}
for _, red_row in ipairs(holes.red) do red_state[red_row.name] = red_row.state end
check(red_state.first_token == 'unknown' and red_state.tool_roundtrip == 'unknown'
    and red_state.remote_roundtrip == 'unavailable',
  'every live row without a number is a red row of the board')
check(red_state.landing == nil and red_state.release == nil, 'and no record row is one')
local landing_row
for _, candidate in ipairs(holes.rows) do if candidate.name == 'landing' then landing_row = candidate end end
check(landing_row and landing_row.state == 'unknown' and not landing_row.red,
  'a record row that has not happened is unknown, never RED')
local holes_table = stats.format_table({ holes_entry }, 'holes')
check(holes_table:find('RED unavailable: no binary to measure', 1, true) ~= nil,
  'the table shows a live hole as RED with its reason')
local no_number_line = holes_table:match('  remote_roundtrip[^\n]*')
check(no_number_line ~= nil and no_number_line:find('%d%.%d%d') == nil,
  'a row with no number prints no load - 0.00 would read as a measurement: ' .. tostring(no_number_line))

-- A HOLE DOES NOT CONSUME THE WINDOW: a commit with no number cannot be the floor, and it must not push
-- the last numbers that exist out of the window either (23/11: the eight commits of 'unavailable' after
-- 8862b600 would otherwise have hidden its 321 ms start from every comparison).
-- THREE points at the floor, because a verdict now needs three (see "the three-point floor" below):
-- the subject here is the WINDOW, not the count.
local with_holes = { entry('floor', 1.0, 321), entry('floor2', 1.0, 330), entry('floor3', 1.0, 325) }
for index = 1, 12 do
  with_holes[#with_holes + 1] = stats.finish({ sha = 'hole' .. index, load = 1.0, rows = {
    start = { state = 'unavailable', reason = 'no binary to measure', load = 0 } } })
end
local after_holes = stats.judge(with_holes, entry('now', 1.0, 350))
check(after_holes.rows[1].best_ms == 321 and after_holes.rows[1].best_sha == 'floor',
  'a run of holes does not hide the last real number (best ' .. tostring(after_holes.rows[1].best_ms) .. ')')
check(after_holes.rows[1].state == 'ok' and after_holes.rows[1].red == false, 'and a number 9% above that floor is not RED')

-- ---- the three-point floor -------------------------------------------------------------------------
-- ONE COMPARABLE POINT IS NOT A VERDICT (mission speed-board-landing-kinds, 23/11). main-health called
-- 414 ms RED +21.1% against a single 342 ms point, and a landing 288 s RED +14300% against one 2 s point:
-- two numbers taken on one machine, presented as a regression. Below three comparable points the row has
-- no verdict at all, and it says how many it has.
local one = { entry('only', 1.0, 200) }
local one_verdict = stats.judge(one, entry('now', 1.0, 500))
check(one_verdict.rows[1].state == 'no_baseline', 'one comparable point is not a verdict: ' .. tostring(one_verdict.rows[1].state))
check(one_verdict.rows[1].red ~= true, 'a single comparable point NEVER makes RED, however slow the row')
check(one_verdict.rows[1].reason == '1 of 3 comparable points', 'and the row says how many points it has: ' .. tostring(one_verdict.rows[1].reason))
check(#one_verdict.red == 0, 'nothing is red on one point')
local two = { entry('p1', 1.0, 200), entry('p2', 1.0, 210) }
local two_verdict = stats.judge(two, entry('now', 1.0, 500))
check(two_verdict.rows[1].state == 'no_baseline' and two_verdict.rows[1].reason == '2 of 3 comparable points',
  'two comparable points are still short: ' .. tostring(two_verdict.rows[1].reason))
check(two_verdict.rows[1].red ~= true, 'and still never RED')
local three = { entry('p1', 1.0, 200), entry('p2', 1.0, 210), entry('p3', 1.0, 205) }
local three_verdict = stats.judge(three, entry('now', 1.0, 500))
check(three_verdict.rows[1].state == 'ok' and three_verdict.rows[1].red == true,
  'three comparable points can make RED')
check(three_verdict.rows[1].best_sha == 'p1' and three_verdict.rows[1].comparable == 3,
  'and the verdict names the floor and the count (' .. tostring(three_verdict.rows[1].best_sha) .. ', ' .. tostring(three_verdict.rows[1].comparable) .. ')')
-- A hole and a busy point are not points either: the count is of comparable points, not of lines.
local mixed = { entry('p1', 1.0, 200), entry('p2', 1.0, 210), entry('busy', 12.0, 900),
  stats.finish({ sha = 'hole', load = 1.0, rows = { start = { state = 'unavailable', reason = 'no binary to measure' } } }) }
local mixed_verdict = stats.judge(mixed, entry('now', 1.0, 500))
check(mixed_verdict.rows[1].comparable == 2 and mixed_verdict.rows[1].state == 'no_baseline',
  'a hole and a point at another load do not make up the three (' .. tostring(mixed_verdict.rows[1].comparable) .. ')')

-- ---- the landing row is judged within its own kind ---------------------------------------------------
-- A LANDING IS NOT ONE COST (23/11): 288 s was called RED +14300% against a 2 s landing that was
-- scripts-only, and a Rust build reinstalls the whole node. So a landing is compared only with landings of
-- the kind land-quick recorded, and a line written before kinds existed is counted and named, never used.
local function landing_point(sha, load, ms, kind)
  local rows = {}
  for _, other in ipairs({ 'start', 'first_token', 'tool_roundtrip', 'remote_roundtrip' }) do
    rows[other] = { samples = { 300 }, load = load }
  end
  rows.landing = { samples = { ms }, load = load }
  if kind then rows.landing.kind = kind end
  return stats.finish({ sha = sha, load = load, rows = rows })
end
local function landing_row_of(verdict)
  for _, row in ipairs(verdict.rows) do if row.name == 'landing' then return row end end
  return nil
end
local scripts_history = { landing_point('s1', 1.0, 2000, 'scripts'), landing_point('s2', 1.0, 2100, 'scripts'),
  landing_point('s3', 1.0, 2050, 'scripts') }
local install_now = stats.judge(scripts_history, landing_point('now', 1.0, 288000, 'lua'))
local install_row = landing_row_of(install_now)
check(install_row and install_row.kind == 'lua', 'the landing row carries its kind: ' .. tostring(install_row and install_row.kind))
check(install_row and install_row.state == 'no_baseline',
  'an install landing is NEVER compared with scripts-only landings: ' .. tostring(install_row and install_row.reason))
check(install_row and install_row.reason == '0 of 3 comparable points (landing kind lua)',
  'and it says which kind it wanted: ' .. tostring(install_row and install_row.reason))
check(install_row and install_row.red ~= true, 'so a 288 s install is not RED against 2 s scripts landings')
check(install_row and install_row.ms == 288000, 'while its own number is still printed')
-- Three of the same kind: now the row has a verdict, and only its own kind is the floor.
local lua_history = { landing_point('i1', 1.0, 280000, 'lua'), landing_point('i2', 1.0, 290000, 'lua'),
  landing_point('i3', 1.0, 285000, 'lua'), landing_point('s1', 1.0, 2000, 'scripts') }
local lua_now = landing_row_of(stats.judge(lua_history, landing_point('now', 1.0, 500000, 'lua')))
check(lua_now and lua_now.comparable == 3 and lua_now.best_sha == 'i1',
  'three landings of one kind are a baseline (' .. tostring(lua_now and lua_now.comparable) .. ', ' .. tostring(lua_now and lua_now.best_sha) .. ')')
check(lua_now and lua_now.red == true, 'and a much slower install of the same kind is RED')
local scripts_now = landing_row_of(stats.judge(lua_history, landing_point('now', 1.0, 9000, 'scripts')))
check(scripts_now and scripts_now.state == 'no_baseline' and scripts_now.comparable == 1
    and scripts_now.reason == '1 of 3 comparable points (landing kind scripts)',
  'a scripts landing counts only the ONE scripts landing and none of the three installs: '
    .. tostring(scripts_now and scripts_now.reason))
-- A LINE WRITTEN BEFORE KINDS EXISTED: not comparable to anything, counted, and said.
local legacy_history = { landing_point('old1', 1.0, 2000), landing_point('old2', 1.0, 2100),
  landing_point('old3', 1.0, 2050) }
local legacy_now = landing_row_of(stats.judge(legacy_history, landing_point('now', 1.0, 3000, 'scripts')))
check(legacy_now and legacy_now.state == 'no_baseline' and legacy_now.no_kind == 3,
  'a landing line with no kind is not a baseline, and the count of them is kept (' .. tostring(legacy_now and legacy_now.no_kind) .. ')')
check(legacy_now and legacy_now.red ~= true, 'and it can never make a landing RED')
local legacy_with_now = { legacy_history[1], legacy_history[2], legacy_history[3], landing_point('now', 1.0, 3000, 'scripts') }
local legacy_table = stats.format_table(legacy_with_now, 'now')
check(legacy_table:find('3 line(s) in the window carry no kind and are not comparable', 1, true) ~= nil,
  'the table says which lines could not be used:\n' .. legacy_table)
-- The row ITSELF with no kind (a record written by a land-quick that had no kind to give).
local no_kind_now = landing_row_of(stats.judge(scripts_history, landing_point('now', 1.0, 1000)))
check(no_kind_now and no_kind_now.state == 'no_baseline'
    and no_kind_now.reason == 'the landing record carries no kind (written before kinds, 23/11)',
  'a landing recorded without a kind has no baseline and says why: ' .. tostring(no_kind_now and no_kind_now.reason))
local kind_table = stats.format_table({ scripts_history[1], scripts_history[2], scripts_history[3],
  landing_point('now', 1.0, 288000, 'lua') }, 'now')
check(kind_table:find('landing kind lua', 1, true) ~= nil, 'the table names the kind it judged within:\n' .. kind_table)
-- The change against the previous commit says the KIND differs, rather than pretending it is a change.
local kinds_pair = { landing_point('s1', 1.0, 2000, 'scripts'), landing_point('i1', 1.0, 280000, 'lua') }
local kind_delta
for _, delta in ipairs(stats.deltas(kinds_pair, kinds_pair[2])) do
  if delta.name == 'landing' then kind_delta = delta end
end
check(kind_delta and kind_delta.comparable == false and kind_delta.kind_differs == true,
  'the change against the previous commit says the landing kinds differ')
local kind_delta_table = stats.format_table(kinds_pair, 'i1')
check(kind_delta_table:find('(landing kind differs)', 1, true) ~= nil,
  'and the table says it in the row: ' .. tostring(kind_delta_table:match('landing[^\n]*')))

-- ---- the change against the previous commit -------------------------------------------------------
local with_previous = { entry("before", 1.0, 400), entry("after", 4.0, 500) }
local deltas = stats.deltas(with_previous, with_previous[2])
check(#deltas == 4 and math.abs(deltas[1].delta_pct - 25) < 0.001,
  'the delta against the previous commit is 25% on the start row, and every live row is compared (' .. #deltas .. ')')
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
