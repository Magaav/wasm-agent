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
-- A RUN THAT CANNOT HAVE ITS SESSION BECAUSE ANOTHER RUN IS WORKING IT (r7c, 24/11).
--
-- MEASURED on the live node: a resume wake's completion was handed a node-thread, could not take its session's
-- claim (an attended CLI turn held it), and the node-thread was gone for 29 minutes while every other session's
-- wake queued behind it. A wake must never wait for a person's turn to end: it defers, keeps its row and its
-- time, and the node-thread is free at once. The words live here, in the module that owns the claim, because
-- TWO places produce and read them - `lua/core/agent.lua` refuses the turn with them and `lua/core/selfloop.lua`
-- recognises the refusal and defers the wake - and a second spelling is how the two would drift.
M.BUSY_REFUSAL = "session_busy: another run of this session is still working; this turn did not start"
function M.is_busy_refusal(text)
  return type(text) == "string" and text:sub(1, #M.BUSY_REFUSAL) == M.BUSY_REFUSAL
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
    if recovered.ok then
      result=M.claim(ctx,{key})
      if result.ok then
        -- An audit line: a stale claim taken over is a fact the operator reads, with nothing replayed.
        result.reclaimed={key=key,principal=prior.principal,run=prior.run}
        result.audit=string.format("run lock reclaimed: %s was held by run %s (principal %s), which is no "..
          "longer running; no effect was replayed",key,tostring(prior.run),tostring(prior.principal))
      end
    end
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
-- Clear this run's own uncertainty on a claim it still holds, with the evidence that
-- was inspected. Narrow by construction: the host accepts it only from the same run,
-- principal and process that granted the claim. Never a release.
function M.recover(ctx,key,evidence)
  local args=owner(ctx); args.key=key; args.evidence=evidence
  return call("recover",args)
end
function M.inspect() return call("list",{}) end
function M.reconcile(args) return call("reconcile",args) end
return M
