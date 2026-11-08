-- The shipped default guard (docs/HOOK-EVENTS.md, "Shipped default guard"; docs/FLEET-OPS.md).
--
-- What it proves, and what it deliberately does not:
--   * it refuses the two actions that took this fleet offline - editing the rendezvous admin set / its
--     drop-in, and restarting `wa-rendezvous` - with the exact sentence the operator asked for, and the
--     safe path named;
--   * it allows the neighbouring commands, including *reading* the same files and the documented safe
--     path (`wa fleet push-roster`). A guard that blocks diagnosis is a guard that gets removed;
--   * it is shipped on by default (no hooks.json in this scratch home) and visible in `/hooks`;
--   * it is overridable, in both documented ways: an operator hook named `guard-destructive` replaces it,
--     and `WASM_AGENT_DEFAULT_GUARD=off` turns it off;
--   * a refusal is a refusal: the tool call returns `effect = "none"` and no operation id, so "refused"
--     can never be a result that ran anyway.
--
-- No network, no node, no real service is touched: every refused command is refused before it runs.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local config = paths.config()
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local hooks = dofile('lua/core/hooks.lua')
local guard = dofile('lua/core/hooks_defaults.lua')

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end
local function write(path, text) assert(host.write_file(path, text), 'write ' .. path) end
assert(host.exec("mkdir -p '" .. config .. "'", '', 30))

local REASON = guard.REASON
ok(type(REASON) == 'string' and REASON:find('this detaches nodes that pin the admin set', 1, true) ~= nil,
  'the refusal carries the operator\'s sentence')
ok(REASON:find('wa fleet push-roster', 1, true) ~= nil, 'and names the safe path')

-- ---- 1. the judgement, as a pure function of the call ---------------------------------------------
local refused = {
  { 'the admin list appended with sed -i', 'bash',
    'sudo sed -i "s/^WASM_AGENT_NETWORK_ADMINS=.*/WASM_AGENT_NETWORK_ADMINS=me/" /etc/systemd/system/wa-rendezvous.service.d/managed.conf' },
  { 'the admin list rewritten with tee', 'bash',
    'printf "WASM_AGENT_NETWORK_ADMINS=me\\n" | sudo tee /etc/systemd/system/wa-rendezvous.service.d/managed.conf' },
  { 'the drop-in edited without naming the variable', 'bash',
    'sudo sed -i "s/nextcloud/me/" /etc/systemd/system/wa-rendezvous.service.d/managed.conf' },
  { 'the rendezvous restarted', 'bash', 'sudo systemctl restart wa-rendezvous' },
  { 'the rendezvous stopped', 'bash', 'systemctl stop wa-rendezvous.service' },
  { 'the rendezvous reloaded', 'bash', 'systemctl --user reload wa-rendezvous' },
  { 'the rendezvous restarted through service(8)', 'bash', 'sudo service wa-rendezvous restart' },
  { 'the drop-in written through the write tool', 'write',
    nil, '/etc/systemd/system/wa-rendezvous.service.d/managed.conf' },
  { 'an operation that restarts the rendezvous', 'operation', 'systemctl restart wa-rendezvous' },
}
for _, case in ipairs(refused) do
  local input = {}
  if case[3] then input.command = case[3] end
  if case[4] then input.path = case[4] end
  local judgement = guard.judge(case[2], input)
  ok(judgement ~= nil, 'refuses ' .. case[1])
  ok(judgement and judgement.rule ~= nil, 'and names the rule for ' .. case[1])
end

local allowed = {
  { 'reading the drop-in', 'bash', 'cat /etc/systemd/system/wa-rendezvous.service.d/managed.conf' },
  { 'grepping for the variable', 'bash', 'grep -rn WASM_AGENT_NETWORK_ADMINS /etc/systemd/system' },
  { 'asking the service for its state', 'bash', 'systemctl status wa-rendezvous' },
  { 'reading the journal', 'bash', 'journalctl -u wa-rendezvous --since "1 hour ago" | tail -50' },
  { 'the documented safe path', 'bash', 'wa fleet push-roster nextcloud' },
  { 'a different unit restart', 'bash', 'sudo systemctl restart wa-node' },
  { 'editing an unrelated config', 'bash', 'sed -i "s/a/b/" ~/.config/wa/other.conf' },
  { 'a plain command', 'bash', 'printf ok' },
  { 'reading the drop-in through the read tool', 'read', nil, '/etc/systemd/system/wa-rendezvous.service.d/managed.conf' },
  { 'writing a doc that mentions the variable', 'write', 'WASM_AGENT_NETWORK_ADMINS is pinned per node',
    '/home/operator/notes/fleet.md' },
  { 'a restart word in a grep', 'bash', 'git log --grep "restart wa-rendezvous" -n 5' },
}
for _, case in ipairs(allowed) do
  local input = {}
  if case[3] then input.command = case[3] end
  if case[4] then input.path = case[4] end
  ok(guard.judge(case[2], input) == nil, 'allows ' .. case[1])
end

