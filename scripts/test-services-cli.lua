-- The operator's service door (lua/core/services_cli.lua) and the master-only peer half of it.
--
-- Why this test exists: `wa services` answered "unknown command" while the only way to stop a service
-- component was a turn - which a model-less node cannot run (`docs/MODEL-LESS.md`). The failure this
-- door prevents was live on 11/11: a component that had started twice had to be stopped by hand.
--
-- What it proves, in order:
--   * every verb refuses with an exit code and a word, never silently: no verb, unknown verb, a verb
--     without a name, a name this node does not store;
--   * the CLI is dispatched from the one place `wa` dispatches commands (`lua/core/init.lua`), so the
--     verb exists in the binary an operator actually runs - not only as a module;
--   * the registry gate is the door's gate: a guest and a child agent are refused `start`/`stop` by the
--     same function the CLI and the peer capability call;
--   * with a service fixture installed, the whole lifecycle runs through the CLI: start, status, stop,
--     enable, disable - and `start`/`stop` do not change what happens at boot.
-- A fixture that is not installed is reported as a skip of the lifecycle half, never as a pass.
local json = dofile('lua/vendor/json.lua')
local services = dofile('lua/core/services.lua')
local cli = dofile('lua/core/services_cli.lua')
local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('SERVICES CLI CHECK FAILED: ' .. label) end
end
local function sleep_ms(ms)
  local began = host.monotonic_ms()
  while host.monotonic_ms() - began < ms do end
end

assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)', '[]')).ok)
local master = { role = 'master' }

-- Refusals: each one is a code AND a reason, because a script that stops a service must not read
-- "it refused" as "it stopped".
check(cli.run({}) == 2, 'no verb is a usage refusal')
check(cli.run({ 'help' }) == 0, 'help is a request, never a change')
check(cli.run({ 'frobnicate' }) == 2, 'an unknown verb is refused')
check(cli.run({ 'start' }) == 2, 'start without a name is refused')
check(cli.run({ 'status', 'no-such-service' }) == 1, 'status of a service this node does not store is refused')
check(cli.run({ 'stop', 'no-such-service' }) == 1, 'stop of a service this node does not store is refused')
check(cli.run({ 'enable', 'no-such-service' }) == 1, 'enable of a service this node does not store is refused')

-- The verb exists in the CLI an operator runs: `lua/core/init.lua` is the dispatch table `wa` falls
-- through to ("unknown command" came from there), and it must route `services` to this module.
local init = host.read_file('lua/core/init.lua') or ''
check(init:find('command == "services"', 1, true) ~= nil, 'wa dispatches a `services` command')
check(init:find('services_cli', 1, true) ~= nil, 'and sends it to lua/core/services_cli.lua')
check(init:find('services list|status|start|stop|enable|disable', 1, true) ~= nil, 'and names it in `wa help`')

-- The peer half is a capability of this node, gated by the same registry function: the gate that a
-- remote caller meets is the gate a guest meets here.
local server = host.read_file('lua/core/server.lua') or ''
check(server:find('capability == "services"', 1, true) ~= nil, 'the `services` peer capability has a branch')
check(server:find('services=true', 1, true) ~= nil, 'and is in the managed-capability list')
check(server:find('services = true', 1, true) ~= nil, 'and is graded `control` for the mesh')
check(services.control({ action = 'start', name = 'x' }, { role = 'guest' }).error == 'forbidden', 'a guest cannot start a service')
check(services.control({ action = 'stop', name = 'x' }, { role = 'guest' }).error == 'forbidden', 'a guest cannot stop one')
check(services.control({ action = 'start', name = 'x' }, { role = 'master', subagent = {} }).error == 'services_management_forbidden_for_subagent', 'a child agent cannot start one')
check(services.control({ action = 'stop', name = 'x' }, { role = 'master', subagent = {} }).error == 'services_management_forbidden_for_subagent', 'a child agent cannot stop one')

-- The lifecycle through the CLI, on a fixture this node has. `scripts/fast.sh` builds `svc-echo` for
-- this row and hands it over as `WA_SVC_ECHO_COMPONENT_WASM` (installed, pinned, in the row's own
-- component directory); a checkout run can name the same variable by hand. A run with no service
-- artifact at all reports the skip instead of claiming a pass.
local installed = {}
if host.components then
  for _, component in ipairs(json.decode(host.components()) or {}) do
    if component.ok and (component.name == 'svc-echo' or component.name == 'svc-echo-v1') then
      installed[#installed + 1] = component.name
    end
  end
end
if #installed == 0 and (host.getenv('WA_SVC_ECHO_COMPONENT_WASM') or '') ~= '' then
  installed[1] = 'svc-echo'
end
if #installed == 0 then
  print('services cli checks: ' .. checks .. ' (no service fixture installed; lifecycle checks skipped)')
  return
end
local name = installed[1]
local put = services.control({ action = 'put', definition = { name = name }, expected_revision = services.inventory().revision }, master)
check(put.ok and put.enabled == false, 'the fixture is stored disabled')

check(cli.run({ 'list' }) == 0, 'list prints')
check(cli.run({ 'list', '--json' }) == 0, 'list --json prints the registry answer')
check(cli.run({ 'start', name }) == 0, 'start runs it')
sleep_ms(1500)
local row = services.inventory().services[1]
check(row.live.state == 'running', 'running after `wa services start`: ' .. tostring(row.live.state))
check(row.enabled == false, 'start does not decide the boot question')
check(cli.run({ 'status', name }) == 0, 'status prints')
check(cli.run({ 'status', name, '--json' }) == 0, 'status --json prints the host answer')
check(cli.run({ 'stop', name }) == 0, 'stop stops it')
sleep_ms(200)
row = services.inventory().services[1]
check(row.live.state == 'not_running', 'stopped after `wa services stop`: ' .. tostring(row.live.state))
check(row.enabled == false, 'stop does not decide the boot question either')

check(cli.run({ 'enable', name }) == 0, 'enable')
sleep_ms(1500)
row = services.inventory().services[1]
check(row.enabled == true and row.live.state == 'running', 'enable starts it and remembers the boot decision')
check(services.autostart().started[name] ~= nil, 'and autostart finds it already running')
check(cli.run({ 'disable', name }) == 0, 'disable')
row = services.inventory().services[1]
check(row.enabled == false and row.live.state == 'not_running', 'disable stops it and forgets the boot decision')
check(services.control({ action = 'remove', name = name, expected_revision = services.inventory().revision }, master).ok, 'the fixture is removed again')

print('services cli ok: ' .. checks .. ' checks')
