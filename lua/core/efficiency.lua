-- Efficiency report: what the last model call actually sent, what it cost, and
-- which part of the request did not come from the provider's prefix cache.
--
-- Deterministic and read-only with respect to the model. It reads the durable
-- harness ledger (`harness_events`) and the transcript, computes the report, and
-- (when a caller passes the live agent) writes the exact prefix to a file a human
-- can open. It never calls a provider.
--
-- The numbers are the provider's own usage where the provider reported it, and
-- the configured rates (`WASM_AGENT_MODEL_RATES`) where a price is asked for. A
-- missing price stays visible as "unpriced" rather than becoming a free call, and
-- a missing cache figure stays "unknown" rather than becoming a zero - the same
-- rule `telemetry.normalize` and `docs/OBSERVABILITY.md` already hold.
--
-- This is a gathering tool, not a verdict. The signals it prints are facts for a
-- reader to reason over; `worthy`, "waste" and "at the limit" are not claims this
-- file can support, so it does not make them.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local telemetry = dofile("lua/core/telemetry.lua")
local provider = dofile("lua/core/provider.lua")
local paths = dofile("lua/core/paths.lua")

local M = {}

-- Thousands separators. Lua has no locale formatter, and a 900000-token prompt
-- is unreadable as "900000"; the report is read by eye, so the eye gets help.
local function commas(value)
  local number = math.floor(tonumber(value) or 0)
  local sign = ""
  if number < 0 then sign, number = "-", -number end
  local text = tostring(number)
  local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. out
end

local function percent(part, whole)
  if not whole or whole <= 0 then return 0 end
  return 100 * (tonumber(part) or 0) / whole
end

local function money(value)
  if value == nil then return "unpriced" end
  return string.format("$%.6f", value)
end

-- A clickable `file://` URL for a path. Windows gives `C:/...` (the host returns
-- forward slashes), POSIX gives `/...`; both need three slashes after `file:`.
local function file_url(path)
  local text = tostring(path or ""):gsub("\\", "/")
  if text:sub(1, 1) == "/" then return "file://" .. text end
  return "file:///" .. text
end

local function setting(request, key)
  local settings = request.settings
  if type(settings) == "table" and settings[key] ~= nil then return settings[key] end
  return request[key]
end

-- The exact request of the last call, when the session ran in debug mode: the
-- trace of the assistant row carries `request` (agent.lua, round 1 only). Debug
-- is off by default, so this is usually nil and the caller rebuilds instead.
local function find_debug_request(session_id)
  local rows = memory.session_messages(session_id, { limit = 100 })
  for index = #rows, 1, -1 do
    local trace = rows[index].trace
    if type(trace) == "table" then
      for _, span in ipairs(trace) do
        if type(span) == "table" and type(span.request) == "table" then
          return span.request
        end
      end
    end
  end
  return nil
end

