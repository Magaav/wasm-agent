-- Fleet bootstrap from the command line: `wa fleet push-roster <node>`.
--
-- The problem: a node that was bound before the mesh existed pins the operator list it was bound
-- with, and no mesh call can change that from the outside. The fleet therefore has to be installed
-- *on* it, by a node it already accepts under today's binding.
--
-- What this command does, in one sentence: from a node that is already one of <node>'s operators, it
-- sends the signed fleet roster and the fleet **public** key to <node> over the transport <node>
-- already serves (the relay), lets <node> install it (pin the key, merge the `mesh` section into its
-- own `policy.json` with a backup, write the roster, enable the flag for the next start), and then
-- proves it with a mesh call that <node> decides by the roster.
--
-- The merged `mesh` section is the whole statement a *running* node needs, because it cannot be
-- restarted to be given one: `enabled`, the roster, and the listener's port — taken from the roster's
-- own address for <node> (the only "where this node answers" a relayed push carries), so the node's
-- live mount opens the listener on its next poll (rust/wa-mesh/src/host_call.rs). A target the roster
-- gives no address keeps its own `mesh.port`, and the answer says it is not listening.
--
-- The roster itself is made with the operator's tools, which never travel and never need a node:
--
--   wa fleet keygen --out ~/fleet/ohana.key          create the fleet key, print its public key
--   wa fleet sign roster.json --key ~/fleet/ohana.key --expires-days 90
--   wa fleet show roster.signed.json                 verify it and print the levels
--   wa fleet push-roster nextcloud
--   wa fleet push-roster nextcloud --replace-key <hex>    re-anchor a node that pins another key
--
-- `keygen`, `sign` and `show` are dispatched by the Rust host (wa_mesh::fleetkey) before this module
-- is reached; `push-roster` is here because it needs this node's identity, policy and relay.
--
-- What never travels: the fleet private key. The request carries a signature made with *this* node's
-- key, a signed roster and a public key. Nothing here can sign as the fleet.
--
-- `--replace-key <hex>` is the *old* fleet key's signature over
-- `mesh-anchor-v1|<new key>|<roster fingerprint>`, which only the operator who holds that key can
-- produce. Without it a node that already pins a different fleet key refuses the push: no silent
-- re-anchoring (docs/MESH.md §7).
local json = dofile('lua/vendor/json.lua')
local nodes = dofile('lua/core/nodes.lua')
local paths = dofile('lua/core/paths.lua')

local M = {}

local function fail(code, detail)
  local out = { ok = false, error = code }
  if detail ~= nil then out.detail = tostring(detail) end
  print(json.encode(out))
  return out
end

local function decode(raw)
  local ok, value = pcall(json.decode, raw or '')
  if not ok or type(value) ~= 'table' then return nil end
  return value
end

-- This node's own roster and the key its policy pins: the material a push carries.
local function local_fleet()
  local policy = decode(host.read_file(paths.config() .. '/policy.json') or '')
  local mesh = policy and type(policy.mesh) == 'table' and policy.mesh or {}
  local key = tostring(mesh.roster_key or '')
  local roster_path = host.getenv('WASM_AGENT_MESH_ROSTER')
  if not roster_path or roster_path == '' then
    roster_path = type(mesh.roster) == 'string' and mesh.roster ~= '' and mesh.roster or 'mesh-roster.json'
    if roster_path:sub(1, 1) ~= '/' and not roster_path:match('^%a:') then
      roster_path = paths.config() .. '/' .. roster_path
    end
  end
  local text = host.read_file(roster_path)
  if not text or text == '' then return nil, 'roster_missing', roster_path end
  if key == '' then return nil, 'roster_key_missing', paths.config() .. '/policy.json' end
  return { text = text, key = key, path = roster_path }
end

-- The node the operator named, resolved through the roster: the roster is what says a node exists,
-- and its entry is the node_id the push is addressed to.
local function target(fleet, selector)
  local roster = decode(fleet.text)
  if not roster or type(roster.nodes) ~= 'table' then return nil, 'roster_unreadable' end
  local found
  for _, node in ipairs(roster.nodes) do
    if type(node) == 'table' and (node.node_id == selector or node.name == selector) then
      if found then return nil, 'fleet_target_ambiguous' end
      found = node
    end
  end
  if not found then return nil, 'fleet_target_not_in_roster' end
  return found
end

-- The push itself: the caller's own `/node/call` request (signed the way every peer call is) with a
-- `roster` capability, sent over the transport the target already serves.
local function push(peer, args)
  local body = json.encode({
    from_node_id = (nodes.identity() or {}).node_id,
    to_node_id = peer.node_id,
    request_id = host.uuid(),
    capability = 'roster',
    args = args,
  })
  local headers, problem = nodes.signed_headers('call', body)
  if not headers then return nil, problem or 'no_identity' end
  local response = nodes.request(peer, '/node/call', body, headers)
  if not response then return nil, 'remote_unreachable' end
  if response.error == 'relay_refused' then
    return nil, 'relay_refused:' .. tostring(response.reason or response.relay_status)
  end
  if response.error then return nil, tostring(response.error) end
  local decoded, reason, refusal = nodes.verified_reply(peer, headers, response.body or '')
  if refusal then return nil, refusal.reason or 'remote_refused' end
  if not decoded then return nil, reason or 'unsigned_reply' end
  return decoded
end

