-- harness-evaluator: capture, metrics, the catalogue, verdicts and the report.
--
-- Why this test exists. The engine's whole job is to turn a session the operator actually ran into a
-- replayable record *without* leaking it, so the two things worth proving are the ones a happy path
-- hides: that every number comes from the ledger's own rows (nothing invented), and that no code path
-- prints or stores a frozen task anywhere except the node's evaluator directory.
--
-- What it proves, in order:
--   * a capture freezes the prompt, the category, the check, the policy/mode, the tools the session
--     really called, the model the run used and the recorded connector answers - and refuses a session
--     that does not exist, a turn that does not exist, and a check it cannot parse;
--   * the metrics are the ledger's: rounds from `harness_events` model_call spans, tokens from their
--     normalized usage, tool errors, effects attempted (by name), files changed (by write/edit calls),
--     the final answer and the wall time from the transcript;
--   * `wa eval` is dispatched from the one place `wa` dispatches commands, by running the binary;
--   * a verdict is refused on a task whose success its own check decides, and accepted on a human one;
--   * `report` and `compare` print ids, categories and counts, never the prompt or the answer.
local json = dofile('lua/vendor/json.lua')
local core = dofile('lua/core/harness_evaluator.lua')
local cli = dofile('lua/core/harness_evaluator_cli.lua')

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('HARNESS EVALUATOR CHECK FAILED: ' .. label) end
end

