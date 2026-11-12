-- `/mcp`: every connector this node can use, and the controls each one gives the model.
--
-- Two sources, one list. A connector either lives in this node's registry (`lua/core/mcp.lua`, stored in
-- `meta`) or on a peer that federates it (`lua/core/federation.lua`, `peer_<peer>__<tool>`). The operator
-- asked for one command that shows both, opens either one to the exact callable names the model is given,
-- and turns either one on or off. So this module *composes*; it never registers. The registry, its probe
-- records, the approval tiers and the federation cache are the existing ones: a connector's state here is
-- read from them at the moment of the call, never kept a second time, and the toggle goes through
-- `mcp.control` (validation, expected-revision CAS, probe-required enable) or through the peer's own
-- `federation` capability - so the rules that decide are the ones that already decide.
--
-- Names are verbatim. A local tool is `mcp_<id>_<name>_<hash8>` (`mcp.namespace`), a peer's is
-- `peer_<peer>__<that name>` (`federation.local_name`): the exact strings the model is offered, because a
-- view that abbreviates them costs the reader a hunt for the real name (session 10/11).
local json = dofile('lua/vendor/json.lua')
local M = {}

local function mcp_module() return dofile('lua/core/mcp.lua') end
local function federation() return dofile('lua/core/federation.lua') end

-- A connector's state, from what the registry already recorded: enabled, or the last thing that failed.
-- `probe` is the handshake, `last_call` the last tool call; either failing is the error the reader needs,
-- and a connector that never probed is disabled, not broken.
local function local_state(server)
  if server.enabled == true then
    -- Still on, but the catalogue the operator approved is not the one the connector now reports: the next
    -- call refuses before dispatch until it is probed again. Saying `disabled` here (what a call used to do by
    -- turning the connector off) sent a reader looking for a connector that had never gone away.
    local stale = server.probe_stale
    if type(stale) == 'table' then
      return 'stale', 'its tool list changed since the last probe (' .. tostring(stale.error or 'schema_changed')
        .. '); it is still on, and a call refuses until it is probed again'
    end
    return 'enabled', nil
  end
  local probe = server.probe
  if type(probe) == 'table' and probe.ok ~= true then return 'failing', probe.error or 'probe_failed' end
  local call = server.last_call
  if type(call) == 'table' and call.ok == false then return 'failing', call.error or 'call_failed' end
  return 'disabled', nil
end

