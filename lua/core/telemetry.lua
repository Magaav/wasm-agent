-- Durable, per-request accounting. Pi's usage categories are disjoint: input
-- means uncached input; reasoning is already included in output. Never turn
-- absent provider usage or absent prices into a claim of zero cost.
local json = dofile("lua/vendor/json.lua")
local redact = dofile("lua/core/redact.lua")
local M = {}
local ready = false
-- Set when a write failed in a way that says the table is absent, so the next write replays the DDL
-- instead of trusting the process-wide migration flag.
local schema_missing = false

-- A telemetry record is worth less than the run it describes, so nothing in this module may raise.
-- Every statement here is issued against a database that several interpreters, several processes and
-- the UI's own polling all share, so `database is locked` is ordinary weather on a busy node and not
-- a run error. A write that cannot proceed is retried briefly; if it still cannot proceed it is
-- DROPPED with one line on the node's log (`host.log` is the `[lua] ...` channel the rest of the node
-- writes to) and counted in `M.drops()`. The old `error(result.error)` here turned that weather into
-- `lua/core/telemetry.lua:12: database is locked` and killed whatever run happened to be writing.
local function number_env(name, default, low, high)
  local raw = host.getenv and host.getenv(name) or nil
  local value = tonumber(raw)
  if not value then return default end
  return math.max(low, math.min(high, value))
end

-- One attempt can cost as much as the connection's own busy wait (`PRAGMA busy_timeout=5000`, set once
-- per connection in rust/wa-host/src/main.rs) before SQLite refuses it. That patience is not this
-- module's to shorten: the connection is shared with the transcript's own writes, and a shorter timeout
-- there would make a *turn* fail sooner - a telemetry "fix" that breaks the run it is protecting. So the
-- knobs are how many attempts a write may make, and a cap on the whole write; the worst case one record
-- can cost a run is therefore attempts x 5s, once, and nothing for the next `cooldown` - and the line
-- that reports the loss says how many attempts it made and how long it spent.
local function attempts_max() return number_env("WASM_AGENT_TELEMETRY_WRITE_ATTEMPTS", 2, 1, 20) end
local function retry_budget_ms() return number_env("WASM_AGENT_TELEMETRY_WRITE_MS", 8000, 0, 60000) end
-- After one refusal the same run does not pay that wait again for every later event: for this long
-- each further write is dropped immediately - each still with its own visible line, never silently.
local function cooldown_ms() return number_env("WASM_AGENT_TELEMETRY_WRITE_COOLDOWN_MS", 5000, 0, 600000) end
local PAUSE_START_MS, PAUSE_MAX_MS = 25, 400

local drops = {count = 0, last_at = nil, last_error = nil, label = nil, cooldown_until = 0}

local function log_line(text)
  -- The one audible record of a loss. Guarded because a missing `host.log` (an older host) must not
  -- make the loss itself fatal.
  if host.log then pcall(host.log, text) end
end

local function note_drop(label, reason, attempts, spent_ms)
  drops.count, drops.attempts = drops.count + 1, attempts
  drops.last_at, drops.last_error, drops.label = host.now(), reason, label
  log_line(string.format(
    "telemetry: dropped %s after %d attempt(s) in %dms: %s - this record is lost, the run is not",
    label, attempts, spent_ms, tostring(reason)))
end

-- One host call, one pcall: a host that is missing, a malformed payload that json.encode refuses, a
-- result that is not JSON - none of them can leave this function as an error. It returns the result
-- table or `nil, reason`.
local function attempt(method, statement, params)
  local ok, raw = pcall(function() return host[method](statement, json.encode(params or {})) end)
  if not ok then return nil, tostring(raw) end
  local result = raw
  if type(result) == "string" then
    local decoded
    ok, decoded = pcall(json.decode, result)
    if not ok then return nil, "undecodable_result" end
    result = decoded
  end
  if type(result) ~= "table" then return nil, "no_result_from_host" end
  if result.error then return nil, tostring(result.error) end
  return result
end

-- Reads. An unreadable ledger is reported as an unreadable ledger rather than raised: the callers are
-- the UI's model poll, the observability export and a child's receipt, and each of them can say
-- "unknown" - none of them can survive a Lua error here.
local function query(statement, params)
  local rows, reason = attempt("sql_query", statement, params)
  if not rows then return nil, reason end
  return rows
