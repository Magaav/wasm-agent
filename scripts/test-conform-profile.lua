-- The provider door and the measurement behind it (docs/AGENT-SEAT.md, principle 7).
--
-- This file was deleted with the two-transport mode and RESTORED here (review r1, item 5) because the
-- door it guards is live: the node refuses a provider that cannot call tools BY NAME, and it may be
-- opened by a MEASURED profile. The rows below judge four things the audit named:
--   * an all-fail profile (0 of 0) decides NOTHING - `0 >= 0` used to read as tool_call;
--   * a model id with a separator (`vendor/model`) can be measured and read back;
--   * the door opens for a measured tool-call profile and refuses everything else, by name;
--   * the refusal says how the profile gets installed, because `wa conform` measures in a scratch home.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local conform = dofile('lua/core/conform.lua')
local profile_lib = dofile('lua/core/model_profile.lua')
local raw_code = dofile('lua/core/raw_code.lua')
local paths = dofile('lua/core/paths.lua')

local checks = 0
local function check(v, label) checks = checks + 1; if not v then error(label, 0) end end

-- ---- 1. what a measured profile decides -------------------------------------------------------
local none = conform.decide(nil)
check(none.transport == nil and none.source == 'no_profile', 'no profile decides nothing')
local all_fail = conform.decide({ tasks = {}, rates = { uses_run_tool = 0, acts_in_answer = 0 } })
check(all_fail.transport == nil, 'an all-fail profile decides NOTHING (0 >= 0 is not tool_call)')
check(all_fail.source == 'no_action_measured', 'and names why: ' .. tostring(all_fail.source))
local tool = conform.decide({ tasks = {}, rates = { uses_run_tool = 3, acts_in_answer = 1 } })
check(tool.transport == conform.TOOL_CALL, 'a tool-call measurement implies the tool call')
local fence = conform.decide({ tasks = {}, rates = { uses_run_tool = 1, acts_in_answer = 4 } })
check(fence.transport == conform.BLOCK, 'a fence-favouring measurement is recorded as such (the node does not honour it)')

-- ---- 2. a model id with a separator can have a profile ---------------------------------------
local SLASH = 'vendor/model-1'
local wrote, why_wrote = profile_lib.write(SLASH, { tasks = {}, rates = { uses_run_tool = 3, acts_in_answer = 0 } })
check(wrote == true, 'a model id with a slash is measurable: ' .. tostring(why_wrote))
local back = profile_lib.read(SLASH)
check(type(back) == 'table' and back.model == SLASH, 'and reads back as the same id (' .. tostring(back and back.model) .. ')')
local file_name = select(1, profile_lib.file_name(SLASH))
check(tostring(file_name):find('/', 1, true) == nil, 'its FILE name carries no separator (' .. tostring(file_name) .. ')')
check(tostring(file_name):find('%%2F', 1, true) ~= nil, 'because the separator is encoded, not dropped')
local file_path = profile_lib.path(SLASH)
check(tostring(file_path):sub(1, #paths.data()) == paths.data(), 'and the file stays inside this node (' .. tostring(file_path) .. ')')

-- ---- 3. the door ------------------------------------------------------------------------------
check(raw_code.transport_refusal('opencode-go', 'deepseek-v4.1-flash') == nil,
  'the fleet provider has a tool-call row, so it is not refused')
local unknown = raw_code.transport_refusal('a-provider-nobody-measured', 'a-model-nobody-measured')
check(unknown and unknown.name == 'provider_cannot_call_tools', 'an unmeasured provider is refused by name')
check(unknown.text:find('this provider cannot call tools; add a row or measure it with', 1, true) ~= nil,
  'and says the two repairs')
check(unknown.text:find('INSTALL the profile it prints', 1, true) ~= nil,
  'including that a measurement has to be INSTALLED (it runs in a scratch home)')

local measured = raw_code.transport_refusal('a-provider-nobody-measured', 'measured-model-1')
check(measured ~= nil, 'a model with no profile does not open the door')
profile_lib.write('measured-model-1', { tasks = {}, rates = { uses_run_tool = 4, acts_in_answer = 0 } })
check(raw_code.transport_refusal('a-provider-nobody-measured', 'measured-model-1') == nil,
  'a measured tool-call profile opens it for a provider with no row')
profile_lib.write('all-fail-model-1', { tasks = {}, rates = { uses_run_tool = 0, acts_in_answer = 0 } })
local all_fail_door = raw_code.transport_refusal('a-provider-nobody-measured', 'all-fail-model-1')
check(all_fail_door ~= nil and all_fail_door.name == 'provider_cannot_call_tools',
  'an all-fail profile does NOT open it')
profile_lib.write('fence-model-1', { tasks = {}, rates = { uses_run_tool = 0, acts_in_answer = 3 } })
local fence_door = raw_code.transport_refusal('a-provider-nobody-measured', 'fence-model-1')
check(fence_door ~= nil, 'nor does a profile that only ever acted through a fence')

-- ---- 4. the harness measures the one door ------------------------------------------------------
local harness = conform.harness(dofile('lua/core/memory.lua'), 'master', { session_id = 'conform-harness', user_id = 'master', role = 'master' })
check(type(harness.tools) == 'table' and #harness.tools > 0, 'the harness declares tools')
check(tostring(harness.system):find('js run block: it runs the same way', 1, true) == nil,
  'and no longer offers a fenced block as a second way to act')
check(tostring(harness.system):find('run tool', 1, true) ~= nil, 'it names the run tool')

print('conform profile ok (' .. checks .. ' checks)')
