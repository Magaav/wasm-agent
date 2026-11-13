-- harness-evaluator replay: the isolation, proved where it can be observed.
--
-- Why this test exists. "A replay cannot touch anything real" is a claim, and a claim about a sandbox is
-- worth exactly what its weakest check is worth. So this row proves the parts separately, from inside the
-- processes that would do the damage:
--
--   * the child of a replay runs in a `mktemp -d` scratch home of its own, with its own ledger, and the
--     row's own ledger and home are unchanged by it (counted, not assumed);
--   * the frozen task's prompt is what the child was given, and the run's metrics are read back from the
--     child's own ledger through the dump the engine writes and the candidate binary runs;
--   * the sink is installed as a real `PreToolUse` hook in the child's config, and a connector read
--     dispatched through the child's own `tools.dispatch` comes back `hook_denied` with the answer that
--     was recorded with the task - the tool never reaches a live account;
--   * the PATH guards refuse `git push` (and ssh/scp/rsync/gh) by name, with the attempt recorded;
--   * a replay refuses a binary path that is not absolute, and the scratch never lands inside the node's
--     home.
--
-- What it does NOT prove, and says so: no model is called here, so this row measures the harness (boot,
-- prompt, ledger, hooks), not an answer. A run with no provider records exactly that.
local json = dofile('lua/vendor/json.lua')
local core = dofile('lua/core/harness_evaluator.lua')
local replay = dofile('lua/core/harness_evaluator_replay.lua')

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('HARNESS EVALUATOR REPLAY CHECK FAILED: ' .. label) end
end
local function read(path) return host.read_file(path) end

local home = host.getenv('WASM_AGENT_HOME') or ''
check(home ~= '', 'the row runs with a scratch home')
local bin = host.getenv('FAST_BIN') or ''
check(bin ~= '' and bin:sub(1, 1) == '/', 'the row has the binary under test (' .. bin .. ')')

-- ---------------------------------------------------------------- a task to replay
dofile('lua/core/memory.lua').setup()
local function exec(sql, params) return json.decode(host.sql_exec(sql, json.encode(params or {}))) end
local sid = 'replay-fixture-0001'
local PROMPT = 'Print the replay marker and stop.'
exec('INSERT INTO sessions(id,route_id,objective,started_at,user_id,node_id,mode,title) VALUES(?,?,?,?,?,?,?,?)',
  { sid, '', 'fixture', 1000.0, 'master', 'fixture-node', 'default', 'replay fixture' })
exec('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,tokens,ms,ok,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
  { sid .. '-1', sid, 1, 'user', PROMPT, '[]', '', '', 0, 0, 1, '[]', 1001.0 })
exec('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,tokens,ms,ok,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
  { sid .. '-2', sid, 2, 'assistant', '', json.encode({ { id = 'c1', type = 'function',
      ['function'] = { name = 'whatsapp_read', arguments = json.encode({ chat = 'fixture-chat' }) } } }), '', '', 0, 0, 1, '[]', 1002.0 })
exec('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,tokens,ms,ok,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
  { sid .. '-3', sid, 3, 'tool', 'MESSAGE 1: the recording says hello from the fixture', '[]', 'c1', 'whatsapp_read', 0, 0, 1, '[]', 1003.0 })
exec('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,tokens,ms,ok,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
  { sid .. '-4', sid, 4, 'assistant', 'Printed the marker.', '[]', '', '', 0, 0, 1, '[]', 1004.0 })
exec('INSERT INTO harness_events(id,session_id,run_id,span_id,kind,phase,at,payload) VALUES(?,?,?,?,?,?,?,?)',
  { 'rev-1', sid, 'run-1', 'span-1', 'model_call', 'end', 1002.0,
    json.encode({ model = 'fixture-model', provider = 'fixture-provider',
      normalized = { known = true, input = 500, output = 50, cacheRead = 0, cacheWrite = 0, prompt = 500 } }) })

local ws = home .. '/replay-ws'
check(host.write_file(ws .. '/README.md', 'the frozen workspace\n'), 'the fixture workspace exists')
local task = core.capture(sid, { id = 'replay-fixture', category = 'evaluator', check = 'cmd:true', dir = ws })
check(task ~= nil, 'the fixture task is frozen')

-- ---------------------------------------------------------------- the isolation helpers
check(replay.inside('/a/b/c', '/a/b'), 'a child path is recognised inside its parent')
check(not replay.inside('/a/bc', '/a/b'), 'a sibling with the parent as a prefix is not inside it')
check(replay.inside('/a/b', '/a/b'), 'a path equal to the home counts as inside, so a scratch there is refused')
check(not replay.inside('/x', home), 'a path outside the home is outside')

