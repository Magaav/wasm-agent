-- Policy for cooperative resource ownership. Arbitrary operator shell commands
-- are not sandboxed; these claims cover participating runs and client tools.
local json = dofile("lua/vendor/json.lua")
local M = {}
local function call(action, args)
  if not host.resource then return {error="resource_capability_unavailable"} end
  local ok, raw=pcall(host.resource,action,json.encode(args or {}))
  if not ok then return {error="resource_store_failed",detail=tostring(raw)} end
  local decoded,value=pcall(json.decode,raw)
  if not decoded or type(value)~="table" then return {error="resource_store_invalid_result"} end
  return value
end
local function owner(ctx)
  return {principal=ctx.user_id,session=ctx.session_id,run=ctx.run_id}
end
function M.claim(ctx,keys)
  local args=owner(ctx); args.keys=keys
  return call("claim",args)
end
function M.begin(ctx)
  local key="session:"..tostring(ctx.session_id)
  local result=M.claim(ctx,{key})
  if result.error=="resource_busy" and result.claim and result.claim.key==key then
    -- A newly submitted run may reclaim a dead session owner, never a desktop
    -- or other effectful resource. The host refuses while that owner is alive.
    local prior=result.claim
    local recovered=call("reconcile",{key=key,principal=prior.principal,run=prior.run,
      evidence="New explicit run claims session execution after the prior owner ended; no effects replayed."})
    if recovered.ok then result=M.claim(ctx,{key}) end
  end
  if not result.ok then return result end
  local exclusive=ctx.subagent and ctx.subagent.resources and ctx.subagent.resources.exclusive
  if exclusive~=nil then
    if type(exclusive)~="table" then M.finish(ctx); return {error="invalid_exclusive_resources"} end
    local keys={}
    for _,name in ipairs(exclusive) do
      if type(name)~="string" or name=="" then M.finish(ctx); return {error="invalid_exclusive_resource"} end
      keys[#keys+1]="shared:"..name
    end
    if #keys>0 then
      result=M.claim(ctx,keys)
      if not result.ok then M.finish(ctx); return result end
    end
  end
  return result
end
function M.finish(ctx) return call("finish",owner(ctx)) end
function M.uncertain(ctx) return call("uncertain",owner(ctx)) end
function M.inspect() return call("list",{}) end
function M.reconcile(args) return call("reconcile",args) end
return M
