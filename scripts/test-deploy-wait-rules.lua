-- AN UNKNOWN FROM THE RELAY IS NOT A VERDICT (26/11, openclaw).
--
-- A release round called openclaw 'unknown after 186s: node_no_answer' and printed checks it had skipped. That
-- node had accepted the request, was downloading on a slow link, missed status reads inside the relay's
-- deadline, then finished and came up on node-6b6afc72f188. The rule is named on land so this row drives it:
-- five read-backs, 30 s apart, stopping at the first ANSWER, and the node own record decides before `unknown`.
local land = dofile('lua/core/land.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function eq(got, want, label) ok(tostring(got) == tostring(want), label .. ' (got ' .. tostring(got) .. ')') end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 90) .. ')') end

local SHA = '6b6afc72f188a1a5724c16f1453cd5d956dd2e2'
local slept = {}
land.sleep = function(seconds) slept[#slept + 1] = seconds end
local function reset() slept = {} end
local function reader(list)
  local n = 0
  return function() n = n + 1; local v = list[n] or list[#list]; if type(v) == 'function' then return v() end; return v end, function() return n end
end

eq(land.DEPLOY_FINAL_READS, 5, 'five read-backs')
eq(land.DEPLOY_FINAL_INTERVAL, 30, 'thirty seconds apart')

-- 1. a read that did not arrive does not end it, and the wait is finite
reset()
local r1, count1 = reader({ { state = 'unknown' } })
local settled, answered = land.deploy_last_chance({ node = 'openclaw' }, SHA, r1)
eq(settled, false, 'all reads unknown: the row is not settled')
eq(answered, nil, 'and nothing answered')
eq(count1(), 5, 'exactly five reads were taken')
eq(#slept, 4, 'with four waits between them')
eq(slept[1], 30, 'of 30 s each')

-- 2. the first answer that is a verdict ends the reads; the rest are not taken
reset()
local r2, count2 = reader({ { state = 'unknown' }, { state = 'failed', installed_commit = '' } })
local settled2, answered2 = land.deploy_last_chance({ node = 'openclaw' }, SHA, r2)
eq(settled2, false, 'a failed answer does not settle it as installed')
eq(answered2, 'failed', 'it is returned as the answer')
eq(count2(), 2, 'and the reads stopped there, not at five')
eq(#slept, 1, 'after one wait')

-- 3. an install that finished inside the read-backs settles the row
reset()
local r3, count3 = reader({ { state = 'unknown' }, { state = 'unknown' }, { state = 'installed', installed_commit = SHA } })
local row3 = { node = 'openclaw' }
local settled3 = land.deploy_last_chance(row3, SHA, r3)
eq(settled3, true, 'a record naming the commit settles the row')
eq(row3.state, 'installed', 'as installed')
eq(row3.installed_commit, SHA, 'with the commit it read')
has(row3.detail, 'read 3', 'and says which read found it')
eq(count3(), 3, 'three reads, not five')

-- 4. a record naming ANOTHER commit is a verdict, not a wait: never installed for someone else bytes
reset()
local r4 = reader({ { state = 'installed', installed_commit = 'a1857d15887cc8f7f3c07419f6af2639e852a8d5' } })
local row4 = { node = 'openclaw' }
eq(land.deploy_last_chance(row4, SHA, r4), true, 'it settles the row')
eq(row4.state, 'installed_mismatch', 'as installed_mismatch')
has(row4.detail, 'a1857d15', 'naming the commit it found')
has(row4.detail, SHA, 'and the one this round asked for')

-- 5. a read that raises is a read that did not arrive; an empty commit never matches
reset()
local raised = 0
local r5 = function() raised = raised + 1; if raised == 1 then error('the relay died') end; return { state = 'unknown', installed_commit = '' } end
eq(land.deploy_last_chance({ node = 'openclaw' }, SHA, r5), false, 'a raising read is survived')
eq(raised, 5, 'and the five read-backs still happen')
eq(land.deploy_last_chance({ node = 'openclaw' }, '', reader({ { state = 'installed', installed_commit = '' } })), false, 'an empty sha is never matched')

-- 6. the loop uses the rules, not a copy of them
local src = host.read_file('lua/core/land.lua') or ''
has(src, 'return M.deploy_settles(state)', 'the wave loop calls deploy_settles')
has(src, 'local settled, answered = M.deploy_last_chance(row, sha, read)', 'the deadline path calls deploy_last_chance with a read function')
has(src, 'read-backs', 'and its unknown detail names the read-backs')

if failed > 0 then print(string.format('deploy wait rules FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('deploy wait rules ok (%d checks)', checks))
return 0
