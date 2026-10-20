-- The wave end asks for its own install. Private scratch home, private Git fixture, FAKE request
-- directory under it: no live Sentinel, no live home, no network, no installation. Every request this
-- prints was written by the code under test into <scratch>/home/.wasm-agent/sentinel/requests.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local paths=dofile('lua/core/paths.lua')
local nodes=dofile('lua/core/nodes.lua')
local wave=dofile('lua/core/wave_autoflush.lua')
local getenv=host.getenv
host.getenv=function(k)
  if k=='WASM_AGENT_CODEMODE' then return 'off' end
  return getenv(k)
end
host.http=function() error('network forbidden') end;host.http_stream=host.http
local checks=0
local function check(value,label) assert(value,label);checks=checks+1 end
local function q(s) return "'"..tostring(s):gsub("'","'\\''").."'" end

local home=assert(getenv('WASM_AGENT_HOME'),'scratch home required: WASM_AGENT_HOME')
local space=home..'/wave-end-deploy'
local main=space..'/main'
local child_tree=space..'/child'
local install=assert(getenv('WA_INSTALL_DIR'),'scratch install required: WA_INSTALL_DIR')
local requests_dir=paths.config()..'/sentinel/requests'
assert(host.path_kind(space)=='missing','fresh scratch required: '..space)
check(requests_dir:sub(1,#home)==home,'the request box is inside the scratch home, never the live one')
check(requests_dir:sub(-17)=='sentinel/requests','the request box is the sentinel drop-box path')

local function write(path,text) assert(host.write_file(path,text),'write '..path) end
local function sh(command,cwd,seconds)
  local raw=host.exec(command,cwd or space,seconds or 120)
  local result=json.decode(raw)
  assert(result and result.code==0,'command failed: '..command..'\n'..tostring(result and (tostring(result.stdout)..tostring(result.stderr))))
  return tostring(result.stdout or '')
end
local function git(dir,...)
  local parts={}
  for _,argument in ipairs({...}) do parts[#parts+1]=q(argument) end
  return (sh('git -C '..q(dir)..' '..table.concat(parts,' ')):gsub('%s+$',''))
end

-- ---- the fixture: a repository on main, one linked child worktree, a scratch install ----
write(main..'/scripts/deploy-shipped.json',json.encode({schema=1,directories={},files={},globs={}})..'\n')
write(main..'/notes.md','base\n')
write(install..'/runtime-worktree.txt',main..'\n')
git(space,'init','-b','main',main)
git(main,'config','user.name','private fixture')
git(main,'config','user.email','fixture@invalid')
git(main,'add','.')
git(main,'commit','-m','base')
local base=git(main,'rev-parse','HEAD')
git(main,'update-ref','refs/remotes/origin/main',base)
git(main,'worktree','add','-b','change/fixture',child_tree,base)
write(child_tree..'/notes.md','child work\n')
git(child_tree,'add','.')
git(child_tree,'commit','-m','child task','-m','Agent: private-fixture role=child')
local tip=git(child_tree,'rev-parse','HEAD')
git(main,'merge','--ff-only','change/fixture')
git(main,'update-ref','refs/remotes/origin/main',tip)
check(git(main,'rev-parse','origin/main')==tip,'origin/main names the child tip')
check(git(main,'status','--porcelain','--untracked-files=all')=='','fixture main starts clean')

local function installed(commit)
  local hint=commit and ('source_commit_hint='..commit..'\n') or ''
  write(install..'/installed.txt','commit=1a2b3c4d\nsha256='..string.rep('0',64)..'\n'..hint..'record_role=final\n')
end

local function queued()
  local listing=host.list_dir(requests_dir)
  local value=type(listing)=='string' and json.decode(listing) or listing
  local names={}
  if type(value)=='table' and not value.error then
    for _,entry in ipairs(value.entries or value) do
      if tostring(entry.name):sub(-5)=='.json' then names[#names+1]=requests_dir..'/'..entry.name end
    end
  end
  return names
end
local function request_of(path)
  local decoded,value=pcall(json.decode,assert(host.read_file(path)))
  assert(decoded,'request must be readable JSON')
  return value
end

-- ---- fake native children, no process ----
local views={}
host.subagent=function(action,raw)
  local args=json.decode(raw)
  if action=='list' then return json.encode({subagents=views,count=#views}) end
  if action=='status' then
    for _,view in ipairs(views) do if view.subagent_id==args.id then return json.encode(view) end end
    return nil
  end
  error('unexpected native fixture action '..action)
end
local serial=0
local function parent()
  serial=serial+1
  local sid=memory.start_session('','chat',{id='wave-deploy-parent-'..serial,user_id='master',node_id=(nodes.identity() or {}).node_id})
  memory.set_session_worktree(sid,main)
  return {role='master',user_id='master',session_id=sid,run_id='coordinator-fixture-'..serial}
end
-- A running child: admitted, captured, and only then settled, so the wave's own `active` count is what
-- the flow underneath produces rather than something the test asserts it produced.
local function child(ctx,id)
  local sid=memory.start_session('','subagent',{id=id,user_id='master',parent_session_id=ctx.session_id})
  memory.set_session_workspace(sid,{worktree=child_tree,required=true,state='allocated',branch='change/fixture',base_commit=base})
  local view={subagent_id=id,session_id=sid,parent_session_id=ctx.session_id,run_origin='cli',
    profile='orchestration-worker',state='running',settled=false}
  views[#views+1]=view
  return view
end
local function settle(view)
  wave.capture(memory,{session_id=view.session_id,user_id='master'},child_tree,tip,base)
  view.state='completed';view.settled=true
  return view
end
local function enable(ctx)
  local result=wave.control({action='enable',revision=0},ctx)
  assert(result and result.ok and not result.not_applicable,json.encode(result))
  assert(result.wave and result.wave.enabled,'the wave is enabled on the fixture repository')
  return result
end
local function report(ctx,result)
  local notice=wave.report(ctx,true,result)
  return notice and notice.text or nil
end

local out={}

-- ---- 1. the last child settles and the install is not origin/main: exactly one request ----
local ctx=parent()
local first=child(ctx,'wave-deploy-child-1')
local second=child(ctx,'wave-deploy-child-2')
enable(ctx)
installed(nil)                                          -- installed.txt names an older commit
settle(first)
local early=wave.finalize(ctx)
check(early and early.deferred,'one child still running keeps the wave open')
check(#queued()==0,'no request while a child is still running')
settle(second)
local last=wave.finalize(ctx)
local requests=queued()
check(#requests==1,'the last child settling writes exactly one request')
local request=request_of(requests[1])
check(request.verb=='deploy','the request is a deploy')
check(request.target_commit==tip,'the request targets origin/main')
check(type(request.queued_at)=='number' and request.queued_at>0,'the request is stamped with its queue time')
check(request.session==nil and request.prompt==nil,'no conversation is woken by it')
check(last and last.deploy and last.deploy.state=='queued','the finalize reports the queue')
check(last.deploy.line=='deploy: queued '..tip:sub(1,8),'the line names the target: '..tostring(last.deploy.line))
local notice=report(ctx,last)
check(notice=='deploy: queued '..tip:sub(1,8),'the wave report carries the deploy line: '..tostring(notice))
check(report(ctx,last)==nil,'the same answer is not repeated')
-- Finalize twice in the same wave: still one request.
local again=wave.finalize(ctx)
check(#queued()==1,'a second finalize of the same wave writes no second request')
check(again and again.deploy and again.deploy.state=='skipped','and says why: '..tostring(again and again.deploy and again.deploy.line))
check(tostring(again.deploy.line):find('deploy: skipped (',1,true)==1,'the skip is a deploy line')
out.last_child=last.deploy.line

-- ---- 2. a request for the same target is already pending: no second one ----
local ctx2=parent()
local only=child(ctx2,'wave-deploy-child-3')
enable(ctx2)
installed(nil)
settle(only)
local pending=wave.finalize(ctx2)
check(#queued()==1,'a pending request for this target is not queued again')
check(pending.deploy.state=='skipped' and tostring(pending.deploy.line):find('already pending',1,true),
  'and the line says it is already pending: '..tostring(pending.deploy and pending.deploy.line))
out.pending=pending.deploy.line

-- ---- 3. installed == origin/main: nothing is written and the wave says so ----
local ctx3=parent()
local third=child(ctx3,'wave-deploy-child-4')
enable(ctx3)
installed(tip)
settle(third)
local current=wave.finalize(ctx3)
check(#queued()==1,'nothing new is written when the install is already main')
check(current.deploy.state=='not_needed','the outcome is not_needed')
check(current.deploy.line=='deploy: not needed (installed == main)','the exact line: '..tostring(current.deploy.line))
check(report(ctx3,current)=='deploy: not needed (installed == main)','the report says it once')
check(report(ctx3,current)==nil,'and not twice')
out.current=current.deploy.line

-- ---- 4. a dirty source tree: no request, and the dirty paths are named ----
local ctx4=parent()
local fourth=child(ctx4,'wave-deploy-child-5')
enable(ctx4)
installed(nil)
write(main..'/review-notes.md','unreviewed work\n')
check(git(main,'status','--porcelain','--untracked-files=all'):find('review-notes.md',1,true)~=nil,'the fixture main is dirty')
settle(fourth)
local dirty=wave.finalize(ctx4)
check(#queued()==1,'a dirty tree writes no request')
check(dirty.deploy.state=='skipped','the outcome is skipped')
check(tostring(dirty.deploy.reason):find('source dirty',1,true)==1,'the reason is the dirty source: '..tostring(dirty.deploy.reason))
check(dirty.deploy.line:find('deploy: skipped (source dirty',1,true)==1,'the line names the dirty source')
check(dirty.deploy.line:find('review-notes.md',1,true)~=nil,'and the dirty path: '..tostring(dirty.deploy.line))
check(#(dirty.deploy.paths or {})==1,'the paths are reported as data, not only as text')
local dirty_notice=report(ctx4,dirty)
check(dirty_notice and dirty_notice:find('deploy: skipped (source dirty',1,true)==1,'the report carries it: '..tostring(dirty_notice))
out.dirty=dirty.deploy.line
sh('git -C '..q(main)..' clean -fd')
check(git(main,'status','--porcelain','--untracked-files=all')=='','the fixture main is clean again')

-- ---- 5. two children, one request, and it appears only after the last settles ----
local ctx5=parent()
local left=child(ctx5,'wave-deploy-child-6')
local right=child(ctx5,'wave-deploy-child-7')
enable(ctx5)
installed(nil)
-- Remove the earlier request so this wave faces an empty box of its own.
local stale=queued()
check(#stale==1,'one request from the earlier waves')
sh('rm -f '..q(stale[1]))
check(#queued()==0,'the box is empty for this wave')
settle(left)
local holding=wave.finalize(ctx5)
check(holding and holding.deferred,'the wave is still working with one child running')
check(#queued()==0,'no request while any child runs')
settle(right)
local final=wave.finalize(ctx5)
check(#queued()==1,'the request appears when the last child settles')
check(request_of(queued()[1]).target_commit==tip,'and it targets origin/main')
check(final.deploy.state=='queued','the finalize reports the queue')
out.two_children=final.deploy.line

check(git(main,'status','--porcelain','--untracked-files=all')=='','fixture main left clean')
check(git(child_tree,'status','--porcelain','--untracked-files=all')=='','fixture child left clean')
local box=queued()
print(json.encode({ok=true,checks=checks,requests=#box,request_box=requests_dir,lines=out,
  request=#box>0 and request_of(box[#box]) or nil,
  live_installation=false,sentinel_contacted=false,label='FAKE request directory under a scratch home'}))
