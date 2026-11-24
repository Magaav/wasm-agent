-- One node's half of scripts/test-federated-connector-read.mjs: one JSON answer on stdout, no model,
-- no network of its own beyond the call it is asked to make. It runs as a \`wa --script\` process in a
-- scratch home, so it acts as that node's own tooling - the same route \`/mcp <id> probe\` takes.
--
--   WA_FED_ACTION=setup   the stub connector, through mcp.control put -> probe -> enable
--   WA_FED_ACTION=local   the same tool on this node, with no relay lane under it (the control)
--   WA_FED_ACTION=call    the federated call a master makes: nodes.remote_call(peer, "federation", ...)
local json = dofile('lua/vendor/json.lua')
local action = tostring(host.getenv('WA_FED_ACTION') or '')
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
  print(json.encode({ step = 'done', tool = mcp.namespace('stubconn', 'echo') }))
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
else
  print(json.encode({ error = 'unknown_action', action = action }))
end
