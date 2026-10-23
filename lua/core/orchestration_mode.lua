-- Conversation-owned delegation preference, not an automatic task router.
-- The coordinator assesses full conversation context before requesting any child.
--
-- The mode is permission plus one recorded decision. A turn is routed by the coordinator -
-- "direct" for a quick answer, a read-only inspection or a short one-step task it does here,
-- "delegate" for a concrete implementation or multi-step change it hands to a child - and an
-- effectful direct call is refused until that route exists. The floor reads the mode state,
-- the route record and the admission record only: never the user's text. It is not a router,
-- it starts nothing, and blind delegation is a failure, not the goal: a wrong route is a
-- recorded misroute, not a shortcut.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local users=dofile('lua/core/users.lua')
local nodes=dofile('lua/core/nodes.lua')
local M={}
M.PROFILE='orchestration-worker'
local function key(id) return 'orchestration-mode:'..id end
local function admitted_key(id) return 'orchestration-admitted:'..id end
local function route_key(id) return 'orchestration-route:'..id end
function M.read(id)
  local raw=memory.meta_get(key(id))
  if not raw then return {enabled=false,revision=0,thread=id} end
  local ok,value=pcall(json.decode,raw)
  if not ok or type(value)~='table' or type(value.enabled)~='boolean' or type(value.revision)~='number'
      or value.revision<0 or value.revision%1~=0 then error('orchestration_mode_corrupt') end
  value.thread=id;return value
end
function M.control(args,ctx)
  if ctx.subagent or ctx.remote or not users.is_master(ctx.role) or not nodes.is_master() then return {error='orchestration_operator_only'} end
  local parent=memory.session(ctx.session_id)
  if not parent or parent.user_id~=ctx.user_id or parent.objective=='subagent' then return {error='forbidden_parent_session'} end
  if args.mode_action=='get' or not args.mode_action then return {ok=true,orchestration=M.read(ctx.session_id),route=M.routing(ctx.session_id)} end
  return memory.transaction(function()
    local value=M.read(ctx.session_id)
    if args.mode_action~='toggle' and args.mode_action~='set' then return {error='invalid_orchestration_action'} end
    if args.revision~=value.revision then return {error='orchestration_mode_conflict',orchestration=value} end
    local enabled=args.enabled
    if args.mode_action=='toggle' then enabled=not value.enabled end
    if type(enabled)~='boolean' then return {error='orchestration_enabled_required'} end
    value={enabled=enabled,revision=value.revision+1,thread=ctx.session_id}
    memory.meta_set(key(ctx.session_id),json.encode(value))
    return {ok=true,orchestration=value}
  end)
end
function M.is_task(text)
  return not tostring(text):match('^%[Sentinel notice%]') and not tostring(text):match('^%[Child completion notice%]')
end
-- Compatibility for old internal callers: mode is permission, never a dispatch.
-- A raw continuation cannot become a child before coordinator inference/context.
function M.route() return nil end

-- The effects that are the *work*: writing files, running a command, changing a worktree and
-- landing a tip. Reads, discovery, memory and status stay direct.
local DIRECT_EFFECT={write=true,write_many=true,edit=true,edit_many=true,bash=true,shell=true,
  integrate=true,spell_run=true,operation=true,session_worktree=true}
-- Shell verbs whose whole effect is reading. Anything unlisted - an interpreter, a wrapper, a
-- heredoc - counts as an effect: a wrong "read-only" would let the work through, while a
-- wrong "effect" costs one refusal that names the required route.
local READ_VERBS={rg=true,grep=true,ls=true,cat=true,head=true,tail=true,wc=true,pwd=true,
  echo=true,printf=true,stat=true,file=true,diff=true,du=true,df=true,date=true,uname=true,
  basename=true,dirname=true,realpath=true,readlink=true,sha256sum=true,md5sum=true,
  sort=true,uniq=true,cut=true,tr=true,jq=true,column=true,test=true,['true']=true,['false']=true}
local GIT_READ={status=true,diff=true,log=true,show=true,['rev-parse']=true,['ls-files']=true,
  ['ls-tree']=true,['cat-file']=true,blame=true,describe=true,['show-ref']=true,
  ['for-each-ref']=true,grep=true,shortlog=true,['merge-base']=true,['diff-tree']=true,
  ['count-objects']=true}
