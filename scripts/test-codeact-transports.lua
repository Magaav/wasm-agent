-- The two CodeAct transports (docs/AGENT-SEAT.md, principle 2): a fenced run block in the answer and
-- a native run({code, raw?}) tool call are ONE pathway. Each becomes the same codemode call, and the
-- results come back the same way. Nothing here calls a provider: the dispatch is the node's own.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local tools = dofile('lua/core/tools.lua')
local policy = dofile('lua/core/codemode_policy.lua')
local raw = dofile('lua/core/raw_code.lua')

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format('%s\n  got:  %s\n  want: %s', what, tostring(got), tostring(want)))
  end
end
local function has(haystack, needle, what)
  checks = checks + 1
  if not string.find(tostring(haystack), needle, 1, true) then
    error(string.format('%s: %q does not contain %q', what, tostring(haystack), needle))
  end
end

local sid = memory.start_session('', 'codeact transports', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
policy.pin(memory, 'master', ctx)
assert(policy.enforced(ctx), 'code mode must be enabled for this test')

-- ------------------------------------------------------------------ the native run call
local plain = assert(raw.native_run({ code = 'return 1' }))
eq(plain.code, 'return 1', 'a run call with no raw is its code, unchanged')

local no_code, why = raw.native_run({})
eq(no_code, nil, 'a run call with no code is refused')
eq(why.error, 'run_needs_code', 'the refusal is named')

local not_object, why2 = raw.native_run({ code = 'x', raw = 'a string' })
eq(not_object, nil, 'raw must be an object')
eq(why2.error, 'run_raw_not_object', 'the refusal is named')

local bad_name, why3 = raw.native_run({ code = 'x', raw = { ['not a name'] = 'y' } })
eq(bad_name, nil, 'a raw name that is not an identifier is refused')
eq(why3.error, 'run_raw_name', 'the refusal is named')

local bad_text, why4 = raw.native_run({ code = 'x', raw = { body = 42 } })
eq(bad_text, nil, 'a raw value that is not text is refused')
eq(why4.error, 'run_raw_not_text', 'the refusal is named')

-- Bytes travel exactly (principle 4): a file body full of quotes, backslashes and newlines survives
-- the one JSON encode and comes back byte for byte, because the script reads a string, not code.
local tricky = 'a\\b"c\nd\te\r\0f'
local carried = assert(raw.native_run({ code = 'return __raw.body.length', raw = { body = tricky } }))
eq(carried.raw_blocks[1], 'body', 'the raw block name is reported')
local literal = carried.code:match('^const __raw = (.-);\n')
assert(literal, 'the raw blocks are emitted as one object literal')
eq(json.decode(literal).body, tricky, 'the raw bytes survive exactly')

-- ------------------------------------------------------------------ the tool the model sees
local schema = raw.run_tool_schema()
eq(schema.name, 'run', 'the tool is named run')
eq(schema.schema.required[1], 'code', 'code is required')
-- It is always EXECUTABLE (the catalog is what the principal may run and delegate), and it is
-- declared to the model unless the node's raw-code mode empties the declared surface on purpose
-- (`only`: the block is the only way to act). Both halves are asserted, so neither is assumed.
local in_catalog = false
for _, item in ipairs(tools.catalog('master')) do
  if item['function'] and item['function'].name == 'run' then in_catalog = true end
end
eq(in_catalog, true, 'the run tool is in the catalog')
local raw_mode = dofile('lua/core/raw_code.lua')
local declared = false
for _, item in ipairs(tools.envelope('master', ctx)) do
  if item['function'] and item['function'].name == 'run' then declared = true end
end
if raw_mode.only and raw_mode.only(ctx.codemode_policy) then
  eq(declared, false, 'in the default only mode nothing is declared: the run block is the one way to act')
else
  eq(declared, true, 'outside only mode the run tool is declared to the model')
end
-- Two rows of this table are the whole of principle 2: one action, two transports.
local by_block = { content = '```js run\nreturn 1\n```', tool_calls = {}, finish_reason = 'stop' }
local entry = raw_mode.take(by_block, false, ctx.codemode_policy)
assert(entry, 'a fenced run block became a call')
eq(#by_block.tool_calls, 1, 'the block formed exactly one call')
eq(by_block.tool_calls[1]['function'].name, 'codemode', 'a block is a codemode call')
local via_run = assert(raw_mode.native_run({ code = 'return 1' }))
eq(via_run.code, 'return 1', 'a run call is the same script for the same pathway')
-- And the dispatch really runs it: one real script through the run transport. The node's own
-- read is the effect, so nothing leaves this machine.
local out = tools.dispatch(memory, 'run', { code = 'const r = await tools.read({path:"/etc/hostname"}); return {n:(r.content||"").length}' }, 'master', ctx)
eq(out.ok, true, 'the run transport executed a real script: ' .. json.encode(out):sub(1, 300))
-- The script's own return value comes back as `value` (the model-facing shape of a codemode call).
local returned = json.decode(out.value or '{}')
assert(tonumber(returned.n) and tonumber(returned.n) > 0, 'the script read a real file')
-- A run call with no code is refused by name, before anything runs.
local refused = tools.dispatch(memory, 'run', {}, 'master', ctx)
eq(refused.error, 'run_needs_code', 'an empty run call is refused by name')
-- raw blocks travel exactly: the script reads the bytes as a value, never as code.
local body = 'line one\nline "two"\\three'
local exact = tools.dispatch(memory, 'run', { code = 'return __raw.body.length', raw = { body = body } }, 'master', ctx)
eq(exact.ok, true, 'a run call with raw blocks executes: ' .. json.encode(exact):sub(1, 300))
eq(tonumber(exact.value), #body, 'the raw body arrived byte for byte')

print('codeact transports ok (' .. checks .. ' checks)')
