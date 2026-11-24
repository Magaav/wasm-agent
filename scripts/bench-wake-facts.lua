-- THE COST OF THE NODE'S OWN WAKE FACTS, on a ledger that is bigger than any node has.
--
-- MEASURED once, before landing (r8c item G): `selfloop.wake_facts` runs on the node's placement tick, every
-- 2 s, forever. Its four aggregates are cheap only if each one uses an index, so this script seeds a synthetic
-- ledger through the PRODUCT'S OWN sql host into the product's own table and table shape (never a table made by
-- hand), times the real `wake_facts` call, and prints the query plan of each statement the call runs.
--
--   WA_BENCH_WAKES_ROWS=10000 WA_SCRIPT=scripts/bench-wake-facts.lua wa --db <scratch>/b.db
--   WA_BENCH_WAKE_FACTS_ITERATIONS=300 (default 300: the median is what a tick pays)
--
-- It prints one line per measurement and one plan line per query; it does not gate anything (a bench is not a
-- row: scripts/test-node-wake-facts.cjs and scripts/test-health-wakes-rule.cjs are the rows).
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
local selfloop = dofile('lua/core/selfloop.lua')
memory.setup()
selfloop.setup()

local ROWS = tonumber(os.getenv('WA_BENCH_WAKES_ROWS') or '') or 10000
local ITERATIONS = tonumber(os.getenv('WA_BENCH_WAKE_FACTS_ITERATIONS') or '') or 300
local now = tonumber(host.now())

local function decode(raw) if type(raw) == 'string' then return json.decode(raw) end return raw end

-- A LEDGER THAT LOOKS LIKE A LONG-LIVED NODE'S: three states, rows that were dispatched (attempts>0), rows that
-- are due and waiting, and a share of them held by sessions in self_wake_pauses (the exclusion the rule reads).
local seeded = decode(host.sql_exec([[
INSERT INTO self_wakes(id,owner,session_id,status,reason,prompt,on_topics,probe,probe_result,event_json,
  fired_at,created_at,updated_at,attempts,last_error,boot,run_id,due_at,every_seconds)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < ?)
SELECT 'bench-' || n,
       'master',
       'bench-session-' || (n % 50),
       CASE WHEN n % 3 = 0 THEN 'pending' ELSE 'delivered' END,
       'bench row ' || n, '', '[]', '', '', '',
       0, ?, ?,
       CASE WHEN n % 3 = 0 THEN 0 ELSE 1 END,
       '', '', NULL,
       CASE WHEN n % 3 = 0 THEN ? ELSE NULL END,
       NULL
FROM seq
]], json.encode({ ROWS, now - 3600, now - (ROWS - 0), now - (ROWS % 60) })))
print(string.format('seeded=%s', json.encode(seeded)))

local held = decode(host.sql_exec([[INSERT OR IGNORE INTO self_wake_pauses(session_id,owner,reason,paused_at,kind)
  SELECT 'bench-session-' || n, 'master', 'bench hold', ?, 'park' FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2)]],
  json.encode({ now - 600 })))
print(string.format('held_sessions=%s', json.encode(held)))

local function ms(started) return (host.monotonic_ms() - started) end

-- One call, timed, and the shape it answers (so a number here is never a call that refused).
local function timed() local began = host.monotonic_ms(); local facts = selfloop.wake_facts({}); return ms(began), facts end
local elapsed, facts = timed()
print(string.format('first_call_ms=%.2f due=%s dispatchable=%s oldest=%s',
  elapsed, tostring(facts.due), tostring(facts.dispatchable), tostring(facts.oldest_dispatchable_age_s)))

local samples = {}
for i = 1, ITERATIONS do
  local took = timed()
  samples[#samples + 1] = took
end
table.sort(samples)
local total = 0
for _, value in ipairs(samples) do total = total + value end
print(string.format('iterations=%d min_ms=%.2f median_ms=%.2f mean_ms=%.2f p95_ms=%.2f max_ms=%.2f',
  ITERATIONS, samples[1], samples[math.floor(#samples / 2) + 1], total / #samples,
  samples[math.max(1, math.floor(#samples * 0.95))], samples[#samples]))

-- THE PLANS. Each statement the call runs, by the same SQL text (a plan for a statement the call does not run
-- would prove nothing), with the same parameters.
local plans = {
  { 'due', [[SELECT COUNT(*) AS n FROM self_wakes
    WHERE status='pending' AND due_at IS NOT NULL AND due_at<=?]], { now } },
  { 'dispatchable', [[SELECT COUNT(*) AS n, MIN(due_at) AS oldest FROM self_wakes
    WHERE status='pending' AND due_at IS NOT NULL AND due_at<=?
    AND session_id NOT IN (SELECT session_id FROM self_wake_pauses)]], { now } },
  { 'held', [[SELECT COUNT(*) AS n FROM self_wakes
    WHERE status='pending' AND due_at IS NOT NULL AND due_at<=?
    AND session_id IN (SELECT session_id FROM self_wake_pauses)]], { now } },
  { 'last_dispatch', 'SELECT MAX(updated_at) AS at FROM self_wakes WHERE attempts>0', {} },
}
for _, plan in ipairs(plans) do
  local rows = decode(host.sql_query('EXPLAIN QUERY PLAN ' .. plan[2], json.encode(plan[3]))) or {}
  local lines = {}
  for _, row in ipairs(rows) do lines[#lines + 1] = tostring(row.detail or json.encode(row)) end
  print(string.format('plan %s: %s', plan[1], table.concat(lines, ' | ')))
end
print('bench-wake-facts ok')
