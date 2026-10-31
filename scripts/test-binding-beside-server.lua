-- Enrolling beside the node that owns the ledger (31/10): a sentinel-managed node runs `wa serve`, which
-- holds the outbound transport, and that used to refuse `wa bind` outright
-- (binding_attachment_preflight_refused <- binding_existing_server_owned) with no runtime in which the
-- operator could bind instead. Enrollment must be possible beside it: the transport lease still admits one
-- owner, so the CLI stands by and the node keeps attaching.
local json=dofile('lua/vendor/json.lua')
local binding=dofile('lua/core/binding.lua')
local id=json.decode(host.node_identity())
local pin={node_id=id.node_id,public_key=id.public_key}
local service='http://127.0.0.1:12431'
local preflight_error='binding_existing_server_owned; bind in its owner runtime or stop it explicitly'
local checks=0
local function check(v,label) assert(v,label); checks=checks+1 end

host.http=function(method,url,headers,body)
  local value
  if url:match('/service$') then
    value={protocol=1,binding_protocol=1,binding_lifetimes={'standard','permanent'},enrollment_ready=true,operators={pin}}
  elseif method=='POST' and url:match('/bindings/request$') then
    local posted=json.decode(body)
    value={ok=true,binding={digest=host.sha256(body),request=posted,state='pending',revision=1}}
  elseif method=='GET' and url:find('/bindings/request?',1,true) then
    local stored=json.decode(host.binding_state('read','{}')).state or {}
    value={ok=true,binding={digest=stored.digest,request=stored.request or {},state=stored.phase=='accepted' and 'accepted' or 'pending',revision=stored.revision or 1}}
  else error('unexpected request '..tostring(method)..' '..url) end
  return json.encode({status=200,body=json.encode(value)})
end
host.binding_transport=function(action)
  if action=='preflight' then return json.encode({ok=false,error=preflight_error}) end
  if action=='start' then return json.encode({ok=true,state='standby',owner='another process'}) end
  if action=='status' then return json.encode({state='standby',owner='another process'}) end
  return json.encode({ok=false,error='binding_transport_action_invalid'})
end

local preview=binding.inspect(service)
check(preview.ok,'the service inspects while a server owns the ledger')

-- Any other preflight failure is still fatal (a broken lease is not "a server owns it"), and it refuses
-- before anything is stored.
preflight_error='binding_database_identity_missing'
local refused=binding.begin(preview,'PERMANENT',nil,'permanent')
check(refused.error=='binding_attachment_preflight_refused' and binding.saved()==nil,'an unrelated preflight failure still refuses: '..json.encode(refused))

-- A running server of this ledger does not: the CLI submits, stands by, and the node keeps the transport.
preflight_error='binding_existing_server_owned; bind in its owner runtime or stop it explicitly'
local submitted=binding.begin(preview,'PERMANENT',nil,'permanent')
check(submitted.ok and submitted.state=='pending','a CLI submits enrollment beside the running node: '..json.encode(submitted))
check(submitted.attachment=='standby','the result says the running node keeps the transport: '..json.encode(submitted))
check(submitted.lifetime=='permanent' and submitted.code and #submitted.code==12 and submitted.phrase,'the permanent intent and its one-line phrase survive: '..json.encode(submitted))
local stored=json.decode(host.binding_state('read','{}')).state or {}
check(stored.phase=='pending' and stored.request and stored.request.lifetime=='permanent','the pending request was persisted: '..json.encode(stored.phase))
check(stored.request.node_id==pin.node_id and stored.request.public_key==pin.public_key,'the request is signed for this node only')

print(json.encode({ok=true,checks=checks}))
