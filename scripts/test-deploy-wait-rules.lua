-- AN UNKNOWN FROM THE RELAY IS NOT A VERDICT (26/11, openclaw).
--
-- A release round called openclaw 'unknown after 186s: node_no_answer' and printed a long list of checks it had
-- skipped. That node had accepted the request, was downloading on a slow link, missed ONE status read inside the
-- relay's deadline, then finished and came up on node-6b6afc72f188. The two rules of the wait are named
-- functions on land (deploy_settles, deploy_last_chance) so this row can drive the rule itself.
local land = dofile('lua/core/land.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function eq(got, want, label) ok(tostring(got) == tostring(want), label .. ' (got ' .. tostring(got) .. ')') end

ok(type(land.deploy_settles) == 'function', 'deploy_settles is a named rule')
ok(type(land.deploy_last_chance) == 'function', 'deploy_last_chance is a named rule')

-- 1. the wait does NOT end on a read that did not arrive
eq(land.deploy_settles('unknown'), false, 'unknown keeps the wait open')
eq(land.deploy_settles('not_known_yet'), false, 'not_known_yet keeps it open too')
eq(land.deploy_settles(nil), false, 'a missing state keeps it open (an empty value is not a verdict)')
eq(land.deploy_settles('installed'), true, 'installed ends it')
eq(land.deploy_settles('failed'), true, 'failed ends it')
eq(land.deploy_settles('silent'), true, 'silent ends it')
eq(land.deploy_settles('refused'), true, 'refused ends it')

-- 2. the last read before `unknown` is written settles a finished install
local SHA = '6b6afc72f188a1a5724c16f1453cd5d956dd2e2'
local row = { node = 'openclaw', state = 'unknown' }
ok(land.deploy_last_chance(row, SHA, { installed_commit = SHA }), 'a record naming the commit settles the row')
eq(row.state, 'installed', 'and the row says installed')
eq(row.installed_commit, SHA, 'with the commit it read back')
ok(tostring(row.detail):find('after the wait', 1, true) ~= nil, 'and the detail says it was read back after the wait')
local other = { node = 'openclaw', state = 'unknown' }
eq(land.deploy_last_chance(other, SHA, { installed_commit = 'a1857d15887cc8f7f3c07419f6af2639e852a8d5' }), false, 'a record naming ANOTHER commit does not settle it')
eq(other.state, 'unknown', 'that row stays unknown - never installed for someone else bytes')
local none = { node = 'openclaw', state = 'unknown' }
eq(land.deploy_last_chance(none, SHA, {}), false, 'no installed_commit at all does not settle it')
eq(land.deploy_last_chance(none, '', { installed_commit = SHA }), false, 'and an empty sha is never matched')

-- 3. the closure uses the rules, not a copy of them
local src = host.read_file(land.__path or 'lua/core/land.lua') or ''
ok(tostring(src):find('return M.deploy_settles(state)', 1, true) ~= nil, 'the wave loop calls deploy_settles')
ok(tostring(src):find('if M.deploy_last_chance(row, sha, last) then', 1, true) ~= nil, 'the deadline path calls deploy_last_chance')

if failed > 0 then print(string.format('deploy wait rules FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('deploy wait rules ok (%d checks)', checks))
return 0
