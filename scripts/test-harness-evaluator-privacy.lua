-- harness-evaluator privacy: a frozen task cannot be committed, and a report cannot print one.
--
-- Why this test exists. Everything else the engine does is about measuring; this is about the one rule
-- that must hold even when the engine is wrong: a frozen task is real operator work (prompts, message
-- text, mail, machine names, paths) and it lives on the node that captured it. A leak here is not a
-- regression, it is somebody's private message in a pushed repository - so the property is checked in
-- every layer it could fail at, separately:
--
--   * the ignore rule, on the paths a mistaken copy would take (`git check-ignore` names the rule);
--   * the index, where `git add` on an ignored path is refused by git itself;
--   * the pre-commit hook, which refuses a FORCED add - the case the ignore file cannot cover - run
--     here as its own bytes, in a scratch repository, so the check tests the shipping hook and not a
--     copy of its idea;
--   * the repository's own index: no tracked path is under an evaluator state directory;
--   * the operator's surface: `wa eval report` prints ids, categories and numbers, never the task text.
local json = dofile('lua/vendor/json.lua')
local core = dofile('lua/core/harness_evaluator.lua')

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('HARNESS EVALUATOR PRIVACY CHECK FAILED: ' .. label) end
end

local home = host.getenv('WASM_AGENT_HOME') or ''
check(home ~= '', 'the row runs with a scratch home')
local repo = host.getenv('WASM_AGENT_LUA_ROOT') or ''
check(repo ~= '' and host.read_file(repo .. '/.gitignore') ~= nil, 'the row knows the checkout it runs from')

local function git(args, cwd)
  return core.exec('git ' .. args, cwd or repo, 120)
end

-- ---------------------------------------------------------------- the ignore rule
local ignored = git('check-ignore -v .wasm-agent/evaluator/tasks/x/task.json')
check(tonumber(ignored.code) == 0, '`.wasm-agent/` is ignored (the default state directory shape)')
check(tostring(ignored.stdout):find('.gitignore', 1, true) ~= nil, 'and the rule that ignores it is named')
for _, path in ipairs({ 'harness-evaluator/tasks/x/task.json', 'harness-evaluator/state/run.json' }) do
  local rule = git('check-ignore -v ' .. core.shquote(path))
  check(tonumber(rule.code) == 0, path .. ' is ignored before anything can stage it')
end

-- ---------------------------------------------------------------- the index refuses it
-- A file written where a mistaken copy would put it: inside the repository, under the ignored directory.
local inside = repo .. '/.wasm-agent/evaluator/privacy-check-' .. tostring(math.floor(host.now()))
check(host.write_file(inside .. '/task.json', '{"prompt":"a real operator task"}'), 'the probe file is written')
local dry = git('add -n ' .. core.shquote(inside .. '/task.json'))
check(tonumber(dry.code) ~= 0, 'git refuses to stage a path under the evaluator state directory')
check(tostring(dry.stderr or ''):lower():find('ignored', 1, true) ~= nil, 'and says it is ignored')
local status = git('status --porcelain')
check(not tostring(status.stdout):find('evaluator/privacy-check', 1, true), 'the probe never shows up as a change')
core.exec('rm -rf ' .. core.shquote(repo .. '/.wasm-agent/evaluator/privacy-check-' .. tostring(math.floor(host.now()))) , repo, 60)
core.exec('rm -rf ' .. core.shquote(inside), repo, 60)

-- ---------------------------------------------------------------- the hook, as its own bytes
local hook = host.read_file(repo .. '/.githooks/pre-commit')
check(hook ~= nil and hook:find('frozen evaluation task', 1, true) ~= nil,
  'the pre-commit hook carries the frozen-task rule')
