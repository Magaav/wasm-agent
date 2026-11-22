-- THE TWO NOTES A SCRIPT CARRIES BESIDE ITS ANSWER KEEP THE PLAIN FORM (22/11).
--
-- A run result can carry pending_backgrounded (the calls this script stopped waiting for) and
-- pending_settled (handles that settled while nobody waited) - lua/core/codemode.lua adds both after the
-- script ends. They were ordinary keys, so a result carrying either could not be plain: it was sent to the
-- model as a JSON object with the output as an ESCAPED STRING. Measured on the real ledger before this
-- change: 673 of 3,131 results (21%) were that object. What replaced it is one header line per note,
-- 'pending: <what> <the key own JSON>', above a plain body, read back by lua/core/tool_output.lua's
-- parse_view; a note too large for a header keeps the JSON form rather than losing a field.
-- Real sandbox, real handles, its own scratch home; no model and no network.
local json = dofile('lua/vendor/json.lua')
local env = host.getenv
host.getenv = function(k) if k == 'WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local codemode = dofile('lua/core/codemode.lua')
local output = dofile('lua/core/tool_output.lua')
local checks = 0
local function check(value, label) if not value then error('FAIL: ' .. label, 2) end checks = checks + 1 end
local ready = false
if type(host.quickjs) == 'function' then
  local ok, answer = pcall(host.quickjs, 'ready', '{}')
  if ok then local decoded = json.decode(answer); ready = type(decoded) == 'table' and decoded.ok == true end
end
assert(ready, 'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
-- A scratch home of this row's own, and a refusal to run anywhere else: this row writes handles to disk.
local home = tostring(host.getenv('HOME') or '')
local data = dofile('lua/core/paths.lua').data()
assert(home ~= '' and not home:match('/%.wasm%-agent$') or data:find('scratch', 1, true) or data:find('/tmp/', 1, true) or data:find('wa%-test', 1, true),
  'this row needs a scratch HOME (it writes pending-handle indexes); it refused to run in ' .. tostring(data))
local sid = memory.start_session('', 'pending header', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
local catalog = tools.all('master', ctx, memory)
local execution = tools.discovery_execution(memory, ctx)
local function dispatch(name, params, raw) return tools.dispatch(memory, name, params, 'master', ctx, raw) end
local function script(code)
  return codemode.run(memory, { code = code }, 'master', ctx, catalog, function() return catalog end, dispatch, execution)
end

-- 1. A script that stops waiting leaves its call running: the note is a header line, the body is plain.
local left = script([[const s = await tools.bash({command: 'sleep 1; echo later', wait_s: 0}); return {op: s.op};]])
check(type(left) == 'table' and left.ok == true, 'the script ran: ' .. tostring(left and (left.error or left.message)))
check(type(left.pending_backgrounded) == 'table' and type(left.pending_backgrounded.ops) == 'table'
  and #left.pending_backgrounded.ops == 1,
  'the result carries pending_backgrounded with the handle it left: ' .. json.encode(left.pending_backgrounded or {}))
local op = tostring(left.pending_backgrounded.ops[1])
local view = output.project('run', left)
check(view:match('^status 200'), 'the view opens with the status line, not a JSON envelope: ' .. view:sub(1, 160))
check(view:find('\npending: backgrounded {', 1, true) ~= nil, 'the note is a header line: ' .. view:sub(1, 400))
check(not view:find('"pending_backgrounded"', 1, true), 'and no longer a JSON key of the envelope')
local calls_at, pending_at = view:find('\ncalls: ', 1, true), view:find('\npending: ', 1, true)
check(calls_at and pending_at and calls_at < pending_at, 'the note comes after the calls: line, as the reader expects')
check(view:find('\n\n{"op":"' .. op .. '"}', 1, true) ~= nil, 'the body is still the script own text, unescaped: ' .. view:sub(-200))
-- The ledger row a later turn reads IS this view: the loop stores what project produced, and
-- context_view sends a stored view under the budget byte for byte (what "the result row starts with
-- status 200" means when an operator looks at it in the ledger).
check(output.context_view('run', view) == view, 'the stored view is sent byte for byte on the next turn')
local parsed = output.parse_view(view)
check(type(parsed) == 'table' and type(parsed.pending_backgrounded) == 'table'
  and parsed.pending_backgrounded.count == left.pending_backgrounded.count
  and parsed.pending_backgrounded.ops[1] == op,
  'parse_view reads the note back: ' .. json.encode(parsed and parsed.pending_backgrounded or {}))

-- 2. The handle settles while nobody waits: the NEXT script is told, in the same shape and just as plainly.
if host.sleep then host.sleep(2600) else dispatch('bash', { command = 'sleep 2.6' }) end
local after = script('return {done: true};')
check(type(after.pending_settled) == 'table' and #after.pending_settled >= 1,
  'the settled handle is announced: ' .. json.encode(after.pending_settled or {}))
local row
for _, entry in ipairs(after.pending_settled) do if entry.op == op then row = entry end end
check(row ~= nil and row.state == 'done' and row.stdout == 'later\n' and row.code == 0 and type(row.result_sha256) == 'string',
  'the announced row is the answer itself, with its retained hash: ' .. json.encode(row or {}))
local settled_view = output.project('run', after)
check(settled_view:match('^status 200'), 'the announcing result keeps the plain form too: ' .. settled_view:sub(1, 160))
check(settled_view:find('\npending: settled [', 1, true) ~= nil, 'with its own header line: ' .. settled_view:sub(1, 600))
check(not settled_view:find('\\"', 1, true), 'and nothing in it is an escaped string')
check(output.context_view('run', settled_view) == settled_view, 'and so is the announcing view')
local settled_parsed = output.parse_view(settled_view)
local back
for _, entry in ipairs(type(settled_parsed.pending_settled) == 'table' and settled_parsed.pending_settled or {}) do
  if entry.op == op then back = entry end
end
check(back ~= nil and back.stdout == 'later\n' and back.state == 'done' and back.result_sha256 == row.result_sha256,
  'parse_view reads the settled row back whole: value and retained hash: ' .. json.encode(back or {}))
check(type(settled_parsed.returned) == 'table' and settled_parsed.returned.done == true,
  'and the body after the notes still parses as what the script returned: ' .. json.encode(settled_parsed.returned or {}))

-- 3. A note too large for a header keeps the JSON form: nothing is dropped to win the plain shape.
local big = { ok = true, status = 200, summary = 'bash 200', returned = 'x', calls = {},
  pending_backgrounded = { count = 1, ops = { 'op-big' }, detail = string.rep('y', 5000) } }
local big_view = output.project('run', big)
local big_decoded = json.decode(big_view)
check(type(big_decoded) == 'table' and type(big_decoded.pending_backgrounded) == 'table'
  and #big_decoded.pending_backgrounded.detail == 5000,
  'an oversized note keeps every field, in the JSON form: ' .. tostring(big_view):sub(1, 200))
check(not tostring(big_view):find('pending: backgrounded', 1, true), 'and is not half-written as a header line')

print(json.encode({ ok = true, checks = checks }))
print('run-pending-header ok (' .. checks .. ' checks)')
