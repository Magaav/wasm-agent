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
-- 3b. TIMERS (27/11): the largest missing-global class. Measured over 7 days of retained run results:
-- 91 `ReferenceError: setTimeout is not defined`, and of the 36 whose script was recoverable, 27 wrote
-- `await new Promise(r => setTimeout(r, ms))`. Every timer runs on the one pause the host answers
-- (`sleep`), so a wait spends none of the script's budget, and nothing is promoted to a job silently.
r = run('const t0=Date.now(); await new Promise(res => setTimeout(res, 60)); return Date.now()-t0;')
check(r.ok == true and (tonumber((value_of(r))) or 0) >= 50,
  'await new Promise(r => setTimeout(r, 60)) really pauses: ' .. shown(r))
r = run('let seen=""; setTimeout(() => { seen="callback"; }, 10); await sleep(40); return seen;')
check(r.ok == true and value_of(r) == 'callback', 'setTimeout(fn, ms) runs the callback: ' .. shown(r))
r = run('let seen="never"; const id=setTimeout(() => { seen="fired"; }, 20); clearTimeout(id); await sleep(60); return seen;')
check(r.ok == true and value_of(r) == 'never', 'clearTimeout stops it: ' .. shown(r))
r = run('let n=0; const id=setInterval(() => { n++; }, 10); await sleep(80); clearInterval(id); return n;')
check(r.ok == true and (tonumber((value_of(r))) or 0) >= 2, 'setInterval repeats and clearInterval stops it: ' .. shown(r))
r = run('await new Promise(res => setImmediate(res)); return "immediate";')
check(r.ok == true and value_of(r) == 'immediate', 'setImmediate is a zero-delay timer: ' .. shown(r))
r = run('setTimeout("not a function", 10); return "done";')
check(r.ok == false and tostring(r.error):find('setTimeout takes a function', 1, true) ~= nil,
  'setTimeout with something else says the shape: ' .. shown(r))
-- The ceiling an uncleared interval really meets in a script: one pause is 5 s and a script pauses 30 s in
-- total (lua/core/codemode.lua), so a repeating timer that nobody clears is stopped by that budget and its
-- line names clearInterval AND the call that makes the work outlive the script. 30 s of real waiting, so
-- it is the slow half.
if os.getenv('WA_TIMERS_SLOW') == '1' then
  local began = os.time()
  r = run('let n=0; setInterval(() => { n++; }, 5000); await sleep(5000); await sleep(5000); await sleep(5000); await sleep(5000); await sleep(5000); await sleep(5000); return n;')
  check(r.ok == false and tostring(r.code) == 'codemode_sleep_total_too_long', 'the script pause budget stops it (' .. (os.time() - began) .. ' s): ' .. shown(r))
end
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

-- 5. ONE pause budget (Victor 27/11): there is no sleep limit and no timer limit of their own. sleep,
-- every timer built on it and wait(op) read lua/core/codemode_pending.lua's two numbers - the per-pause
-- ceiling (PAUSE_MS_MAX) and the budget a script may pause in total (MAX_WAIT_S). This row changes them
-- in the fixture and watches BOTH move, which is the contract the follow-up asks for: one edit, no other
-- file touched, sleep and timers answer the new numbers.
local pending = dofile('lua/core/codemode_pending.lua')
local pause_was, budget_was = pending.PAUSE_MS_MAX, pending.MAX_WAIT_S
check(tonumber(pause_was) ~= nil and tonumber(budget_was) ~= nil, 'the shared numbers live in codemode_pending')
pending.PAUSE_MS_MAX, pending.MAX_WAIT_S = 1000, 12
r = run('await sleep(1500); return "slept";')
check(r.ok == false and tostring(r.code) == 'codemode_sleep_too_long',
  'the shared per-pause number refuses sleep(1500) at 1 s: ' .. shown(r))
r = run('const t0=Date.now(); await new Promise(res => setTimeout(res, 1500)); return Date.now()-t0;')
check(r.ok == true and (tonumber((value_of(r))) or 9999) < 1300,
  'and the SAME number clamps a timer to it (a timer has no limit of its own): ' .. shown(r))
-- The budget case needs the real per-pause ceiling, so only the total moves here.
pending.PAUSE_MS_MAX, pending.MAX_WAIT_S = 5000, 12
r = run('const a=Date.now(); await sleep(5000); await sleep(5000); await sleep(5000); return Date.now()-a;')
check(r.ok == false and tostring(r.code) == 'codemode_sleep_total_too_long',
  'three 5 s sleeps pass a 12 s shared budget and the third is refused: ' .. shown(r))
r = run('let n=0; setInterval(() => { n++; }, 5000); await sleep(5000); await sleep(5000); await sleep(5000); return n;')
check(r.ok == false and tostring(r.code) == 'codemode_sleep_total_too_long',
  'and a timer loop meets the same budget, not a timer one: ' .. shown(r))
pending.PAUSE_MS_MAX, pending.MAX_WAIT_S = pause_was, budget_was

-- 6. A sleeping script is still a cancelled one: the loop checks the run between two calls, so the
-- cancel arrives at the next iteration instead of after the last sleep.
local real_cancel = host.run_cancelled
local asked = 0
local swapped = pcall(function() host.run_cancelled = function() asked = asked + 1; return json.encode({ cancelled = asked > 2 }) end end)
if swapped and host.run_cancelled ~= real_cancel then
  r = run('await sleep(200); await sleep(200); await sleep(200); return `done`;')
  check(r.ok == false and tostring(r.error):find('run_cancelled', 1, true) ~= nil,
    'a cancelled run ends a script that is sleeping: ' .. shown(r))
  check(asked >= 2, 'and the loop asked between the sleeps (' .. asked .. ' times)')
  pcall(function() host.run_cancelled = real_cancel end)
else
  pcall(function() host.run_cancelled = real_cancel end)
  print('SKIP codemode-globals: this node does not let a test replace host.run_cancelled, so cancellation between two sleeps cannot be driven here')
end

print(json.encode({ ok = true, checks = checks }))