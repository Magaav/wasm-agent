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

print(string.format('thinking block ok (%d checks)', checks))