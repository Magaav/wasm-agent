-- Service components registry (lua/core/services.lua) over the real host runner (services.rs).
-- Needs the svc-echo fixture installed in WA_COMPONENTS_DIR (scripts/build-components.sh svc-echo);
-- without it only the definition and authority checks run.
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

local installed=false
for _,c in ipairs(json.decode(host.components()) or {})do if c.name=='svc-echo' and c.ok then installed=true end end
if not installed then print('service checks: '..checks..' (svc-echo not installed; runtime checks skipped)');return end

check(control('put',{definition={name='svc-echo',net={'127.0.0.1:9'},config={refused='127.0.0.2:9'}}}).ok,'store disabled definition')
check(services.inventory().services[1].enabled==false and services.inventory().services[1].live.state=='not_running','put does not start')
local enabled=control('enable',{name='svc-echo'})
check(enabled.ok and enabled.enabled and enabled.start.ok,'enable starts it: '..tostring(enabled.error or (enabled.start and enabled.start.error)))
sleep_ms(1200)
local live=services.inventory().services[1].live
check(live.state=='running','running after enable')
local log=services.control({action='logs',name='svc-echo'},master).log or ''
check(log:find('heartbeat',1,true)~=nil,'heartbeat in the log')
check(log:find('refused -13',1,true)~=nil,'an ungranted dial is refused inside the service')
check(services.autostart().started['svc-echo'].already_running==true,'autostart is idempotent for a running service')
check(control('put',{definition={name='svc-echo'}}).error:find('service_enabled',1,true)~=nil,'an enabled definition cannot change underneath')
local restarted=services.control({action='restart',name='svc-echo'},master)
check(restarted.ok and restarted.started,'restart: '..json.encode(restarted))
local disabled=control('disable',{name='svc-echo'})
check(disabled.ok and disabled.stop.was_running,'disable stops it')
check(services.inventory().services[1].live.state=='not_running','stopped after disable')
check(services.autostart().started['svc-echo']==nil,'autostart skips a disabled service')
check(control('remove',{name='svc-echo'}).removed==true and #services.inventory().services==0,'remove')
print('service checks: '..checks)
