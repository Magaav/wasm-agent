-- Deterministic role/envelope contract; never call a provider.
host.http=function()error('network forbidden')end
local agent=dofile('lua/core/agent.lua')
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local function has(s,t)return s and s:gsub('%s+',' '):find(t:gsub('%s+',' '),1,true)end
local common={'Temporary operator evaluation contract','until the operator explicitly removes it','`evaluation:`','harness, graph and code mode','used/not-used/unknown','ALL relevant','exact tool/call/receipt','subjective judgements and untested hypotheses','No new findings is','unsuitable tool use','feedback-skill limits'}
local function contract(text)
 for _,s in ipairs(common)do if not has(text,s)then return false end end
 return true
end
local worker,wp=agent.role_instructions('subagents','master')
local owner,op=agent.role_instructions('orchestrator','master')
check(contract(worker),'worker evaluation contract')
check(contract(owner),'coordinator evaluation contract')
for _,s in ipairs({'Relay ALL original subagent feedback','with attribution','including criticism','preserve original evidence','never silently omit feedback','after settlement only','no active-subagent steering','automatic inference retry','runtime admission/acceptance gate','recursive','pre-delegation reasoning/checks','guest/WhatsApp/third-party'})do check(has(owner,s),'relay boundary '..s)end
for _,kind in ipairs({'subagents','orchestrator'})do check(agent.role_instructions(kind,'guest')==nil,'guest role isolation '..kind)end
local child=agent.subagent_system_prompt({role='master',subagent={id='orchestration-worker',allowed={read=true}}},{})
local main=agent.system_prompt('master','PROJECT_KEEP','AGENTS.md',{},'progressive')
local guest=agent.system_prompt('guest','GUEST_KEEP','AGENTS.guest.md',{},'full')
check(has(child,worker),'worker sees original contract')
check(has(main,owner),'coordinator sees original contract')
check(not has(child,'Relay ALL original subagent feedback'),'worker does not get coordinator contract')
check(not has(guest,'Temporary operator evaluation contract'),'guest envelope isolation')
check(has(guest,'GUEST_KEEP') and has(main,'PROJECT_KEEP'),'project scope retained')
for _,s in ipairs({'bounded child task','Do not deploy/publish installed UI or use Sentinel','integrate','approved profile'})do check(has(child,s),'child boundary '..s)end
for _,s in ipairs({'No subagents in direct mode','reason with context before native handoff','Followups wait for reports','never replay or falsely settle','Periodic watcher wakes remain disabled','self-review'})do check(has(main,s),'ordinary workflow '..s)end
-- The exact pre-amendment files are retained by the runner, not reconstructed approximations.
for _,kind in ipairs({'subagents','orchestrator'})do
 local old=assert(host.read_file(assert(host.getenv('WA_EVAL_OLD_'..kind:upper()))))
 check(not contract(old),'old contract negative control '..kind)
end
assert(host.write_file(assert(host.getenv('WA_EVAL_CAPTURE')),json.encode({ok=true,checks=checks,worker_path=wp,owner_path=op,worker=worker,owner=owner,child=child,main=main,guest=guest,provider_calls=0})))
print('evaluation feedback ok ('..checks..' checks, 0 skipped)')
