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
  -- A connector of the WhatsApp family is RETIRED, not broken, and the row says so instead of repeating
  -- the last probe error it recorded.
  --
  -- The Go connector (`connectors/whatsapp`) went on 11/11 (Phase 4) and nothing in this tree serves its
  -- port any more; 28787/8787 belongs to unrelated services now. A registry row can outlive its program,
  -- and the row used to keep publishing `failing` with the last error it saw - "connector stopped, port
  -- 8787 held by space-serve", "down ~37h" - which reads as a live incident: session b393f280 spent ten
  -- rounds chasing a connector that cannot be started again before it gave up on the task. A retired
  -- thing must SAY it is retired, once, in the place the model reads it.
  local retired = nil
  if superseded then
    state, error = 'retired', nil
    retired = 'retired: the WhatsApp Go connector was removed on 11/11 and this row is what is left of it. '
      .. 'It is not stopped, absent or down, and no port it used to hold says anything about this node. '
      .. 'WhatsApp is mcp_whatsapp_* - one surface, answered by the node that holds the account.'
  end
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
  end
  -- A retired row keeps its facts but not its last failure's words: the probe/observed/last-call error
  -- strings are what carried the port 8787 / "down ~37h" noise to the model, and none of it is true any
  -- more. `retired_at` is the fact that replaces them.
  local reported_probe, observed, last_call = server.probe, server.observed_status, server.last_call
  if superseded then
    local function cleared(value)
      if type(value) ~= 'table' then return value end
      local copy = {}
      for key, item in pairs(value) do if key ~= 'error' then copy[key] = item end end
      if next(copy) == nil then return nil end
      copy.retired = true
      return copy
    end
    reported_probe, observed, last_call = cleared(reported_probe), cleared(observed), cleared(last_call)
  end
  return {
    key = server.id, id = server.id, name = server.name or server.id,
    where = 'this node', scope = 'local', transport = definition.transport or 'unknown',
    state = state, error = error, enabled = server.enabled == true,
    tool_count = published, approved = #sorted_keys(approved), discovered = #(server.probe and server.probe.tools or {}),
    revision = revision, observed = observed, last_call = last_call, probe = reported_probe,
    -- The vault keys this connector's definition names, by NAME only (`secret_env`): the detail page is
    -- where a reader learns which key to store, and a value never crosses this boundary.
    secret_env = definition.secret_env,
    note = retired or (superseded and 'superseded_by_mcp_whatsapp' or nil),
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

-- ------------------------------------------------------- the balloon (one screen, three levels)
--
-- What `/mcp` shows, as pages `lua/core/balloon.lua` draws - the SAME pages whether the reader is between
-- runs (the interpreter opens them) or in the middle of one (the client draws the published stack from
-- `host.local_view` while this interpreter is blocked in the model call).
--
-- The shape it replaces, and why. `/mcp` printed a table of connector rows, a wall of prose per
-- connector, and every tool's input schema as raw JSON; changing one meant typing `/mcp <key> on`. The
-- operator's words were "a horrible ux". So: one screen listing every connector with its state, tool
-- count and last error on one line; Enter opens the connector (where it runs, the error in full, what it
-- gives the model); its tools are one keypress further, with the schema *summarised* as the fields it
-- takes rather than pasted.
--
-- Actions are pages too, and always as a `run` line - `/mcp <key> probe`, `/mcp <key> off` - never a Lua
-- callback: the client cannot run one (it has no registry), so an option the client can draw has to be a
-- line the interpreter executes. Mid-run that line is queued for the next turn, and the balloon says so.
local balloon = dofile('lua/core/balloon.lua')

-- The one word a reader scans for, per state the registry reports. `enabled` is the registry's word for a
-- connector that answered its last probe and is published; nobody outside `lua/core/mcp.lua` says it.
local STATE_LABELS = {
  enabled = 'connected', stale = 'stale', failing = 'failed', disabled = 'disabled',
  -- A row whose program was removed (`514a1c41`): retired, not broken, and the one word that says so.
  retired = 'retired',
}

-- Whether the connector's own error says the far end refused a credential: the one case where turning it
-- on is not the next action, signing in is.
local function credential_refused(entry)
  local text = tostring(entry.error or ''):lower()
  return text:find('401', 1, true) or text:find('403', 1, true) or text:find('unauthor', 1, true)
    or text:find('not logged in', 1, true) or text:find('login', 1, true)
    or text:find('credential', 1, true) or text:find('token expired', 1, true)
end

-- The state, in one word. `needs login` wins: a credential the far end refused is more useful to know than
-- that the last call failed, and it names the next action.
function M.state_label(entry)
  if credential_refused(entry) then return 'needs login' end
  return STATE_LABELS[tostring(entry.state)] or tostring(entry.state or 'unknown')
end

-- "6 tools", "1 tool", "no tool".
local function tools_phrase(count)
  count = tonumber(count) or 0
  if count == 0 then return 'no tool' end
  return string.format('%d tool%s', count, count == 1 and '' or 's')
end

-- The vault keys this connector's definition names (`secret_env`), by name. Only the NAMES: a value never
-- leaves the vault, and this page is the only place a reader learns which name to store.
local function vault_keys(entry)
  local names = {}
  for _, name in ipairs(entry.secret_env or {}) do names[#names + 1] = tostring(name) end
  return names
end

-- The input a tool takes, summarised: its field names, or "none". The old detail pasted the whole JSON
-- schema; at 80 columns that was unreadable, and the fields are what a reader is actually asking about.
local function input_fields(tool)
  local schema = tool.schema or tool.parameters
  if type(schema) == 'string' then
    local decoded
    if pcall(function() decoded = json.decode(schema) end) and type(decoded) == 'table' then schema = decoded end
  end
  if type(schema) ~= 'table' then return 'unknown' end
  local names = {}
  for name in pairs(schema.properties or {}) do names[#names + 1] = tostring(name) end
  table.sort(names)
  if #names == 0 then return 'none' end
  return table.concat(names, ', ')
end

-- One tool, in full but not in JSON: what it does, how it is approved, whether the model is offered it
-- now, and the fields it takes.
function M.tool_page(tool, entry, back)
  local lines = {
    'from ' .. tostring(entry.key) .. ' (' .. tostring(entry.where) .. ')',
    string.format('approval: %s \u{b7} %s', tostring(tool.approval or 'unknown'),
      tool.published and 'the model is offered it now' or 'not offered to the model now'),
    'input: ' .. input_fields(tool),
  }
  if tool.description and tool.description ~= '' then
    for _, line in ipairs(balloon.wrap(tostring(tool.description), balloon.WIDTH, '')) do lines[#lines + 1] = line end
  end
  if tool.note then lines[#lines + 1] = 'note: ' .. tostring(tool.note) end
  return balloon.page({ title = tostring(tool.name), lines = lines,
    options = { { label = 'Back', hint = 'the connector', back = true } } })
end

-- What one connector's tools are, as a page of options: one per tool, with its approval and whether the
-- model is offered it.
function M.tools_page(entry, links, back)
  local options = {}
  for index, tool in ipairs(entry.tools or {}) do
    options[#options + 1] = {
      label = tostring(tool.name),
      hint = string.format('%s \u{b7} %s', tostring(tool.approval or 'unknown'),
        tool.published and 'callable now' or 'not callable now'),
      page = links.tool[index],
    }
  end
  options[#options + 1] = { label = 'Back', hint = 'the connector', back = true }
  local lines = {
    string.format('%s \u{b7} %s', tostring(entry.key),
      #(entry.tools or {}) == 0 and 'no tool' or tools_phrase(#(entry.tools or {}))),
  }
  if #(entry.tools or {}) == 0 then
    lines[#lines + 1] = 'This connector gives the model no tool: it has not been probed, or it exposes none.'
  else
    lines[#lines + 1] = 'The exact name the model is given, then how it is approved. Enter opens one.'
  end
  return balloon.page({ title = 'Tools', lines = lines, options = options, selected = 1 })
end

-- One connector: where it runs, how it stands, the error in full, and what can be done from here.
--
-- The actions are the node's real verbs and nothing more: `probe` re-reads the tool list (that is what
-- "reconnect" means here), `on`/`off` is the registry's own enable/disable, and `login` is offered only
-- when the connector's definition names a vault key - an invented sign-in flow would be a lie on screen.
function M.detail_page(entry, links, opts)
  opts = opts or {}
  local lines = {
    string.format('where: %s (%s) \u{b7} transport %s \u{b7} revision %s', tostring(entry.where),
      tostring(entry.scope), tostring(entry.transport), tostring(entry.revision or '?')),
    string.format('state: %s \u{b7} %s callable now (approved %s, discovered %s)', M.state_label(entry),
      tostring(entry.tool_count or 0), tostring(entry.approved or 0), tostring(entry.discovered or 0)),
  }
  if entry.note then lines[#lines + 1] = 'note: ' .. tostring(entry.note) end
  if entry.observed then lines[#lines + 1] = 'last observation: ' .. tostring(entry.observed) end
  local error_text = entry.error and tostring(entry.error) or ''
  if entry.last_call and type(entry.last_call) == 'table' and entry.last_call.ok == false and entry.last_call.error then
    error_text = error_text ~= '' and error_text or tostring(entry.last_call.error)
  end
  if error_text ~= '' then
    lines[#lines + 1] = 'error:'
    for _, line in ipairs(balloon.wrap(error_text, balloon.WIDTH, '  ')) do lines[#lines + 1] = line end
  else
    lines[#lines + 1] = 'error: none reported'
  end
  if entry.policy and entry.policy.approval then
    for _, line in ipairs(balloon.wrap('approval: ' .. tostring(entry.policy.approval), balloon.WIDTH, '')) do
      lines[#lines + 1] = line
    end
  end
  local options = {
    { label = (entry.tools and #entry.tools > 0) and ('Tools (' .. #entry.tools .. ')') or 'Tools',
      hint = 'names, approvals, inputs', page = links.tools },
  }
  if entry.scope == 'local' then
    options[#options + 1] = { label = 'Reconnect', hint = 'probe again, now', run = '/mcp ' .. entry.key .. ' probe' }
    options[#options + 1] = entry.enabled
      and { label = 'Turn off', hint = 'the model stops seeing its tools', run = '/mcp ' .. entry.key .. ' off' }
      or { label = 'Turn on', hint = 'needs a passed probe and every approved tool', run = '/mcp ' .. entry.key .. ' on' }
    local keys = vault_keys(entry)
    if M.state_label(entry) == 'needs login' or #keys > 0 then
      options[#options + 1] = { label = 'Sign in', hint = #keys > 0 and ('vault key ' .. table.concat(keys, ', '))
        or 'no vault key is named by this connector', run = '/mcp ' .. entry.key .. ' login' }
    end
  else
    options[#options + 1] = { label = 'Reconnect', hint = 'on ' .. tostring(entry.where) .. ', from there',
      run = '/mcp ' .. entry.key .. ' probe' }
    if not entry.note then
      options[#options + 1] = entry.enabled
        and { label = 'Turn off', hint = 'asks ' .. tostring(entry.where), run = '/mcp ' .. entry.key .. ' off' }
        or { label = 'Turn on', hint = 'asks ' .. tostring(entry.where), run = '/mcp ' .. entry.key .. ' on' }
    end
  end
  options[#options + 1] = { label = 'Back', hint = 'the list', back = true }
  return balloon.page({ title = tostring(entry.key) .. (entry.name and entry.name ~= entry.key and (' \u{b7} ' .. tostring(entry.name)) or ''),
    lines = lines, options = options, selected = 1, hint = 'Enter opens \u{b7} Esc or \u{2190} goes back' })
end

-- The whole `/mcp` balloon: the list and one detail page per connector, plus its tools and their pages.
-- `links` is the bookkeeping a linked stack needs; nothing here reads a clock or a registry twice.
function M.views(view, opts)
  opts = opts or {}
  view = view or { connectors = {}, counts = {} }
  local counts = view.counts or {}
  local pages = {}
  local lines = {
    string.format('%d connectors \u{b7} %d here, %d from peers \u{b7} %d enabled \u{b7} %d tools callable now',
      counts.connectors or 0, counts.here or 0, counts.from_peers or 0, counts.enabled or 0, counts.tools or 0),
  }
  if view.read_only then
    lines[#lines + 1] = 'read-only: ' .. tostring(view.note)
  end
  local list = balloon.page({ title = 'MCP connectors', lines = lines, options = {}, selected = 1,
    hint = 'Enter opens a connector \u{b7} Esc or \u{2190} closes' })
  pages[1] = list
  if #(view.connectors or {}) == 0 then
    list.lines[#list.lines + 1] = 'none: no connector is registered on this node, and no peer exports one.'
  end
  local index = 1
  for _, entry in ipairs(view.connectors or {}) do
    index = index + 1
    local detail_index = index
    index = index + 1
    local tools_index = index
    local tool_pages = {}
    for tool_number in ipairs(entry.tools or {}) do
      index = index + 1
      tool_pages[tool_number] = index
    end
    local links = { tools = tools_index, tool = tool_pages }
    pages[detail_index] = M.detail_page(entry, links, opts)
    pages[tools_index] = M.tools_page(entry, links, detail_index)
    for tool_number, tool in ipairs(entry.tools or {}) do
      pages[tool_pages[tool_number]] = M.tool_page(tool, entry, detail_index)
    end
    local hint = string.format('%s \u{b7} %s \u{b7} %s', tostring(entry.key), M.state_label(entry),
      tools_phrase(entry.tool_count))
    if entry.error and tostring(entry.error) ~= '' then
      hint = hint .. ' \u{b7} ' .. balloon.fit(tostring(entry.error), 28)
    end
    list.options[#list.options + 1] = {
      label = tostring(entry.name or entry.key), hint = hint, page = detail_index,
    }
  end
  return { command = '/mcp', captured_at = host.now and host.now() or os.time(), views = pages, view = view }
end

-- The list as text: the balloon's own rendering of its first page (a pipe gets this, and so does a snapshot).
function M.text(view, width)
  local set = M.views(view)
  return balloon.text({ set.views[1] }, width or balloon.WIDTH)
end

-- One connector as text: its page and the tools it offers, in the same rendering.
function M.detail_text(entry, width)
  local set = M.views({ connectors = { entry }, counts = { connectors = 1, here = 1, enabled = entry.enabled and 1 or 0,
    tools = entry.tool_count or 0 } })
  return balloon.text(set.views, width or balloon.WIDTH)
end

-- ---------------------------------------------------------------- reconnect
--
-- "Reconnect" is the registry's own `probe`: read the tool list again and cache it. A stale connector
-- (its tool list moved under an approved set) is fixed by this and nothing else, which is why it is the
-- first action on the detail page. A peer connector is probed on the node that runs it - this node cannot
-- start a process there - and says so instead of pretending.
function M.probe(ctx, key, opts)
  opts = opts or {}
  local view = M.list(ctx, opts)
  local entry = M.find(view, key)
  if not entry then return { ok = false, error = 'unknown_connector', key = tostring(key) } end
  if entry.scope ~= 'local' then
    return { ok = false, error = 'connector_probe_remote', connector = entry.key, where = entry.where,
      effect = 'none', note = 'a connector is probed on the node that runs it: run /mcp there, from that node' }
  end
  local answer = mcp_module().control({ action = 'probe', id = entry.id }, ctx)
  audit(ctx, 'probe', { connector = entry.key, where = 'this node', ok = answer.ok == true,
    error = answer.error, tools = type(answer.tools) == 'table' and #answer.tools or nil })
  local after = M.inspect(ctx, entry.key, opts)
  return { ok = answer.ok == true, action = 'probe', connector = entry.key, where = 'this node',
    error = answer.error, tools = type(answer.tools) == 'table' and #answer.tools or nil,
    connector_state = after.ok and after.connector or nil }
end

return M
