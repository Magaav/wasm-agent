-- whatsapp-finds-owner: a WhatsApp call on a node that runs no component reaches the node that does.
--
-- MEASURED, 22/11, session daf51bb3 on avell (build e1d457f0 / binary 124cf45b): a turn of 83 s and nine
-- model rounds, four of them spent finding where WhatsApp runs. `mcp_whatsapp_contacts` and
-- `mcp_whatsapp_read` answered 202 `whatsapp_*_slow` with `state:"queued"` and the note "no node in this
-- fleet says it runs wa-whatsapp" - while `tools.nodes()` listed openclaw with `mcp_whatsapp_read` and one
-- `tools.remote` to openclaw answered in 1.04 s.
--
-- THE CAUSE THIS ROW PINS: `federation.refresh` stored each peer's `tools` and threw its `connectors`
-- away, so `whatsapp.owner` - which reads exactly `peer.connectors[*].whatsapp_account` - could never
-- find the holder. Every earlier routing test passed a `ctx.owner_catalog` straight in and so never
-- touched the refresh. This row drives the REAL path: refresh -> the node's own cache -> owner -> the
-- tool the model calls. It fails on the code before the fix at the first cache check.
--
-- Hermetic: no rendezvous, no relay, no model. The fleet is a stub (as `scripts/test-federation.lua` does
-- it) and the only state touched is the scratch WASM_AGENT_HOME the row is given, which it refuses to run
-- without.
local json = dofile('lua/vendor/json.lua')

local function refuse(why) print('REFUSED test-whatsapp-finds-owner: ' .. why); os.exit(2) end
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-whatsapp-finds-owner')
if why_home then refuse(why_home) end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

-- The clock is the test's: routing is a decision, and a decision must not need a sleep.
local at = 1700000000
host.now = function() return at end

