-- The tool boundary (docs/HOOKS.md): PreToolUse can allow, deny or rewrite, PostToolUse and
-- PostToolUseFailure fire on the call that actually ran, and a node with no hooks configured is
-- exactly the node it was before. Model-free: `tools.dispatch` is called directly, so no provider and
-- no inference is involved.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end

local config = paths.config()
local home = paths.home()
local function sh(command)
  local result = json.decode(host.exec(command, '', 30))
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
sh("mkdir -p '" .. config .. "'")
sh("mkdir -p '" .. home .. "/hooks-work'")
write(home .. '/hooks-work/wanted.txt', 'the file the hook chose\n')
write(home .. '/hooks-work/original.txt', 'the file the model asked for\n')

local memory = dofile('lua/core/memory.lua')
memory.setup()
local tools = dofile('lua/core/tools.lua')
local hooks = dofile('lua/core/hooks.lua')
local session = memory.start_session('', 'hooks tool fixture', { user_id = 'master' })
local ctx = { session_id = session, user_id = 'master', role = 'master', cwd = home .. '/hooks-work' }

-- ---- 1. no hooks: the tool behaves exactly as before --------------------------------------------
hooks.reset()
local plain = tools.dispatch(memory, 'read', { path = home .. '/hooks-work/original.txt' }, 'master', ctx)
ok(type(plain) == 'table' and plain.error == nil, 'with no hooks configured, read succeeds')
ok(tostring(plain.content or plain.text or json.encode(plain)):find('the file the model asked for', 1, true) ~= nil,
  'and answers the file it was asked for')

-- ---- 2. PreToolUse deny: the call does not run --------------------------------------------------
local deny_marker = home .. '/hooks-work/denied.marker'
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'deny-reads', matcher = '^read$', command = answer('denyread', json.encode({ hookSpecificOutput = {
    hookEventName = 'PreToolUse', permissionDecision = 'deny',
    permissionDecisionReason = 'reads are forbidden in this fixture' },
    systemMessage = 'a hook refused a read' })) } } } }))
hooks.reset()
local denied = tools.dispatch(memory, 'read', { path = home .. '/hooks-work/original.txt' }, 'master', ctx)
ok(type(denied) == 'table' and denied.error == 'hook_denied', 'PreToolUse deny answers hook_denied')
ok(denied.effect == 'none', 'and marks the refusal as no effect, so the node is not left uncertain')
ok(denied.reason == 'reads are forbidden in this fixture', 'with the hook\'s own reason')
ok(denied.denied_by == 'deny-reads', 'and the hook that refused it')
ok(json.encode(denied):find('the file the model asked for', 1, true) == nil, 'the refused call read nothing')
ok(type(denied.hook_system_messages) == 'table' and denied.hook_system_messages[1] == 'a hook refused a read',
  'its systemMessage travels with the answer for the reader')

-- The matcher is a boundary, not a formality: a different tool is untouched.
local other = tools.dispatch(memory, 'bash', { command = 'echo other-tool-ran' }, 'master', ctx)
ok(type(other) == 'table' and other.error ~= 'hook_denied', 'a tool the matcher does not name still runs')

-- ---- 3. updatedInput: the tool receives the hook's arguments ------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'narrow-path', matcher = 'read', command = answer('narrow', json.encode({ hookSpecificOutput = {
    hookEventName = 'PreToolUse', permissionDecision = 'allow',
    updatedInput = { path = home .. '/hooks-work/wanted.txt' } } })) } } } }))
hooks.reset()
local rewritten = tools.dispatch(memory, 'read', { path = home .. '/hooks-work/original.txt' }, 'master', ctx)
ok(type(rewritten) == 'table' and rewritten.error == nil, 'an updatedInput call runs')
ok(tostring(rewritten.content or rewritten.text or json.encode(rewritten)):find('the file the hook chose', 1, true) ~= nil,
  'and the tool read the path the hook rewrote, not the one the model asked for')

