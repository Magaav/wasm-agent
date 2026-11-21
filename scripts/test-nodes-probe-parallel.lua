-- Peer probing runs AT ONCE, through supervised processes (item 10 of the node-ops round).
--
--   bash scripts/test-nodes-probe-parallel.sh   (a scratch home, through the node)
--
-- WHAT WAS MEASURED: lua/core/nodes.lua M.list asked each peer's capabilities in a serial loop, so a list
-- of four unreachable peers cost four deadlines before a display drew anything. host.http is one blocking
-- call, so the fix is not a coroutine: it is one supervised child per peer ("wa nodes probe <id>"), ALL
-- started before any is awaited.
--
-- WHAT THIS PROVES, with a stubbed host (nodes.lua reads the global host, so the stub IS the interface):
--   * every child is STARTED before the first await - the fan-out, not the sum;
--   * each peer's answer comes from its own child, matched by node_id;
--   * a child that does not settle inside the deadline is named probe_timeout, never silently [] ;
--   * one child per peer: a list that also asks in-process would pay twice.
-- The stub is deliberate: a test that needed four real unreachable peers would depend on the cluster
-- being broken to prove anything.

local json = dofile('lua/vendor/json.lua')

local function refuse(why) print('REFUSED test-nodes-probe-parallel: ' .. why); os.exit(2) end
-- THE SCRATCH-HOME RULE, FROM ONE PLACE (item 3 of the node-ops round): the four refusals the shell
-- guard makes, against the RIGHT side - WASM_AGENT_HOME is the USER home, and the store hangs off it as
-- <home>/.wasm-agent. This row used to refuse only the store path itself, so WASM_AGENT_HOME=$HOME passed.
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-nodes-probe-parallel')
if why_home then refuse(why_home) end


local real_host = host
local events = {}
local starts = 0

