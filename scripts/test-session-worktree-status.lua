-- Item 3 of the harness-fixes mission (18/11): `session_worktree status` answers in one line what is
-- bound and what to do next, and a session that needs no worktree is not offered the tool at all.
--
-- Measured: after `session_worktree set path=...`, `status` returned a structure whose every field was
-- empty or a duplicate, so a model called it three times in a row until the repetition guard ended the
-- turn (guard_repeated_calls, rc 1).
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local workspaces=dofile('lua/core/workspaces.lua')
local paths=dofile('lua/core/paths.lua')
-- The declared surface (what the provider is shown) is real only where tools are declared: the default
-- CodeAct mode declares nothing at all, so this row reads the envelope through the codemode opt-out.
local real_getenv=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_RAW_CODE' then return 'codemode' end return real_getenv(k) end
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local function offered(ctx)
  local names={}
  for _,item in ipairs(tools.envelope('master',ctx)) do names[item['function'].name]=true end
  return names
end
local function catalogue(ctx)
  local names={}
  for _,item in ipairs(tools.all('master',ctx,memory)) do names[item['function'].name]=true end
  return names
end
local function envelope(ctx)
  local names={}
  for _,item in ipairs(tools.envelope('master',ctx)) do names[item['function'].name]=true end
  return names
end

-- 1. a session that needs no worktree ------------------------------------------------------------------
local free=memory.start_session('','worktree-status-free',{user_id='master',node_id='',title='free'})
local free_ctx={session_id=free,user_id='master'}
local status=tools.dispatch(memory,'session_worktree',{action='status'},'master',free_ctx)
check(type(status.status_line)=='string' and status.status_line~='',
  'ITEM 3: status answers with one line: '..json.encode(status):sub(1,200))
check(status.status_line:find('no workspace required',1,true)~=nil,
  'ITEM 3: the line says nothing is bound and nothing needs to be: '..tostring(status.status_line))
check(status.status_line:find('node',1,true)~=nil,
  'ITEM 3: the line names where the tools actually run: '..tostring(status.status_line))
check(offered(free_ctx).session_worktree==nil,
  'ITEM 3: with no workspace required the tool is not offered')
check(envelope(free_ctx).session_worktree==nil,'ITEM 3: nor in the envelope the provider is shown')
check(catalogue(free_ctx).session_worktree==true,
  'ITEM 3: and still discoverable in the catalogue (searchTools finds it, callable=false)')
check(catalogue(free_ctx).bash==true,'ITEM 3: the rest of the surface is untouched')
check(tools.dispatch(memory,'session_worktree',{action='status'},'master',free_ctx).session_id==free,
  'ITEM 3: a caller that names the tool is still answered')

-- 2. a session with a managed workspace ---------------------------------------------------------------
local root=paths.data()..'/worktree-status-managed'
assert(host.write_file(root..'/sum.txt','a-b'),'fixture file')
local bound=memory.start_session('','worktree-status-bound',{user_id='master',node_id='',title='bound'})
memory.set_session_workspace(bound,{required=true,state='allocated',worktree=root,
  branch='mission/harness-fixes',base_commit='0123456789abcdef'})
local bound_ctx={session_id=bound,user_id='master'}
local allocated=tools.dispatch(memory,'session_worktree',{action='status'},'master',bound_ctx)
check(tostring(allocated.status_line):find(root,1,true)~=nil,
  'ITEM 3: an allocated workspace names its path: '..tostring(allocated.status_line))
check(tostring(allocated.status_line):find('mission/harness-fixes',1,true)~=nil,
  'ITEM 3: and its branch: '..tostring(allocated.status_line))
check(tostring(allocated.status_line):find('nothing to bind',1,true)~=nil,
  'ITEM 3: and says there is nothing left to do: '..tostring(allocated.status_line))
check(offered(bound_ctx).session_worktree==true,'ITEM 3: a managed workspace keeps the tool offered')

-- 3. a failed workspace: the line carries the reason and the one next step ---------------------------
local broken=memory.start_session('','worktree-status-failed',{user_id='master',node_id='',title='failed'})
memory.set_session_workspace(broken,{required=true,state='failed',
  error='workspace_wave_admission_refused:wave_registration_required'})
local failed=tools.dispatch(memory,'session_worktree',{action='status'},'master',{session_id=broken,user_id='master'})
check(tostring(failed.status_line):find('wave_registration_required',1,true)~=nil,
  'ITEM 3: a failed workspace says why: '..tostring(failed.status_line))
check(tostring(failed.status_line):find('session_worktree action=',1,true)~=nil,
  'ITEM 3: and the next action to take: '..tostring(failed.status_line))
check(workspaces.status_line(memory,broken)==failed.status_line,'ITEM 3: one implementation of the line')

print(json.encode({ok=true,checks=checks}))