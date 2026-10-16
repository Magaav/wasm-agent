-- Private native SQLite/Git + actual agent loop. All queue effects below are LABELLED FAKE.
-- Inherited child/run guards are preserved. No real Sentinel or provider call.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local native=dofile
local real_getenv=host.getenv
host.getenv=function(k)
  if k=='WASM_AGENT_LLM_API_KEY' then return 'fixture' end
  if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if k=='WASM_AGENT_CODEMODE' then return 'off' end
  return real_getenv(k)
end
host.http=function() error('network forbidden') end;host.http_stream=host.http
local nodes=native('lua/core/nodes.lua')
local provider=native('lua/core/provider.lua')
local wave=native('lua/core/wave_autoflush.lua')
local update=native('lua/core/update.lua')
local root=assert(host.getenv('WA_WAVE_MAIN'));local own=assert(host.getenv('WA_WAVE_OWN'))
local base=assert(host.getenv('WA_WAVE_BASE'));local tip=assert(host.getenv('WA_WAVE_TIP'))
local q=function(s)return "'"..s:gsub("'","'\\''").."'"end
local function git(p,a)local r=json.decode(host.exec('git -C '..q(p)..' '..a,p,120));assert(r.code==0,json.encode(r));return (r.stdout or ''):gsub('%s+$','') end
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local views={};local native_subagent=host.subagent
host.subagent=function(action,raw)
  local a=json.decode(raw)
  if action=='list' then return json.encode({subagents=views,count=#views}) end
  if action=='status' then for _,v in ipairs(views)do if v.subagent_id==a.id then return json.encode(v) end end end
  error('unexpected native fixture action '..action)
end
local queue_calls=0;local mode='queued'
local function fake_queue(scope)
  assert(scope.prequeue(),'real prequeue revalidation')
  local state=json.decode(memory.meta_get('wave-autoflush:v2:'..scope.session_id))
  assert(state.inflight==scope.obligation_id and state.requests[#state.requests].state=='reserved','journal exists BEFORE fake queue')
  assert(wave.admission_guard({session_id=scope.session_id,user_id=scope.owner,role='master'}).error=='wave_installation_obligation_held','new admissions fenced under same DB transaction')
  queue_calls=queue_calls+1
  assert(scope.sha==git(root,'rev-parse HEAD'),'fake queue exact source')
  assert(scope.tree==git(root,'rev-parse HEAD^{tree}'),'fake queue exact tree')
  if mode=='before' then error('LABELLED FAKE crash before queue') end
  local raw='requested deploy: PRIVATE-FAKE/'..queue_calls..'.json\n'
  local recorded={};for k,v in pairs(scope)do if type(v)~='function' then recorded[k]=v end end
  assert(host.write_file(host.getenv('WA_WAVE_QUEUE'),json.encode({label='FAKE queue, not installation',calls=queue_calls,scope=recorded,stdout=raw})))
  if mode=='after' then error('LABELLED FAKE lost response after queue') end
  return {queued=true,installed=false,operation={code=0,stdout=raw},request_id='fake-'..queue_calls,intent_sha256='fake'}
end
dofile=function(p)
  if p=='lua/core/provider.lua' then return provider end
  if p=='lua/core/update.lua' then local copy={};for k,v in pairs(update)do copy[k]=v end;copy.request_bound=fake_queue;return copy end
  return native(p)
end
local agent=native('lua/core/agent.lua')
provider.complete_with=function()return {content='fixture final',finish_reason='stop',usage={prompt_tokens=1,completion_tokens=1,total_tokens=2}} end
local serial=0
local function parent()
 serial=serial+1
 local sid=memory.start_session('','chat',{id='wave-parent-'..serial,user_id='master',node_id=(nodes.identity() or {}).node_id})
 memory.set_session_worktree(sid,root)
 return {role='master',user_id='master',session_id=sid,run_id='coordinator-fixture-'..serial}
end
local function child(ctx,state,id)
 id=id or ('wave-child-'..serial)
 local sid=memory.start_session('','subagent',{id=id,user_id='master',parent_session_id=ctx.session_id})
 memory.set_session_workspace(sid,{worktree=own,required=true,state='allocated',branch='change/wave-fixture',base_commit=base})
 local v={subagent_id=id,session_id=sid,parent_session_id=ctx.session_id,run_origin='cli',profile='orchestration-worker',state=state,settled=state~='running'}
 if state~='running' then wave.capture(memory,{session_id=sid,user_id='master'},own,tip,base) end
 views[#views+1]=v
 return v
end
local function status(ctx)local r=wave.control({action='status'},ctx);assert(r.ok,json.encode(r));return r end
local function on(ctx)
 local pending={}
 for _,v in ipairs(views)do if v.parent_session_id==ctx.session_id and v.settled then pending[#pending+1]={v=v,state=v.state};v.state='running';v.settled=false end end
 local r=wave.control({action='enable',revision=0},ctx);assert(r.ok,json.encode(r))
 for _,p in ipairs(pending)do p.v.state=p.state;p.v.settled=true end
 return r
end
local function accept(ctx,id)
 local r=status(ctx);local c=assert(r.wave.children[id]);local f=c.settlement.impact
 local a=wave.control({action='accept',revision=r.wave.revision,child_id=id,tip=f.tip,digest=c.settlement.digest,sha=r.source.sha,tree=r.source.tree,evidence='original fixture source/diff/logs; labelled self-review'},ctx)
 assert(a.ok,json.encode(a));return a
end
local builds={}
local function qualify(ctx)
 local r=status(ctx);local receipt
 local can=true
 for _,v in pairs(r.wave.children)do if not v.acceptance or not v.settled or v.state=='unknown' then can=false end end
 if git(own,'status --porcelain')~='' then can=false end
 if can and r.wave.generation then
  local id=r.wave.generation.id..':'..r.source.sha
  receipt=builds[id]
  if not receipt then
   local command='node '..q(root..'/scripts/codemode-build.mjs')..' build '..q(root)..' --assets '..q(host.getenv('WA_WAVE_ASSETS'))..' --wave-generation '..q(r.wave.generation.id)
   local built=json.decode(host.exec(command,root,1800));assert(built.code==0,json.encode(built))
   local proof=json.decode(built.stdout);assert(proof.ok,'real private native build')
   receipt=proof.evidence..'/receipt.json';builds[id]=receipt
  end
 end
 return wave.control({action='qualify',revision=r.wave.revision,sha=r.source.sha,tree=r.source.tree,binary_receipt=receipt,evidence='original exact-source focused checks; fixture self-review'},ctx)
end
local function answer(ctx)
 local bot=agent.new(ctx.session_id,function()end,'master','master','')
 return bot:run('fixture coordinator close, no external effects')
end
local ctx=parent();local c=child(ctx,'running')
views[#views+1]={subagent_id='historical-unknown',session_id='historical-missing-session',parent_session_id=ctx.session_id,profile='orchestration-worker',run_origin='cli',state='unknown',settled=false}
views[#views+1]={subagent_id='operational-job',session_id=c.session_id,parent_session_id=ctx.session_id,profile='orchestration-worker',run_origin='job',state='running',settled=false}
check(wave.finalize(ctx)==nil and queue_calls==0,'OFF does not queue')
on(ctx)
check(status(ctx).wave.activity=='working','real native fixture activity, not pending flags')
check(status(ctx).wave.children['historical-unknown']==nil and status(ctx).wave.children['operational-job']==nil,'historical unknown and active operational jobs are outside this self wave')
check(not qualify(ctx).ok,'active required child prevents qualification')
c.state='completed';c.settled=true
-- Original own tip is captured before the native integration fast-forward.
local f=wave.capture(memory,{session_id=c.session_id,user_id='master'},own,tip,base)
check(f.verdict=='required' and #f.shipped==1,'own original shipped impact')
local integration=native('lua/core/integrate.lua')
local resources=native('lua/core/resources.lua')
local worker={user_id='master',session_id=c.session_id,run_id='fixture-integrate',subagent={id='orchestration-worker'}}
assert(resources.begin(worker).ok)
local landed=integration.run(memory,worker);assert(landed.ok,json.encode(landed));assert(resources.finish(worker).ok)
check(git(own,'rev-parse HEAD')==git(root,'rev-parse HEAD'),'native integration ff happened')
check(git(own,'diff --name-only origin/main')=='','old merge-base measurement would miss integrated impact')
check(status(ctx).wave.children[c.subagent_id].settlement.impact.verdict=='required','integrated own impact survives ff')
check(not qualify(ctx).ok and queue_calls==0,'settlement/result is never acceptance')
check(not wave.control({action='accept',revision=status(ctx).wave.revision,child_id=c.subagent_id,tip=tip,digest='forged',sha=tip,tree=string.rep('a',40),evidence='forged success'},ctx).ok,'forged source/digest acceptance refused')
check(not wave.control({action='installed',revision=status(ctx).wave.revision,ok=true},ctx).ok,'caller-supplied installed success has no control action')
accept(ctx,c.subagent_id);check(qualify(ctx).ok,'explicit coordinator acceptance and exact qualification')
local constraint_checks,qualified_self_binary=assert(load(assert(host.read_file(host.getenv('WA_WAVE_CONSTRAINTS'))),'@self-constraints'))().before({json=json,wave=wave,ctx=ctx,root=root,own=own,q=q,git=git,status=status,parent=parent,child=child,memory=memory,views=views,agent=agent,queue_count=function()return queue_calls end})
checks=checks+constraint_checks
-- Causal control: actual old agent module has no closure call, though obligation is ready.
local old_path=host.getenv('WA_WAVE_OLD_AGENT')
local old=assert(load(assert(host.read_file(old_path)),'@old-agent-causal-control'))();local oldbot=old.new(ctx.session_id,function()end,'master','master','')
oldbot:run('old-source causal control')
check(queue_calls==0 and status(ctx).wave.qualified~=nil,'old source finishes owed+ready without request')
local closed=answer(ctx)
check(queue_calls==1,'new normal actual-agent completed candidate queues exactly once: '..tostring(closed))
local queued_status=status(ctx)
check(queued_status.wave.requests[1].state=='queued','queued is not installed: '..json.encode(queued_status.wave))
wave.finalize(ctx);native('lua/core/wave_autoflush.lua').finalize(ctx)
check(queue_calls==1,'duplicate closure and module restart cannot replay')
local tools=native('lua/core/tools.lua')
check(tools.dispatch(memory,'wave_autoflush',{action='status'},'master',ctx).ok,'actual ordinary control-plane tool dispatch')
check(tools.dispatch(memory,'wave_autoflush',{action='status'},'guest',{session_id=ctx.session_id,user_id='master'}).error~=nil,'actual guest dispatcher fence')
check(tools.dispatch(memory,'wave_autoflush',{action='status'},'master',{session_id=ctx.session_id,user_id='master',subagent={id='orchestration-worker',allowed={wave_autoflush=true}}}).error=='wave_coordinator_only','even a widened child declaration cannot gain coordinator authority')
check(wave.control({action='status'},{role='guest',user_id='master',session_id=ctx.session_id}).error=='wave_coordinator_only','guest refused')
check(wave.control({action='status'},{role='master',user_id='other',session_id=ctx.session_id}).error=='wave_owner_revoked','wrong principal refused')
check(wave.control({action='status'},{role='master',user_id='master',session_id=ctx.session_id,subagent={id='orchestration-worker'}}).error=='wave_coordinator_only','worker refused')
check(wave.control({action='status'},{role='master',user_id='master',session_id=ctx.session_id,remote=true}).error=='wave_coordinator_only','foreign transport refused')
check(wave.control({action='status'},{role='master',user_id='master',session_id=ctx.session_id,profile={id='specialist'}}).error=='wave_coordinator_only','specialized context refused')
local wrongnode=memory.start_session('','chat',{user_id='master',node_id='foreign-node'})
check(wave.control({action='status'},{role='master',user_id='master',session_id=wrongnode}).error=='wave_node_mismatch','foreign node parent refused')
for _,state in ipairs({'failed','refused','cancelled','unknown'})do
 local p=parent();local v=child(p,state);on(p)
 local e=status(p).wave.children[v.subagent_id].settlement
 check(e.state==state and e.impact.verdict~='none','all return states persist measured facts or unknown: '..state)
end
-- Newly admitted actual native child invalidates old readiness.
local p=parent();local v=child(p,'completed');on(p);accept(p,v.subagent_id);assert(qualify(p).ok)
local extra=child(p,'running','new-active-required');wave.admitted(extra.subagent_id,p)
check(status(p).wave.qualified==nil and wave.finalize(p).held,'new work invalidates qualified source')
-- Fresh source invalidates a qualification even if children stay unchanged.
local p2=parent();local v2=child(p2,'completed');on(p2);accept(p2,v2.subagent_id);assert(qualify(p2).ok)
assert(host.write_file(root..'/new-doc.md','new published source\n'));git(root,'add new-doc.md');git(root,'commit -m new-source');git(root,'push origin main')
check(wave.finalize(p2).held and queue_calls==1,'new published source holds stale readiness')
-- Dirty drafts never qualify and are preserved.
assert(host.write_file(own..'/dirty-draft','recoverable draft'))
check(not qualify(p2).ok and host.read_file(own..'/dirty-draft')=='recoverable draft','dirty child held, original draft preserved')
git(own,'clean -f -- dirty-draft') -- private fixture only, after proving retained bytes
-- Native admission references survive default OFF and turn missing records into
-- unknown holds, never phantom idle/zero-impact work.
local orphan=parent();local ov=child(orphan,'running')
wave.admitted(ov.subagent_id,orphan)
local observed=status(orphan)
check(observed.wave.children[ov.subagent_id]==nil and not observed.wave.enabled,'OFF does not enroll old admissions into a new wave')
local enabled_orphan=wave.control({action='enable',revision=observed.wave.revision},orphan);assert(enabled_orphan.ok,json.encode(enabled_orphan))
table.remove(views,#views)
local missing=wave.control({action='status'},orphan)
check(missing.held and missing.error:find('wave_native_child_missing',1,true),'missing admitted native record is unknown/held, not idle success')
-- Ambiguous outcomes both before and after the labelled fake queue hold across restart.
for _,crash in ipairs({'before','after'})do
 local pp=parent();local vv=child(pp,'completed');on(pp);accept(pp,vv.subagent_id);assert(qualify(pp).ok)
 mode=crash;local before=queue_calls
 check(wave.finalize(pp).held,'crash produces named hold '..crash)
 native('lua/core/wave_autoflush.lua').finalize(pp)
 check(queue_calls==before+1,'reserved effect cannot replay '..crash)
 check(status(pp).wave.requests[1].state=='reserved','original ambiguous reservation retained '..crash)
end
local restart_parent='wave-parent-'..serial
-- A docs-only child syncs another wave's shipped upstream work. Measure actual
-- integration comparison BEFORE ff, not admission-base -> final aggregate tip.
local dp=parent();local ds=memory.start_session('','subagent',{id='docs-sync-child',user_id='master',parent_session_id=dp.session_id})
local docown=root..'/../doc-own';git(root,'worktree add -b change/docs-sync '..q(docown)..' '..base)
memory.set_session_workspace(ds,{worktree=docown,required=true,state='allocated',branch='change/docs-sync',base_commit=base})
local dv={subagent_id='docs-sync-native',session_id=ds,parent_session_id=dp.session_id,profile='orchestration-worker',run_origin='cli',state='running',settled=false};views[#views+1]=dv;on(dp)
assert(host.write_file(root..'/jobs/upstream.json','{"upstream_wave":true}\n'));git(root,'add jobs/upstream.json');git(root,'commit -m upstream-shipped-change');git(root,'push origin main')
git(docown,'fetch origin');git(docown,'merge --no-ff origin/main -m sync-upstream')
assert(host.write_file(docown..'/own-doc.md','own documentation\n'));git(docown,'add own-doc.md');git(docown,'commit -m own-doc -m '..q('Agent: wasm-agent role=child session='..ds))
local own_doc_tip=git(docown,'rev-parse HEAD')
local dw={user_id='master',session_id=ds,run_id='docs-sync-integration',subagent={id='orchestration-worker'}}
assert(resources.begin(dw).ok);local docland=integration.run(memory,dw);assert(docland.ok,json.encode(docland));assert(resources.finish(dw).ok)
check(docland.impact.verdict=='none' and #docland.impact.paths==1,'docs-only own delta remains none after syncing upstream shipped changes')
local baseline_wave=assert(load(assert(host.read_file(host.getenv('WA_WAVE_BASELINE_MODULE'))),'@old-doc-impact'))()
local overcount=baseline_wave.capture(memory,{session_id='old-doc-overcount',user_id='master'},docown,own_doc_tip,base)
check(overcount.verdict=='required','old admission-base source fails synced-docs protection oracle')
dv.state='completed';dv.settled=true;accept(dp,dv.subagent_id)
local before_docs=queue_calls;answer(dp)
check(queue_calls==before_docs and status(dp).wave.obligation=='none','accepted docs/upstream-only generation closes without debt, binary or queue')
mode='queued'
local command=update.bound_command({sentinel='PRIVATE-FAKE/sentinel'},{sha=tip,owner='master',session_id=ctx.session_id})
check(command:find('--expected-sha',1,true) and command:find('--owner',1,true) and not command:find('--prompt',1,true),'strict source-bound command, no legacy prompt')
local off=wave.control({action='off',revision=status(ctx).wave.revision},ctx)
check(off.ok and not off.wave.enabled and off.wave.inflight~=nil,'off preserves admitted immutable request')
local count=queue_calls;answer(ctx);check(queue_calls==count,'off/status ordinary question produces no queue or inference loop')
-- Docs-only own admission delta has no install impact, not a guessed clean zero.
local docbase=git(own,'rev-parse HEAD')
assert(host.write_file(own..'/docs-only.md','documentation only\n'));git(own,'add docs-only.md');git(own,'commit -m docs-only')
local docfact=wave.capture(memory,{session_id='doc-only-measurement',user_id='master'},own,git(own,'rev-parse HEAD'),docbase)
check(docfact.verdict=='none','measured docs-only delta has no install impact')
local unknown=wave.capture(memory,{session_id='unmeasured-fixture',user_id='master'},own,git(own,'rev-parse HEAD'),nil)
check(unknown.verdict=='unknown','missing admission base cannot become zero')
-- Private readback proof tests TEXT CLI receipts; exit0/generic success is not installed.
local paths=native('lua/core/paths.lua');local queuefile=paths.data()..'/fake-request.json'
local scope={sha=tip,owner='master',session_id=ctx.session_id,obligation_id='private-wave'}
local intent={id='fake-request',verb='deploy',expected_sha=tip,owner=scope.owner,session=scope.session_id,queued_at=math.floor(host.now()),reason='accepted coordinator wave closure private-wave; exact source '..tip}
assert(host.write_file(queuefile,json.encode(intent)))
local receipt=update.bound_receipt({code=0,stdout='  requested deploy: '..queuefile..'\n  the sentinel performs it - it is the only thing that stops or starts this node\n'},scope,{sentinel_dir=paths.data()})
check(receipt.queued and not receipt.installed and receipt.intent_raw~=nil,'plaintext receipt requires immutable exact intent readback')
check(receipt.operation.stdout:sub(1,2)=='  ' and receipt.operation.stdout:find('\n  the sentinel performs it',1,true)~=nil,'real indented structured stdout stays original, not the parsing view')
intent.owner='forged';assert(host.write_file(queuefile,json.encode(intent)))
check(update.bound_receipt({code=0,stdout='requested deploy: '..queuefile..'\n'},scope,{sentinel_dir=paths.data()}).held,'wrong native owner holds')
check(update.bound_receipt({code=0,stdout='ok installed'},scope,{sentinel_dir=paths.data()}).held,'generic exit0 forged success holds')
check(update.bound_receipt(nil,scope,{sentinel_dir=paths.data()}).held,'lost CLI response holds')
local fake_release={code=0,stdout=json.encode({released=true,id='protected-failure',phase='aborted_preinstall'})}
check(not update.reservation_released({id='protected-failure',phase='admitted'},fake_release),'protected failed/admitted generation cannot be cleared by retirement flag')
check(not update.reservation_released({id='protected-failure',phase='failed'},fake_release),'failed install never qualifies as released')
check(not update.reservation_released({id='other',phase='aborted_preinstall'},fake_release),'retirement exact native generation id required')
check(update.reservation_released({id='protected-failure',phase='aborted_preinstall'},fake_release),'only supported exact native retirement receipt permits later source admission; not installation')
if host.getenv('WASM_AGENT_PROVENANCE')=='child' then
 check(update.request_bound(scope).error=='update_coordinator_only','real inherited child guard refuses actual queue path before any effect')
end
assert(host.write_file(host.getenv('WA_WAVE_RESTART'),json.encode({views=views,parent=restart_parent,user_id='master',role='master'})))
print(json.encode({ok=true,checks=checks,skipped=0,queue='LABELLED FAKE',queue_calls=queue_calls,paid_calls=0,live_installation=false,inherited_child_guard=host.getenv('WASM_AGENT_PROVENANCE')=='child',qualified_self_binary=qualified_self_binary,integration=landed}))
