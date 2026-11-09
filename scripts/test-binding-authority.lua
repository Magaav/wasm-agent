-- A changed service operator list must not detach a healthy binding (measured 2026-11-09: appending one
-- administrator to WASM_AGENT_NETWORK_ADMINS took work, mail and nextcloud off the directory for hours,
-- the third occurrence of this class). The tick records the change instead of stopping; admission still
-- refuses a pinned operator the service no longer vouches for. Deterministic HTTP, real native CAS.
local json=dofile('lua/vendor/json.lua')
local binding=dofile('lua/core/binding.lua')
local checks=0
local function ok(value,label) checks=checks+1;assert(value,label) end
local id=json.decode(host.node_identity())
local service='http://127.0.0.1:12345'
local now=math.floor(host.now())
local function operator(digit,key) return {node_id=string.rep(digit,32),public_key=string.rep(key,64)} end
local first,second,third=operator('1','a'),operator('2','b'),operator('3','c')
local request={schema=1,id=host.uuid():gsub('-',''),code='0123456789ab',node_id=id.node_id,public_key=id.public_key,
  name='probe',service=service,operators={first,second},scope='user-account-tools',expires_at=now+86400,pairing_expires_at=now+600}
local raw=json.encode(request)
local state={schema=1,request=request,raw_request=raw,digest=host.sha256(raw),service=service,operators={first,second},
  expires_at=request.expires_at,active=true,consent=true,phase='accepted',network_role='guest'}
ok(json.decode(host.binding_state('cas',json.encode({state=state}))).ok,'private binding state installed')
local mode={operators={first,second}}
host.http=function(method,url,headers,body)
  if url:match('/service$') then
    if mode.down then return json.encode({status=503,body=json.encode({error='unavailable'})}) end
    return json.encode({status=200,body=json.encode({protocol=1,binding_protocol=1,enrollment_ready=true,operators=mode.operators})})
  end
  local value
  if url:find('/bindings/request?',1,true) then value={ok=true,binding={digest=state.digest,request=request,state='accepted',revision=2}}
  elseif url:find('/register',1,true) then value={ok=true}
  elseif url:find('/relay/poll',1,true) then value={}
  elseif url:find('/lookup?',1,true) then value={public_key=id.public_key,role='guest',online=true,relay_attached=true}
  else error('unexpected request '..url) end
  return json.encode({status=200,body=json.encode(value)})
end
-- 1. The same set in another order is the same authority.
mode.operators={second,first}
local tick=binding.tick()
ok(tick.state=='attached' and tick.authority=='same','a reordered operator list still attaches')
-- 2. An added operator is reported, not fatal. This is the regression that took the fleet offline.
mode.operators={first,second,third}
tick=binding.tick()
ok(tick.state=='attached','an added operator no longer detaches the node (2026-11-09 regression)')
ok(tick.authority=='added','the growth is named on the tick result')
ok(json.encode(tick.authority_gained)==json.encode({third.node_id}),'the newly vouched operator is named exactly')
local status=binding.status()
ok(status.authority and status.authority.relation=='added' and status.authority.vouched==3 and status.authority.consented==2,
  'status reports vouched vs consented operators')
ok(status.attachment_note and status.attachment_note:find('did not consent',1,true)~=nil,'status explains the growth in words')
ok(binding.authorize(first.node_id,first.public_key)~=nil,'a consented operator is still admitted')
ok(binding.authorize(second.node_id,second.public_key)~=nil,'every consented operator is still admitted')
ok(binding.authorize(third.node_id,third.public_key)==nil,'an operator added after consent is not admitted by the pins')
-- 3. A pinned operator that loses the service's vouch is refused at admission, and the node stays reachable.
mode.operators={first}
tick=binding.tick()
ok(tick.state=='attached','a lost vouch does not detach the node from the directory')
ok(tick.authority=='removed' and json.encode(tick.authority_lost)==json.encode({second.node_id}),'the lost operator is named exactly')
ok(binding.authorize(second.node_id,second.public_key)==nil,'a pinned operator without a vouch is refused at admission')
ok(binding.authorize(first.node_id,first.public_key)~=nil,'the operator that is still vouched for keeps working')
status=binding.status()
ok(status.authority.relation=='removed' and status.attachment_note:find('no longer vouched',1,true)~=nil,'status explains the loss in words')
-- 4. A simultaneous loss and gain is `changed`, and admits nobody new.
mode.operators={first,third}
tick=binding.tick()
ok(tick.authority=='changed','a simultaneous loss and gain is reported as changed')
ok(binding.authorize(second.node_id,second.public_key)==nil,'the lost operator is still refused')
ok(binding.authorize(third.node_id,third.public_key)==nil,'the gained operator is not admitted by the pins')
-- 5. A new consent still refuses a changed operator list: the preview an operator approved must be the set.
local preview={ok=true,service=service,operators={first,second},lifetimes={'standard'}}
local refused=binding.begin(preview,'BIND')
ok(refused.error=='binding_operator_pins_changed','a fresh consent still refuses a changed operator list')
-- 6. An unreadable service is its own named failure, never an authority change.
mode.down=true
local failed=binding.tick()
ok(failed.error=='binding_service_unavailable','an unreadable service is named unavailable, not an authority change')
mode.down=false
ok(binding.tick().state=='attached','the binding attaches again once the service answers')
print('binding authority ok ('..checks..' checks, 0 skipped)')
