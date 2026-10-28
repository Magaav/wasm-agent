-- Connector federation: a master node uses every online peer's connectors as its own.
--
-- A connector belongs to the machine that holds it - the WhatsApp linked device, a mail credential file,
-- a loopback service - so copying its definition to another node (lua/core/access.lua) gives that node a
-- definition it cannot run. Federation leaves each connector where it is and makes its tools reachable:
-- each peer's enabled connector tools are listed here as `peer_<peer>__<tool>`, and a call runs ON that
-- peer, through the signed node call, under that peer's own guards (its write gates, its approvals, its
-- refusals). Nothing secret moves, no node is configured by hand, and a node that has just been bound or
-- promoted to master sees everything the cluster offers on its next turn.
--
-- Peer side: `catalog` (what this node exports) and `call` (run one exported tool for a verified master).
-- Local side: `schemas` (cached, never waits on the network), `resolve`, `call`, `refresh`.
local json = dofile('lua/vendor/json.lua')

local M = { SCHEMA = 1, TTL = 600, RETRY = 60, PREFIX = 'peer_' }
local CACHE_KEY = 'federation.catalog.v1'

local function meta_get(key)
  local ok, raw = pcall(host.sql_query, 'SELECT value FROM meta WHERE key=?', json.encode({ key }))
  if not ok then return nil end
  local rows = json.decode(raw or '[]')
  return type(rows) == 'table' and rows[1] and rows[1].value or nil
end

local function meta_set(key, value)
  pcall(host.sql_exec, 'INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    json.encode({ key, value }))
end

-- ---------------------------------------------------------------- peer side

-- The connector tools this node exports: its enabled MCP tools and its WhatsApp facade, with the tier
-- each was approved at. Exactly the names `call` accepts; nothing else is reachable through it.
function M.exported()
  local tools = {}
  local mcp = dofile('lua/core/mcp.lua')
  local ok, schemas = pcall(mcp.schemas)
  for _, schema in ipairs(ok and schemas or {}) do
    local fn = schema['function']
    tools[#tools + 1] = { name = fn.name, description = fn.description, parameters = fn.parameters,
      effect = mcp.is_read(fn.name) and 'read' or 'write' }
  end
  local wok, whatsapp = pcall(dofile, 'lua/core/whatsapp.lua')
  if wok and type(whatsapp) == 'table' and type(whatsapp.schemas) == 'function' then
    local listed, list = pcall(whatsapp.schemas)
    for _, schema in ipairs(listed and list or {}) do
      local fn = schema['function']
      tools[#tools + 1] = { name = fn.name, description = fn.description, parameters = fn.parameters,
        effect = fn.name == 'whatsapp_send' and 'write' or 'read' }
    end
  end
  table.sort(tools, function(a, b) return a.name < b.name end)
  return tools
end

-- `caller` is the verified peer (server.lua). Only a master may use another node's connectors.
function M.serve(args, caller, dispatch)
  args = args or {}
  if not caller or caller.role ~= 'master' then return { ok = false, error = 'federation_requires_master' } end
  local action = args.action or 'catalog'
  if action == 'catalog' then
    local identity = dofile('lua/core/nodes.lua').identity() or {}
    return { ok = true, schema = M.SCHEMA, node_id = identity.node_id, tools = M.exported() }
  elseif action == 'call' then
    local name = tostring(args.name or '')
    local exported = false
    for _, tool in ipairs(M.exported()) do if tool.name == name then exported = true break end end
    if not exported then return { ok = false, error = 'federation_tool_not_exported', name = name } end
    return dispatch(name, type(args.args) == 'table' and args.args or {})
  end
  return { ok = false, error = 'unknown_federation_action' }
end

-- ---------------------------------------------------------------- local side

local function sanitize(text) return (tostring(text or ''):gsub('[^%w_-]', '_')) end

-- `peer_<peer>__<tool>`, inside the 64-character function-name limit (a hash keeps a long one unique).
function M.local_name(peer_name, tool_name)
  local name = M.PREFIX .. sanitize(peer_name) .. '__' .. sanitize(tool_name)
  if #name <= 64 then return name end
  return name:sub(1, 55) .. '_' .. host.sha256(name):sub(1, 8)
end

local function load_cache()
  local raw = meta_get(CACHE_KEY)
  local ok, value = pcall(json.decode, raw or '')
  return (ok and type(value) == 'table') and value or { at = 0, peers = {} }
end

-- Ask every online peer for its catalog and keep the answers. A peer that does not answer (down, or an
-- older build without federation) keeps no tools here and says why in `peers[id].error`.
function M.refresh()
  local nodes = dofile('lua/core/nodes.lua')
  local cache = { at = host.now(), peers = {} }
  local ok, list = pcall(nodes.list)
  for _, node in ipairs(ok and list or {}) do
    if not node.local_node and node.online ~= false then
      local answer = nodes.remote_call(node.node_id or node.id, 'federation', { action = 'catalog' })
      local entry = { name = node.name or node.node_id, node_id = node.node_id or node.id, at = host.now() }
      if type(answer) == 'table' and answer.ok and type(answer.tools) == 'table' then
        entry.tools = answer.tools
      else
        entry.tools = {}
        entry.error = type(answer) == 'table' and (answer.error or answer.detail) or 'no_answer'
      end
      cache.peers[entry.node_id] = entry
    end
  end
  meta_set(CACHE_KEY, json.encode(cache))
  return cache
end

-- The cache, refreshed when it is older than TTL (at most once per RETRY when peers keep failing). This
-- is the only place a turn may wait on peers, and only once in ten minutes.
function M.catalog()
  local cache = load_cache()
  local age = host.now() - (tonumber(cache.at) or 0)
  if age > M.TTL then
    local tried = tonumber(meta_get(CACHE_KEY .. '.tried')) or 0
    if host.now() - tried > M.RETRY then
      meta_set(CACHE_KEY .. '.tried', tostring(host.now()))
      local ok, fresh = pcall(M.refresh)
      if ok then cache = fresh end
    end
  end
  return cache
end

function M.schemas()
  local out = {}
  for _, peer in pairs(M.catalog().peers or {}) do
    for _, tool in ipairs(peer.tools or {}) do
      out[#out + 1] = { type = 'function', ['function'] = {
        name = M.local_name(peer.name, tool.name),
        description = '[on peer ' .. tostring(peer.name) .. '] ' .. tostring(tool.description or ''),
        parameters = tool.parameters or { type = 'object', properties = {} } } }
    end
  end
  table.sort(out, function(a, b) return a['function'].name < b['function'].name end)
  return out
end

-- The peer and the tool a local name stands for, from the cache only.
function M.resolve(name)
  if type(name) ~= 'string' or name:sub(1, #M.PREFIX) ~= M.PREFIX then return nil end
  for _, peer in pairs(load_cache().peers or {}) do
    for _, tool in ipairs(peer.tools or {}) do
      if M.local_name(peer.name, tool.name) == name then return peer, tool end
    end
  end
  return nil
end

function M.is_read(name)
  local _, tool = M.resolve(name)
  return tool ~= nil and tool.effect == 'read'
end

function M.call(name, args)
  local peer, tool = M.resolve(name)
  if not peer then return { ok = false, error = 'federation_tool_unknown', effect = 'none' } end
  local answer = dofile('lua/core/nodes.lua').remote_call(peer.node_id, 'federation',
    { action = 'call', name = tool.name, args = args or {} })
  if type(answer) == 'table' then answer.peer = answer.peer or peer.name end
  return answer
end

return M
