-- R4 (rel review r1): the leak net skips code, and its notice names the channel the node offers.
--
-- Four cases, exactly as the review names them: a fenced <bash> SAMPLE and an inline mention of a
-- tag in the final answer are prose (finished); a bare leaked call earns ONE named continue and then
-- a named failure. The notice must name the run tool in native mode, not a fenced block the node
-- does not use.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local raw = dofile('lua/core/raw_code.lua')
local contract = dofile('lua/core/finish_contract.lua')
local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end
local TICK = string.rep(string.char(96), 3)

-- a. a fenced sample is prose: the scan runs on the text OUTSIDE fences
local fenced = 'Here is the shape I would use:\n' .. TICK .. 'bash\n<bash>{"command":"ls"}</bash>\n' .. TICK .. '\nThat is all.'
ok(raw.markup_in_text(fenced) ~= nil, 'the raw scan does see the marker (the skip is applied by take)')
local result_fenced = { content = fenced, tool_calls = {}, finish_reason = 'stop' }
local memory = dofile('lua/core/memory.lua'); memory.setup()
local sid = memory.start_session('', 'r4', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
dofile('lua/core/codemode_policy.lua').pin(memory, 'master', ctx)
local entry = raw.take(result_fenced, false, ctx.codemode_policy)
ok(entry == nil or not entry.leaked_markup, 'a fenced <bash> sample is not a leak')

-- b. an inline mention of a tag in the final answer is prose
local TICKC = string.char(96)
local inline = 'The parameter element ends with ' .. TICKC .. '<' .. '/parameter>' .. TICKC .. ' in the spec, as I read it.'
local result_inline = { content = inline, tool_calls = {}, finish_reason = 'stop' }
local entry2 = raw.take(result_inline, false, ctx.codemode_policy)
ok(entry2 == nil or not entry2.leaked_markup, 'an inline `</parameter>` mention is not a leak')

-- c. a bare leaked call IS a leak
local bare = '<bash>{"command":"ls"}</bash>'
local result_bare = { content = bare, tool_calls = {}, finish_reason = 'stop' }
local entry3 = raw.take(result_bare, false, ctx.codemode_policy)
ok(entry3 ~= nil and entry3.leaked_markup == true, 'a bare leaked call is a leak')

-- d. the notice names the channel this node offers, never a fence it does not use
local real = host.getenv
host.getenv = function(k) if k == 'WASM_AGENT_RAW_CODE' then return 'native' end return real(k) end
local found = contract.markup('<bash>{"command":"ls"}</bash>')
host.getenv = real
ok(found ~= nil, 'the contract still names the shape')
ok(found.notice:find('run tool', 1, true) ~= nil,
  'in native mode the notice names the run tool: ' .. tostring(found.notice))
ok(found.notice:find(TICK, 1, true) == nil,
  'and it does not tell a native node to write a fenced block: ' .. tostring(found.notice))
print('leak net ok (' .. checks .. ' checks)')

