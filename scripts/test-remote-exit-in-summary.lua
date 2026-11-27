-- A REMOTE COMMAND THAT EXITS NON-ZERO MUST NOT LOOK LIKE SUCCESS (refusals-that-help, item (j)).
--
-- MEASURED (the session behind the item): `tools.remote` bash on a peer DID return stderr
-- ("no such column: bucket_id") and process_exit_code 1 - nothing was lost on the wire. But the run line said
-- "status 200 \194\183 remote 200" (the HTTP status, not the exit), and the model's script returned only
-- .stdout, so the error never reached it and an empty stdout read as "no rows".
--
-- What this row pins:
--   1. the per-call summary of a call that exited non-zero says so: `remote 200 exit=1 stderr 33 B`;
--   2. the run's result names that call ONCE with the first line of a stderr the script's own return dropped;
--   3. a script that DID return the stderr gets no note - the line is for dropped evidence, not a banner;
--   4. zero prompt bytes: nothing here is in a prompt or a tool description; the bytes this adds are result
--      bytes, measured below.
--
-- Hermetic: its own scratch home, and the peer call is a stub, so nothing leaves this machine.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local output_view = dofile('lua/core/tool_output.lua')
local sid = memory.start_session('', 'remote exit', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local checks, failed = 0, 0
local function check(ok, message)
  if ok then checks = checks + 1 else failed = failed + 1; print('FAIL ' .. message) end
end

-- The peer's answer, exactly the shape measured: HTTP 200, a non-zero exit, stderr, empty stdout.
local STDERR = 'Error: no such column: bucket_id\n'
local real_dispatch = tools.dispatch
tools.dispatch = function(memory_arg, name, args, ...)
  if name == 'remote' then
    return { status = 200, ok = true, node = 'scratch-peer', capability = 'bash',
      stdout = '', stderr = STDERR, process_exit_code = 1 }
  end
  return real_dispatch(memory_arg, name, args, ...)
end
local function run(code) return real_dispatch(memory, 'codemode', { code = code }, 'master', ctx) end

-- 1. THE MEASURED SCRIPT: it returns only stdout, so the failure was invisible.
local dropped = run('const r = await tools.remote({node:"scratch-peer",capability:"bash",command:"sqlite3 x"}); return r.stdout;')
check(dropped.ok == true, 'the script itself succeeds: ' .. json.encode(dropped):sub(1, 200))
check(type(dropped.summary) == 'string' and dropped.summary:find('remote', 1, true) ~= nil,
  'the summary names the call: ' .. tostring(dropped.summary))
check(type(dropped.summary) == 'string' and dropped.summary:find('exit=1', 1, true) ~= nil,
  'the summary says the command exited 1, not only that the wire said 200: ' .. tostring(dropped.summary))
check(type(dropped.summary) == 'string' and dropped.summary:find('stderr ' .. #STDERR .. ' B', 1, true) ~= nil,
  'and how much stderr there was: ' .. tostring(dropped.summary))
local first_call = type(dropped.calls) == 'table' and dropped.calls[1] or {}
check(first_call.exit == 1 and first_call.stderr_bytes == #STDERR,
  'the call record carries the exit and the stderr size: ' .. json.encode(first_call):sub(1, 200))

-- 2. THE RESULT NAMES THE CALL, with the first line of what the return value dropped.
local shown = output_view.project('codemode', dropped)
check(type(shown) == 'string' and shown:find('note: remote exited 1', 1, true) ~= nil,
  'the model reads which call failed: ' .. tostring(shown):sub(1, 400))
check(type(shown) == 'string' and shown:find('no such column: bucket_id', 1, true) ~= nil,
  'and the first line of its stderr: ' .. tostring(shown):sub(1, 400))

-- 3. A SCRIPT THAT RETURNED THE STDERR GETS NO NOTE (a note for dropped evidence, not a banner).
local kept = run('const r = await tools.remote({node:"scratch-peer",capability:"bash",command:"sqlite3 x"}); return r.stderr;')
local kept_shown = output_view.project('codemode', kept)
check(type(kept_shown) == 'string' and kept_shown:find('note: remote exited', 1, true) == nil,
  'a script that returned the stderr is not warned about it: ' .. tostring(kept_shown):sub(1, 300))
check(type(kept.summary) == 'string' and kept.summary:find('exit=1', 1, true) ~= nil,
  'though the summary still says the exit: ' .. tostring(kept.summary))

-- 4. WHAT IT COSTS: the note is one line, the first stderr line, and this is its size.
local note_line
for line in (tostring(shown) or ''):gmatch('[^\n]+') do
  if line:find('note: remote exited', 1, true) then note_line = line end
end
check(note_line ~= nil and #note_line < 300, 'the note line stays small (' .. tostring(note_line and #note_line) .. ' B)')
print(('remote exit in summary: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
