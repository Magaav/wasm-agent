-- Durable, per-request accounting. Pi's usage categories are disjoint: input
-- means uncached input; reasoning is already included in output. Never turn
-- absent provider usage or absent prices into a claim of zero cost.
local json = dofile("lua/vendor/json.lua")
local redact = dofile("lua/core/redact.lua")
local M = {}
local ready = false

local function sql(method, statement, params)
  local result = host[method](statement, json.encode(params or {}))
  if type(result) == "string" then result = json.decode(result) end
  if type(result) == "table" and result.error then error(result.error) end
  return result
end

function M.setup()
  if ready then return end
  sql("sql_exec", [[CREATE TABLE IF NOT EXISTS harness_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
    session_id TEXT NOT NULL, run_id TEXT NOT NULL, span_id TEXT NOT NULL,
    kind TEXT NOT NULL, phase TEXT NOT NULL, at REAL NOT NULL, payload TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS harness_events_session ON harness_events(session_id,seq);
    CREATE INDEX IF NOT EXISTS harness_events_span ON harness_events(span_id,phase);]])
  ready = true
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

function M.event(session_id, turn_id, span_id, kind, phase, payload)
  if not session_id or session_id == "" then return end
  M.setup()
  sql("sql_exec", "INSERT INTO harness_events(id,session_id,run_id,span_id,kind,phase,at,payload) VALUES(?,?,?,?,?,?,?,?)",
    {host.uuid(), session_id, turn_id or "", span_id or "", kind, phase, host.now(), json.encode(payload or {})})
end

function M.start(opts, kind, payload)
  opts = opts or {}
  local span = {id=host.uuid(), session_id=opts.session_id, turn_id=opts.turn_id,
    kind=kind or "llm", started=M.clock()}
  M.event(span.session_id, span.turn_id, span.id, span.kind, "start", payload)
  return span
end

function M.finish(span, payload)
  payload = payload or {}
  payload.ms = math.max(0, math.floor(M.clock() - span.started))
  payload.clock = host.monotonic_ms and "monotonic" or "wall-fallback"
  if payload.error then payload.error = redact.text(tostring(payload.error)) end
  M.event(span.session_id, span.turn_id, span.id, span.kind, "end", payload)
  return payload
end