local home = host.getenv('WASM_AGENT_HOME') or ''
check(home ~= '', 'the row runs with a scratch home')
-- The state directory is the node's own (`<config>/evaluator`), which in this row is the scratch home:
-- that is the default this test wants to exercise, not an override.
local state = core.state_dir()
check(state:find('/.wasm-agent/evaluator', 1, true) ~= nil, 'the default state directory is <config>/evaluator (' .. state .. ')')
check(state:sub(1, #home) == home, 'the default state directory is inside this row home, never a repository')
check(host.write_file(state .. '/.keep', ''), 'the state directory can be made')

-- ---------------------------------------------------------------- the session under test
local sid = 'eval-fixture-0001'
local SECRET = 'the operator asked for the ledger fix'
local function exec(sql, params) return json.decode(host.sql_exec(sql, json.encode(params or {}))) end
dofile('lua/core/memory.lua').setup()
exec('INSERT INTO sessions(id,route_id,objective,started_at,ended_at,user_id,node_id,mode,title) VALUES(?,?,?,?,?,?,?,?,?)',
  { sid, '', 'fixture', 1000.0, 1300.0, 'master', 'fixture-node', 'default', 'fixture task' })
local function msg(seq, role, content, extra)
  local row = extra or {}
  exec('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,tokens,ms,ok,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
    { sid .. '-' .. seq, sid, seq, role, content, row.tool_calls or '[]', row.tool_call_id or '', row.tool_name or '',
      row.tokens or 0, row.ms or 0, row.ok == nil and 1 or row.ok, '[]', 1000.0 + seq * 10 })
end
local function call(id, name, args)
  return json.encode({ { id = id, type = 'function', ['function'] = { name = name, arguments = json.encode(args) } } })
end
msg(1, 'user', SECRET .. ' and say what you changed.')
msg(2, 'assistant', '', { tool_calls = call('call-1', 'read', { path = 'README.md' }) })
msg(3, 'tool', 'the readme', { tool_call_id = 'call-1', tool_name = 'read' })
msg(4, 'assistant', '', { tool_calls = call('call-2', 'write', { path = 'ledger.lua' }) })
msg(5, 'tool', '{"ok":true}', { tool_call_id = 'call-2', tool_name = 'write' })
msg(6, 'assistant', '', { tool_calls = call('call-3', 'whatsapp_read', { chat = 'fixture-chat' }) })
msg(7, 'tool', 'MESSAGE 1: the recorded answer', { tool_call_id = 'call-3', tool_name = 'whatsapp_read' })
msg(8, 'tool', 'refused: no such chat', { tool_call_id = 'call-4', tool_name = 'email_read', ok = 0 })
msg(9, 'assistant', 'Fixed the ledger and read the chat.')
-- A second user message is a second task: `--turn 2` has to find it and stop the first task's window.
msg(10, 'user', 'now do the second thing')
msg(11, 'assistant', 'second answer')
local events = {
  { 'tool', { name = 'read', ok = true, ms = 12 } },
  { 'model_call', { model = 'fixture-model', provider = 'fixture-provider',
      normalized = { known = true, input = 900, output = 120, cacheRead = 4000, cacheWrite = 0, prompt = 4900 } } },
  { 'tool', { name = 'write', ok = true, ms = 20 } },
  { 'tool', { name = 'whatsapp_read', ok = true, ms = 40 } },
  { 'tool', { name = 'email_read', ok = false, ms = 40 } },
  { 'model_call', { model = 'fixture-model', provider = 'fixture-provider',
      normalized = { known = true, input = 800, output = 200, cacheRead = 5000, cacheWrite = 0, prompt = 5800 } } },
  { 'tool', { name = 'whatsapp_send', ok = false, ms = 5 } },
}
for index, row in ipairs(events) do
  exec('INSERT INTO harness_events(id,session_id,run_id,span_id,kind,phase,at,payload) VALUES(?,?,?,?,?,?,?,?)',
    { 'ev-' .. index, sid, 'run-1', 'span-' .. index, row[1], 'end', 1010.0 + index, json.encode(row[2]) })
end

-- ---------------------------------------------------------------- capture
-- A small workspace of its own: the capture must not depend on (or touch) the repository this row runs in.
local ws = home .. '/fixture-ws'
check(host.write_file(ws .. '/ledger.lua', 'return {}\n'), 'the fixture workspace exists')
local task, problem = core.capture(sid, { category = 'code-fix', check = 'human', id = 'fixture-fix', dir = ws })
check(task ~= nil, 'the session can be frozen: ' .. tostring(problem))
check(task.id == 'fixture-fix', 'the task carries the id it was given')
check(task.category == 'code-fix' and task.check.kind == 'human', 'category and check are the ones asked for')
check(task.prompt:find(SECRET, 1, true) ~= nil, 'the prompt is the operator task, not the session title')
check(task.source.session_id == sid and task.source.turn == 1, 'the record names its source session and turn')
check(task.model.recorded == 'fixture-model' and task.model.provider == 'fixture-provider',
  'the model and provider come from the run telemetry')
check(task.catalogue.known == false, 'the historical catalogue is declared unknown, not invented')
local used = table.concat(task.catalogue.tools_used, ',')
check(used:find('whatsapp_read', 1, true) and used:find('write', 1, true), 'the tools the session called are recorded')
local recorded = {}
for _, item in ipairs(task.connectors.recordings) do recorded[#recorded + 1] = item end
check(#recorded == 2, 'both connector reads in the window are captured (' .. #recorded .. ')')
local whatsapp
for _, item in ipairs(recorded) do if item.tool == 'whatsapp_read' then whatsapp = item end end
check(whatsapp ~= nil and whatsapp.response:find('recorded answer', 1, true) ~= nil and whatsapp.ok == true,
  'a connector read is captured with the answer it gave')
for _, item in ipairs(recorded) do
  if item.tool == 'email_read' then check(item.ok == false and item.response:find('refused', 1, true) ~= nil,
    'a failed connector read is kept as a recorded failure') end
end
check(task.connectors.live_access == false, 'the recording is not live access')

local outcome = task.outcome
check(outcome.rounds == 2, 'rounds are the model_calls of the task window (' .. tostring(outcome.rounds) .. ')')
check(outcome.tokens_in == 1700 and outcome.tokens_out == 320, 'tokens are the normalized usage sums')
check(outcome.cache_read == 9000, 'cache read is summed, not inferred')
check(outcome.tool_calls == 5, 'tool calls are the tool spans (' .. tostring(outcome.tool_calls) .. ')')
check(outcome.tool_errors == 2, 'each failed tool span is one error, and the transcript row is not counted again')
check(outcome.effects_attempted == 1, 'an effect-named tool call is counted once as an effect attempted')
check(outcome.tool_source == 'telemetry spans', 'tool numbers come from one source, named')
check(outcome.wall_ms ~= nil and outcome.wall_ms > 0, 'the wall time is the transcript window')
check(table.concat(outcome.files_changed, ','):find('ledger.lua', 1, true) ~= nil,
  'the files changed come from the write/edit calls')
check((outcome.final_answer or ''):find('Fixed the ledger', 1, true) ~= nil, 'the final answer is the task answer')
check(not (outcome.final_answer or ''):find('second answer', 1, true), 'the next turn is not part of this task')

-- The record lives under the state directory, in the node's home - never in a repository.
check(host.read_file(state .. '/tasks/fixture-fix/task.json') ~= nil, 'the frozen task is under the state directory')
check(host.read_file(core.state_dir() .. '/tasks.json') ~= nil, 'the catalogue is written beside it')
local rows = core.tasks()
check(#rows == 1 and rows[1].id == 'fixture-fix', 'the catalogue lists the task once')
check(rows[1].check.kind == 'human', 'the catalogue carries the check kind, not the prompt')
check(not json.encode(rows[1]):find(SECRET, 1, true), 'the catalogue row carries no prompt text')

-- `--turn 2` freezes the second task and its own window.
local second = core.capture(sid, { turn = 2, category = 'other', id = 'fixture-second', dir = ws })
check(second ~= nil, 'a later turn can be frozen on its own')
check(second.prompt:find('second thing', 1, true) ~= nil, 'the second turn is the second user message')
check((second.outcome.final_answer or ''):find('second answer', 1, true) ~= nil, 'its window is its own answer')

-- Refusals are refusals: a word and no record.
local missing, why = core.capture('no-such-session', {})
check(missing == nil and type(why) == 'string' and why:find('no such session', 1, true) ~= nil, 'an unknown session is refused')
local bad_turn, turn_why = core.capture(sid, { turn = 9 })
check(bad_turn == nil and turn_why:find('turn 9', 1, true) ~= nil, 'a turn that does not exist is refused by number')
local bad_check, check_why = core.capture(sid, { check = 'whenever' })
check(bad_check == nil and type(check_why) == 'string', 'a check it cannot parse is refused')

-- ---------------------------------------------------------------- the operator's door
check(cli.run({ 'eval', 'help' }) == 0, 'help is a request')
check(cli.run({ 'eval', 'frobnicate' }) == 2, 'an unknown verb is refused')
check(cli.run({ 'eval', 'run', 'fixture-fix' }) == 2, 'a replay without --bin is refused')
check(cli.run({ 'eval', 'capture' }) == 2, 'a capture without a session is refused')
check(cli.run({ 'eval', 'verdict', 'fixture-fix' }) == 2, 'a verdict needs a state')

-- ---------------------------------------------------------------- runs, verdicts, findings
local function fake_run(id, task_id, metrics)
  core.record_run({
    schema = core.SCHEMA, id = id, task_id = task_id, category = 'code-fix', check = { kind = 'human' },
    started_at = 2000, wall_ms = metrics.wall_ms, metrics = metrics, outcome = { state = 'needs-human' },
  })
end
fake_run('fixture-fix-001', 'fixture-fix', { rounds = 3, tokens_in = 1000, tokens_out = 200, cache_hit = 0.5,
  tool_calls = 5, tool_errors = 1, refusals = 0, effects_attempted = 0, wall_ms = 4200 })
fake_run('fixture-fix-002', 'fixture-fix', { rounds = 2, tokens_in = 800, tokens_out = 150, cache_hit = 0.6,
  tool_calls = 4, tool_errors = 0, refusals = 1, effects_attempted = 0, wall_ms = 3100 })
fake_run('fixture-second-001', 'fixture-second', { rounds = 1, tokens_in = 100, tokens_out = 20,
  tool_calls = 0, tool_errors = 0, refusals = 0, effects_attempted = 0, wall_ms = 900 })

local verdict_ok, verdict_why = core.verdict('fixture-fix-001', 'pass', 'done by hand')
check(verdict_ok ~= nil, 'a human check takes a hand verdict: ' .. tostring(verdict_why))
check(core.run_record('fixture-fix-001').verdict.state == 'pass', 'the verdict is stored on the run')
local refused_verdict, refused_why = core.verdict('fixture-fix-001', 'maybe', '')
check(refused_verdict == nil and type(refused_why) == 'string', 'a state that is not pass/fail is refused')

local machine = core.capture(sid, { check = 'cmd:true', id = 'fixture-machine', dir = ws })
check(machine ~= nil, 'a machine-checked task can be frozen')
core.record_run({ schema = core.SCHEMA, id = 'fixture-machine-001', task_id = 'fixture-machine',
  category = 'other', check = { kind = 'command', command = 'true' }, started_at = 2100,
  metrics = { rounds = 1 }, outcome = { state = 'pass' } })
local no_verdict, no_verdict_why = core.verdict('fixture-machine-001', 'fail', 'it passed')
check(no_verdict == nil and no_verdict_why:find('own check', 1, true) ~= nil,
  'a hand verdict cannot contradict a machine check')

local reviewer = core.reviewer_record('fixture-fix-001', { findings = 4, accepted = 3, misses = 1, cost = '0.42' })
check(reviewer ~= nil and reviewer.reviewer.findings == 4 and reviewer.reviewer.cost == '0.42',
  'the reviewer shape is stored (storage only, no reviewer runs here)')

local lines = core.report({ all = true })
local text = table.concat(lines, '\n')
check(text:find('fixture-fix', 1, true) ~= nil, 'the report names the task by id')
check(text:find('needs%-human') ~= nil or text:find('pass', 1, true) ~= nil, 'the report carries success')
check(not text:find(SECRET, 1, true), 'the report never prints the prompt')
check(not text:find('Fixed the ledger', 1, true), 'the report never prints the answer')
check(text:find('reviewer', 1, true) ~= nil, 'the report shows the reviewer shape when one is recorded')
local latest = core.report({})
check(#table.concat(latest, '\n') > 0, 'the default report prints the latest run per task')

local compared, compare_why = core.compare('fixture-fix-001', 'fixture-fix-002')
check(compared ~= nil, 'two runs can be compared: ' .. tostring(compare_why))
check(compared:find('rounds', 1, true) ~= nil and compared:find('success', 1, true) ~= nil, 'the comparison has metrics')
local no_compare, no_compare_why = core.compare('fixture-fix-001', 'nope')
check(no_compare == nil and tostring(no_compare_why):find('no such run', 1, true) ~= nil, 'an unknown run is refused')

-- The verb exists in the binary an operator runs, not only as a module.
local bin = host.getenv('FAST_BIN')
if bin and bin ~= '' then
  local ran = json.decode(host.exec('"' .. bin .. '" eval help', '', 120))
  check((tonumber(ran.code) or 1) == 0, 'the binary dispatches `wa eval help`')
  check((ran.stdout or ''):find('wa eval', 1, true) ~= nil, 'the help text is the engine’s own')
  local listed = json.decode(host.exec('"' .. bin .. '" eval list', '', 120))
  check((listed.stdout or ''):find('fixture-fix', 1, true) ~= nil, 'the binary lists the frozen task')
else
  print('SKIP harness evaluator binary dispatch: no FAST_BIN in this row')
end

print(string.format('harness evaluator ok (%d checks)', checks))