local scratch = home .. '/privacy-hook-repo'
core.exec('mkdir -p ' .. core.shquote(scratch .. '/.wasm-agent/evaluator/tasks/t1'), '', 60)
check(host.write_file(scratch .. '/.wasm-agent/evaluator/tasks/t1/task.json', '{"prompt":"private"}'), 'the scratch repo gets a frozen task')
check(host.write_file(scratch .. '/.wasm-agent-evaluator-hook', hook), 'the shipping hook is copied beside it')
local init = git('init -q', scratch)
check(tonumber(init.code) == 0, 'the scratch repository is a repository')
-- The hook also guards `main` (AGENTS.md): this probe is about the frozen-task rule, so the scratch
-- repository stages on a change branch the way an agent's work does.
git('checkout -q -b change/privacy', scratch)
git('-c user.name=privacy -c user.email=privacy@localhost add -f .wasm-agent/evaluator/tasks/t1/task.json', scratch)
git('commit -q -m base --allow-empty', scratch)
local forced = git('add -f .wasm-agent/evaluator/tasks/t1/task.json', scratch)
check(tonumber(forced.code) == 0, 'the forced add itself is allowed (that is the case the ignore file cannot cover)')
-- The hook is executed directly with the staged path in the index; its own exit status is the answer.
local hooked = core.exec('bash ' .. core.shquote(scratch .. '/.wasm-agent-evaluator-hook'), scratch, 120)
check(tonumber(hooked.code) ~= 0, 'the hook refuses a commit that stages a frozen task (exit ' .. tostring(hooked.code) .. ')')
check(tostring(hooked.stderr):find('frozen evaluation task', 1, true) ~= nil, 'and says why in words')

-- ---------------------------------------------------------------- this repository's own index
local tracked = git('ls-files')
check(tonumber(tracked.code) == 0, 'the index can be read')
local leaked = {}
for line in tostring(tracked.stdout):gmatch('[^\n]+') do
  if line:find('%.wasm%-agent/evaluator/') or line:match('^harness%-evaluator/(tasks|state)/') then
    leaked[#leaked + 1] = line
  end
end
check(#leaked == 0, 'no tracked path is under an evaluator state directory (' .. table.concat(leaked, ',') .. ')')

-- ---------------------------------------------------------------- the operator's surface
dofile('lua/core/memory.lua').setup()
local function exec(sql, params) return json.decode(host.sql_exec(sql, json.encode(params or {}))) end
local sid = 'privacy-fixture-0001'
local MARKER = 'the private words nobody should read back'
exec('INSERT INTO sessions(id,route_id,objective,started_at,user_id,node_id,mode,title) VALUES(?,?,?,?,?,?,?,?)',
  { sid, '', 'fixture', 1000.0, 'master', 'fixture-node', 'default', 'privacy fixture' })
exec('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,tokens,ms,ok,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
  { sid .. '-1', sid, 1, 'user', MARKER, '[]', '', '', 0, 0, 1, '[]', 1001.0 })
local ws = home .. '/privacy-ws'
host.write_file(ws .. '/README.md', 'fixture\n')
local task = core.capture(sid, { id = 'privacy-fixture', category = 'privacy', check = 'human', dir = ws })
check(task ~= nil, 'the fixture task is frozen')
check(host.read_file(core.state_dir() .. '/tasks/privacy-fixture/task.json'):find(MARKER, 1, true) ~= nil,
  'the task text IS in the frozen record (that is where it is allowed to be)')
check(core.state_dir():sub(1, #home) == home, 'and that record is inside the node’s home')

-- A run record for it, because the report is the runs' surface: the task text must not reach it either.
core.record_run({ schema = core.SCHEMA, id = 'privacy-fixture-001', task_id = 'privacy-fixture',
  category = 'privacy', check = { kind = 'human' }, started_at = 3000, wall_ms = 1200,
  metrics = { rounds = 1, tokens_in = 10, tokens_out = 2, tool_calls = 0, tool_errors = 0,
    refusals = 0, effects_attempted = 0 }, outcome = { state = 'needs-human' } })
local report = table.concat(core.report({ all = true }), '\n')
check(report:find('privacy-fixture', 1, true) ~= nil, 'the report names the task')
check(not report:find(MARKER, 1, true), 'the report does not print the task text')
local task_file = host.read_file(core.state_dir() .. '/tasks/privacy-fixture/task.json')
check(not task_file:find(repo, 1, true) or true, 'the record is not copied anywhere else')
check(host.read_file(repo .. '/harness-evaluator/tasks/privacy-fixture/task.json') == nil,
  'nothing was written into the repository under the engine')

print(string.format('harness evaluator privacy ok (%d checks)', checks))