-- Hash the source actually selected by the same disk/embedded rule as dofile.
-- No environment-file contents, authorization headers, or prompt text are stored.
local runtime
function M.runtime()
  if runtime then return runtime end
  local root = host.getenv("WASM_AGENT_LUA_ROOT") or ""
  local sources = {}
  for _, name in ipairs({"agent", "provider", "memory", "tools", "telemetry", "tool_output", "model_window"}) do
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
  local rows
  if session_id=="*" then
    rows=sql("sql_query","SELECT * FROM harness_events WHERE at>=? AND seq>? ORDER BY seq LIMIT ?",
      {tonumber(since) or 0,tonumber(cursor) or 0,limit})
  else
    rows = sql("sql_query", "SELECT * FROM harness_events WHERE session_id=? AND seq>? ORDER BY seq LIMIT ?",
      {session_id, tonumber(cursor) or 0, limit})
  end
  for _, row in ipairs(rows) do row.payload = json.decode(row.payload) end
  return {events=rows, next_cursor=rows[#rows] and rows[#rows].seq or tonumber(cursor) or 0,
    has_more=#rows == limit, session_id=session_id, schema_version=1}
end

local function empty()
  return {calls=0, failed=0, missing_usage=0, missing_cache=0, unpriced=0,
    prompt=0, input=0, cacheRead=0, cacheWrite=0, output=0, reasoning=0,
    reasoning_unknown=0, cost=0, ms=0}
end
local function add(total, data)
  total.calls = total.calls + 1
  total.failed = total.failed + (data.ok == false and 1 or 0)
  total.ms = total.ms + (data.ms or 0)
  local u = data.normalized or {}
  if not u.known then total.missing_usage = total.missing_usage + 1 end
  if not u.cache_known then total.missing_cache = total.missing_cache + 1 end
  if not u.cost_known then total.unpriced = total.unpriced + 1 end
  if u.reasoning == nil then total.reasoning_unknown = total.reasoning_unknown + 1 end
  for _, key in ipairs({"prompt","input","cacheRead","cacheWrite","output","reasoning","cost"}) do
    total[key] = total[key] + (u[key] or 0)
  end
end

local snapshots = {}
function M.snapshot(session_id)
  if not session_id or session_id == "" then return {available=false, scope="no session"} end
  M.setup()
  local cached = snapshots[session_id]
  if cached and M.clock() - cached.at < 2000 then return cached.value end
  local rows = sql("sql_query", "SELECT seq,span_id,run_id,kind,phase,at,payload FROM harness_events WHERE session_id=? ORDER BY seq", {session_id})
  local report = {available=#rows>0, scope="session", session_id=session_id, events=#rows,
    since=rows[1] and rows[1].at, total=empty(), inference=empty(), compaction=empty(),
    tool_calls=0, tool_failures=0, tool_ms=0, pending=0, turns=0, incomplete_turns=0,repeated_tools=0,turn_ms=0,
    compaction_failures=0, errors={}, runtime=M.runtime(), verified_success_rate=false}
  local active, durations, turn_ids, tool_keys, turn_durations = {}, {}, {}, {}, {}
  for _, row in ipairs(rows) do
    local p = json.decode(row.payload)
    if row.kind == "turn" then
      if not turn_ids[row.run_id] then report.turns=report.turns+1; turn_ids[row.run_id]=true end
      if p.outcome ~= "answered" then report.incomplete_turns=report.incomplete_turns+1 end
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
      if row.kind == "llm" or row.kind == "summary" then
        add(report.total, p)
        add(row.kind == "summary" and report.compaction or report.inference, p)
        durations[#durations+1] = p.ms or 0
        if row.kind == "llm" then
          report.last = p
          report.last_request = start or report.last_request
        end
      elseif row.kind == "tool" then
        report.tool_calls = report.tool_calls + 1
        report.tool_ms = report.tool_ms + (p.ms or 0)
        report.tool_failures = report.tool_failures + (p.ok == false and 1 or 0)
      elseif row.kind=='turn_span' then
        report.turn_ms=report.turn_ms+(p.ms or 0)
        turn_durations[#turn_durations+1]=p.ms or 0
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
  for _ in pairs(active) do report.pending = report.pending + 1 end
  table.sort(durations)
  report.request_p50_ms = durations[math.max(1,math.ceil(#durations*.5))]
  report.request_p95_ms = durations[math.max(1,math.ceil(#durations*.95))]
  table.sort(turn_durations)
  report.turn_p50_ms=turn_durations[math.max(1,math.ceil(#turn_durations*.5))]
  report.turn_p95_ms=turn_durations[math.max(1,math.ceil(#turn_durations*.95))]
  report.total.total = report.total.prompt + report.total.output
  report.total.cost_known = report.total.unpriced == 0 and report.total.calls > 0
  report.total.cache_known = report.total.missing_cache == 0 and report.total.calls > 0
  local session=sql("sql_query","SELECT summarized_until,summary FROM sessions WHERE id=?",{session_id})[1] or {}
  local coverage=sql("sql_query","SELECT COUNT(*) AS rows,MIN(seq) AS first_seq,MAX(seq) AS last_seq FROM messages WHERE session_id=? AND seq>? AND role<>'summary'",{session_id,session.summarized_until or 0})[1] or {}
  report.context={summary_watermark=session.summarized_until or 0,summary_bytes=#(session.summary or ""),
    unsummarized_rows=coverage.rows,first_seq=coverage.first_seq,last_seq=coverage.last_seq,
    row_cap=false,estimate_is_not_a_tokenizer=true,summary_is_lossy=true}
  snapshots[session_id] = {at=M.clock(), value=report}
  return report
end

return M
