-- The code graph, wrapped for the agent.
--
-- `host.graph_*` returns JSON strings; this module decodes them and degrades to a
-- clear error when the host is older or the graph is not ready, so a caller never
-- has to pcall the capability itself. Results are compacted: a definition's edge
-- list is capped, because a well-connected function can have hundreds of callers
-- and the model only needs the shape and the first few places to look.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function capability(name)
  return type(host[name]) == "function"
end

local function call(name, ...)
  if not capability(name) then return nil, "graph_capability_missing" end
  local ok, raw = pcall(host[name], ...)
  if not ok then return nil, tostring(raw) end
  local decoded = json.decode(raw or "")
  if type(decoded) ~= "table" then return nil, "graph_decode_failed" end
  if decoded.error then return nil, decoded.error end
  return decoded
end

-- Whether this host can answer graph questions at all (an older host cannot).
function M.available()
  return capability("graph_query") and capability("graph_explain")
end

function M.status()
  return call("graph_status", "{}")
end

function M.index(opts)
  return call("graph_index", json.encode(opts or {}))
end

function M.query(text, opts)
  if type(text) ~= "string" or text == "" then return nil, "query_required" end
  -- A broad name used to return 50 path matches before the useful symbol. Fetch one extra
  -- row so the model can tell whether a compact answer omitted more candidates.
  local limit = math.max(1, math.min(tonumber(opts and opts.limit) or 12, 200))
  local rows, err = call("graph_query", text, json.encode({ limit = limit + 1 }))
  if not rows then return nil, err end
  local truncated = #rows > limit
  local results = {}
  for i = 1, math.min(#rows, limit) do
    local row = rows[i]
    results[#results + 1] = { kind = row.kind, name = row.name, path = row.path, line = row.line }
  end
  return { query = text, count = #results, truncated = truncated, results = results }
end

-- Ranked discovery is separate from legacy `query`: callers can measure whether returning a
-- source-ready selector actually replaces grep/read rather than silently changing old behavior.
function M.search_symbols(text, opts)
  if type(text) ~= "string" or text == "" then return nil, "query_required" end
  if not capability("graph_search") then return nil, "graph_retrieval_unavailable" end
  local limit = math.max(1, math.min(tonumber(opts and opts.limit) or 8, 50))
  local prefer = opts and opts.prefer_implementations == true
  local rows, err = call("graph_search", text,
    json.encode({ limit = limit + 1, prefer_implementations = prefer }))
  if not rows then return nil, err end
  local results = {}
  for i = 1, math.min(#rows, limit) do
    local row = rows[i]
    results[#results + 1] = {
      kind = row.kind, name = row.name, path = row.path, line = row.line,
      language = row.language, signature = row.signature, score = row.score,
      confidence = row.confidence, reason = row.reason, matched_terms = row.matched_terms,
      unmatched_terms = row.unmatched_terms,
      unmatched_definition_terms = row.unmatched_definition_terms,
      score_breakdown = row.score_breakdown,
    }
  end
  local top = results[1]
  local partial = top and ((top.unmatched_terms and #top.unmatched_terms > 0)
    or (top.unmatched_definition_terms and #top.unmatched_definition_terms > 0))
  return {
    query = text, count = #results, truncated = #rows > limit,
    verdict = #results == 0 and "absent" or partial and "partial" or "ok", results = results,
    next = #results == 0 and "Try an exact identifier or bounded grep; absence here is lexical only."
      or partial and "Top result lacks some query terms in its definition. Inspect a likely definition, then use bounded grep for the missing terms before editing."
      or "Call graph action=symbol_source with one result's path, name, line and kind.",
  }
end

function M.symbol_source(selector, opts)
  if not capability("graph_source") then return nil, "graph_retrieval_unavailable" end
  if type(selector) ~= "table" or type(selector.path) ~= "string" or selector.path == "" then
    return nil, "path_required"
  end
  if type(selector.name) ~= "string" or selector.name == "" then return nil, "name_required" end
  local line = tonumber(selector.line)
  if not line or line < 1 or line % 1 ~= 0 then return nil, "line_required" end
  opts = opts or {}
  return call("graph_source", json.encode({
    path = selector.path, name = selector.name, line = line, kind = selector.kind,
    byte_offset = tonumber(opts.byte_offset) or 0,
    max_bytes = tonumber(opts.max_bytes) or 20000,
  }))
end

local function edge_label(edge)
  local label = tostring(edge.target or "?")
  if edge.dst_path then
    label = label .. " -> " .. tostring(edge.dst_path) .. ":" .. tostring(edge.dst_line or 0)
  end
  return label
end

function M.explain(name, opts)
  if type(name) ~= "string" or name == "" then return nil, "name_required" end
  local rows, err = call("graph_explain", name, json.encode(opts or {}))
  if not rows then return nil, err end
  local out = {}
  for _, entry in ipairs(rows) do
    local node = entry.node or {}
    local uses, callers, use_evidence, caller_evidence = {}, {}, {}, {}
    for _, edge in ipairs(entry.outgoing or {}) do
      uses[#uses + 1] = edge_label(edge)
      use_evidence[#use_evidence + 1] = {kind=edge.kind,target=edge.target,path=edge.path,
        line=edge.line,resolved=edge.resolved,resolution=edge.resolution,confidence=edge.confidence,
        dst_path=edge.dst_path,dst_line=edge.dst_line}
      if #uses >= 15 then break end
    end
    for _, edge in ipairs(entry.incoming or {}) do
      if edge.kind == "calls" or edge.kind == "capability" then
        -- For an incoming edge, path:line is the call site. dst_path:dst_line is
        -- the caller's definition and repeats for every call in that function.
        callers[#callers + 1] = tostring(edge.path or "?") .. ":" .. tostring(edge.line or 0)
        caller_evidence[#caller_evidence + 1] = {kind=edge.kind,path=edge.path,line=edge.line,
          resolution=edge.resolution,confidence=edge.confidence,
          caller_path=edge.dst_path,caller_line=edge.dst_line}
        if #callers >= 15 then break end
      end
    end
    out[#out + 1] = {
      kind = node.kind, name = node.name, path = node.path, line = node.line,
      uses = uses, callers = callers,
      use_evidence = use_evidence, caller_evidence = caller_evidence,
    }
  end
  return { name = name, definitions = out }
end

function M.path(from, to)
  if type(from) ~= "string" or from == "" or type(to) ~= "string" or to == "" then
    return nil, "from_and_to_required"
  end
  local result, err = call("graph_path", from, to, "{}")
  if not result then return nil, err end
  return { from = from, to = to, found = result.found, steps = result.steps or {} }
end

function M.caps()
  return call("graph_caps", "{}")
end

function M.stats()
  return call("graph_stats", "{}")
end

function M.overview(opts)
  if not capability("graph_overview") then return nil, "graph_overview_unavailable" end
  opts = opts or {}
  local aspects = {}
  if type(opts.aspects) == "table" then
    for i, aspect in ipairs(opts.aspects) do
      if type(aspect) ~= "string" or aspect == "" then return nil, "invalid_overview_aspect" end
      aspects[i] = aspect
    end
  end
  return call("graph_overview", json.encode({aspects=aspects,
    limit=math.max(1,math.min(tonumber(opts.limit) or 8,50)),
    max_bytes=math.max(2048,math.min(tonumber(opts.max_bytes) or 24000,200000))}))
end

function M.impact(patch, opts)
  if not capability("graph_impact") then return nil, "graph_impact_unavailable" end
  if type(patch) ~= "table" or type(patch.changes) ~= "table" then return nil, "changes_required" end
  opts = opts or {}
  return call("graph_impact", json.encode({changes=patch.changes,
    direction=opts.direction or "both",depth=tonumber(opts.depth) or 2,
    limit=tonumber(opts.limit) or 50,offset=tonumber(opts.offset) or 0,
    cursor=opts.cursor,max_bytes=tonumber(opts.max_bytes) or 24000}))
end

return M
