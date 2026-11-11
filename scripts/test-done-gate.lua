-- The done gate (docs/DONE-GATE.md): a turn ends when the request is done or measurably impossible.
--
-- Model-free: the provider is the same fake HTTP fixture the other loop tests use, scripted per call,
-- so these are real agent runs - real tool dispatch, real shell, real transcript - with no inference
-- and no network. What each case pins, in the operator's words:
--
--   capture        a "do X" request gets its acceptance checks recorded next to the verbatim words,
--                  and a paraphrase of the request is refused;
--   re-entry       a fixture agent that stops at a natural break point is re-entered, with the
--                  operator's words and the failing output, until its check passes;
--   refusal        a recorded check cannot be dropped without the operator's own words in the
--                  transcript, and is dropped (recorded) when they are there;
--   impossibility  a measured impossibility ends the turn, and an unmeasured one does not;
--   stall          a loop that repeats the same failing output yields exactly ONE named record and
--                  one wake;
--   no gate        an explanation request is never gated;
--   demand         a work request with no checks is told to record them, and proceeds once it has;
--   verifier       a written criterion is judged by a fresh verifier pass, and its verdict moves the
--                  gate in both directions.
local json = dofile('lua/vendor/json.lua')
local real_getenv = host.getenv
local overrides = { WASM_AGENT_PROVIDER = 'opencode-go', WASM_AGENT_LLM_API_KEY = 'fixture-only',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_MAX_TOOL_ROUNDS = '12', WASM_AGENT_DONE_GATE_STALL = '3' }
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return real_getenv(key) end
host.http = function() error('unexpected network in the done-gate fixture') end

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end

