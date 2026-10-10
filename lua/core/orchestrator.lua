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

local function discovery_error(row)
  if not row.detail or row.detail=='' then return nil end
  local ok,value=pcall(json.decode,row.detail)
  if ok and type(value)=='table' then
    local named=value.error or value.reason
    return type(named)=='string' and named~='' and named:sub(1,256) or nil
  end
  if ok then return type(value)=='string' and value~='' and value:sub(1,256) or nil end
  return row.detail:sub(1,256)
end

local function observations()
  exec("CREATE TABLE IF NOT EXISTS orchestration_observations (dispatch_id TEXT PRIMARY KEY, source_receipt TEXT NOT NULL, observation TEXT NOT NULL)")
end
local function recorded(row)
  if row.destination=='local' then return json.decode(row.receipt) end
  observations()
  local item=query('SELECT observation FROM orchestration_observations WHERE dispatch_id=? AND source_receipt=?',{row.id,row.receipt})[1]
  return json.decode(item and item.observation or row.receipt)
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
  -- How many times a destination has been asked for this task. A refusal that loops (capacity) has to
  -- be countable from the receipt, or "it keeps retrying" is only something a log reader can see.
  receipt.attempts = tonumber(args.dispatch_attempts) or 0
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
  local api = dofile("lua/core/subagents.lua")
  local profile, problem = api.resolve(tostring(copy.profile or "explore"), ctx)
  if not profile then return {error=problem} end
  local selected
  selected, problem = api.selection(copy, ctx, profile)
  if not selected then return {error=problem} end
  copy.model, copy.reasoning, copy.provider = selected.model, selected.reasoning, selected.provider
  copy.parent_session_id = ctx.session_id
  local context = { user_id=ctx.user_id, role=ctx.role, session_id=ctx.session_id,
    run_id=ctx.run_id, node_id=ctx.node_id, model=ctx.model, reasoning=ctx.reasoning }
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
--               stops it being tried. `subagents.RETRYABLE_ADMISSION` is the other half of this
--               distinction (which refusals keep the child session for the retry to reuse), and the
--               placement fixture fails if the two ever disagree.
--   refused   - a refusal that proves nothing was started and that no candidate can be asked to
--               take as it stands: the attempt is over, and the coordinator may retract the row
--               instead of waiting for an admission that cannot come. Measured: a destination that
--               answered `workspace_session_not_found` was re-dispatched every ~2.5s for minutes,
--               and every attempt wrote another empty session shell on the node that had just
--               refused it.
--   uncertain - nothing was proved: the request may have arrived, so re-sending it could start a
--               second run of the same task. The row is *parked* (`unknown`, destination and key
--               kept) rather than retried; `reconcile` asks the destination what it holds for the
--               key, and that answer decides whether a retry or a cancel is safe.
local unadmitted = {node_full=true, queue_full=true, subagent_runtime_unavailable=true,
  workspace_destination_source_missing=true}
function M.spills_on(error) return unadmitted[error] == true end
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

-- A dispatch that ended in `unknown` may have been delivered, so the last write wins: nothing is
-- sent again until the destination says whether it holds a run for the key.
local function parked(memory_row)
  return memory_row.state == "unknown" or memory_row.state == "placing"
end

