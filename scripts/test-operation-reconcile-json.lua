-- Real Lua/host boundary proof, shared only by private owner/reconciler processes.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local root=assert(host.getenv('WA_RECONCILE_JSON_ROOT'))
local mode=assert(host.getenv('WA_RECONCILE_JSON_MODE'))
local checks=0
local function check(value,label) assert(value,label);checks=checks+1 end
if mode=='owner' then
  local launch=json.decode(host.operation('start',json.encode({
    command='printf raw-json-fixture',cwd=root,timeout_seconds=10,owner='private-json-owner'})))
  assert(launch.operation_id,'native launch failed')
  local settled=json.decode(host.operation('await',json.encode({id=launch.operation_id,wait_for='settled'})))
  assert(settled.settled==true and settled.ok==true,'private fixture did not settle')
  local file=paths.data()..'/operations/'..launch.operation_id..'/state.json'
  local raw=assert(host.read_file(file))
  assert(host.write_file(root..'/ready.json',json.encode({id=launch.operation_id,path=file,owner_boot=settled.owner_boot})))
  -- Keep this exact native manager's OS lease alive until the other process tests it.
  local until_at=host.monotonic_ms()+30000
  while not host.read_file(root..'/release') do
    assert(host.monotonic_ms()<until_at,'private owner release timed out')
    host.sleep(10)
  end
  print(json.encode({ok=true,mode=mode}))
  return
end
local metadata=json.decode(assert(host.read_file(root..'/ready.json')))
local raw=assert(host.read_file(metadata.path))
local decoded=json.decode(raw)
local function request()
  return {id=metadata.id,owner_boot=metadata.owner_boot,expected_state_json=raw,
    evidence='private real Lua/native raw JSON fixture',
    drain_evidence='fixture command fully settled before owner release',
    effect_evidence='printf only; original state/output retained, no replay'}
end
local function reconcile(args)
  return json.decode(host.operation('reconcile',json.encode(args)))
end
check(raw:find('"error":null',1,true)~=nil,'native state includes explicit null')
check(decoded.error==nil,'ordinary decoder keeps existing nil behavior')
local lossy=request();lossy.expected_state_json=nil;lossy.expected_state=decoded
check(reconcile(lossy).error=='operation_state_moved','lossy old form still fails exact-state comparison')
if mode=='live' then
  check(reconcile(request()).error=='operation_owner_live_or_unverifiable','raw form preserves the live-owner refusal')
elseif mode=='recover' then
  local invalid=request();invalid.expected_state_json='{'
  check(reconcile(invalid).error=='expected_state_json_invalid','malformed raw input refuses by name')
  for _,body in ipairs({'null','[]','false','1','"state"'}) do
    invalid.expected_state_json=body
    check(reconcile(invalid).error=='expected_state_json_object_required','raw state must be an object')
  end
  local both=request();both.expected_state=decoded
  check(reconcile(both).error=='expected_state_forms_exclusive','two expected-state forms refuse')
  local changed=request();changed.expected_state_json=raw:gsub('"error":null','"error":false',1)
  check(reconcile(changed).error=='operation_state_moved','real null-to-value change remains a refusal')
  local no_effect=request();no_effect.effect_evidence=''
  check(reconcile(no_effect).error=='effect_evidence_required','raw input never bypasses effect evidence')
  check(host.read_file(metadata.path)==raw,'refusals preserve exact original bytes')
  local result=reconcile(request())
  check(result.ok==true and result.reconciled==true,'one ordinary encoded raw-string request reconciles')
  check(result.execution_outcome=='unchanged' and result.original_preserved==true,'reconciliation never claims execution success')
  check(host.read_file(metadata.path)==raw,'successful recovery preserves original bytes')
  local relevant=json.decode(host.operation('relevant',json.encode({cwd=root,limit=1})))
  check(relevant.ok==true and #relevant.operations==0 and not relevant.truncated,'exact reconciliation removes only the proved blocker')
else error('unknown private mode') end
print(json.encode({ok=true,mode=mode,checks=checks,skipped=0}))
