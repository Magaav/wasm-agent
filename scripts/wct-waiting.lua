-- waiting-costs-no-turns: HOW MANY TURNS AND TOKENS A SESSION SPENDS ONLY WAITING.
--
-- The report (docs/missions/reports/waiting-costs-no-turns.md) named the cost and the query meant to measure it;
-- wct-query.lua paid the RUN-level half (runs >120 s and the operation calls inside them). This is the TURN-level
-- half, which is what the title claims, and it reports TOKENS as well as turns.
--
-- WHAT A WAITING TURN IS, measured rather than assumed:
--   a round (one model call plus the tool calls it asked for) that
--     (a) called only `operation` - i.e. asked for a state, and did nothing else, or
--     (b) asked for EXACTLY what the previous round asked for (same tool names, same arguments_hash): a poll.
-- MEASURED 28/11 on this node, 2-day window: (a) alone finds ZERO rounds - no round is operation-only - and (b) finds
-- the cost. So a single wait is not the problem; REPETITION is, and the ledger can see it because every tool/start
-- carries arguments_hash.
-- MEASURED the same day, one run: `operation wait` DOES block (2.75 s of a 4 s budget, returning when the operation
-- settled), so the engine is not the cost either. The cost is the shape of the asking.
--
-- TOKENS: model_call/end carries `usage` but NOT the round, so a call is attributed to the round of the FIRST tool/start
-- AFTER it in the same run - the call the tools answered. Rows are sorted by their own `at` per run, so the order is
-- the run's order and not the ledger's paging order.
--
-- Read-only: dispatches nothing, starts nothing, writes nothing.
--   WA_SCRIPT=scripts/wct-waiting.lua WCT_DAYS=7 wa
--   WCT_JSON=1 ... for one line, WCT_PAGES=n to bound the scan (default 60 pages x 1000 rows)

local telemetry = dofile('lua/core/telemetry.lua')
telemetry.setup()

local days = tonumber(host.getenv('WCT_DAYS') or '') or 7
-- A SHORTER WINDOW THAN A DAY (28/11): the fix for this mission landed this morning, and "is the after visible
-- yet?" is a question about HOURS. WCT_HOURS overrides WCT_DAYS when set, so the same query answers both the
-- week-long comparison and "since the change landed".
local hours = tonumber(host.getenv('WCT_HOURS') or '')
if hours and hours > 0 then days = hours / 24 end
local as_json = (host.getenv('WCT_JSON') or '') ~= ''
local pages_max = tonumber(host.getenv('WCT_PAGES') or '') or 60
local since = os.time() - days * 86400

local runs, usage_keys, cursor, rows = {}, {}, nil, 0
local pages, previous_cursor = 0, nil
while true do
  local page = telemetry.events('*', cursor, 1000, since)
  if not page.available then
    io.stderr:write('wct-waiting: the ledger is unreadable: ' .. tostring(page.detail) .. '\n')
    os.exit(2)
  end
  for _, row in ipairs(page.events or {}) do
    rows = rows + 1
    local run = runs[row.run_id]
    if not run then run = { rows = {} }; runs[row.run_id] = run end
    local payload = row.payload
    if type(payload) == 'table' and (row.kind == 'tool' or row.kind == 'model_call') then
      run.rows[#run.rows + 1] = {
        at = row.at, kind = row.kind, phase = row.phase,
        round = tonumber(payload.round) or 0,
        name = payload.name and tostring(payload.name) or nil,
        hash = payload.arguments_hash and tostring(payload.arguments_hash) or '',
        usage = payload.usage,
      }
    end
  end
  cursor = page.next_cursor
  pages = pages + 1
  -- A REPEATED CURSOR IS THE END OF THE LEDGER (measured: a 2-hour window ends this way at 7,991 rows, while a
  -- week-long one stops at the page cap first). Calling it an error made a small window look broken.
  if cursor == previous_cursor then break end
  previous_cursor = cursor
  if not cursor then break end
  if pages >= pages_max then
    io.stderr:write('wct-waiting: stopped at the page cap (' .. pages_max .. ' pages, ' .. rows .. ' rows)\n')
    break
  end
end

local function tokens(usage)
  local in_t, out_t = 0, 0
  if type(usage) ~= 'table' then return 0, 0 end
  for key, value in pairs(usage) do
    if type(value) == 'number' then
      usage_keys[key] = true
      if key:find('input') or key:find('prompt') then in_t = in_t + value end
      if key:find('output') or key:find('completion') then out_t = out_t + value end
    end
  end
  return in_t, out_t
