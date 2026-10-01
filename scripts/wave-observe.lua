local json=dofile('lua/vendor/json.lua')
local request=json.decode(assert(host.getenv('WA_WAVE_OBSERVATION')))
if request.kind=='operations' then
  print(host.operation('relevant',json.encode({cwd=request.cwd or '*',after=request.after or '',limit=256})))
elseif request.kind=='legacy' then
  print(host.operation('legacy_adjudicate',json.encode(request.bundle)))
elseif request.kind=='claims' then
  print(host.resource('list','{}'))
elseif request.kind=='claim_reconcile' then
  local expected=request.expected_claim
  assert(type(expected)=='table' and type(request.evidence)=='string' and request.evidence~='','exact claim and effect evidence required')
  local current=json.decode(host.resource('list','{}'));assert(current.ok==true,'claim inventory unavailable')
  local found
  for _,claim in ipairs(current.claims) do if claim.key==expected.key then found=claim end end
  assert(found,'claim missing')
  for _,field in ipairs({'key','principal','run','boot','session','uncertain'}) do assert(found[field]==expected[field],'claim owner or state moved') end
  local paths=dofile('lua/core/paths.lua')
  assert(host.canonical_path(paths.data()..'/resources/'..found.boot..'.lease.sqlite'),'original claim boot lease missing')
  print(host.resource('reconcile',json.encode({key=found.key,principal=found.principal,run=found.run,evidence=request.evidence})))
elseif request.kind=='registry' or request.kind=='retire' then
  local memory=dofile('lua/core/memory.lua')
  local workspaces=dofile('lua/core/workspaces.lua')
  local item=request.item
  local value,why
  if request.kind=='retire' and item.mode=='remove' then value,why=workspaces.release(memory,item.session_id,item.user_id,item.tip)
  elseif item.mode=='park' then value,why=workspaces.reconcile_park(memory,item.session_id,item.user_id,item.tip,item.evidence,request.kind=='retire')
  else value,why=workspaces.reconcile_release(memory,item.session_id,item.user_id,item.evidence) end
  print(json.encode({ok=value~=nil,workspace=value,error=why}))
else error('unknown external wave observation') end
