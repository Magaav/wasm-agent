-- Explicit external reconciliation, not an age-based sweep. The plan pins
-- session/principal/evidence for each already missing directory. No refs move.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local workspaces=dofile('lua/core/workspaces.lua')
local plan=json.decode(assert(host.read_file(assert(host.getenv('WA_WAVE_RECONCILE_PLAN')))))
assert(type(plan)=='table' and type(plan.sessions)=='table','exact session plan required')
local reconciled,blocked={},{}
for _,item in ipairs(plan.sessions) do
  local result,why=workspaces.reconcile_release(memory,item.session_id,item.user_id,item.evidence)
  if result and result.state=='released' then reconciled[#reconciled+1]=item.session_id
  else blocked[#blocked+1]={session_id=item.session_id,error=why} end
end
print(json.encode({ok=#blocked==0,reconciled=reconciled,blocked=blocked,
  note='Registry reconciliation only; no operation outcome or branch was rewritten.'}))
if #blocked>0 then error('workspace reconciliation blocked') end
