-- Review of 18/11, item 4 (two BLOCKERs): WHO counts as the operator's own session, and does the operator path
-- survive the allocation it admits? Both are decided inside `workspaces.ensure`, so both are tested through it -
-- `wave_admission_outcome` alone passes every case below on the old code.
--
-- What was wrong on 62c3c064:
--   - `operator_session` read the objective as "not subagent", so a session ANOTHER node started
--     (`objective='remote'`, `lua/core/session_watch.lua`) skipped wave admission on this node's shared
--     repository; and it never read `user_id` at all, so a root session of any principal did too. Cases 1, 2
--     and 5 pin that through the two admission sites (an already allocated binding, and a new allocation).
--   - the new-allocation path set `start_state.wave_admission` BEFORE `local start_state` existed, so the very
--     path the exception exists for died with "attempt to index a nil value (global 'start_state')", and the
--     table built a few lines later would have dropped the fact anyway. Case 4 pins that.
--
-- The repository is real (a scratch git repo, real `git worktree add`); only the wave entrypoint is stubbed,
-- because the case is a node with NO registration and asking the real store would be node state, not a test.
local json=dofile('lua/vendor/json.lua')
local base=host.paths() or {}
local scratch=tostring(base.temp or '/tmp')..'/wa-operator-session-'..host.uuid()
-- Every path this test writes (its data dir, the install record, the git repo) is under `scratch`.
host.paths=function()
  return {home=scratch, config=scratch..'/config', data=scratch..'/data', cache=scratch..'/cache', temp=scratch}
end
local real_getenv=host.getenv
host.getenv=function(k) if k=='WA_INSTALL_DIR' then return scratch..'/install' end return real_getenv(k) end

