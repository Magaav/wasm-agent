-- A tool call made *inside* another call is a hook boundary of its own (docs/HOOKS.md).
--
-- Why this row exists. The engine used to fire once per outermost call, so a hook that matched
-- `read`, `bash`, `remote` or a connector never saw the same call made as `await tools.read()` inside
-- a code-mode script or through `tool_call` - and code mode is the default way this node is worked.
-- Measured 11/11 on `oc-in/change/ops` + `change/harness-evaluator`: a PreToolUse deny on `read`
-- refused the direct call, and the script and `tool_call` both read the file anyway.
--
-- So this row proves, from the same `tools.dispatch` funnel the node uses:
--   1. a direct call the hook refuses is refused, with `hook_denied`, the hook's own reason and note;
--   2. the same call made through `tool_call` (single and batched) and nested inside a real code-mode
--      script is refused with the SAME words, and inside a script it arrives as that call's failed
--      result - the script catches it and finishes, it does not crash the run;
--   3. the inner tool name and arguments are what the hook sees, in Pre AND Post, so a matcher on the
--      inner name is a real boundary;
--   4. one logical call fires once: `bash` starting its own supervised `operation` is the same call
--      and does not fire again;
--   5. a hook that itself runs a tool does not re-enter the engine: no recursion, and its own call
--      still runs.
--
-- Model-free and provider-free. The code-mode case drives the real native guest (`host.quickjs`), so
-- this row needs a binary built with the prepared code-mode assets, like every other code-mode row.
local json = dofile('lua/vendor/json.lua')

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end

local getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_CODEMODE' then return 'native' end
  return getenv(key)
end

local paths = dofile('lua/core/paths.lua')
local home, config = paths.home(), paths.config()
local function sh(command)
  local result = json.decode(host.exec(command, '', 60))
  assert(result and result.code == 0, command .. ' -> ' .. json.encode(result))
end
local function write(path, text) assert(host.write_file(path, text), 'write ' .. path) end
local function script(name, body)
  local path = config .. '/' .. name .. '.sh'
  write(path, '#!/usr/bin/env bash\n' .. body .. '\n')
  sh("chmod +x '" .. path .. "'")
  return "bash '" .. path .. "'"
end
local function answer(name, text)
  return script(name, "printf '%s' " .. string.format('%q', text))
end
-- The text a code-mode script printed: the only thing a script hands the model, and the place a
-- refused nested call has to arrive as an answer rather than as a dead run.
local function first_text(run)
  local item = type(run) == 'table' and type(run.items) == 'table' and run.items[1] or nil
  return type(item) == 'table' and tostring(item.text or '') or ''
end
sh("mkdir -p '" .. config .. "'")
sh("mkdir -p '" .. home .. "/nested-work'")
local secret_path = home .. '/nested-work/wanted.txt'
local secret_text = 'the file the model asked for'
write(secret_path, secret_text .. '\n')

local memory = dofile('lua/core/memory.lua')
memory.setup()
local tools = dofile('lua/core/tools.lua')
local hooks = dofile('lua/core/hooks.lua')
local hooks_json = config .. '/hooks.json'
local function clear_fixture() sh("rm -f '" .. hooks_json .. "'") end
local deny_script = answer('denyread', json.encode({ hookSpecificOutput = {
  hookEventName = 'PreToolUse', permissionDecision = 'deny',
  permissionDecisionReason = 'reads are forbidden in this fixture' } }))
local function install_deny()  -- one command hook, the form the evaluator's sink uses
  write(hooks_json, json.encode({ hooks = { PreToolUse = {
    { name = 'deny-reads', matcher = '^read$', command = deny_script } } } }))
  hooks.reset()
end

local sid = memory.start_session('', 'nested hook boundary', { user_id = 'master' })
local base_ctx = { session_id = sid, user_id = 'master', role = 'master', cwd = home .. '/nested-work' }

-- ---- 1. the same refusal, however the call is made -------------------------------------------------
install_deny()
local direct = tools.dispatch(memory, 'read', { path = secret_path }, 'master', base_ctx)
ok(type(direct) == 'table' and direct.error == 'hook_denied', 'a direct call the hook names is refused')
ok(direct.denied_by == 'deny-reads' and direct.reason == 'reads are forbidden in this fixture',
  'with the hook that refused it and its own reason')