end

local total_rounds, waiting_rounds, waiting_tokens, all_tokens = 0, 0, 0, 0
local runs_with_waiting, worst_turns, worst_run = 0, 0, ''
local example = nil

for run_id, run in pairs(runs) do
  table.sort(run.rows, function(a, b) return (a.at or 0) < (b.at or 0) end)
  -- Walk the run: a model call's tokens belong to the round that answers it (the first tool/start after it).
  local pending_in, pending_out = 0, 0
  local rounds, order, previous_signature = {}, {}, nil
  for _, r in ipairs(run.rows) do
    if r.kind == 'model_call' and r.phase == 'end' then
      local i, o = tokens(r.usage)
      pending_in, pending_out = pending_in + i, pending_out + o
    elseif r.kind == 'tool' and r.phase == 'start' then
      local round = r.round
      local slot = rounds[round]
      if not slot then slot = { calls = {}, in_tokens = 0, out_tokens = 0, round = round }; rounds[round] = slot; order[#order + 1] = round end
      slot.calls[#slot.calls + 1] = (r.name or '?') .. ':' .. r.hash
      slot.in_tokens = slot.in_tokens + pending_in
      slot.out_tokens = slot.out_tokens + pending_out
      pending_in, pending_out = 0, 0
    end
  end
  local run_waiting = 0
  for _, round in ipairs(order) do
    local slot = rounds[round]
    if #slot.calls > 0 then
      local signature = table.concat(slot.calls, '|')
      local only_operation = true
      for _, call in ipairs(slot.calls) do
        if call:sub(1, 10) ~= 'operation:' then only_operation = false break end
      end
      local repeat_of_previous = (previous_signature ~= nil and signature == previous_signature)
      previous_signature = signature
      total_rounds = total_rounds + 1
      local cost = slot.in_tokens + slot.out_tokens
      all_tokens = all_tokens + cost
      if only_operation or repeat_of_previous then
        waiting_rounds = waiting_rounds + 1
        waiting_tokens = waiting_tokens + cost
        run_waiting = run_waiting + 1
        if not example then
          example = string.format('%s round %d: %s', tostring(run_id):sub(1, 12), round, signature:gsub(':', ''))
        end
      end
    end
  end
  if run_waiting > 0 then runs_with_waiting = runs_with_waiting + 1 end
  if run_waiting > worst_turns then worst_turns, worst_run = run_waiting, tostring(run_id) end
end

local run_count = 0
for _ in pairs(runs) do run_count = run_count + 1 end
local keys = {}
for key in pairs(usage_keys) do keys[#keys + 1] = key end
table.sort(keys)
local turn_share = total_rounds > 0 and (waiting_rounds * 100 / total_rounds) or 0
local token_share = all_tokens > 0 and (waiting_tokens * 100 / all_tokens) or 0

if as_json then
  print(string.format('{"days":%d,"rows":%d,"runs":%d,"rounds":%d,"waiting_rounds":%d,"waiting_share_pct":%.2f,'
    .. '"waiting_tokens":%d,"all_tokens":%d,"waiting_token_share_pct":%.2f,"runs_with_waiting":%d,'
    .. '"worst_run_waiting_rounds":%d,"usage_keys":"%s"}',
    tonumber(string.format('%.0f', days)), rows, run_count, total_rounds, waiting_rounds, turn_share, waiting_tokens, all_tokens, token_share,
    runs_with_waiting, worst_turns, table.concat(keys, ',')))
  return
end

local window = hours and hours > 0 and string.format('last %g hour(s)', hours) or string.format('last %g day(s)', days)
print(string.format('wct-waiting: %s - %d ledger rows, %d runs, %d rounds', window, rows, run_count, total_rounds))
print(string.format('  ROUNDS SPENT ONLY WAITING: %d of %d (%.2f%%)', waiting_rounds, total_rounds, turn_share))
print(string.format('  TOKENS SPENT ONLY WAITING: %d of %d (%.2f%%)', waiting_tokens, all_tokens, token_share))
print(string.format('  runs with one or more: %d; worst run: %d waiting rounds (%s)', runs_with_waiting, worst_turns, worst_run:sub(1, 12)))
print('  first example: ' .. (example or 'none'))
print('  usage keys reported: ' .. (next(keys) and table.concat(keys, ', ') or 'none'))
