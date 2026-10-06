-- Explicit external executor for the operator's exact risk-accepted backlog.
local json=dofile('lua/vendor/json.lua')
assert(host.getenv('WA_QUARANTINE_EXECUTOR')=='1' and host.getenv('WASM_AGENT_IN_TURN')~='1','external quarantine executor required')
local plan=json.decode(assert(host.read_file(assert(host.getenv('WA_QUARANTINE_PLAN')))))
local memory=dofile('lua/core/memory.lua');memory.setup()
local workspaces=dofile('lua/core/workspaces.lua')
local results={operations={},claims={},workspaces={}}
local function decoded(raw) local value=json.decode(raw);assert(not value.error and value.original_outcome=='unknown',json.encode(value));return value end
for _,item in ipairs(plan.operations or {}) do
 decoded(host.operation('quarantine_retire',json.encode({id=item.id,expected_state_json=item.expected_json,authorization_sha256=plan.authorization_sha256})))
 results.operations[#results.operations+1]=item.id
end
for _,item in ipairs(plan.claims or {}) do
 decoded(host.resource('quarantine_retire',json.encode({key=item.key,run=item.run,principal=item.principal,expected_claim_json=item.expected_json,authorization_sha256=plan.authorization_sha256})))
 results.claims[#results.claims+1]=item.key
end
for _,item in ipairs(plan.workspaces or {}) do
 local value,why=workspaces.quarantine_park(memory,item.session_id,item.principal,plan.authorization_sha256)
 assert(value and value.state=='parked',tostring(why));results.workspaces[#results.workspaces+1]=item.session_id
end
print(json.encode({ok=true,results=results,original_outcome='unknown',risk_accepted=true,never_replay=true,drain_proven=false}))