ok(json.encode(direct):find(secret_text, 1, true) == nil, 'and it read nothing')

local via_call = tools.dispatch(memory, 'tool_call', { name = 'read', arguments = { path = secret_path } }, 'master', base_ctx)
ok(type(via_call) == 'table' and via_call.error == 'hook_denied',
  'the same call made through tool_call is refused (answered ' .. tostring(type(via_call) == 'table' and via_call.error) .. ')')
ok(via_call.denied_by == direct.denied_by and via_call.reason == direct.reason,
  'tool_call answers with the same hook and the same reason as the direct call')
ok(json.encode(via_call):find(secret_text, 1, true) == nil, 'and tool_call read nothing')

-- NOTE on what is deliberately not here: `tool_call {calls=...}` is its own read-batch contract (it
-- answers `batch_target_not_pure_read` for a plain `read` before dispatching anything), so it is not an
-- instance of nesting; `read_many` reads inside its own call rather than dispatching a second one. The
-- nested dispatch this row proves is the one the model makes through the ordinary `tool_call` and from
-- inside a script, which is where the measured bypass was.

-- ---- 2. inside a real code-mode script -------------------------------------------------------------
-- The guest is the real native one: a script awaits the tool and catches what comes back. Readiness is
-- asked of the node's own policy, so an env-provided asset directory and the embedded assets both work.
local code_mode_ready = dofile('lua/core/codemode_policy.lua').pin(memory, 'master', base_ctx)
ok(code_mode_ready.enabled == true, 'this binary can run the code-mode guest the boundary is proved in ('
  .. tostring(code_mode_ready.unavailable) .. '; build with WA_CODEMODE_BUILD_ASSETS=<prepared assets>)')
