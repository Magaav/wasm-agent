-- Service components registry (lua/core/services.lua) over the real host runner (services.rs).
-- Needs the fixtures installed in WA_COMPONENTS_DIR (scripts/build-components.sh svc-echo svc-echo-v1):
-- `svc-echo` speaks wa:kernel@0.2 (native async) and `svc-echo-v1` speaks wa:kernel@0.1, so the same
-- registry lifecycle is proven for both runners; a fixture that is not installed is reported as a
-- skip of that fixture, never as a pass.
local json=dofile('lua/vendor/json.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)','[]')).ok)
local services=dofile('lua/core/services.lua')
local tools=dofile('lua/core/tools.lua')
local checks=0
local function check(value,label)checks=checks+1;if not value then error('SERVICE CHECK FAILED: '..label)end end
local master={role='master'}
local function control(action,extra)local a=extra or {};a.action=action;a.expected_revision=services.inventory().revision;return services.control(a,master)end
local function sleep_ms(ms)local t=host.monotonic_ms();while host.monotonic_ms()-t<ms do end end

check(services.validate({name='svc-echo',net={'127.0.0.1:*','*.whatsapp.net:443','web.whatsapp.com:443'}})==nil,'definition with exact, port-wildcard and suffix nets')
check(services.validate({name='Bad'})=='invalid_service_name','name fenced')
check(services.validate({name='x',net={'evil host:1'}})=='invalid_service_net','net fenced')
check(services.validate({name='x',env={K='/etc/passwd'}})=='service_credentials_require_references','env takes names')
check(services.validate({name='x',file_env={K='/home/u/token'}})==nil,'file_env takes a path')
check(services.validate({name='x',program='node'})=='unsupported_service_definition_field:program','no command fields')
check(services.control({action='list'},{role='guest'}).error=='forbidden','guest refused')
check(services.control({action='list'},{role='master',subagent={}}).error=='services_management_forbidden_for_subagent','child refused')
check(services.control({action='put',definition={name='svc-echo'}},master).error=='services_store_revision_changed','explicit revision required')
local names={};for _,s in ipairs(tools.admin)do names[s['function'].name]=true end
check(names.services,'services is an admin tool')

local installed={}
local present={}
for _,c in ipairs(json.decode(host.components()) or {})do if c.ok then present[c.name]=true end end
for _,name in ipairs({'svc-echo','svc-echo-v1'})do if present[name] then installed[#installed+1]=name end end
if #installed==0 then print('service checks: '..checks..' (no service fixture installed; runtime checks skipped)');return end

-- The same lifecycle for each installed fixture: one is wa:kernel@0.1 (polled) and one is
-- wa:kernel@0.2 (awaited); a node runs whatever a definition names, and the registry does not care
-- which contract the module speaks.
for _,name in ipairs(installed)do
  local function one(action,extra)local a=extra or {};a.action=action;a.name=name;a.expected_revision=services.inventory().revision;return services.control(a,master)end
  check(control('put',{definition={name=name,net={'127.0.0.1:9'},config={refused='127.0.0.2:9'}}}).ok,'store disabled definition: '..name)
  local live=services.inventory().services[1].live
  check(services.inventory().services[1].enabled==false and live.state=='not_running','put does not start: '..name)
  local enabled=one('enable')
  check(enabled.ok and enabled.enabled and enabled.start.ok,'enable starts it: '..name..' '..tostring(enabled.error or (enabled.start and enabled.start.error)))
  sleep_ms(1500)
  live=services.inventory().services[1].live
  check(live.state=='running','running after enable: '..name)
  local log=services.control({action='logs',name=name},master).log or ''
  check(log:find('heartbeat',1,true)~=nil,'heartbeat in the log: '..name)
  check(log:find('refused -13',1,true)~=nil,'an ungranted dial is refused inside the service: '..name)
  check(log:find('kv ok',1,true)~=nil,'the kv round trip ran inside the service: '..name)
  check(services.autostart().started[name].already_running==true,'autostart is idempotent for a running service: '..name)
  check(one('put',{definition={name=name}}).error:find('service_enabled',1,true)~=nil,'an enabled definition cannot change underneath: '..name)
  local restarted=one('restart')
  check(restarted.ok and restarted.started,'restart: '..name..' '..json.encode(restarted))
  local disabled=one('disable')
  check(disabled.ok and disabled.stop.was_running,'disable stops it: '..name)
  check(services.inventory().services[1].live.state=='not_running','stopped after disable: '..name)
  check(services.autostart().started[name]==nil,'autostart skips a disabled service: '..name)
  check(one('remove').removed==true and #services.inventory().services==0,'remove: '..name)
end
print('service checks: '..checks)
