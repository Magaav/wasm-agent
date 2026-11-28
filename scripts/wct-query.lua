-- waiting-costs-no-turns: the measurement, as a command instead of a memory.
--
-- WHY THIS FILE EXISTS. docs/missions/reports/waiting-costs-no-turns.md decides the mission (the hold is withdrawn;
-- the pending answer is the contract; the shared wait replaced it) and then says what to measure after a week: "the
-- same ledger query (wct-query.sql)". MEASURED 27/11: no such file was in the tree - `find` over the repo returned
-- nothing - so the before lived only in the head of whoever wrote it, and the "after is a subtraction" could not be
-- made by anyone else. A cited-but-absent query is the cheapest kind of debt; this pays it.
--
-- IT IS NOT SQL because the ledger is a guarded path: bash cannot read memory.db (the node refuses the path), so the
-- only honest reader is the node's own surface, `telemetry.events`, paged by cursor. That is what the report's numbers
-- were taken with, and this is the same query in the one language that may run it.
--
-- WHAT IT COUNTS (the report's four numbers, and the same ones the after must be compared with):
--   1. runs that lasted more than two minutes;
--   2. `operation` calls inside those runs;
--   3. how many of those runs made six or more calls, and how many made more than twenty (the tail the hold was
--      trying to remove);
--   4. the worst single run.
-- It also reports the marathon's second reading - repeated polls of one call shape - because the report's numbers and
-- mine disagreed in shape and agreed in substance, and a reader should see both.
--
-- USAGE
--   WA_SCRIPT=scripts/wct-query.lua wa                 # the last 7 days
--   WA_SCRIPT=scripts/wct-query.lua wa --days 14       # any window
--   WA_SCRIPT=scripts/wct-query.lua wa --json          # one line, for a before/after table
-- Read-only: it dispatches nothing, starts nothing and writes nothing.

local telemetry = dofile('lua/core/telemetry.lua')
telemetry.setup()

-- OPTIONS COME FROM THE ENVIRONMENT, not argv: a script the node runs receives its words in the environment, and
-- MEASURED 27/11 - a row that passed --days=1 --json on the command line had both swallowed by `wa`, so the query
-- answered its human form and the row reported 'an unusable answer'. The environment is the door that exists.
local days = tonumber(host.getenv('WCT_DAYS') or '') or 7
local as_json = (host.getenv('WCT_JSON') or '') ~= ''

local since = os.time() - days * 86400
local LONG_TOOL_S, LONG_RUN_S, TAIL = 120, 120, 20

-- One pass over the window, paged: the ledger answers at most 1000 rows per call.
local runs, shapes, cursor, pages, seen = {}, {}, 0, 0, 0
while true do
  local page = telemetry.events('*', cursor, 1000, since)
  if not page.available then
    io.stderr:write('wct-query: the ledger is unreadable: ' .. tostring(page.detail) .. '\n')
    os.exit(2)
  end
  pages = pages + 1
  for _, row in ipairs(page.events or {}) do
    seen = seen + 1
    local run = runs[row.run_id]
    if not run then
      run = { first = row.at, last = row.at, operations = 0, session = row.session_id }
      runs[row.run_id] = run
    end
    if row.at < run.first then run.first = row.at end
    if row.at > run.last then run.last = row.at end
    local payload = row.payload
    if row.kind == 'tool' and row.phase == 'start' and type(payload) == 'table' then
      if payload.name == 'operation' then run.operations = run.operations + 1 end
      local hash = tostring(payload.arguments_hash or '')
      if hash ~= '' then shapes[hash] = (shapes[hash] or 0) + 1 end
    end
  end
  cursor = page.next_cursor
  if not page.has_more then break end
end

local long, calls_inside, ge6, gt20, worst = 0, 0, 0, 0, { calls = 0 }
for id, run in pairs(runs) do
  local seconds = run.last - run.first
  if seconds > LONG_RUN_S then
    long = long + 1
    calls_inside = calls_inside + run.operations
    if run.operations >= 6 then ge6 = ge6 + 1 end
    if run.operations > TAIL then gt20 = gt20 + 1 end
    if run.operations > worst.calls then
      worst = { calls = run.operations, seconds = seconds, run = id, session = run.session }
    end
  end
end

local repeated, repeated_calls = 0, 0
for _, n in pairs(shapes) do
  if n >= 2 then repeated = repeated + 1; repeated_calls = repeated_calls + (n - 1) end
end

if as_json then
  print(string.format(
    '{"days":%d,"events":%d,"runs":%d,"long_runs":%d,"operation_calls_in_long_runs":%d,'
    .. '"long_runs_with_6_plus":%d,"long_runs_over_20":%d,"worst_run_calls":%d,"worst_run_seconds":%d,'
    .. '"repeat_poll_shapes":%d,"repeat_polls":%d}',
    days, seen, (function() local n = 0 for _ in pairs(runs) do n = n + 1 end return n end)(), long, calls_inside,
    ge6, gt20, worst.calls, math.floor(worst.seconds or 0), repeated, repeated_calls))
  return
end

print(string.format('wct-query: the last %d day(s), %d events, %d runs', days, seen,
  (function() local n = 0 for _ in pairs(runs) do n = n + 1 end return n end)()))
print(string.format('  runs over %ds            %d', LONG_RUN_S, long))
print(string.format('  operation calls inside   %d', calls_inside))
print(string.format('  ... 6 or more calls      %d', ge6))
print(string.format('  ... more than %d calls  %d', TAIL, gt20))
print(string.format('  worst single run         %d calls in %ds (%s)', worst.calls, math.floor(worst.seconds or 0),
  tostring(worst.run or 'none')))
print(string.format('  repeated polls of one call shape: %d shapes, %d calls beyond the first', repeated, repeated_calls))