end

-- Writes. Retried within a bounded budget, then dropped and logged. Returns the result or `nil, reason`.
local function write(label, statement, params)
  local limit, budget = attempts_max(), retry_budget_ms()
  local started = M.clock()
  if started < drops.cooldown_until then
    note_drop(label, "write lock still held by another connection (cooldown)", 0, 0)
    return nil, "cooldown"
  end
  local attempts, reason, pause = 0, nil, PAUSE_START_MS
  while true do
    attempts = attempts + 1
    local result, failure = attempt("sql_exec", statement, params)
    if result then return result end
    reason = failure
    if attempts >= limit then break end
    if M.clock() - started >= budget then break end
    if host.sleep then host.sleep(tostring(pause)) end
    pause = math.min(PAUSE_MAX_MS, pause * 2)
  end
  local spent = math.floor(M.clock() - started)
  drops.cooldown_until = M.clock() + cooldown_ms()
  note_drop(label, reason or "unknown", attempts, spent)
  return nil, reason
end

function M.setup()
  if ready then return true end
  -- The DDL is a WRITE, and every interpreter opens its own connection: replaying it in every
  -- interpreter was a write on the telemetry path that only the first interpreter in the process
  -- needs. `lua/core/memory.lua` already records that migration once per process
  -- (`host.db_ready`/`host.mark_db_ready`), and `memory.setup` calls this setup before marking it, so
  -- the flag already covers this schema. A migration this module never marked is not assumed, and a
  -- write that failed because the table is absent replays the DDL rather than trusting the flag.
  if host.db_ready and host.db_ready() and not schema_missing then
    ready = true
    return true
  end
  local result = write("schema", [[CREATE TABLE IF NOT EXISTS harness_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
    session_id TEXT NOT NULL, run_id TEXT NOT NULL, span_id TEXT NOT NULL,
    kind TEXT NOT NULL, phase TEXT NOT NULL, at REAL NOT NULL, payload TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS harness_events_session ON harness_events(session_id,seq);
    CREATE INDEX IF NOT EXISTS harness_events_span ON harness_events(span_id,phase);
    CREATE TABLE IF NOT EXISTS harness_mutation (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
    INSERT OR IGNORE INTO harness_mutation VALUES(1,0);
    CREATE TRIGGER IF NOT EXISTS harness_updated AFTER UPDATE ON harness_events BEGIN
      UPDATE harness_mutation SET revision=revision+1 WHERE id=1; END;
    CREATE TRIGGER IF NOT EXISTS harness_deleted AFTER DELETE ON harness_events BEGIN
      UPDATE harness_mutation SET revision=revision+1 WHERE id=1; END;]])
  if not result then return false end
  schema_missing, ready = false, true
  return true
end

function M.clock()
  if host.monotonic_ms then return host.monotonic_ms() end
  return host.now() * 1000
end

-- Pi estimates an image at 1200 tokens, not one token per four base64 bytes.
-- This is an estimate, not a promise about a provider's vision tokenizer.
function M.estimate_messages(messages)
  local total=0
  for _,message in ipairs(messages or {}) do
    local copy={}
    for key,value in pairs(message) do copy[key]=value end
    if type(message.content)=="table" then
      copy.content={}
      for _,part in ipairs(message.content) do
        if part.type=="image_url" or part.type=="image" then total=total+1200
        else copy.content[#copy.content+1]=part end
      end
    end
    total=total+math.ceil(#json.encode(copy)/4)
  end
  return total
end

-- Exact JSON byte sizes by message role, plus source-byte subsets that help
-- locate growth. These are not token counts and cannot be added to provider
-- usage. Prompt content itself never enters the diagnostic ledger.
function M.prompt_shape(messages, tools)
  local shape = {system_bytes=0,user_bytes=0,assistant_bytes=0,tool_result_bytes=0,
    other_bytes=0,schema_bytes=#json.encode(tools or {}),reasoning_source_bytes=0,
    tool_arguments_source_bytes=0,messages=0,tool_results=0,tool_calls=0,images=0}
  for _, message in ipairs(messages or {}) do
    shape.messages=shape.messages+1
    local encoded=#json.encode(message)
    if message.role=="system" then shape.system_bytes=shape.system_bytes+encoded
    elseif message.role=="user" then shape.user_bytes=shape.user_bytes+encoded
    elseif message.role=="assistant" then
      shape.assistant_bytes=shape.assistant_bytes+encoded
      shape.reasoning_source_bytes=shape.reasoning_source_bytes+#tostring(message.reasoning_content or "")
      for _, call in ipairs(message.tool_calls or {}) do
        shape.tool_calls=shape.tool_calls+1
        shape.tool_arguments_source_bytes=shape.tool_arguments_source_bytes
          +#tostring((call["function"] or {}).arguments or "")
      end
    elseif message.role=="tool" then
      shape.tool_result_bytes=shape.tool_result_bytes+encoded
      shape.tool_results=shape.tool_results+1
    else shape.other_bytes=shape.other_bytes+encoded end
    if type(message.content)=="table" then
      for _, part in ipairs(message.content) do
        if part.type=="image_url" or part.type=="image" then shape.images=shape.images+1 end
      end
    end
  end
  shape.total_message_bytes=shape.system_bytes+shape.user_bytes+shape.assistant_bytes
    +shape.tool_result_bytes+shape.other_bytes
  return shape
end

local function number(value)
  local n = tonumber(value)
  if n and n >= 0 and n < math.huge then return n end
end

function M.normalize(raw, rates)
  if type(raw) ~= "table" then return {known=false, cache_known=false, cost_known=false} end
  local prompt, output = number(raw.prompt_tokens), number(raw.completion_tokens)
  local detail = raw.prompt_tokens_details or {}
  local read = number(detail.cached_tokens or raw.prompt_cache_hit_tokens or raw.cached_tokens
    or (raw.prompt_cache or {}).cached_tokens)
  local write = number(detail.cache_write_tokens) or 0
  local reasoning = number((raw.completion_tokens_details or {}).reasoning_tokens)
  local known = prompt ~= nil and output ~= nil
  local cache_known = read ~= nil and prompt ~= nil and read + write <= prompt
  local result = {known=known, cache_known=cache_known, cost_known=false,
    prompt=prompt, output=output, cacheRead=read, cacheWrite=write,
    reasoning=reasoning, total=known and (prompt + output) or nil}
  if read and prompt and read + write > prompt then result.issue = "cache_exceeds_input" end
  if reasoning and output and reasoning>output then result.issue="reasoning_exceeds_output" end
  if cache_known then result.input = prompt - read - write end
  if known and number(raw.total_tokens) and raw.total_tokens ~= result.total then
    result.issue = "provider_total_mismatch"
  end
  if known and cache_known and type(rates) == "table" and number(rates.input)
      and number(rates.output) and (read == 0 or number(rates.cacheRead))
      and (write == 0 or number(rates.cacheWrite)) then
    result.cost = (result.input * rates.input + read * (rates.cacheRead or 0)
      + write * (rates.cacheWrite or 0) + output * rates.output) / 1000000
    result.cost_known, result.rate_snapshot = true, rates
  end
  return result
end

function M.event(session_id, run_id, span_id, kind, phase, payload)
  if not session_id or session_id == "" then return end
  -- `setup` may have dropped its own DDL; the line for that loss is already written.
  if not M.setup() then return end
  local written, reason = write("harness_events insert", "INSERT INTO harness_events(id,session_id,run_id,span_id,kind,phase,at,payload) VALUES(?,?,?,?,?,?,?,?)",
    {host.uuid(), session_id, run_id or "", span_id or "", kind, phase, host.now(), json.encode(payload or {})})
  -- "no such table" is the one refusal worth answering differently: it says the schema is not there,
  -- so the next event replays the DDL instead of trusting the process-wide flag.
  if not written and reason and tostring(reason):find("no such table", 1, true) then
    schema_missing, ready = true, false
  end
end

function M.start(opts, kind, payload)
  opts = opts or {}
  local span = {id=host.uuid(), session_id=opts.session_id, run_id=opts.run_id,
    kind=kind or "model_call", started=M.clock()}
  M.event(span.session_id, span.run_id, span.id, span.kind, "start", payload)
  return span
end

function M.finish(span, payload)
  payload = payload or {}
  payload.ms = math.max(0, math.floor(M.clock() - span.started))
  payload.clock = host.monotonic_ms and "monotonic" or "wall-fallback"
  if payload.error then payload.error = redact.text(tostring(payload.error)) end
  M.event(span.session_id, span.run_id, span.id, span.kind, "end", payload)
  return payload
end

-- Hash the source actually selected by the same disk/embedded rule as dofile.
-- No environment-file contents, authorization headers, or prompt text are stored.
local runtime
function M.runtime()
  if runtime then return runtime end
  local root = host.getenv("WASM_AGENT_LUA_ROOT") or ""
  local sources = {}
  for _, name in ipairs({"agent", "provider", "memory", "tools", "telemetry", "tool_output", "model_window", "file_tools", "evidence_view", "diagnose", "prefix_audit", "openai_sub", "openai_sub_bridge"}) do
    local key = "lua/core/" .. name .. ".lua"
    sources[name] = (LOADED_SOURCES or {})[key] or "unavailable (older host)"
  end
  local native = host.runtime_info and host.runtime_info() or {}
  if type(native) == "string" then native = json.decode(native) end
  runtime = {lua_mode=root ~= "" and "disk" or "embedded", lua_root=root,
    source_hash=host.sha256(json.encode(sources)), sources=sources, native=native,
    schema_version=1}
  return runtime
end

function M.events(session_id, cursor, limit, since)
  M.setup()
  limit = math.max(1, math.min(1000, tonumber(limit) or 500))
  local rows, reason
  if session_id=="*" then
    rows, reason = query("SELECT * FROM harness_events WHERE at>=? AND seq>? ORDER BY seq LIMIT ?",
      {tonumber(since) or 0,tonumber(cursor) or 0,limit})
  else
    rows, reason = query("SELECT * FROM harness_events WHERE session_id=? AND seq>? ORDER BY seq LIMIT ?",
      {session_id, tonumber(cursor) or 0, limit})
  end
  if not rows then
    -- Reported, not raised. `available=false` and `reason` say the ledger could not be read, which is
    -- a different statement from "this session has no events" - the same distinction this file keeps
    -- between a measured zero and an absent number.
    return {events={}, next_cursor=tonumber(cursor) or 0, has_more=false, session_id=session_id,
      schema_version=1, available=false, reason="ledger_unreadable", detail=reason,
      dropped_writes=drops.count}
  end
  for _, row in ipairs(rows) do
    local ok, payload = pcall(json.decode, row.payload)
    row.payload = ok and payload or {unreadable_payload=true}
  end
  return {events=rows, next_cursor=rows[#rows] and rows[#rows].seq or tonumber(cursor) or 0,
    has_more=#rows == limit, session_id=session_id, schema_version=1, available=true,
    dropped_writes=drops.count}
end

local function empty()
  return {calls=0, failed=0, missing_usage=0, missing_cache=0, unpriced=0,
    prompt=0, input=0, cacheRead=0, cacheWrite=0, output=0, reasoning=0,
    reasoning_unknown=0, transport_failed_attempts=0, cost=0, ms=0}
end
local function add(total, data)
  total.calls = total.calls + 1
  total.failed = total.failed + (data.ok == false and 1 or 0)
  total.ms = total.ms + (data.ms or 0)
  total.transport_failed_attempts = total.transport_failed_attempts + (data.transport_failed_attempts or 0)
  local u = data.normalized or {}
  if not u.known then total.missing_usage = total.missing_usage + 1 end
  if not u.cache_known then total.missing_cache = total.missing_cache + 1 end
  if not u.cost_known then total.unpriced = total.unpriced + 1 end
  if u.reasoning == nil then total.reasoning_unknown = total.reasoning_unknown + 1 end
  for _, key in ipairs({"prompt","input","cacheRead","cacheWrite","output","reasoning","cost"}) do
    total[key] = total[key] + (u[key] or 0)
  end
end

local snapshots, snapshot_order = {}, {}
function M.snapshot(session_id)
  if not session_id or session_id == "" then return {available=false, scope="no session"} end
  M.setup()
  -- Covering-index metadata, not historical payloads. Updates/deletes invalidate
  -- even when count and high-water stay unchanged; imports below it change count.
  local heads, problem=query([[SELECT COUNT(*) AS count,MIN(seq) AS first,MAX(seq) AS last,
    (SELECT revision FROM harness_mutation WHERE id=1) AS revision
    FROM harness_events WHERE session_id=?]],{session_id})
  local head=heads and heads[1]
  if not head or head.revision==nil then
    return {available=false,scope="session",reason="ledger_unreadable",detail=problem or "mutation_revision_unavailable",dropped_writes=drops.count}
  end
  local cached=snapshots[session_id]
  if cached and (cached.revision~=head.revision or cached.first~=head.first
      or (head.last or 0)<cached.seq or head.count<cached.value.events) then cached=nil end
  local rows, unreadable=query([[SELECT seq,span_id,run_id,kind,phase,at,payload FROM harness_events
    WHERE session_id=? AND seq>? AND seq<=? ORDER BY seq]],{session_id,cached and cached.seq or 0,head.last or 0})
  if rows and cached and cached.value.events+#rows~=head.count then
    cached=nil
    rows,unreadable=query([[SELECT seq,span_id,run_id,kind,phase,at,payload FROM harness_events
      WHERE session_id=? AND seq<=? ORDER BY seq]],{session_id,head.last or 0})
  end
  if not rows then
    -- An unreadable ledger answers "unknown", and does not answer as a session with no events. The
    -- degraded shape is the one the callers already handle (`wa_model` passes an unavailable
    -- observation to the page), and it is deliberately not cached, so the next poll tries again.
    return {available=false, scope="session", session_id=session_id, events=nil,
      reason="ledger_unreadable", detail=unreadable, dropped_writes=drops.count,
      runtime=M.runtime(), verified_success_rate=false}
  end
  -- Do not commit a partial accumulator if another connection repaired/deleted
  -- evidence between our metadata and payload reads. Appends above the pin wait
  -- for the next read; no elapsed-time stale-success shortcut is used.
  local revision=query("SELECT revision FROM harness_mutation WHERE id=1")
  if not revision or not revision[1] or revision[1].revision~=head.revision
      or (cached and cached.value.events or 0)+#rows~=head.count then
    snapshots[session_id]=nil
    return {available=false,scope="session",reason="ledger_changed_during_read",dropped_writes=drops.count}
  end
  local report = cached and cached.value or {available=false, scope="session", session_id=session_id, events=0,
    total=empty(), inference=empty(), compaction=empty(),
    tool_calls=0, tool_failures=0, tool_ms=0, pending=0, runs=0, incomplete_runs=0,repeated_tools=0,run_ms=0,
    compaction_failures=0, errors={}, runtime=M.runtime(), verified_success_rate=false,
    dropped_writes=drops.count}
  local active, durations, run_ids, tool_keys, run_durations = {}, {}, {}, {}, {}
  if cached then active,durations,run_ids,tool_keys,run_durations=cached.active,cached.durations,cached.run_ids,cached.tool_keys,cached.run_durations end
  for _, row in ipairs(rows) do
    local ok,p=pcall(json.decode,row.payload)
    if not ok or type(p)~="table" then
      snapshots[session_id]=nil
      return {available=false,scope="session",reason="ledger_unreadable",detail="unreadable_payload at seq "..tostring(row.seq),dropped_writes=drops.count}
    end
    if not report.since then report.since=row.at end
    if row.kind == "step" then
      if not run_ids[row.run_id] then report.runs=report.runs+1; run_ids[row.run_id]=true end
      if p.outcome ~= "answered" then report.incomplete_runs=report.incomplete_runs+1 end
    elseif row.phase == "start" then
      active[row.span_id] = p
      if row.kind=="tool" then
        local key=tostring(p.name)..":"..tostring(p.arguments_hash)
        if tool_keys[key] then report.repeated_tools=report.repeated_tools+1 end
        tool_keys[key]=true
      end
    elseif row.phase == "end" then
      local start = active[row.span_id]
      active[row.span_id] = nil
      if row.kind == "model_call" or row.kind == "summary" then
        add(report.total, p)
        add(row.kind == "summary" and report.compaction or report.inference, p)
        durations[#durations+1] = p.ms or 0
        if row.kind == "model_call" then
          report.last = p
          report.last_request = start or report.last_request
        end
      elseif row.kind == "tool" then
        report.tool_calls = report.tool_calls + 1
        report.tool_ms = report.tool_ms + (p.ms or 0)
        report.tool_failures = report.tool_failures + (p.ok == false and 1 or 0)
      elseif row.kind=='run' then
        report.run_ms=report.run_ms+(p.ms or 0)
        run_durations[#run_durations+1]=p.ms or 0
      end
      if p.ok == false then
        report.errors[#report.errors+1] = {kind=row.kind, at=row.at, error=p.error, code=p.code, name=p.name}
        if #report.errors > 10 then table.remove(report.errors,1) end
      end
    elseif row.kind == "compact" then
      report.last_compaction = p
      if p.ok == false then report.compaction_failures=report.compaction_failures+1 end
    end
  end
  report.events=report.events+#rows;report.available=report.events>0;report.pending=0
  report.dropped_writes=drops.count
  for _ in pairs(active) do report.pending = report.pending + 1 end
  if #rows>0 then table.sort(durations);table.sort(run_durations) end
  report.request_p50_ms = durations[math.max(1,math.ceil(#durations*.5))]
  report.request_p95_ms = durations[math.max(1,math.ceil(#durations*.95))]
  report.run_p50_ms=run_durations[math.max(1,math.ceil(#run_durations*.5))]
  report.run_p95_ms=run_durations[math.max(1,math.ceil(#run_durations*.95))]
  report.total.total = report.total.prompt + report.total.output
  report.total.cost_known = report.total.unpriced == 0 and report.total.calls > 0
    and report.total.transport_failed_attempts == 0
  report.total.cache_known = report.total.missing_cache == 0 and report.total.calls > 0
  -- The two context reads are not allowed to take the report down with them: what a ledger that can be
  -- read says with an unavailable context block is still more than a Lua error to the caller.
  local session_row = query("SELECT summarized_until,length(CAST(summary AS BLOB)) AS summary_bytes FROM sessions WHERE id=?",{session_id})
  local coverage_row = query("SELECT COUNT(*) AS rows,MIN(seq) AS first_seq,MAX(seq) AS last_seq FROM messages WHERE session_id=? AND seq>? AND role<>'summary'",
    {session_id, (session_row and session_row[1] or {}).summarized_until or 0})
  local session, coverage = (session_row or {})[1] or {}, (coverage_row or {})[1] or {}
  report.context={summary_watermark=session.summarized_until or 0,summary_bytes=session.summary_bytes or 0,
    unsummarized_rows=coverage.rows,first_seq=coverage.first_seq,last_seq=coverage.last_seq,
    row_cap=false,estimate_is_not_a_tokenizer=true,summary_is_lossy=true}
  if not (session_row and coverage_row) then
    report.context={unavailable=true, reason="ledger_unreadable"}
  end
  snapshots[session_id] = {seq=head.last or 0,revision=head.revision,first=head.first,value=report,
    active=active,durations=durations,run_ids=run_ids,tool_keys=tool_keys,run_durations=run_durations}
  for i,id in ipairs(snapshot_order) do if id==session_id then table.remove(snapshot_order,i);break end end
  snapshot_order[#snapshot_order+1]=session_id
  if #snapshot_order>8 then snapshots[table.remove(snapshot_order,1)]=nil end
  -- Detached public snapshot: consumers cannot mutate the retained exact accumulator.
  return json.decode(json.encode(report))
end

-- What telemetry lost: the count of dropped writes, the last refusal and when. A caller that wants
-- more than the one line on the log reads this; nothing here claims a record was stored. It is also
-- carried in `snapshot().dropped_writes` and `events().dropped_writes`, so a session's own report says
-- whether its ledger is complete.
function M.drops()
  return {count=drops.count, last_at=drops.last_at, last_error=drops.last_error, label=drops.label,
    attempts=drops.attempts, retry_budget_ms=retry_budget_ms(), attempts_max=attempts_max(),
    cooldown_ms=cooldown_ms()}
end

return M
