-- The number Victor asked to be able to see: how long a turn takes to REACH the model
-- (change/start-instant, item 5, 22/11).
--
--   wa stalls [--since <hours>] [--json]
--
-- READ-ONLY. It answers one question from the ledger's own rows - for every run in the window, the time
-- between its run/start event and its first model_call/start - and it names the phase when that run's
-- preflight row says which one was slow (lua/core/agent.lua, the per-phase clock). Keeping this
-- measurement is the point: a first model call that takes 20 s must be a number somebody can read the next
-- morning, not a feeling.
--
-- HOW IT STAYS CHEAP ON A 900 MB LEDGER. There is no index on kind/phase/at, so a WHERE over the table is
-- a scan of every byte of it. Events are appended in time order, so this walks the seq index BACKWARDS in
-- chunks and stops once a chunk is entirely older than the window: the cost is the pages of the window,
-- not the life of the node. A window it could not cover is reported (truncated/complete=false), never
-- guessed - unknown is not zero.
local json = dofile('lua/vendor/json.lua')
local M = {}

local CHUNK = 1000

local function query(statement, params)
  local ok, raw = pcall(host.sql_query, statement, json.encode(params or {}))
  if not ok then return nil, tostring(raw) end
  local okd, decoded = pcall(json.decode, raw)
  if not okd or type(decoded) ~= 'table' then return nil, 'unreadable answer' end
  if decoded.error then return nil, tostring(decoded.error) end
  return decoded
end


local function percentile(sorted, fraction)
  if #sorted == 0 then return nil end
  local index = math.ceil(#sorted * fraction)
  if index < 1 then index = 1 end
  if index > #sorted then index = #sorted end
  return sorted[index]
end

-- run_id -> { at = run/start seconds, call = first model_call/start seconds, preflight = payload or nil }
function M.measure(opts)
  opts = opts or {}
  local hours = tonumber(opts.since_hours) or 24
  local since = host.now() - hours * 3600
  local runs, order = {}, {}
  local scanned, cursor, complete = 0, nil, true
  local preflights = {}
  while true do
    local found, why
    if cursor == nil then
      found, why = query([[SELECT seq,run_id,kind,phase,at FROM harness_events
        WHERE kind IN ('run','model_call','preflight') ORDER BY seq DESC LIMIT ?]], { CHUNK })
    else
      found, why = query([[SELECT seq,run_id,kind,phase,at FROM harness_events
        WHERE seq<? AND kind IN ('run','model_call','preflight') ORDER BY seq DESC LIMIT ?]], { cursor, CHUNK })
    end
    if not found then return nil, why end
    if #found == 0 then break end
    local oldest = nil
    for _, row in ipairs(found) do
      scanned = scanned + 1
      local at = tonumber(row.at)
      cursor = tonumber(row.seq)
      if at then
        if not oldest or at < oldest then oldest = at end
        local run_id = tostring(row.run_id or '')
        local kind = tostring(row.kind or '')
        if at >= since and run_id ~= '' then
          local entry = runs[run_id]
          if kind == 'run' and tostring(row.phase) == 'start' then
            if not entry then entry = { run_id = run_id }; runs[run_id] = entry; order[#order + 1] = entry end
            if not entry.at or at < entry.at then entry.at = at end
          elseif kind == 'model_call' and tostring(row.phase) == 'start' then
            if not entry then entry = { run_id = run_id }; runs[run_id] = entry; order[#order + 1] = entry end
            if not entry.call or at < entry.call then entry.call = at end
          elseif kind == 'preflight' then
            -- Only THAT one exists: the payload is read for the worst five below, not for every row
            -- (a payload is the whole phase table, and this walk must stay cheap).
            preflights[run_id] = true
          end
        end
      end
    end
    if #found < CHUNK then break end
    if not oldest or oldest < since then
      -- Everything older than the window: the walk is done. Nothing was skipped inside it.
      break
    end
    if scanned > 200000 then complete = false; break end
  end
  -- The window's turns: a run whose start and first model call are both in it.
  local turns = {}
  for _, entry in ipairs(order) do
    if entry.at and entry.call then
      turns[#turns + 1] = { run_id = entry.run_id, at = entry.at,
        gap_ms = math.floor((entry.call - entry.at) * 1000 + 0.5) }
    end
  end
  table.sort(turns, function(a, b) return a.at < b.at end)
  local gaps = {}
  for _, turn in ipairs(turns) do gaps[#gaps + 1] = turn.gap_ms end
  table.sort(gaps)
  local over2, over5 = 0, 0
  for _, gap in ipairs(gaps) do
    if gap > 2000 then over2 = over2 + 1 end
    if gap > 5000 then over5 = over5 + 1 end
  end
  -- The worst five, each with the phase its own preflight row named (read only for these five).
  local worst = {}
  for index = #turns, 1, -1 do
    if #worst >= 5 then break end
    local turn = turns[index]
    local slow
    if preflights[turn.run_id] then
      local found = query([[SELECT payload FROM harness_events WHERE run_id=? AND kind='preflight'
        ORDER BY seq DESC LIMIT 1]], { turn.run_id })
      if found and found[1] then
        local ok, decoded = pcall(json.decode, found[1].payload)
        if ok and type(decoded) == 'table' then slow = decoded.slow end
      end
    end
    worst[#worst + 1] = { run_id = turn.run_id, at = turn.at, gap_ms = turn.gap_ms, slow = slow }
  end
  return { since_hours = hours, complete = complete, scanned = scanned, turns = #turns,
    median_ms = percentile(gaps, 0.5), p90_ms = percentile(gaps, 0.9),
    over_2s = over2, over_5s = over5, max_ms = gaps[#gaps], worst = worst }
end

local function seconds(ms)
  if not ms then return 'unknown' end
  return string.format('%.2f s', ms / 1000)
end

function M.report(opts)
  local measured, why = M.measure(opts)
  if not measured then
    print('stalls: the ledger could not be read (' .. tostring(why) .. ')')
    return 1
  end
  if measured.turns == 0 then
    print(string.format('stalls: no turn in the last %gh reached a model call (%d events read)',
      measured.since_hours, measured.scanned))
    return 0
  end
  print(string.format('run start -> first model call, last %gh: %d turn(s)%s', measured.since_hours,
    measured.turns, measured.complete and '' or ' (window truncated)'))
  print(string.format('  median %s   p90 %s   over 2 s: %d   over 5 s: %d   worst %s',
    seconds(measured.median_ms), seconds(measured.p90_ms), measured.over_2s, measured.over_5s,
    seconds(measured.max_ms)))
  print('  worst five (started, from run start to the model call, and the phase that run named):')
  for _, item in ipairs(measured.worst or {}) do
    local when = os.date('%Y-%m-%d %H:%M:%S', math.floor(item.at))
    print(string.format('    %s  %8s  %s', when, seconds(item.gap_ms), item.slow or '(no phase named)'))
  end
  return 0
end

function M.cli(args)
  local opts, as_json = {}, false
  for index = 2, #args do
    local word = tostring(args[index])
    local since = word:match('^%-%-since=(.+)$')
    if since then opts.since_hours = tonumber(since)
    elseif word == '--since' and args[index + 1] then opts.since_hours = tonumber(args[index + 1])
    elseif word == '--json' then as_json = true end
  end
  if as_json then
    local measured, why = M.measure(opts)
    if not measured then print(json.encode({ error = 'ledger_unreadable', detail = tostring(why) })); return 1 end
    print(json.encode(measured))
    return 0
  end
  return M.report(opts)
end

return M
