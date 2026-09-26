local json=dofile('lua/vendor/json.lua')
local resources=dofile('lua/core/resources.lua')
local tools=dofile('lua/core/tools.lua')
local mode=host.getenv('WA_RESOURCE_MODE')
local a={user_id='alice',session_id='session-a',run_id='run-a'}
local b={user_id='bob',session_id='session-b',run_id='run-b'}
local function check(value,label) assert(value,label); print('CHECK '..label) end
if mode=='hold' then
  check(resources.begin(a).ok,'owner begins')
  check(resources.claim(a,{'client:local'}).ok,'owner reserves client')
  host.write_file(host.getenv('WA_RESOURCE_READY'),'ready')
  host.sleep(60000)
elseif mode=='contend' then
  check(resources.claim(b,{'client:local'}).error=='resource_busy','different process cannot interleave client effects')
  check(resources.reconcile({key='client:local',run='run-a',principal='alice',evidence='fixture probe'}).error=='resource_owner_active_or_unavailable','live process cannot be reconciled away')
  check(resources.begin({user_id='alice',session_id='session-a',run_id='second-a'}).error=='resource_busy','same session cannot run in two processes')
elseif mode=='recover' then
  check(resources.claim(b,{'client:local'}).error=='resource_busy','crash does not silently release effect ownership')
  check(resources.reconcile({key='client:local',run='wrong',principal='alice',evidence='fixture probe'}).error=='resource_owner_changed','stale ownership comparison refuses')
  check(resources.reconcile({key='client:local',run='run-a',principal='alice',evidence='fixture verified original process exited; mock client had no external effects'}).ok,'explicit evidenced reconciliation releases dead owner')
  check(resources.begin({user_id='alice',session_id='session-a',run_id='new-a'}).ok,'explicit new request can reclaim dead session without replay')
  check(resources.begin(b).ok,'independent session begins')
  local client=host.client
  host.client=function() return json.encode({error='fixture uncertain client failure'}) end
  local failed=tools.dispatch(nil,'client',{action='screenshot'},'master',b)
  host.client=client
  check(failed.error=='fixture uncertain client failure','client failure surfaced')
  check(resources.finish(b).ok,'failed run can settle')
  check(resources.claim(a,{'client:local'}).error=='resource_busy','failed client effects retain durable ownership after settlement')
  check(tools.dispatch(nil,'resource',{action='list'},'guest',{}).error=='forbidden_for_role:guest','guest cannot inspect or release claims')
  check(resources.reconcile({key='client:local',run='run-b',principal='bob',evidence='mock client failure inspected; no real effect'}).ok,'settled uncertain owner can be explicitly reconciled')
  check(resources.claim(a,{'client:local'}).ok,'resource usable after reconciliation')
  check(resources.finish(a).ok,'normal completion releases owned resources')
else error('unknown fixture mode') end
print('resource claims '..mode..' ok')