-- ---- the fleet: one peer holds the account, one does not, one cannot be asked ---------------------
-- The shape is the one `federation.serve` answers: `tools` (exported connectors) and `connectors` (this
-- node's own /mcp view, where the WhatsApp row says whether the account is here).
local function whatsapp_row(holds, tools)
  return { id = 'whatsapp', name = 'WhatsApp', type = 'built-in', enabled = true, state = 'enabled',
    whatsapp_account = holds, tools = tools or {} }
end
local function tools_of(names)
  local out = {}
  for _, name in ipairs(names or {}) do out[#out + 1] = { name = name, description = name, effect = 'read' } end
  return out
end
local SURFACE = { 'mcp_whatsapp_backfill', 'mcp_whatsapp_contacts', 'mcp_whatsapp_read', 'mcp_whatsapp_send' }

local fleet = {}
local function fleet_with(peers) fleet = peers end
local remote_answers = {}
local asked = {}

local nodes = dofile('lua/core/nodes.lua')
local real_nodes = nodes
-- The roster and the relay, as `federation.refresh` asks for them. `live_capabilities = false` is the
-- call the refresh makes (it must never start a probe): a list with options is the roster only.
local roster = {}
local list_opts = nil
-- Anything this stub does not name falls through to the real module (a caller like
-- `server.wa_peer_dispatch` reads `nodes.node_name` and `author_of`, and those are not part of what this
-- row replaces). `remote_call` IS replaced: a test may never reach the real relay.
local function stub_nodes(extra)
  local stub = setmetatable({
    list = function(opts) list_opts = opts; return roster end,
    remote_call = function(node_id, capability, args)
      asked[#asked + 1] = { node_id = node_id, capability = capability, action = args and args.action }
      local answer = remote_answers[node_id]
      if type(answer) == 'function' then return answer(capability, args) end
      return answer
    end,
    known_capabilities = function() return extra and extra.known or {} end,
    self_name = function() return 'avell' end,
    node_name = function() return 'avell' end,
  }, { __index = real_nodes })
  return stub
end

local current_nodes = stub_nodes(nil)
local federation = dofile('lua/core/federation.lua')
local real_dofile = dofile
-- Two doors are replaced, and only these two: `nodes` (the fleet and the relay) and `federation` (so the
-- module `whatsapp` dofiles is the same table this row just refreshed, not a second copy of it).
dofile = function(path)
  if path == 'lua/core/nodes.lua' then return current_nodes end
  if path == 'lua/core/federation.lua' then return federation end
  return real_dofile(path)
end
-- The tool layer is loaded ONCE, after the doors: `tools.lua` holds its own `nodes.lua` at load time.
local tools = dofile('lua/core/tools.lua')
local whatsapp = dofile('lua/core/whatsapp.lua')

-- This node runs no wa-whatsapp component, and its own capability - which is what a queued job comes
-- from - counts every call it gets: zero is the proof that nothing was written here.
local local_calls = 0
local function absent_capability()
  local_calls = local_calls + 1
  return json.encode({ ok = false, error = 'whatsapp_component_absent', component = 'wa-whatsapp',
    state = 'stopped', effect = 'none' })
end
local function slow_capability()
  local_calls = local_calls + 1
  return json.encode({ error = 'whatsapp_read_slow', id = 42, state = 'queued', retry = true,
    detail = 'the wa-whatsapp component has not answered yet; the same call reads the same job' })
end
for _, name in ipairs({ 'whatsapp_contacts', 'whatsapp_search', 'whatsapp_read', 'whatsapp_reactions',
  'whatsapp_media', 'whatsapp_download', 'whatsapp_backfill', 'whatsapp_send_status', 'whatsapp_send' }) do
  host[name] = absent_capability
end
host.service = function() return json.encode({ { name = 'wa-whatsapp', state = 'stopped' } }) end
local real_getenv = host.getenv
host.getenv = function(name)
  if name == 'WASM_AGENT_WHATSAPP_OWNER' then return '' end
  return real_getenv(name)
end

-- The relay door a routed call travels through, and the answer the account node would give.
local served = {}
local function relay(answer)
  return function(node, capability, args)
    served[#served + 1] = { node = node, capability = capability, args = args }
    if type(answer) == 'function' then return answer(node, capability, args) end
    return answer
  end
end
local ctx = { user_id = 'master', role = 'master', codemode_nested = true }
local function ctx_with(answer)
  local copy = {}
  for key, value in pairs(ctx) do copy[key] = value end
  copy.remote_call = relay(answer)
  return copy
end

-- The fleet is refreshed the way a turn refreshes it: no peer answer is invented here, and every one of
-- them carries the connectors the real `federation.serve` sends.
local function refresh(source)
  roster = source.roster or {}
  remote_answers = source.answers or {}
  current_nodes = stub_nodes(source)
  asked = {}
  return federation.refresh()
end

-- ---- 1. the cache keeps the connectors: the cause ------------------------------------------------
local cache = refresh({
  roster = {
    { node_id = 'self', name = 'avell', local_node = true, online = true },
    { node_id = 'peer-1', name = 'openclaw', online = true },
    { node_id = 'peer-2', name = 'work', online = true },
  },
  answers = {
    ['peer-1'] = { ok = true, tools = tools_of({ 'email_read' }),
      connectors = { whatsapp_row(true, tools_of(SURFACE)) } },
    ['peer-2'] = { ok = true, tools = {}, connectors = { whatsapp_row(false, tools_of(SURFACE)) } },
  },
})
ok(list_opts and list_opts.live_capabilities == false,
  'the refresh asks for the roster only, never a live probe: ' .. json.encode(list_opts))
ok(type(cache.peers['peer-1'].connectors) == 'table',
  'the refresh KEEPS the peer connectors (the field whatsapp.owner reads): ' .. json.encode(cache.peers['peer-1']))
ok(cache.peers['peer-2'].connectors and cache.peers['peer-2'].connectors[1].whatsapp_account == false,
  'a peer that runs no component keeps its row too, saying so: ' .. json.encode(cache.peers['peer-2']))

-- The owner lookup reads THAT cache - no injected catalog, the same dofile a real call makes.
ok(whatsapp.owner() == 'openclaw',
  'the one peer whose connector says it holds the account is the owner: ' .. tostring(whatsapp.owner()))
local evidence = whatsapp.owner_evidence()
ok(#evidence.owners == 1 and evidence.owners[1].name == 'openclaw' and #evidence.candidates == 0,
  'and the evidence names it as the only holder, not as a maybe: ' .. json.encode(evidence))

-- ---- 2. a read on this node is answered by the account node, and nothing is queued here ---------
local read_ctx = ctx_with({ ok = true, header = { name = 'Laura' }, messages = { { id = 'm1', text = 'oi' } } })
local_calls, served = 0, {}
local read = tools.dispatch(memory, 'mcp_whatsapp_read', { chat = 'Laura', limit = 3 }, 'master', read_ctx)
ok(local_calls == 0, 'the node without the component never asks its own capability (nothing can be queued): '
  .. json.encode(read))
ok(served[1] and served[1].node == 'openclaw' and served[1].capability == 'mcp_whatsapp_read',
  'the read asked the node that holds the account: ' .. json.encode(served))
ok(read.served_by == 'openclaw' and read.asked_owner == 'openclaw',
  'and the answer says who served it: ' .. json.encode(read))
ok(read.id == nil and read.state == nil and read.retry == nil,
  'no queued local job reaches the model: ' .. json.encode(read))

-- The same for a send: it travels to the account node and runs there (never here), which is the only
-- place its guards and its queue live.
local send_ctx = ctx_with({ ok = true, state = 'done', id = 5, status = 'sent' })
local_calls, served = 0, {}
local sent = tools.dispatch(memory, 'mcp_whatsapp_send', { chat = '5551@s.whatsapp.net', text = 'oi' }, 'master', send_ctx)
ok(local_calls == 0, 'a send on this node is never queued here: ' .. json.encode(sent))
ok(sent.served_by == 'openclaw' and served[1] and served[1].capability == 'mcp_whatsapp_send',
  'the send was asked of the account node: ' .. json.encode(served))

-- ---- 3. a fleet that lists nobody: one refusal, and the sentence is allowed here -----------------
refresh({
  roster = { { node_id = 'self', name = 'avell', local_node = true, online = true },
    { node_id = 'peer-2', name = 'work', online = true } },
  answers = { ['peer-2'] = { ok = true, tools = {}, connectors = { whatsapp_row(false, tools_of(SURFACE)) } } },
})
ok(whatsapp.owner() == nil, 'a peer that says it does not hold the account is not an owner')
local_calls, served = 0, {}
local alone = tools.dispatch(memory, 'mcp_whatsapp_read', { chat = 'Laura' }, 'master', ctx_with({ ok = true }))
ok(alone.ok == false and alone.error == 'whatsapp_component_absent',
  'with nobody holding the account the answer is one refusal: ' .. json.encode(alone))
ok(alone.id == nil and alone.discarded_job == nil and #served == 0,
  'and it queues nothing and forwards nowhere: ' .. json.encode(alone))
ok(local_calls == 1, 'the refusal cost this node one local check, no more: ' .. local_calls)
ok(tostring(alone.note):find('no node in this fleet', 1, true) ~= nil,
  'the sentence is used when the roster really lists nobody: ' .. tostring(alone.note))

-- ---- 4. one owner that does not answer: named, and never the sentence above ---------------------
refresh({
  roster = { { node_id = 'self', name = 'avell', local_node = true, online = true },
    { node_id = 'peer-1', name = 'openclaw', online = true } },
  answers = { ['peer-1'] = { ok = true, tools = {}, connectors = { whatsapp_row(true, tools_of(SURFACE)) } } },
})
local_calls, served = 0, {}
local unreachable = tools.dispatch(memory, 'mcp_whatsapp_read', { chat = 'Laura' }, 'master',
  ctx_with(function() return nil end))
ok(unreachable.error == 'whatsapp_account_unreachable' and unreachable.account_lives_on == 'openclaw',
  'an owner that did not answer is named: ' .. json.encode(unreachable))
ok(local_calls == 0 and unreachable.id == nil,
  'and nothing is queued on this node: ' .. json.encode(unreachable))
ok(tostring(unreachable.note):find('no node in this fleet', 1, true) == nil,
  'the roster DOES list the account node, so that sentence must not appear: ' .. tostring(unreachable.note))
ok(tostring(unreachable.note):find('openclaw', 1, true) ~= nil, 'the note names it: ' .. tostring(unreachable.note))

-- ---- 5. two owners: refuse, name both, and hand over the call to make ---------------------------
refresh({
  roster = { { node_id = 'self', name = 'avell', local_node = true, online = true },
    { node_id = 'peer-1', name = 'openclaw', online = true },
    { node_id = 'peer-3', name = 'work', online = true } },
  answers = {
    ['peer-1'] = { ok = true, tools = {}, connectors = { whatsapp_row(true, tools_of(SURFACE)) } },
    ['peer-3'] = { ok = true, tools = {}, connectors = { whatsapp_row(true, tools_of(SURFACE)) } },
  },
})
ok(whatsapp.owner() == nil, 'two holders are not resolved by picking the first')
local_calls, served = 0, {}
local two = tools.dispatch(memory, 'mcp_whatsapp_read', { chat = 'Laura' }, 'master', ctx_with({ ok = true }))
ok(two.ok == false and two.error == 'whatsapp_account_ambiguous',
  'two owners are one refusal with their own word: ' .. json.encode(two))
ok(local_calls == 0 and #served == 0, 'and nothing is asked: no local job, no guessed hop: ' .. json.encode(two))
ok(type(two.candidates) == 'table' and #two.candidates == 2,
  'both nodes are named: ' .. json.encode(two.candidates))
ok(tostring(two.ask_with):find('tools.remote({node="', 1, true) ~= nil
  and tostring(two.ask_with):find('capability="mcp_whatsapp_read"', 1, true) ~= nil,
  'with the exact call that asks one of them: ' .. tostring(two.ask_with))
ok(tostring(two.note):find('no node in this fleet', 1, true) == nil,
  'and the sentence above is NOT used: ' .. tostring(two.note))

-- ---- 6. a fleet that lists the surface but not the account: forward to the one, name it for two --
-- An older peer's connector row has no `whatsapp_account` field at all, and the roster can still say a
-- node admits `mcp_whatsapp_read`. That is weaker evidence - the node may be asking another one itself -
-- so ONE such node is worth the hop and TWO are a refusal that names both.
local function old_row() return { id = 'whatsapp', name = 'WhatsApp', enabled = true, state = 'enabled',
  tools = tools_of(SURFACE) } end
refresh({
  roster = { { node_id = 'self', name = 'avell', local_node = true, online = true },
    { node_id = 'peer-1', name = 'openclaw', online = true } },
  answers = { ['peer-1'] = { ok = true, tools = {}, connectors = { old_row() } } },
})
ok(whatsapp.owner() == nil, 'a row without the flag says nothing about the account')
local_calls, served = 0, {}
local via_surface = tools.dispatch(memory, 'mcp_whatsapp_contacts', { q = 'Laura' }, 'master',
  ctx_with({ ok = true, count = 1, chat = '5551@s.whatsapp.net' }))
ok(local_calls == 0 and via_surface.served_by == 'openclaw',
  'the one node that lists the surface answers the call: ' .. json.encode(via_surface))

-- ... and the same evidence from the ROSTER (a peer whose known capabilities admit the verb).
refresh({
  roster = { { node_id = 'self', name = 'avell', local_node = true, online = true },
    { node_id = 'peer-1', name = 'openclaw', online = true },
    { node_id = 'peer-3', name = 'work', online = true } },
  answers = { ['peer-1'] = { ok = true, tools = {} },
    ['peer-3'] = { ok = true, tools = {} } },
  known = {
    { node_id = 'peer-1', capabilities = { 'bash', 'mcp_whatsapp_read' }, at = at - 3, age_s = 3 },
    { node_id = 'peer-3', capabilities = { 'bash', 'mcp_whatsapp_read', 'mcp_whatsapp_send' }, at = at - 9, age_s = 9 },
  },
})
local_calls, served = 0, {}
local by_roster = tools.dispatch(memory, 'mcp_whatsapp_read', { chat = 'Laura' }, 'master', ctx_with({ ok = true }))
ok(by_roster.ok == false and by_roster.error == 'whatsapp_component_absent',
  'two nodes can answer, none holds the account: one refusal, not a guess: ' .. json.encode(by_roster))
ok(local_calls == 0 and #served == 0, 'and nothing was asked: ' .. json.encode(by_roster))
ok(type(by_roster.candidates) == 'table' and #by_roster.candidates == 2,
  'both are named: ' .. json.encode(by_roster.candidates))
ok(by_roster.candidates[1].age_s ~= nil and by_roster.candidates[1].age_s >= 3,
  'with how old the roster answer is: ' .. json.encode(by_roster.candidates[1]))
ok(tostring(by_roster.ask_with):find('capability="mcp_whatsapp_read"', 1, true) ~= nil,
  'and the exact call: ' .. tostring(by_roster.ask_with))

-- ---- 7. the last corner: nobody in the fleet holds it, and this node queued a send anyway -------
-- The registry had not caught up (or this process is not the serving node), so the send capability wrote a
-- job on a node where nothing runs `wa-whatsapp`. There is nowhere to route it, so the job is not hidden -
-- but it is not called a sent message either: the answer says the effect is unknown and that nothing here
-- sends it, which is the one fact the model must not have to discover by reading the same id four times.
refresh({
  roster = { { node_id = 'self', name = 'avell', local_node = true, online = true },
    { node_id = 'peer-2', name = 'work', online = true } },
  answers = { ['peer-2'] = { ok = true, tools = {}, connectors = { whatsapp_row(false, tools_of(SURFACE)) } } },
})
host.whatsapp_send = function()
  local_calls = local_calls + 1
  return json.encode({ ok = true, id = 9, state = 'pending', op = 'send' })
end
local_calls, served = 0, {}
local stalled = tools.dispatch(memory, 'mcp_whatsapp_send', { chat = '5551@s.whatsapp.net', text = 'oi' }, 'master',
  ctx_with({ ok = true }))
ok(local_calls == 1 and #served == 0, 'with nobody named the send is asked here and nowhere else: '
  .. json.encode(stalled))
ok(stalled.effect == 'unknown', 'and it is not reported as sent: ' .. json.encode(stalled))
ok(stalled.id == 9, 'the queued job keeps its id: ' .. json.encode(stalled))
ok(tostring(stalled.note):find('nothing here sends that job', 1, true) ~= nil,
  'and the answer says so in one sentence: ' .. tostring(stalled.note))

-- ---- 8. a SEND never hops on weak evidence (review 23/11, MUST 1) ------------------------------
-- Every managed master admits the nine verbs, so "the one peer that lists mcp_whatsapp_*" says nothing
-- about where the account is. A READ may take that hop (section 6); a message may not - it is forwarded
-- only to the node the deploy declared, or the one whose connector says `whatsapp_account = true`, and
-- otherwise it is refused with the candidates and the call to make, before anything is queued here.
refresh({
  roster = { { node_id = 'peer-1', name = 'openclaw', online = true } },
  answers = { ['peer-1'] = { ok = true, tools = {}, connectors = { old_row() } } },
})
ok(whatsapp.owner() == nil, 'a row without the flag is not an owner for a send either')
local_calls, served = 0, {}
local weak_send = tools.dispatch(memory, 'mcp_whatsapp_send', { chat = '5551@s.whatsapp.net', text = 'oi' },
  'master', ctx_with({ ok = true, state = 'done', id = 5 }))
ok(weak_send.ok == false and weak_send.error == 'whatsapp_component_absent',
  'a send is not forwarded on weak evidence: ' .. json.encode(weak_send))
ok(weak_send.effect == 'none' and weak_send.id == nil, 'and it has no effect and no job: ' .. json.encode(weak_send))
ok(#served == 0 and local_calls == 0, 'nothing was asked: no hop, no local queue: ' .. json.encode(served))
ok(type(weak_send.candidates) == 'table' and weak_send.candidates[1]
  and weak_send.candidates[1].name == 'openclaw',
  'the node that can answer is named: ' .. json.encode(weak_send.candidates))
ok(tostring(weak_send.ask_with):find('capability="mcp_whatsapp_send"', 1, true) ~= nil,
  'with the exact call to make: ' .. tostring(weak_send.ask_with))

-- ---- 9. no ping-pong: a call that ARRIVED from a peer is answered or refused here (MUST 2) ------
-- Every managed master admits the nine verbs and each asks its own account node, so two nodes WITHOUT the
-- component are each other's "single peer that lists mcp_whatsapp_*": A forwards to B on that evidence and
-- B would forward back to A on the same evidence, hop after hop, for ever. A call that arrived is therefore
-- strict (no weak evidence) and is never routed back to the node it came from.
--
-- The arrived side is driven through the REAL seam a peer call goes through, `server.wa_peer_dispatch`
-- (lua/core/server.lua, the function that builds `peer_call = true` and `session_id = "peer:<caller>"`),
-- not through a ctx this row invented. B's fleet is A: one weak candidate, exactly the shape that loops.
-- `wa_peer_dispatch` is a GLOBAL in that module (not a field of a returned table), so it is read from the
-- interpreter's globals after the dofile - the same function a verified peer call runs.
real_dofile('lua/core/server.lua')
local peer_dispatch = wa_peer_dispatch
ok(type(peer_dispatch) == 'function', 'the peer seam this row drives exists: ' .. type(peer_dispatch))
local function node_b_fleet()
  refresh({
    roster = { { node_id = 'peer-a', name = 'avell', online = true } },
    answers = { ['peer-a'] = { ok = true, tools = {}, connectors = { old_row() } } },
  })
end
local a_roster = { { node_id = 'peer-1', name = 'openclaw', online = true } }
local a_answers = { ['peer-1'] = { ok = true, tools = {}, connectors = { old_row() } } }
refresh({ roster = a_roster, answers = a_answers })
local_calls, served = 0, {}
local hops, b_forwarded = 0, {}
local function to_b(node, capability, args)
  hops = hops + 1
  -- B's own view of the fleet for the duration of the call: A is its ONE weak candidate.
  local mine_roster, mine_answers = roster, remote_answers
  node_b_fleet()
  local asked_before = #asked
  local ok_call, answer = pcall(peer_dispatch, capability, args,
    { node_id = 'peer-a', role = 'master' }, 'avell')
  for index = asked_before + 1, #asked do b_forwarded[#b_forwarded + 1] = asked[index] end
  roster, remote_answers = mine_roster, mine_answers
  current_nodes = stub_nodes({ roster = roster, answers = remote_answers })
  if not ok_call then return { error = 'b_raised', detail = tostring(answer) } end
  return answer
end
local ping = tools.dispatch(memory, 'mcp_whatsapp_read', { chat = 'Laura' }, 'master', {
  user_id = 'master', role = 'master', codemode_nested = true, remote_call = to_b })
ok(hops == 1, 'the call took exactly ONE hop (A -> B) and no hop back: ' .. hops)
ok(ping.ok == false and ping.error == 'whatsapp_no_owner_on_this_node',
  'B refused it by name instead of forwarding it back: ' .. json.encode(ping))
ok(ping.arrived_from == 'peer-a',
  'and the refusal says which node it arrived from: ' .. tostring(ping.arrived_from))
ok(#b_forwarded == 0,
  'B forwarded nothing: ' .. json.encode({ b_forwarded = b_forwarded }))
ok(local_calls == 0 and ping.id == nil,
  'nothing was queued on either node: ' .. json.encode({ local_calls = local_calls, id = ping.id }))
ok(ping.effect == 'none', 'and no effect was claimed: ' .. tostring(ping.effect))

-- The same refusal, without the peer seam: a call carrying the arrival marker is never forwarded again,
-- whatever the weak evidence says.
refresh({ roster = a_roster, answers = a_answers })
local arrived_ctx = { user_id = 'master', role = 'master', codemode_nested = true,
  peer_call = true, session_id = 'peer:peer-a', remote_call = relay({ ok = true }) }
served = {}
local direct = tools.dispatch(memory, 'mcp_whatsapp_send', { chat = '5551@s.whatsapp.net', text = 'oi' },
  'master', arrived_ctx)
ok(direct.error == 'whatsapp_no_owner_on_this_node' and #served == 0,
  'an arrived SEND is refused here too, never bounced: ' .. json.encode(direct))

dofile = real_dofile
print('whatsapp finds owner ok (' .. checks .. ' checks)')
