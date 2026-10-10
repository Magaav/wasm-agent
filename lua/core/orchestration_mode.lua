-- Conversation-owned routing preference, not fleet placement or a background job.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local users=dofile('lua/core/users.lua')
local nodes=dofile('lua/core/nodes.lua')
local M={}
M.PROFILE='orchestration-worker'
local function key(id) return 'orchestration-mode:'..id end
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
  if args.mode_action=='get' or not args.mode_action then return {ok=true,orchestration=M.read(ctx.session_id)} end
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
  -- Automated completion/deploy reports stay coordinator work, never recursive tasks.
  return not tostring(text):match('^%[Sentinel notice%]') and not tostring(text):match('^%[Child completion notice%]')
end
function M.route(self,text,images)
  if self.subagent or not users.is_master(self.role) or not M.is_task(text) or not M.read(self.session_id).enabled then return nil end
  if host.subagent then
    -- Read back any prior admission for this exact parent request before start.
    local observed=json.decode(host.subagent('resolve',json.encode({owner_user=self.user,idempotency_key='route:'..self.run_id})))
    if type(observed)~='table' or observed.error then
      return {reply='Delegation lookup unavailable. No new admission or direct fallback; inspect original request.',receipt=observed,ok=false}
    end
    if observed.found and observed.subagent_id then
      return {reply='Delegation already recorded · '..observed.subagent_id..' · '..tostring(observed.state)..'. Inspect its original report; no task replay.',receipt=observed,ok=true}
    end
  end
  local context='Exact operator task. Own it end to end; report back. No nested delegation, Sentinel, update, deployment or installed UI writes. Coordinator followups arrive only after your report.'
  if images and #images>0 then context=context..'\nRetained image references (inspect with read): '..json.encode(images) end
  local source=memory.session_workspace(self.session_id)
  if source and source.state=='allocated' then
    context=context..'\nTarget source: '..tostring(source.source_path or source.worktree)..'. Owned worker tree is allocated by the runtime; canonical integration is discovered from its linked Git repository.'
  end
  local called,receipt=pcall(function() return dofile('lua/core/subagents.lua').control({action='start',profile=M.PROFILE,
    prompt=text,context=context,title=tostring(text):gsub('%s+',' '):sub(1,90),idempotency_key='route:'..self.run_id},
    {user_id=self.user,role=self.role,session_id=self.session_id,run_id=self.run_id,node_id=self.node,
      placement={}, -- Explicit mode stays local; no unrelated fleet policy or remote authority change.
      model=self.model,reasoning=(dofile('lua/core/provider.lua').reasoning(self.model) or {}).selected}) end)
  if not called then receipt={error='delegation_outcome_unconfirmed',detail=tostring(receipt),state='unknown'} end
  local started=type(receipt)=='table' and receipt.subagent_id and not receipt.error
    and receipt.state~='unknown' and receipt.state~='refused'
  local reply=started and ('Delegated · '..tostring(receipt.title or receipt.subagent_id)..' · '..tostring(receipt.state)..'. I am free for the next request; the worker will report back.')
    or ('Delegation not confirmed: '..tostring(receipt and (receipt.error or receipt.state) or 'unreadable_receipt')..'. No direct fallback or automatic retry; inspect the original receipt.')
  return {reply=reply,receipt=receipt,ok=started and true or false}
end
return M
