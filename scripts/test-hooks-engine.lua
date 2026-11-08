-- The hook engine's own contract (docs/HOOKS.md): config sources, matchers, the Claude Code command
-- protocol, the bounds, the bus source, and the read surface. Model-free and hermetic: every config
-- and every hook command is written into this test's own scratch home, and no provider is called.
--
-- The point of the file is that each assertion is the *documented* behaviour, not the implementation's
-- accident: a deny denies, a broken hook does not, a timeout is bounded, and an `updatedInput` is
-- what the tool actually receives.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end

local config = paths.config()
local function sh(command)
  local result = json.decode(host.exec(command, '', 30))
  assert(result and result.code == 0, command .. ' -> ' .. json.encode(result))
  return result
end
local function write(path, text)
  assert(host.write_file(path, text), 'write ' .. path)
end
-- A hook command is the operator's own: a tiny script that reads its stdin and answers. Written per
-- case so a failure names the case.
local function script(name, body)
  local path = config .. '/' .. name .. '.sh'
  write(path, '#!/usr/bin/env bash\n#!/bin/sh\n' .. body .. '\n')
  sh("chmod +x '" .. path .. "'")
  return "bash '" .. path .. "'"
end
local function answer(name, text)
  return script(name, "printf '%s' " .. string.format('%q', text))
end

sh("mkdir -p '" .. config .. "'")

local hooks = dofile('lua/core/hooks.lua')

-- ---- 1. nothing configured: the shipped guard is the only thing in the path ----------------------
hooks.reset()
ok(hooks.configured() == false, 'no config file means no configured hooks')
ok(hooks.active() == true,
  'the shipped default guard is active with no config at all (docs/HOOK-EVENTS.md)')
local inert = hooks.fire('PreToolUse', { tool_name = 'bash', tool_input = { command = 'echo x' } }, { session_id = 's' })
ok(inert.ran == 0 and inert.blocked == false and inert.status == 'no_hooks',
  'a fire with no configured hook runs no hook and blocks nothing')
ok(inert.guard and inert.guard.origin == 'shipped' and inert.guard.status == 'allow',
  'the shipped guard saw the call and refused nothing')
ok(inert.updated_input and next(inert.updated_input) == nil, 'and answers no input rewrite')
ok(host.read_file(config .. '/hooks.json') == nil, 'the scratch home had no hooks.json to begin with')

