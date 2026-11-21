-- R4 (rel review r1), ONE PATH (Victor 21/11): the leak net skips code, and its notice names the one door
-- this node has.
--
-- Four cases, exactly as the review names them, on the modules the loop uses: a fenced sample and an
-- inline mention of a tag in the final answer are prose (finished); a bare leaked call earns ONE named
-- continue and then a named failure; and the notice names the run tool, never a fenced block that no
-- longer runs.
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
ok(raw.markup_in_text(fenced) ~= nil, 'the raw scan does see the marker inside a fence')
ok(contract.markup(fenced) == nil, 'but a fenced sample is prose, not a call the model meant to make')

-- b. an inline mention of a tag in the final answer is prose
local TICKC = string.char(96)
local inline = 'The parameter element ends with ' .. TICKC .. '<' .. '/parameter>' .. TICKC .. ' in the spec, as I read it.'
ok(raw.markup_in_text(inline) ~= nil, 'the raw scan does see the tag named inline')
ok(contract.markup(inline) == nil, 'an inline mention is prose, not a leak')

-- c. a bare leaked call IS a leak, and the contract names the shape
local bare = '<bash>{"command":"ls"}</bash>'
ok(raw.markup_in_text(bare) ~= nil, 'a bare leaked call is seen by the scan')
local found = contract.markup(bare)
ok(found ~= nil and found.shape == 'markup', 'and the contract names the shape')

-- d. the notice names the channel this node offers, never a fence it does not use
-- ONE path: every node is native now, so the notice is the run-tool sentence without a mode to read.
ok(found.notice:find('run tool', 1, true) ~= nil,
  'the notice names the run tool: ' .. tostring(found.notice))
ok(found.notice:find(TICK, 1, true) == nil,
  'and it does not tell the node to write a fenced block: ' .. tostring(found.notice))

-- e. a run block that ENDS the answer is the action in the wrong form (the removed transport's shape),
--    and it is read without a mode: one marker, named.
local block = { content = 'Let me look.\n' .. TICK .. 'js run\nreturn await tools.ls({path: "lua"});\n' .. TICK }
local shaped = raw.text_action(block.content)
ok(shaped ~= nil and shaped.marker == TICK .. 'js run', 'a run block that ends the answer is markup')
ok(raw.text_action('an example:\n' .. TICK .. 'js run\nreturn 1;\n' .. TICK .. '\nand that is what it means') == nil,
  'a block the answer goes on from is prose')

print('leak net ok (' .. checks .. ' checks)')