local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local function quote(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function sh(command,cwd)
  local ok,raw=pcall(host.exec,command,cwd or '',120)
  assert(ok,'exec failed: '..tostring(raw))
  local result=json.decode(raw)
  assert(type(result)=='table' and tonumber(result.code)==0,
    'command failed ('..tostring(result and result.code)..'): '..command..' :: '..tostring(result and result.stderr))
  return tostring(result.stdout or '')
end

-- A scratch checkout with one commit, and an install directory that names it as this node's runtime tree
-- (`update.runtime_tree` reads <install>/runtime-worktree.txt).
sh('mkdir -p '..quote(scratch..'/data')..' '..quote(scratch..'/install')..' '..quote(scratch..'/repo'))
local root=scratch..'/repo'
sh('git init -q --initial-branch=main .',root)
sh('git -c user.email=fixture@example.invalid -c user.name=fixture commit -q --allow-empty -m base',root)
local head=sh('git rev-parse HEAD',root):gsub('%s+$','')
assert(host.write_file(scratch..'/install/runtime-worktree.txt',root..'\n'),'fixture install record')
-- An already allocated linked worktree, made by git itself: the binding a second session can be given without
-- involving the allocator (so case 1 pins the ADMISSION, not an allocation that throws for another reason).
local allocated=scratch..'/allocated'
local allocated_branch='change/fixture-'..host.uuid():gsub('-','')
sh('git worktree add -q -b '..allocated_branch..' '..quote(allocated)..' '..head,root)
local allocated_path=sh('git -C '..quote(allocated)..' rev-parse --show-toplevel'):gsub('%s+$','')
check(allocated_path==allocated,'ITEM 4: the fixture worktree resolves to itself: '..allocated_path)

-- The wave entrypoint, as the only stubbed part: it answers the absent-authority refusal this node has, or
-- (with 'admit' appended) an ordinary admission, which is the control at the end.
local waves={'refuse'}
local real_exec=host.exec
host.exec=function(command,cwd,timeout)
  local text=tostring(command or '')
  if text:find('wave%-entry%.mjs') and text:find(' check ',1,true) then
    if waves[#waves]=='refuse' then
      return json.encode({code=1,stdout=json.encode({ok=false,reason='wave_registration_required'}),stderr=''})
    end
    return json.encode({code=0,stdout=json.encode({ok=true,mode='produce'}),stderr=''})
  end
  return real_exec(command,cwd,timeout)
end

local memory=dofile('lua/core/memory.lua');memory.setup()
local workspaces=dofile('lua/core/workspaces.lua')
local users=dofile('lua/core/users.lua')
local owner=users.default_user()
check(type(owner)=='table' and tostring(owner.id)=='master',
  'ITEM 4: the node owner principal is read, not assumed: '..json.encode(owner))

local function bind(session_id,state)
  memory.set_session_workspace(session_id,{required=true,state=state or 'allocated',worktree=allocated,
    branch=allocated_branch,workspace_branch=allocated_branch,base_commit=head,start_state={source_root=root}})
end
local function refused(ws,err,label)
  check(ws==nil,label..': it does not skip wave admission')
  check(tostring(err):find('workspace_wave_admission_refused',1,true)~=nil,
    label..': refused by name: '..tostring(err):sub(1,200))
  check(tostring(err):find('wave_registration_required',1,true)~=nil,
    label..': with the reason the entrypoint gave: '..tostring(err):sub(1,200))
  check(tostring(err):find('node scripts/wave-entry.mjs register',1,true)~=nil,
    label..': and the one command that gives the repository an owner')
end

-- 1. the ALLOCATED admission site: a session another node started -----------------------------------------
local remote=memory.start_session('remote','remote',{user_id=owner.id,node_id='',title='remote'})
bind(remote)
local remote_ws,remote_err=workspaces.ensure(memory,remote,nil,{})
refused(remote_ws,remote_err,'ITEM 4 (allocated): a remote session')
check(memory.session_workspace(remote).state=='allocated',
  'ITEM 4 (allocated): a refused session keeps its binding as it was, not rewritten as failed')

-- 2. the ALLOCATED admission site: a root session of ANOTHER principal ------------------------------------
local guest=memory.start_session('','',{user_id='guest',node_id='',title='guest'})
bind(guest)
local guest_ws,guest_err=workspaces.ensure(memory,guest,nil,{})
refused(guest_ws,guest_err,'ITEM 4 (allocated): a root session of a principal that is not the node owner')

-- 3. the control for the site above: the OPERATOR session, bound the same way, is admitted ----------------
local operator=memory.start_session('','',{user_id=owner.id,node_id='',title='operator'})
bind(operator)
local operator_bound,bound_err=workspaces.ensure(memory,operator,nil,{})
check(operator_bound~=nil,'ITEM 4 (allocated): the operator session is admitted in place of the wave: '..tostring(bound_err))
check(operator_bound and operator_bound.start_state and
  tostring(operator_bound.start_state.wave_admission)=='absent_operator_unregistered',
  'ITEM 4 (allocated): and the binding records the absent registration: '..
  json.encode(operator_bound and operator_bound.start_state and operator_bound.start_state.wave_admission))

-- 4. the NEW-ALLOCATION admission site, operator: it must not throw, and it must record what it decided -----
-- On 62c3c064 this is where `ensure` threw: the exception was recorded before `local start_state` existed.
local fresh=memory.start_session('','',{user_id=owner.id,node_id='',title='fresh'})
local ok_fresh,fresh_ws,fresh_err=pcall(workspaces.ensure,memory,fresh,nil,{})
check(ok_fresh,'ITEM 4 (allocate): the operator path does not throw: '..tostring(fresh_ws))
check(fresh_ws~=nil,'ITEM 4 (allocate): the operator session allocates: '..tostring(fresh_err))
if fresh_ws then
  check(fresh_ws.state=='allocated','ITEM 4 (allocate): the workspace is allocated: '..json.encode(fresh_ws):sub(1,200))
  check(tostring(fresh_ws.start_state and fresh_ws.start_state.wave_admission)=='absent_operator_unregistered',
    'ITEM 4 (allocate): and the binding records the absent registration: '..
    json.encode(fresh_ws.start_state and fresh_ws.start_state.wave_admission))
  local worktree=tostring(fresh_ws.worktree or '')
  check(worktree~='' and worktree~=root and worktree~=allocated_path,
    'ITEM 4 (allocate): it is NOT "in place": its own linked worktree ('..worktree..'), never the source checkout')
  check(tostring(fresh_ws.start_state and fresh_ws.start_state.source_root)==root,
    'ITEM 4 (allocate): forked from the node runtime tree: '..tostring(fresh_ws.start_state and fresh_ws.start_state.source_root))
  check(tostring(fresh_ws.base_commit)==head,'ITEM 4 (allocate): at the source HEAD: '..tostring(fresh_ws.base_commit)..' vs '..head)
end

-- 5. the NEW-ALLOCATION admission site, remote: refused, and the refusal is recorded on the binding -------
local remote_fresh=memory.start_session('remote','remote',{user_id=owner.id,node_id='',title='remote-fresh'})
local ok_rf,rf_ws,rf_err=pcall(workspaces.ensure,memory,remote_fresh,nil,{})
check(ok_rf,'ITEM 4 (allocate): a remote session is refused, not crashed: '..tostring(rf_ws))
refused(rf_ws,rf_err,'ITEM 4 (allocate): a remote session')
local rf_record=memory.session_workspace(remote_fresh)
check(rf_record.state=='failed' and tostring(rf_record.error):find('workspace_wave_admission_refused',1,true)~=nil,
  'ITEM 4 (allocate): the refusal is recorded on the binding, so a retry reads it: '..json.encode(rf_record))

-- 6. the control: with wave authority the same remote session allocates, so the refusals above are the
--    admission decision and not a repository or a stub that cannot work at all.
waves[#waves+1]='admit'
local remote_admitted=memory.start_session('remote','remote',{user_id=owner.id,node_id='',title='remote-admitted'})
local ok_ra,ra_ws,ra_err=pcall(workspaces.ensure,memory,remote_admitted,nil,{})
check(ok_ra and ra_ws~=nil,'ITEM 4 (control): with wave authority a remote session allocates: '..tostring(ra_ws or ra_err))
if ra_ws then
  check(ra_ws.start_state==nil or ra_ws.start_state.wave_admission==nil,
    'ITEM 4 (control): and nothing claims an absent registration for it: '..
    json.encode(ra_ws.start_state and ra_ws.start_state.wave_admission))
end

pcall(host.exec,'rm -rf '..quote(scratch),'',120)
print(json.encode({ok=true,checks=checks}))
