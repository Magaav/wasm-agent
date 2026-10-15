-- Conversation-owned delegation preference, not an automatic task router.
-- The coordinator assesses full conversation context before requesting any child.
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
  return not tostring(text):match('^%[Sentinel notice%]') and not tostring(text):match('^%[Child completion notice%]')
end
-- Compatibility for old internal callers: mode is permission, never a dispatch.
-- A raw continuation cannot become a child before coordinator inference/context.
function M.route() return nil end
return M