-- After the install: one mesh call the *target* must decide by the roster. This is the only proof
-- that the bootstrap worked, because the push itself was admitted by today's pins.
local function verify(peer, capability)
  if type(host.mesh_call) ~= 'function' then return { ok = false, error = 'mesh_disabled' } end
  local inner = json.encode({
    from_node_id = (nodes.identity() or {}).node_id,
    to_node_id = peer.node_id,
    request_id = host.uuid(),
    capability = capability,
    args = {},
  })
  local headers, problem = nodes.signed_headers('call', inner)
  if not headers then return { ok = false, error = problem or 'no_identity' } end
  local pairs_list = {}
  for name, value in pairs(headers) do pairs_list[#pairs_list + 1] = { name, tostring(value) } end
  local ok, raw = pcall(host.mesh_call, json.encode({
    node = peer.node_id,
    capability = capability,
    args = {},
    inner_body = inner,
    inner_headers = pairs_list,
    peers = { nodes = nodes.peers({ fresh = true }) },
  }))
  if not ok or type(raw) ~= 'string' then return { ok = false, error = 'mesh_unavailable' } end
  local answer = decode(raw)
  if not answer then return { ok = false, error = 'mesh_unreadable' } end
  if answer.ok then
    return { ok = true, transport = answer.transport, decision = answer.decision,
             reason = answer.reason, node = answer.node, level = answer.level }
  end
  return { ok = false, error = tostring(answer.error or 'mesh_refused'),
           reason = tostring(answer.reason or answer.code or ''),
           detail = answer.detail, transport = answer.transport }
end

function M.usage()
  print('wa fleet keygen --out <path>          create the fleet key (ed25519, mode 0600), print its public key')
  print('wa fleet sign <roster.json> --key <path> [--expires-days N] [--out <path>]')
  print('    sign the roster and write <name>.signed.json; refuses unknown fields and duplicate ids')
  print('wa fleet show <roster.json> [--key <hex|path>]')
  print('    verify a roster and print its levels (this node\'s policy.json key by default)')
  print('wa fleet push-roster <node> [--replace-key <hex>]')
  print('    install the signed fleet roster on <node>, from a node it already accepts as an')
  print('    operator, then verify it with a mesh call (docs/MESH.md §7). The fleet private key')
  print('    never travels: only the public key and the signed roster do.')
end

-- `rest` is everything after the subcommand: "<node> [--replace-key <hex>]".
function M.run(sub, rest)
  if sub == nil or sub == '' or sub == '--help' or sub == 'help' then
    M.usage()
    return { ok = true, usage = true }
  end
  if sub ~= 'push-roster' then return fail('fleet_subcommand_unknown', sub) end
  local selector, replace_key = nil, nil
  for word in tostring(rest or ''):gmatch('%S+') do
    if word == '--replace-key' then
      replace_key = true -- the value is the next word
    elseif replace_key == true then
      replace_key = word
    elseif selector == nil then
      selector = word
    end
  end
  if not selector then return fail('fleet_node_required', 'wa fleet push-roster <node>') end
  local fleet, problem, detail = local_fleet()
  if not fleet then return fail(problem, detail) end
  if type(host.mesh_call) ~= 'function' then return fail('mesh_disabled', 'this host has no host.mesh_call') end
  -- The roster must be the operator's own, and it must be current: a push of an unverified roster is
  -- refused here, so the target is never asked to consider one.
  local local_check = decode(host.mesh_call(json.encode({ verify_roster = { text = fleet.text, key = fleet.key } })))
  if not local_check or local_check.ok ~= true then
    return fail('roster_unverified', local_check and local_check.detail or 'roster_unverified')
  end
  local peer, why = target(fleet, selector)
  if not peer then return fail(why or 'fleet_target_not_in_roster', selector) end
  local me = nodes.identity() or {}
  if peer.node_id == me.node_id then return fail('fleet_target_is_this_node') end

  local pushed, push_problem = push(peer, {
    action = 'push',
    roster = fleet.text,
    roster_key = fleet.key,
    replace_key_signature = type(replace_key) == 'string' and replace_key or nil,
  })
  if not pushed then return fail(push_problem or 'roster_push_failed', tostring(peer.name or peer.node_id)) end
  if pushed.ok ~= true then
    local out = { ok = false, error = tostring(pushed.error or 'roster_push_refused'), node = peer.name }
    for _, field in ipairs({ 'detail', 'previous_key', 'roster_key' }) do
      if pushed[field] ~= nil then out[field] = pushed[field] end
    end
    print(json.encode(out))
    return out
  end

  -- Installed. Prove it: one call the target must decide by the roster, not by the pins that admitted
  -- the push. `status` is a read: it changes nothing on the target.
  local checked = verify(peer, 'status')
  local out = {
    ok = checked.ok == true,
    node = peer.name, node_id = peer.node_id,
    installed = {
      fleet = pushed.fleet, fingerprint = pushed.fingerprint, nodes = pushed.nodes,
      roster_key = pushed.roster_key, previous_key = pushed.previous_key,
      backup = pushed.backup, roster_path = pushed.roster_path, env = pushed.env,
      -- The listener the *running* target now mounts (or why it does not): a port means the next
      -- poll of its mount opens the socket, with no restart.
      port = pushed.port, bind = pushed.bind, listener = pushed.listener,
    },
    verification = checked,
    privacy = 'the fleet private key never left this node',
  }
  if not out.ok then out.error = checked.error or 'roster_verification_failed' end
  print(json.encode(out))
  return out
end

return M
