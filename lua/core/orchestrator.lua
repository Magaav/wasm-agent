-- Ordered placement is Lua policy. Native child admission reserves capacity;
-- the serve-owned timer only supplies lifetime. No model runs in this module.
local json = dofile("lua/vendor/json.lua")
local nodes = dofile("lua/core/nodes.lua")
local users = dofile("lua/core/users.lua")
local provider = dofile("lua/core/provider.lua")
local M = {}
local function sql(kind, statement, values)
  local result = json.decode(host[kind](statement, json.encode(values or {})))
  if result.error then error(result.error) end
  return result
end
local function query(statement, values) return sql("sql_query", statement, values) end
local function exec(statement, values) return sql("sql_exec", statement, values) end
function M.policy(owner)
  local row = query("SELECT policy FROM orchestration_policy WHERE owner=?", {owner})[1]
  return row and json.decode(row.policy) or { enabled=false, nodes={} }
end
function M.enabled(owner) return M.policy(owner).enabled == true end

function M.validate(policy)
  if type(policy) ~= "table" or type(policy.enabled) ~= "boolean" or type(policy.nodes) ~= "table" then
    return nil, "invalid_placement_policy"
  end
  if #policy.nodes > 32 or (policy.enabled and #policy.nodes == 0) then return nil, "placement_nodes_required" end
  local clean, seen = {enabled=policy.enabled, nodes={}}, {}
  for _, item in ipairs(policy.nodes) do
    local id = type(item) == "table" and item.node
    local limit = type(item) == "table" and item.max_tasks
    if type(id) ~= "string" or id == "" or seen[id] then return nil, "invalid_placement_node" end
    if type(limit) ~= "number" or limit % 1 ~= 0 or limit < 0 or limit > 128 then return nil, "invalid_node_limit" end
    seen[id] = true
    clean.nodes[#clean.nodes+1] = {node=id, max_tasks=limit}
  end
  return clean
end

local function view(row)
  local receipt = json.decode(row.receipt)
  receipt.remote_subagent_id = receipt.subagent_id
  receipt.subagent_id = row.id
  receipt.execution_node = row.destination
  receipt.dispatch_state = row.state
  receipt.state = receipt.state or row.state
  receipt.settled = receipt.settled == true or row.state == "cancelled" or row.state == "failed"
    -- A refused attempt has nothing left that could still happen, so it settles the completion the
    -- same way a cancelled one does, and the coordinator is woken to decide what to do with it.
    or row.state == "refused"
  receipt.error = receipt.error or (row.detail ~= "" and row.detail or nil)
  local args, ctx = json.decode(row.args), json.decode(row.context)
  receipt.prompt = args.prompt
  receipt.profile = receipt.profile or args.profile or "explore"
  receipt.model = receipt.model or args.model
  receipt.reasoning = receipt.reasoning or args.reasoning
  receipt.parent_session_id = ctx.session_id
  receipt.created_at = row.created_at
  receipt.completion=dofile('lua/core/completions.lua').status(row.id,row.owner)
  return receipt
end

function M.enqueue(args, ctx)
  if ctx.role ~= "master" or not nodes.is_master() then return {error="forbidden"} end
  if type(args.prompt) ~= "string" or args.prompt == "" then return {error="prompt_required"} end
  if #json.encode(args) > 524288 then return {error="prompt_too_large"} end
  local key = tostring(args.idempotency_key or args.delivery_id or host.uuid())
  local copy = json.decode(json.encode(args))
  copy.model = copy.model or ctx.model or provider.settings().model
  copy.reasoning = copy.reasoning or ctx.reasoning
  copy.parent_session_id = ctx.session_id
  local context = { user_id=ctx.user_id, role=ctx.role, session_id=ctx.session_id,
    run_id=ctx.run_id, node_id=ctx.node_id, model=copy.model, reasoning=copy.reasoning }
  exec("INSERT OR IGNORE INTO orchestration_tasks(id,owner,request_key,args,context,created_at) " ..
    "SELECT ?,?,?,?,?,? WHERE (SELECT COUNT(*) FROM orchestration_tasks WHERE owner=? AND state IN ('queued','placing'))<128",
    {"dispatch:"..host.uuid(), ctx.user_id, key, json.encode(copy), json.encode(context), host.now(),ctx.user_id})
  local row = query("SELECT * FROM orchestration_tasks WHERE owner=? AND request_key=?", {ctx.user_id,key})[1]
  if not row then return {error="placement_queue_full"} end
  dofile('lua/core/completions.lua').watch(row.id,ctx)
  local result = view(row)
  result.note = "Queued durably for ordered placement. Observe this receipt; do not submit it again with a new key."
  return result
end

local function invoke(destination, args, ctx, api)
  if destination == "local" then
    local local_ctx = {}
    for k,v in pairs(ctx) do local_ctx[k]=v end
    local_ctx.remote = true
    local_ctx.placement = args.placement
    return api.control(args, local_ctx)
  end
  return nodes.remote_call(destination, "subagent", args)
end

-- A refusal below proves no admission happened. Transport failures never do.
--
--   admitted  - a receipt with a subagent id: a run exists there.
--   spilled   - a refusal that proves nothing was started and that another candidate may still be
--               able to take: capacity (`node_full`, `queue_full`, runtime unavailable) and a
--               destination whose own checkout cannot be named at all. The pin is dropped so the
--               next tick re-reads eligibility, which is also why removing a node from the policy
--               stops it being tried.
--   refused   - a refusal that proves nothing was started and that no candidate can be asked to
--               take as it stands: the attempt is over, and the coordinator may retract the row
--               instead of waiting for an admission that cannot come. Measured: a destination that
--               answered `workspace_session_not_found` was re-dispatched every ~2.5s for minutes,
--               and every attempt wrote another empty session shell on the node that had just
--               refused it.
--   uncertain - anything else: the request may or may not have arrived, so only the pinned
--               destination and key are retried (`no blind failover or replay`).
local unadmitted = {node_full=true, queue_full=true, subagent_runtime_unavailable=true,
  workspace_destination_source_missing=true}
function M.classify(result)
  if type(result) ~= "table" then return "uncertain" end
  if result.subagent_id then return "admitted" end
  if unadmitted[result.error] then return "spilled" end
  -- `not_started` is the destination's own statement that no run of its was created for this
  -- request. It is only read together with an error: a receipt with neither an id nor an error
  -- proves nothing at all and keeps the pinned retry.
  if result.not_started and result.error then return "refused" end
  return "uncertain"
end

function M.tick(api)
  for _, row in ipairs(query("SELECT * FROM orchestration_tasks WHERE state IN ('queued','placing') ORDER BY created_at LIMIT 32")) do
    local user = users.find(row.owner)
    if not user or not users.is_master(user.role) or not nodes.is_master() then
      exec("UPDATE orchestration_tasks SET state='failed',detail='authority_revoked' WHERE id=?", {row.id})
    else
      local policy = M.policy(row.owner)
      local args, ctx = json.decode(row.args), json.decode(row.context)
      local choices = policy.enabled and policy.nodes or {}
      -- Once delivery might have happened, only resolve/retry the pinned target.
      if row.destination ~= "" then choices={{node=row.destination, max_tasks=tonumber(args.admission_limit) or 1}} end
      for _, item in ipairs(choices) do
        if item.max_tasks > 0 then
          local target = item.node == "local" and {local_node=true,online=true} or nodes.find(item.node)
          if target and (target.online ~= false or row.destination ~= "") then
            local destination = target.local_node and "local" or item.node
            if row.destination == "" then
              args.admission_limit=item.max_tasks
              local reserved = exec("UPDATE orchestration_tasks SET destination=?,state='placing',args=? WHERE id=? AND state='queued'",
                {destination,json.encode(args),row.id})
              -- Cancellation may win after the queue snapshot was read.
              if reserved.changes ~= 1 then break end
            end
            args.action="start"
            args.idempotency_key=row.id
            args.placement={max_tasks=item.max_tasks}
            local ok, result = pcall(invoke,destination,args,ctx,api)
            if not ok then result={error="dispatch_uncertain",detail=tostring(result)} end
            local outcome = M.classify(result)
            if outcome == "admitted" then
              exec("UPDATE orchestration_tasks SET state='admitted',receipt=?,detail='' WHERE id=?",
                {json.encode(result),row.id})
              break
            elseif outcome == "spilled" then
              exec("UPDATE orchestration_tasks SET state='queued',destination='',detail=? WHERE id=?", {result.error,row.id})
              row.destination=""
            elseif outcome == "refused" then
              -- The destination answered, and its answer proves no run of it was started, so
              -- nothing is left in flight to reconcile. The attempt ends here with the refusal on
              -- the row; the coordinator reads it and cancels the row if it will not retry.
              exec("UPDATE orchestration_tasks SET state='refused',detail=? WHERE id=?", {json.encode(result),row.id})
              break
            else
              -- Keep target/key for reconciliation; no blind failover or replay.
              exec("UPDATE orchestration_tasks SET detail=? WHERE id=?", {json.encode(result),row.id})
              break
            end
          end
        end
      end
    end
  end
end

function M.control(args, ctx, api)
  local action = args.action or "list"
  local id = tostring(args.id or args.subagent_id or "")
  if action == "placement" or action == "fleet" then
    if ctx.role ~= "master" or not nodes.is_master() then return true,{error="forbidden"} end
    if action == "placement" and args.policy ~= nil then
      local policy, problem = M.validate(args.policy)
      if not policy then return true,{error=problem} end
      exec("INSERT INTO orchestration_policy(owner,policy) VALUES(?,?) ON CONFLICT(owner) DO UPDATE SET policy=excluded.policy",
        {ctx.user_id,json.encode(policy)})
    end
    return true,{policy=M.policy(ctx.user_id),nodes=nodes.list()}
  end
  if id:sub(1,9) == "dispatch:" then
    if ctx.role ~= "master" or not nodes.is_master() then return true,{error="forbidden"} end
    local row = query("SELECT * FROM orchestration_tasks WHERE id=? AND owner=?", {id,ctx.user_id})[1]
    if not row then return true,{error="unknown_subagent"} end
    if action=="await" then
      local deadline=host.now()+math.min(60000,math.max(0,tonumber(args.wait_ms or args.timeout_ms) or 60000))/1000
      while (row.state=="queued" or row.state=="placing") and host.now()<deadline do
        host.sleep(100)
        row=query("SELECT * FROM orchestration_tasks WHERE id=? AND owner=?",{id,ctx.user_id})[1]
      end
      args.wait_ms=math.max(0,math.floor((deadline-host.now())*1000))
    end
    if (row.state == "queued" or row.state == "refused") and action == "cancel" then
      -- A refused attempt is retractable without reconciliation: the destination said it never
      -- started a run, so there is nothing in flight to reconcile - which is exactly what the
      -- `placing` guard below protects, and why it does not apply here.
      exec("UPDATE orchestration_tasks SET state='cancelled' WHERE id=? AND state IN ('queued','refused')", {id})
      row=query("SELECT * FROM orchestration_tasks WHERE id=?",{id})[1]
    end
    if row.state ~= "admitted" then
      if action=="message" or action=="session" or action=='steer' or action=='steering_status' then return true,{error="placement_pending"} end
      if action=="cancel" and row.state=="placing" then return true,{error="placement_uncertain_reconcile_before_cancelling"} end
      return true,view(row)
    end
    local receipt = json.decode(row.receipt)
    local forwarded = json.decode(json.encode(args))
    forwarded.id=receipt.subagent_id
    forwarded.subagent_id=nil
    local result=invoke(row.destination,forwarded,json.decode(row.context),api)
    if action == "status" or action == "result" or action == "await" or action == "cancel" then
      if result.subagent_id then
        exec("UPDATE orchestration_tasks SET receipt=? WHERE id=?",{json.encode(result),id})
        row.receipt=json.encode(result)
        return true,view(row)
      end
    elseif action == "message" and result.subagent_id then
      dofile('lua/core/completions.lua').watch(row.id,json.decode(row.context),result.subagent_id)
      -- The card follows the latest run in the same conversation.
      exec("UPDATE orchestration_tasks SET receipt=? WHERE id=?",{json.encode(result),id})
      row.receipt=json.encode(result)
      return true,view(row)
    end
    if action=='session' and type(result.messages)=='table' then
      for _,message in ipairs(result.messages) do
        if message.evidence and message.evidence.tool=='subagent' then message.evidence.id=id end
      end
    end
    return true,result
  end
  if action == "list" then
    if ctx.role ~= "master" or not nodes.is_master() then return false end
    local local_ctx = {}
    for k,v in pairs(ctx) do local_ctx[k]=v end
    local_ctx.remote=true
    local list=api.control({action="list"},local_ctx)
    local tasks, remote_ids = {}, {}
    for _, row in ipairs(query("SELECT * FROM orchestration_tasks WHERE owner=? ORDER BY created_at DESC",{ctx.user_id})) do
      if row.state=="admitted" then
        local receipt=json.decode(row.receipt)
        local result=invoke(row.destination,{action="status",id=receipt.subagent_id},json.decode(row.context),api)
        if result.subagent_id then row.receipt=json.encode(result)
        else row.detail="Node status unavailable: "..json.encode(result) end
        if row.destination=="local" then remote_ids[receipt.session_id]=true end
      end
      tasks[#tasks+1]=view(row)
    end
    for _, task in ipairs(list.subagents or {}) do
      if not remote_ids[task.session_id] then task.execution_node="local"; tasks[#tasks+1]=task end
    end
    return true,{subagents=tasks}
  end
  return false
end

return M
