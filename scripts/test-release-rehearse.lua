-- `wa release rehearse` (26/11, Fable): the gates a cut depends on, run against the fleet, changing nothing.
--
-- A green rehearsal is a condition of the next cut, so the row has to pin the two ways it can lie: claiming a
-- fleet it could not read (a refused read is not a green node) and treating the aggregate alone as the verdict
-- (a FAIL, or a cutting canary proven nowhere, stays red).
local rehearse = dofile('lua/core/release_rehearse.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 110) .. ')') end

local RING = { { node = 'this node', mode = 'local' }, { node = 'openclaw', mode = 'release' } }
local function results(spec)
  local list = {}
  for _, one in ipairs(spec) do list[#list + 1] = one end
  return list
end
local function run(spec)
  return rehearse.rehearse({
    ring = RING,
    read = spec.read or function() return { ok = true, state = 'installed', installed_commit = '6b6afc72f188' } end,
    canaries = spec.canaries or function() return { features = spec.peer_results or {} } end,
    local_results = { results = spec.local_results or {} },
  })
end

-- 1. the report shape is the cut canary step's
local all_good = run({
  local_results = results({ { feature = 'release-update', ok = true, stage = 'identity' }, { feature = 'mail', ok = true, stage = 'answered' } }),
  peer_results = results({ { feature = 'release-update', ok = true, stage = 'identity' }, { feature = 'mail', ok = true, stage = 'answered' } }),
})
ok(all_good.ok == true, 'a fleet that answers and passes is GREEN')
has(all_good.lines[1], 'rehearse: 2 node(s) read; canaries', 'the first line counts the nodes read')
has(table.concat(all_good.lines, '\n'), 'this node', 'the report names this node')
has(table.concat(all_good.lines, '\n'), 'openclaw', 'and every peer it read')
has(all_good.lines[#all_good.lines], 'GREEN', 'the last line is the verdict')

-- 2. a refused read is not a green node
local refused = run({ read = function() return { ok = false, error = 'node_no_answer' } end })
ok(refused.ok == false, 'a peer whose record could not be read makes the rehearsal RED')
has(table.concat(refused.red, '\n'), 'node_no_answer', 'named with the refusal')
has(refused.lines[#refused.lines], 'RED', 'and the verdict says so')

-- 3. a peer whose canaries did not arrive is red too
local silent = run({ canaries = function() return nil end })
ok(silent.ok == false, 'a peer that did not answer its canaries is RED')
has(table.concat(silent.red, '\n'), 'its canaries did not arrive', 'and the reason is named')

-- 4. a FAIL stays red, and a cutting proven nowhere stays red
local failing = run({ peer_results = results({ { feature = 'whatsapp-receive', ok = false, stage = 'whatsapp_component_absent' } }) })
ok(failing.ok == false, 'a FAIL on a peer is RED')
has(table.concat(failing.red, '\n'), 'whatsapp_component_absent', 'named')
local cutting = run({ local_results = results({ { feature = 'release-update', not_proven = true, stage = 'no_data' } }) })
ok(cutting.ok == false, 'release-update proven nowhere is RED (the cut cannot prove itself)')
has(table.concat(cutting.cutting, '\n'), 'release-update', 'and it is the cutting list')

-- 5. a not_proven everywhere is LISTED and the rehearsal is still green (r5)
local listed = run({ local_results = results({ { feature = 'release-update', ok = true, stage = 'identity' }, { feature = 'mail', not_proven = true, stage = 'no_data' } }),
  peer_results = results({ { feature = 'release-update', ok = true, stage = 'identity' }, { feature = 'mail', not_proven = true, stage = 'no_data' } }) })
ok(listed.ok == true, 'mail not proven on every node is listed, and the fleet is still GREEN')
has(table.concat(listed.lines, '\n'), 'NOT PROVEN ON ANY NODE', 'under the same heading as the cut step')
has(table.concat(listed.listed, '\n'), 'mail', 'with the feature named')

-- 6. read-only by construction: nothing in the module asks the fleet to change
local src = host.read_file('lua/core/release_rehearse.lua') or ''
ok(src:find('remote_update.request', 1, true) == nil, 'the rehearsal never calls remote_update.request')
ok(src:find('git push', 1, true) == nil, 'and never pushes')
ok(src:find('M.deploy', 1, true) == nil, 'and never deploys')
has(src, 'remote_update.status', 'it reads records with status only')

-- 6b. THE VERB IS REACHABLE (26/11: my first cut put it in a second `command == release` branch, which never
--     runs - the release verb already exists and answers verify/trust-key). The verb must live INSIDE that
--     branch, before the trust door.
local init = host.read_file('lua/core/init.lua') or ''
local i_branch = init:find('if command == ' .. string.char(34) .. 'release' .. string.char(34) .. ' then', 1, true)
local i_rehearse = init:find(string.char(34) .. 'rehearse' .. string.char(34), i_branch or 1, true)
local i_trust = init:find('local trust = dofile(', i_branch or 1, true)
ok(i_branch ~= nil, 'the release branch exists')
ok(i_rehearse ~= nil, 'and dispatches the rehearse verb')
ok(i_rehearse ~= nil and i_trust ~= nil and i_rehearse < i_trust, 'before the trust door, so the verb is reachable')
ok(init:find('elseif command == ' .. string.char(34) .. 'release' .. string.char(34), 1, true) == nil, 'and there is no second release branch')
-- 7. the exit code a caller sees
ok(type(rehearse.run) == 'function', 'M.run is the CLI door')

if failed > 0 then print(string.format('release rehearse FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('release rehearse ok (%d checks)', checks))
return 0
