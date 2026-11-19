-- The block in the thinking (harness #52) and the end-of-turn gate that answers it.
--
-- PHASE 0 verdict (docs/missions/reports/thinking-block.md): the run block arrives in the provider's
-- REASONING field, not in its content. The harness read only the answer, so the turn failed
-- 'reasoning is not an answer' and the action the model wrote was never run. The fix is one named
-- continue: the model is told where the block belongs, and NOTHING is executed from the thinking.
--
-- Two levels, the same split test-empty-reply.lua uses:
--   * the pure detector and its sentences (no host, no model, no network);
--   * the loop itself, driven through host.http_stream with a recorded response shape - the same entry
--     point the provider uses, so the wiring is under test and not a copy of it.
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-thinking-block.lua wa --db /tmp/x.db
local real_getenv = host.getenv
host.getenv = function(key)
  -- CodeAct, the default mode, PINNED: these rows drive the run-block path, and a node that happens to run
  -- `codemode` (this one does) would otherwise read every one of them with the switch off.
  if key == 'WASM_AGENT_RAW_CODE' then return 'only' end
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  return real_getenv(key)
end
local raw_code = dofile('lua/core/raw_code.lua')
local json = dofile('lua/vendor/json.lua')

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format('%s: got %q, want %q', what, tostring(got), tostring(want)))
  end
end
local function has(haystack, needle, what)
  checks = checks + 1
  if not string.find(tostring(haystack), needle, 1, true) then
    error(string.format('%s: %q does not contain %q', what, tostring(haystack), needle))
  end
end

-- ------------------------------------------------------------ the detector
local TICK = string.rep(string.char(96), 3)
local COMPLETE = 'Let me look at the file.\n' .. TICK .. 'js run\nreturn 1;\n' .. TICK
eq(raw_code.in_thinking(COMPLETE).shape, 'run', 'a complete run block that ends the thinking')
eq(raw_code.in_thinking(COMPLETE .. '\nand then some more prose'), nil,
  'thinking that goes on after a block is the model reasoning about code')
eq(raw_code.in_thinking(TICK .. 'js run\nreturn 1;').shape, 'cut_run', 'a cut run block')
eq(raw_code.in_thinking(TICK .. 'js\nreturn 1;\n' .. TICK).shape, 'plain_js', 'a plain js block')
eq(raw_code.in_thinking('I reasoned and stopped.'), nil, 'no block at all (#22)')
-- #51/C: the four lenient spellings are the same tag, and all four are run blocks.
eq(raw_code.in_thinking(TICK .. 'JS run\nreturn 1;\n' .. TICK).shape, 'run', '#51/C: the tag in capitals')
eq(raw_code.in_thinking(TICK .. 'js  run\nreturn 1;\n' .. TICK).shape, 'run', '#51/C: two spaces')
eq(raw_code.in_thinking(TICK .. 'javascript run\nreturn 1;\n' .. TICK).shape, 'run', '#51/C: javascript')
eq(raw_code.in_thinking(TICK .. 'js run return 1;\n' .. TICK).shape, 'run', '#51/C: code on the fence line')

-- ---------------------------------------------------------- the sentences
-- Model-facing strings: asserted verbatim, because they are the fix the model reads.
local notice = raw_code.thinking_notice({ shape = 'run' })
has(notice, 'in your thinking, not in your answer', 'the notice names the field the block is in')
has(notice, 'js run', 'the notice names the tag to write')
has(notice, 'Write it in your ANSWER', 'the notice says where to write it')
has(raw_code.thinking_notice({ shape = 'plain_js' }), 'tagged js rather than js run',
  'the plain-js notice names the one thing to change')
has(raw_code.thinking_notice({ shape = 'cut_run' }), 'cut off', 'the cut notice names the cut')
has(raw_code.thinking_failure({ shape = 'run' }), 'run_block_in_thinking', 'the failure is named')
has(raw_code.reasoning_only_notice(), 'you reasoned and then stopped', '#22 notice')
has(raw_code.reasoning_only_failure(), 'reasoning_only', '#22 failure')
eq(raw_code.THINKING_CONTINUES, 1, 'one continue, not a loop')

