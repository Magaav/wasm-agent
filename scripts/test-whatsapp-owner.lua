-- The WhatsApp account is served by exactly one node. A node that runs no wa-whatsapp component
-- answers `whatsapp_component_absent` naming the owner, and the question is asked there instead of
-- waiting on a queue nobody consumes (2026-11-09: a caller spent 14 minutes discovering that the
-- "component has not answered yet" answer was really "this node has no component").
local tools = dofile('lua/core/tools.lua')
local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

-- The host prefixes the refusal with the capability's tool name (`whatsapp_search_<code>`), so the
-- matcher must find the code as a suffix, not compare it whole.
local absent = { error = 'whatsapp_search_whatsapp_component_absent', owner = 'openclaw', component = 'wa-whatsapp', effect = 'none' }

-- 1. the question is asked of the owner, unchanged, and the answer says who served it
local asked = nil
local served = tools.whatsapp_forward(absent, 'whatsapp_search', { q = 'fernanda' }, function(node, name, args)
  asked = { node = node, name = name, args = args }
  return { ok = true, hits = {} }
end)
ok(asked ~= nil, 'the owner was asked')
ok(asked.node == 'openclaw', 'the owner named in the answer is the one asked')
ok(asked.name == 'whatsapp_search' and asked.args.q == 'fernanda', 'the same question travelled')
ok(served.served_by == 'openclaw', 'the answer names the node that served it')

-- 2. an unreachable owner is a refusal that names it, never a queue
local refused = tools.whatsapp_forward(absent, 'whatsapp_search', {}, function() error('no route') end)
ok(refused.error == 'whatsapp_owner_unreachable', 'an unreachable owner is a named refusal')
ok(refused.owner == 'openclaw' and refused.effect == 'none', 'the refusal carries the owner and no effect')

-- 3. a refusal from the owner is passed through unchanged, never stamped as served
local passthrough = tools.whatsapp_forward(absent, 'whatsapp_read', {}, function()
  return { error = 'remote_refused', effect = 'none' }
end)
ok(passthrough.error == 'remote_refused', 'the owner refusal is not rewritten')
ok(passthrough.served_by == nil, 'a refusal is not stamped as served')

print('whatsapp owner routing: ' .. checks .. ' checks passed')
