-- The hooks seam's parity suite (docs/CORE-SPLIT.md, docs/HOOK-EVENTS.md "The engine as a
-- component"): the same events fired through the native `lua/core/hooks.lua` engine and through the
-- `hooks` component, compared decision for decision - the config view, the matchers, the ordering, a
-- hook's answer, a timeout, the bus source, the mods surface and `/hooks` itself.
--
-- Self-contained: a scratch WASM_AGENT_HOME with this test's own hook scripts, no node, no network,
-- no model. The component half needs a built `hooks.wasm` reachable by this process, which means
-- `WA_HOOKS_COMPONENT_WASM` (`scripts/test-hooks-component.sh` builds it and sets it). When it is not
-- reachable the comparisons are SKIPPED - printed as such - and a skip is never counted as a pass.
--
-- The two interpreters are one process: the seam flag is read when the module loads, exactly as a
-- node reads it, so the test flips the *host's* answer while each instance loads rather than reaching
-- into the module. Process-wide state (the config cache, the outcome log, the plugin registry) is
-- shared by both instances on purpose - it is the node's state, not the module's - so every case
-- resets the cache before it runs either path.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local checks, comparisons, skipped, failed = 0, 0, 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end
local function skip(what, why)
  skipped = skipped + 1
  print('SKIP hooks seam: ' .. what .. ' (' .. why .. ')')
end
local function decode(value)
  if type(value) ~= 'string' then return value end
  local decoded_ok, decoded = pcall(json.decode, value)
  return decoded_ok and decoded or value
end

local config = paths.config()
local function sh(command)
  local result = decode(host.exec(command, '', 30))
  assert(type(result) == 'table' and result.code == 0, command .. ' -> ' .. tostring(result and result.stderr))
end
local function write(path, text)
  assert(host.write_file(path, text), 'write ' .. path)
end
local function script(name, body)
  local path = config .. '/' .. name .. '.sh'
  write(path, '#!/bin/sh\n' .. body .. '\n')
  sh("chmod +x '" .. path .. "'")
  return "sh '" .. path .. "'"
end
local function answer(name, text)
  return script(name, "printf '%s' " .. string.format('%q', text))
end

sh("mkdir -p '" .. config .. "'")

-- ---- the two interpreters ----------------------------------------------------------------------
local real_getenv, real_hooks, real_log = host.getenv, host.hooks, host.log
local logged = {}

