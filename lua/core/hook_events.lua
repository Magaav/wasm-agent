-- Read-only inventory. This is neither an emitter nor an execution/approval registry.
local json=dofile('lua/vendor/json.lua')
local M={}
local function row(id,name,kind,producer,boundary,state,limit)
  return {id=id,name=name,kind=kind,producer=producer,boundary=boundary,state=state,
    reliability=limit,handlers={}}
end
function M.catalogue(jobs)
  if type(jobs)~='table' then return {error='hook_job_store_invalid'} end
  for key,value in pairs(jobs) do
    if type(key)~='number' or key%1~=0 or key<1 or key>#jobs or type(value)~='table' then return {error='hook_job_store_invalid'} end
  end
  local source_jobs={}
  for _,job in ipairs(jobs) do
    if type(job.id)=='string' then source_jobs[job.id]=job end
  end
  local function source_state(id)
    local job=source_jobs[id]
    if not job then return 'source job '..id..' is not configured' end
    return 'source job '..id..' '..(job.enabled==true and 'enabled' or 'disabled')..' (revision '..tostring(job.revision or 'unknown')..')'
  end
  local events={
    row('sentinel.return','Sentinel return','native event + jobs',
      'rust/wa-sentinel/src/sentinel_return.rs; native watcher observation',
      'request acknowledgement / held / updating / failed / unknown / verified',
      'source available; watcher liveness not measured here',
      'Durable request/event keys; ambiguous notification is never replayed. Delivery and installation verification are separate facts; a queued wake is not completion.'),
    row('subagent.return','Child return','event + jobs',
      'scripts/subagent-return-hook.mjs; subagent-return-observe source job',
      'settled child receipt: completed / refused / cancelled / failed / unknown',
      source_state('subagent-return-observe'),
      'Observation/prepare are deterministic; wake may invoke inference. Handler supersedes completion notice only while enabled; unknown effects remain unknown.'),
    row('child_completion','Native child completion','native callback',
      'lua/core/completions.lua; host internal completion scheduler',
      'owned child settlement/outbox evaluation',
      'native callback; may be superseded by an enabled completion_wake job',
      'Owner/parent scoped durable outbox; not a user-configurable event job. Delivery is not acceptance, deployment or task verification.'),
    row('patch_audit_before_reply','Patch audit before reply','opt-in pre-answer check',
      'lua/core/agent.lua; lua/core/patch_audit.lua',
      'completed no-tool candidate before final transcript commit',
      host.getenv('WA_GRAPH_PATCH_AUDIT')=='1' and 'enabled by WA_GRAPH_PATCH_AUDIT=1' or 'disabled; WA_GRAPH_PATCH_AUDIT is not 1',
      'May request another model step for unread callers. Static leads are not correctness; not a generic beforeFinalAnswer hook or worktree repair.'),
    row('final_answer_begin','Final answer begins','display telemetry',
      'lua/core/subscription_wire.lua; lua/core/openai_sub_bridge.lua',
      'explicit provider item phase, early on native Responses or late at Pi text_end',
      'provider-dependent; not universal',
      'May precede tools, steering, cancellation or failure. Text may already be shown. Does not authorize checks/effects or establish run settlement.'),
    row('reply','Final reply recorded','native run event',
      'lua/core/agent.lua; record_turn and self.emit(reply)',
      'accepted answer after loop and durable transcript write',
      'post-commit; not a before-answer barrier',
      'No reply on failed/cancelled calls; crashes may interrupt publication. Answered does not mean task verified.'),
    row('run_terminal','Run error / done','native stream events',
      'lua/core/server.lua; rust/wa-host/src/serve.rs',
      'run failure/cancellation or terminal stream completion',
      'terminal events; may be missed by a disconnected reader',
      'done marks stream completion, not task correctness. Crashed runs may have no terminal event; inspect the durable journal and never infer no effect from disconnection.'),
    row('beforeFinalAnswer','beforeFinalAnswer','evaluated / not implemented',
      'no registered producer or execution handler',
      'proposed completed-candidate barrier; not provider final phase',
      'not implemented; no event is emitted',
      'Reliable only with defined candidate identity, durable prepare/commit boundary, steering revalidation and unknown-effect handling. Cannot promise pre-stream timing or eventual final answer.'),
    row('git_lifecycle','Repository Git hooks','repository declaration',
      '.githooks/pre-commit; .githooks/commit-msg; .githooks/pre-push',
      'ordinary Git commit/message/push commands',
      'repository declarations; installed execution not measured',
      'LF/provenance/main-only guards. Client hooks are bypassable convenience; remote protection remains authoritative. Not Engine jobs.')
  }
  local by_topic={};for _,event in ipairs(events) do by_topic[event.id]=event end
  by_topic['sentinel.return'].source_job=source_state('sentinel-return-observe')..'; optional scheduled observer, native observation remains separate'
  for _,job in ipairs(jobs) do
    local trigger,action=job.trigger,job.action
    if type(trigger)~='table' or type(action)~='table' or type(job.id)~='string' then return {error='hook_job_definition_invalid'} end
    if trigger.kind=='event' then
      if type(trigger.topic)~='string' or trigger.topic=='' then return {error='hook_job_event_topic_invalid'} end
      local event=by_topic[trigger.topic]
      if not event then
        event=row(trigger.topic,trigger.topic,'configured event job','explicit event ingress / source-specific adapter',
          'trigger.topic matches current job revision','producer liveness not measured',
          'Revision/source-id dedupe; job approval does not authorize event data. Queue/unknown delivery is not execution success.')
        events[#events+1]=event;by_topic[trigger.topic]=event
      end
      local last
      if type(job.last_delivery)=='table' then last={state=job.last_delivery.state,detail=job.last_delivery.detail} end
      event.handlers[#event.handlers+1]={id=job.id,name=job.name or job.id,enabled=job.enabled==true,
        revision=job.revision,action=action.kind,queued=job.queued or 0,last_delivery=last}
    end
  end
  for _,event in ipairs(events) do
    table.sort(event.handlers,function(a,b)return a.id<b.id end)
    event.handler_count=#event.handlers
    local enabled=0;for _,handler in ipairs(event.handlers)do if handler.enabled then enabled=enabled+1 end end
    event.enabled_handlers=enabled
  end
  return {schema=1,read_only=true,events=events,returned=#events,
    note='Inventory, not execution authority. Source availability is not watcher liveness, delivered notification, verified task or installation. Existing jobs remain managed in Jobs.'}
end
function M.get()
  local ok,raw=pcall(host.jobs,'list','{}')
  if not ok then return {error='hook_job_store_unavailable',detail=tostring(raw)} end
  local decoded,value=pcall(json.decode,raw)
  if not decoded or type(value)~='table' then return {error='hook_job_store_invalid'} end
  if value.error then return {error='hook_job_store_unavailable',detail=value.error} end
  return M.catalogue(value.jobs)
end
return M
