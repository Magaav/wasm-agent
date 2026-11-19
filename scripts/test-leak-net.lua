if not host then error('node only') end
local raw = dofile('lua/core/raw_code.lua')
local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end

-- The three shapes the review named must be read as leaks now.
for _, shape in ipairs({
  '<bash>{"command":"ls"}</bash>',
  '<invoke name="read"><parameter name="path">x</parameter></invoke>',
  '<run>return 1</run>',
  '<|DSML|invoke name="bash">',
  '<tool_call>{"name":"bash"}</tool_call>',
}) do
  ok(raw.markup_in_text(shape) ~= nil, 'a leaked shape is named: ' .. shape)
end

-- Prose is still an answer, and a marker inside a fence is a sample.
ok(raw.markup_in_text('I read the file; it had 400 rows and 7 columns.') == nil,
  'plain prose is not a leak')
ok(raw.markup_in_text('The output said "use <bash> to run it" in a sentence.') == nil,
  'a marker with no closing shape in running prose is not read as a call')

-- And through the real pathway: a native turn whose text is call markup and whose calls are empty.
local result = { content = '<bash>{"command":"ls"}</bash>', tool_calls = {}, finish_reason = 'stop' }
local policy = dofile('lua/core/codemode_policy.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local sid = memory.start_session('', 'leak', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
policy.pin(memory, 'master', ctx)
local entry = raw.take(result, false, ctx.codemode_policy)
ok(entry ~= nil and entry.leaked_markup == true,
  'take() reports the leak on a native turn: ' .. tostring(entry and entry.leaked_markup))
ok(tostring(entry.marker):find('bash', 1, true) ~= nil, 'and names the marker')
print('leak net ok (' .. checks .. ' checks)')

