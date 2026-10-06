-- Private native fixture only: input contains actual archived unknown records.
local j=dofile('lua/vendor/json.lua')
local p=j.decode(assert(host.read_file(assert(host.getenv('WA_QUARANTINE_TEST_PLAN')))))
local function value(raw)return j.decode(raw)end
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local args={id=p.operation.id,expected_state_json=p.operation.expected_json,authorization_sha256=p.authorization_sha256}
check(value(host.operation('index',j.encode({evidence='private exact original fixture imported'}))).ok,'import fixture')
local before=value(host.operation('relevant',j.encode({cwd=p.cwd,limit=1})))
check(#before.operations==1,'unknown blocks before acceptance')
local saved=host.read_file(p.state_path)
local bad={id=args.id,expected_state_json=args.expected_state_json,authorization_sha256='wrong'}
check(value(host.operation('quarantine_retire',j.encode(bad))).error~=nil,'authorization movement refused')
local accepted=value(host.operation('quarantine_retire',j.encode(args)))
check(accepted.original_outcome=='unknown' and accepted.drain_proven==false,'unknown not settlement')
check(host.read_file(p.state_path)==saved,'original state retained')
local after=value(host.operation('relevant',j.encode({cwd=p.cwd,limit=1})))
check(#after.operations==0 and after.quarantined_unknown_outcomes==1,'risk reservation retired')
check(value(host.operation('quarantine_retire',j.encode(args))).original_outcome=='unknown','duplicate collects receipt')
local archive=host.read_file(p.archived_state);assert(host.write_file(p.archived_state,archive..' '))
check(#value(host.operation('relevant',j.encode({cwd=p.cwd,limit=1}))).operations==1,'moved archive restores blocker')
assert(host.write_file(p.archived_state,archive))
local claims=value(host.resource('list','{}')).claims
local target
for _,c in ipairs(claims)do if c.key==p.claim.key then target=c end end
check(target and target.uncertain,'exact legacy reservation present')
local retired=value(host.resource('quarantine_retire',j.encode({key=target.key,run=target.run,principal=target.principal,expected_claim_json=p.claim.expected_json,authorization_sha256=p.authorization_sha256})))
check(retired.original_outcome=='unknown','claim risk accepted separately')
for _,c in ipairs(value(host.resource('list','{}')).claims)do check(c.key~=target.key,'old execution reservation released') end
local old_claim_bytes=host.read_file(p.claim.archived_claim)
assert(host.write_file(p.claim.archived_claim,old_claim_bytes..' '))
check(value(host.resource('claim',j.encode({principal='fixture',session='old',run='new',keys={'session:old'}}))).error=='quarantine_claim_archive_unverifiable','changed retired-claim archive prevents reuse')
assert(host.write_file(p.claim.archived_claim,old_claim_bytes))
-- Hold a real native current-process claim: copied old receipt cannot authorize it.
local live={principal='fixture',session='live',run='live',keys={'session:live'}}
check(value(host.resource('claim',j.encode(live))).ok,'real live claim granted')
local current
for _,c in ipairs(value(host.resource('list','{}')).claims)do if c.key=='session:live' then current=c end end
check(value(host.resource('quarantine_retire',j.encode({key=current.key,run='live',principal='fixture',expected_claim_json=j.encode(current),authorization_sha256=p.authorization_sha256}))).error~=nil,'live reservation never risk retired')
check(value(host.resource('finish',j.encode(live))).ok,'private known live fixture closed')
local memory=dofile('lua/core/memory.lua');memory.setup()
local workspaces=dofile('lua/core/workspaces.lua')
local ws,why=workspaces.quarantine_park(memory,p.workspace.id,'fixture',p.authorization_sha256)
check(ws and ws.state=='parked',tostring(why))
check(ws.start_state.quarantined_retirement.original.branch==p.workspace.original_branch,'original binding retained')
check(ws.start_state.quarantined_retirement.original_outcome=='unknown','parking not original task success')
local removed,removal_reason=workspaces.release(memory,p.workspace.id,'fixture')
check(not removed and removal_reason=='quarantine_park_preserved_no_removal','quarantined source cannot be ordinarily deleted')
local ws2,why2=workspaces.quarantine_park(memory,p.workspace.id,'fixture',p.authorization_sha256)
check(ws2 and ws2.state=='parked',tostring(why2))
local binding_saved=host.read_file(p.workspace.archived_binding)
assert(host.write_file(p.workspace.archived_binding,binding_saved..' '))
local corrupt=workspaces.quarantine_park(memory,p.workspace.id,'fixture',p.authorization_sha256)
check(not corrupt,'parked archive movement remains visible on observation')
assert(host.write_file(p.workspace.archived_binding,binding_saved))
print('quarantined retirement native ok ('..checks..' checks, 0 skipped; private effects only)')