local refused_record, refused_why = replay.run(task, { bin = 'wa' })
check(refused_record == nil and tostring(refused_why):find('absolute', 1, true) ~= nil,
  'a bare binary name is refused (it would resolve against the replay’s own PATH)')
local no_bin, no_bin_why = replay.run(task, {})
check(no_bin == nil and tostring(no_bin_why):find('--bin', 1, true) ~= nil, 'a replay without --bin is refused')

-- ---------------------------------------------------------------- a real run
-- What a run may add is its own record under the evaluator directory; anything else appearing beside it
-- would mean the child wrote into this node.
local function state_names()
  local names = {}
  for _, entry in ipairs(core.entries(home .. '/.wasm-agent')) do
    if entry.name ~= 'evaluator' then names[#names + 1] = entry.name end
  end
  table.sort(names)
  return table.concat(names, ',')
end
local before = state_names()
local own_before = (json.decode(host.sql_query('SELECT COUNT(*) AS n FROM messages', '[]')) or {})[1]
local record, run_why = replay.run(task, { bin = bin, timeout = 120 })
check(record ~= nil, 'the frozen task replays: ' .. tostring(run_why))
check(record.id == 'replay-fixture-001' and record.task_id == 'replay-fixture', 'the run is numbered per task')
check(record.isolation and record.isolation.scratch ~= nil, 'the run names its scratch root')
check(not replay.inside(record.isolation.scratch, home), 'the scratch root is not inside this node’s home')
check(record.isolation.marker == '.wasm-agent-eval-scratch', 'the scratch root carries the engine marker')
check(record.isolation.model_route:find('none', 1, true) ~= nil, 'without --model the child gets no provider')
check(record.command:find('env %-i') ~= nil, 'the child is started with env -i and an allowlist')
check(record.command:find('WASM_AGENT_CODEMODE=.native.') ~= nil,
  'code mode is on in the replay, and the command says so (a nested dispatch is a hook boundary now)')
check(record.kept_scratch == false, 'a scratch root is removed after the run')
check(#core.entries(record.isolation.scratch) == 0, 'and it is gone from the filesystem')
check(record.outcome.state == 'pass', 'the task’s own check decides success (' .. tostring(record.outcome.state) .. ')')

-- The child ran the frozen prompt, in its own ledger.
local ledger_text = read(core.runs_dir() .. '/' .. record.id .. '/ledger.json')
check(ledger_text ~= nil, 'the run keeps the child’s ledger as evidence')
local ledger = json.decode(ledger_text)
local saw_prompt, child_session = false, nil
for _, row in ipairs(ledger.messages or {}) do
  if row.role == 'user' and tostring(row.content):find('Print the replay marker', 1, true) ~= nil then
    saw_prompt = true
    child_session = row.session_id
  end
end
check(saw_prompt, 'the child was given the frozen prompt, not a copy of this session')
check(child_session ~= nil and child_session ~= sid, 'the child ran in its own session')
check(record.metrics.rounds == 0, 'no model was reachable, so there are no rounds to count')
check((record.outcome.detail or ''):find('no model was reachable', 1, true) ~= nil,
  'the run says out loud that it measured the harness, not an answer')

-- This row's own ledger and home are untouched by the child.
local own_after = (json.decode(host.sql_query('SELECT COUNT(*) AS n FROM messages', '[]')) or {})[1]
check(tonumber(own_after.n) == tonumber(own_before.n), 'the replay added no message to this node’s ledger')
check(tonumber((json.decode(host.sql_query('SELECT COUNT(*) AS n FROM sessions WHERE id=?',
  json.encode({ child_session }))) or {})[1].n) == 0,
  'the child’s session exists in its own ledger, not in this node’s')

-- ---------------------------------------------------------------- a kept scratch, inspected
local kept = replay.run(task, { bin = bin, timeout = 120, keep_scratch = true })
check(kept ~= nil and kept.kept_scratch == true, 'a run can keep its scratch root for inspection')
local scratch = kept.isolation.scratch
check(read(scratch .. '/.wasm-agent-eval-scratch') ~= nil, 'the marker file is there')
check(read(scratch .. '/home/.wasm-agent/hooks.json') ~= nil, 'the replay hook is installed as the child’s own config')
local hooks = json.decode(read(scratch .. '/home/.wasm-agent/hooks.json'))
local matchers = {}
for _, entry in ipairs(hooks.hooks.PreToolUse or {}) do matchers[#matchers + 1] = entry.matcher end
local pattern_text = table.concat(matchers, ' ')
check(pattern_text:find('^whatsapp_', 1, true) ~= nil, 'connector tools are hooked')
check(pattern_text:find('^tool_call$', 1, true) ~= nil,
  'the one-tool dispatch is hooked too (a nested call is where an effect would otherwise slip past)')
check(pattern_text:find('^email_', 1, true) ~= nil and pattern_text:find('^web_', 1, true) ~= nil,
  'network and mail tools are hooked')

-- The decision for a recorded connector read carries the answer the original session got.
local decision = json.decode(read(scratch .. '/decisions/whatsapp_read.json') or '')
check(decision ~= nil and decision.decision == 'block', 'a connector read is a block decision')
check(decision.additionalContext:find('hello from the fixture', 1, true) ~= nil,
  'and the block carries the recorded answer as context, which is what the model sees')

-- A dispatched connector call inside the child's own environment is denied, and the sink records it.
local probe = scratch .. '/probe.lua'
host.write_file(probe, [[
local json = dofile('lua/vendor/json.lua')
local tools = dofile('lua/core/tools.lua')
local r = tools.dispatch(nil, 'whatsapp_read', { chat = 'fixture-chat' }, 'master', { cwd = '/' })
print(json.encode({ error = r.error, denied_by = r.denied_by, note = r.note, context = r.hook_context }))
]])
local probe_cmd = 'env -i PATH=' .. core.shquote(scratch .. '/bin:/usr/local/bin:/usr/bin:/bin')
  .. ' HOME=' .. core.shquote(scratch .. '/home')
  .. ' WASM_AGENT_HOME=' .. core.shquote(scratch .. '/home')
  .. ' WASM_AGENT_DB=' .. core.shquote(scratch .. '/home/.wasm-agent/memory.db')
  .. ' WA_EVAL_SINK_DIR=' .. core.shquote(scratch .. '/sink')
  .. ' WA_EVAL_DECISIONS=' .. core.shquote(scratch .. '/decisions')
  .. ' WASM_AGENT_CODEMODE=native'
  .. ' WA_SCRIPT=' .. core.shquote(probe) .. ' timeout 120 ' .. core.shquote(bin)
  .. ' --db ' .. core.shquote(scratch .. '/home/.wasm-agent/memory.db')
local probed = core.exec(probe_cmd, scratch, 180)
local answer = nil
for line in tostring(probed.stdout or ''):gmatch('[^\n]+') do
  local ok, value = pcall(json.decode, line)
  if ok and type(value) == 'table' and (value.error or value.denied_by) then answer = value end
end
check(answer ~= nil, 'the child can dispatch a tool inside its own ledger: ' .. tostring(probed.stderr):sub(-200))
check(answer.error == 'hook_denied' and answer.denied_by == 'eval-sink',
  'a connector read is refused by the replay sink (' .. tostring(answer.error) .. ')')
check(tostring(answer.note or ''):find('recorded with the task', 1, true) ~= nil,
  'and the refusal says the answer comes from the recording')
local served = read(scratch .. '/sink/served.log') or ''
check(served:find('whatsapp_read', 1, true) ~= nil, 'the sink records which decision it served')
check(#core.entries(scratch .. '/sink') > 0, 'the sink keeps the event as evidence')

-- ---------------------------------------------------------------- nested effects reach the sink
-- The reason code mode used to be forced off here: a tool call inside a script did not cross the hook
-- boundary, so a replay could perform an effect and report none. With the boundary fixed, a script's
-- call reaches the sink under its OWN name - the whole point of the row above.
local nested_probe = scratch .. '/probe-nested.lua'
host.write_file(nested_probe, [[
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local tools = dofile('lua/core/tools.lua')
local sid = memory.start_session('', 'replay nested sink probe', { user_id = 'master' })
local code = 'let out; try { const r = await tools.remote({node: "fixture-peer-nested", capability: "read", '
  .. 'args: {path: "/etc/hostname"}}); out = "REACHED:" + JSON.stringify(r).slice(0, 200); } '
  .. 'catch (e) { out = "REFUSED:" + String((e && e.message) || e); } text(out);'
local r = tools.dispatch(memory, 'codemode', { code = code }, 'master',
  { session_id = sid, user_id = 'master', role = 'master', cwd = '/' })
local shown = type(r.items) == 'table' and type(r.items[1]) == 'table' and tostring(r.items[1].text or '') or ''
print(json.encode({ ok = r.ok, error = r.error, shown = shown }))
]])
local nested_cmd = 'env -i PATH=' .. core.shquote(scratch .. '/bin:/usr/local/bin:/usr/bin:/bin')
  .. ' HOME=' .. core.shquote(scratch .. '/home')
  .. ' WASM_AGENT_HOME=' .. core.shquote(scratch .. '/home')
  .. ' WASM_AGENT_DB=' .. core.shquote(scratch .. '/home/.wasm-agent/memory.db')
  .. ' WA_EVAL_SINK_DIR=' .. core.shquote(scratch .. '/sink')
  .. ' WA_EVAL_DECISIONS=' .. core.shquote(scratch .. '/decisions')
  .. ' WASM_AGENT_CODEMODE=native'
  .. ' WA_SCRIPT=' .. core.shquote(nested_probe) .. ' timeout 180 ' .. core.shquote(bin)
  .. ' --db ' .. core.shquote(scratch .. '/home/.wasm-agent/memory.db')
local nested_run = core.exec(nested_cmd, scratch, 240)
local nested = nil
for line in tostring(nested_run.stdout or ''):gmatch('[^\n]+') do
  local decoded_ok, value = pcall(json.decode, line)
  if decoded_ok and type(value) == 'table' and (value.shown ~= nil or value.error ~= nil) then nested = value end
end
check(nested ~= nil, 'the child can run a code-mode script in the replay: ' .. tostring(nested_run.stderr):sub(-200))
check(tostring(nested.error or '') ~= 'codemode_not_enabled',
  'code mode really is available in the replay (a binary without the embedded code-mode assets cannot prove this)')
check(nested.ok == true and tostring(nested.shown):find('^REFUSED:', 1) ~= nil,
  'an effect tool called inside a script is refused, and the script catches it (' .. tostring(nested.shown):sub(1, 160) .. ')')
check(tostring(nested.shown):find('hook_denied', 1, true) ~= nil
  and tostring(nested.shown):find('eval-sink', 1, true) ~= nil,
  'the refusal inside the script is the replay sink\'s own (' .. tostring(nested.shown):sub(1, 300) .. ')')
-- The evidence, from what the sink RECORDED: an event naming the inner tool and the script's own
-- arguments, which an outer name could not carry.
local nested_events, nested_payloads = 0, 0
for _, entry in ipairs(core.entries(scratch .. '/sink')) do
  if entry.kind == 'file' and tostring(entry.name):match('^event%-') then
    local body = read(scratch .. '/sink/' .. entry.name) or ''
    if body:find('fixture-peer-nested', 1, true) ~= nil then
      nested_events = nested_events + 1
      if body:find('"tool_name":"remote"', 1, true) ~= nil
        or body:find('"tool_name": "remote"', 1, true) ~= nil then nested_payloads = nested_payloads + 1 end
    end
  end
end
check(nested_events > 0, 'the sink saw the call made inside the script (its arguments are in the event)')
check(nested_payloads > 0, 'and it saw it under the inner tool\'s own name, not the outer one')

-- The PATH guards refuse a remote command and record it.
local pushed = core.exec('env -i PATH=' .. core.shquote(scratch .. '/bin:/usr/local/bin:/usr/bin:/bin')
  .. ' WA_EVAL_SINK_DIR=' .. core.shquote(scratch .. '/sink')
  .. ' sh -c ' .. core.shquote('git push origin main'), scratch, 120)
check(tonumber(pushed.code) == 97, 'git push is refused by the replay guard (exit ' .. tostring(pushed.code) .. ')')
check((read(scratch .. '/sink/commands.log') or ''):find('push', 1, true) ~= nil,
  'and the refused command is recorded as would-have-done')
for _, name in ipairs({ 'ssh', 'scp', 'rsync', 'gh' }) do
  local ran = core.exec('env -i PATH=' .. core.shquote(scratch .. '/bin:/usr/local/bin:/usr/bin:/bin')
    .. ' WA_EVAL_SINK_DIR=' .. core.shquote(scratch .. '/sink') .. ' ' .. name .. ' --version', scratch, 60)
  check(tonumber(ran.code) == 97, name .. ' is refused by the replay guard')
end
local local_git = core.exec('env -i PATH=' .. core.shquote(scratch .. '/bin:/usr/local/bin:/usr/bin:/bin') .. ' git --version', scratch .. '/ws', 60)
check(tonumber(local_git.code) == 0, 'local git still works through the guard (only a remote verb is refused)')
check(tostring(local_git.stdout or ''):find('git version', 1, true) ~= nil, 'and it is the real git answering')

print(string.format('harness evaluator replay ok (%d checks)', checks))
