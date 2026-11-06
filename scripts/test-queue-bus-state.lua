-- The three host providers of p2c, end to end, in one running service component:
--   * `wa:queue` (docs/QUEUE.md)  — produce -> consume -> done, dedupe, a progress stream, the admin
--     surface, and a queue name outside the manifest grant refused;
--   * `wa:bus` (docs/BUS.md)      — publish -> subscribe on the component's own topic, `source` set
--     by the host, and a topic outside the namespace refused;
--   * versioned state (docs/STATE.md) — a v1 namespace, then a manifest that declares
--     `state_version: 2`, migrated on a snapshot copy and swapped in before the guest starts; and a
--     version with no step in the host's registry refused with the old state intact.
--
-- Needs the fixture installed (`scripts/build-components.sh svc-queue-echo`, which scripts/test.sh
-- does into its own component directory). Without it this says so and returns: a skip is reported as
-- a skip, never as a pass.
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(value,label)checks=checks+1;if not value then error('QUEUE/BUS/STATE CHECK FAILED: '..label)end end
local function sleep_ms(ms)local t=host.monotonic_ms();while host.monotonic_ms()-t<ms do end end
local function text(value)return tostring(value or '')end

local name='svc-queue-echo'
local dir=host.getenv('WA_COMPONENTS_DIR') or ''
local present=false
if host.components then
  for _,component in ipairs(json.decode(host.components()) or {})do
    if component.ok and component.name==name then present=true end
  end
end
if not (present and host.service and host.state)then
  print('queue, bus and state checks: fixture not installed (runtime checks skipped)')
  return
end

local function call(request)return json.decode(host.service(json.encode(request)))end
local function state_status()return json.decode(host.state(json.encode({action='status',name=name})))end
local function start(attempt)return call({action='start',name=name,config={tick_ms=100,attempt=attempt==true}})end
local function stop()return call({action='stop',name=name})end
local function log_text()return text(call({action='logs',name=name,bytes=1<<20}).log)end
local function manifest_path()return dir..'/'..name..'.json' end
local function write_state_version(version)
  local manifest=host.read_file(manifest_path())
  check(manifest~=nil,'the installed manifest is readable')
  local rewritten,n=manifest:gsub('"state_version"%s*:%s*%d+','"state_version": '..tostring(version))
  check(n==1,'the manifest declares a state_version to rewrite')
  host.write_file(manifest_path(),rewritten)
end

-- 1. A v1 install: an empty namespace starts at the version the component declares, and the guest
--    writes the v1 shape of its own note.
local first=start(true)
check(first.ok,'the v1 install started: '..json.encode(first))
check(first.state and first.state.state=='fresh' and first.state.schema==1,'a fresh namespace at the declared version 1: '..json.encode(first.state))
check(first.sha256~=nil,'the pin is reported back')
sleep_ms(1500)
local log1=log_text()
check(log1:find('state v1 fresh',1,true)~=nil,'the guest wrote its v1 note: '..log1)
-- The queue: one job, one dedupe hit, a progress chunk, a settle, and the admin counts.
check(log1:find('queue ok',1,true)~=nil,'produce -> consume -> done ran: '..log1)
check(log1:find('deduped=true',1,true)~=nil,'one dedupe key, one job: '..log1)
check(log1:find('chunks=1',1,true)~=nil,'the progress stream carried the chunk the worker appended: '..log1)
check(log1:find('Done',1,true)~=nil and log1:find('state=State::Done',1,true)~=nil,'the job settled as done: '..log1)
check(log1:find('queue stats ready=0 done=1',1,true)~=nil,'the admin surface counts the settled job: '..log1)
-- The bus: our own event came back on our own subscription, with the host-set source.
check(log1:find('bus ok',1,true)~=nil,'publish reached the subscription: '..log1)
check(log1:find('matched=1 delivered=1',1,true)~=nil,'the publish report is the real fan-out: '..log1)
check(log1:find('source='..name,1,true)~=nil,'the host set the event source, not the guest: '..log1)
check(log1:find('payload=hello',1,true)~=nil,'the opaque payload survived the round trip: '..log1)
check(log1:find('bus done delivered=',1,true)~=nil,'a second fact went out: '..log1)
-- The grants: a queue name and a topic outside the manifest are refusals the guest sees.
check(log1:find('queue refused',1,true)~=nil,'a queue outside the granted namespaces is refused: '..log1)
check(log1:find('bus refused',1,true)~=nil,'a topic outside the granted patterns is refused: '..log1)
check(log1:find('refusal missing',1,true)==nil,'no refusal is missing where one is expected: '..log1)

-- 2. The upgrade: the same module, a manifest that declares state_version 2. The host snapshots the
--    namespace, migrates a copy, and only then swaps it in; the guest therefore starts on v2 data.
check(stop().was_running==true,'the v1 instance stopped')
write_state_version(2)
local second=start(false)
check(second.ok,'the v2 install started: '..json.encode(second))
check(second.state and second.state.state=='migrated','the install migrated rather than restarted: '..json.encode(second.state))
check(second.state and second.state.from==1 and second.state.to==2,'the migration went 1 -> 2: '..json.encode(second.state))
check(second.state and text(second.state.snapshot)~='','the pre-migration snapshot was kept: '..json.encode(second.state))
sleep_ms(1000)
local log2=log_text()
check(log2:find('state v2 migrated value=written at v1',1,true)~=nil,'the guest reads the migrated shape with the old value: '..log2)
check(log2:find('state v2 stale',1,true)==nil,'the v1 key did not survive the migration: '..log2)
local status=state_status()
check(status.ok and status.schema==2,'the namespace reports schema 2: '..json.encode(status))
check(status.snapshots and status.snapshots>=1,'the snapshot directory has a backup: '..json.encode(status))

-- 3. A version this host has no step for is refused, and refusing must not touch the state: that is
--    the "transactional" half of the install, and the only half a person can see from outside.
check(stop().was_running==true,'the v2 instance stopped')
write_state_version(3)
local third=start(false)
check(third.ok==false,'an install with no step path is refused')
check(text(third.error):find('state_no_migration_path',1,true)~=nil,'the refusal names the missing step: '..json.encode(third))
local after=state_status()
check(after.ok and after.schema==2,'the refused install left the state at schema 2: '..json.encode(after))
local live=call({action='status',name=name})
check(live.state=='not_running','a refused install starts nothing: '..json.encode(live))

-- 4. Back to the version the state is at: no work, and the guest still reads v2 data.
write_state_version(2)
local fourth=start(false)
check(fourth.ok,'the restored manifest starts: '..json.encode(fourth))
check(fourth.state and fourth.state.state=='up-to-date','a namespace already at the version is up to date: '..json.encode(fourth.state))
sleep_ms(800)
check(log_text():find('state v2 migrated',1,true)~=nil,'the guest still reads the migrated shape')
check(stop().was_running==true,'the final instance stopped')

print('queue, bus and state checks: '..checks)
