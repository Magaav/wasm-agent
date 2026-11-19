if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")") end

-- The model profile and the transport it decides (docs/AGENT-SEAT.md, principle 7). A measurement is
-- read; a missing measurement is named and does not become a silent pass.
local profile = dofile('lua/core/model_profile.lua')
local conform = dofile('lua/core/conform.lua')
local raw = dofile('lua/core/raw_code.lua')

local n = 0
local function eq(a, b, w)
  n = n + 1
  if a ~= b then error(w .. '\\n  got:  ' .. tostring(a) .. '\\n  want: ' .. tostring(b)) end
end
local function has(a, b, w)
  n = n + 1
  if not tostring(a):find(b, 1, true) then error(w .. ': ' .. tostring(a)) end
end

-- A model name is a file name here: a path is refused rather than sanitised into another file.
local bad, why = profile.safe_name('../../etc/passwd')
eq(bad, nil, 'a path is not a model name')
eq(why, 'model_name_not_a_file_name', 'the refusal is named')
eq((profile.safe_name('')), nil, 'an empty model is refused')

-- No profile is no_profile, never a pass.
local none, reason = profile.read('never-measured-model')
eq(none, nil, 'an unmeasured model has no profile')
eq(reason, 'no_profile', 'and that is said by name')

-- The conservative default names its source and gives one notice line.
local transport, source, notice = raw.transport_for('never-measured-model', true)
eq(transport, 'tool_call', 'a model that can call tools is offered the run tool')
eq(source, 'default', 'with no profile the choice is the default')
has(notice, 'wa conform', 'the notice suggests the measurement')
has(notice, 'never-measured-model', 'the notice names the model')
local unable, unable_source = raw.transport_for('never-measured-model', false)
eq(unable, 'block', 'a model that cannot call tools is offered the block')
eq(unable_source, 'default', 'that too is the default')

-- A measured profile drives the choice, and says so.
local measured = { model = 'm1', rates = { uses_run_tool = 1, acts_in_answer = 0 }, tasks = {} }
local stored, serr = profile.write('m1', measured)
eq(stored, true, 'a profile is stored: ' .. tostring(serr))
eq(profile.read('m1').model, 'm1', 'and reads back')
local chosen, chosen_source, chosen_notice = raw.transport_for('m1', true)
eq(chosen, 'tool_call', 'the measured transport is used')
eq(chosen_source, 'profile', 'and the source says it is the profile')
eq(chosen_notice, nil, 'a measured model needs no notice')

-- Guidance matches the transport and never offers the other one.
has(raw.guidance_for('tool_call'), 'run tool', 'the tool-call guidance names the run tool')
n = n + 1
if raw.guidance_for('block'):find('run tool', 1, true) then
  error('the block guidance must not offer the run tool')
end

-- The suite has the recorded shapes the seat names, and every task can fail.
local tasks = dofile('lua/core/conform_tasks.lua')
assert(#tasks.TASKS >= 9, 'the suite carries the seat\'s shapes, got ' .. #tasks.TASKS)
for _, task in ipairs(tasks.TASKS) do
  assert(type(task.id) == 'string' and task.id ~= '', 'a task has an id')
  assert(type(task.prompt) == 'string' and task.prompt ~= '', task.id .. ' has a prompt')
  local passed, why = task.check({ answer_text = '', tool_calls = {} }, raw)
  assert(passed == false and why ~= nil, task.id .. ' must be able to fail, with a reason')
end
print('conform profile ok (' .. n .. ' checks)')
