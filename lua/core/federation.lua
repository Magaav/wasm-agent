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
-- Peer side: `catalog` (what this node exports, and the connectors that export it), `call` (run one
-- exported tool for a verified master) and `control` (turn one of this node's connectors on or off, decided
-- by this node's own registry).
-- Local side: `schemas` (cached, never waits on the network), `resolve`, `call`, `refresh`, `control`.
--
-- `/mcp` (`lua/core/mcp_command.lua`) is the reader of both halves: the catalog carries `connectors` so a
-- master lists a peer's connectors as connectors - state, transport and tool count - instead of inferring
-- them from a flat list of tool names.
local json = dofile('lua/vendor/json.lua')

local M = { SCHEMA = 2, TTL = 600, RETRY = 60, PREFIX = 'peer_' }

-- Is this name a spelling of the ONE WhatsApp surface (`lua/core/whatsapp.lua`)?
--
-- WhatsApp has one surface on every node - `mcp_whatsapp_<verb>`, answered by the account node - and
-- no peer spelling of it (operator decision, 11/11; #118). A peer that still exports one (an older
-- build, a registry row from before 11/11) must therefore never become a `peer_<node>__*` tool here:
-- in session b393f280 the model found `peer_openclaw__mcp_whatsapp_native_inspect_chat_*`, spent its
-- turns on a second route for the same question, and the one surface went unused. The predicate is
-- `whatsapp.renamed`, which is the mapping the dispatch already refuses these names with, so the two
-- cannot disagree about which spellings are the same question.
-- `lua/core/whatsapp.lua`, loaded once: the predicate below runs per peer tool, and a `dofile` per
-- name would re-read the whole surface for every name in a catalogue.
local whatsapp_loaded
local function whatsapp_module()
  if whatsapp_loaded == nil then
    local ok, module = pcall(dofile, 'lua/core/whatsapp.lua')
    whatsapp_loaded = (ok and type(module) == 'table') and module or false
  end
  return whatsapp_loaded or nil
end

local function whatsapp_spelling(name)
  if type(name) ~= 'string' or name == '' then return false end
  local whatsapp = whatsapp_module()
  if whatsapp == nil then return false end
  if whatsapp.tool(name) then return true end
  return whatsapp.renamed(name) ~= nil
end
M.whatsapp_spelling = whatsapp_spelling

-- v2 carries `connectors` beside `tools`. A v1 row is not read as a v2 answer: an old cache would list a
-- peer with tools and no registry, which is the "older build" case and must say so, not be guessed at.
local CACHE_KEY = 'federation.catalog.v2'

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

-- The tools this node exports to a master: its enabled MCP tools and, where an operator profile is
-- installed, the operator route - with the tier each was approved at. Exactly the names `call` accepts.
--
-- WhatsApp is deliberately NOT here since 11/11 (#118). It used to be exported twice - as
-- `whatsapp_search`/`read`/`reactions`/`media` under a `peer_<node>__` prefix and, through the MCP
-- half, as `peer_<node>__mcp_whatsapp_native_read_newest_<hash8>` - and both spellings were the same
-- four questions as the account node's own tools. A master now has ONE WhatsApp surface on its own
-- node, `mcp_whatsapp_<verb>` (`lua/core/whatsapp.lua`), which asks the account node itself; the
-- account node answers that capability (it is admitted in `lua/core/server.lua`) and exports nothing.
-- `M.connectors` still reports which node holds the account, so the surface can find it without a name
-- being hard-coded anywhere.
function M.exported()
  local tools = {}
  local mcp = dofile('lua/core/mcp.lua')
  local ok, schemas = pcall(mcp.schemas)
  for _, schema in ipairs(ok and schemas or {}) do
    local fn = schema['function']
    -- The one WhatsApp surface is not exported (11/11). This is the second half of that decision: `mcp`
    -- already refuses to publish a WhatsApp connector's tools here, and this refuses a name that got
    -- into the catalogue another way, so no peer of this node can ever offer a `peer_<this>__*whatsapp*`
    -- tool to a master.
    if not whatsapp_spelling(fn.name) then
      tools[#tools + 1] = { name = fn.name, description = fn.description, parameters = fn.parameters,
        effect = mcp.is_read(fn.name) and 'read' or 'write' }
    end
  end
  if next(M.operator_profiles()) and M.operator_script() then tools[#tools + 1] = M.operator_schema(M.operator_profiles()) end
  table.sort(tools, function(a, b) return a.name < b.name end)
  return tools
end

-- This node's connectors as one list, for a master's `/mcp`: its registry, composed by the same module the
-- local view uses (`lua/core/mcp_command.lua`) so the two answers cannot disagree, plus the two things it
-- exports that are not registry entries - the native WhatsApp read path and, where an operator profile is
-- installed, the operator route. Those are always on: there is no registry row to toggle, and saying so is
-- better than listing them as if there were.
function M.connectors()
  local list = {}
  local ok, command = pcall(dofile, 'lua/core/mcp_command.lua')
  if ok and type(command) == 'table' and command.local_connectors then
    local connectors = command.local_connectors({})
    for _, entry in ipairs(connectors or {}) do list[#list + 1] = entry end
  end
  -- The one WhatsApp surface, and the one fact a peer needs about it: does this node hold the account?
  -- It is not a registry entry and has no toggle - the component is what runs, not this row.
  local whatsapp = dofile('lua/core/whatsapp.lua')
  local holds = whatsapp.holds_account()
  -- The tools this row publishes are the ones the model is offered: the hidden compatibility alias
  -- (`mcp_whatsapp_send_status`) is callable and is in no catalogue, so it is not a tool of the surface
  -- an operator is told about either.
  local offered = whatsapp.schemas()
  -- The same columns this node's own `/mcp` draws for it (`whatsapp.service_row`): a peer reading this
  -- node's inventory sees WhatsApp as one service among the connectors, with its type, its node and a
  -- count, not as a special row that needs a heading of its own.
  local surface = { id = 'whatsapp', name = 'WhatsApp',
    type = 'built-in', node = tostring(whatsapp.self_name() or 'this node'),
    node_phrase = 'on this node', state_label = holds and 'connected' or 'unknown',
    count_phrase = (holds and 'account here' or 'account elsewhere'),
    transport = 'native', enabled = true, state = 'enabled', tools = {}, approved = #offered,
    discovered = #offered, whatsapp_account = holds,
    note = holds
      and 'This node runs wa-whatsapp, so it holds the account: its reads answer here and any master may ask it.'
      or 'This node runs no wa-whatsapp component: its reads are answered by the node that holds the account.' }
  for _, schema in ipairs(offered) do
    local fn = schema['function']
    local verb = whatsapp.by_verb[fn.name:sub(14)]
    surface.tools[#surface.tools + 1] = { name = fn.name, description = fn.description,
      schema = json.encode(fn.parameters), approval = verb and verb.effect or 'write', published = true }
  end
  table.sort(surface.tools, function(a, b) return a.name < b.name end)
  surface.tool_count = #surface.tools
  list[#list + 1] = surface
  local profiles = M.operator_profiles()
  if next(profiles) then
    local schema = M.operator_schema(profiles)
    list[#list + 1] = { id = 'whatsapp_operator', name = 'WhatsApp operator route', transport = 'native',
      enabled = true, state = 'enabled', approved = 1, discovered = 1, tool_count = 1,
      tools = { { name = schema.name, description = schema.description,
        schema = json.encode(schema.parameters), approval = 'write', published = true } },
      note = 'Operator-directed text; the connector re-checks scope, recipient and approval digest on every call.' }
  end
  return list
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
  -- The Rust/WASI path (Phase 2 of the 10/11 decision): the same state machine, with the send on the
  -- node's explicit-send outbox and the component's posting-hold/fence gate in front of the wire. It
  -- is opt-in by node (`WA_WHATSAPP_OPERATOR_BACKEND=native`) until a live account proves it in place;
  -- the Node CLI below remains the route for a node whose Go connector still owns the linked session.
  if (host.getenv('WA_WHATSAPP_OPERATOR_BACKEND') or '') == 'native' and type(host.whatsapp_send) == 'function' then
    local ok, operator = pcall(dofile, 'lua/core/whatsapp_operator.lua')
    if ok and type(operator) == 'table' and type(operator.call) == 'function' then
      local answer = operator.call({ action = action, profile = args.profile, request = request })
      answer.action = action
      answer.profile = args.profile
      answer.backend = 'native'
      answer.note = 'One call, no retry. After a timeout or unknown outcome use status with the same intent_id.'
      return answer
    end
  end
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
    return { ok = true, schema = M.SCHEMA, node_id = identity.node_id, tools = M.exported(), connectors = M.connectors() }
  elseif action == 'control' then
    return M.control_here(args, caller)
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

-- Turn one of THIS node's connectors on or off for a verified master, and answer with the fresh state.
--
-- The decision is this node's own: `mcp.control` validates the id, requires a passing probe to enable and
-- CASes the revision, exactly as the `mcp` tool does. The master's `expected_revision` is the one its
-- cached catalog carried, so a registry that moved since refuses (`mcp_store_revision_changed`) and
-- nothing is written - a master cannot silently overwrite a change made here. The record stays on this
-- node: `harness_events` (kind `mcp_control`) names the caller, and the registry revision moves.
function M.control_here(args, caller)
  local control = type(args.control) == 'table' and args.control or nil
  if not control then return { ok = false, error = 'federation_control_invalid' } end
  local action = tostring(control.action or '')
  if action ~= 'enable' and action ~= 'disable' then
    return { ok = false, error = 'federation_control_unsupported', action = action }
  end
  local id = tostring(control.id or '')
  local ctx = { role = 'master', session_id = 'federation-control:' .. tostring(caller.node_id), peer = caller.node_id }
  local mcp = dofile('lua/core/mcp.lua')
  local answer = mcp.control({ action = action, id = id, expected_revision = tonumber(control.expected_revision) }, ctx)
  local ok, inventory = pcall(mcp.inventory)
  local revision = ok and type(inventory) == 'table' and inventory.revision or nil
  pcall(function()
    dofile('lua/core/telemetry.lua').event(ctx.session_id, '', '', 'mcp_control', action,
      { connector = id, caller = caller.node_id, ok = answer.ok == true, error = answer.error, revision = revision })
  end)
  if not answer.ok then
    answer.revision = revision
    answer.node_id = (dofile('lua/core/nodes.lua').identity() or {}).node_id
    return answer
  end
  local identity = dofile('lua/core/nodes.lua').identity() or {}
  return { ok = true, schema = M.SCHEMA, node_id = identity.node_id, id = id, enabled = answer.enabled == true,
    revision = revision, tools = M.exported(), connectors = M.connectors(),
    note = 'Applied by this node\'s own registry and recorded here (harness_events kind mcp_control).' }
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
--
-- This runs inside a turn, before its first model call, so it is bounded: a peer the relay reports as not
-- attached is not asked (a relayed call to it waits out the relay hold, up to a minute), and once BUDGET
-- seconds are spent the remaining peers are left for the next refresh. A registered peer whose process
-- had stopped held a master's first turn for minutes (v0.1.0-alpha.12 gate on openclaw, 30/10).
M.BUDGET = 15
function M.refresh()
  local nodes = dofile('lua/core/nodes.lua')
  local cache = { at = host.now(), peers = {} }
  local started = host.now()
  local ok, list = pcall(nodes.list)
  for _, node in ipairs(ok and list or {}) do
    if not node.local_node and node.online ~= false then
      local entry = { name = node.name or node.node_id, node_id = node.node_id or node.id, at = host.now() }
      local reachable, why = true, nil
      if nodes.reachable then
        local rok, r, reason = pcall(nodes.reachable, node)
        if rok and r == false then reachable, why = false, reason or 'not_reachable' end
      end
      local answer
      if not reachable then
        answer = { error = why }
      elseif host.now() - started > M.BUDGET then
        answer = { error = 'refresh_budget_spent' }
      else
        answer = nodes.remote_call(entry.node_id, 'federation', { action = 'catalog' })
      end
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

-- The cache as it stands, with no refresh attempt. `catalog` may wait up to BUDGET seconds on peers, which
-- a window's own request timeout cannot afford; a view that must answer now (GET /mcp) reads this and says
-- how old it is.
function M.cached() return load_cache() end

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

-- Peer names from the last refresh, cache only (never waits on the network): the code-mode hint names
-- them so an empty-context model knows other nodes exist before it calls `nodes` (29/10).
function M.cached_peers()
  local names = {}
  for _, peer in pairs(load_cache().peers or {}) do
    if peer.name and not peer.error then names[#names + 1] = tostring(peer.name) end
  end
  table.sort(names)
  return names
end

-- Ask a peer to change one of its connectors, and take its answer as the new catalog for that peer.
--
-- Writing the answer into the cache is what makes the change reach this node's own tool list at once: a
-- peer toggle that waited for the ten-minute refresh would leave a running session's `[session update]`
-- note owed for ten minutes, which is the silent delay this command exists to avoid. `opts.call` exists so
-- a Lua test can stand in for the signed node call; production always uses `nodes.remote_call`.
function M.control(peer_name, args, opts)
  opts = opts or {}
  -- The cache key is the one the catalog used, not the id the answer carries: they are the same on a real
  -- cluster, and a peer that renames or re-registers must not leave this node writing under a key nothing
  -- reads.
  local key, node = nil, nil
  for id, peer in pairs(load_cache().peers or {}) do
    if peer.name == peer_name or peer.node_id == peer_name or id == peer_name then key, node = id, peer end
  end
  if not node then return { ok = false, error = 'unknown_peer', peer = tostring(peer_name) } end
  local call = opts.call or function(node_id, capability, payload)
    return dofile('lua/core/nodes.lua').remote_call(node_id, capability, payload)
  end
  local answer = call(node.node_id, 'federation', { action = 'control', control = args or {} })
  if type(answer) ~= 'table' then return { ok = false, error = 'peer_answer_unreadable', peer = node.name } end
  if answer.ok and type(answer.connectors) == 'table' then
    answer.catalog_updated = M.remember(key, answer) == true
  end
  answer.peer = answer.peer or node.name
  return answer
end

-- The peer's answer replaces what the cache held for it: `tools` and `connectors` are the state after the
-- change, read from the peer in the same call. `cache.at` is left alone - the refresh TTL is about when
-- peers were last asked, and this did not ask them all.
function M.remember(node_id, answer)
  local cache = load_cache()
  local peer = cache.peers[node_id]
  if not peer then return false end
  if type(answer.tools) == 'table' then peer.tools = answer.tools end
  if type(answer.connectors) == 'table' then peer.connectors = answer.connectors end
  if answer.node_id then peer.node_id = answer.node_id end
  peer.at = host.now()
  meta_set(CACHE_KEY, json.encode(cache))
  return true
end

-- The schema a peer published for one tool, exactly as it sent it.
--
-- A peer publishes the catalogue shape (`parameters`, the object its own `searchTools` answers) and its
-- `/mcp` view publishes the same declaration as JSON text (`schema`); either is the server's own word
-- about its arguments and neither may be replaced by an empty one. So: `parameters` when it is there,
-- the decoded `schema` text when only that is, and `{type="object"}` - a tool that takes no arguments -
-- only when the peer declared neither. 13/11: a peer tool whose declaration did not arrive in
-- `parameters` was offered with `properties = {}`, so the model guessed argument names and ate a
-- `schema_extra` refusal for each guess. `scripts/test-tool-schema-fidelity.lua` holds this line.
local function peer_parameters(tool)
  if type(tool.parameters) == 'table' and next(tool.parameters) ~= nil then return tool.parameters end
  if type(tool.schema) == 'string' then
    local ok, decoded = pcall(json.decode, tool.schema)
    if ok and type(decoded) == 'table' and next(decoded) ~= nil then return decoded end
  end
  return { type = 'object' }
end

function M.schemas()
  local out = {}
  for _, peer in pairs(M.catalog().peers or {}) do
    for _, tool in ipairs(peer.tools or {}) do
      -- A peer's WhatsApp spelling is not a tool here, whatever the peer says: its one surface is this
      -- node's own `mcp_whatsapp_<verb>`, which asks the account node itself. Skipping it in the
      -- catalogue is what keeps it out of the model's tool list, `searchTools` and `describeTool` at
      -- once - a name that is not offered cannot be discovered.
      if not whatsapp_spelling(tool.name) then
        out[#out + 1] = { type = 'function', ['function'] = {
          name = M.local_name(peer.name, tool.name),
          description = '[on peer ' .. tostring(peer.name) .. '] ' .. tostring(tool.description or ''),
          parameters = peer_parameters(tool) } }
      end
    end
  end
  table.sort(out, function(a, b) return a['function'].name < b['function'].name end)
  return out
end

-- The peer and the tool a local name stands for, from the cache only.
-- A WhatsApp spelling resolves to nothing: it is not a peer tool here (see `whatsapp_spelling`), and a
-- cached name from before this rule must stop working at the same moment it stops being listed.
function M.resolve(name)
  if type(name) ~= 'string' or name:sub(1, #M.PREFIX) ~= M.PREFIX then return nil end
  if whatsapp_spelling(name) then return nil end
  for _, peer in pairs(load_cache().peers or {}) do
    for _, tool in ipairs(peer.tools or {}) do
      if not whatsapp_spelling(tool.name) and M.local_name(peer.name, tool.name) == name then return peer, tool end
    end
  end
  return nil
end

function M.is_read(name)
  local _, tool = M.resolve(name)
  return tool ~= nil and tool.effect == 'read'
end

function M.call(name, args)
  if whatsapp_spelling(name) then
    -- The one surface answers this question, on this node, routed to the account node: say so with the
    -- name to use instead of "unknown tool", which sends the model looking for a route that is gone.
    local whatsapp = dofile('lua/core/whatsapp.lua')
    local use = whatsapp.renamed(name)
    local answer = { ok = false, error = 'whatsapp_tool_renamed', effect = 'none',
      note = tostring(name) .. ' is not a WhatsApp tool any more: WhatsApp has one surface, and a peer spelling of it is not one of them' }
    if use then answer.use = use end
    return answer
  end
  local peer, tool = M.resolve(name)
  if not peer then return { ok = false, error = 'federation_tool_unknown', effect = 'none' } end
  local answer = dofile('lua/core/nodes.lua').remote_call(peer.node_id, 'federation',
    { action = 'call', name = tool.name, args = args or {} })
  if type(answer) == 'table' then answer.peer = answer.peer or peer.name end
  return answer
end

return M