local VERSION_ONLY={node=true,npm=true,cargo=true,go=true,python=true,python3=true,deno=true,
  bun=true,rustc=true}

-- True only for a command that cannot change anything: every simple command is an allowlisted
-- verb (or `git` with an allowlisted subcommand), and there is no redirection, heredoc or
-- substitution. A null sink (`2>/dev/null`, `2>&1`) is not a write.
function M.read_only_command(command)
  local text=tostring(command or '')
  if text=='' then return false end
  text=text:gsub('%d*>%s*&%d+',''):gsub('%d*>%s*/dev/null','')
  if text:find('[<>`\r\n]') or text:find('$(',1,true) then return false end
  for segment in text:gmatch('[^|;&]+') do
    local words={}
    for word in segment:gmatch('%S+') do words[#words+1]=word end
    local i=1
    while words[i] and words[i]:match('^[%a_][%w_]*=') do i=i+1 end
    local verb=words[i]
    if not verb then return false end
    if verb=='git' then
      local sub=words[i+1]
      if not (sub=='--version' or sub=='-v' or (sub and GIT_READ[sub])) then return false end
      for _,word in ipairs(words) do if word:lower():find('^%-%-output') ~= nil then return false end end
    elseif VERSION_ONLY[verb] then
      local rest=words[i+1]
      if rest and rest~='--version' and rest~='-v' and rest~='version' then return false end
    elseif not READ_VERBS[verb] then
      return false
    end
  end
  return true
end

function M.effectful(name,args)
  if not DIRECT_EFFECT[name] then return false end
  args=args or {}
  if name=='bash' or name=='shell' then return not M.read_only_command(args.command) end
  if name=='operation' then return tostring(args.action or 'start')=='start' end
  if name=='session_worktree' then return tostring(args.action or 'status')~='status' end
  return true
end

-- True when this conversation is in orchestration mode. A child, a sessionless call and a
-- corrupt record are all not-the-mode's-business here.
function M.mode_on(ctx)
  local sid=ctx and ctx.session_id
  if type(sid)~='string' or sid=='' then return false end
  local ok,state=pcall(M.read,sid)
  return ok and state.enabled==true
end

-- The turn a record belongs to. `run_id` is this run (a steering note only adds a later user
-- row to it); `user_seq` is the newest user row, so a resumed run of the same turn matches too.
local function same_turn(record,ctx,sid)
  local run=tostring(ctx.run_id or '')
  if run~='' and tostring(record.run_id or '')==run then return true end
  return (tonumber(record.user_seq) or 0)>=(memory.latest_user_seq(sid) or 0)
end

-- Written by `subagents.start` once a child is admitted, and only while the mode is on.
function M.record_admission(ctx,receipt)
  local sid=ctx and ctx.session_id
  if type(sid)~='string' or sid=='' then return false end
  if not M.mode_on(ctx) then return false end
  receipt=receipt or {}
  memory.meta_set(admitted_key(sid),json.encode{run_id=tostring(ctx.run_id or ''),
    user_seq=memory.latest_user_seq(sid),subagent_id=tostring(receipt.subagent_id or ''),
    child_session=tostring(receipt.session_id or ''),profile=tostring(receipt.profile or ''),
    thread=sid})
  return true
end

-- The admission record, or nil. An unreadable record is reported as invalid, never as "admitted".
function M.admission(session_id)
  local raw=memory.meta_get(admitted_key(session_id))
  if not raw then return nil end
  local ok,value=pcall(json.decode,raw)
  if not ok or type(value)~='table' then return {invalid=true} end
  return value
end

function M.delegated(ctx,sid)
  local marker=M.admission(sid)
  if not marker or marker.invalid then return false end
  return same_turn(marker,ctx,sid)
end

-- The routing decision the coordinator recorded, or nil. It is a decision, not an action:
-- recording one starts nothing and executes nothing.
function M.routing(session_id)
  local raw=memory.meta_get(route_key(session_id))
  if not raw then return nil end
  local ok,value=pcall(json.decode,raw)
  if not ok or type(value)~='table' or (value.route~='direct' and value.route~='delegate') then
    return {invalid=true}
  end
  return value
end

function M.record_route(args,ctx)
  args=args or {}
  ctx=ctx or {}
  local sid=ctx.session_id
  if type(sid)~='string' or sid=='' then return {error='session_required'} end
  if ctx.subagent then return {error='orchestration_operator_only'} end
  if not M.mode_on(ctx) then return {error='orchestration_mode_not_enabled',not_started=true} end
  local route=tostring(args.route or '')
  if route~='direct' and route~='delegate' then return {error='route_direct_or_delegate_required',effect='none'} end
  local function sentence(value,limit)
    local text=tostring(value or ''):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
    if #text>limit then text=text:sub(1,limit) end
    return text
  end
  local task=sentence(args.task,400)
  if task=='' then return {error='route_task_required',effect='none',
    detail='state the task in your own words, so the route can be judged from what you understood'} end
  local reason=sentence(args.reason,400)
  local record={route=route,task=task,reason=reason,run_id=tostring(ctx.run_id or ''),
    user_seq=memory.latest_user_seq(sid),thread=sid,at=host.now()}
  memory.meta_set(route_key(sid),json.encode(record))
  pcall(function()
    dofile('lua/core/telemetry.lua').event(sid,tostring(ctx.run_id or ''),'','orchestration_route',
      route,{route=route,task_chars=#task,has_reason=reason~=''})
  end)
  return {ok=true,route=route,task=task,reason=reason,started_child=false,effect='none',
    note=route=='delegate'
      and 'Routed delegate: start the child (subagent action="start", profile="'..M.PROFILE
        ..'") with the bounded prompt and the relevant context, then continue from its report. '
        ..'Direct effects stay refused until that child exists.'
      or 'Routed direct: a read-only inspection or a short one-step task may be done here. A '
        ..'concrete implementation or multi-step change belongs in a delegated turn instead.'}
end

function M.refusal(name,kind)
  local tool=tostring(name or '')
  local refusal={effect='none',not_started=true,tool=tool,mode='on',route=kind,
    required_profile=M.PROFILE,
    handoff={tool='subagent',arguments={action='start',profile=M.PROFILE,
      title='<short task-specific heading>',prompt='<the bounded task, authored here>',
      context='<the relevant context, decisions and acceptance criteria>'}}}
  if kind=='delegate' then
    refusal.error='orchestration_delegate_required'
    refusal.note='This turn is routed delegate, so the coordinator did not run `'..tool
      ..'` itself. Start the child (subagent action="start", profile="'..M.PROFILE
      ..'", with the bounded prompt and the context/acceptance criteria) and continue from its '
      ..'report. If the route was wrong for genuinely short work, record route_task '
      ..'route="direct" with the reason and do it here; a concrete implementation routed direct '
      ..'is a misroute, not a shortcut.'
  else
    refusal.error='orchestration_route_required'
    refusal.note='Orchestration mode is on and this turn has no routing decision yet, so `'..tool
      ..'` was refused before it ran and no child was started. Decide first, in this same '
      ..'request: route_task route="direct" for a quick answer, a read-only inspection or a short '
      ..'one-step task you will do here (task in your own words, one-line reason), or route_task '
      ..'route="delegate" for a concrete implementation or multi-step change, followed by the '
      ..'child (subagent action="start", profile="'..M.PROFILE..'", bounded prompt and context). '
      ..'Questions and pure reads need no route at all. Do not re-issue this call unchanged.'
  end
  return refusal
end

-- The floor. `nil` means: not mode-on, a child's own call, read-only, a recorded direct route
-- for this turn, or a child already admitted for it.
function M.guard(name,args,ctx)
  ctx=ctx or {}
  if ctx.subagent then return nil end
  if not M.effectful(name,args) then return nil end
  local sid=ctx.session_id
  if type(sid)~='string' or sid=='' then return nil end
  if not M.mode_on(ctx) then return nil end
  if M.delegated(ctx,sid) then return nil end
  local routing=M.routing(sid)
  if routing and not routing.invalid and same_turn(routing,ctx,sid) then
    if routing.route=='direct' then return nil end
    return M.refusal(name,'delegate')
  end
  return M.refusal(name,'unrouted')
end
return M
