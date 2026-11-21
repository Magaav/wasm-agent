-- The model reads the LEAN view of a script result under the name it calls the tool by: `run`.
--
-- Why this row exists (22/11): lua/core/tool_output.lua gave the lean view to `name=='codemode'` only,
-- and the loop hands it the name the model used. Since `run` became the one path the model read the whole
-- stored envelope instead - 6,912k characters over 1,976 real results where the lean view is 4,643k.
-- No model, no network: the real dispatcher, the real sandbox, private files.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local output = dofile('lua/core/tool_output.lua')
local agent = dofile('lua/core/agent.lua')
local checks = 0
local function check(value, label) if not value then error('FAIL: ' .. label, 2) end checks = checks + 1 end
local sid = memory.start_session('', 'run view fixture', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
local function run(code) return tools.dispatch(memory, 'run', { code = code }, 'master', ctx) end

-- 1. The ordinary script: one shell call, its output returned. The view is a header and the text.
local result = run([[const r = await tools.bash({command: 'printf "alpha\\nbeta %s\\n" \'"quoted"\''}); return r.stdout;]])
check(type(result) == 'table' and result.ok == true and type(result.attempts) == 'table', 'the script ran and its record carries attempts: ' .. json.encode(result):sub(1, 300))
local as_run, as_codemode = output.project('run', result), output.project('codemode', result)
check(as_run == as_codemode, 'the view under the name run is the view under the name codemode')
check(as_run:match('^status 200 '), 'the view opens with the status line, not with a JSON envelope: ' .. as_run:sub(1, 120))
check(as_run:find('alpha\nbeta "quoted"', 1, true), 'the output is the script\'s own text: real newlines, real quotes, nothing escaped')
check(not as_run:find('attempts', 1, true) and not as_run:find('context_policy', 1, true) and not as_run:find('rust-wasmtime', 1, true),
  'the bookkeeping (attempts, context_policy, backend) is not in what the model reads')
local _, copies = as_run:gsub('alpha', '')
check(copies == 1, 'the output is in the view ONCE (the envelope carried it again inside attempts): ' .. copies)
check(#as_run < #json.encode(result) / 2, 'the view is under half of the stored envelope: ' .. #as_run .. ' of ' .. #json.encode(result))
-- the stored view is what a later turn sends: it reads back as the same facts
local parsed = output.parse_view(as_run)
check(type(parsed) == 'table' and parsed.status == 200 and tostring(parsed.returned):find('alpha', 1, true), 'parse_view reads the stored view back')
check(output.context_view('run', as_run) == as_run, 'a later turn sends the stored view byte for byte')

-- 2. A failed script keeps its structured error and still drops the bookkeeping.
local failed = run('const x = ;')
local failed_view = output.project('run', failed)
check(failed.ok == false and failed_view == output.project('codemode', failed), 'a failed script: one view under either name')
check(failed_view:find('SyntaxError', 1, true) and not failed_view:find('"attempts"', 1, true), 'the failure names its error and carries no attempts')

-- 3. A script that returns an object: compact JSON of exactly that object.
local object = run('return {n: 2, list: ["a", "b"]};')
local object_view = output.project('run', object)
check(object_view:match('^status 200') and object_view:find('"list":["a","b"]', 1, true) and not object_view:find('attempts', 1, true), 'an object is returned as itself: ' .. object_view)

-- 4. Other tools are untouched: the predicate is the two script names and nothing else.
check(output.is_script('run') and output.is_script('codemode') and not output.is_script('bash') and not output.is_script(nil), 'is_script names the script tool only')
local bash = { stdout = 'x', stderr = '', code = 0, attempts = {}, summary = 's' }
check(output.project('bash', bash) == json.encode(bash) or json.decode(output.project('bash', bash)).attempts ~= nil, 'a bash result is not read as a script result')

-- 5. The done gate's effect rule reads the same predicate: a read-only script under the name run is
--    judged by what its calls did (M.script_effect), like one under the name codemode.
local reading = run('const r = await tools.bash({command: "ls /"}); return r.stdout.length;')
check(agent.script_effect(reading) == false, 'a script whose one call is a read-only shell command changed nothing')
local source = assert(host.read_file('lua/core/agent.lua'))
check(source:find('if tool_output.is_script(function_.name) then', 1, true), 'the loop asks tool_output.is_script, not a literal name')
check(not source:find('function_.name == "codemode"', 1, true), 'no literal codemode name is left in the loop\'s effect rule')

print(json.encode({ ok = true, checks = checks }))
print('run-view ok (' .. checks .. ' checks)')
