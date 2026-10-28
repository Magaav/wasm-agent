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
  if next(M.operator_profiles()) and M.operator_script() then tools[#tools + 1] = M.operator_schema(M.operator_profiles()) end
  table.sort(tools, function(a, b) return a.name < b.name end)
  return tools
end

-- ---------------------------------------------------------------- operator-directed WhatsApp send
--
-- docs/WHATSAPP-OPERATOR-MANAGEMENT.md: a node holding provisioned operator configs
-- (`<config>/operator-management-<profile>.json`, each scoped to exact chats, tokens as FILE references)
-- runs `scripts/whatsapp-operator.mjs prepare|approve|send|status` as the trusted operator process. It
-- was reachable only from a shell on that machine; a bound master now reaches it the same way it reaches
-- the reads. Nothing about its authority changes: the connector re-checks scope, exact recipient, the
-- approval digest and the durable intent; the CLI makes one call and never retries.
local function operator_dir()
  local override = host.getenv('WA_WHATSAPP_OPERATOR_DIR')
  if override and override ~= '' then return override end
  local ok, home = pcall(function() return dofile('lua/core/paths.lua').home() end)
  return ok and home and (home .. '/.config/wa-whatsapp') or nil
end

-- {profile = {conversations = {...}}} for every operator config here; non-secret fields only.
function M.operator_profiles()
  local dir = operator_dir(); if not dir then return {} end
  local ok, listing = pcall(function() return json.decode(host.list_dir(dir)) end)
  local profiles = {}
  for _, entry in ipairs(ok and type(listing) == 'table' and listing.entries or {}) do
    local name = entry.kind == 'file' and tostring(entry.name):match('^operator%-management%-([%w_%-]+)%.json$')
    if name then
      local raw = host.read_file(dir .. '/' .. entry.name)
      local parsed, config = pcall(json.decode, raw or '')
      if parsed and type(config) == 'table' and config.kind == 'whatsapp-operator-v1' and type(config.conversations) == 'table' then
        profiles[name] = { file = dir .. '/' .. entry.name, conversations = config.conversations }
      end
    end
  end
  return profiles
end

local function operator_script()
  local ok, mcp = pcall(dofile, 'lua/core/mcp.lua')
  local dir = ok and mcp.script_dir and mcp.script_dir()
  local script = dir and (dir .. '/whatsapp-operator.mjs')
  return (script and host.path_kind(script) == 'file') and script or nil, ok and mcp.node_program and mcp.node_program() or nil
end

local function operator_schema(profiles)
  local names, lines = {}, {}
  for name, profile in pairs(profiles) do
    names[#names + 1] = name
    lines[#lines + 1] = name .. ': ' .. table.concat(profile.conversations, ', ')
  end
  table.sort(names); table.sort(lines)
  return { name = 'whatsapp_operator', effect = 'write',
    description = 'Operator-directed WhatsApp text (docs/WHATSAPP-OPERATOR-MANAGEMENT.md): prepare -> approve -> send -> status, ONE call each, never retried. '
      .. 'The human\'s exact request is the content approval; YOU must resolve the exact recipient id first (ask the human when several chats match) and never change their text. '
      .. 'prepare {conversation_id, body, reply_to?, mentions?} returns intent_id and approval_digest; approve repeats conversation_id/body/reply_to/mentions plus intent_id and approval_digest; '
      .. 'send/status take {conversation_id, intent_id}. After a timeout use status with the same intent_id, never a second send. Profiles and the chats each may write to: ' .. table.concat(lines, '; '),
    parameters = { type = 'object', required = { 'action', 'profile', 'request' }, properties = {
      action = { type = 'string', enum = { 'prepare', 'approve', 'send', 'status' } },
      profile = { type = 'string', enum = names },
      request = { type = 'object', description = 'The request for that action, exactly as above.' } } } }
end

M.operator_script, M.operator_schema = operator_script, operator_schema

-- Run one operator action here (peer side, for a verified master).
function M.operator_call(args)
  args = args or {}
  local profiles = M.operator_profiles()
  local profile = profiles[tostring(args.profile or '')]
  if not profile then return { ok = false, error = 'operator_profile_unknown' } end
  local action = tostring(args.action or '')
  if action ~= 'prepare' and action ~= 'approve' and action ~= 'send' and action ~= 'status' then
    return { ok = false, error = 'operator_action_unsupported' }
  end
  local request = type(args.request) == 'table' and args.request or {}
  local allowed = false
  for _, id in ipairs(profile.conversations) do if id == request.conversation_id then allowed = true end end
  if not allowed then return { ok = false, error = 'operator_conversation_outside_profile', profile = args.profile } end
  local script, node = operator_script()
  if not script or not node then return { ok = false, error = 'operator_cli_not_installed' } end
  local dir = operator_dir() .. '/requests'
  local file = dir .. '/federated-' .. host.uuid() .. '.json'
  if not host.write_file(file, json.encode(request)) then return { ok = false, error = 'operator_request_not_written' } end
  local quote = function(text) return "'" .. tostring(text):gsub("'", "'\\''") .. "'" end
  local command = 'umask 077; chmod 600 ' .. quote(file) .. '; ' .. quote(node) .. ' ' .. quote(script) .. ' ' .. action
    .. ' --authority-file ' .. quote(profile.file) .. ' --request-file ' .. quote(file)
  local ok, raw = pcall(host.exec, command, '')
  local result = ok and (type(raw) == 'string' and json.decode(raw) or raw) or { code = -1, stderr = tostring(raw) }
  local parsed, answer = pcall(json.decode, tostring(result.stdout or ''))
  return { ok = (tonumber(result.code) == 0) and parsed and type(answer) == 'table' and answer.ok ~= false,
    action = action, profile = args.profile, request_file = file,
    result = parsed and answer or nil, stderr = result.stderr and tostring(result.stderr):sub(1, 400) or nil,
    note = 'One call, no retry. After a timeout or unknown outcome use status with the same intent_id.' }
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
    if name == 'whatsapp_operator' then return M.operator_call(args.args) end
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
