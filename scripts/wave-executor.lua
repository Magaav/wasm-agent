-- Model-free external operation driver for wave-lifecycle. Run in a private
-- external wa process, never in the node turn or a tree being retired.
local json=dofile('lua/vendor/json.lua')
local id=assert(host.getenv('WA_WAVE_OPERATION_ID'),'wave operation identity required')
local wave=assert(host.getenv('WA_WAVE_ID'),'wave identity required')
local spec=json.decode(assert(host.getenv('WA_WAVE_COMMAND'),'native operation specification required'))
assert(type(spec)=='table' and spec.program and type(spec.args)=='table','native argv required')
assert(spec.cwd and spec.cwd~='','external executor cwd required')
spec.owner='wave:'..wave..':operation:'..id
local accepted=json.decode(host.operation('start',json.encode(spec)))
if not accepted.operation_id then print(json.encode({ok=false,error=accepted.error,operation_id=id,settled=false}));return end
local result=json.decode(host.operation('await',json.encode({id=accepted.operation_id,wait_for='settled'})))
print(json.encode({ok=result.ok==true,settled=result.settled==true,cleanup=result.cleanup,
  operation_id=id,native_operation_id=accepted.operation_id,owner=spec.owner,
  owner_boot=result.owner_boot,cwd=result.effective_cwd,code=result.code,error=result.error}))
