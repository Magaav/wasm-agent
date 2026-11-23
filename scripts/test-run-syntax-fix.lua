-- THE FAILURE LINE FOR A SCRIPT THAT DOES NOT COMPILE NAMES THE CAUSE AND THE WAY OUT (22/11).
--
-- Measured on the two days before on this node: about 35 compile failures - the biggest single failure
-- class, half of every failure - and the fix line said only "Change line N", which names WHERE and not WHY.
-- The three shapes below are taken from the real ledger (a shell value inside a template, a backtick
-- inside a template, a stray backtick after the code): all three are one cause - shell text inside a
-- JavaScript string - and the way out is the run tool's raw argument, where the bytes never pass through
-- JavaScript at all. Real sandbox, its own scratch home; no model and no network.
local env = host.getenv
host.getenv = function(k) if k == 'WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local codemode = dofile('lua/core/codemode.lua')
local checks = 0
local function check(value, label) if not value then error('FAIL: ' .. label, 2) end checks = checks + 1 end
local ready = false
if type(host.quickjs) == 'function' then
  local ok, answer = pcall(host.quickjs, 'ready', '{}')
  if ok then local decoded = dofile('lua/vendor/json.lua').decode(answer); ready = type(decoded) == 'table' and decoded.ok == true end
end
assert(ready, 'this node has no embedded code-mode assets, so no script compiled and nothing here was measured')
-- This row writes nothing but its script's own failures; it still refuses to run in the node's own store.
local home = tostring(host.getenv('HOME') or '')
local data = dofile('lua/core/paths.lua').data()
assert(home ~= '' and not home:match('/%.wasm%-agent$') or data:find('scratch', 1, true) or data:find('/tmp/', 1, true) or data:find('wa%-test', 1, true),
  'this row needs a scratch HOME; it refused to run in ' .. tostring(data))