-- Status is a signed control read, never a model probe. Old peers and absent
-- serving state remain unknown/compatible; responsiveness is not quota evidence.
function M.serving_eligible(destination, model, requested_provider)
  if destination=='local' then
    if not provider.serving then return true,'unknown' end
    if requested_provider and provider.active and provider.active().id~=requested_provider then return true,'provider_route_unavailable' end
    local value=provider.serving(model)
    return value.state~='blocked',value.reason or value.state
  end
  local target=nodes.find(destination)
  local node_id=target and target.node_id
  if not node_id or type(model)~='string' or model=='' then return true,'serving_identity_unknown' end
  local ok,value=pcall(nodes.remote_call,destination,'status',{model=model,provider=requested_provider,serving_identity_only=true})
  local identity=ok and type(value)=='table' and value.serving_identity
  if type(identity)~='table' or identity.node_id~=node_id or identity.model~=model or
      type(identity.provider)~='string' or identity.provider=='' or
      (requested_provider and identity.provider~=requested_provider) or
      type(identity.account_profile)~='string' or identity.account_profile=='' or
      type(identity.binding)~='string' or not identity.binding:match('^%x+$') or #identity.binding~=64 or
      type(identity.generation)~='number' or identity.generation<0 or identity.generation%1~=0 then
    return true,'serving_identity_unknown'
  end
  ok,value=pcall(nodes.remote_call,destination,'status',{model=model,provider=requested_provider,serving_identity=identity})
  local observed=ok and type(value)=='table' and value.serving
  if type(observed)~='table' then return true,'serving_metadata_unknown' end
  for _,key in ipairs({'node_id','model','provider','account_profile','binding','generation'}) do
    if observed[key]~=identity[key] then return true,'serving_identity_changed' end
  end
  if observed.state=='blocked' and (observed.reason=='provider_monthly_quota' or observed.reason=='provider_eligibility_corrupt') then
    return false,observed.reason
  end
  return true,'unknown'
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
      local has_capacity=false
      for _,candidate in ipairs(choices) do if candidate.max_tasks>0 then has_capacity=true end end
      if row.destination=='' and not has_capacity then
        exec("UPDATE orchestration_tasks SET detail='waiting_approved_capacity' WHERE id=? AND state='queued'",{row.id})
      end
      -- Once delivery might have happened, only resolve/retry the pinned target.
      if row.destination ~= "" then choices={{node=row.destination, max_tasks=tonumber(args.admission_limit) or 1}} end
      for _, item in ipairs(choices) do
        if item.max_tasks > 0 then
          local target = item.node == "local" and {local_node=true,online=true} or nodes.find(item.node)
          if target and (target.online ~= false or row.destination ~= "") then
            local destination = target.local_node and "local" or item.node
            local eligible, reason=M.serving_eligible(destination,args.model,args.provider)
            if not eligible and row.destination=='' then
              exec("UPDATE orchestration_tasks SET detail=? WHERE id=? AND state='queued'",
                {'waiting_provider_serving:'..reason,row.id})
            else
            if row.destination == "" then
              args.admission_limit=item.max_tasks
              -- Counted where an operator can read it (`attempts` on the receipt): a task that keeps
              -- being refused shows how many times a destination was asked, not only the last
              -- reason. Nothing is capped here, because every code that returns to this loop proved
              -- that nothing was started and left no effect behind (see section 2 of the placement
              -- contract in docs/ORCHESTRATOR-WORKSPACE.md).
              args.dispatch_attempts=(tonumber(args.dispatch_attempts) or 0)+1
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
              -- Nothing was proved about this delivery, so it is not sent again: a second send
              -- could start a second child for one task. The destination and key are kept for the
              -- reconcile that has to happen first (`action="reconcile"`).
              exec("UPDATE orchestration_tasks SET state='unknown',detail=? WHERE id=?", {json.encode(result),row.id})
              break
            end
            end -- serving eligibility; uncertain deliveries retain reconciliation rules
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
      -- `placing`/`unknown` guard below protects, and why it does not apply here.
      exec("UPDATE orchestration_tasks SET state='cancelled' WHERE id=? AND state IN ('queued','refused')", {id})
      row=query("SELECT * FROM orchestration_tasks WHERE id=?",{id})[1]
    end
    if action == "reconcile" then
      -- The only move for a delivery whose outcome was never observed: ask the destination whether
      -- it holds a run for this task's key. Its answer is authoritative and duplicate-free - the
      -- runtime looks the key up under the same lock that admission takes, so a request still in
      -- flight there is waited for, not raced.
      if not parked(row) then return true,{error="placement_not_uncertain",state=row.state} end
      local answer = invoke(row.destination,{action="resolve",idempotency_key=row.id},ctx,api)
      if type(answer) ~= "table" or not answer.idempotency_key then
        exec("UPDATE orchestration_tasks SET detail=? WHERE id=?",{json.encode(answer),row.id})
        return true,{error="reconcile_failed",detail=json.encode(answer),dispatch_state=row.state,
          dispatch_destination=row.destination}
      end
      if answer.found then
        -- A run exists there: adopt its receipt and supervise it. Nothing was re-sent.
        exec("UPDATE orchestration_tasks SET state='admitted',receipt=?,detail='' WHERE id=?",
          {json.encode(answer.receipt),row.id})
        return true,view(query("SELECT * FROM orchestration_tasks WHERE id=?",{id})[1])
      end
      -- Nothing was admitted there, so the attempt is over and the task may be placed again.
      exec("UPDATE orchestration_tasks SET state='queued',destination='',detail=? WHERE id=?",
        {json.encode({reconciled="unadmitted",from=row.destination}),row.id})
      return true,view(query("SELECT * FROM orchestration_tasks WHERE id=?",{id})[1])
    end
    if row.state ~= "admitted" then
      if action=="message" or action=="session" or action=='steer' or action=='steering_status' then return true,{error="placement_pending"} end
      if action=="cancel" and parked(row) then
        -- An unobserved delivery may be running there; cancelling on a guess is how a child keeps
        -- working after its task looks withdrawn. `action="reconcile"` is how the row stops being
        -- uncertain - it needs the destination's answer, not a coordinator's.
        return true,{error="placement_uncertain_reconcile_before_cancelling",state=row.state,
          dispatch_destination=row.destination}
      end
      return true,view(row)
    end
    local receipt = json.decode(row.receipt)
    if (action=='steer' or action=='message') and json.decode(row.args or '{}').profile=='orchestration-worker' then
      local actual=invoke(row.destination,{action='status',id=receipt.subagent_id},json.decode(row.context),api)
      if actual.settled~=true or actual.state=='unknown' then return true,{error='worker_followup_requires_report',effect='none'} end
    end
    local forwarded = json.decode(json.encode(args))
    forwarded.id=receipt.subagent_id
    forwarded.subagent_id=nil
    if row.destination=='local' then
      local latest=invoke('local',{action='lookup_session',conversation_id=receipt.session_id},json.decode(row.context),api)
      if type(latest)~='table' then return true,{error='native_session_lookup_invalid'} end
      if latest.error then return true,latest end
      if latest.found~=true or type(latest.task)~='table' or
          latest.task.session_id~=receipt.session_id or type(latest.task.subagent_id)~='string' or
          latest.task.subagent_id=='' then return true,{error='native_session_lookup_invalid'} end
      forwarded.id=latest.task.subagent_id
      -- Expected attempt/run identity remains on the forwarded request. Exact
      -- historical access uses the native id, not the conversation's dispatch alias.
    end
    local result=invoke(row.destination,forwarded,json.decode(row.context),api)
    if action == "status" or action == "result" or action == "await" or action == "cancel" then
      if result.subagent_id then
        if row.destination~='local' then
          if result.subagent_id~=receipt.subagent_id or result.session_id~=receipt.session_id or
              (result.attempt_id and receipt.attempt_id and result.attempt_id~=receipt.attempt_id) or
              type(result.state)~='string' or type(result.settled)~='boolean' then
            return true,{error='remote_observation_identity_invalid'}
          end
          local previous=recorded(row)
          if (previous.settled==true or previous.state=='unknown') and result.settled~=true and result.state~='unknown' then
            return true,{error='remote_observation_regression'}
          end
          observations()
          -- Bind to the exact admitted receipt; a concurrent message continuation
          -- changes that receipt and prevents this predecessor observation being reused.
          local saved=exec('INSERT INTO orchestration_observations(dispatch_id,source_receipt,observation) SELECT id,receipt,? FROM orchestration_tasks WHERE id=? AND owner=? AND destination=? AND receipt=? ON CONFLICT(dispatch_id) DO UPDATE SET source_receipt=excluded.source_receipt,observation=excluded.observation WHERE orchestration_observations.source_receipt<>excluded.source_receipt OR (COALESCE(json_extract(orchestration_observations.observation,\'$.settled\'),0)=0 AND COALESCE(json_extract(orchestration_observations.observation,\'$.state\'),\'\')<>\'unknown\') OR (json_extract(orchestration_observations.observation,\'$.state\')=json_extract(excluded.observation,\'$.state\') AND json_extract(orchestration_observations.observation,\'$.settled\')=json_extract(excluded.observation,\'$.settled\'))',
            {json.encode(result),id,ctx.user_id,row.destination,row.receipt})
          if saved.changes~=1 then return true,{error='remote_observation_superseded'} end
        end
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
  if action == "list" or action == "lookup_session" then
    if ctx.role ~= "master" or not nodes.is_master() then return false end
    local local_ctx = {}
    for k,v in pairs(ctx) do local_ctx[k]=v end
    local_ctx.remote=true
    local list=api.control(action=='lookup_session' and
      {action='lookup_session',conversation_id=args.conversation_id} or {action="list"},local_ctx)
    if list.error then return true,list end
    local native = action=='lookup_session' and (list.found and {list.task} or {}) or (list.subagents or {})
    local by_session={}
    for _,task in ipairs(native) do
      local old=by_session[task.session_id]
      if not old or (tonumber(task.created_at) or 0)>(tonumber(old.created_at) or 0) or task.after_id==old.subagent_id then
        by_session[task.session_id]=task
      end
    end
    local tasks, remote_ids = {}, {}
    local rows
    if action=='lookup_session' then
      rows=query("SELECT * FROM orchestration_tasks WHERE owner=? AND json_extract(receipt,'$.session_id')=? ORDER BY created_at DESC",
        {ctx.user_id,tostring(args.conversation_id or '')})
    else
      rows=query("SELECT * FROM orchestration_tasks WHERE owner=? ORDER BY created_at DESC",{ctx.user_id})
    end
    for _, row in ipairs(rows) do
      local receipt=recorded(row)
      if row.destination=='local' and by_session[receipt.session_id] then
        receipt=by_session[receipt.session_id]
        remote_ids[receipt.session_id]=true
      end
      if action=='list' or receipt.session_id==args.conversation_id then
        local request=json.decode(row.args)
        local parent=json.decode(row.context)
        local summary={subagent_id=row.id, remote_subagent_id=receipt.subagent_id,
          transport=receipt.transport or 'native',task_id=receipt.task_id or receipt.subagent_id,
          attempt_id=receipt.attempt_id or receipt.subagent_id,event_epoch=receipt.event_epoch,
          event_node_id=receipt.event_node_id,node_id=receipt.node_id,session_id=receipt.session_id,
          execution_node=row.destination,dispatch_state=row.state,state=receipt.state or row.state,
          settled=receipt.settled==true or row.state=='cancelled' or row.state=='failed' or row.state=='refused',
          profile=receipt.profile or request.profile,
          title=receipt.title or request.title or tostring(request.prompt or ''):gsub('%s+',' '):sub(1,100),
          parent_session_id=receipt.parent_session_id or parent.session_id,
          parent_run_id=receipt.parent_run_id or parent.run_id, after_id=receipt.after_id,
          model=receipt.model or request.model,reasoning=receipt.reasoning or request.reasoning,
          created_at=receipt.created_at or row.created_at,started_at=receipt.started_at,settled_at=receipt.settled_at,
          error=(type(receipt.error)=='string' and receipt.error~='' and receipt.error:sub(1,256) or nil) or discovery_error(row), freshness=row.destination=='local' and by_session[receipt.session_id] and
            'native_snapshot' or 'recorded_observation', stale=row.destination~='local'}
        tasks[#tasks+1]=summary
      end
    end
    for _, task in ipairs(native) do
      if not remote_ids[task.session_id] then task.execution_node="local"; tasks[#tasks+1]=task end
    end
    if action=='lookup_session' then
      table.sort(tasks,function(a,b) return (tonumber(a.created_at) or 0)>(tonumber(b.created_at) or 0) end)
      return true,{found=tasks[1]~=nil,task=tasks[1]}
    end
    return true,{subagents=tasks}
  end
  return false
end

return M
