-- One node's half of scripts/test-federated-connector-read.mjs: one JSON answer on stdout, no model,
-- no network of its own beyond the call it is asked to make. It runs as a \`wa --script\` process in a
-- scratch home, so it acts as that node's own tooling - the same route \`/mcp <id> probe\` takes.
--
--   WA_FED_ACTION=setup   the stub connector, through mcp.control put -> probe -> enable
--   WA_FED_ACTION=local   the same tool on this node, with no relay lane under it (the control)
--   WA_FED_ACTION=call    the federated call a master makes: nodes.remote_call(peer, "federation", ...)
local json = dofile('lua/vendor/json.lua')
local action = tostring(host.getenv('WA_FED_ACTION') or '')
-- ONE NODE'S HALF, NOT A TEST OF ITS OWN. scripts/test-discriminates.sh treats every changed test-*
-- path as a row, and this file has no verdict without the harness that drives it: it says so in the one
-- shape that is neither a pass nor a failure ("^SKIP ", a hole the test itself names), so a round that
-- adds it is not blocked by a row that could never catch anything.
if action == '' then
  print('SKIP this file is one node\'s half of scripts/test-federated-connector-read.mjs; it has no verdict of its own')
  return
end
local tool = tostring(host.getenv('WA_FED_TOOL') or '')

if action == 'setup' then
  local mcp = dofile('lua/core/mcp.lua')
  local ctx = { role = 'master', user_id = 'federated-read-test', operator = true }
  local function revision() local inventory = mcp.inventory(); return inventory.revision end
  local definition = {
    id = 'stubconn', name = 'Stub connector', transport = 'stdio',
    program = tostring(host.getenv('WA_FED_NODE_PROGRAM')),
    args = { tostring(host.getenv('WA_FED_STUB')), '--log', tostring(host.getenv('WA_FED_STUB_LOG')) },
    timeout_seconds = 30,
    -- ONE READ TOOL, on purpose: a read tool is what takes the persistent read-session path
    -- (lua/core/mcp_session.lua), which is the path this test exists for.
    tools = { echo = 'read' },
  }
  local put = mcp.control({ action = 'put', expected_revision = revision(), definition = definition }, ctx)
  if not put.ok then print(json.encode({ step = 'put', answer = put })); return end
  local probe = mcp.control({ action = 'probe', id = 'stubconn', expected_revision = revision() }, ctx)
  if not probe.ok then print(json.encode({ step = 'probe', answer = probe })); return end
  local enable = mcp.control({ action = 'enable', id = 'stubconn', expected_revision = revision() }, ctx)
  if not enable.ok then print(json.encode({ step = 'enable', answer = enable })); return end
  -- A SECOND CONNECTOR, THE SAME TOOL DECLARED A WRITE (24/11): a write tool takes the one-shot client path
  -- (lua/core/mcp.lua, `mcp-client.mjs`), not the read-session pool, and it names its own owner on the start
  -- and the await - so the same federated failure had a second door, and only a row that drives both can say
  -- it is shut. Same stub program, different registry id, so the two paths cannot be confused.
  local write = { id = 'stubwrite', name = 'Stub write connector', transport = 'stdio',
    program = tostring(host.getenv('WA_FED_NODE_PROGRAM')),
    args = { tostring(host.getenv('WA_FED_STUB')), '--log', tostring(host.getenv('WA_FED_STUB_LOG')) },
    timeout_seconds = 30, tools = { echo = 'write' } }
  local wrote = mcp.control({ action = 'put', expected_revision = revision(), definition = write }, ctx)
  if not wrote.ok then print(json.encode({ step = 'put_write', answer = wrote })); return end
  local probed = mcp.control({ action = 'probe', id = 'stubwrite', expected_revision = revision() }, ctx)
  if not probed.ok then print(json.encode({ step = 'probe_write', answer = probed })); return end
  local on = mcp.control({ action = 'enable', id = 'stubwrite', expected_revision = revision() }, ctx)
  if not on.ok then print(json.encode({ step = 'enable_write', answer = on })); return end
  -- A THIRD CONNECTOR WHOSE SERVER WILL NEVER BECOME READY (Fable, 25/11): the registry is filled while the
  -- program still speaks MCP (so the probe passes and the operator's own route enables it), and the row then
  -- overwrites that program with one that never answers. A timeout of 2 s keeps the case short; the ready wait
  -- is what has to be exercised, not the tool call.
  local mute = { id = 'stubmute', name = 'Stub mute connector', transport = 'stdio',
    program = tostring(host.getenv('WA_FED_NODE_PROGRAM')),
    args = { tostring(host.getenv('WA_FED_MUTE_STUB')), '--log', tostring(host.getenv('WA_FED_STUB_LOG')) },
    timeout_seconds = 2, tools = { echo = 'read' } }
  local put_mute = mcp.control({ action = 'put', expected_revision = revision(), definition = mute }, ctx)
  if not put_mute.ok then print(json.encode({ step = 'put_mute', answer = put_mute })); return end
  local probe_mute = mcp.control({ action = 'probe', id = 'stubmute', expected_revision = revision() }, ctx)
  if not probe_mute.ok then print(json.encode({ step = 'probe_mute', answer = probe_mute })); return end
  local on_mute = mcp.control({ action = 'enable', id = 'stubmute', expected_revision = revision() }, ctx)
  if not on_mute.ok then print(json.encode({ step = 'enable_mute', answer = on_mute })); return end
  print(json.encode({ step = 'done', tool = mcp.namespace('stubconn', 'echo'),
    write_tool = mcp.namespace('stubwrite', 'echo'), mute_tool = mcp.namespace('stubmute', 'echo') }))
elseif action == 'local' then
  -- THE CONTROL. Same node, same connector, same binary, same Lua: the only thing absent is the relay
  -- lane, which is the runtime owner a relayed call imposes on the thread. Without it the read session
  -- is started and observed by the name its own caller chose, and it answers.
  local answer = dofile('lua/core/mcp.lua').call(tool, { value = { same_node = 1 } },
    { role = 'master', user_id = 'federated-read-test' })
  print(json.encode({ control = answer }))
elseif action == 'call' then
  -- The real federation entry point: exactly what peer_<node>__<tool> runs on the caller's side.
  local answer = dofile('lua/core/nodes.lua').remote_call(tostring(host.getenv('WA_FED_PEER')), 'federation',
    { action = 'call', name = tool, args = { value = { federated = 1 } } })
  print(json.encode({ call = answer }))
elseif action == 'write' then
  -- The same call for a tool the registry declares a WRITE: mcp.lua starts it with the one-shot client and
  -- accounts for it under its own owner name, which is the second door the relay lane rewrote.
  local answer = dofile('lua/core/nodes.lua').remote_call(tostring(host.getenv('WA_FED_PEER')), 'federation',
    { action = 'call', name = tool, args = { value = { federated_write = 1 } } })
  print(json.encode({ call = answer }))
elseif action == 'through_federation' then
  -- The MODEL'S OWN ROUTE, not the capability directly: federation.call is what `peer_<node>__<tool>` runs,
  -- and it is where a peer that cannot serve is named in words the reader can act on.
  local federation = dofile('lua/core/federation.lua')
  -- The catalogue this route resolves through is a CACHE (ten minutes). A fresh scratch home has none, so the
  -- row asks for it the way a master's first turn does, and only then calls.
  pcall(federation.refresh)
  -- `federation.call` takes the LOCAL name a model would call (`peer_<node>__<tool>`), not the peer's own
  -- tool name: it resolves the name through the catalogue this node holds, which is the whole point of the
  -- spelling. The row knows the peer's node_id, so it looks the local name up the same way the catalogue
  -- builds it (federation.local_name) - never by guessing the hash.
  local cache = federation.catalog and federation.catalog() or {}
  local local_name
  for _, peer in pairs(cache.peers or {}) do
    if tostring(peer.node_id) == tostring(host.getenv('WA_FED_PEER')) then
      for _, entry in ipairs(peer.tools or {}) do
        if entry.name == tool then local_name = federation.local_name(peer.name, entry.name) end
      end
    end
  end
  if not local_name then print(json.encode({ call = { error = 'local_name_unresolved', tool = tool } })); return end
  local answer = federation.call(local_name, { value = { through = 'federation' } })
  print(json.encode({ call = answer, local_name = local_name }))
elseif action == 'foreign' then
  -- (a) THE NEGATIVE HALF: an owner that did not start this operation asks for it, and must be refused by
  -- name. This is the operation the relay lane started, read from the peer's own process with somebody
  -- else's relay id - the one way to show the fix did not widen who may observe what.
  local status = json.decode(host.operation('status', json.encode({
    id = tostring(host.getenv('WA_FED_ID') or ''), owner = tostring(host.getenv('WA_FED_OWNER') or '') })))
  print(json.encode({ status = status }))
else
  print(json.encode({ error = 'unknown_action', action = action }))
end
