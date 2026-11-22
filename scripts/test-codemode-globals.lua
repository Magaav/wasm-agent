-- A script that reaches for a well-known global gets an ANSWER, not a bare ReferenceError (Victor 22/11,
-- from a turn note: "the codemode sandbox has no Buffer/btoa, so my first attempt to ship a patch file to
-- the peer died with ReferenceError: Buffer is not defined").
--
-- What this row pins, and why each one is here:
--   * \`btoa\`/\`atob\` exist and are the standard two (lua/core/codemode_harness.lua): one character per
--     byte, and text above U+00FF gets the UTF-8 route in its own message;
--   * \`sleep(ms)\` is a real pause, answered by the loop in the host, so it is not charged to the
--     script's computing budget, and it is capped (lua/core/codemode.lua, \`SLEEP_MS_MAX\`);
--   * a ReferenceError for a name in the allow-list gets the way that exists here instead of "Change line
--     N" (the measured reach: setTimeout 40, Buffer 17, HOME 16, location 12, require 6 over the retained
--     ledger); a name OUTSIDE the list keeps the generic sentence;
--   * the trailing sentence is printed once, not twice (a nested refusal carries one out).
--
-- Hermetic: its own scratch home, and it refuses to run against a live one. Every script it runs is local.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'sandbox globals', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function run(code) return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx) end
local function shown(result)
  return json.encode({ ok = result.ok, code = result.code, error = tostring(result.error):sub(1, 240),
    fix = tostring(result.fix):sub(1, 400), line = result.line, value = result.value }):sub(1, 800)
end
local function value_of(result) return tostring(result.value):gsub('^"', ''):gsub('"$', '') end
local function occurrences(text, needle)
  local count = 0
  local at = 1
  while true do
    local found = text:find(needle, at, true)
    if not found then return count end
    count = count + 1; at = found + #needle
  end
end

-- 1. btoa/atob: the standard two, and the exact answer Victor checks by hand.
local r = run('return btoa("hi")')
check(r.ok == true and value_of(r) == 'aGk=', 'btoa("hi") answers aGk=: ' .. shown(r))
r = run('return atob("aGk=")')
check(r.ok == true and value_of(r) == 'hi', 'atob("aGk=") answers hi: ' .. shown(r))
-- Padding and a length that is not a multiple of three, so the '=' branch is exercised.
r = run('return [btoa("a"), btoa("ab"), btoa("abc"), atob("YQ=="), atob("YWI="), atob("YWJj")].join(",")')
check(r.ok == true and value_of(r) == 'YQ==,YWI=,YWJj,a,ab,abc', 'one and two bytes pad, three do not: ' .. shown(r))
-- The standard is one character per byte, and the message for text above U+00FF names the UTF-8 route
-- instead of throwing an anonymous error.
r = run('return btoa("café")')
check(r.ok == true and value_of(r) == 'Y2Fm6Q==', 'one character per byte, so é is one byte here: ' .. shown(r))
r = run('return atob(btoa(unescape(encodeURIComponent("café"))))')
check(r.ok == true and value_of(r) == 'cafÃ©', 'and reading it back is the inverse: ' .. shown(r))
r = run('return btoa("中")')
check(r.ok == false and tostring(r.error):find('encodeURIComponent', 1, true) ~= nil,
  'text above U+00FF says the UTF-8 route: ' .. shown(r))
r = run('return atob("not base64!")')
check(r.ok == false and tostring(r.error):find('base64 text', 1, true) ~= nil,
  'atob on text that is not base64 says so: ' .. shown(r))

-- 2. sleep(ms): a real pause, in the host, capped.
r = run('const t0=Date.now(); const s=await sleep(150); return {ms:Date.now()-t0, slept:s.slept_ms};')
check(r.ok == true and tostring(r.value):find('"slept":150', 1, true) ~= nil, 'sleep(150) reports what it slept: ' .. shown(r))
local ms = tonumber(tostring(r.value):match('"ms":(%d+)') or '')
check(ms ~= nil and ms >= 120, 'sleep(150) really paused (Date.now moved by ' .. tostring(ms) .. ' ms): ' .. shown(r))
r = run('await sleep(9000); return "slept";')
check(r.ok == false and tostring(r.code) == 'codemode_sleep_too_long'
  and tostring(r.fix):find('wait_s', 1, true) ~= nil, 'sleep past the cap names wait_s instead: ' .. shown(r))
r = run('await sleep("soon"); return "slept";')
check(r.ok == false and tostring(r.code) == 'codemode_sleep_requires_milliseconds',
  'sleep that is not given milliseconds is refused by name: ' .. shown(r))

-- 3. A missing global in the allow-list names the way that exists here.
r = run('const b = Buffer.from("x");\nreturn b;')
check(r.ok == false and tostring(r.code) == 'ReferenceError', 'Buffer is still a ReferenceError: ' .. shown(r))
check(tostring(r.fix):find('There is no Buffer in this sandbox', 1, true) ~= nil
  and tostring(r.fix):find('raw.script', 1, true) ~= nil
  and tostring(r.fix):find('capability: "write"', 1, true) ~= nil
  and tostring(r.fix):find('btoa', 1, true) ~= nil, 'and its fix names the body route, the peer write and btoa: ' .. shown(r))
check(r.line == 1, 'and the line it happened on: ' .. shown(r))
r = run('setTimeout(() => {}, 10);\nreturn "done";')
check(tostring(r.fix):find('await sleep(ms)', 1, true) ~= nil, 'setTimeout names sleep: ' .. shown(r))
r = run('return HOME;')
check(tostring(r.fix):find('printenv HOME', 1, true) ~= nil, 'HOME names the command that reads it: ' .. shown(r))
r = run('const x = require("fs");\nreturn x;')
check(tostring(r.fix):find('This is not Node', 1, true) ~= nil, 'require says this is not Node: ' .. shown(r))
r = run('return location.href;')
check(tostring(r.fix):find('There is no browser in a script', 1, true) ~= nil, 'location says there is no browser: ' .. shown(r))
r = run('return fetch("http://example.invalid");')
check(tostring(r.fix):find('curl -s', 1, true) ~= nil, 'fetch names the command that can: ' .. shown(r))
-- A name the allow-list does not hold keeps the generic sentence: nothing here can guess what a script
-- meant by its own typo.
r = run('return wt.value;')
check(tostring(r.fix):find('Change line 1 and run the script again.', 1, true) ~= nil,
  'a name nobody can explain keeps "Change line N": ' .. shown(r))

-- 4. The trailing sentence is printed ONCE: a nested refusal carries one out, and the outer sentence used
-- to append a second (measured: "... run the script again. No call had succeeded yet. No call had
-- succeeded yet.").
r = run('await tools.run({code: "const a = ;"});')
local fix = tostring(r.fix)
check(r.ok == false and tostring(r.error):find('^tools%.run failed: SyntaxError') ~= nil,
  'a nested run refusal is unwrapped: ' .. shown(r))
check(occurrences(fix, 'No call had succeeded yet.') == 1,
  'and "No call had succeeded yet." is printed once (' .. occurrences(fix, 'No call had succeeded yet.') .. '): ' .. shown(r))

print(json.encode({ ok = true, checks = checks }))