local paths = dofile('lua/core/paths.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local done_gate = dofile('lua/core/done_gate.lua')
local agent = dofile('lua/core/agent.lua')
done_gate.setup()

local scratch = paths.home() .. '/gate'
host.exec("mkdir -p '" .. scratch .. "'", '')
local function missing(name) return scratch .. '/' .. name end
local function present(name)
  return "test -f '" .. missing(name) .. "'"
end
local function absent(name)
  return "test -f '" .. missing(name) .. "'"
end
local function make(name, text)
  assert(host.write_file(missing(name), text or 'ok'), 'write ' .. name)
end
local function drop(name) os.remove(missing(name)) end

local function session(title)
  return memory.start_session('', 'done-gate', { user_id = 'master', node_id = '', title = title or 'gate' })
end
local function gate_rows(sid)
  return memory.session_messages(sid, { all = true })
end
local function count_where(rows, needle)
  local n = 0
  for _, row in ipairs(rows) do
    if tostring(row.content or ''):find(needle, 1, true) then n = n + 1 end
  end
  return n
end
local function user_row(sid, text)
  memory.append_turn(sid, { role = 'user', content = text })
end
-- The newest gate row for a session, whatever its status.
local function last_gate(sid)
  local rows = host.sql_query('SELECT * FROM done_gates WHERE session_id=? ORDER BY created_at DESC LIMIT 1',
    json.encode({ sid }))
  local decoded = type(rows) == 'string' and json.decode(rows) or rows
  return decoded and decoded[1] or nil
end

-- ---- work_shaped: the policy switch, pinned so a reader can predict it --------------------------
ok(done_gate.work_shaped('Fix the flaky landing queue'), 'an imperative request is work')
ok(done_gate.work_shaped('please land change/done-gate and push it'), 'please <verb> is work')
ok(done_gate.work_shaped('Can you deploy wasm_the_first?'), 'can you <verb> is work even as a question')
ok(done_gate.work_shaped('Fix it. Then prove it. Phase 2 is the proof.'), 'a phased plan is work')
ok(not done_gate.work_shaped('explain how the landing queue works'), 'explain ... is a question')
ok(not done_gate.work_shaped('Why does the build fail?'), 'why ... ? is a question')
ok(not done_gate.work_shaped('What did the smoke test skip?'), 'what ... ? is a question')
ok(not done_gate.work_shaped('[self-wake] scheduled wake: look again'), 'a harness turn is not an operator request')

-- ---- A. the store and the tool -----------------------------------------------------------------
local a = session('store')
local request = 'Fix the flaky landing queue and prove the fix'
user_row(a, request)

local refused = done_gate.tool({ action = 'capture', request = 'fix the queue', checks = { { command = 'true' } } },
  { session_id = a, user_id = 'master' })
ok(refused.error == 'done_gate_request_not_in_transcript', 'a paraphrase of the request is refused: ' .. tostring(refused.error))
ok(done_gate.gate_for(a, request) == nil, 'and no gate was created by the refusal')

local captured = done_gate.tool({ action = 'capture', checks = { { command = 'true', why = 'the shell runs' },
  { command = 'test -f ' .. missing('nope.txt'), expect_exit = 1, why = 'the file is absent' } } },
  { session_id = a, user_id = 'master' })
ok(captured.ok == true and captured.gate_id ~= nil, 'capture records a gate: ' .. json.encode(captured.error))
ok(#done_gate.checks(captured.gate_id) == 2, 'with both checks')
local gate_a = done_gate.gate(captured.gate_id)
ok(gate_a.request == request, 'and the operator words, verbatim, not the tool call: ' .. tostring(gate_a.request))

local dup = done_gate.tool({ action = 'capture', checks = { { command = 'true' } } }, { session_id = a, user_id = 'master' })
ok(dup.existing == true and dup.gate_id == captured.gate_id, 'a second capture for the same request reuses the gate')

local first_check = done_gate.checks(captured.gate_id)[1]
local dropped = done_gate.tool({ action = 'remove', id = first_check.id }, { session_id = a, user_id = 'master' })
ok(dropped.error == 'done_check_removal_requires_operator_words', 'a check cannot be dropped without the operator: ' .. tostring(dropped.error))
ok(#done_gate.checks(captured.gate_id) == 2, 'and the check is still live')

local quoted = 'drop the check that watches the log, keep the rest'
user_row(a, quoted)
local removed = done_gate.tool({ action = 'remove', id = first_check.id, operator_quote = 'drop the check that watches the log' },
  { session_id = a, user_id = 'master' })
ok(removed.ok == true, 'with the operator words quoted from the transcript it is removed: ' .. json.encode(removed.error))
ok(#done_gate.checks(captured.gate_id) == 1, 'and only that check is gone')
ok(#done_gate.removed_checks(captured.gate_id) == 1, 'the removal keeps its row, so the audit trail survives')

local invented = done_gate.tool({ action = 'remove', id = done_gate.checks(captured.gate_id)[1].id,
  operator_quote = 'the operator said to drop everything' }, { session_id = a, user_id = 'master' })
ok(invented.error == 'done_check_removal_requires_operator_words', 'a quote the operator never said is refused')

-- an impossibility must be measured
local unmeasured = done_gate.tool({ action = 'impossible', reason = 'the host does not exist' },
  { session_id = a, user_id = 'master' })
ok(unmeasured.error == 'done_gate_impossibility_not_measured', 'an impossibility with no probe is refused')
local wrong_probe = done_gate.tool({ action = 'impossible', reason = 'the host does not exist',
  probes = { { command = 'test -f ' .. missing('nope.txt'), expect_exit = 0 } } },
  { session_id = a, user_id = 'master' })
ok(wrong_probe.error == 'impossibility_not_measured', 'a probe that does not show the blocker is refused')
local measured = done_gate.tool({ action = 'impossible', reason = 'the host does not exist',
  probes = { { command = 'test -f ' .. missing('nope.txt'), expect_exit = 1 } } },
  { session_id = a, user_id = 'master' })
ok(measured.ok == true and measured.status == 'impossible', 'a probe the harness reruns closes the gate: ' .. json.encode(measured.error))
local closed = done_gate.gate(captured.gate_id)
ok(closed.status == 'impossible' and closed.close_code == 'probe_measured',
  'and the gate records how it ended: ' .. tostring(closed.status) .. '/' .. tostring(closed.close_code))

-- an exemption is recorded, and refused while checks are live
local b = session('exempt')
user_row(b, 'Fix the thing')
local exempted = done_gate.tool({ action = 'exempt', why = 'the request needed no change in the world' },
  { session_id = b, user_id = 'master' })
ok(exempted.ok == true, 'a request with no gate can be exempted while it is being decided')

-- ---- B. the turn-end gate, inside a real run ---------------------------------------------------
local requests, answers = {}, {}
host.http_stream = function(_, _, _, body)
  local encoded = type(body) == 'string' and body or json.encode(body)
  requests[#requests + 1] = encoded
  if os.getenv('DO_GATE_TRACE') then
    local okmsg, decoded = pcall(json.decode, encoded)
    local last = okmsg and decoded.messages and decoded.messages[#decoded.messages] or nil
    print(string.format('call %d: %s: %s', #requests, tostring(last and last.role),
      tostring(last and last.content or ''):sub(1, 160):gsub('\n', ' ')))
  end
  local next_answer = table.remove(answers, 1)
  if not next_answer then
    print('fixture exhausted at call ' .. #requests .. '; tail of the request:\n'
      .. tostring(requests[#requests]):sub(-2000))
    error('the fixture was asked for more calls than it scripted')
  end
  return json.encode(next_answer)
end
-- A one-shot call that is not streamed (the verifier) reaches `host.http`, whose contract is
-- `{status, body}` with an OpenAI-shaped body - the same answer, in the other envelope.
host.http = function(_, _, _, body)
  local encoded = type(body) == 'string' and body or json.encode(body)
  requests[#requests + 1] = encoded
  local next_answer = table.remove(answers, 1)
  if not next_answer then error('the fixture was asked for more calls than it scripted') end
  local payload = { id = 'fixture', model = 'fixture',
    choices = { { index = 0, finish_reason = next_answer.finish_reason or 'stop',
      message = { role = 'assistant', content = next_answer.content or '' } } },
    usage = next_answer.usage }
  return json.encode({ status = 200, body = json.encode(payload) })
end
local usage = { prompt_tokens = 100, completion_tokens = 10, total_tokens = 110 }
local function final(text)
  return { status = 200, content = text, stream_complete = true, finish_reason = 'stop', usage = usage, tool_calls = {} }
end
local function calls(list)
  local out = {}
  for index, item in ipairs(list) do
    out[index] = { id = 'call_' .. index .. '_' .. tostring(math.random(100000)),
      type = 'function', ['function'] = { name = item[1], arguments = json.encode(item[2]) } }
  end
  return { status = 200, content = '', stream_complete = true, finish_reason = 'tool_calls', usage = usage, tool_calls = out }
end
local function run(sid, text)
  local emitted = {}
  local bot = agent.new(sid, function(event) emitted[#emitted + 1] = event end, 'master', 'master', '')
  local reply = bot:run(text)
  return reply, emitted
end
local function last_request_has(needle)
  local body = requests[#requests] or ''
  return body:find(needle, 1, true) ~= nil
end

-- 1. a fixture agent that stops early is re-entered until its check passes -----------------------
drop('phase2.txt')
local s1 = session('two-phase')
local two_phase = 'Fix the landing queue in two phases: phase 1 writes the plan, phase 2 creates the marker'
requests = {}
answers = {
  calls({ { 'done_criteria', { action = 'capture', checks = {
    { command = present('phase2.txt'), why = 'phase 2 delivered' } } } } }),
  final('Phase 1 is done: the plan is written. Phases 2-4 not started.'),
  calls({ { 'write', { path = missing('phase2.txt'), content = 'phase 2' } } }),
  final('Both phases are done; the check passes.'),
}
local reply1, emitted1 = run(s1, two_phase)
ok(reply1 == 'Both phases are done; the check passes.', 'the run continued past the early stop: ' .. tostring(reply1))
ok(#requests == 4, 'exactly one re-entry was needed (4 model calls, no operator turn): ' .. #requests)
ok(last_request_has(two_phase), 'the re-entry carried the operator words, not a summary')
ok(last_request_has('[done gate') or last_request_has('done gate'),
  'and it is labelled as the harness, not as a new request')
local rows1 = gate_rows(s1)
ok(count_where(rows1, 'Phase 1 is done') == 1, 'the early answer is kept in the transcript')
local gate1 = last_gate(s1)
ok(gate1 and gate1.status == 'passed', 'the gate closed as passed: ' .. tostring(gate1 and gate1.status))
ok(memory.session_messages(s1, { all = true })[#memory.session_messages(s1, { all = true })] ~= nil, 'the session still reads')
local saw_continue = false
for _, event in ipairs(emitted1) do
  if event.type == 'status' and tostring(event.text):find('still failing', 1, true) then saw_continue = true end
end
ok(saw_continue, 'the reader is told the turn continued on a failing check')

-- 2. a dropped check is refused (already pinned above), and a stalled loop yields ONE named record --
drop('stall.txt')
local s2 = session('stall')
requests = {}
answers = {
  calls({ { 'done_criteria', { action = 'capture', checks = {
    { command = present('stall.txt'), why = 'the artifact exists' } } } } }),
  final('Phase 1 done; the rest is not started.'),
  final('Phase 1 done; the rest is not started.'),
  final('Phase 1 done; the rest is not started.'),
}
local reply2 = run(s2, 'Fix the stall and prove it')
ok(reply2 == 'Phase 1 done; the rest is not started.', 'the stalled turn still answers with the model words: ' .. tostring(reply2))
ok(#requests == 4, 'three identical failing turn ends, then the loop stops: ' .. #requests)
local rows2 = gate_rows(s2)
ok(count_where(rows2, 'done_gate_stalled') == 1, 'exactly one named stalled record: ' .. count_where(rows2, 'done_gate_stalled'))
ok(count_where(rows2, 'Phase 1 done') == 3, 'the three candidate answers are all kept')
local gate2 = last_gate(s2)
ok(gate2 and gate2.status == 'stalled', 'the gate records the stall: ' .. tostring(gate2 and gate2.status))
ok(gate2 and gate2.wake_id ~= '' and gate2.wake_id ~= nil, 'and one wake was scheduled for the operator: ' .. tostring(gate2 and gate2.wake_id))

-- 3. a measured impossibility ends the turn -----------------------------------------------------
drop('never.txt')
local s3 = session('impossible')
requests = {}
answers = {
  calls({ { 'done_criteria', { action = 'capture', checks = {
    { command = present('never.txt'), why = 'the artifact exists' } } } } }),
  calls({ { 'done_criteria', { action = 'impossible', reason = 'the artifact cannot exist: the producer is gone',
    probes = { { command = 'test -f ' .. missing('never.txt'), expect_exit = 1 } } } } }),
  final('Impossible: the producer is gone, measured by the probe; here is what I did not do.'),
}
local reply3 = run(s3, 'Fix it and prove the artifact exists')
ok(reply3 == 'Impossible: the producer is gone, measured by the probe; here is what I did not do.',
  'a measured impossibility ends the turn: ' .. tostring(reply3))
ok(#requests == 3, 'and it is not re-entered: ' .. #requests)
local gate3 = last_gate(s3)
ok(gate3 and gate3.status == 'impossible', 'the gate closed as impossible: ' .. tostring(gate3 and gate3.status))

-- 4. an explanation request is not gated --------------------------------------------------------
local s4 = session('explain')
requests = {}
answers = {
  calls({ { 'bash', { command = 'echo the gate runs the recorded checks at each turn end' } } }),
  final('The done gate runs the checks the run recorded, at every turn end.'),
}
local reply4 = run(s4, 'Explain how the done gate decides a turn is finished')
ok(reply4 == 'The done gate runs the checks the run recorded, at every turn end.', 'the explanation is answered: ' .. tostring(reply4))
ok(#requests == 2, 'with no extra model call for a gate: ' .. #requests)
ok(last_gate(s4) == nil, 'and no gate was created for a question')

-- 5. a work request that changed state without recording checks leaves a NAMED record ----------------
drop('demand.txt')
local s5 = session('uncaptured')
requests = {}
answers = {
  calls({ { 'write', { path = missing('scratch.txt'), content = 'working' } } }),
  final('Done.'),
}
local reply5 = run(s5, 'Fix the demand path and prove it')
ok(reply5 == 'Done.', 'a run that recorded no checks still answers: ' .. tostring(reply5))
ok(#requests == 2, 'and is not re-entered for the paperwork: ' .. #requests)
local gate5 = last_gate(s5)
ok(gate5 and gate5.status == 'uncaptured', 'the missing capture is a durable record: ' .. tostring(gate5 and gate5.status))
ok(gate5 and tostring(gate5.close_detail):find('no acceptance checks', 1, true) ~= nil,
  'and the record says what was missing')
-- With the checks recorded, the same request is gated: a passing check ends the turn.
drop('demand2.txt')
local s5b = session('captured')
requests = {}
answers = {
  calls({ { 'done_criteria', { action = 'capture', checks = {
    { command = present('demand2.txt'), why = 'the artifact exists' } } } } }),
  calls({ { 'write', { path = missing('demand2.txt'), content = 'ok' } } }),
  final('Done, and the check passes.'),
}
local reply5b = run(s5b, 'Fix the demand path and prove it')
ok(reply5b == 'Done, and the check passes.', 'a captured request finishes on its check: ' .. tostring(reply5b))
local gate5b = last_gate(s5b)
ok(gate5b and gate5b.status == 'passed', 'and the gate closes passed: ' .. tostring(gate5b and gate5b.status))

-- 6. a written criterion is judged by a fresh verifier pass -------------------------------------
local s6 = session('verifier')
requests = {}
answers = {
  calls({ { 'done_criteria', { action = 'capture', checks = {
    { text = 'the summary document says what the gate does', why = 'the operator asked for a summary' } } } } }),
  final('Summary attached.'),
  final(json.encode({ verdicts = { { id = 'c1', pass = false, reason = 'no document is attached' } } })),
  final('Summary attached: the gate runs the recorded checks at every turn end.'),
  final(json.encode({ verdicts = { { id = 'c1', pass = true, reason = 'the answer states what the gate does' } } })),
}
local reply6 = run(s6, 'Write a summary of what the done gate does and attach it')
ok(reply6 == 'Summary attached: the gate runs the recorded checks at every turn end.', 'the verifier can hold and release a turn')
ok(#requests == 5, 'one held turn, one released turn, one verifier call each: ' .. #requests)
local gate6 = last_gate(s6)
ok(gate6 and gate6.status == 'passed', 'the gate closed passed after the verifier agreed: ' .. tostring(gate6 and gate6.status))
local verifier_prompt_seen = false
for _, body in ipairs(requests) do
  if tostring(body):find('You are a verifier', 1, true) then verifier_prompt_seen = true end
end
ok(verifier_prompt_seen, 'the verifier receives its own no-stake prompt, not the working session')

if failed > 0 then print('done-gate: ' .. failed .. ' failed, ' .. checks .. ' checks') os.exit(1) end
print('done-gate ok: ' .. checks .. ' checks')
