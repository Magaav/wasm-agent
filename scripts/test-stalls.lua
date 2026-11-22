-- wa stalls MEASURES FROM THE KEYPRESS THE HOST SAW, AND ITS WORST FIVE ARE THE FIVE SLOWEST
-- (change/chat-start-guard, item 3, 22/11).
--
-- Two defects, both measured on a9d4617d:
--   * a turn was measured from its own run/start row, so a wait BEFORE the run - the twenty seconds
--     between the reader's Enter and the run the CLI finally began - was invisible (the operator's
--     exact complaint: 'every one of these 20 s waits was invisible to it');
--   * 'the worst five' walked the turns backwards, so it listed the last five turns of the window and
--     a slow turn fell out of it as soon as anything newer happened.
--
-- This seeds a scratch ledger with the rows a real chat leaves - a keypress (kind=input, phase=submit),
-- the run it asked for, and that run's first model call - plus seven runs whose gaps are 7 s and then
-- six of 1 s, the SLOWEST BEING THE OLDEST, which is the shape that tells 'the five slowest' from 'the
-- last five'.
--
-- Run: WA_SCRIPT=scripts/test-stalls.lua wa --db /tmp/x.db
local scratch = dofile('scripts/lib/scratch-home.lua')
local refusal = scratch.guard('test-stalls.lua')
if refusal then print('REFUSED ' .. refusal); os.exit(2) end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local telemetry = dofile('lua/core/telemetry.lua'); telemetry.setup()
local stalls = dofile('lua/core/stalls.lua')

local checks, failures = 0, {}
local function check(condition, label)
  checks = checks + 1
  if not condition then failures[#failures + 1] = label end
end
local function near(value, want, tolerance, label)
  check(type(value) == 'number' and math.abs(value - want) <= tolerance,
    string.format('%s: got %s, wanted %s +- %s', label, tostring(value), tostring(want), tostring(tolerance)))
end

-- An hour back: inside the default 24 h window, and none of it is 'now' (a stamp taken by accident would
-- still be inside the window, so the assertions below are what catches it, not the clock).
local base = host.now() - 3600
local function event(session, run_id, kind, phase, offset)
  telemetry.event(session, run_id, '', kind, phase, {}, base + offset)
end

-- 1. THE TURN WHOSE WAIT HAPPENED BEFORE THE RUN EXISTED: Enter at 0, the run's first record at 20, the
--    model call at 20.5. Measured from the run it is 0.5 s; measured from the keypress it is 20.5 s.
event('stalls-enter', '', 'input', 'submit', 0)
event('stalls-enter', 'run-enter', 'run', 'start', 20)
event('stalls-enter', 'run-enter', 'model_call', 'start', 20.5)

-- 2. SEVEN RUNS WHOSE SLOWEST IS THE OLDEST: gaps of 7 s, then six of 1 s, in time order. Each is asked
--    for by a keypress at its own start, so the gap does not move and the count of keypress-measured
--    turns is what the assertions below hold the report to.
for index = 1, 7 do
  local session = 'stalls-rank'
  local run_id = 'run-rank-' .. index
  event(session, '', 'input', 'submit', 100 + index)
  event(session, run_id, 'run', 'start', 100 + index)
  event(session, run_id, 'model_call', 'start', 100 + index + (index == 1 and 7 or 1))
end

-- 3. A RUN NOBODY TYPED FOR (a wake, a sentinel): no keypress, so it is measured from run/start and the
--    answer says which (unknown is not zero).
event('stalls-wake', 'run-wake', 'run', 'start', 200)
event('stalls-wake', 'run-wake', 'model_call', 'start', 200.75)

local measured = stalls.measure({ since_hours = 24 })
check(type(measured) == 'table', 'measure answers with a table')
if type(measured) == 'table' then
  check(tonumber(measured.turns) == 9, 'nine runs in the window, got ' .. tostring(measured.turns))
  check(tonumber(measured.from_keypress) == 8, 'eight turns measured from a keypress, got ' .. tostring(measured.from_keypress))
  check(tonumber(measured.from_run) == 1, 'one turn with no keypress measured from run start, got ' .. tostring(measured.from_run))
  local worst = type(measured.worst) == 'table' and measured.worst or {}
  check(#worst == 5, 'the worst list is five rows, got ' .. #worst)
  local first = worst[1] or {}
  near(first.gap_ms, 20500, 5, 'the slowest turn is measured FROM THE KEYPRESS (0.5 s from the run)')
  near(first.pre_run_ms, 20000, 5, 'and the wait before the run is reported as its own number')
  check(first.from == 'enter', 'the row says it was measured from the keypress, got ' .. tostring(first.from))
  check((worst[2] or {}).gap_ms == 7000,
    'the second slowest is the OLDEST 7 s turn (the last-five bug lists the newest instead): got '
      .. tostring((worst[2] or {}).gap_ms))
  check(#worst == 5 and (worst[5] or {}).gap_ms == 1000,
    'the list is the five LARGEST, so its last row is a 1 s turn: got ' .. tostring((worst[5] or {}).gap_ms))
  local named = {}
  for _, row in ipairs(worst) do named[tostring(row.run_id)] = true end
  check(named['run-rank-1'] == true, 'the 7 s turn is named; the list is not the last five of anything')
  check(named['run-wake'] ~= true, 'the wake (0.75 s) is not among the five slowest')
  -- The report a person reads: it must say WHERE the measurement starts, and how many turns it could
  -- not start at a keypress.
  local printed = {}
  local real_print = print
  print = function(text) printed[#printed + 1] = tostring(text) end
  local ok, why = pcall(stalls.report, { since_hours = 24 })
  print = real_print
  check(ok, 'the report prints without an error: ' .. tostring(why))
  local head = printed[1] or ''
  check(head:find('Enter -> first model call', 1, true) ~= nil, 'the report names the keypress: ' .. head)
  check(head:find('from the keypress', 1, true) ~= nil, 'the report says how many turns were measured from one: ' .. head)
  local rows = {}
  for _, text in ipairs(printed) do if text:find('s of it before the run', 1, true) then rows[#rows + 1] = text end end
  check(#rows >= 1, 'the slow turn says how much of it was spent before the run: ' .. table.concat(printed, ' | '))
end

if #failures > 0 then
  for _, label in ipairs(failures) do print('FAIL ' .. label) end
  print(string.format('stalls: %d checks, %d failed', checks, #failures))
  os.exit(1)
end
print(string.format('stalls ok (%d checks)', checks))
