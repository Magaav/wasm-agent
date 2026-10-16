-- Additional operator oracles over REAL Git, physical native binaries and build receipts.
-- Queue and inference alone are fake; no installer or live settings are used.
local M={}
function M.before(t)
 local json=t.json;local wave=t.wave;local ctx=t.ctx;local checks=0
 local function check(v,label)assert(v,label);checks=checks+1 end
 local function cmd(c)local r=json.decode(host.exec(c,t.root,180));assert(r.code==0,json.encode(r));return r.stdout end
 local function control(receipt)
  local s=t.status(ctx)
  return wave.control({action='qualify',revision=s.wave.revision,sha=s.source.sha,tree=s.source.tree,binary_receipt=receipt,evidence='original private native build logs'},ctx)
 end
 local s=t.status(ctx);local qualified=assert(s.wave.qualified);local b=qualified.binary
 local raw=assert(host.read_file(b.receipt));local original=json.decode(raw)
 local serial=0
 local function bad(change,label)
  serial=serial+1;local r=json.decode(raw);change(r)
  local file=original.evidence..'/negative-'..serial..'.json';assert(host.write_file(file,json.encode(r)))
  local refused=control(file);check(not refused.ok and refused.held,label);return refused
 end
 bad(function(r)r.source_commit=string.rep('0',40)end,'wrong-source physical candidate refused')
 bad(function(r)r.source_tree=string.rep('0',40)end,'wrong-tree physical candidate refused')
 bad(function(r)r.started_at=s.wave.generation.opened_at-1 end,'stale build refused')
 bad(function(r)r.wave_generation='earlier-unrelated-wave'end,'earlier-wave candidate refused')
 bad(function(r)r.platform='foreign-target'end,'wrong native target refused')
 bad(function(r)r.binary_sha256=string.rep('0',64)end,'corrupt binary binding refused')
 bad(function(r)r.logs['embedded.stdout']=string.rep('0',64)end,'original native proof mismatch refused')
 bad(function(r)r.build_schema=nil;r.ready=true end,'ready flag is not a build/check receipt')
 check(not control(nil).ok,'missing binary receipt refused')
 local backup=b.binary..'.private-constraints-original'
 cmd('mv '..t.q(b.binary)..' '..t.q(backup))
 cmd('cp '..t.q(host.getenv('WA_WAVE_OLD_BINARY'))..' '..t.q(b.binary))
 local digest=cmd('node -e '..t.q("const fs=require('fs'),c=require('crypto');console.log(c.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'))")..' '..t.q(b.binary)):gsub('%s+$','')
 local relabelled=bad(function(r)r.binary_sha256=digest end,'genuine earlier-wave artifact cannot be relabelled with a current ready receipt')
 check(relabelled.error:find('wave_candidate_native_verification_failed',1,true)~=nil,'fresh native compiled identity catches relabelled earlier-wave bytes')
 cmd('rm '..t.q(b.binary)..' && mv '..t.q(backup)..' '..t.q(b.binary))
 cmd('mv '..t.q(b.binary)..' '..t.q(backup))
 check(not control(b.receipt).ok,'missing physical binary refused')
 assert(host.write_file(b.binary,'not a native binary'))
 check(not control(b.receipt).ok,'corrupt physical bytes refused')
 local before=t.queue_count();local drift=wave.finalize(ctx)
 check(drift and drift.held and t.queue_count()==before,'post-qualification byte drift cannot reserve or queue')
 cmd('rm '..t.q(b.binary)..' && mv '..t.q(backup)..' '..t.q(b.binary))
 check(control(b.receipt).ok,'original bytes and native receipt requalified')
 -- Run the candidate as the actual executing node: the same physical artifact
 -- cannot qualify as a NEW binary. No host.runtime_info or ready predicate is mocked.
 local probe=original.evidence..'/probe.json'
 local args={action='qualify',revision=t.status(ctx).wave.revision,sha=s.source.sha,tree=s.source.tree,binary_receipt=b.receipt,evidence='private original native proof'}
 assert(host.write_file(probe,json.encode({label='PRIVATE FAKE QUEUE ONLY',kind='unchanged',parent=ctx.session_id,args=args})))
 local runtime=json.decode(host.runtime_info())
 local function probe_run(binary,kind,baseline,parent)
  assert(host.write_file(probe,json.encode({label='PRIVATE FAKE QUEUE ONLY',kind=kind,parent=parent or ctx.session_id,args=args,baseline=baseline,views=t.views})))
  local env='WA_SCRIPT='..t.q(host.getenv('WA_WAVE_PROBE'))..' WA_WAVE_PROBE_CONFIG='..t.q(probe)
  if kind=='job' or kind=='old-job' then env=env..' WA_JOB_EVENT_FILE='..t.q(probe) end
  local r=json.decode(host.exec(env..' '..t.q(binary)..' --db '..t.q(host.getenv('WA_WAVE_DB')),t.root,180))
  assert(r.code==0,json.encode(r));return json.decode(r.stdout)
 end
 local unchanged=probe_run(b.binary,'unchanged')
 check(unchanged.ok and unchanged.held,'actual running installed artifact cannot count as a new candidate')
 local job=probe_run(runtime.binary_path,'job')
 check(job.ok and job.origin=='job' and job.queue_calls==0,'native operational-job origin cannot close an enabled ready self wave')
 -- A real other repository, even with a genuine native candidate and shipped manifest.
 local other=t.root..'/../other';local bare=t.root..'/../other.git';local own=t.root..'/../other-own'
 cmd('mkdir -p '..t.q(other..'/jobs')..' '..t.q(other..'/scripts')..' '..t.q(other..'/rust/target/release'))
 assert(host.write_file(other..'/.gitignore','rust/target\n'))
 assert(host.write_file(other..'/jobs/private.json','{}\n'))
 assert(host.write_file(other..'/scripts/deploy-shipped.json',assert(host.read_file(t.root..'/scripts/deploy-shipped.json'))))
 t.git(other,'init -b main');t.git(other,'config user.name private');t.git(other,'config user.email private@invalid');t.git(other,'config core.autocrlf false')
 t.git(other,'add .');t.git(other,'commit -m other-baseline');t.git(other,'init --bare '..t.q(bare));t.git(other,'remote add origin '..t.q(bare));t.git(other,'push -u origin main')
 local base=t.git(other,'rev-parse HEAD');t.git(other,'worktree add -b change/other '..t.q(own)..' origin/main')
 assert(host.write_file(own..'/jobs/private.json','{"other":true}\n'));t.git(own,'add .');t.git(own,'commit -m other-software')
 local tip=t.git(own,'rev-parse HEAD');t.git(other,'merge --no-ff '..tip..' -m other-merge');t.git(other,'push origin main');t.git(own,'merge --ff-only origin/main')
 cmd('cp '..t.q(b.binary)..' '..t.q(other..'/rust/target/release/'..(runtime.os=='windows' and 'wa.exe' or 'wa')))
 local foreign=t.parent();t.memory.set_session_worktree(foreign.session_id,other)
 local sid=t.memory.start_session('','subagent',{user_id='master',parent_session_id=foreign.session_id})
 t.memory.set_session_workspace(sid,{worktree=own,required=true,state='allocated',branch='change/other',base_commit=base})
 local id='foreign-private-child';t.views[#t.views+1]={subagent_id=id,session_id=sid,parent_session_id=foreign.session_id,profile='orchestration-worker',run_origin='cli',state='completed',settled=true}
 wave.capture(t.memory,{session_id=sid,user_id='master'},own,tip,base)
 local not_self=wave.control({action='enable',revision=0},foreign)
 check(not_self.not_applicable and not_self.reason~='', 'other repository is not applicable before creating debt')
 check(t.memory.meta_get('wave-autoflush:v2:'..foreign.session_id)==nil,'other repository creates no wave state')
 check(wave.admission_guard(foreign)==nil,'other software is never fenced')
 local old_loader=dofile;local old=assert(load(assert(host.read_file(host.getenv('WA_WAVE_BASELINE_MODULE'))),'@old-permissive-wave'))()
 local unsafe=0
 local function old_prepare(c,child)
  local r=old.control({action='enable',revision=0},c);assert(r.ok,json.encode(r))
  local v=assert(r.wave.children[child]);local f=v.settlement.impact
  r=old.control({action='accept',revision=r.wave.revision,child_id=child,tip=f.tip,digest=v.settlement.digest,sha=r.source.sha,tree=r.source.tree,evidence='private baseline oracle'},c);assert(r.ok,json.encode(r))
  r=old.control({action='qualify',revision=r.wave.revision,sha=r.source.sha,tree=r.source.tree,evidence='no binary qualification'},c);assert(r.ok,json.encode(r))
 end
 local function old_answer(c)
  dofile=function(p)
   if p=='lua/core/wave_autoflush.lua' then return old end
   if p=='lua/core/update.lua' then return {request_bound=function()unsafe=unsafe+1;return {queued=true,label='FAKE baseline unsafe proposal'}end} end
   return old_loader(p)
  end
  local bot=t.agent.new(c.session_id,function()end,'master','master','');bot:run('private baseline protection oracle')
  dofile=old_loader
 end
 old_prepare(foreign,id);old_answer(foreign)
 check(unsafe==1,'old actual-agent source fails other-software protection oracle')
 -- Old source also qualifies and queues with the physical artifact missing.
 local missing_parent=t.parent();local mv=t.child(missing_parent,'completed');old_prepare(missing_parent,mv.subagent_id)
 cmd('mv '..t.q(b.binary)..' '..t.q(backup));old_answer(missing_parent)
 cmd('mv '..t.q(backup)..' '..t.q(b.binary))
 check(unsafe==2,'old actual-agent source fails missing-binary protection oracle')
 local old_job_parent=t.parent();local jv=t.child(old_job_parent,'completed');old_prepare(old_job_parent,jv.subagent_id)
 local oldjob=probe_run(runtime.binary_path,'old-job',host.getenv('WA_WAVE_BASELINE_MODULE'),old_job_parent.session_id)
 check(oldjob.ok and oldjob.origin=='job' and oldjob.queue_calls==1,'old actual-agent source fails native-job protection oracle')
 check(control(b.receipt).ok,'genuine exact SELF binary remains qualified after negative oracles')
 b.archive=original.evidence..'/qualified-positive-wa.exe'
 cmd('cp '..t.q(b.binary)..' '..t.q(b.archive))
 return checks,b
end
return M