if code_mode_ready.enabled then
  local code = 'let out; try { const r = await tools.read({path: ' .. json.encode(secret_path)
    .. '}); out = "REACHED:" + String(r.content).trim(); } catch (e) { out = "REFUSED:" + String((e && e.message) || e); } text(out);'
  local run = tools.dispatch(memory, 'codemode', { code = code }, 'master', base_ctx)
  local shown = first_text(run)
  ok(run.ok == true, 'the script finishes: a refused nested call is that call\'s failed result, not a crash of the run')
  ok(shown:find('^REFUSED:', 1) ~= nil, 'the script saw the nested call fail (' .. shown:sub(1, 160) .. ')')
  ok(shown:find('hook_denied', 1, true) ~= nil, 'and the failure is the hook refusal, under its own error name')
  ok(shown:find('deny-reads', 1, true) ~= nil, 'the hook that refused the direct call refused the scripted one')
  ok(shown:find('reads are forbidden in this fixture', 1, true) ~= nil, 'in the same words as outside')
  ok(shown:find(secret_text, 1, true) == nil, 'the script never received the file it asked for')
  ok(shown:find(direct.note, 1, true) ~= nil, 'and the refusal carries the same note a direct refusal carries')
  ok(type(run.calls) == 'table' and type(run.calls[1]) == 'table' and run.calls[1].ok == false,
    'the run records the nested call as failed, so the evidence matches what the script saw')

  -- ---- 3. the hook sees the INNER name and arguments, in Pre and Post ------------------------------
  clear_fixture()
  local seen = {}
  hooks.register('PreToolUse', function(payload)
    seen[#seen + 1] = { event = 'pre', tool = payload.tool_name, input = payload.tool_input }
  end, { name = 'count-pre' })
  hooks.register('PostToolUse', function(payload)
    seen[#seen + 1] = { event = 'post', tool = payload.tool_name, input = payload.tool_input, ok = payload.ok }
  end, { name = 'count-post' })
  hooks.reset()
  local allowed = tools.dispatch(memory, 'codemode', { code = 'const r = await tools.read({path: '
    .. json.encode(secret_path) .. '}); text(r.content);' }, 'master', base_ctx)
  local allowed_text = first_text(allowed)
  local function events_for(name, phase)
    local list = {}
    for _, row in ipairs(seen) do if row.tool == name and row.event == phase then list[#list + 1] = row end end
    return list
  end
  local inner_pre, inner_post = events_for('read', 'pre'), events_for('read', 'post')
  ok(allowed.ok == true and allowed_text:find(secret_text, 1, true) ~= nil,
    'a nested call the hook allows runs and answers the script (' .. tostring(allowed.error):sub(1, 120) .. ')')
  ok(#inner_pre == 1, 'PreToolUse fires once for the call made inside the script (saw ' .. #inner_pre .. ')')
  ok(inner_pre[1] and inner_pre[1].input and inner_pre[1].input.path == secret_path,
    'and it sees the inner tool\'s own arguments, not the script\'s')
  ok(#inner_post == 1 and inner_post[1].ok == true, 'PostToolUse fires for the same nested call, once, with its result')
  ok(#events_for('codemode', 'pre') == 1, 'the outer codemode call is a boundary too, and fires once')
  ok(#seen == 4, 'two boundaries, two events each, and no more (saw ' .. #seen .. ')')

  -- A matcher on the inner name cannot be satisfied by the outer name that is not it.
  install_deny()
  local nested_denied = tools.dispatch(memory, 'codemode', { code = 'try { await tools.read({path: '
    .. json.encode(secret_path) .. '}); text("REACHED"); } catch (e) { text(String((e && e.message) || e)); }' },
    'master', base_ctx)
  local denied_text = first_text(nested_denied)
  ok(denied_text:find('deny-reads', 1, true) ~= nil and denied_text:find(secret_text, 1, true) == nil,
    'with the deny hook installed again, the scripted call is refused by name and reads nothing')
end

-- ---- 4. one logical call fires once ----------------------------------------------------------------
clear_fixture()
local fired = {}
hooks.register('PreToolUse', function(payload) fired[#fired + 1] = payload.tool_name end, { name = 'count-only' })
hooks.reset()
local started = tools.dispatch(memory, 'bash', { command = 'true', timeout_seconds = 60 }, 'master',
  { session_id = sid, user_id = 'master', role = 'master', cwd = home .. '/nested-work', parallel_start = true })
ok(type(started) == 'table' and started.operation_id ~= nil,
  'bash starts its supervised operation (' .. tostring(type(started) == 'table' and (started.error or started.operation_id)) .. ')')
ok(#fired == 1 and fired[1] == 'bash',
  'bash starting its own operation fires one hook, for bash, and none for the plumbing (saw '
  .. table.concat(fired, ',') .. ')')
if type(started) == 'table' and started.operation_id then
  tools.dispatch(nil, 'operation', { action = 'await', id = started.operation_id, tool = 'bash' }, 'master',
    { session_id = sid, user_id = 'master', role = 'master' })
  tools.dispatch(nil, 'operation', { action = 'cancel', id = started.operation_id }, 'master',
    { session_id = sid, user_id = 'master', role = 'master' })
end

-- ---- 5. a hook that runs a tool does not re-enter itself --------------------------------------------
clear_fixture()
local runs, inner_value = 0, nil
hooks.register('PreToolUse', function(payload)
  runs = runs + 1
  -- The hook asks the node something of its own, on the very tool its own matcher names: without the
  -- engine's guard this is unbounded recursion, not a slightly slow hook.
  local answer_row = tools.dispatch(memory, 'read', { path = secret_path }, 'master', base_ctx)
  inner_value = type(answer_row) == 'table' and tostring(answer_row.content or '') or nil
end, { name = 'hook-runs-a-tool', matcher = '^read$' })
hooks.reset()
local read_once = tools.dispatch(memory, 'read', { path = secret_path }, 'master', base_ctx)
ok(type(read_once) == 'table' and tostring(read_once.content or ''):find(secret_text, 1, true) ~= nil,
  'the call the hook interrupted still ran and answered')
ok(runs == 1, 'the hook ran once: the tool it runs itself does not fire it again (ran ' .. runs .. ')')
ok(inner_value ~= nil and inner_value:find(secret_text, 1, true) ~= nil,
  'and the tool the hook ran itself actually ran, so the guard is not a silent no-op')

hooks.reset()
print(json.encode({ ok = failed == 0, checks = checks, failed = failed }))
if failed > 0 then error('HOOKS NESTED CHECK FAILED: ' .. failed .. ' of ' .. checks) end
