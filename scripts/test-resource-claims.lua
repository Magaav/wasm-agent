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
elseif mode=='reuse' then
  -- A refusal that never reached the client is not an uncertain effect: uncertainty is
  -- for unknown effects, and branding a run that mistyped something costs it the client.
  local d={user_id='dave',session_id='session-d',run_id='run-d'}
  check(resources.begin(d).ok,'reuse: independent run begins')
  local real=host.client
  host.client=function(action,args) return json.encode({ok=false,error='client_not_connected',connected=false,effect='none'}) end
  local refused=tools.dispatch(nil,'client',{action='click',x=1,y=1},'master',d)
  check(refused.error=='client_not_connected','reuse: a pre-effect refusal is surfaced')
  check(resources.claim(d,{'client:local'}).ok,'reuse: a refusal that never reached the client leaves no uncertainty')
  check(resources.finish(d).ok,'reuse: independent run settles')

  -- A node-only spell must not claim the client's resource. Classification
  -- inspects the saved steps/checks, not the untrusted target label.
  local spells=dofile('lua/core/spells.lua')
  local old_exec=host.exec
  host.exec=function() return json.encode({ok=true,code=0,stdout='{"ready":true}'}) end
  local node_spec={name='resource-node-only',target={node='local'},
    steps={{kind='run',script='fixture',expect={ready=true}}},
    post={{kind='run',script='fixture',expect={ready=true}}}}
  check(spells.save(node_spec).ok,'reuse: node-only spell saved')
  check(spells.needs_client(node_spec.name)==false,'reuse: run checks do not need client')
  local holder={user_id='holder',session_id='holder-session',run_id='holder-run'}
  check(resources.begin(holder).ok and resources.claim(holder,{'client:local'}).ok,
    'reuse: another owner holds client')
  local node_owner={user_id='no-client',session_id='node-session',run_id='node-run'}
  check(resources.begin(node_owner).ok,'reuse: node-only owner begins')
  local node_result=tools.dispatch(nil,'spell_run',{name=node_spec.name},'master',node_owner)
  check(node_result.settled==true,'reuse: node-only spell runs despite another client owner')
  local mixed_spec={name='resource-mixed',target={node='local'},
    steps={{kind='run',script='fixture'}},post={{script='document.title',truthy=true}}}
  check(spells.save(mixed_spec).ok and spells.needs_client(mixed_spec.name),
    'reuse: browser postcondition makes a spell client-bound regardless of target')
  local blocked_spell=tools.dispatch(nil,'spell_run',{name=mixed_spec.name},'master',node_owner)
  check(blocked_spell.error=='resource_busy','reuse: mixed spell cannot bypass client owner')
  local node_chain=spells.compose({name='resource-node-chain',
    parts={{name=node_spec.name},{name=node_spec.name}}})
  check(node_chain.ok and not spells.needs_client(node_chain.name),
    'reuse: composed run-only spells remain node-only')
  check(tools.dispatch(nil,'spell_run',{name=node_chain.name},'master',node_owner).settled==true,
    'reuse: composed node-only spell runs despite another client owner')
  local mixed_chain=spells.compose({name='resource-mixed-chain',
    parts={{name=node_spec.name},{name=mixed_spec.name}}})
  check(mixed_chain.ok and spells.needs_client(mixed_chain.name),
    'reuse: composed browser check remains client-bound')
  check(tools.dispatch(nil,'spell_run',{name=mixed_chain.name},'master',node_owner).error=='resource_busy',
    'reuse: composed mixed spell cannot bypass client owner')
  check(resources.finish(node_owner).ok and resources.finish(holder).ok,'reuse: both owners settle')
  for _,name in ipairs({node_spec.name,mixed_spec.name,node_chain.name,mixed_chain.name}) do spells.remove(name) end
  host.exec=old_exec

  -- A write refused before it was dispatched - nothing to run - is not an uncertain
  -- effect either: the node marks `client_not_connected`, and Lua marks its own
  -- argument refusals the same way.
  local e={user_id='erin',session_id='session-e',run_id='run-e'}
  check(resources.begin(e).ok,'reuse: third run begins')
  local empty=tools.dispatch(nil,'shell',{command=''},'master',e)
  check(empty.error=='command_required' and empty.effect=='none','reuse: a pre-dispatch argument refusal says it had no effect')
  check(resources.claim(e,{'client:local'}).ok,'reuse: an argument refusal leaves no uncertainty')
  check(resources.finish(e).ok,'reuse: third run settles')

  local c={user_id='carol',session_id='session-c',run_id='run-c'}
  check(resources.begin(c).ok,'reuse: owner begins')
  check(resources.claim(c,{'client:local'}).ok,'reuse: owner reserves client')

  -- Looking is free, so the holder can always see what the client is doing.
  host.client=function(action,args)
    if action=='status' then return json.encode({ok=true,connected=true}) end
    return json.encode({error='fixture: write not expected here'})
  end
  local reading=tools.dispatch(nil,'client',{action='status'},'master',c)
  check(type(reading)=='table' and reading.error==nil,'reuse: a read is answered while the claim is held')

  -- A write whose answer was lost leaves the claim uncertain ...
  host.client=function(action,args)
    if action=='status' then return json.encode({ok=true,connected=true}) end
    return json.encode({error='client_timeout',observed='fixture lost the answer'})
  end
  local lost=tools.dispatch(nil,'client',{action='click',x=2,y=2},'master',c)
  check(lost.error=='client_timeout','reuse: the unanswered write is surfaced')
  local held=resources.claim(c,{'client:local'})
  check(held.error=='resource_busy' and held.claim.uncertain==true,'reuse: a lost answer leaves the run holding an uncertain claim')

  -- ... so the next write of the *same* run is not wedged behind its own claim: it
  -- looks at the client, clears only its own uncertainty, and reaches the client again.
  local calls=0
  host.client=function(action,args)
    calls=calls+1
    if action=='status' then return json.encode({ok=true,connected=true}) end
    return json.encode({error='client_timeout',observed='fixture lost the answer again'})
  end
  local again=tools.dispatch(nil,'client',{action='click',x=3,y=3},'master',c)
  check(again.error=='client_timeout','reuse: the next write is not refused by the run\'s own uncertain claim')
  check(calls>0,'reuse: the next write actually reached the client')

  -- An absent or busy client is a real answer, and it refuses rather than guessing.
  host.client=function(action,args)
    if action=='status' then return json.encode({ok=false,error='client_not_connected',connected=false,effect='none'}) end
    return json.encode({error='fixture: write must not be attempted while the owner is uncertain'})
  end
  local blocked=tools.dispatch(nil,'client',{action='click',x=4,y=4},'master',c)
  check(blocked.error=='resource_busy','reuse: an absent client cannot justify clearing uncertainty')
  check(type(blocked.observed)=='string' and type(blocked.next)=='string','reuse: the refusal names what was seen and what to do next')
  host.client=real
  check(resources.finish(c).ok,'reuse: uncertain owner settles')
else error('unknown fixture mode') end
print('resource claims '..mode..' ok')