local function instance(seam)
  host.getenv = function(name)
    if name == 'WA_HOOKS_COMPONENT' then return seam and '1' or nil end
    return real_getenv(name)
  end
  host.log = function(line) logged[#logged + 1] = tostring(line) end
  local module = dofile('lua/core/hooks.lua')
  host.getenv, host.log = real_getenv, real_log
  return module
end

local native = instance(false)

-- Is the component reachable from *this process*? A "parity" comparison against a fallback would pass
-- while proving nothing, so the probe decides, and an unreachable component is a reported SKIP.
local reachable = nil
if type(real_hooks) ~= 'function' then
  skip('parity', 'this binary has no host.hooks capability')
else
  local probe = decode(real_hooks(json.encode({ op = 'catalogue' })))
  if type(probe) ~= 'table' or probe.ok ~= true then
    skip('parity', 'the hooks component did not answer: '
      .. tostring(type(probe) == 'table' and probe.error or probe))
  else
    reachable = probe.result
  end
end

local seam
if reachable then
  logged = {}
  seam = instance(true)
  local fallbacks = {}
  for _, line in ipairs(logged) do fallbacks[#fallbacks + 1] = line end
  ok(#fallbacks == 0, 'loading the seam engine logged no fallback: ' .. tostring(fallbacks[1]))
end

-- ---- canonical comparison ----------------------------------------------------------------------
-- Ids, clocks and durations are the things the two paths cannot share: one reads the host clock and
-- the other formats a row it was handed, and a median ms is a measurement, not a decision. Everything
-- else - statuses, names, reasons, contexts, the merged input, the footer line - is compared as it is.
local ORDER_INSENSITIVE = { errors = true, sources = true }
local function canon(value, key)
  if type(value) ~= 'table' then
    if value == json.null then return 'null' end
    return type(value) .. ':' .. tostring(value)
  end
  local keys = {}
  for name in pairs(value) do
    if name ~= 'at' and name ~= 'ms' and name ~= 'elapsed_ms' then keys[#keys + 1] = name end
  end
  if #keys == 0 then return '{}' end
  local array = #value == #keys
  local parts = {}
  if array and ORDER_INSENSITIVE[key] then
    for _, item in ipairs(value) do parts[#parts + 1] = canon(item, key) end
    table.sort(parts)
  elseif array then
    for _, item in ipairs(value) do parts[#parts + 1] = canon(item, key) end
  else
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, name in ipairs(keys) do parts[#parts + 1] = tostring(name) .. '=' .. canon(value[name], name) end
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- Run one case through both paths and require the same answer, then let the caller assert what the
-- answer actually was (so "both paths are equally empty" can never pass as parity).
local function pair(label, fn)
  if not reachable then
    skip(label, 'no hooks component in this process')
    return nil, nil
  end
  native.reset()
  local a_ok, a = pcall(fn, native)
  native.reset()
  local b_ok, b = pcall(fn, seam)
  comparisons = comparisons + 1
  if not a_ok then
    print('FAIL ' .. label .. ': native raised ' .. tostring(a))
    failed = failed + 1
    return nil, nil
  end
  if not b_ok then
    print('FAIL ' .. label .. ': component path raised ' .. tostring(b))
    failed = failed + 1
    return a, nil
  end
  local left, right = canon(a), canon(b)
  if left ~= right then
    print('FAIL ' .. label .. ': the two paths disagree')
    print('  native:    ' .. left)
    print('  component: ' .. right)
    failed = failed + 1
  end
  return a, b
end

local function hooks_json(entries)
  return json.encode({ hooks = entries })
end

-- ---- 1. the catalogue and the bounds are the same list ----------------------------------------
if reachable then
  local events = reachable.events or {}
  local bounds = reachable.bounds or {}
  ok(#events == #native.EVENTS, 'the component documents every event this engine knows: '
    .. tostring(#events) .. ' vs ' .. tostring(#native.EVENTS))
  for index, event in ipairs(native.EVENTS) do
    local mirrored = events[index]
    ok(mirrored ~= nil and mirrored.name == event.name,
      'event ' .. tostring(index) .. ' is ' .. event.name)
    if mirrored then
      ok(mirrored.matcher == (event.matcher == true), event.name .. ' has the same matcher flag')
      ok(canon(mirrored.may) == canon(event.may), event.name .. ' may decide the same things')
      ok(canon(mirrored.fields) == canon(event.fields), event.name .. ' carries the same fields')
      ok(type(mirrored.when) == 'string' and #mirrored.when > 10, event.name .. ' documents when it fires')
    end
  end
  ok(bounds.version == native.VERSION, 'the protocol version is the same')
  ok(bounds.default_timeout_ms == native.DEFAULT_TIMEOUT_MS, 'the default timeout is the same')
  ok(bounds.max_timeout_ms == native.MAX_TIMEOUT_MS, 'the timeout cap is the same')
  ok(bounds.max_stdout_bytes == native.MAX_STDOUT_BYTES, 'the stdout cap is the same')
  ok(bounds.max_stderr_bytes == native.MAX_STDERR_BYTES, 'the stderr cap is the same')
  ok(bounds.max_context_bytes == native.MAX_CONTEXT_BYTES, 'the context cap is the same')
  ok(bounds.max_system_message_bytes == native.MAX_SYSTEM_MESSAGE_BYTES, 'the systemMessage cap is the same')
  ok(bounds.statusline_ttl_ms == native.STATUSLINE_TTL_MS, 'the footer cache TTL is the same')
  ok(bounds.statusline_max == native.STATUSLINE_MAX, 'the footer segment cap is the same')
end

-- ---- 2. nothing configured: inert on both paths ------------------------------------------------
sh("rm -f '" .. config .. "/hooks.json'")
local inert = pair('an inert node', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash', tool_input = { command = 'echo x' } }, { session_id = 's' })
end)
if inert then
  ok(inert.ran == 0 and inert.blocked == false and inert.status == 'no_hooks',
    'a fire with no configuration runs nothing and blocks nothing')
end
local inert_view = pair('an inert config view', function(module) return module.config({}) end)
if inert_view then
  ok(inert_view.disabled == false and inert_view.present == false, 'and reports no source present')
end

-- ---- 3. one deny: the decision, the reason, the order ------------------------------------------
write(config .. '/hooks.json', hooks_json({
  PreToolUse = {
    { name = 'deny-bash', matcher = 'bash', timeout_ms = 3000, command = answer('deny', json.encode({
      hookSpecificOutput = { permissionDecision = 'deny', permissionDecisionReason = 'no bash here' } })) },
    { name = 'after-the-deny', matcher = 'bash', command = answer('after', '{}') },
    { name = 'allow-read', matcher = '^read$', command = answer('allowread', json.encode({
      hookSpecificOutput = { permissionDecision = 'allow' } })) },
  },
}))
local denied = pair('one deny', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash', tool_input = { command = 'ls' }, tool_call_id = 'call-1' },
    { session_id = 'sess-1', run_id = 'run-1', role = 'master' })
end)
if denied then
  ok(denied.blocked == true and denied.blocked_by == 'deny-bash', 'the refusing hook is named')
  ok(denied.reason == 'no bash here', 'the reason is the sentence the hook gave: ' .. tostring(denied.reason))
  ok(denied.ran == 1, 'the hook after a denial never runs: ran=' .. tostring(denied.ran))
  ok(denied.status == 'denied', 'the status names the denial')
end
local unmatched = pair('a matcher that does not name the tool', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash', tool_input = { command = 'ls' }, tool_call_id = 'call-1' },
    { session_id = 'sess-1', run_id = 'run-1', role = 'master', tool = 'grep' })
end)
if unmatched then ok(unmatched.ran == 0 and unmatched.blocked == false, 'another tool is untouched') end

-- ---- 4. matchers are Lua patterns, not regexes --------------------------------------------------
local matrix_script = answer('matrix', json.encode({ systemMessage = 'matched' }))
local matchers = {
  { name = 'plain', matcher = 'bash' },
  { name = 'anchored', matcher = '^read$' },
  { name = 'set', matcher = '^[rw]ead$' },
  { name = 'class', matcher = '%a+ash' },
  { name = 'literal-pipe', matcher = 'bash|shell' },
  { name = 'anything', matcher = '.*' },
  { name = 'case', matcher = 'Bash' },
  { name = 'prefix', matcher = 'mcp_' },
}
local matcher_entries = {}
for _, item in ipairs(matchers) do
  matcher_entries[#matcher_entries + 1] = { name = item.name, matcher = item.matcher, command = matrix_script }
end
write(config .. '/hooks.json', hooks_json({ PreToolUse = matcher_entries }))
for _, tool in ipairs({ 'bash', 'Bash', 'read', 'grep', 'mcp_echo', 'shell', 'bash|shell' }) do
  local verdict = pair('matchers against ' .. tool, function(module)
    return module.fire('PreToolUse', { tool_name = tool }, { session_id = 's', tool = tool })
  end)
  if verdict then
    local names = {}
    for _, row in ipairs(verdict.outcomes or {}) do names[#names + 1] = row.name end
    -- The native engine is the reference: `bash|shell` is a literal (Lua patterns have no
    -- alternation), `Bash` matches case-insensitively because it is a plain word, and `%a+ash` is a
    -- class. The parity comparison above is what proves the component agrees; this is what makes the
    -- case non-empty.
    if tool == 'bash' then
      ok(#names >= 3, 'a bash call runs the plain, class and wildcard matchers: ' .. table.concat(names, ','))
    elseif tool == 'read' then
      ok(#names >= 2, 'a read call runs the anchored and set matchers: ' .. table.concat(names, ','))
    end
  end
end

-- ---- 5. a rewrite, a context, a system message, an ask ------------------------------------------
write(config .. '/hooks.json', hooks_json({
  PreToolUse = {
    { name = 'narrow', matcher = 'read', command = answer('narrow', json.encode({
      hookSpecificOutput = { updatedInput = { path = 'README.md' },
        additionalContext = 'Today is a test day.' } })) },
    { name = 'see-the-chain', matcher = 'read', command = script('see-chain',
      "printf '%s' \"$(cat)\" > " .. string.format('%q', config .. '/seen.json') .. "\nprintf '{}'") },
  },
  Stop = { { name = 'continue', command = answer('stop-continue', json.encode({
    continue = false, stopReason = 'not yet' })) } },
}))
sh("rm -f '" .. config .. "/seen.json'")
local rewritten = pair('an input rewrite', function(module)
  return module.fire('PreToolUse', { tool_name = 'read', tool_input = { path = 'notes.md', limit = 5 } },
    { session_id = 's', tool = 'read' })
end)
if rewritten then
  ok(rewritten.updated_input and rewritten.updated_input.path == 'README.md', 'the rewrite is the decision')
  ok(rewritten.input_changes and rewritten.input_changes.path == 'README.md', 'and it is named for the log')
  ok(rewritten.additional_context == 'Today is a test day.', 'the context is added')
  ok(rewritten.ran == 2, 'both hooks ran: ' .. tostring(rewritten.ran))
  -- The second hook is handed the payload the first one rewrote: one chain, not two copies.
  local seen = decode(host.read_file(config .. '/seen.json') or '{}')
  ok(type(seen) == 'table' and type(seen.tool_input) == 'table' and seen.tool_input.path == 'README.md',
    'a later hook sees the merged arguments: ' .. tostring(host.read_file(config .. '/seen.json')))
end
write(config .. '/hooks.json', hooks_json({
  PreToolUse = { { name = 'ask-write', matcher = 'write', command = answer('ask-write', json.encode({
    hookSpecificOutput = { permissionDecision = 'ask', permissionDecisionReason = 'are you sure' } })) } },
}))
local asked = pair('an ask with the default on_ask', function(module)
  return module.fire('PreToolUse', { tool_name = 'write' }, { session_id = 's', tool = 'write' })
end)
if asked then
  ok(asked.blocked == true and asked.status == 'ask', 'an ask is refused by policy when on_ask is deny')
  ok(type(asked.reason) == 'string' and asked.reason:find('on_ask', 1, true) ~= nil, 'and says how to allow it')
end
write(config .. '/hooks.json', hooks_json({
  PreToolUse = { { name = 'ask-write', matcher = 'write', on_ask = 'allow',
    command = answer('ask-allow', json.encode({ hookSpecificOutput = { permissionDecision = 'ask' } })) } },
}))
local allowed = pair('an ask with on_ask=allow', function(module)
  return module.fire('PreToolUse', { tool_name = 'write' }, { session_id = 's', tool = 'write' })
end)
if allowed then
  ok(allowed.blocked == false and allowed.permission == 'allow', 'on_ask=allow accepts it')
  ok(#allowed.notes == 1, 'and records that the policy, not a person, answered')
end
write(config .. '/hooks.json', hooks_json({
  Stop = { { name = 'stop-stop', command = answer('stop-stop', json.encode({ continue = false, stopReason = 'not yet' })) } },
}))
local stopped = pair('a Stop that keeps the answer', function(module)
  return module.fire('Stop', { message_id = 'm1', text_len = 10 }, { session_id = 's' })
end)
if stopped then
  ok(stopped.stop == true and stopped.stop_reason == 'not yet', 'continue:false stops the run with its reason')
end

-- ---- 6. a broken hook, a garbage answer, a timeout ---------------------------------------------
write(config .. '/hooks.json', hooks_json({
  PreToolUse = {
    { name = 'exit2', matcher = 'bash', command = script('exit2', 'echo "blocked by exit 2" >&2\nexit 2') },
    { name = 'never', matcher = 'bash', command = answer('never', '{}') },
  },
}))
local exit_two = pair('exit code 2', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if exit_two then
  ok(exit_two.blocked == true and exit_two.reason == 'blocked by exit 2', 'exit 2 blocks with its stderr')
  ok(exit_two.ran == 1, 'and stops the event')
end
write(config .. '/hooks.json', hooks_json({
  PreToolUse = {
    { name = 'broken', matcher = 'bash', command = script('broken', 'echo boom >&2\nexit 1') },
    { name = 'garbage', matcher = 'bash', command = answer('garbage', 'not json at all') },
    { name = 'silent', matcher = 'bash', command = script('silent', 'true') },
  },
}))
local noise = pair('a failing hook changes nothing', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if noise then
  ok(noise.blocked == false and noise.ran == 3, 'every hook ran and none blocked')
  ok(#noise.errors == 1 and noise.errors[1].error == 'exit_1', 'the failure is recorded, named exit_1')
end
write(config .. '/hooks.json', hooks_json({
  PreToolUse = { { name = 'slow', matcher = 'bash', timeout_ms = 500, command = script('slow', 'sleep 30') } },
}))
local timed_out = pair('a hook that hangs', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if timed_out then
  ok(timed_out.blocked == false, 'the turn continues: a timeout is recorded, never a refusal')
  ok(timed_out.errors[1] and timed_out.errors[1].error == 'timeout', 'and the timeout is named')
  ok(timed_out.outcomes[1].status == 'timeout', 'with the row it happened on')
end
write(config .. '/hooks.json', hooks_json({
  PreToolUse = { { name = 'leaky', matcher = 'bash',
    command = script('leaky', "echo 'token=sk-1234567890' >&2\nprintf '{}'") } },
}))
local leaky = pair('a hook that prints a secret', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if leaky then
  ok(leaky.blocked == false, 'its output is not a decision')
  ok(leaky.outcomes[1].detail ~= nil, 'the detail is stored')
end

-- ---- 7. the bus source -------------------------------------------------------------------------
write(config .. '/hooks.json', hooks_json({
  ['bus:session.message'] = { { name = 'on-message', command = answer('bus-one', json.encode({ systemMessage = 'a message arrived' })) },
    { name = 'second', command = answer('bus-two', '{}') } },
  ['bus:*'] = { { name = 'everything', command = answer('bus-all', '{}') } },
}))
local bus = pair('a bus publish', function(module)
  return module.bus('session.message', { id = 'e1' }, { session_id = 's' })
end)
if bus then
  ok(bus.ran == 3, 'the named topic and the wildcard both receive the publish: ran=' .. tostring(bus.ran))
  ok(bus.system_messages[1] == 'a message arrived', 'a bus hook can surface a message')
end
local bad_topic = pair('an empty bus topic', function(module) return { module.bus('', {}) } end)
if bad_topic then ok(bad_topic[1] == nil and bad_topic[2] == 'bus_topic_required', 'an empty topic is refused') end

-- ---- 8. the mods surface -----------------------------------------------------------------------
write(config .. '/hooks.json', json.encode({
  hooks = { PreToolUse = { { name = 'policy', matcher = 'bash', command = 'true' } } },
  mods = {
    statusline = {
      { name = 'model', command = script('status-model', 'printf "model %s" "$(sed -n \'s/.*"model":"\\([^"]*\\)".*/\\1/p\')"') },
      { name = 'broken-mod', command = script('status-broken', 'exit 3') },
    },
    commands = { { name = '/hello', description = 'say hello',
      -- The arguments arrive in the payload on stdin (the protocol for a mod), not in `$1`, so the
      -- command reads them from there.
      command = script('hello', [[awk -F'"args":"' '{split($2, b, "\""); printf "hello %s", b[1]}']]) } },
    keybindings = { { key = 'ctrl+g', command = 'git status', description = 'working tree' } },
  },
}))
native.reset()
local footer = pair('the footer segment', function(module)
  return module.statusline({ session_id = 's', model = 'test-model', runs = 3, tokens = 1200 })
end)
if footer then
  ok(type(footer) == 'string' and footer:find('model test-model', 1, true) ~= nil,
    'the segment carries the model it was told about: ' .. tostring(footer))
  ok(footer:find('!broken-mod', 1, true) ~= nil, 'a broken mod is named, not dropped: ' .. tostring(footer))
end
local command = pair('a custom command', function(module) return module.run_command('/hello', 'world', {}) end)
if command then ok(command.ok == true and command.output == 'hello world', 'the command runs with its arguments') end
local unknown = pair('an unknown custom command', function(module) return module.run_command('/nope', '', {}) end)
if unknown then ok(unknown.ok == false and unknown.error == 'unknown_hook_command', 'a typo is a refusal') end
local listed = pair('/hooks', function(module) return { module.list({}), module.report({}) } end)
if listed then
  ok(type(listed[2]) == 'string' and listed[2]:find('PreToolUse', 1, true) ~= nil, '/hooks lists the event')
  ok(listed[2]:find('keybinding', 1, true) ~= nil, 'and the key declaration it cannot dispatch')
end

-- ---- 9. the config errors an operator must see -------------------------------------------------
write(config .. '/hooks.json', '{ this is not json')
local broken_config = pair('a config that is not JSON', function(module) return module.config({}) end)
if broken_config then
  ok(broken_config.present == false, 'an invalid file is not a present source')
  ok(#broken_config.errors == 1 and broken_config.errors[1]:find('not valid JSON', 1, true) ~= nil,
    'and the error is reported')
end
write(config .. '/hooks.json', json.encode({ hooks = {
  NoSuchEvent = { { name = 'typo', command = 'true' } },
  PreToolUse = { { name = 'no-command' }, { name = 'empty', command = '  ' } },
}, mods = { commands = { { name = 'noslash', command = 'true' } } } }))
local typo = pair('a config with a typo', function(module) return module.config({}) end)
if typo then
  ok(#typo.errors == 4, 'a typo is visible, not silently dropped: ' .. tostring(#typo.errors))
  ok(typo.hooks.PreToolUse == nil or #typo.hooks.PreToolUse == 0, 'and the bad entries are not kept')
end
write(config .. '/hooks.json', '{ "PreToolUse": [ { "name": "bare", "command": "true" } ] }')
local bare = pair('a bare event map', function(module) return module.config({}) end)
if bare then
  ok(bare.hooks.PreToolUse and #bare.hooks.PreToolUse == 1, 'the flatter shape (no `hooks` key) is read too')
end

-- ---- 10. two sources, in order, and Claude Code behind the opt-in -------------------------------
local project = config .. '/project-fixture'
sh("mkdir -p '" .. project .. "/.wasm-agent'")
write(project .. '/.wasm-agent/hooks.json', hooks_json({
  PreToolUse = { { name = 'project-deny', matcher = 'bash', command = answer('projectdeny', json.encode({
    decision = 'block', reason = 'the project forbids it' })) } },
}))
write(config .. '/hooks.json', hooks_json({
  PreToolUse = { { name = 'node-allow', matcher = 'bash', command = answer('nodeallow', json.encode({ decision = 'approve' })) } },
}))
local ordered = pair('two sources', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's', workdir = project })
end)
if ordered then
  ok(ordered.ran == 2, 'both sources were read for the same event: ran=' .. tostring(ordered.ran))
  ok(ordered.blocked == true and ordered.blocked_by == 'project-deny', 'a later denial is not talked out of it')
  ok(ordered.permission == 'allow' and ordered.allowed_by == 'node-allow', 'and the earlier allow is still recorded')
end
sh("rm -rf '" .. project .. "'")

local home = paths.home()
sh("mkdir -p '" .. home .. "/.claude'")
write(home .. '/.claude/settings.json', json.encode({ hooks = { PreToolUse = {
  { matcher = 'Bash', hooks = { { type = 'command', command = answer('claude-deny', json.encode({ decision = 'block', reason = 'claude says no' })), timeout = 30 } } },
} } }))
write(config .. '/hooks.json', hooks_json({ PreToolUse = {
  { name = 'node', matcher = 'bash', command = 'true' } } }))
local without_opt_in = pair('Claude hooks without the opt-in', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if without_opt_in then
  ok(without_opt_in.ran == 1, 'another harness\'s hooks are not re-used behind the operator: ran='
    .. tostring(without_opt_in.ran))
end
write(config .. '/hooks.json', json.encode({
  hooks = { claude_compat = true, PreToolUse = { { name = 'node', matcher = 'bash', command = 'true' } } } }))
local with_opt_in = pair('Claude hooks with the opt-in', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if with_opt_in then
  ok(with_opt_in.ran == 2, 'the opt-in reads them, seconds-timeout included: ran=' .. tostring(with_opt_in.ran))
  ok(with_opt_in.blocked_by == 'PreToolUse#1', 'the entry is named the way the config reads: '
    .. tostring(with_opt_in.blocked_by))
  ok(with_opt_in.reason == 'claude says no', 'and its reason is the sentence')
end

-- ---- 11. ten hooks: the whole loop, in order ---------------------------------------------------
local many = {}
for index = 1, 10 do
  many[#many + 1] = { name = 'h' .. index, matcher = 'bash', command = answer('h' .. index, '{}') }
end
write(config .. '/hooks.json', hooks_json({ PreToolUse = many }))
local ten = pair('ten hooks', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if ten then
  ok(ten.ran == 10, 'all ten ran: ' .. tostring(ten.ran))
  local names = {}
  for _, row in ipairs(ten.outcomes) do names[#names + 1] = row.name end
  ok(table.concat(names, ',') == 'h1,h2,h3,h4,h5,h6,h7,h8,h9,h10', 'in the file\'s order: '
    .. table.concat(names, ','))
end

-- ---- 12. a Lua plugin hook still runs last, on both paths --------------------------------------
write(config .. '/hooks.json', hooks_json({ PreToolUse = { { name = 'node', matcher = 'bash', command = 'true' } } }))
local plugin_seen = 0
native.register('PreToolUse', function(payload, ctx)
  plugin_seen = plugin_seen + 1
  if payload.tool_name == 'bash' then return { systemMessage = 'the plugin saw it' } end
end, { name = 'plugin-watch', matcher = 'bash' })
local plugin = pair('a Lua plugin hook', function(module)
  return module.fire('PreToolUse', { tool_name = 'bash' }, { session_id = 's' })
end)
if plugin then
  ok(plugin.ran == 2, 'the config entry and the plugin both ran: ' .. tostring(plugin.ran))
  ok(plugin.outcomes[2].kind == 'lua' and plugin.outcomes[2].name == 'plugin-watch',
    'and the plugin is the one that runs last')
  ok(plugin.system_messages[1] == 'the plugin saw it', 'its systemMessage reaches the reader')
end

-- ---- report ------------------------------------------------------------------------------------
print(string.format('hooks seam: %d checks, %d failed, %d parity comparisons (ran), %d skipped',
  checks, failed, comparisons, skipped))
if failed > 0 then
  print('hooks seam FAILED')
  os.exit(1)
end
print('hooks seam ok')
