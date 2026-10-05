-- Focused binding recovery/controller checks with the real native CAS and deterministic HTTP.
local json=dofile('lua/vendor/json.lua')
local binding=dofile('lua/core/binding.lua')
local cli=dofile('lua/core/binding_cli.lua')
local checks=0
local function ok(v,label) checks=checks+1;assert(v,label) end
local id=json.decode(host.node_identity())
local pin={node_id=id.node_id,public_key=id.public_key}
local service='http://127.0.0.1:12345'
local now=math.floor(host.now())
local request={schema=1,id=host.uuid():gsub('-',''),code='0123456789ab',node_id=id.node_id,public_key=id.public_key,name='private',service=service,operators={pin},scope='user-account-tools',expires_at=now+86400,pairing_expires_at=now+600}
local raw=json.encode(request)
local original={schema=1,request=request,raw_request=raw,digest=host.sha256(raw),service=service,operators={pin},expires_at=request.expires_at,active=false,consent=true,phase='unknown',network_role='guest'}
ok(json.decode(host.binding_state('cas',json.encode({state=original}))).ok,'native first CAS')
ok(not json.decode(host.binding_state('cas',json.encode({state=original}))).ok,'stale CAS cannot overwrite')
local calls,mode=0,'accepted'
host.http=function(method,url,headers,body)
  calls=calls+1
  local value
  if url:match('/service$') then value={protocol=1,binding_protocol=1,enrollment_ready=true,operators={pin}}
  elseif url:find('/bindings/request?',1,true) then value={ok=true,binding={digest=original.digest,request=request,state=mode,revision=2}}
  elseif url:find('/register',1,true) then value={ok=true}
  elseif url:find('/relay/poll',1,true) then value={}
  elseif url:find('/lookup?',1,true) then value={public_key=id.public_key,role='guest',online=true,relay_attached=false}
  elseif url:find('/bindings/revoke',1,true) then return json.encode({error='deliberate unobserved network response'})
  else error('unexpected request '..url) end
  return json.encode({status=200,body=json.encode(value)})
end
-- Adopt exact prior unknown by observation; never POST the request again.
local tick=binding.tick();ok(tick.state=='attached','accepted unknown collected and attached')
local s=binding.saved();ok(s.phase=='accepted' and s.active,'observed approval persisted')
ok(binding.authorize(id.node_id,id.public_key)~=nil,'fresh exact approval authorizes pinned admin')
mode='revoked';ok(binding.authorize(id.node_id,id.public_key)==nil,'fresh registry revoke fences caller')
mode='accepted'
local status=binding.status();ok(status.active==true and status.attached==false,'saved active is not attachment success')
mode='pending';local revoked=binding.unbind();ok(revoked.local_revoked==true and revoked.ok==false,'unobserved network revoke reports partial')
ok(binding.saved().consent==false and binding.profile()==nil,'local revoke survives failed registry notification')
local snapshot=json.encode(binding.saved());local count=calls
local preview={ok=true,service=service,binding={request=request,digest=original.digest,revision=2}}
local refused=binding.accept(preview,'cancel');ok(refused.error=='binding_accept_confirmation_required' and calls==count,'cancel acceptance sends nothing')
ok(json.encode(binding.saved())==snapshot,'cancel retains exact state')
local bad=binding.inspect('http://127.0.0.1:12345/path');ok(not bad.ok,'service must be an origin not a path')
local pending={};for k,v in pairs(binding.saved()) do pending[k]=v end
pending.consent=true;pending.phase='pending';pending.active=false;pending.request.pairing_expires_at=1
pending.raw_request=json.encode(pending.request);pending.digest=host.sha256(pending.raw_request)
local old=binding.saved();ok(json.decode(host.binding_state('cas',json.encode({expected=old,state=pending}))).ok,'store private expired pairing')
local at=calls;ok(binding.tick().state=='pairing_expired' and calls==at,'expired pairing stops observation requests')
ok(select('#',host.binding_state('read','{}'))==1,'host state returns one value')
ok(select('#',host.binding_transport('status'))==1,'host transport returns one value')
print('binding runtime ok ('..checks..' checks, 0 skipped)')
