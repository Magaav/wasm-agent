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

print(dofile('lua/vendor/json.lua').encode({ ok = true, checks = checks }))
print('run-syntax-fix ok (' .. checks .. ' checks)')