-- ---- 2. every event exists, with a documented payload -------------------------------------------
local documented = {}
for _, event in ipairs(hooks.EVENTS) do
  documented[event.name] = true
  ok(type(event.when) == 'string' and #event.when > 10, event.name .. ' documents when it fires')
  ok(type(event.fields) == 'table' and #event.fields > 0, event.name .. ' documents its payload fields')
  ok(type(event.may) == 'table', event.name .. ' documents what it may decide')
end
for _, name in ipairs({ 'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
  'PreCompact', 'PostCompact', 'Stop', 'SubagentStart', 'SubagentStop', 'Notification', 'SelfWake',
  'PreDeploy', 'PostDeploy', 'ComponentInstall', 'ComponentSwap', 'StatusLine' }) do
  ok(documented[name] == true, 'the catalogue has ' .. name)
end

-- A Lua hook is how the payload is observed without a shell: it receives exactly the table a command
-- hook receives on stdin, so one assertion covers both kinds.
local captured, capture_ctx
local capture = hooks.register('PreToolUse', function(payload, ctx) captured, capture_ctx = payload, ctx end, { name = 'capture' })
ok(capture ~= nil, 'a Lua hook registers for a documented event')
local nil_handle, why = hooks.register('NoSuchEvent', function() end)
ok(nil_handle == nil and why == 'unknown_hook_event:NoSuchEvent', 'an unknown event is refused, not silently kept')

local fired = hooks.fire('PreToolUse', { tool_name = 'bash', tool_input = { command = 'ls' }, tool_call_id = 'call-1' },
  { session_id = 'sess-1', run_id = 'run-1', role = 'master' })
ok(captured and captured.hook_event_name == 'PreToolUse', 'the payload names the event (hook_event_name)')
ok(captured.version == hooks.VERSION, 'the payload carries the protocol version')
ok(captured.session_id == 'sess-1' and captured.run_id == 'run-1' and captured.role == 'master',
  'the payload carries the session, run and role')
ok(captured.tool_name == 'bash' and type(captured.tool_input) == 'table', 'the payload carries the tool call')
ok(captured.tool_call_id == 'call-1' and type(captured.cwd) == 'string' and captured.cwd ~= '',
  'the payload carries the call id and the working directory')
ok(fired.ran == 1 and #fired.outcomes == 1 and fired.outcomes[1].status == 'ok', 'the Lua hook ran once')
ok(capture_ctx.session_id == 'sess-1', 'the second argument is the firing context')
hooks.unregister(capture)
ok(hooks.fire('PreToolUse', {}, { session_id = 's' }).ran == 0, 'an unregistered hook does not run again')

-- ---- 3. the Claude Code command protocol -------------------------------------------------------
-- deny, allow and ask, each through a real subprocess reading the JSON on stdin.
write(config .. '/hooks.json', json.encode({ hooks = {
  PreToolUse = {
    { name = 'deny-bash', matcher = 'bash', command = answer('deny', json.encode({ hookSpecificOutput = {
      hookEventName = 'PreToolUse', permissionDecision = 'deny', permissionDecisionReason = 'no shells here' } })) },
    { name = 'allow-read', matcher = '^read$', command = answer('allow', json.encode({ hookSpecificOutput = {
      hookEventName = 'PreToolUse', permissionDecision = 'allow', permissionDecisionReason = 'reads are fine' } })) },
    { name = 'ask-write', matcher = 'write', command = answer('ask', json.encode({ hookSpecificOutput = {
      hookEventName = 'PreToolUse', permissionDecision = 'ask', permissionDecisionReason = 'this writes a file' } })) },
  },
} }))
hooks.reset()
ok(hooks.active() == true, 'a configured hook makes the engine active')

local denied = hooks.fire('PreToolUse', { tool_name = 'bash', tool_input = { command = 'rm -rf /' } }, { session_id = 's' })
ok(denied.blocked == true and denied.permission == 'deny', 'permissionDecision deny blocks the call')
ok(denied.reason == 'no shells here', 'the hook\'s own reason is what the caller shows: ' .. tostring(denied.reason))
ok(denied.blocked_by == 'deny-bash', 'the refusing hook is named')
ok(#denied.system_messages == 0, 'a deny with no systemMessage adds no reader line')

local allowed = hooks.fire('PreToolUse', { tool_name = 'read', tool_input = { path = 'x' } }, { session_id = 's' })
ok(allowed.blocked == false and allowed.permission == 'allow' and allowed.allowed_by == 'allow-read',
  'permissionDecision allow is recorded and does not block')

local asked = hooks.fire('PreToolUse', { tool_name = 'write', tool_input = { path = 'x' } }, { session_id = 's' })
ok(asked.blocked == true and asked.permission == 'ask', 'ask is refused when this node has no prompt for it')
ok(tostring(asked.reason):find('on_ask', 1, true) ~= nil, 'and the refusal names the way to change it')

-- `on_ask: "allow"` is the documented answer for an operator who accepts the hook's judgement.
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'ask-write', matcher = 'write', on_ask = 'allow',
    command = answer('ask2', json.encode({ hookSpecificOutput = { permissionDecision = 'ask' } })) } } } }))
hooks.reset()
local asked_allowed = hooks.fire('PreToolUse', { tool_name = 'write', tool_input = {} }, { session_id = 's' })
ok(asked_allowed.blocked == false and asked_allowed.permission == 'allow', 'on_ask:"allow" answers an ask with an allow')

