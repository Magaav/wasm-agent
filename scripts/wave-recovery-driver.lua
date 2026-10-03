-- Explicit verified external script, NOT embedded or a model tool. The caller
-- is trusted Lua already admitted through resources.begin on this native thread.
local json=dofile('lua/vendor/json.lua')
local M={}
local loaded=debug.getinfo(1,'S').source:gsub('^@','')
local function decode(raw) local ok,v=pcall(json.decode,raw or ''); assert(ok and type(v)=='table','recovery_driver_invalid_json'); return v end
local function resource(action,args) return decode(host.resource(action,json.encode(args))) end
local function operation(action,args) return decode(host.operation(action,json.encode(args))) end
local function equal(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~='table' then return a==b end
  for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function read_all(id)
  local chunks,offset={},0
  while true do
    local page=operation('read',{id=id,stream='stdout',offset=offset,limit=65536})
    assert(page.content and not page.text_lossy,page.error or 'recovery_driver_output_unreadable')
    chunks[#chunks+1]=page.content;offset=page.next_offset
    if offset>=page.available_bytes then break end
  end
  return table.concat(chunks):gsub('%s+$','')
end
local function run(program,args,cwd)
  local accepted=operation('start',{program=program,args=args,cwd=cwd,timeout_seconds=120})
  assert(accepted.operation_id,accepted.error)
  local settled=operation('await',{id=accepted.operation_id,wait_for='settled'})
  assert(settled.settled==true and settled.ok==true,settled.error or 'recovery_driver_operation_unsettled')
  return read_all(accepted.operation_id)
end
local function source(repo,d)
  assert(d.schema==2 and d.kind=='wave-reviewed-source','recovery_driver_source_v2_required')
  assert(host.canonical_path(loaded)==host.canonical_path(d.root..'/scripts/wave-recovery-driver.lua'),'recovery_driver_source_path')
  local function git(...) return run('git',{'-C',repo,...},d.root) end
  assert(git('rev-parse',d.tip..'^{tree}')==d.tree,'recovery_driver_source_tree')
  local review=decode(git('show',d.review_commit..':'..d.review_path))
  assert(review.schema==2 and review.kind=='wave-source-review' and review.tip==d.tip and review.tree==d.tree
    and review.verdict=='passed' and review.producer~=review.reviewer and equal(review.files,d.files)
    and equal(review.runtime,d.runtime) and review.authority==d.authority,'recovery_driver_source_review')
  local function anchor(commit)
    local message=git('show','-s','--format=%B',commit);local last=message:match('([^\n]+)$') or ''
    local count,owner=0,nil;for value in last:gmatch('session=([^%s]+)') do count=count+1;owner=value end
    assert(last:match('^Agent:') and count==1,'recovery_driver_anchor');return owner
  end
  assert(anchor(d.tip)==review.producer and anchor(d.review_commit)==review.reviewer,'recovery_driver_source_provenance')
  local names={};for name in git('ls-tree','-r','--name-only',d.tip):gmatch('[^\r\n]+') do names[#names+1]=name end
  assert(#names==#d.files,'recovery_driver_full_closure')
  local files={};for _,f in ipairs(d.files) do assert(not files[f.path],'recovery_driver_duplicate_source');files[f.path]=f.sha256 end
  for _,name in ipairs(names) do
    assert(files[name] and not name:find('..',1,true) and not name:find('[\r\n]'),'recovery_driver_source_path')
    -- Non-executable binary UI/evidence assets are verified by the Node batch
    -- blob verifier before admission/effects; every executable text input is
    -- checked here BEFORE starting any JavaScript from this root.
    local executable=name:match('%.lua$') or name:match('%.mjs$') or name:match('%.cjs$') or name:match('%.js$')
      or name:match('%.rs$') or name:match('%.c$') or name:match('%.h$') or name:match('%.toml$')
      or name:match('%.lock$') or name:match('%.sh$') or name:match('%.ps1$') or name:match('^%.githooks/')
    if executable then
      local bytes=host.read_file(d.root..'/'..name)
      assert(bytes and host.sha256(bytes)==files[name],'recovery_driver_source_bytes:'..name)
    end
  end
  local runtime=decode(host.runtime_info())
  assert(runtime.binary_sha256==d.runtime.native.sha256,'recovery_driver_native_binary')
  local function binary_hash(file)
    local observed=resource('source_binary_observe',{path=file})
    assert(observed.ok and observed.kind=='native-binary-observation','recovery_driver_binary_observation')
    return observed.sha256
  end
  assert(binary_hash(d.runtime.node.path)==d.runtime.node.sha256 and binary_hash(d.runtime.git.path)==d.runtime.git.sha256,'recovery_driver_runner_binary')
  if runtime.os=='windows' then assert(binary_hash(d.runtime.observer.path)==d.runtime.observer.sha256,'recovery_driver_observer_binary') end
  assert(not host.getenv('NODE_OPTIONS') or host.getenv('NODE_OPTIONS')=='','recovery_driver_unpinned_node_options')
  assert(not host.getenv('NODE_PATH') or host.getenv('NODE_PATH')=='','recovery_driver_unpinned_node_path')
  assert(d.runtime.driver=='scripts/wave-recovery-driver.lua' and d.runtime.consumer=='scripts/wave-recovery-bootstrap.mjs'
    and equal(d.runtime.effects,{'canonical-local-main-cas'}),'recovery_driver_effect_contract')
  return runtime,git('rev-parse','--path-format=absolute','--git-common-dir')
end
local function execute(packet,lifecycle)
  local d=decode(assert(host.read_file(packet.source_file),'recovery_driver_source_missing'))
  local runtime,common=source(packet.repo,d)
  local context=decode(assert(host.read_file(packet.context_file),'recovery_driver_context_missing'))
  assert(context.phase=='land' and context.recovery,'recovery_driver_land_required')
  local scope={git_common_dir=common,ref='refs/heads/main'}
  local inspection=resource('target_inspect',scope)
  assert(inspection.ok and inspection.complete and inspection.identities_complete and inspection.admissible,'recovery_driver_native_inventory_refused')
  local held=resource('target_hold',scope);assert(held.ok,held.error)
  local receipt=held.receipt
  lifecycle.receipt=receipt
  assert(receipt.exclusion_scope=='git-common-directory','recovery_driver_directory_exclusion_required')
  local check={git_common_dir=common,ref=scope.ref,receipt=receipt}
  assert(resource('target_check',check).held,'recovery_driver_native_hold_check')
  local channel=host.paths().temp..'/wa-recovery-'..host.uuid()
  local nonce=host.uuid()..host.uuid()
  local launch=operation('start',{program=d.runtime.node.path,args={d.root..'/scripts/wave-recovery-bootstrap.mjs',packet.repo,packet.source_file,packet.context_file,'land',channel},cwd=d.root,timeout_seconds=300})
  lifecycle.operation_id=launch.operation_id
  if not launch.operation_id then
    resource('uncertain',{principal=receipt.principal,run=receipt.run})
    return {ok=false,error=launch.error or 'recovery_driver_launch_unknown',native_receipt=receipt,uncertain=true}
  end
  assert(host.write_file(channel..'.parent.json',json.encode({schema=1,kind='native-recovery-channel',nonce=nonce,
    receipt=receipt,runtime=runtime,data=host.paths().data,operation_id=launch.operation_id,source={tip=d.tip,tree=d.tree}})),'recovery_driver_channel_write')
  -- Only trusted Lua can supply a function; JSON packets cannot install an
  -- observer or choose a native command. Used by the private causal harness.
  if type(packet.observe)=='function' then packet.observe('held',{receipt=receipt,channel=channel}) end
  local sequence=0;local state;local child
  repeat
    local raw=host.read_file(channel..'.request-'..(sequence+1)..'.json')
    if raw then
      local ok,request=pcall(decode,raw)
      if ok and request.nonce==nonce and request.sequence==sequence+1 and request.verb=='check' then
        sequence=request.sequence
        local observe={git_common_dir=common,ref=scope.ref,receipt=receipt,child_process_id=request.child_process_id}
        local result=resource('target_child_observe',observe)
        if result.ok and child and not equal(result.child,child) then result={ok=false,error='recovery_driver_child_generation_changed'} end
        if result.ok then child=result.child end
        if type(packet.observe)=='function' then packet.observe('check',{sequence=sequence,result=result,receipt=receipt,channel=channel}) end
        assert(host.write_file(channel..'.reply-'..sequence..'.json',json.encode({nonce=nonce,sequence=sequence,result=result})),'recovery_driver_reply_write')
      end
    end
    state=operation('status',{id=launch.operation_id})
    if not state.settled then host.sleep(10) end
  until state.settled or state.overdue or state.error=='operation_not_found'
  local ok,result=pcall(function() return decode(read_all(launch.operation_id)) end)
  if state.settled~=true or state.ok~=true or not ok or result.ok~=true or result.publication_scope~='canonical-local' then
    resource('uncertain',{principal=receipt.principal,run=receipt.run})
    return {ok=false,error=ok and (result.reason or result.error) or state.error or 'recovery_driver_effect_unknown',native_receipt=receipt,
      native_operation_id=launch.operation_id,settled=state.settled==true,uncertain=true,detail=ok and result or nil}
  end
  assert(resource('target_check',check).held,'recovery_driver_post_effect_check')
  check.evidence='Reviewed source-only canonical-local CAS, worktree readback, and exact owned operation settled: '..result.landing
  local released=resource('target_release',check)
  assert(released.ok,released.error)
  result.native_receipt=receipt;result.native_child=child;result.native_operation_id=launch.operation_id;result.native_settled=true;result.native_released=true
  return result
end
function M.run(packet)
  local lifecycle={}
  local ok,result=pcall(execute,packet,lifecycle)
  if ok then return result end
  local settled=nil
  if lifecycle.receipt then
    resource('uncertain',{principal=lifecycle.receipt.principal,run=lifecycle.receipt.run})
    if lifecycle.operation_id then
      operation('cancel',{id=lifecycle.operation_id})
      settled=operation('await',{id=lifecycle.operation_id,wait_for='settled'})
    end
  end
  return {ok=false,error=tostring(result),native_receipt=lifecycle.receipt,native_operation_id=lifecycle.operation_id,
    uncertain=lifecycle.receipt~=nil,settled=settled and settled.settled==true or false}
end
return M
