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
    local uses, callers = {}, {}
    for _, edge in ipairs(entry.outgoing or {}) do
      uses[#uses + 1] = edge_label(edge)
      if #uses >= 15 then break end
    end
    for _, edge in ipairs(entry.incoming or {}) do
      if edge.kind == "calls" or edge.kind == "capability" then
        -- For an incoming edge, path:line is the call site. dst_path:dst_line is
        -- the caller's definition and repeats for every call in that function.
        callers[#callers + 1] = tostring(edge.path or "?") .. ":" .. tostring(edge.line or 0)
        if #callers >= 15 then break end
      end
    end
    out[#out + 1] = {
      kind = node.kind, name = node.name, path = node.path, line = node.line,
      uses = uses, callers = callers,
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

return M