-- A human-readable rendering of one request: the system prompt whole, the tools
-- ranked by schema size, and the transcript as an outline with per-message byte
-- sizes. The JSON beside it is the exact bytes; this is the version to read.
function M.prefix_markdown(request, session_id, source)
  local messages = request.messages or {}
  local tools = request.tools or {}
  local system_bytes, transcript_bytes = 0, 0
  for _, message in ipairs(messages) do
    local size = #json.encode(message)
    if message.role == "system" then system_bytes = system_bytes + size
    else transcript_bytes = transcript_bytes + size end
  end
  local lines = {
    "# Request prefix - session " .. tostring(session_id),
    "",
    "source: " .. tostring(source),
    "model: " .. tostring(request.model),
    string.format("tools: %d (%s bytes)", #tools, commas(#json.encode(tools))),
    string.format("messages: %d (system %s bytes, transcript %s bytes)",
      #messages, commas(system_bytes), commas(transcript_bytes)),
    "",
  }
  for index, message in ipairs(messages) do
    if message.role == "system" then
      lines[#lines + 1] = string.format("## system message [%d] (%s bytes)", index, commas(#json.encode(message)))
      lines[#lines + 1] = "```"
      lines[#lines + 1] = tostring(message.content or "")
      lines[#lines + 1] = "```"
      lines[#lines + 1] = ""
    end
  end
  lines[#lines + 1] = string.format("## tools (%d, %s bytes)", #tools, commas(#json.encode(tools)))
  local ranked = {}
  for _, tool in ipairs(tools) do
    local function_ = tool["function"] or {}
    ranked[#ranked + 1] = { name = function_.name or "?", size = #json.encode(tool) }
  end
  table.sort(ranked, function(a, b) return a.size > b.size end)
  for _, row in ipairs(ranked) do
    lines[#lines + 1] = string.format("- %s  %s bytes", row.name, commas(row.size))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("## transcript (%d messages)", #messages)
  for index, message in ipairs(messages) do
    if message.role ~= "system" then
      local preview = tostring(message.content or ""):gsub("\n", " "):sub(1, 72)
      if type(message.tool_calls) == "table" and #message.tool_calls > 0 then
        preview = string.format("<%d tool_call(s)>", #message.tool_calls)
      end
      lines[#lines + 1] = string.format("[%d] %-9s %s bytes  %s",
        index, message.role, commas(#json.encode(message)), preview)
    end
  end
  return table.concat(lines, "\n")
end

-- Write the prefix a human will read. With a debug capture that is the last call
-- exactly; otherwise it is `build_context()` - the same deterministic function
-- that builds the next call, and therefore the prefix the next call will send.
-- The file name is session-derived and stable, so re-running overwrites rather
-- than accumulating, and the report is deterministic.
function M.dump_prefix(agent, session_id)
  if not (host.write_file and session_id and session_id ~= "") then
    return { error = "write_unavailable" }
  end
  local request = find_debug_request(session_id)
  local source = "debug capture (the last call, byte for byte)"
  if not request then
    if not agent then return { error = "no_debug_capture_and_no_agent" } end
    local built, context = pcall(function() return agent:build_context() end)
    if not built or type(context) ~= "table" then return { error = "build_context_failed" } end
    request = { model = agent.model, messages = context, tools = agent.tool_list }
    source = "rebuilt from the transcript (the next call's prefix)"
  end
  local short = tostring(session_id):sub(1, 8)
  local directory = paths.data() .. "/efficiency"
  local json_path = directory .. "/" .. short .. "-prefix.json"
  local markdown_path = directory .. "/" .. short .. "-prefix.md"
  local wrote_json = host.write_file(json_path, json.encode(request))
  local wrote_markdown = host.write_file(markdown_path, M.prefix_markdown(request, session_id, source))
  return {
    source = source,
    json = wrote_json and json_path or nil,
    markdown = wrote_markdown and markdown_path or nil,
    json_url = wrote_json and file_url(json_path) or nil,
    markdown_url = wrote_markdown and file_url(markdown_path) or nil,
  }
end

-- Everything the report needs, as data. `render` turns it into text; a test can
-- assert the fields without parsing prose.
function M.build(opts)
  opts = opts or {}
  local session_id = opts.session_id
  local snapshot = telemetry.snapshot(session_id)
  local report = {
    schema_version = 1,
    session_id = session_id,
    available = snapshot.available == true,
    hours = math.max(1, math.min(720, tonumber(opts.hours) or 48)),
    snapshot = snapshot,
  }
  if not report.available then return report end

  local request = snapshot.last_request or {}
  local response = snapshot.last or {}
  local shape = request.prompt_shape or {}
  local audit = request.prefix_audit or {}
  local normalized = response.normalized or {}
  local model = request.model or (provider.settings() or {}).model
  local rates = provider.rates(model)
  report.model = model
  report.provider = setting(request, "provider")
  -- `settings.reasoning` is the resolved reasoning object in the start payload, not
  -- a level; render its `.selected` so the header shows "high" and not a table address.
  local reasoning = setting(request, "reasoning")
  if type(reasoning) == "table" then reasoning = reasoning.selected or reasoning.effort end
  report.reasoning = type(reasoning) == "string" and reasoning ~= "provider" and reasoning or nil
  report.request_hash = request.request_hash
  report.request_bytes = request.request_bytes
  report.prefix_audit = audit

  -- Where the request bytes go. The subsets (reasoning, tool arguments) are
  -- already inside the assistant row, so they are marked and excluded from the
  -- percentage column's total. `stable` marks a component that must not be
  -- reduced by rewriting already-sent messages: reasoning replay is prefix-stable
  -- (see `provider.reasoning` and docs/MEMORY.md), so the report names it rather
  -- than offering it as a target.
  local whole = (tonumber(shape.total_message_bytes) or 0) + (tonumber(shape.schema_bytes) or 0)
  local rows = {
    { label = "tools (schemas)", bytes = shape.schema_bytes },
    { label = "system", bytes = shape.system_bytes },
    { label = "user", bytes = shape.user_bytes },
    { label = "assistant", bytes = shape.assistant_bytes },
    { label = "  reasoning", bytes = shape.reasoning_source_bytes, subset = true, stable = true },
    { label = "  tool args", bytes = shape.tool_arguments_source_bytes, subset = true },
    { label = "tool results", bytes = shape.tool_result_bytes },
    { label = "other", bytes = shape.other_bytes },
  }
  for _, row in ipairs(rows) do
    row.bytes = tonumber(row.bytes) or 0
    -- `x and nil or y` is y when x is true in Lua, so the subset case is explicit.
    if row.subset then row.percent = nil else row.percent = percent(row.bytes, whole) end
  end
  report.domination = {
    whole_bytes = whole,
    messages = shape.messages or 0,
    tool_calls = shape.tool_calls or 0,
    tool_results = shape.tool_results or 0,
    images = shape.images or 0,
    rows = rows,
  }

  -- KV cache: the provider's own categories, kept disjoint (Pi's accounting).
  local prompt = tonumber(normalized.prompt) or 0
  local read = tonumber(normalized.cacheRead)
  local write = tonumber(normalized.cacheWrite)
  local output = tonumber(normalized.output) or 0
  local uncached = tonumber(normalized.input)
  local cost = { known = false }
  if rates and normalized.known == true then
    local input_rate, output_rate = tonumber(rates.input), tonumber(rates.output)
    if input_rate and output_rate then
      local input_cost = (uncached or 0) * input_rate / 1000000
      local read_cost = (read or 0) * (tonumber(rates.cacheRead) or 0) / 1000000
      local write_cost = (write or 0) * (tonumber(rates.cacheWrite) or 0) / 1000000
      local output_cost = output * output_rate / 1000000
      local total_cost = input_cost + read_cost + write_cost + output_cost
      local cache_cost = read_cost + write_cost
      cost = {
        known = true, rates = rates,
        uncached_input = input_cost, cache_read = read_cost, cache_write = write_cost,
        output = output_cost, total = total_cost, cache = cache_cost,
        cache_percent_of_total = percent(cache_cost, total_cost),
        cache_percent_of_input = percent(cache_cost, input_cost + read_cost + write_cost),
      }
    end
  end
  local new_messages
  if audit.shared_messages ~= nil and shape.messages ~= nil then
    new_messages = (tonumber(shape.messages) or 0) - (tonumber(audit.shared_messages) or 0)
    if new_messages < 0 then new_messages = nil end
  end
  local reasons = {}
  if audit.relation and audit.relation ~= "append_only" and audit.relation ~= "identical" then
    reasons[#reasons + 1] = "prefix " .. tostring(audit.relation)
  end
  if audit.tools_changed then reasons[#reasons + 1] = "tool set changed" end
  if audit.model_changed then reasons[#reasons + 1] = "model changed" end
  if audit.routing_changed then reasons[#reasons + 1] = "routing changed" end
  report.cache = {
    known = normalized.cache_known == true,
    prompt = prompt,
    read = read,
    write = write,
    uncached = uncached,
    output = output,
    reasoning = normalized.reasoning,
    hit_percent = (read ~= nil and prompt > 0) and percent(read, prompt) or nil,
    uncached_percent = (uncached ~= nil and prompt > 0) and percent(uncached, prompt) or nil,
    new_messages = new_messages,
    relation = audit.relation,
    first_changed_message = audit.first_changed_message,
    reasons = reasons,
    cost = cost,
  }

  -- The session, not just the call. A single cheap call says nothing about a
  -- thread that spent a million tokens on compaction.
  local totals = snapshot.total or {}
  local inference = snapshot.inference or {}
  local session_cost = { known = false }
  if inference.calls and inference.calls > 0 and inference.unpriced == 0 then
    session_cost = { known = true, total = inference.cost, cache = nil }
  end
  report.session = {
    calls = totals.calls or 0,
    failed = totals.failed or 0,
    prompt = totals.prompt or 0,
    uncached = totals.input or 0,
    cache_read = totals.cacheRead or 0,
    output = totals.output or 0,
    cost = totals.cost,
    cost_known = totals.cost_known == true,
    cache_known = totals.cache_known == true,
    inference_cost = inference.cost,
    inference_cost_known = inference.calls and inference.calls > 0 and inference.unpriced == 0 or false,
    inference_cache_read = inference.cacheRead or 0,
    inference_prompt = inference.prompt or 0,
    compaction_calls = (snapshot.compaction or {}).calls or 0,
    compaction_failures = snapshot.compaction_failures or 0,
    context = snapshot.context,
    tool_calls = snapshot.tool_calls or 0,
    tool_failures = snapshot.tool_failures or 0,
    repeated_tools = snapshot.repeated_tools or 0,
    runs = snapshot.runs or 0,
    incomplete_runs = snapshot.incomplete_runs or 0,
  }

  -- Signals are facts a reader can act on, never a score. Each one names the
  -- field it came from, so the reader can go and check it.
  local signals = {}
  if audit.relation == "rewritten" or audit.relation == "shortened" then
    signals[#signals + 1] = string.format(
      "prefix %s at message %s: the provider cannot reuse the KV before that point (prefix_audit)",
      tostring(audit.relation), tostring(audit.first_changed_message or "?"))
  end
  if audit.cache_relevant_changed then
    signals[#signals + 1] = "cache-relevant change: " .. table.concat(reasons, ", ")
  end
  if normalized.cache_known ~= true then
    signals[#signals + 1] = "the provider did not report cache usage; the hit rate is unknown, not zero"
  end
  if normalized.known ~= true then
    signals[#signals + 1] = "the provider did not report usage; this call is unmeasured"
  end
  if cost.known ~= true then
    signals[#signals + 1] = "no rates for " .. tostring(model) .. "; the USD is unpriced (set WASM_AGENT_MODEL_RATES)"
  end
  if (snapshot.compaction_failures or 0) > 0 then
    signals[#signals + 1] = string.format("%d compaction failure(s): an oversized turn can keep failing",
      snapshot.compaction_failures)
  end
  if (snapshot.compaction or {}).calls and snapshot.compaction.calls > 0 then
    signals[#signals + 1] = string.format("%d compaction call(s) in this session: each one rewrites the prefix",
      snapshot.compaction.calls)
  end
  if (snapshot.repeated_tools or 0) > 0 then
    signals[#signals + 1] = string.format("%d repeated tool call(s) (same name + arguments) - a lead, not waste",
      snapshot.repeated_tools)
  end
  if #(snapshot.errors or {}) > 0 then
    signals[#signals + 1] = string.format("%d recorded failure(s); see the harness errors below", #snapshot.errors)
  end
  report.signals = signals

  -- The footer gathers the other surfaces so one command is enough to start.
  local ok_audit, graph = pcall(function()
    return dofile("lua/core/patch_audit.lua").report(report.hours)
  end)
  report.graph = ok_audit and graph or { error = "graph_report_unavailable" }
  report.runtime = telemetry.runtime()
  report.artifact = opts.agent and M.dump_prefix(opts.agent, session_id) or nil
  return report
end

local function table_row(left, middle, right)
  return string.format("    %-22s %12s  %6s", left, middle, right)
end

function M.render(report)
  local lines = {}
  local short = report.session_id and tostring(report.session_id):sub(1, 8) or "?"
  lines[#lines + 1] = string.format("efficiency report - session %s", short)
  if not report.available then
    lines[#lines + 1] = "  no model call recorded in this session yet; nothing to measure."
    lines[#lines + 1] = "  the report reads the durable harness ledger, so it fills in after the first call."
    return table.concat(lines, "\n")
  end
  lines[#lines + 1] = string.format("  model %s @ %s%s", tostring(report.model), tostring(report.provider),
    report.reasoning and ("  reasoning " .. tostring(report.reasoning)) or "")

  local cache = report.cache
  lines[#lines + 1] = ""
  lines[#lines + 1] = "last call"
  if cache.hit_percent ~= nil then
    lines[#lines + 1] = string.format(
      "  prompt %s tok   cache read %s (%.1f%%)   uncached input %s   cache write %s",
      commas(cache.prompt), commas(cache.read), cache.hit_percent,
      cache.uncached ~= nil and commas(cache.uncached) or "?", commas(cache.write or 0))
  else
    lines[#lines + 1] = string.format("  prompt %s tok   cache usage not reported by the provider", commas(cache.prompt))
  end
  lines[#lines + 1] = string.format("  output %s tok", commas(cache.output))
  if cache.cost.known then
    lines[#lines + 1] = string.format(
      "  cost %s   cache %s (%.1f%% of call cost, %.1f%% of input cost)",
      money(cache.cost.total), money(cache.cost.cache),
      cache.cost.cache_percent_of_total, cache.cost.cache_percent_of_input)
    lines[#lines + 1] = string.format(
      "    uncached input %s   cache read %s   cache write %s   output %s",
      money(cache.cost.uncached_input), money(cache.cost.cache_read),
      money(cache.cost.cache_write), money(cache.cost.output))
  else
    lines[#lines + 1] = "  cost unpriced (no rates for this model)"
  end
  if cache.relation then
    lines[#lines + 1] = string.format("  prefix %s%s", tostring(cache.relation),
      cache.new_messages ~= nil and string.format("  (%s message(s) appended, %s shared)",
        commas(cache.new_messages), commas(report.domination.messages - cache.new_messages)) or "")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("  where the request bytes go   (whole request %s B, %s messages)",
    commas(report.domination.whole_bytes), commas(report.domination.messages))
  for _, row in ipairs(report.domination.rows) do
    local shown = row.percent and string.format("%.1f%%", row.percent) or "(subset)"
    if row.stable then shown = shown .. "  stable" end
    lines[#lines + 1] = table_row(row.label, commas(row.bytes) .. " B", shown)
  end
  lines[#lines + 1] = "    (subset rows are inside assistant; percentages are of the whole request)"
  lines[#lines + 1] = "    (reasoning is prefix-stable: keep it whole or omit it, never window it - docs/MEMORY.md)"

  local session = report.session
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("session totals (%s inference call(s), %s failed)",
    commas(session.calls), commas(session.failed))
  lines[#lines + 1] = string.format(
    "  prompt %s   uncached %s   cache read %s   output %s",
    commas(session.prompt), commas(session.uncached), commas(session.cache_read), commas(session.output))
  if session.inference_cost_known then
    lines[#lines + 1] = string.format("  cost %s (inference only; compaction calls are separate)",
      money(session.inference_cost))
  elseif session.cost_known then
    lines[#lines + 1] = string.format("  cost %s (includes compaction)", money(session.cost))
  else
    lines[#lines + 1] = "  cost unpriced or incomplete"
  end
  if session.compaction_calls > 0 or session.compaction_failures > 0 then
    lines[#lines + 1] = string.format("  compaction %s applied, %s failed",
      commas(session.compaction_calls), commas(session.compaction_failures))
  end
  if session.context then
    lines[#lines + 1] = string.format("  context watermark seq %s, summary %s B, %s unsummarized row(s)",
      commas(session.context.summary_watermark or 0), commas(session.context.summary_bytes or 0),
      commas(session.context.unsummarized_rows or 0))
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "signals (facts, not a verdict)"
  if #report.signals == 0 then
    lines[#lines + 1] = "  none"
  else
    for _, signal in ipairs(report.signals) do
      lines[#lines + 1] = "  - " .. signal
    end
  end

  if report.artifact then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "prefix artifact - the exact bytes sent, to read and diff"
    if report.artifact.error then
      lines[#lines + 1] = "  unavailable: " .. tostring(report.artifact.error)
    else
      lines[#lines + 1] = "  source: " .. tostring(report.artifact.source)
      if report.artifact.markdown_url then lines[#lines + 1] = "  " .. report.artifact.markdown_url end
      if report.artifact.json_url then lines[#lines + 1] = "  " .. report.artifact.json_url end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "footer - where these facts come from, and where to go next"
  lines[#lines + 1] = string.format("  harness (this session)  GET /observability/events?id=%s  (engine -> sessions)",
    tostring(report.session_id))
  lines[#lines + 1] = "  harness (node, 48h)     engine -> sessions -> Export node - 48h, then audit below"
  local graph = report.graph or {}
  if graph.error then
    lines[#lines + 1] = "  graph / patch audit     unavailable: " .. tostring(graph.error)
  else
    lines[#lines + 1] = string.format(
      "  graph / patch audit     audits=%s leads=%s confirmed=%s false=%s worthy=%s (last %sh)",
      commas(graph.audits or 0), commas(graph.leads or 0), commas(graph.confirmed_catches or 0),
      commas(graph.false_positives or 0), tostring(graph.worthy or "unproven"), commas(report.hours))
  end
  lines[#lines + 1] = "  token audit (offline)   node scripts/audit-tokens.cjs <export.json>"
  if report.runtime then
    lines[#lines + 1] = string.format("  runtime                 lua=%s source=%s",
      tostring(report.runtime.lua_mode), tostring(report.runtime.source_hash))
  end
  lines[#lines + 1] = "  docs                    docs/OBSERVABILITY.md  docs/TOKEN_EFFICIENCY.md  docs/GRAPH-PATCH-AUDIT.md"
  lines[#lines + 1] = "  reasoning replay        prefix-stable, all-or-nothing: do not window it (docs/MEMORY.md)"
  lines[#lines + 1] = "  artifacts               data/tool-results/ (original oversized tool output)  data/efficiency/ (prefixes)"
  return table.concat(lines, "\n")
end

-- Build and render in one call. Returns the text and the data.
function M.report(opts)
  local report = M.build(opts)
  return M.render(report), report
end

return M