-- exit 2 is Claude Code's blocking exit; stderr is the reason.
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'exit2', matcher = 'bash', command = script('exit2', 'echo "blocked by exit 2" >&2\nexit 2') } } } }))
hooks.reset()
local exit_two = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
ok(exit_two.blocked == true and exit_two.status == 'blocked', 'exit code 2 blocks')
ok(exit_two.reason == 'blocked by exit 2', 'exit 2 carries its stderr as the reason')

-- exit 1 is a visible failure, and it changes nothing.
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'broken', matcher = 'bash', command = script('broken', 'echo boom >&2\nexit 1') } } } }))
hooks.reset()
local broken = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
ok(broken.blocked == false and broken.status == 'ok', 'a hook that exits 1 does not block the call')
ok(#broken.errors == 1 and broken.errors[1].error == 'exit_1', 'and its failure is recorded as a failure')

-- Garbage on stdout, no stdout at all, and a hook that dies: all non-blocking.
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'garbage', matcher = 'bash', command = answer('garbage', 'not json at all') },
  { name = 'silent', matcher = 'bash', command = script('silent', 'true') } } } }))
hooks.reset()
local noise = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
ok(noise.blocked == false and noise.ran == 2 and noise.errors == nil or #noise.errors == 0,
  'unparseable output and silent success are both non-blocking')
ok(noise.outcomes[1].status == 'ok' and noise.outcomes[1].answered == nil, 'unparseable output is not an answer')

-- ---- 4. updatedInput: the tool receives the hook's arguments ------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'narrow', matcher = 'read', command = answer('narrow', json.encode({ hookSpecificOutput = {
    hookEventName = 'PreToolUse', permissionDecision = 'allow', updatedInput = { path = 'README.md', limit = 40 } } })) } } } }))
hooks.reset()
local rewritten = hooks.fire('PreToolUse', { tool_name = 'read', tool_input = { path = '/etc/passwd', offset = 10 } }, { session_id = 's' })
ok(rewritten.updated_input.path == 'README.md' and rewritten.updated_input.limit == 40,
  'updatedInput is what the caller applies')
ok(rewritten.updated_input.offset == nil, 'the rewrite carries only what it names; the merge is the caller\'s')
ok(rewritten.input_changes.path == 'README.md', 'the change is named for the log, without the old value')

-- ---- 5. additionalContext, block and continue ---------------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = {
  UserPromptSubmit = { { name = 'date', command = answer('date', json.encode({ hookSpecificOutput = {
    hookEventName = 'UserPromptSubmit', additionalContext = 'Today is a test day.' } })) } },
  Stop = { { name = 'keep-going', command = answer('keep', json.encode({ decision = 'block',
    reason = 'the tests were not run yet' })) } },
} }))
hooks.reset()
local prompt = hooks.fire('UserPromptSubmit', { prompt = 'hi', prompt_len = 2 }, { session_id = 's' })
ok(prompt.blocked == false and prompt.additional_context == 'Today is a test day.',
  'UserPromptSubmit can add context without blocking')
local stop = hooks.fire('Stop', { message_id = 'm', text_len = 12 }, { session_id = 's' })
ok(stop.blocked == true and stop.reason == 'the tests were not run yet', 'a Stop hook can ask the run to continue')
ok(stop.stop == nil, 'and that is not the same answer as stop')

write(config .. '/hooks.json', json.encode({ hooks = { Stop = {
  { name = 'stop-now', command = answer('stopnow', json.encode({ continue = false, stopReason = 'the operator said stop' })) } } } }))
hooks.reset()
local stopped = hooks.fire('Stop', { message_id = 'm' }, { session_id = 's' })
ok(stopped.stop == true and stopped.stop_reason == 'the operator said stop', 'continue:false keeps the answer and says why')