local sid = memory.start_session('', 'syntax fix', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
local catalog = tools.all('master', ctx, memory)
local execution = tools.discovery_execution(memory, ctx)
local function dispatch(name, params, raw) return tools.dispatch(memory, name, params, 'master', ctx, raw) end
local function script(code)
  return codemode.run(memory, { code = code }, 'master', ctx, catalog, function() return catalog end, dispatch, execution)
end
local T = string.char(96)   -- a backtick, so this row's own source needs none
local D = string.char(36)   -- a dollar, for the shell's brace form
local function shape(name, code, expect)
  local r = script(code)
  check(type(r) == 'table' and r.ok == false, name .. ': the script does not compile, and the result says so: ' .. tostring(r and (r.error or r.message)))
  check(r.code == 'SyntaxError', name .. ': it is a SyntaxError: ' .. tostring(r.code))
  check(tostring(r.error):find(expect, 1, true) ~= nil, name .. ': the sandbox own words are kept ("' .. expect .. '"): ' .. tostring(r.error))
  check(tostring(r.fix):find('shell text inside a JavaScript string', 1, true) ~= nil, name .. ': the fix names the cause: ' .. tostring(r.fix))
  check(tostring(r.fix):find('raw.script', 1, true) ~= nil, name .. ': and the way out, by name: ' .. tostring(r.fix))
  check(tostring(r.fix):find('did not compile', 1, true) ~= nil, name .. ': and that nothing ran: ' .. tostring(r.fix))
  check(#tostring(r.fix) <= 600, name .. ': the fix stays inside its 600-byte budget: ' .. #tostring(r.fix))
  check(r.line ~= nil and tostring(r.message):find('line ', 1, true) ~= nil, name .. ': it still names where: ' .. tostring(r.message))
  return r
end

-- 1. A shell value inside a template: the ledger's "expected '}' after template expression".
shape('shell value in a template', 'const sh = String.raw' .. T .. '#!/usr/bin/env bash\nBIN=' .. D .. '{WA_BIN:-wa}\n' .. T .. ';',
  "expected '}' after template expression")
-- 2. A backtick inside a template: the ledger's "expecting ';'".
shape('backtick in a template', 'const body = String.raw' .. T .. '-- a comment with a backtick ' .. T .. ' here\nmore text' .. T .. ';',
  "expecting ';'")
-- 3. A stray backtick after the code: the ledger's "unexpected end of string".
shape('stray backtick', 'const r = await tools.bash({command:' .. T .. 'cd /tmp && echo hi' .. T .. '});\nreturn r.stdout;' .. T .. ';',
  'unexpected end of string')

-- 4. Scoped to its class: a script that RUNS and fails at runtime does not get the compile-failure
--    sentence, so the sentence stays a diagnosis instead of boilerplate on every failure.
local runtime = script('const x = 1; return x.y.z;')
check(type(runtime) == 'table' and runtime.ok == false, 'a runtime failure fails: ' .. tostring(runtime and runtime.error))
check(tostring(runtime.fix):find('shell text inside', 1, true) == nil,
  'a runtime failure does not get the compile-failure sentence: ' .. tostring(runtime.fix))
check(tostring(runtime.error):find('TypeError', 1, true) ~= nil, 'and keeps its own error: ' .. tostring(runtime.error))

-- 5. THE LINE IS THE MODEL'S OWN (23/11). A run call is not compiled as it was written: raw_code.native_run
--    wraps it (one line for the `raw` binding, four when the call carries raw blocks) and the harness adds
--    a prologue - and script_line undid only the prologue. So the answer named a line of the WRAPPED
--    source: reproduced on 23/11 with one raw block, a three-line script was told "Change line 6", a line
--    that script does not have. Measured over the retained ledger: 202 compile failures in the five days
--    to 23/11 13:00Z, and 132 of them arrived after the fix line already named `raw`, so the sentence
--    being there is not the same as the model finding its line.
local raw_code = dofile('lua/core/raw_code.lua')
local function native(code, blocks)
  local call, refused = raw_code.native_run({ code = code, raw = blocks })
  check(call ~= nil, 'the native call is accepted: ' .. tostring(refused and refused.note))
  return codemode.run(memory, call, 'master', ctx, catalog, function() return catalog end, dispatch, execution)
end
local Q = string.char(39)   -- a single quote, so this row's own source needs no escaping
local quoted = 'const a = 1;\nconst s = ' .. Q .. 'hello;\nreturn a;'
local with_raw = native(quoted, { body = 'x' })
check(type(with_raw) == 'table' and with_raw.ok == false,
  'a native call that does not compile fails: ' .. tostring(with_raw and with_raw.error))
check(with_raw.line == 2, 'the line it names is the model own line (2), not a line of the wrapped source (got '
  .. tostring(with_raw.line) .. ')')
check(tostring(with_raw.message):find('line 2', 1, true) ~= nil,
  'and the message says line 2: ' .. tostring(with_raw.message))
check(tostring(with_raw.fix):find('Change line 2', 1, true) ~= nil,
  'and the fix says which line to change: ' .. tostring(with_raw.fix))
--    Without raw blocks the wrapper is one line, which is the shape most calls have.
local plain = native(quoted, nil)
check(plain.line == 2, 'a call with no raw blocks names its own line too (got ' .. tostring(plain.line) .. ')')

-- 6. THREE LINES AROUND IT, MARKED (23/11). One line was shown before, and the cause of "expecting ';'" or
--    "unexpected end of string" is often the line ABOVE - a literal left open - which was never shown at
--    all. The '>' row is the line the sandbox stopped on.
local around = 'const a = 1;\nconst b = 2;\nconst s = ' .. Q .. 'oops;\nreturn a;'
local r3 = native(around, nil)
local msg3 = tostring(r3.message)
check(r3.line == 3, 'the error is on the model line 3 (got ' .. tostring(r3.line) .. '): ' .. msg3)
check(msg3:find('\n 2: const b = 2;', 1, true) ~= nil, 'the line above is shown: ' .. msg3)
check(msg3:find('\n>3: const s = ', 1, true) ~= nil, 'the error line is marked with >: ' .. msg3)
check(msg3:find('\n 4: return a;', 1, true) ~= nil, 'the line below is shown: ' .. msg3)

-- 7. A LONG LINE IS NOT SILENTLY CUT (23/11). 39 of the 202 measured failures showed an offending line cut
--    at exactly 160 characters with nothing said, so the backtick the sentence asks about could sit past the
--    cut and stay invisible. A line too long for the excerpt now says how much it is not showing.
local longline = 'const s = ' .. Q .. string.rep('x', 300) .. ';'
local long = longline .. '\nreturn 1;'
local rlong = native(long, nil)
local msglong = tostring(rlong.message)
check(rlong.line == 1, 'the long line is the one named (got ' .. tostring(rlong.line) .. ')')
check(#longline > 200 and msglong:find(' +' .. (#longline - 200), 1, true) ~= nil,
  'the count of characters not shown is printed (#' .. #longline .. ' - 200): ' .. msglong)

print(dofile('lua/vendor/json.lua').encode({ ok = true, checks = checks }))
print('run-syntax-fix ok (' .. checks .. ' checks)')
