-- Coordinator-owned closure, not a scheduler, child approval, or installer.
-- All external writes are preceded by a durable non-replayable reservation.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local users=dofile('lua/core/users.lua')
local nodes=dofile('lua/core/nodes.lua')
local platform=dofile('lua/core/platform.lua')
local M={}
local terminal={completed=true,failed=true,refused=true,cancelled=true,unknown=true}
local function q(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
local function decode(raw)
  local ok,v=pcall(json.decode,raw or '')
  if ok and type(v)=='table' then return v end
end
local function run(cmd,cwd)
  local r=decode(host.exec(cmd,cwd or '',120))
  assert(r and r.code==0 and r.ok~=false,'wave_command_failed: '..tostring(r and (r.stderr or r.stdout) or cmd))
  return (r.stdout or ''):gsub('[\r\n]+$','')
end
local function git(root,args) return run('git -C '..q(root)..' '..args,root) end
local function hash(v) return host.sha256(json.encode(v)) end
local function key(ctx) return 'wave-autoflush:v2:'..ctx.session_id end
local function load(ctx)
  local raw=memory.meta_get(key(ctx))
  if not raw then return {schema=2,enabled=false,revision=0,children={},requests={},history={}} end
  local s=assert(decode(raw),'wave_state_unreadable')
  assert(s.schema==2 and type(s.enabled)=='boolean' and type(s.revision)=='number' and s.revision>=0 and s.revision%1==0 and type(s.children)=='table' and type(s.requests)=='table','wave_state_unsupported')
  return s
end
local function save(ctx,s) memory.meta_set(key(ctx),json.encode(s)) end
local function authority(ctx)
  local origin=(decode(host.runtime_info()) or {}).run_origin
  if origin~='cli' and origin~='interactive' and origin~='completion' and origin~='control' then return nil,'wave_origin_not_applicable' end
  if ctx.subagent or ctx.remote or ctx.profile or ctx.job_id or ctx.delivery_id or not users.is_master(ctx.role) or not nodes.is_master() then return nil,'wave_coordinator_only' end
  local user=users.find(ctx.user_id)
  if not user or not users.is_master(user.role) then return nil,'wave_owner_revoked' end
  local p=memory.session(ctx.session_id)
  if not p or p.user_id~=ctx.user_id or p.objective=='subagent' or tostring(p.route_id):lower():find('whatsapp',1,true) or (p.parent_session_id or '')~='' then return nil,'wave_parent_forbidden' end
  local node=(nodes.identity() or {}).node_id
  if not node or node=='' or (p.node_id~='' and p.node_id~=node) then return nil,'wave_node_mismatch' end
  return {owner=ctx.user_id,parent=ctx.session_id,node=node}
end
local function repository(ctx)
  local root=memory.session_worktree(ctx.session_id)
  if not root or root=='' then
    local update=dofile('lua/core/update.lua');root=update.runtime_tree(update.install_dir())
  end
  if not root or root=='' then return nil,'selected_repository_unavailable' end
  local readable,common=pcall(git,root,'rev-parse --path-format=absolute --git-common-dir')
  if not readable then return nil,'not_a_self_repository' end
  local update=dofile('lua/core/update.lua')
  local runtime=update.runtime_tree(update.install_dir())
  assert(runtime and runtime~='','wave_runtime_identity_unavailable')
  local runtime_common=git(runtime,'rev-parse --path-format=absolute --git-common-dir')
  local normalize=function(v) return platform.os()=='windows' and v:lower() or v end
  if normalize(common)~=normalize(runtime_common) then return nil,'other_repository' end
  local main=git(runtime,'worktree list --porcelain'):match('^worktree ([^\r\n]+)')
  assert(main and git(main,'branch --show-current')=='main','wave_canonical_main_missing')
  return {main=main,common=common,id=host.sha256(normalize(common)),runtime_common=runtime_common}
end
local function source(repo)
  assert(git(repo.main,'status --porcelain --untracked-files=all')=='','wave_source_dirty')
  local sha=git(repo.main,'rev-parse HEAD')
  assert(#sha==40 and sha==git(repo.main,'rev-parse origin/main'),'wave_source_not_published')
  assert(sha==git(repo.main,'ls-remote origin refs/heads/main'):match('^(%x+)'),'wave_remote_source_mismatch')
  return {sha=sha,tree=git(repo.main,'rev-parse HEAD^{tree}'),repository=repo.id}
end
local function same(a,b) return hash(a)==hash(b) end
local function bound(s,scope,repo)
  assert(s.scope and same(s.scope,scope) and s.repository and same(s.repository,repo),'wave_scope_mismatch')
end
local function shipped(path,m)
  for _,d in ipairs(m.directories or {}) do if path:sub(1,#d)==d then return true end end
  for _,field in ipairs({'files','wave_closure_files'}) do for _,f in ipairs(m[field] or {}) do if path==f then return true end end end
  for _,g in ipairs(m.globs or {}) do
    local prefix=g:match('^(.-)%*$')
    if prefix and path:sub(1,#prefix)==prefix then local tail=path:sub(#prefix+1);if tail~='' and not tail:find('/',1,true) then return true end end
  end
  return false
end
-- Native admission base, not merge-base with today's main. Save before integration ff.
function M.capture(mem,ctx,root,tip,base)
  local fact={schema=1,session=ctx.session_id,owner=ctx.user_id,tip=tip,base=base,verdict='unknown'}
  local ok,err=pcall(function()
    assert(type(base)=='string' and #base==40 and not base:find('[^%x]'),'admission_base_missing')
    assert(type(tip)=='string' and #tip==40 and not tip:find('[^%x]'),'own_tip_missing')
    fact.repository=git(root,'rev-parse --path-format=absolute --git-common-dir')
    fact.tree=git(root,'rev-parse '..tip..'^{tree}')
    assert(git(root,'status --porcelain --untracked-files=all')=='','child_dirty')
    fact.comparison_base=base
    fact.merge_base=git(root,'merge-base '..base..' '..tip)
    assert(fact.merge_base~=tip,'already_merged_own_tip_unmeasured')
    local manifest=assert(decode(git(root,'show '..base..':scripts/deploy-shipped.json')),'shipped_rules_unreadable')
    assert(manifest.schema==1 and type(manifest.directories)=='table' and type(manifest.files)=='table' and type(manifest.globs)=='table','shipped_rules_unsupported')
    fact.rules_sha256=hash(manifest);fact.paths={};fact.shipped={}
    for path in git(root,'diff --name-only -z '..fact.merge_base..' '..tip):gmatch('[^%z]+') do
      fact.paths[#fact.paths+1]=path
      if shipped(path,manifest) then fact.shipped[#fact.shipped+1]=path end
    end
    fact.verdict=#fact.shipped>0 and 'required' or 'none'
  end)
  if not ok then fact.error=tostring(err) end
  fact.digest=hash(fact)
  -- Original facts are append-only; the session pointer is only an index.
  mem.meta_set('wave-impact-fact:'..fact.digest,json.encode(fact))
  mem.meta_set('wave-impact:'..ctx.session_id,json.encode(fact))
  return fact
end
function M.settlement(result,owner,parent)
  local sid=tostring(result.session_id or '')
  local fact=decode(memory.meta_get('wave-impact:'..sid))
  if fact and (not fact.comparison_base or not fact.merge_base) then
    fact={schema=1,session=sid,owner=owner,verdict='unknown',error='legacy_own_impact_unmeasured',original_fact_digest=fact.digest}
  end
  if not fact then
    fact={schema=1,session=sid,owner=owner,verdict='unknown',error='original_own_tip_integration_comparison_unmeasured'}
  end
  local envelope={child=result.subagent_id,owner=owner,parent=parent,node=(nodes.identity() or {}).node_id,session=sid,state=result.state,impact=fact}
  envelope.digest=hash(envelope)
  memory.meta_set('wave-settlement:'..envelope.digest,json.encode(envelope))
  return envelope
end
-- Native list is unpaginated and owner-scoped. Never infer activity from our owed rows.
local function native_children(ctx)
  local view=assert(decode(host.subagent('list',json.encode({owner_user=ctx.user_id}))),'wave_native_list_unreadable')
  assert(not view.error and type(view.subagents)=='table','wave_native_list_unavailable')
  return view.subagents
end
local function relevant(child,ctx,repo)
  if child.parent_session_id~=ctx.session_id or child.profile~='orchestration-worker' then return false end
  if child.run_origin~='cli' and child.run_origin~='interactive' and child.run_origin~='completion' and child.run_origin~='control' then return false end
  local w=memory.session_workspace(child.session_id)
  if not w or not w.worktree then return false end
  local ok,common=pcall(git,w.worktree,'rev-parse --path-format=absolute --git-common-dir')
  return ok and common==repo.common
end
local function generation(ctx,s,repo,admitted)
  if s.generation then s.history[#s.history+1]={generation=s.generation,children=s.children,obligation=s.obligation} end
  s.children={};s.qualified=nil
  s.generation={id=host.uuid(),opened_at=host.now(),baseline={},included={}}
  for _,c in ipairs(native_children(ctx)) do
    s.generation.baseline[c.subagent_id]=true
    if c.subagent_id==admitted or (not c.settled and c.state~='unknown' and relevant(c,ctx,repo)) then s.generation.included[c.subagent_id]=true end
  end
end
local function refresh(ctx,s)
  local repo=assert(s.repository,'wave_scope_required')
  local native=native_children(ctx)
  if s.generation and s.generation.closed then
    for _,c in ipairs(native) do
      if not s.generation.baseline[c.subagent_id] and not s.children[c.subagent_id] and relevant(c,ctx,repo) then generation(ctx,s,repo,c.subagent_id);break end
    end
  end
  local ids,active={},0
  for _,child in ipairs(native) do
    local member=s.generation and (s.children[child.subagent_id] or s.enabled and (s.generation.included[child.subagent_id] or not s.generation.baseline[child.subagent_id] and relevant(child,ctx,repo)))
    if member then
      local id=assert(child.subagent_id,'wave_native_id_missing');ids[#ids+1]=id
      local old=s.children[id] or {}
      local settled=child.settled==true or child.state=='unknown'
      if not settled then active=active+1 end
      local e=old.settlement
      if settled and (not e or e.state~=child.state or e.session~=child.session_id) then e=M.settlement(child,ctx.user_id,ctx.session_id) end
      local fingerprint=hash({id=id,state=child.state,session=child.session_id,settled=settled,settlement=e and e.digest})
      if old.fingerprint~=fingerprint then old.acceptance=nil;s.qualified=nil;s.revision=s.revision+1 end
      old.fingerprint=fingerprint;old.state=child.state;old.session=child.session_id;old.settled=settled;old.settlement=e
      s.children[id]=old
    end
  end
  table.sort(ids)
  -- A lost native record is unknown, never quietly removed from required work.
  local present={};for _,id in ipairs(ids) do present[id]=true end
  for id in pairs(s.children) do assert(present[id],'wave_native_child_missing:'..id) end
  s.active=active;s.childset=hash(ids)
  s.obligation='none'
  for _,child in pairs(s.children) do
    if not child.settled or not child.settlement or child.settlement.impact.verdict=='unknown' then s.obligation='held';break end
    if child.settlement.impact.verdict=='required' and child.covered~=child.fingerprint then s.obligation='owed' end
  end
  if s.inflight then
    local request=s.requests[#s.requests];s.obligation=request and request.state=='queued' and 'queued' or 'held'
  elseif s.qualified then s.obligation='ready' end
  s.activity=active>0 and 'working' or 'idle'
end
local function observe(s)
  if not s.inflight then return end
  local r=s.requests[#s.requests]
  if not r or r.id~=s.inflight then return end
  local receipt=r.recovered_receipt or r.receipt
  if not receipt or not receipt.queued then return end
  local id=receipt.request_id
  if not id or id:find('[^%w%-]') then return end
  local root=dofile('lua/core/paths.lua').config()..'/sentinel'
  local dir=root..'/deploy-protocol/'..id
  local function file(name) local raw=host.read_file(dir..'/'..name);return decode(raw),raw end
  local intent,intent_raw=file('intent.json')
  if not intent_raw or host.sha256(intent_raw)~=receipt.intent_sha256 then s.blocker='wave_immutable_intent_changed_or_missing';return end
  local proof,raw=file('verification.json');local effect=file('effect.json');local binding=file('binding.json');local result=file('result.json')
  local active=decode(host.read_file(root..'/protocol-effect.json'))
  -- Read only native verifier output, never a caller-supplied success/exit flag.
  -- This records historical installation evidence, not a fresh verifier of our own.
  if not proof or not effect or not binding or not result or not active then s.blocker='native_installation_verification_missing';return end
  if proof.ok~=true or proof.suite~='verify-install' or proof.exit~=0 or proof.failed~=0 or proof.skipped~=0 or (proof.checks or 0)<1
      or proof.request_id~=id or proof.expected_sha~=r.source.sha or proof.tree~=r.source.tree
      or proof.owner~=r.scope.owner or proof.parent~=r.scope.parent
      or not same(binding.intent,intent) or binding.id~=id or binding.owner~=r.scope.owner or binding.parent~=r.scope.parent
      or effect.id~=id or effect.expected_sha~=r.source.sha or effect.tree~=r.source.tree
      or effect.owner~=r.scope.owner or effect.parent~=r.scope.parent
      or active.phase~='verified' or active.id~=id or result.ok~=true or result.request_id~=id or result.expected_sha~=r.source.sha then
    s.blocker='native_installation_verification_mismatch';return
  end
  local generation_a,generation_b={},{}
  for k,v in pairs(active) do if k~='phase' and k~='verified_at' and k~='retired_at' then generation_a[k]=v end end
  for k,v in pairs(effect) do if k~='phase' and k~='verified_at' and k~='retired_at' then generation_b[k]=v end end
  if not same(generation_a,generation_b) then s.blocker='native_effect_generation_mismatch';return end
  for _,k in ipairs({'node_sha256','sentinel_sha256','scripts_sha256','ui_sha256'}) do
    if type(proof[k])~='string' or #proof[k]~=64 or proof[k]:find('[^%x]') then s.blocker='native_artifact_identity_missing';return end
  end
  if not proof.raw_stdout or not proof.raw_stderr or proof.raw_stdout:find('[/\\]') or proof.raw_stderr:find('[/\\]')
      or not host.read_file(dir..'/'..proof.raw_stdout) or host.read_file(dir..'/'..proof.raw_stderr)==nil then
    s.blocker='native_original_verification_logs_missing';return
  end
  r.state='installed_verified';r.verification={path=dir..'/verification.json',sha256=host.sha256(raw),at=proof.at}
  for id,fingerprint in pairs(r.fingerprints or {}) do
    local child=s.children[id];if child and child.fingerprint==fingerprint then child.covered=fingerprint end
  end
  s.inflight=nil;s.blocker=nil;s.obligation='installed_verified'
  if s.generation then s.generation.closed=true end
end
function M.admission_guard(ctx)
  local scope=authority(ctx);if not scope then return end
  local repo=repository(ctx);if not repo then return end
  local s=load(ctx)
  if s.enabled and s.inflight then
    bound(s,scope,repo)
    observe(s) -- verification-only consumption before a new SELF admission; never replay
    save(ctx,s)
  end
  if s.enabled and s.inflight then return {error='wave_installation_obligation_held',effect='none',reservation=s.inflight} end
end
function M.admitted(id,ctx)
  -- Existing native admission notification only invalidates; it never queues.
  local s=load(ctx);if not s.enabled then return end
  local scope=authority(ctx);if not scope then return end
  local repo=repository(ctx);if not repo then return end
  local v=decode(host.subagent('status',json.encode({owner_user=ctx.user_id,id=id})))
  if not v or not relevant(v,ctx,repo) then return end
  memory.transaction(function()
    s=load(ctx)
    if not s.generation or s.generation.closed then generation(ctx,s,repo,id) end
    if not s.children[id] then
      -- Native admission reference survives a lost/corrupt runtime record. It is
      -- NOT an activity flag: refresh still derives working from native records,
      -- and a missing admitted id becomes an explicit unknown/held blocker.
      s.children[id]={session=v.session_id,state=v.state,settled=v.settled==true,
        admission={child=id,owner=scope.owner,parent=scope.parent,node=scope.node},fingerprint='admission:'..id}
      s.qualified=nil;s.revision=s.revision+1;save(ctx,s)
    end
  end)
end
local function clean_child(child,repo,scope)
  assert(child.settled and terminal[child.state] and child.state~='unknown','wave_child_active_or_unknown')
  local e=assert(child.settlement,'wave_settlement_missing');local f=e.impact
  assert(e.owner==scope.owner and e.parent==scope.parent and e.node==scope.node and f.owner==e.owner and f.session==e.session,'wave_settlement_scope_mismatch')
  assert(f and f.verdict~='unknown','wave_impact_unknown')
  assert(f.repository==repo.common,'wave_child_repository_mismatch')
  local w=memory.session_workspace(child.session)
  assert(w and w.worktree and git(w.worktree,'status --porcelain --untracked-files=all')=='','wave_child_dirty_or_unreadable')
  git(repo.main,'merge-base --is-ancestor '..git(w.worktree,'rev-parse HEAD')..' HEAD')
  git(repo.main,'merge-base --is-ancestor '..f.tip..' HEAD')
  return f
end
local function ready(s,repo)
  assert(s.active==0,'wave_required_child_active')
  local owed=false
  for _,child in pairs(s.children) do
    local f=clean_child(child,repo,s.scope)
    assert(child.acceptance and child.acceptance.fingerprint==child.fingerprint,'wave_review_needed')
    if f.verdict=='required' and child.covered~=child.fingerprint then owed=true end
  end
  return owed
end
local function binary_ready(s,repo,current,receipt)
  assert(type(receipt)=='string' and receipt~='','wave_source_bound_build_receipt_required')
  local runtime=assert(decode(host.runtime_info()),'wave_runtime_identity_missing')
  assert(runtime.binary_path and runtime.binary_sha256,'wave_installed_binary_unmeasured')
  local command='node '..q(repo.main..'/scripts/codemode-build.mjs')..' qualify-wave '..q(repo.main)
    ..' --receipt '..q(receipt)..' --generation '..q(s.generation.id)..' --opened-at '..q(s.generation.opened_at)
    ..' --installed-binary '..q(runtime.binary_path)
  local result=assert(decode(run(command,repo.main)),'wave_binary_verification_unreadable')
  assert(result.ok==true and result.source_commit==current.sha and result.source_tree==current.tree
    and result.generation==s.generation.id and result.binary_sha256~=runtime.binary_sha256,'wave_binary_identity_mismatch')
  return result
end
local function recheck_binary(s,repo,qualified)
  local actual=binary_ready(s,repo,qualified.source,qualified.binary.receipt)
  for _,field in ipairs({'receipt_sha256','binary_sha256','binary','generation','platform','arch'}) do
    assert(actual[field]==qualified.binary[field],'wave_qualified_binary_changed:'..field)
  end
end
function M.control(args,ctx)
  local scope,err=authority(ctx);if not scope then return {error=err,not_applicable=err=='wave_origin_not_applicable'} end
  local ok,result=pcall(function()
    local repo,why=repository(ctx)
    if not repo then return {ok=true,not_applicable=true,reason=why} end
    return memory.transaction(function()
      local s=load(ctx)
      if s.scope then bound(s,scope,repo) end
      if args.action=='enable' then
        assert(not s.inflight,'wave_admitted_obligation_held; observe/reconcile the original before re-enabling')
        assert(host.getenv('WASM_AGENT_COMPLETION_WAKE')~='0','wave_native_completion_disabled')
        assert(args.revision==s.revision,'wave_revision_conflict')
        if not s.enabled then generation(ctx,s,repo) end
        s.scope=scope;s.repository=repo;s.enabled=true;s.qualified=nil;s.revision=s.revision+1
      elseif args.action=='off' then
        assert(args.revision==s.revision,'wave_revision_conflict')
        s.enabled=false;s.qualified=nil;s.revision=s.revision+1
      elseif args.action~='status' and args.action~='accept' and args.action~='qualify' and args.action~='reconcile' then error('wave_action_invalid') end
      if s.repository then refresh(ctx,s);observe(s) end
      if args.action=='reconcile' then
        assert(type(args.evidence)=='string' and args.evidence:find('%S'),'wave_original_evidence_required')
        assert(args.revision==s.revision and s.inflight,'wave_reconciliation_binding_required')
        local r=s.requests[#s.requests];local id=args.request_id
        assert(type(id)=='string' and id~='' and not id:find('[^%w%-]'),'wave_request_id_invalid')
        if r.receipt and r.receipt.request_id then assert(r.receipt.request_id==id,'wave_request_immutable') end
        local dir=dofile('lua/core/paths.lua').config()..'/sentinel/deploy-protocol/'..id
        local raw=assert(host.read_file(dir..'/intent.json'),'wave_native_intent_missing');local intent=assert(decode(raw),'wave_native_intent_unreadable')
        assert(intent.id==id and intent.verb=='deploy' and intent.expected_sha==r.source.sha and intent.owner==r.scope.owner and intent.session==r.scope.parent
          and intent.reason=='accepted coordinator wave closure '..r.id..'; exact source '..r.source.sha,'wave_reconciliation_intent_mismatch')
        r.reconciliation={request_id=id,evidence=args.evidence,intent_sha256=host.sha256(raw)}
        -- Preserve the original lost/refused operation; recovery only observes an
        -- EXACT wave-tagged native request. It never writes the request queue.
        r.recovered_receipt={request_id=id,intent_sha256=host.sha256(raw),queued=true,observation_only=true}
        observe(s)
      end
      if args.action=='accept' or args.action=='qualify' then
        s.blocker=nil
        assert(s.enabled,'wave_disabled');assert(args.revision==s.revision,'wave_revision_conflict')
        assert(type(args.evidence)=='string' and args.evidence:find('%S'),'wave_original_evidence_required')
        local current=source(repo)
        assert(args.sha==current.sha and args.tree==current.tree,'wave_candidate_mismatch')
        if args.action=='accept' then
          local child=assert(s.children[args.child_id],'wave_child_not_owned');local f=clean_child(child,repo,s.scope)
          assert(args.tip==f.tip and args.digest==child.settlement.digest,'wave_acceptance_binding_mismatch')
          child.acceptance={fingerprint=child.fingerprint,sha=current.sha,tree=current.tree,evidence=args.evidence,review='coordinator judgement; self-review is not independent review',run=ctx.run_id}
          s.qualified=nil;s.revision=s.revision+1
        else
          assert(ready(s,repo),'wave_no_install_impact')
          local binary=binary_ready(s,repo,current,args.binary_receipt)
          s.qualified={source=current,binary=binary,revision=s.revision,childset=s.childset,evidence=args.evidence,run=ctx.run_id}
        end
      end
      save(ctx,s);return {ok=true,wave=s,source=(function() local ok,v=pcall(source,repo);return ok and v or {error=tostring(v)} end)()}
    end)
  end)
  return ok and result or {error=tostring(result),held=true}
end
-- Called at the coordinator's completed-candidate closure, after steering/audit.
-- Not provider telemetry and no promise of pre-stream timing. No extra inference.
function M.finalize(ctx)
  local scope=authority(ctx);if not scope then return end
  local s=load(ctx);if not s.enabled then return end
  local ok,result=pcall(function()
    local repo,why=repository(ctx);if not repo then return {not_applicable=true,reason=why} end
    bound(s,scope,repo)
    assert(not ctx.current or ctx.current(),'wave_coordinator_candidate_changed')
    local reservation,observation
    memory.transaction(function()
      s=load(ctx);bound(s,scope,repo)
      local previous=s.inflight
      local prepared,why=pcall(function()
        refresh(ctx,s);observe(s)
        if previous and not s.inflight then
          local installed=s.requests[#s.requests]
          observation={installed_verified=true,source=installed.source,verification=installed.verification,notification='separate native return state'}
          return
        end
        if s.inflight then error('wave_request_held:'..s.inflight) end
        if not ready(s,repo) then
          if s.generation then s.generation.closed=true end
          s.obligation='none';observation={not_applicable=true,reason='no_own_install_impact'};return
        end
        assert(s.qualified,'wave_review_or_qualification_needed')
        assert(s.qualified.revision==s.revision and s.qualified.childset==s.childset,'wave_readiness_stale')
        assert(ready(s,repo),'wave_no_install_impact')
        local current=source(repo)
        assert(same(current,s.qualified.source),'wave_qualified_source_changed')
        recheck_binary(s,repo,s.qualified)
        reservation={id=host.uuid(),state='reserved',source=current,scope=scope,qualified=s.qualified,fingerprints={}}
        for id,child in pairs(s.children) do reservation.fingerprints[id]=child.fingerprint end
        s.inflight=reservation.id;s.requests[#s.requests+1]=reservation;s.qualified=nil
      end)
      if not prepared then
        -- Persist observed invalidation/unknowns rather than rolling them back
        -- just because a read-only readiness check refused closure.
        if not s.inflight then s.qualified=nil end
        s.blocker=tostring(why);observation={held=true,error=tostring(why)}
      end
      save(ctx,s) -- BEFORE any queue call; crash here holds, never retries.
    end)
    if not reservation then return observation end
    local update=dofile('lua/core/update.lua')
    local receipt=update.request_bound({session_id=ctx.session_id,owner=ctx.user_id,sha=reservation.source.sha,tree=reservation.source.tree,root=repo.main,obligation_id=reservation.id,
      prequeue=function()
        return memory.transaction(function()
          assert(not ctx.current or ctx.current(),'wave_coordinator_candidate_changed_before_queue')
          local current=load(ctx);refresh(ctx,current)
          assert(current.enabled and current.inflight==reservation.id and current.revision==reservation.qualified.revision and current.active==0,'wave_activity_changed_before_queue')
          assert(ready(current,repo),'wave_readiness_changed_before_queue')
          recheck_binary(current,repo,reservation.qualified)
          save(ctx,current);return true
        end)
      end})
    memory.transaction(function()
      s=load(ctx);assert(s.inflight==reservation.id,'wave_reservation_changed')
      local record=s.requests[#s.requests];record.receipt=receipt;record.state=receipt.queued and 'queued' or 'held'
      s.obligation=record.state;s.blocker=receipt.error
      save(ctx,s)
    end)
    return receipt
  end)
  if not ok then
    -- Persist blockers without deleting an admitted reservation or original receipt.
    memory.transaction(function() local current=load(ctx);current.blocker=tostring(result);save(ctx,current) end)
    return {held=true,error=tostring(result)}
  end
  return result
end
return M