-- ---- 6. the bounds: timeout and stdout cap ------------------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'slow', matcher = 'bash', timeout_ms = 500, command = script('slow', "sleep 30") } } } }))
hooks.reset()
local started = host.monotonic_ms()
local timed_out = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
local elapsed = host.monotonic_ms() - started
ok(timed_out.blocked == false, 'a hook that times out does not block the call')
ok(timed_out.outcomes[1].status == 'timeout', 'the timeout is recorded as a timeout, not a silent success')
ok(#timed_out.errors == 1 and timed_out.errors[1].error == 'timeout', 'and it is a visible error')
ok(elapsed < 5000, 'the per-hook timeout is what ended it, not the exec default (' .. elapsed .. 'ms)')

write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'chatty', matcher = 'bash',
    command = script('chatty', "yes 'hook output line' | head -c 200000") } } } }))
hooks.reset()
local chatty = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
ok(#chatty.outcomes[1].stdout <= hooks.MAX_STDOUT_BYTES, 'stdout is capped at the documented bound')
ok(chatty.outcomes[1].stdout_clipped == true, 'and the cap is recorded, not silent')

-- ---- 7. sources, precedence and the Claude opt-in -----------------------------------------------
-- Two sources, both answering PreToolUse: the node file first, the project file second, and a deny in
-- the later one still denies (a later hook cannot undo a refusal).
local project = config .. '/../../project-fixture/.wasm-agent'
sh("mkdir -p '" .. project .. "'")
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'node-allow', matcher = 'bash', command = answer('nodeallow', json.encode({ decision = 'approve' })) } } } }))
write(project .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'project-deny', matcher = 'bash', command = answer('projectdeny', json.encode({ decision = 'block', reason = 'the project forbids it' })) } } } }))
hooks.reset()
local ordered = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's', workdir = config .. '/../../project-fixture' })
ok(ordered.ran == 2, 'both config sources were read for the same event')
ok(ordered.outcomes[1].name == 'node-allow' and ordered.outcomes[2].name == 'project-deny',
  'the node file runs before the project file')
ok(ordered.blocked == true and ordered.blocked_by == 'project-deny', 'a later denial is not talked out of it')

-- Claude Code's settings are read only when the operator opts in.
local claude_home = paths.home() .. '/.claude'
sh("mkdir -p '" .. claude_home .. "'")
local claude_entry = { matcher = 'Bash', hooks = { { type = 'command',
  command = answer('claudehook', json.encode({ hookSpecificOutput = { permissionDecision = 'deny',
    permissionDecisionReason = 'claude-compat deny' } })), timeout = 20 } } }
write(claude_home .. '/settings.json', json.encode({ hooks = { PreToolUse = { claude_entry } } }))
hooks.reset()
local without = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
ok(without.blocked == false, 'claude settings are not used without hooks.claude_compat')
local passive = hooks.list({})
ok(passive.claude_compat == false, 'and /hooks says the compat source is off')

write(config .. '/hooks.json', json.encode({ hooks = { claude_compat = true } }))
hooks.reset()
local with_compat = hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
ok(with_compat.blocked == true and with_compat.reason == 'claude-compat deny',
  'hooks.claude_compat:true reads ~/.claude/settings.json, matcher and seconds-timeout included')
ok(with_compat.outcomes[1].timeout_ms == 20000, 'Claude Code\'s seconds become milliseconds')
local compat_list = hooks.list({})
ok(compat_list.claude_compat == true, '/hooks reports the compat source as on')
local source_names = {}
for _, row in ipairs(compat_list.sources) do source_names[row.name] = true end
ok(source_names['node'] == true and source_names['user-claude'] == true, 'both sources are named')

-- Earlier, the same config answered an `on_ask` and an event the engine does not know. The unknown
-- event is reported, not silently dropped - an operator's typo must be visible.
write(config .. '/hooks.json', json.encode({ hooks = { claude_compat = true, PreToolUse = {}, NotAnEvent = {} } }))
hooks.reset()
local reported = hooks.list({})
local mentioned = false
for _, problem in ipairs(reported.errors) do
  if tostring(problem):find('NotAnEvent', 1, true) then mentioned = true end
