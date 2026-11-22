-- The number Victor asked to be able to see: how long a turn takes to REACH the model
-- (change/start-instant, item 5, 22/11).
--
--   wa stalls [--since <hours>] [--json]
--
-- READ-ONLY. It answers one question from the ledger's own rows: for every run in the window, the time
-- between the KEYPRESS THE HOST SAW and that run's first model_call/start - and it names the phase when
-- the run's own preflight row says which one was slow (lua/core/agent.lua, the per-phase clock).
--
-- FROM THE KEYPRESS, NOT FROM THE RUN'S FIRST RECORD (change/chat-start-guard, item 3). A run's first
-- record is written once the turn has begun, so a wait BEFORE it was invisible: measured on d7597689,
-- 20.6 s of silence after Enter, and wa stalls reported a 0.0 s turn - every one of those waits was
-- invisible to it. The keypress is its own row (kind=input, phase=submit: lua/core/chat.lua, stamped
-- with the host's clock from host.input_take), and a run is paired with the latest submit in its own
-- session at or before its start. A run with no such row (a wake, a sentinel, a scripted prompt) is
-- still measured, from run/start, and says so: from_run counts them.
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

-- run_id -> { at = run/start seconds, call = first model_call/start seconds, session = its session }
function M.measure(opts)
  opts = opts or {}
  local hours = tonumber(opts.since_hours) or 24
  local since = host.now() - hours * 3600
  local runs, order = {}, {}
  -- session_id -> { <submit seconds>, ... }: THE KEYPRESSES, which is where a turn is measured from
  -- (see the header). Grouped by session so a run is paired with the keypress that asked for IT.
  local submits = {}
  local scanned, cursor, complete = 0, nil, true
  local preflights = {}
  while true do
    local found, why
    if cursor == nil then
      found, why = query([[SELECT seq,run_id,session_id,kind,phase,at FROM harness_events
        WHERE kind IN ('run','model_call','preflight','input') ORDER BY seq DESC LIMIT ?]], { CHUNK })
    else
      found, why = query([[SELECT seq,run_id,session_id,kind,phase,at FROM harness_events
        WHERE seq<? AND kind IN ('run','model_call','preflight','input') ORDER BY seq DESC LIMIT ?]], { cursor, CHUNK })
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
        if at >= since then
          if kind == 'input' then
            -- The reader's keypress, stamped where the host saw it. No run_id of its own: the run does
            -- not exist yet when the line is typed, which is the whole point of this row.
            local session = tostring(row.session_id or '')
            if session ~= '' and tostring(row.phase) == 'submit' then
              submits[session] = submits[session] or {}
              local list = submits[session]
              list[#list + 1] = at
            end
          elseif run_id ~= '' then
            local entry = runs[run_id]
            if kind == 'run' and tostring(row.phase) == 'start' then
              if not entry then entry = { run_id = run_id }; runs[run_id] = entry; order[#order + 1] = entry end
              entry.session = entry.session or tostring(row.session_id or '')
              if not entry.at or at < entry.at then entry.at = at end
            elseif kind == 'model_call' and tostring(row.phase) == 'start' then
              if not entry then entry = { run_id = run_id }; runs[run_id] = entry; order[#order + 1] = entry end
              entry.session = entry.session or tostring(row.session_id or '')
              if not entry.call or at < entry.call then entry.call = at end
            elseif kind == 'preflight' then
              -- Only THAT one exists: the payload is read for the worst five below, not for every row
              -- (a payload is the whole phase table, and this walk must stay cheap).
              preflights[run_id] = true
            end
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
  for _, list in pairs(submits) do table.sort(list) end
  -- The latest keypress in this run's own session at or before its start: the line that asked for it.
  local function keypress_for(entry)
    local list = submits[tostring(entry.session or '')]
    if not list or #list == 0 then return nil end
    local low, high, found = 1, #list, nil
    while low <= high do
      local mid = math.floor((low + high) / 2)
      if list[mid] <= entry.at then found = list[mid]; low = mid + 1 else high = mid - 1 end
    end
    return found
  end
  -- The window's turns: a run whose start and first model call are both in it.
  local turns = {}
  local from_keypress, from_run = 0, 0
  for _, entry in ipairs(order) do
    if entry.at and entry.call then
      local keypress = keypress_for(entry)
      local start = keypress or entry.at
      if keypress then from_keypress = from_keypress + 1 else from_run = from_run + 1 end
      turns[#turns + 1] = { run_id = entry.run_id, at = entry.at, from = keypress and 'enter' or 'run',
        keypress = keypress, pre_run_ms = keypress and math.floor((entry.at - keypress) * 1000 + 0.5) or nil,
        gap_ms = math.floor((entry.call - start) * 1000 + 0.5) }
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
  -- THE WORST FIVE ARE THE FIVE LARGEST, not the five newest (fixed 22/11, change/chat-start-guard item
  -- 3): this walked the turns backwards, so a quiet afternoon pushed every slow turn out of the list and
  -- the row that exists to name the slow ones named the last five of anything.
  local ranked = {}
  for index, turn in ipairs(turns) do ranked[index] = turn end
  table.sort(ranked, function(a, b)
    if a.gap_ms ~= b.gap_ms then return a.gap_ms > b.gap_ms end
    return a.at > b.at
  end)
  local worst = {}
  for index = 1, math.min(#ranked, 5) do
    local turn = ranked[index]
    local slow
    if preflights[turn.run_id] then
      local found = query([[SELECT payload FROM harness_events WHERE run_id=? AND kind='preflight'
        ORDER BY seq DESC LIMIT 1]], { turn.run_id })
      if found and found[1] then
        local ok, decoded = pcall(json.decode, found[1].payload)
        if ok and type(decoded) == 'table' then slow = decoded.slow end
      end
    end
    worst[#worst + 1] = { run_id = turn.run_id, at = turn.at, gap_ms = turn.gap_ms, from = turn.from,
      pre_run_ms = turn.pre_run_ms, slow = slow }
  end
  return { since_hours = hours, complete = complete, scanned = scanned, turns = #turns,
    from_keypress = from_keypress, from_run = from_run,
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
  local counted = string.format('%d from the keypress, %d from run start',
    tonumber(measured.from_keypress) or 0, tonumber(measured.from_run) or 0)
  if not measured.complete then counted = counted .. ', window truncated' end
  print(string.format('Enter -> first model call, last %gh: %d turn(s) - %s',
    measured.since_hours, measured.turns, counted))
  print(string.format('  median %s   p90 %s   over 2 s: %d   over 5 s: %d   worst %s',
    seconds(measured.median_ms), seconds(measured.p90_ms), measured.over_2s, measured.over_5s,
    seconds(measured.max_ms)))
  print('  the five slowest (and how much of each was spent BEFORE the run began, with the phase that run named):')
  for _, item in ipairs(measured.worst or {}) do
    local when = os.date('%Y-%m-%d %H:%M:%S', math.floor(item.at))
    local before = tonumber(item.pre_run_ms)
    local waited = before and before >= 1 and string.format(' (%.2f s of it before the run)', before / 1000) or ''
    print(string.format('    %s  %8s  %s%s', when, seconds(item.gap_ms), item.slow or '(no phase named)', waited))
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