-- ------------------------------------------------------- lenient fences (#51/C)
local blocks = raw_code.parse(TICK .. 'js run const r = 1;\n' .. TICK)
eq(#blocks, 1, 'one block')
eq(blocks[1].run, true, 'a statement on the fence line is still a run block')
eq(blocks[1].inline, 'const r = 1;', 'the fence line carries line 1 of the script')
local taken_result = { content = TICK .. 'js run const r = 1;\n' .. TICK, finish_reason = 'stop', tool_calls = {} }
local taken = raw_code.take(taken_result, false, {})
checks = checks + 1
if not taken then error('a run block with code on its fence line must be taken') end
local call = taken_result.tool_calls[#taken_result.tool_calls]
local args = json.decode(call['function'].arguments)
eq(args.code, 'const r = 1;', '#51/C: the script is the code from the fence line')
eq(raw_code.parse(TICK .. 'js runner\nx\n' .. TICK)[1].run, false, 'js runner is not the run tag')

-- 3. A cut run block (a fence that never closes) is refused by name and answered, never run - the
--    same one-continue shape as above, and the refusal is what the model reads.
local cut = { content = TICK .. 'js run\nconst r = 1;', finish_reason = 'stop', tool_calls = {} }
local cut_taken = raw_code.take(cut, false, {})
checks = checks + 1
if not (cut_taken and cut_taken.refusal) then error('a cut run block must be refused, not run') end
eq(cut_taken.refusal.error, 'raw_code_unterminated', 'the cut block is named')
has(cut_taken.refusal.message, 'never closed', 'the refusal says the block was cut')

-- ---------------------------------------------------------------- the loop
local agentlib = dofile('lua/core/agent.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()

local function turn(title)
  local session_id = memory.ensure_session('thinking-block-test', 'local', title)
  local agent = agentlib.new(session_id, function() end, 'master', 'thinking-block-test', 'local')
  agent.stream = true
  return agent, session_id
end
local function rows_of(session_id)
  return memory.session_messages(session_id) or {}
end
local function notice_rows(session_id)
  local found, tools_run = 0, 0
  for _, row in ipairs(rows_of(session_id)) do
    if row.role == 'user' and tostring(row.content):find('in your thinking, not in your answer', 1, true) then
      found = found + 1
    end
    if row.role == 'tool' then tools_run = tools_run + 1 end
  end
  return found, tools_run
end

-- 1. One continue: the block is in the thinking, the harness asks for it in the answer, and the model's
--    next answer ends the turn. Nothing is executed from the thinking.
local step = 0
host.http_stream = function()
  step = step + 1
  if step == 1 then
    return json.encode({ status = 200, content = '', reasoning = COMPLETE, finish_reason = 'stop', tool_calls = {} })
  end
  return json.encode({ status = 200, content = 'The file is there.', finish_reason = 'stop', tool_calls = {} })
end
local agent, session_id = turn('block in the thinking')
local ok_run, run_error = pcall(agent.run, agent, 'check the file')
checks = checks + 1
if not ok_run then error('a block in the thinking must continue the turn, not fail it: ' .. tostring(run_error)) end
local notices, tools_run = notice_rows(session_id)
eq(notices, 1, 'the harness asked for the block in the answer, exactly once')
eq(tools_run, 0, 'nothing was executed from the thinking')

-- 2. Two consecutive ones: the run fails by name, rc != 0, never a finished turn with the action unrun.
host.http_stream = function()
  return json.encode({ status = 200, content = '', reasoning = COMPLETE, finish_reason = 'stop', tool_calls = {} })
end
agent, session_id = turn('block in the thinking twice')
local second_ok, second_error = pcall(agent.run, agent, 'check the file')
checks = checks + 1
if second_ok then error('a second thinking-only answer must fail the run') end
has(second_error, 'run_block_in_thinking', 'the run fails by name')

-- 3. #22: reasoning only, no block. Same gate, its own sentence.
host.http_stream = function()
  return json.encode({ status = 200, content = '', reasoning = 'I should look at the file and decide.',
    finish_reason = 'stop', tool_calls = {} })
end
agent, session_id = turn('reasoning only')
local third_ok, third_error = pcall(agent.run, agent, 'check the file')
checks = checks + 1
if third_ok then error('reasoning-only twice must fail the run') end
has(third_error, 'reasoning_only', 'the reasoning-only run fails by name')


-- ================================================================ round 2: the same rule, every shape
-- One rule (operator 19/11): never end a turn on an action that did not run or on a plan - ONE named
-- continue (counted), a second consecutive one fails the run by name (rc != 0). Each shape below is a
-- recorded response driven through host.http_stream, the same entry point the provider uses.
local finish_contract = dofile('lua/core/finish_contract.lua')
local chat = dofile('lua/core/chat.lua')

eq(finish_contract.CONTINUES, 1, 'one continue for every shape, not a loop')

-- ------------------------------------------------------------------ 1. markup written as text
-- Measured: <ds_tool>{"command":...}</ds_tool> (land-routing 19/11 00:59), a leftover }}</parameter>
-- (thinking-block 00:41). One generic detector, an allow-list of the markers a model has written.
eq((finish_contract.markup('done <ds_tool>{"command":"ls"}</ds_tool>') or {}).shape, 'markup', 'ds_tool markup')
eq((finish_contract.markup('Let me do these in parallel.}}</parameter>') or {}).shape, 'markup', 'leftover close tag')
eq((finish_contract.markup('DSML is a format name.')), nil, 'prose about a format is an answer')
-- Round 3, item 4: the operator's flip, and the two negatives that go with it. A marker NAMED in inline
-- code is prose, not a call the model meant to make - this assertion was the other way round in round 2.
eq(finish_contract.markup('The detector names `' .. '<ds_tool>' .. '` as one marker.'), nil,
  'round 3: a marker inside inline code is prose (round 2 asserted the opposite)')
eq(finish_contract.markup('Prose that mentions `<tool_call>` and `</parameter>` inside backticks is a note '
  .. 'about the format, not a call.'), nil,
  'round 3: <tool_call>/</parameter> named inside backticks is an answer')
eq((finish_contract.markup('A bare `' .. 'x` and then <ds_tool>{}') or {}).shape, 'markup',
  'round 3: a bare marker OUTSIDE the backticks is still a call the model wrote')
eq(finish_contract.markup('Example:\n' .. TICK .. 'text\n<ds_tool>{}</ds_tool>\n' .. TICK), nil,
  'a marker inside a fenced sample is prose, not a call the model meant to make')
has(finish_contract.markup('x <ds_tool>{}').notice, 'your message contains tool-call markup as text, so nothing ran; act with a js run block in your answer',
  'the markup notice is the sentence the operator asked for')

-- ------------------------------------------------------------------ 2. a stale shutdown notice
local SHUTDOWN = '<system_warning>The previous response was interrupted by a node shutdown\n'
  .. '(sessions before the shutdown see un-settled operations).</system_warning>\n\nCheck the state of your work.'
eq((finish_contract.shutdown(SHUTDOWN) or {}).shape, 'shutdown', 'the measured land-routing notice (00:50)')
eq(finish_contract.shutdown('A node shutdown ends the claim; nothing ran.'), nil,
  'an answer ABOUT a shutdown is an answer')

-- ------------------------------------------------------------------ 3. a compaction summary
local SUMMARY = '<analysis>The task is half done and the context is full.</analysis>\n\n'
  .. '<summary>1. The work in progress.\n2. What is next.</summary>'
eq((finish_contract.compaction(SUMMARY) or {}).shape, 'compaction', 'the measured edit-transport answer (01:01)')
eq((finish_contract.compaction('## Goal\nnothing\n## Progress\n## Next Steps\n1. go') or {}).shape, 'compaction',
  'the harness\'s own checkpoint template is the same shape')
eq(finish_contract.compaction('The gate is green and the report is written.'), nil, 'an ordinary answer is not a summary')

-- ------------------------------------------------------------------ 4. a plan instead of an action
eq((finish_contract.plan('Let me look at the gate in lua/core/agent.lua and then run the test.') or {}).shape, 'plan',
  'a first-person intent with no action is a plan')
eq(finish_contract.plan('The suite is green (51 checks).\n\nNext step for you: push the branch when you are ready.'),
  nil, 'a final answer telling the USER a next step is fine')
eq(finish_contract.plan('One.\nTwo.\nThree.\nLet me now run the whole gate.'), nil,
  'a long answer that happens to end on "let me" is a report, not a plan')
eq(finish_contract.plan('Running the gate.\n' .. TICK .. 'js run\nreturn 1;\n' .. TICK), nil,
  'a reply with a run block is an action shape, never a plan')
-- Round 3, item 2: the two false positives the operator measured, each as a negative test.
eq(finish_contract.plan('The fix is pushed. Let me know.'), nil,
  'round 3: "let me know" is addressed to the USER, so it is an answer')
eq(finish_contract.plan('Done. I\'ll stop here.', 3), nil,
  'round 3: after a tool ran this run, a closing sentence is the answer to the request')
eq((finish_contract.plan('Done. I\'ll stop here.', 0) or {}).shape, 'plan',
  'round 3: the same sentence with NOTHING run in this run is still a plan')

-- ------------------------------------------------------------------ 5. round 3, item 3: the language detector
-- REMOVED (operator 19/11): it fired on real answers and never fixed one. What remains is the envelope
-- sentence that asks for the answer in the user's language, so that sentence is asserted here.
eq(finish_contract.language, nil, 'the language detector is removed from the module, not disabled')
has(agentlib.system_prompt('master', nil, nil, {}, 'full'),
  "Reply in the language of the user's latest message",
  'round 3: the envelope still asks for the answer in the user\'s language')

-- A session of its own for every one of these: the file's own turn() reuses the newest open session for
-- its user (memory.ensure_session), which is right for one thread of a report and wrong for counting the
-- notices of a step. Each round-2 case gets a fresh user, so its rows are its own.
local fresh_serial = 0
local function fresh(title)
  fresh_serial = fresh_serial + 1
  local who = 'tb2-' .. tostring(fresh_serial)
  local session_id = memory.start_session('', 'thinking-block-round2',
    { user_id = who, node_id = '', title = title })
  local agent = agentlib.new(session_id, function() end, 'master', who, '')
  agent.stream = true
  return agent, session_id
end

-- ------------------------------------------------------------------ the loop: one continue, then the name
local function shapes_of(session_id)
  local seen, tools_run, answers = {}, 0, {}
  for _, row in ipairs(rows_of(session_id)) do
    local content = tostring(row.content or '')
    if row.role == 'user' and content:find('[Harness notice]', 1, true) then seen[#seen + 1] = content end
    if row.role == 'tool' then tools_run = tools_run + 1 end
    if row.role == 'assistant' and row.phase ~= 'commentary' and content ~= '' then answers[#answers + 1] = content end
  end
  return seen, tools_run, answers
end

local function scripted(replies)
  local index = 0
  host.http_stream = function()
    index = index + 1
    local reply = replies[index] or { content = 'The gate is green.' }
    return json.encode({ status = 200, content = reply.content or '', reasoning = reply.reasoning or '',
      finish_reason = reply.finish_reason or 'stop', tool_calls = reply.tool_calls or {} })
  end
end

-- 5a. markup as text: one continue, nothing run, and the markup is never recorded as the answer.
scripted({ { content = 'Let me look.\n<ds_tool>{"command":"ls /tmp"}</ds_tool>' }, { content = 'The tree is clean.' } })
agent, session_id = fresh('markup as text')
local markup_ok, markup_error = pcall(agent.run, agent, 'check the tree')
checks = checks + 1
if not markup_ok then error('markup as text must continue the turn, not fail it: ' .. tostring(markup_error)) end
local seen, tools_run, answers = shapes_of(session_id)
eq(#seen, 1, 'the harness asked once for the action')
has(seen[1], 'your message contains tool-call markup as text', 'the notice names the markup')
eq(tools_run, 0, 'nothing ran')
local leaked = false
for _, answer in ipairs(answers) do if answer:find('<ds_tool>', 1, true) then leaked = true end end
eq(leaked, false, 'the markup is not recorded as this session\'s answer')

-- 5b. a second consecutive one fails the run by name (rc != 0).
-- The same reply twice: the stub answers the second request with it as well, so the streak is real.
scripted({ { content = 'Again.\n<ds_tool>{"command":"ls"}</ds_tool>' },
  { content = 'Again.\n<ds_tool>{"command":"ls"}</ds_tool>' } })
agent, session_id = fresh('markup twice')
local markup_twice, markup_twice_error = pcall(agent.run, agent, 'check the tree')
checks = checks + 1
if markup_twice then error('a second markup-as-text answer must fail the run') end
has(markup_twice_error, 'tool_call_markup_as_text', 'the markup run fails by name')

-- 6. the stale shutdown notice: never an answer, never the end of the turn.
scripted({ { content = SHUTDOWN }, { content = 'The worktree is clean; the suite passes.' } })
agent, session_id = fresh('stale shutdown notice')
local shutdown_ok, shutdown_error = pcall(agent.run, agent, 'carry on')
checks = checks + 1
if not shutdown_ok then error('a stale shutdown notice must not end the turn: ' .. tostring(shutdown_error)) end
seen, tools_run, answers = shapes_of(session_id)
eq(#seen, 1, 'the harness asked once for the next step')
has(seen[1], 'not from this session', 'the notice says the warning is stale')
leaked = false
for _, answer in ipairs(answers) do if answer:find('node shutdown', 1, true) then leaked = true end end
eq(leaked, false, 'the stale notice is never recorded as the session\'s answer')

-- 7a. a compaction summary as the answer: the turn continues instead of ending on it.
scripted({ { content = SUMMARY }, { content = 'The report is written and the suite passes.' } })
agent, session_id = fresh('compaction answer')
local compaction_ok, compaction_error = pcall(agent.run, agent, 'carry on')
checks = checks + 1
if not compaction_ok then error('a compaction summary must not end the turn: ' .. tostring(compaction_error)) end
seen = shapes_of(session_id)
has(seen[1] or '', 'context-compaction summary', 'the notice names the summary')

-- 7b. twice: the run fails by name.
scripted({ { content = SUMMARY }, { content = SUMMARY } })
agent, session_id = fresh('compaction answer twice')
local compaction_twice, compaction_twice_error = pcall(agent.run, agent, 'carry on')
checks = checks + 1
if compaction_twice then error('a second compaction answer must fail the run') end
has(compaction_twice_error, 'compaction_answer', 'the compaction run fails by name')

-- 8. the harness's OWN compaction mid-run does not end the turn: after compacting, the run continues the
--    task, and the answer that ends it is the model's, not the summary. The window is narrowed through the
--    provider's own overrides (WASM_AGENT_COMPACT_KEEP/RESERVE, WASM_AGENT_CONTEXT_BUDGET): compaction is
--    the harness's decision, and a test that cannot make it fire proves nothing about it.
local real_getenv_budget = host.getenv
-- keep - overhead is what the cut must cross (500 here); the reserve stays a real reply budget, because a
-- 300-token reserve caps the summary at 240 tokens and the provider answers `length` for it.
local budget_env = { WASM_AGENT_COMPACT_KEEP = '400', WASM_AGENT_COMPACT_RESERVE = '4000',
  WASM_AGENT_CONTEXT_BUDGET = '1200' }
host.getenv = function(key)
  if budget_env[key] then return budget_env[key] end
  return real_getenv_budget(key)
end
agent, session_id = fresh('compaction mid-turn')
-- A transcript with something to summarise: compaction needs at least four rows AND a prefix older than
-- the tokens it keeps (measured here: keep - overhead = 500, so the rows below are long enough to cross it).
local SEEDED = 'Earlier in this thread: the gate was read, each shape was listed with the sentence it must '
  .. 'produce, the suite ran and every check passed, the report was started, and the measurements that back '
  .. 'each claim were quoted. '
for index = 1, 4 do
  memory.append_turn(session_id, { role = (index % 2 == 0) and 'assistant' or 'user', content = string.rep(SEEDED, 8) })
end
-- The summary model is called on the non-streaming path (provider.complete_with with stream=false), so the
-- summary is stubbed on host.http and the steps on host.http_stream: neither reaches the network.
local summary_calls, step_calls = 0, 0
local real_http = host.http
host.http = function()
  summary_calls = summary_calls + 1
  return json.encode({ status = 200, headers = {},
    body = json.encode({ choices = { { message = { content = 'Checkpoint: the gate is being checked; '
      .. 'nothing is blocked.' }, finish_reason = 'stop' } },
      usage = { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15 } }) })
end
host.http_stream = function()
  step_calls = step_calls + 1
  if step_calls == 1 then
    return json.encode({ status = 200, content = TICK .. 'js run\nreturn 1;\n' .. TICK,
      finish_reason = 'stop', tool_calls = {} })
  end
  return json.encode({ status = 200, content = 'Compaction did not end the turn: the task finished.',
    finish_reason = 'stop', tool_calls = {} })
end
local mid_ok, mid_reply = pcall(agent.run, agent, 'do the work')
host.getenv = real_getenv_budget
host.http = real_http
checks = checks + 1
if not mid_ok then error('a mid-run compaction must not end the turn: ' .. tostring(mid_reply)) end
has(tostring(mid_reply), 'Compaction did not end the turn', "the run ended on the model's answer, not on a summary")
local summaries, mid_tools = 0, 0
for _, row in ipairs(rows_of(session_id)) do
  if row.role == 'summary' then summaries = summaries + 1 end
  if row.role == 'tool' then mid_tools = mid_tools + 1 end
end
eq(summaries >= 1, true, 'a compaction really did happen in that turn (nothing is claimed without it)')
eq(mid_tools >= 1, true, 'the run block after the compaction still ran: the turn went on with the task')

-- 9. a plan-only ending: one continue; twice, the run fails by name. A plan for the USER is an answer.
scripted({ { content = 'Let me read the gate and then run the suite.' }, { content = 'The suite passes (51 checks).' } })
agent, session_id = fresh('plan only')
local plan_ok, plan_error = pcall(agent.run, agent, 'check the gate')
checks = checks + 1
if not plan_ok then error('a plan must not end the turn: ' .. tostring(plan_error)) end
seen = shapes_of(session_id)
has(seen[1] or '', 'This message was a plan, not an action', 'the notice names the plan')

scripted({ { content = 'Let me read the gate and then run the suite.' },
  { content = 'Let me read the gate and then run the suite.' } })
agent, session_id = fresh('plan only twice')
local plan_twice, plan_twice_error = pcall(agent.run, agent, 'check the gate')
checks = checks + 1
if plan_twice then error('a second plan-only answer must fail the run') end
has(plan_twice_error, 'plan_only', 'the plan run fails by name')

scripted({ { content = 'The gate is green (51 checks).\n\nNext step for you: push the branch when you are ready.' } })
agent, session_id = fresh('eventually a plan for the user')
local user_plan_ok, user_plan_reply = pcall(agent.run, agent, 'check the gate')
checks = checks + 1
if not user_plan_ok then error('a plan for the USER ends the turn: ' .. tostring(user_plan_reply)) end
has(tostring(user_plan_reply), 'Next step for you', 'that answer is the answer')

-- 11. #53: a run the harness refused before it could run exits non-zero. The rule lives in one place
--     (chat.turn_ok), so the scripted CLI and the test read the same answer.
eq(chat.turn_ok(true, { turn_refused = 'no_dispatchable_tools: ...' }), false,
  'a refused run is not a finished turn: the caller exits non-zero')
eq(chat.turn_ok(true, {}), true, 'a run that answered is a finished turn')
eq(chat.turn_ok(false, {}), false, 'a run that raised failed')

-- 12. round 3, item 1: the streak is per RUN. An agent object is reused across turns, and a counter that
--     survived its run failed the next turn's FIRST offence as if it were the second. The counter is reset
--     where the run starts (lua/core/agent.lua, next to fake_answer_repeats), so a stale value does nothing.
agent, session_id = fresh('streak is per run')
agent.finish_continues = 7 -- a stale streak, as an earlier turn of this same agent would leave it
scripted({ { content = 'Let me read the gate and then run the suite.' }, { content = 'The suite passes.' } })
local streak_ok, streak_reply = pcall(agent.run, agent, 'check the gate')
checks = checks + 1
if not streak_ok then error('a stale streak must not fail this run\'s first offence: ' .. tostring(streak_reply)) end
has(tostring(streak_reply), 'The suite passes', 'the run continued once and then answered')

-- 13. round 3, item 2: the operator's two negative tests, through the real loop. "Done. I'll stop here."
--     AFTER a tool ran is the answer to the request - no notice, no failure.
scripted({ { content = TICK .. 'js run\nreturn 1;\n' .. TICK }, { content = 'Done. I\'ll stop here.' } })
agent, session_id = fresh('done after a tool ran')
local done_ok, done_reply = pcall(agent.run, agent, 'check the tree')
checks = checks + 1
if not done_ok then error('a closing sentence after a tool ran must end the turn: ' .. tostring(done_reply)) end
local done_seen, done_tools = shapes_of(session_id)
eq(#done_seen, 0, 'round 3: nothing was flagged after an action had run')
eq(done_tools >= 1, true, 'the run block did run (nothing is claimed without it)')
has(tostring(done_reply), 'Done.', 'that closing sentence is the answer')
--     And the same sentence with NOTHING run is still a plan: one continue, then the run fails by name.
scripted({ { content = 'Done. I\'ll stop here.' }, { content = 'Done. I\'ll stop here.' } })
agent, session_id = fresh('done with no action')
local _, done_plan_error = pcall(agent.run, agent, 'check the tree')
has(done_plan_error, 'plan_only', 'round 3: with nothing run it is still a plan, and the second one fails')

print(string.format('thinking block ok (%d checks)', checks))