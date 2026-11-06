-- Node governance at the runner, for both `wa:kernel` contracts (docs/GRANT-POLICY.md, "How the host
-- wires it"). The unit tests (`cargo test -p wa-host node_policy::tests service_components_v2::tests`)
-- prove the decision and the mapping; this proves the wiring inside a *running* service, which is the
-- thing a deploy changes: with a policy file that rules `net.dial` and `http.request` but says nothing
-- about `kv.write`, a component's write is refused `no_policy` - on the 0.1 poll contract and on the
-- 0.2 native-async one - while the manifest grant still refuses an ungranted address first.
--
-- Needs the fixtures installed in WA_COMPONENTS_DIR (`scripts/build-components.sh svc-echo svc-echo-v1`)
-- and its own home (`scripts/test.sh` gives it one): the policy is loaded once per process, so a home
-- that already answered a policy question would not see the file written below.
local json=dofile('lua/vendor/json.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)','[]')).ok)
local services=dofile('lua/core/services.lua')
local checks=0
local function check(value,label)checks=checks+1;if not value then error('GOVERNANCE SERVICE CHECK FAILED: '..label)end end
local function sleep_ms(ms)local t=host.monotonic_ms();while host.monotonic_ms()-t<ms do end end
local master={role='master'}
local function control(action,extra)local a=extra or {};a.action=action;a.expected_revision=services.inventory().revision;return services.control(a,master)end

local paths=host.paths()
check(type(paths.config)=='string' and paths.config~='','host.paths() names the config directory')
local policy_path=paths.config..'/policy.json'
check(host.path_kind(policy_path)=='missing','this home starts with no policy file')

-- Write the policy before anything asks a policy question: the layer loads once, on the first check.
-- Loopback is allowed (the fixture dials it), the store write is deliberately absent.
local rules={}
for _,name in ipairs({'svc-echo','svc-echo-v1'}) do
  rules[name]={capabilities={
    ['net.dial']={allow={'127.0.0.1:*','[::1]:*'},rate={per_minute=60,burst=120}},
    ['http.request']={allow={'127.0.0.1:*','[::1]:*'},rate={per_minute=60,burst=120}},
  }}
end
check(host.write_file(policy_path,json.encode({version=1,sensitive_capabilities={},components=rules}))==true,'the policy file is written')
local status=json.decode(host.policy_status())
check(status.mode=='policy','a policy file turns the policy layer on ('..tostring(status.mode)..')')
check(status.loaded==true and status.policy.components==2,'both fixtures are named in the loaded policy')
check(status.policy.rules==4,'two rules each ('..tostring(status.policy.rules)..')')

-- The component capability is not in every host; its absence is a reported skip, never a pass.
local installed={}
if host.components then
  local present={}
  for _,c in ipairs(json.decode(host.components()) or {})do if c.ok then present[c.name]=true end end
  for _,name in ipairs({'svc-echo','svc-echo-v1'})do if present[name] then installed[#installed+1]=name end end
end
if #installed==0 then print('node governance service checks: 0 (no service fixture installed; runtime checks skipped)') return end

for _,name in ipairs(installed)do
  -- The baseline, so "this service caused a refusal" is a delta and not a total that a previous run
  -- in the same component directory could have left behind.
  local denied_before=(json.decode(host.policy_status()).decisions or {}).deny or 0
  check(control('put',{definition={name=name,net={'127.0.0.1:9'},config={dial='http://127.0.0.1:9/note',refused='http://127.0.0.2:9/note'}}}).ok,'put: '..name)
  local enabled=control('enable',{name=name})
  check(enabled.ok and enabled.start.ok,'enable starts it: '..name..' '..tostring(enabled.error or (enabled.start and enabled.start.error)))
  -- The 0.2 fixture parks in a timer between ticks; give both contracts time to reach the kv step and
  -- then the dials (the refused one is where the grant and the policy meet).
  local log,deadline='',host.monotonic_ms()+20000
  while host.monotonic_ms()<deadline do
    log=services.control({action='logs',name=name},master).log or ''
    if log:find('no_policy',1,true) and log:find('refused -13',1,true)
       and (log:find('dial failed',1,true) or log:find('dial ok',1,true)) then break end
    sleep_ms(100)
  end
  -- The policy is live and the guest is told why: `no_policy` is the stable reason word.
  check(log:find('kv unavailable',1,true)~=nil,'the policy refused the kv write: '..name..' log='..log)
  check(log:find('no_policy',1,true)~=nil,'the refusal carries its reason: '..name)
  -- The layers are in the documented order: the address the manifest never granted is refused by the
  -- manifest, before the policy is even asked.
  check(log:find('refused -13 (grant)',1,true)~=nil,'the ungranted address is still refused by the grant: '..name)
  -- A dial the policy allows is not refused by it: it reaches the network and fails to connect.
  check(log:find('dial failed',1,true)~=nil,'a policy-allowed dial is attempted and reaches the network (no peer on :9): '..name..' log='..log)
  check(services.inventory().services[1].live.state=='running','the service kept running after a refused call: '..name)
  -- Visible, not inferred: the refusal is in the view, and the view carries no target.
  local after=json.decode(host.policy_status())
  check(after.decisions.deny>denied_before,'the refusal is counted for this run: '..name..' ('..denied_before..' -> '..tostring(after.decisions.deny)..')')
  check(after.decisions.checks>=1 and after.decisions.manifest_mode==0,'a loaded policy decides nothing in manifest mode: '..name)
  local seen=false
  for _,refusal in ipairs(after.recent_refusals)do
    if refusal.component==name and refusal.capability=='kv.write' and refusal.reason=='no_policy' then seen=true end
  end
  check(seen,'recent_refusals names '..name..' kv.write no_policy: '..json.encode(after.recent_refusals))
  check(json.encode(after.recent_refusals):find('svc%-echo/counter')==nil,'a refusal carries no key text')
  check(control('disable',{name=name}).ok,'disable stops it: '..name)
  check(control('remove',{name=name}).removed==true,'remove: '..name)
end

-- Telemetry saw the calls: the runner's own guard is what records them, so a series per component
-- proves the 0.2 host functions are instrumented (not only the 0.1 ones).
local whole=json.decode(host.telemetry(''))
check(type(whole.stats)=='table' and whole.stats.components>=1,'a running component left a series: '..json.encode(whole.stats))
check(type(whole.store)=='table' and type(whole.store.quotas)=='table','the store report travels with it')
check(whole.store.quotas.service_log_bytes==52428800,'a service log is capped at 50 MiB per component')
check(whole.policy.loaded==true and whole.policy.mode=='policy','the summary carries the mode')
print('node governance service checks: '..checks..' ('..#installed..' fixture(s): '..table.concat(installed,',')..')')
