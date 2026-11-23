-- A BODY IS NEVER SILENTLY ALTERED (23/11, ledger notes 83 and 116).
--
-- MEASURED FIRST, on this node, before anything here was written: a body holding a LITERAL backslash-n
-- went through tools.write and arrived as the four characters it was (`od -c`: `A \ n B`), and the same
-- body carried in a run call's raw block arrived byte for byte too. So the harness does not decode
-- anything on the way in - the double decoding those notes report happens in the MODEL's own string
-- literal, one layer above, where the harness never sees the pre-decoding text and cannot undo it. What
-- the harness CAN see is the file after the write, and that is what this row pins: the bytes land as
-- sent, and a write that does not leave those bytes in the file is a refusal whose effect is unknown -
-- never an ok:true over a file nobody checked.
--
-- Hermetic: its own scratch home (the guard refuses the real one), no network, no model. The failure is
-- simulated by wrapping host.write_file for the duration of one call, which is the only honest way to
-- make a filesystem write wrong on purpose.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local json = dofile('lua/vendor/json.lua')

local function refuse(why) print('REFUSED test-write-body-bytes: ' .. why); os.exit(2) end
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-write-body-bytes')
if why_home then refuse(why_home) end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local file_tools = dofile('lua/core/file_tools.lua')

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

local dir = host.getenv('WASM_AGENT_HOME') .. '/bodies'
local made = tools.dispatch(memory, 'bash', { command = 'mkdir -p ' .. dir }, 'master', { user_id = 'master' })
check(made.ok == true, 'the scratch directory exists: ' .. json.encode(made))
local target = dir .. '/body.txt'

-- 1. THE BYTES LAND AS SENT. A body that is the exact text the model meant: a literal backslash followed
--    by n (the two characters), a real newline, a backtick and a dollar-brace, none of them re-decoded.
local BS = string.char(92)
local TICK = string.char(96)
local D = string.char(36)
local body = 'A' .. BS .. 'nB\nC ' .. TICK .. 'x' .. TICK .. ' ' .. D .. '{y}'
local wrote = tools.dispatch(memory, 'write', { path = target, content = body }, 'master', { user_id = 'master' })
check(type(wrote) == 'table' and wrote.ok == true, 'the write is accepted: ' .. json.encode(wrote))
check(host.read_file(target) == body, 'the file holds the bytes the script held, byte for byte')
check(#host.read_file(target) == #body, 'and its length is the length sent (' .. #body .. ')')
check(host.read_file(target):find('A' .. BS .. 'nB', 1, true) ~= nil,
  'the literal backslash-n is still two characters, not a newline')

-- 2. A WRITE THAT DOES NOT LAND THOSE BYTES IS A REFUSAL. The writer is wrapped for one call: it writes
--    all but the last three bytes and reports success, which is a short write nobody would notice.
local real_write = host.write_file
host.write_file = function(path, content)
  local half = type(content) == 'string' and content:sub(1, math.max(0, #content - 3)) or content
  return real_write(path, half)
end
local short, short_error = pcall(tools.dispatch, memory, 'write',
  { path = dir .. '/short.txt', content = 'the whole body this call sent' }, 'master', { user_id = 'master' })
host.write_file = real_write
local shorted = short and short_error or nil
check(shorted ~= nil, 'the short write came back with an answer, not an exception: ' .. tostring(short_error))
check(shorted.ok ~= true, 'and that answer is not a success: ' .. json.encode(shorted))
check(shorted.error == 'write_mismatch', 'it is a write_mismatch: ' .. tostring(shorted.error))
check(tostring(shorted.effect) == 'unknown', 'and it says the effect is unknown, not none: ' .. tostring(shorted.effect))
check(tostring(shorted.note):find('byte', 1, true) ~= nil, 'the note names the byte where they differ: ' .. tostring(shorted.note))
check(tostring(shorted.note):find('does not hold the bytes', 1, true) ~= nil, 'and says what is wrong plainly: ' .. tostring(shorted.note))

-- 3. THE SAME RULE ON THE EDIT PATH, which every edit and mutation batch passes through (file_tools.apply).
local edit_target = dir .. '/edit.txt'
host.write_file(edit_target, 'one two three')
local plan = { path = edit_target, before = 'one two three', after = 'one TWO three', result = { ok = true } }
host.write_file = function(path, content)
  local half = type(content) == 'string' and content:sub(1, 4) or content
  return real_write(path, half)
end
local applied = file_tools.apply(plan, nil)
host.write_file = real_write
check(applied.applied ~= true, 'an edit whose text did not land is not reported as applied: ' .. json.encode(applied))
check(applied.error == 'write_mismatch', 'it is a write_mismatch too: ' .. tostring(applied.error))
check(tostring(applied.outcome) == 'unknown', 'and its outcome is unknown: ' .. tostring(applied.outcome))

-- 4. AND WHEN THE WRITE IS RIGHT, THE EDIT STILL APPLIES: the guard refuses corruption, not edits.
local okplan = { path = edit_target, before = host.read_file(edit_target), after = 'one TWO three', result = { ok = true } }
local clean = file_tools.apply(okplan, nil)
check(clean.applied == true, 'an edit whose text landed is applied: ' .. json.encode(clean))
check(host.read_file(edit_target) == 'one TWO three', 'and the file holds the edited text')

print(json.encode({ ok = true, checks = checks }))
print('write-body-bytes ok (' .. checks .. ' checks)')
