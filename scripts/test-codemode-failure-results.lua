-- A BLOCK THAT STOPS STILL HANDS BACK WHAT IT FINISHED (25/11, item 3 of this mission).
--
-- MEASURED before this change: a script that ran a command and then hit a failing call answered only the
-- error and a sentence that named the command ("Already done, not undone: bash"). The command's own output
-- was in this node's evidence store and nowhere the model could see it without already knowing its hash,
-- so the model re-ran work that had already finished - and a command is not always repeatable. A failed
-- block now carries `done`: one entry per call that settled, in the order the script made them, with the
-- answer each produced.
--
-- What this row pins, and why each one is here:
--   * a HEALTHY block gains nothing: no `done`, no `done_note`, and the same keys it answered with
--     before this change (a healthy call's answer must not move a byte);
--   * a failed block lists every settled call IN ORDER, with the first one's own stdout in the answer,
--     the failing call's own refusal beside it, and the failure sentence unchanged ("Already done, not
--     undone: ..." still names the calls that ran - that is the line the reader already parses);
--   * an answer too large for the block is a POINTER, never a silent cut: the entry carries
--     `unread {sha256, offset, bytes}` and tool_result(sha256) reads it back - proved here by reading it.
--
-- Hermetic: its own scratch home, and it refuses to run against a live one. Every command it runs is local.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'failure results', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function run(code) return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx) end
local function shown(result)
  return json.encode({ ok = result.ok, code = result.code, error = tostring(result.error):sub(1, 200),
    fix = tostring(result.fix):sub(1, 240), value = tostring(result.value):sub(1, 200) }):sub(1, 900)
end
local function text_of(value) return value == nil and '' or json.encode(value) end

-- 1. A HEALTHY BLOCK: the answer it has always given, and nothing of this change in it.
local healthy = run('const t = await tools.time({}); return t.now;')
check(healthy.ok == true, 'the healthy block runs: ' .. shown(healthy))
local keys = {}
for key in pairs(healthy) do keys[#keys + 1] = key end
table.sort(keys)
check(table.concat(keys, ',') == 'attempts,backend,calls,context_policy,items,ok,status,summary,unexecuted,value',
  'a healthy block answers with the same keys it did before this change: ' .. table.concat(keys, ','))
check(healthy.done == nil and healthy.done_note == nil,
  'and gains no done block: ' .. json.encode({ done = healthy.done, note = healthy.done_note }))

-- A healthy block that RUNS A COMMAND keeps nothing extra either: the change is only for a block that failed.
local healthy_bash = run('const a = await tools.bash({command:"echo a healthy block"}); return a.ok;')
check(healthy_bash.ok == true and healthy_bash.done == nil,
  'a healthy block with a finished command gains no done block: ' .. shown(healthy_bash))

-- 2. A FAILED BLOCK: every settled call, in order, with its answer - and the failure sentence unchanged.
local failed = run(table.concat({
  'const a = await tools.bash({command:"echo finished-before-the-error"});',
  'const b = await tools.read({path:"/nonexistent/zz"});',
  'return b;',
}, '\n'))
check(failed.ok == false, 'the block failed: ' .. shown(failed))
local done = failed.done
check(type(done) == 'table' and #done == 2,
  'both calls that settled are listed: ' .. text_of(done):sub(1, 600))
check(done[1].n == 1 and done[1].id == 1 and done[1].name == 'bash' and done[1].ok == true,
  'the command came first, and is marked as having succeeded: ' .. text_of(done[1]):sub(1, 400))
check(text_of(done[1].result):find('finished-before-the-error', 1, true) ~= nil,
  "and the command's OWN output is in the answer, not only its name: " .. text_of(done[1].result):sub(1, 600))
check(done[2].n == 2 and done[2].name == 'read' and done[2].ok == false,
  'the call that failed follows it: ' .. text_of(done[2]):sub(1, 400))
check(text_of(done[2].result):find('read_file_missing', 1, true) ~= nil,
  "and carries the failure's own answer: " .. text_of(done[2].result):sub(1, 400))
check(type(failed.done_note) == 'string' and failed.done_note:find('in order', 1, true) ~= nil,
  'the block says what done is: ' .. tostring(failed.done_note):sub(1, 200))
-- The failure sentence itself is unchanged: the reader that already parses it keeps working.
check(tostring(failed.fix):find('Already done, not undone: bash', 1, true) ~= nil,
  'the fix still names the call that ran: ' .. tostring(failed.fix):sub(1, 300))
check(tostring(failed.error):find('^tools%.read failed') ~= nil,
  'and the error is the failing call, as it was: ' .. tostring(failed.error):sub(1, 200))

-- 3. AN ANSWER TOO LARGE FOR THE BLOCK IS A POINTER THAT READS BACK.
local big = run(table.concat({
  'const a = await tools.bash({command:"seq 1 3000"});',
  'const b = await tools.read({path:"/nonexistent/zz"});',
  'return b;',
}, '\n'))
check(big.ok == false and type(big.done) == 'table' and #big.done == 2,
  'the big block failed and lists both calls: ' .. shown(big))
local pointer = big.done[1]
check(pointer.unread ~= nil and type(pointer.unread.sha256) == 'string'
  and #pointer.unread.sha256 == 64 and (pointer.unread.bytes or 0) > 1200,
  'an answer too large for the block is a reference with its size: ' .. text_of(pointer):sub(1, 400))
check(pointer.result == nil, 'and not a silently cut copy of it')
-- The LAST page of that result, so what is read back is the end of the command's own output: a cut
-- copy of a big answer would have lost exactly this.
local read_back = tools.dispatch(memory, 'tool_result',
  { sha256 = pointer.unread.sha256, offset = math.max(1, pointer.unread.bytes - 200), limit = 400 }, 'master', ctx)
check(type(read_back) == 'table' and read_back.sha256 == pointer.unread.sha256
    and tostring(read_back.content or ''):find('3000', 1, true) ~= nil,
  'tool_result reads the pointer back to its last byte, so nothing was lost: '
    .. tostring(json.encode(read_back)):sub(1, 400))

print(json.encode({ ok = true, checks = checks, done_entries = #done }))