-- The stub is a LAYER, not a replacement: every field it does not name falls through to the real host,
-- so loading the node's modules still has what it needs (measured: a bare table lost host.sha256 and the
-- bootstrap died before a single assertion ran).
host = setmetatable({
  getenv = function(name)
    if name == 'WASM_AGENT_DB' then return '' end
    return real_host.getenv(name)
  end,
  now = function() return 1700000000 end,
  uuid = function() return 'probe-fixture' end,
  read_file = function(path) return real_host.read_file(path) end,
  write_file = function(path, text) return real_host.write_file(path, text) end,
  path_kind = function(path) return real_host.path_kind(path) end,
  runtime_info = function() return json.encode({ binary_path = '/fixture/wa', process_id = 1 }) end,
  operation = function(action, args_json)
    local args = json.decode(args_json) or {}
    if action == 'start' then
      starts = starts + 1
      local node_id = tostring(args.args and args.args[4] or '')
      events[#events + 1] = 'start:' .. node_id
      return json.encode({ operation_id = 'op-' .. starts, node_id = node_id, ok = true })
    elseif action == 'await' then
      events[#events + 1] = 'await:' .. tostring(args.id)
      local id = tostring(args.id or '')
      local index = tonumber(id:match('op%-(%d+)') or '0') or 0
      if index == 3 then return json.encode({ id = id, settled = false, state = 'running' }) end
      return json.encode({ id = id, settled = true, state = 'completed', process_exit_code = 0 })
    elseif action == 'read' then
      local id = tostring(args.id or '')
      local index = tonumber(id:match('op%-(%d+)') or '0') or 0
      local body = index == 1 and json.encode({ capabilities = { 'bash', 'read' }, reason = 'asked' })
        or json.encode({ capabilities = {}, reason = 'remote_unreachable' })
      return json.encode({ content = body })
    elseif action == 'cancel' then
      events[#events + 1] = 'cancel:' .. tostring(args.id)
      return json.encode({ ok = true })
    end
    return json.encode({ error = 'unexpected_action_' .. tostring(action) })
  end,
  node_identity = function() return json.encode({ node_id = 'local-node' }) end,
}, { __index = real_host })

local nodes = dofile('lua/core/nodes.lua')
local ok, out = pcall(function()
  return nodes.list({ probe = true, peers = { { node_id = "peer-a" }, { node_id = "peer-b" }, { node_id = "peer-c" } } })
end)
if not ok then refuse('M.list raised: ' .. tostring(out)) end

-- (1) The fan-out: every start happens before the first await.
local first_await = nil
for index, event in ipairs(events) do
  if event:match('^await:') then first_await = index break end
end
if first_await == nil then refuse('no await was issued, so no child was read back: ' .. json.encode(events)) end
local starts_before = 0
for index = 1, first_await - 1 do if events[index]:match('^start:') then starts_before = starts_before + 1 end end
if starts_before < 3 then
  refuse('only ' .. starts_before .. ' child(ren) started before the first await: the probes ran in series. '
    .. json.encode(events))
end
-- (2) One child per peer, no more.
if starts ~= 3 then refuse('M.list started ' .. starts .. ' children for 3 peers: ' .. json.encode(events)) end
-- (3) The timeout is NAMED, not an empty list that reads as "accepts nothing".
local by_id = {}
for _, peer in ipairs(out) do by_id[peer.node_id] = peer end
local stubborn = by_id['peer-c']
if not stubborn then refuse('the stubborn peer is missing from the list') end
if stubborn.capabilities_reason ~= 'probe_timeout' then
  refuse('the stubborn peer answered ' .. tostring(stubborn.capabilities_reason) .. ', not probe_timeout')
end
-- (4) The answers are matched per node, not to whichever child answered first.
local a = by_id['peer-a']
if not a then refuse('peer-a is missing from the list') end
if type(a.capabilities) ~= 'table' or a.capabilities[1] ~= 'bash' then
  refuse('peer-a did not get its own child answer: ' .. json.encode(a.capabilities))
end
local b = by_id['peer-b']
if not b then refuse('peer-b is missing from the list') end
if b.capabilities_reason ~= 'remote_unreachable' then
  refuse('peer-b answered ' .. tostring(b.capabilities_reason) .. ', not its own remote_unreachable')
end

-- (5) A LOOKUP DOES NOT FAN OUT, AND A PROBE CHILD NEVER PROBES AGAIN (19/11: this module took the
-- whole node down - a 'wa nodes probe <id>' child ran M.probe -> M.find -> M.list with no exclusion,
-- so every child started one child per peer and the tree grew until the machine ran out of memory: 23 GB
-- and 1653 processes from one command). The stub above counts every host.operation start, so both
-- halves are measured here, not argued:
--   * M.find asks the roster and starts ZERO children (it used to start one per peer);
--   * a process that IS a probe child (M.probe sets it) starts ZERO children on a later M.list() - the
--     child's own state, not a table handed in by the test.
starts = 0
events = {}
local found = nodes.find('peer-a')
if starts ~= 0 then
  refuse('M.find started ' .. starts .. ' probe child(ren): that is the recursion that took the node down')
end
nodes.probe('peer-a')
if starts ~= 0 then
  refuse('M.probe started ' .. starts .. ' probe child(ren): a probe child that probes again is a fork tree')
end
if not nodes._in_probe_child then
  refuse('M.probe did not mark the process as a probe child, so the next M.list() fans out again')
end
starts = 0
events = {}
nodes.list({ probe = true, peers = { { node_id = "peer-a" }, { node_id = "peer-b" }, { node_id = "peer-c" } } })
if starts ~= 0 then
  refuse('an M.list() inside a probe child started ' .. starts .. ' children: the recursion is back')
end

print('nodes probe parallel ok: 3 peers started 3 children before the first await, each answer matched by node_id, '
  .. 'and a child that never settles is named probe_timeout instead of answering []')
os.exit(0)