local function sorted_keys(map)
  local keys = {}
  for name in pairs(map or {}) do keys[#keys + 1] = name end
  table.sort(keys)
  return keys
end

-- One registry entry, with every tool it knows about and whether the model is offered it right now.
-- A tool the operator approved but the last probe did not list is shown too: it is the reason `enable`
-- refuses (`mcp_approved_tool_missing`), and hiding it would make that refusal look arbitrary.
local function local_connector(mcp, server, revision)
  local state, error = local_state(server)
  local definition = server.definition or {}
  local approved = definition.tools or {}
  local tools, published, seen = {}, 0, {}
  -- A connector in the WhatsApp family is shown and still toggled by the operator, but its tools are not
  -- offered to the model any more: since 11/11 the one WhatsApp surface is `mcp_whatsapp_<verb>`
  -- (`lua/core/whatsapp.lua`, one exact name per question on every node). Saying so here is what keeps
  -- `/mcp` from listing a row as "callable now" when the callable name is a different one.
  local superseded = mcp.whatsapp_family ~= nil and mcp.whatsapp_family(server.id)
  if superseded then published = 0 end
  local function add(tool_name, description, schema, note)
    local tier = approved[tool_name]
    local is_published = server.enabled == true and tier ~= nil and note == nil and not superseded
    if is_published then published = published + 1 end
    tools[#tools + 1] = {
      name = mcp.namespace(server.id, tool_name), tool = tool_name,
      description = description, schema = schema,
      approval = tier or 'not approved', published = is_published, note = note,
    }
    seen[tool_name] = true
  end
  for _, tool in ipairs(type(server.probe) == 'table' and server.probe.tools or {}) do
    -- The catalogue's own description, composed the way `mcp.schemas` composes it: what the model reads.
    add(tool.name, 'MCP ' .. server.id .. ' / ' .. tool.name .. ': ' .. tostring(tool.description or ''),
      tool.input_schema_json)
  end
  for _, tool_name in ipairs(sorted_keys(approved)) do
    if not seen[tool_name] then
      add(tool_name, '(approved, but the last probe did not list this tool)',
        '{"type":"object","properties":{}}', 'approved_but_not_discovered')
    end
  end
  table.sort(tools, function(a, b) return a.name < b.name end)
  if superseded then
    -- The reason, on every row, so an operator who wondered why the tools vanished from the catalogue
    -- finds the answer where the connector is listed instead of guessing.
    -- The reason is a note, never the `error` a failing probe carries: a connector the operator turned
    -- off is still `disabled` (that is the truth about it), and one that is on but whose tools are offered
    -- elsewhere says why next to its state.
    for _, tool in ipairs(tools) do tool.note = tool.note or 'superseded_by_mcp_whatsapp' end
    if server.enabled == true then
      error = error or 'its tools are offered as mcp_whatsapp_* instead (one WhatsApp surface, #118)'
    end
  end
  return {
    key = server.id, id = server.id, name = server.name or server.id,
    where = 'this node', scope = 'local', transport = definition.transport or 'unknown',
    state = state, error = error, enabled = server.enabled == true,
    tool_count = published, approved = #sorted_keys(approved), discovered = #(server.probe and server.probe.tools or {}),
    revision = revision, observed = server.observed_status, last_call = server.last_call, probe = server.probe,
    note = superseded and 'superseded_by_mcp_whatsapp' or nil,
    tools = tools,
    policy = { tier = 'mcp', managed_by = 'lua/core/mcp.lua',
      approval = 'each tool is approved locally as read or write; a connector stays disabled until a probe passed',
      note = 'Trusted executable code, not a sandbox. Enabling requires a successful probe and every approved tool present.' },
  }
end

-- This node's registry, as one list. Used by the local view and by a peer answering `federation catalog`:
-- the peer reports exactly what it would show itself, so the master's copy of the answer needs no second
-- interpretation.
function M.local_connectors(ctx)
  local ok, inventory = pcall(function() return mcp_module().inventory() end)
  if not ok then
    return {}, { ok = false, error = 'mcp_registry_unreadable', detail = tostring(inventory) }
  end
  if inventory.ok == false then return {}, { ok = false, error = inventory.error or 'mcp_registry_unreadable' } end
  local list = {}
  for _, server in ipairs(inventory.servers or {}) do
    list[#list + 1] = local_connector(mcp_module(), server, inventory.revision)
  end
  return list, { ok = true, revision = inventory.revision }
end

-- One peer connector, in this node's naming: every tool it exports is `peer_<peer>__<name>`, and a tool is
-- published only when the peer actually exported it in the same answer (the two lists cannot drift).
local function peer_connector(peer, connector, exported)
  local tools, published = {}, 0
  for _, tool in ipairs(connector.tools or {}) do
    local name = federation().local_name(peer.name, tool.name)
    local is_published = exported[name] == true
    if is_published then published = published + 1 end
    tools[#tools + 1] = {
      name = name, tool = tool.name, description = tool.description, schema = tool.schema,
      parameters = tool.parameters, approval = tool.approval or 'unknown',
      published = is_published, note = connector.enabled ~= true and 'connector_disabled' or tool.note,
    }
  end
  table.sort(tools, function(a, b) return a.name < b.name end)
  return {
    key = tostring(peer.name) .. ':' .. tostring(connector.id), id = connector.id, peer = peer.name,
    node_id = peer.node_id, where = tostring(peer.name), scope = 'peer',
    name = connector.name or connector.id, transport = connector.transport or 'unknown',
    state = connector.state or (connector.enabled and 'enabled' or 'disabled'), error = connector.error,
    enabled = connector.enabled == true,
    tool_count = published, approved = connector.approved or #tools, discovered = #tools,
    revision = connector.revision, last_call = connector.last_call,
    tools = tools,
    policy = { tier = 'mcp', managed_by = tostring(peer.name) .. ' (lua/core/mcp.lua there)',
      approval = 'approved on ' .. tostring(peer.name) .. ' as read or write; this node calls it through the fabric',
      note = connector.note or ('Runs on ' .. tostring(peer.name) .. '; its own write gates and approvals still decide.') },
  }
end

-- Every online peer's connectors, from the federation cache (never the network: this is a view, and
-- `federation.catalog` refreshes on its own ten-minute rule). A peer on an older build reports tools and
-- no registry, and is shown as one connector that says so rather than as nothing.
-- Every online peer's connectors, from the federation cache. `opts.cache_only` reads it without the
-- ten-minute refresh: a window's GET has its own timeout and must not inherit the federation budget, so it
-- shows the cache and its age instead of waiting.
function M.peer_connectors(opts)
  opts = opts or {}
  local ok, cache = pcall(function()
    if opts.cache_only then return federation().cached() end
    return federation().catalog()
  end)
  if not ok or type(cache) ~= 'table' then return {}, { ok = false, error = 'federation_cache_unreadable' } end
  local list = {}
  local peers = {}
  for _, peer in pairs(cache.peers or {}) do peers[#peers + 1] = peer end
  table.sort(peers, function(a, b) return tostring(a.name) < tostring(b.name) end)
  for _, peer in ipairs(peers) do
    local exported = {}
    for _, tool in ipairs(peer.tools or {}) do exported[federation().local_name(peer.name, tool.name)] = true end
    if type(peer.connectors) == 'table' and #peer.connectors > 0 then
      for _, connector in ipairs(peer.connectors) do
        list[#list + 1] = peer_connector(peer, connector, exported)
      end
    elseif #(peer.tools or {}) > 0 then
      -- An older peer reports its exported tools and not its registry. Group them by the peer's OWN words -
      -- `mcp.schemas` composes `MCP <id> / <tool>: ...`, and `[native] ...` is its native path - so the
      -- operator still sees that peer's connectors as connectors, with the exact names. Nothing here is a
      -- guess: a tool matching neither pattern keeps its own "other exported tools" group, and every group
      -- says the registry was not reported, so `toggle` refuses instead of pretending it could.
      local groups, order = {}, {}
      local function bucket(id, label, transport)
        if not groups[id] then
          groups[id] = { name = label, transport = transport, tools = {} }
          order[#order + 1] = id
        end
        return groups[id]
      end
      for _, tool in ipairs(peer.tools) do
        local description = tostring(tool.description or '')
        local id = description:match('^MCP ([%w_%-]+) / ')
        local label, transport
        if id then
          label, transport = id, 'unknown'
        elseif description:sub(1, 8) == '[native]' then
          id, label, transport = 'native', tostring(peer.name) .. ' native', 'native'
        else
          id, label, transport = '*', tostring(peer.name) .. ' (other exported tools)', 'unknown'
        end
        local group = bucket(id, label, transport)
        group.tools[#group.tools + 1] = { name = federation().local_name(peer.name, tool.name), tool = tool.name,
          description = description, parameters = tool.parameters, approval = tool.effect or 'unknown',
          published = true }
      end
      for _, id in ipairs(order) do
        local group = groups[id]
        table.sort(group.tools, function(a, b) return a.name < b.name end)
        list[#list + 1] = {
          key = tostring(peer.name) .. ':' .. id, id = id, peer = peer.name, node_id = peer.node_id,
          where = tostring(peer.name), scope = 'peer', name = group.name, transport = group.transport,
          state = 'enabled', enabled = true, tool_count = #group.tools, approved = #group.tools,
          discovered = #group.tools, tools = group.tools,
          policy = { tier = 'mcp', managed_by = tostring(peer.name),
            approval = 'the peer decided each tool\'s effect; this node cannot read its registry',
            note = 'The peer did not report its connector registry (older build): its exported tools are grouped '
              .. 'by its own descriptions, and cannot be turned on or off from here.' },
          note = 'connector_registry_not_reported',
        }
      end
    elseif #(peer.tools or {}) == 0 and peer.error then
      list[#list + 1] = {
        key = tostring(peer.name) .. ':*', id = '*', peer = peer.name, node_id = peer.node_id,
        where = tostring(peer.name), scope = 'peer', name = tostring(peer.name) .. ' (no answer)',
        transport = 'unknown', state = 'failing', error = tostring(peer.error), enabled = false,
        tool_count = 0, approved = 0, discovered = 0, tools = {},
        policy = { tier = 'mcp', managed_by = tostring(peer.name),
          approval = 'unknown: the peer answered with an error', note = tostring(peer.error) },
        note = 'connector_registry_not_reported',
      }
    end
  end
  return list, { ok = true, at = cache.at }
end

-- The list `/mcp` prints and the window renders. `read_only` is the guest's answer: the same inventory,
-- with no controls (the toggle refuses, and says why).
function M.list(ctx, opts)
  opts = opts or {}
  local role = type(ctx) == 'table' and ctx.role or 'guest'
  local read_only = not (role == 'master' or role == 'admin')
  local local_list, registry = M.local_connectors(ctx)
  local peer_list, peers_meta = M.peer_connectors(opts)
  local connectors = {}
  for _, entry in ipairs(local_list) do connectors[#connectors + 1] = entry end
  for _, entry in ipairs(peer_list) do connectors[#connectors + 1] = entry end
  local enabled, tools = 0, 0
  for _, entry in ipairs(connectors) do
    if entry.enabled == true then enabled = enabled + 1 end
    tools = tools + (tonumber(entry.tool_count) or 0)
  end
  return {
    ok = true, connectors = connectors, read_only = read_only, role = role,
    revision = registry and registry.revision, registry_error = registry and registry.error,
    peers_at = peers_meta and peers_meta.at,
    counts = { connectors = #connectors, here = #local_list, from_peers = #peer_list, enabled = enabled, tools = tools },
    note = read_only
      and 'Read-only: turning a connector on or off needs a master (the same rule the mcp tool follows).'
      or 'A change applies to new sessions at once; sessions already running are told on their next turn '
        .. 'by the existing [session update] note, because the callable tool list is part of the frozen prefix.',
  }
end

-- The connector a key names. Keys are the list's own (`whatsapp`, `openclaw:whatsapp_native`), and a bare
-- id that only one connector has is accepted, because that is what a reader types.
function M.find(view, key)
  key = tostring(key or '')
  for _, entry in ipairs(view.connectors or {}) do if entry.key == key then return entry end end
  local matches = {}
  for _, entry in ipairs(view.connectors or {}) do if entry.id == key then matches[#matches + 1] = entry end end
  if #matches == 1 then return matches[1] end
  if #matches > 1 then return nil, matches end
  return nil
end

-- What one connector gives the model, verbatim: the names, their descriptions and their exact schemas.
function M.inspect(ctx, key, opts)
  local view = M.list(ctx, opts)
  local entry, ambiguous = M.find(view, key)
  if not entry then
    if ambiguous then
      local keys = {}
      for _, item in ipairs(ambiguous) do keys[#keys + 1] = item.key end
      return { ok = false, error = 'connector_ambiguous', keys = keys }
    end
    return { ok = false, error = 'unknown_connector', key = tostring(key) }
  end
  return { ok = true, connector = entry, read_only = view.read_only, note = view.note }
end

-- The audit line, on the node whose registry moved. `harness_events` is where this node already records
-- durable node state (a session update lands there too), so a control action is one more row of the same
-- ledger rather than a second log. Never fatal: an audit write that fails must not undo the change.
local function audit(ctx, action, payload)
  local session = type(ctx) == 'table' and ctx.session_id or nil
  pcall(function()
    dofile('lua/core/telemetry.lua').event(session and session ~= '' and session or 'mcp-command',
      '', '', 'mcp_control', action, payload)
  end)
end

-- Turn one connector on or off, through the path that owns it.
--
-- Local: `mcp.control`, with the revision read in this same call - validation, the probe requirement and
-- the CAS are unchanged, so a change that raced another writer refuses instead of overwriting it.
-- Peer: `federation.control`, which asks the peer's own registry under a verified master's authority; the
-- peer validates, audits and answers with its new state, and this node writes that answer into its cache
-- so its own catalogue changes at once.
function M.toggle(ctx, key, enable, opts)
  opts = opts or {}
  local view = M.list(ctx, opts)
  if view.read_only then
    return { ok = false, error = 'forbidden', effect = 'none',
      note = 'Read-only: turning a connector on or off needs a master.' }
  end
  local entry = M.find(view, key)
  if not entry then return { ok = false, error = 'unknown_connector', key = tostring(key) } end
  local action = enable and 'enable' or 'disable'
  if entry.scope == 'local' then
    if type(view.revision) ~= 'number' then
      return { ok = false, error = 'mcp_registry_unreadable', detail = view.registry_error }
    end
    local answer = mcp_module().control({ action = action, id = entry.id,
      expected_revision = tonumber(opts.expected_revision) or view.revision }, ctx)
    if not answer.ok then
      audit(ctx, action, { connector = entry.key, where = 'this node', ok = false, error = answer.error,
        revision = answer.revision })
      answer.connector = entry.key
      answer.where = 'this node'
      return answer
    end
    audit(ctx, action, { connector = entry.key, where = 'this node', ok = true, enabled = answer.enabled,
      revision = answer.revision, by = type(ctx) == 'table' and ctx.user_id or nil })
    local after = M.inspect(ctx, entry.key, opts)
    return { ok = true, action = action, connector = entry.key, where = 'this node', id = entry.id,
      enabled = answer.enabled == true, revision = answer.revision,
      connector_state = after.ok and after.connector or nil, note = view.note }
  end
  if entry.note == 'connector_registry_not_reported' then
    return { ok = false, error = 'connector_registry_not_reported', connector = entry.key, where = entry.where,
      effect = 'none', note = 'That peer reported tools, not its registry: it cannot be turned on or off from here.' }
  end
  local answer = federation().control(entry.peer, { action = action, id = entry.id,
    expected_revision = entry.revision }, { ctx = ctx, call = opts.call })
  audit(ctx, action, { connector = entry.key, where = entry.peer, ok = answer.ok == true, error = answer.error,
    revision = answer.revision, by = type(ctx) == 'table' and ctx.user_id or nil })
  if not answer.ok then
    answer.connector = entry.key
    answer.where = entry.peer
    return answer
  end
  local after = M.inspect(ctx, entry.key, opts)
  return { ok = true, action = action, connector = entry.key, where = entry.peer, id = entry.id,
    enabled = answer.enabled == true, revision = answer.revision,
    connector_state = after.ok and after.connector or nil, note = view.note }
end

-- ---------------------------------------------------------------- text (the terminal view)
local function pad(text, width) return tostring(text) .. string.rep(' ', math.max(0, width - #tostring(text))) end

local function summary(entry)
  local count = string.format('%d tool%s', entry.tool_count, entry.tool_count == 1 and '' or 's')
  local detail = entry.error and ('  ! ' .. tostring(entry.error)) or ''
  return string.format('%s %s %s %s', entry.state, entry.transport, count, detail)
end

-- The list. One row per connector: scope, key, name, where, transport, state, tools, and the last error.
-- The keys are what `/mcp <key>` opens, so they are printed whole and never shortened.
function M.text(view)
  local lines = {}
  local counts = view.counts or {}
  lines[#lines + 1] = string.format('MCP connectors: %d (%d here, %d from peers) - %d enabled, %d tools callable now',
    counts.connectors or 0, counts.here or 0, counts.from_peers or 0, counts.enabled or 0, counts.tools or 0)
  if view.read_only then lines[#lines + 1] = '  read-only: ' .. tostring(view.note) end
  if #(view.connectors or {}) == 0 then
    lines[#lines + 1] = '  none: no connector is registered on this node and no peer exports one.'
  end
  local key_width = 0
  for _, entry in ipairs(view.connectors or {}) do key_width = math.max(key_width, #entry.key) end
  key_width = math.min(key_width, 40)
  for _, entry in ipairs(view.connectors or {}) do
    lines[#lines + 1] = string.format('  %-5s %s %s  %s', entry.scope, pad(entry.key, key_width),
      summary(entry), entry.name)
  end
  -- A peer's half is a cache: say how old it is when that is old enough to matter, rather than implying a
  -- liveness the read never had.
  local age = tonumber(view.peers_at) and (host.now() - tonumber(view.peers_at)) or nil
  if age and age > 300 then
    lines[#lines + 1] = string.format('  peer connectors as last refreshed %d min ago (federation refreshes '
      .. 'every 10 min, and on a binding or promotion)', math.floor(age / 60))
  end
  lines[#lines + 1] = '  open one: /mcp <key>   turn it on/off: /mcp <key> on|off'
  return table.concat(lines, '\n')
end

-- One connector, in full: where it runs, what it is, its policy, and every control it gives the model
-- with the exact name, the description and the input schema the model is offered.
function M.detail_text(entry)
  local lines = {}
  lines[#lines + 1] = string.format('%s - %s', entry.key, entry.name)
  lines[#lines + 1] = string.format('  where: %s (%s)   transport: %s   state: %s%s', entry.where, entry.scope,
    entry.transport, entry.state, entry.error and (' - ' .. tostring(entry.error)) or '')
  lines[#lines + 1] = string.format('  tools callable now: %d (approved %d, discovered %d)',
    entry.tool_count, entry.approved or 0, entry.discovered or 0)
  if entry.policy then
    lines[#lines + 1] = string.format('  policy: tier %s - %s', tostring(entry.policy.tier), tostring(entry.policy.approval))
    if entry.policy.note then lines[#lines + 1] = '  ' .. tostring(entry.policy.note) end
  end
  if entry.observed then lines[#lines + 1] = '  last observation: ' .. tostring(entry.observed) end
  if #(entry.tools or {}) == 0 then
    lines[#lines + 1] = '  this connector gives the model no tool: it has not been probed, or it exposes none.'
  else
    lines[#lines + 1] = '  controls it gives the model (names verbatim):'
    for _, tool in ipairs(entry.tools) do
      lines[#lines + 1] = string.format('    %s  [%s%s]', tool.name, tostring(tool.approval),
        tool.published and ', callable now' or ', not callable now')
      if tool.description and tool.description ~= '' then lines[#lines + 1] = '      ' .. tostring(tool.description) end
      lines[#lines + 1] = '      schema: ' .. tostring(tool.schema or (tool.parameters and json.encode(tool.parameters)) or '{}')
    end
  end
  return table.concat(lines, '\n')
end

return M