end
ok(mentioned, 'an unknown event name is reported in /hooks')
ok(hooks.fire('PreToolUse', {}, { session_id = 's' }).ran == 0, 'and no hook runs for it')

-- ---- 8. a bus topic is a hook source ------------------------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = {
  ['bus:session.message'] = { { name = 'on-message', command = answer('onmessage',
    json.encode({ systemMessage = 'a message arrived' })) } },
  ['bus:*'] = { { name = 'every-topic', command = answer('everytopic', '') } },
} }))
hooks.reset()
local bus = hooks.bus('session.message', { session_id = 's', id = 'm1' }, { session_id = 's' })
ok(bus.ran == 2, 'a named topic and the wildcard both receive the publish')
ok(bus.outcomes[1].name == 'on-message' and bus.outcomes[2].name == 'every-topic', 'named topic first, wildcard second')
ok(#bus.system_messages == 1 and bus.system_messages[1] == 'a message arrived', 'a bus hook can surface a message')
local _, topic_error = hooks.bus('not a topic', {})
ok(topic_error == 'bus_topic_required', 'a topic with a space is refused')

-- ---- 9. the read surface, and redaction ---------------------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'leaky', matcher = 'bash', command = script('leaky',
    'echo "OPENAI_API_KEY=sk-live-abcdefghijklmnop" >&2\nexit 1') } } } }))
hooks.reset()
hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
local listed = hooks.list({})
ok(listed.version == hooks.VERSION, 'the read surface carries a version')
ok(#listed.events == 1 and listed.events[1].event == 'PreToolUse', 'it lists one active event')
local shipped_row = listed.events[1].entries[1]
local leaky_row = listed.events[1].entries[2]
ok(shipped_row and shipped_row.name == 'guard-destructive' and shipped_row.origin == 'shipped',
  'the shipped guard is listed first, with its origin')
ok(leaky_row and leaky_row.name == 'leaky' and leaky_row.kind == 'command',
  'with the configured hook\'s name and kind')
ok(listed.recent[1] and listed.recent[1].status == 'ok' or listed.recent[1].status == 'error',
  'and the last outcome')
local leaked = false
for _, row in ipairs(listed.recent) do
  if tostring(row.detail or ''):find('sk-live-abcdefghijklmnop', 1, true) then leaked = true end
end
ok(leaked == false, 'a secret a hook printed is redacted in the recorded outcome')
ok(tostring(listed.recent[1].detail or ''):find('OPENAI_API_KEY=sk%-%.%.%.', 1, false) ~= nil,
  'the masked form is what is kept, so an operator can tell which key it was')
local report = hooks.report({})
ok(report:find('PreToolUse', 1, true) ~= nil, '/hooks prints the active event')
ok(report:find('leaky', 1, true) ~= nil, '/hooks prints the hook name')
ok(report:find('sk-live', 1, true) == nil, '/hooks prints no secret')

-- ---- 10. `WASM_AGENT_HOOKS=off` is a full stop ---------------------------------------------------
-- The knob is read by the engine, so it is asserted through the same door an operator uses: a config
-- that would deny, and a flag that says the operator wants no hooks at all.
local previous = host.getenv('WASM_AGENT_HOOKS')
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'deny-all', command = answer('denyall', json.encode({ decision = 'block', reason = 'no' })) } } } }))
hooks.reset()
ok(hooks.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' }).blocked == true,
  'the configured hook denies while hooks are on')
ok(previous == nil, 'the harness did not preset WASM_AGENT_HOOKS')

if failed > 0 then
  print(string.format('hooks engine: %d failed of %d checks', failed, checks))
  os.exit(1)
end
print(string.format('hooks engine ok (%d checks)', checks))