-- ---- 2. it is shipped on, and visible -------------------------------------------------------------
ok(hooks.configured() == false, 'this scratch home has no hooks.json (nothing is configured)')
local shipped = hooks.guard({})
ok(shipped.name == 'guard-destructive' and shipped.origin == 'shipped', '/hooks names the shipped guard')
ok(shipped.enabled == true and shipped.basis == 'shipped', 'it is on by default')
ok(shipped.override:find('hooks.json', 1, true) ~= nil, 'and /hooks says how to override it')
local listed = hooks.list({})
ok(listed.guard and listed.guard.name == 'guard-destructive', 'the list carries the guard row')
local row
for _, event in ipairs(listed.events) do
  if event.event == 'PreToolUse' then
    for _, entry in ipairs(event.entries) do if entry.name == 'guard-destructive' then row = entry end end
  end
end
ok(row ~= nil and row.origin == 'shipped', 'it appears as a PreToolUse entry with origin shipped')
ok(hooks.report({}):find('shipped guard', 1, true) ~= nil, 'the /hooks text prints it')

-- ---- 3. the refusal through the engine and through the tool path ---------------------------------
local refused_verdict = hooks.fire('PreToolUse',
  { tool_name = 'bash', tool_input = { command = 'sudo systemctl restart wa-rendezvous' } }, { session_id = 's' })
ok(refused_verdict.blocked == true, 'the engine blocks the restart')
ok(refused_verdict.blocked_by == 'guard-destructive', 'and names the guard as the blocker')
ok(refused_verdict.reason == REASON, 'with the operator\'s sentence, byte for byte')
ok(refused_verdict.ran == 1 and #refused_verdict.outcomes == 1, 'one hook ran: the guard')
ok(refused_verdict.outcomes[1].origin == 'shipped', 'and the outcome records where it came from')
ok(refused_verdict.guard and refused_verdict.guard.status == 'deny', 'the verdict says the guard denied')
ok(#refused_verdict.system_messages == 1
  and refused_verdict.system_messages[1]:find('guard-destructive', 1, true) ~= nil,
  'the reader is told which guard refused')

local allowed_verdict = hooks.fire('PreToolUse',
  { tool_name = 'bash', tool_input = { command = 'systemctl status wa-rendezvous' } }, { session_id = 's' })
ok(allowed_verdict.blocked == false and allowed_verdict.ran == 0, 'an allowed command runs nothing')
ok(allowed_verdict.guard and allowed_verdict.guard.status == 'allow', 'and the guard says it allowed it')

-- The tool path: the refusal is a result with no effect, never an effect with a warning.
local ctx = { session_id = 'guard-test', user_id = 'master' }
local denied = tools.dispatch(memory, 'bash', { command = 'sudo systemctl restart wa-rendezvous' }, 'master', ctx)
ok(type(denied) == 'table' and denied.error == 'hook_denied', 'the bash tool refuses it before running')
ok(denied.denied_by == 'guard-destructive', 'the result names the guard')
ok(denied.reason == REASON, 'and carries the same sentence')
ok(denied.effect == 'none', 'nothing was started (effect = none)')
ok(denied.operation_id == nil and denied.state == nil, 'and there is no operation to collect')
local denied_write = tools.dispatch(memory, 'write',
  { path = '/etc/systemd/system/wa-rendezvous.service.d/managed.conf', content = 'WASM_AGENT_NETWORK_ADMINS=me\n' },
  'master', ctx)
ok(type(denied_write) == 'table' and denied_write.error == 'hook_denied', 'the write tool refuses the drop-in')

-- An unrelated command still runs: the guard is a refusal of two actions, not a brake on work.
local ran = tools.dispatch(memory, 'bash', { command = 'printf guard-allows' }, 'master', ctx)
ok(type(ran) == 'table' and ran.ok == true, 'an unrelated bash command still runs')
ok(tostring(ran.stdout or ''):find('guard-allows', 1, true) ~= nil, 'and its output arrives')

-- ---- 4. overridable, visibly ----------------------------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'guard-destructive', matcher = 'bash', command = 'true' } } } }))
hooks.reset()
local replaced = hooks.guard({})
ok(replaced.enabled == false and replaced.basis == 'replaced_by_config',
  'an operator hook with the guard\'s name replaces it (config precedence, not a second rule)')
local after_replace = hooks.fire('PreToolUse',
  { tool_name = 'bash', tool_input = { command = 'sudo systemctl restart wa-rendezvous' } }, { session_id = 's' })
ok(after_replace.blocked == false, 'and the replaced guard no longer refuses')
ok(after_replace.ran == 1 and after_replace.outcomes[1].name == 'guard-destructive',
  'the operator\'s own hook is what ran')

os.remove(config .. '/hooks.json')
hooks.reset()
ok(hooks.guard({}).enabled == true, 'removing the override restores the shipped guard')

-- The environment switch, for a node that has decided otherwise.
local real_getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_DEFAULT_GUARD' then return 'off' end
  return real_getenv(key)
end
hooks.reset()
local off = hooks.guard({})
host.getenv = real_getenv
hooks.reset()
ok(off.enabled == false and off.basis == 'disabled_by_env', 'WASM_AGENT_DEFAULT_GUARD=off turns it off')

-- ---- 5. it is the PreToolUse boundary only --------------------------------------------------------
local other = hooks.fire('PostToolUse', { tool_name = 'bash', tool_input = { command = 'systemctl restart wa-rendezvous' } },
  { session_id = 's' })
ok(other.blocked == false and other.guard == nil, 'the guard is not a PostToolUse rule')

print(string.format('fleetops guard: %d checks, %d failed', checks, failed))
if failed > 0 then error('fleetops guard: ' .. failed .. ' failed checks') end