-- ---- 4. PostToolUse and PostToolUseFailure see the call that ran --------------------------------
local post_marker = home .. '/hooks-work/post.marker'
local fail_marker = home .. '/hooks-work/fail.marker'
write(config .. '/hooks.json', json.encode({ hooks = {
  PostToolUse = { { name = 'after-any', command = script('post', "touch '" .. post_marker .. "'") } },
  PostToolUseFailure = { { name = 'after-fail', command = script('fail', "touch '" .. fail_marker .. "'") } },
} }))
hooks.reset()
os.remove(post_marker); os.remove(fail_marker)
local good = tools.dispatch(memory, 'read', { path = home .. '/hooks-work/original.txt' }, 'master', ctx)
ok(type(good) == 'table' and good.error == nil, 'the read succeeded')
ok(host.read_file(post_marker) ~= nil, 'PostToolUse ran for the successful call')
ok(host.read_file(fail_marker) == nil, 'and PostToolUseFailure did not')

local bad = tools.dispatch(memory, 'read', { path = home .. '/hooks-work/missing-file.txt' }, 'master', ctx)
ok(type(bad) == 'table' and bad.error ~= nil, 'the read of a missing file failed (' .. tostring(type(bad) == 'table' and bad.error) .. ')')
ok(host.read_file(fail_marker) ~= nil, 'PostToolUseFailure ran for the failing call')

-- The payload a PostToolUse hook receives carries the tool name and a bounded result view; a
-- failure hook is told the error. Asserted through a Lua hook, which sees the same table.
local seen = {}
local watcher = hooks.register('PostToolUse', function(payload) seen[#seen + 1] = payload end, { name = 'watch' })
local failure_watcher = hooks.register('PostToolUseFailure', function(payload) seen[#seen + 1] = payload end, { name = 'watch-fail' })
hooks.reset()
tools.dispatch(memory, 'read', { path = home .. '/hooks-work/original.txt' }, 'master', ctx)
tools.dispatch(memory, 'read', { path = home .. '/hooks-work/missing-file.txt' }, 'master', ctx)
hooks.unregister(watcher); hooks.unregister(failure_watcher)
ok(#seen == 2, 'both the success and the failure hook fired once')
ok(seen[1] and seen[1].hook_event_name == 'PostToolUse' and seen[1].tool_name == 'read' and seen[1].ok == true,
  'PostToolUse names the tool and says the call succeeded')
ok(seen[1] and type(seen[1].tool_response) == 'table', 'it carries a bounded view of the response, not the raw object')
ok(seen[2] and seen[2].hook_event_name == 'PostToolUseFailure' and seen[2].ok == false,
  'PostToolUseFailure says the call failed')
ok(seen[2] and seen[2].tool_response == nil, 'a failure carries the error, not a response')

-- ---- 5. additionalContext reaches the model with the result ------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PostToolUse = {
  { name = 'note', command = answer('note', json.encode({ hookSpecificOutput = {
    hookEventName = 'PostToolUse', additionalContext = 'this file is generated; do not edit it' } })) } } } }))
hooks.reset()
local noted = tools.dispatch(memory, 'read', { path = home .. '/hooks-work/original.txt' }, 'master', ctx)
ok(type(noted) == 'table' and noted.hook_context == 'this file is generated; do not edit it',
  'PostToolUse additionalContext is attached to the result the model receives')

-- ---- 6. a broken hook does not break the tool --------------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'broken', matcher = 'read', command = script('broken', 'exit 7') } } } }))
hooks.reset()
local survived = tools.dispatch(memory, 'read', { path = home .. '/hooks-work/original.txt' }, 'master', ctx)
ok(type(survived) == 'table' and survived.error == nil, 'a hook that fails does not fail the tool call')
ok(tostring(survived.content or survived.text or ''):find('the file the model asked for', 1, true) ~= nil,
  'and the call it observed ran normally')

-- ---- 7. hooks nested inside a tool call do not fire twice ---------------------------------------
-- `tools.dispatch` is re-entered by forwarding tools; the flag is what keeps one call one event.
local count = 0
local counter = hooks.register('PreToolUse', function() count = count + 1 end, { name = 'count' })
hooks.reset()
tools.dispatch(memory, 'sessions', {}, 'master', ctx)
hooks.unregister(counter)
ok(count == 1, 'one outermost tool call fires PreToolUse once (saw ' .. count .. ')')

if failed > 0 then
  print(string.format('hooks tools: %d failed of %d checks', failed, checks))
  os.exit(1)
end
print(string.format('hooks tools ok (%d checks)', checks))
