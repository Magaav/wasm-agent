-- Two-sided binding controller. No provider, shell, credentials or conversation changes.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local M={DEFAULT_SERVICE='https://rendezvous.colmeio.com'}
local function decode(raw) local ok,v=pcall(json.decode,raw or '');if not ok or type(v)~='table' then return nil,'binding_reply_invalid' end;return v end
function M.present()
  if not host.binding_state then return host.read_file(paths.config()..'/binding.json')~=nil end
  local v=decode(host.binding_state('read','{}'));return not v or not v.ok or v.state~=nil
end
function M.saved()
  if not host.binding_state then return nil,'binding_host_upgrade_required' end
  local v=decode(host.binding_state('read','{}'));if not v or not v.ok then return nil,v and v.error or 'binding_state_unavailable' end
  if v.state==nil then return nil end
  local s=v.state
  if type(s)~='table' or s.schema~=1 or type(s.request)~='table' or type(s.raw_request)~='string' or type(s.service)~='string' or type(s.operators)~='table'
      or type(s.expires_at)~='number' or type(s.consent)~='boolean' or type(s.active)~='boolean'
      or type(s.phase)~='string' or (s.network_role~='master' and s.network_role~='guest')
      or s.digest~=host.sha256(s.raw_request) then return nil,'binding_state_invalid' end
  local original=decode(s.raw_request);local i=decode(host.node_identity())
  if not original or json.encode(original)~=json.encode(s.request) or s.request.node_id~=i.node_id or s.request.public_key~=i.public_key
      or s.request.service~=s.service or s.request.expires_at~=s.expires_at or json.encode(s.request.operators)~=json.encode(s.operators) then return nil,'binding_state_identity_invalid' end
  return s
end
local function cas(old,new)
  local v=decode(host.binding_state('cas',json.encode({expected=old,state=new})))
  if not v or not v.ok then return nil,v and v.error or 'binding_state_write_failed' end;return v.state
end
local function failure(step,detail) return {ok=false,error=step,detail=detail} end
local function url(service)
  if type(service)~='string' or #service>2048 or service:find('[%s?#]') then return nil,'binding_service_invalid' end
  local scheme,authority=service:match('^(https?)://([^/]+)/?$')
  if not scheme or authority:find('@',1,true) then return nil,'binding_service_origin_required' end
  if scheme~='https' and not authority:match('^127%.0%.0%.1:%d+$') then return nil,'binding_requires_https' end
  return scheme..'://'..authority
end
local function identity() return decode(host.node_identity()) end
local function signed(action,body)
  local i=identity();local ts=tostring(math.floor(host.now()))
  local message=action..'|'..i.node_id..'|'..ts..(body and ('|'..host.sha256(body)) or '')
  local sig=decode(host.sign(message))
  return {['Content-Type']='application/json',['x-wa-node']=i.node_id,['x-wa-pub']=i.public_key,['x-wa-ts']=ts,['x-wa-sig']=sig.signature}
end
local function http(service,method,path,action,payload)
  local body=type(payload)=='string' and payload or payload and json.encode(payload) or ''
  local raw=host.http(method,service..path,json.encode(action and signed(action,action~='relay-respond' and payload and body or nil) or {}),body)
  local r=decode(raw);if not r then return nil,'binding_http_unreadable' end
  local v=decode(r.body);if tonumber(r.status)~=200 then return nil,'binding_http_'..tostring(r.status)..':'..tostring(v and v.error or r.error or r.body) end
  if not v then return nil,'binding_reply_invalid' end;return v
end
function M.inspect(service)
  local origin,problem=url(service or M.DEFAULT_SERVICE);if not origin then return failure(problem) end
  local v,err=http(origin,'GET','/service');if not v then return failure('binding_service_unavailable',err) end
  if v.protocol~=1 or v.binding_protocol~=1 or v.enrollment_ready~=true or type(v.operators)~='table' or #v.operators==0 or #v.operators>32 then return failure('binding_service_protocol_unsupported') end
  local seen={};local pins={}
  for _,pin in ipairs(v.operators) do
    if type(pin.node_id)~='string' or not pin.node_id:match('^%x+$') or #pin.node_id~=32 or type(pin.public_key)~='string' or #pin.public_key~=64 or not pin.public_key:match('^%x+$') or seen[pin.node_id] then return failure('binding_operator_pins_invalid') end
    -- host SHA takes text, not decoded key bytes; key-derived IDs are validated by the registry.
    seen[pin.node_id]=true;pins[#pins+1]={node_id=pin.node_id,public_key=pin.public_key}
  end
  table.sort(pins,function(a,b)return a.node_id<b.node_id end)
  return {ok=true,service=origin,operators=pins,identity=identity(),scope='user-account-tools',hours=24}
end
local function same_pins(a,b)
  if type(a)~='table' or type(b)~='table' or #a~=#b then return false end
  for i,p in ipairs(a) do if p.node_id~=b[i].node_id or p.public_key~=b[i].public_key then return false end end
  return true
end
function M.begin(preview,consent,renew)
  if consent~='BIND' then return failure('binding_consent_required') end
  if host.getenv('WASM_AGENT_MANAGED')=='1' and not M.present() then return failure('binding_existing_managed_enrollment_preserved') end
  if not preview or not preview.ok then return failure('binding_preview_required') end
  local fresh=M.inspect(preview.service);if not fresh.ok then return fresh end
  if not same_pins(fresh.operators,preview.operators) then return failure('binding_operator_pins_changed') end
  local old,err=M.saved();if err then return failure(err) end
  if old and (old.consent or old.active or old.phase=='submitting' or old.phase=='unknown') and not renew then return failure('binding_existing_request_inspect_first') end
  if renew and old then
    if old.service~=fresh.service or not same_pins(old.operators,fresh.operators) then return failure('binding_renew_pins_changed') end
    local revoked=M.unbind();if not revoked.ok then return revoked end;old=M.saved()
  end
  local preflight=decode(host.binding_transport('preflight'));if not preflight or not preflight.ok then return failure('binding_attachment_preflight_refused',preflight and preflight.error) end
  local now=math.floor(host.now());local i=identity();local id=host.uuid():gsub('-','');local code=host.uuid():gsub('-',''):sub(1,12)
  local name=host.read_file(paths.config()..'/node.name') or host.getenv('WASM_AGENT_NODE_NAME') or 'bound-node'
  name=name:gsub('^%s+',''):gsub('%s+$','')
  local request={schema=1,id=id,node_id=i.node_id,public_key=i.public_key,code=code,name=name,service=fresh.service,operators=fresh.operators,scope='user-account-tools',expires_at=now+86400,pairing_expires_at=now+600}
  local raw_request=json.encode(request)
  local s={schema=1,request=request,raw_request=raw_request,digest=host.sha256(raw_request),active=false,consent=true,phase='submitting',network_role='guest',operators=fresh.operators,service=fresh.service,expires_at=request.expires_at}
  local written,why=cas(old,s);if not written then return failure(why) end
  local result,problem=http(s.service,'POST','/bindings/request','bind-request',raw_request)
  if not result then s.phase='unknown';s.error=problem;local kept,save_error=cas(written,s);return failure('binding_submission_unknown',save_error or problem) end
  if type(result.binding)~='table' or result.binding.digest~=s.digest or type(result.binding.request)~='table' or result.binding.request.id~=id then s.phase='unknown';local kept,save_error=cas(written,s);return failure('binding_response_identity_mismatch',save_error) end
  s.phase='pending';s.revision=result.binding.revision;s.error=nil
  local saved,save_error=cas(written,s);if not saved then return failure(save_error) end
  local transport=decode(host.binding_transport('start'));if not transport or not transport.ok then return failure('binding_transport_unavailable',transport and transport.error) end
  return {ok=true,state='pending',node_id=i.node_id,code=code,phrase=code:sub(1,4)..'-'..code:sub(5,8)..'-'..code:sub(9,12),pairing_expires_at=request.pairing_expires_at,expires_at=request.expires_at}
end
local function request_status(s) return http(s.service,'GET','/bindings/request?id='..s.request.id,'bind-status') end
local function valid_reply(s,v)
  return v and v.ok==true and type(v.binding)=='table' and type(v.binding.request)=='table' and v.binding.digest==s.digest and v.binding.request.id==s.request.id and v.binding.request.node_id==s.request.node_id and v.binding.request.public_key==s.request.public_key
end
function M.status()
  local s,problem=M.saved();if not s then return {ok=false,active=false,error=problem or 'not_bound'} end
  local v,err=request_status(s);if not v then return {ok=false,active=false,error='binding_status_unavailable',detail=err} end
  if not valid_reply(s,v) then return {ok=false,active=false,error='binding_response_identity_mismatch'} end
  local transport=decode(host.binding_transport('status')) or {}
  local own,lookup_error=http(s.service,'GET','/lookup?node_id='..s.request.node_id,'lookup')
  local registered=own and own.public_key==s.request.public_key and own.online==true or false
  local active=s.active==true and s.consent==true and s.expires_at>host.now() and v.binding.state=='accepted'
  return {ok=true,state=v.binding.state,active=active,registered=registered,attached=registered and own.relay_attached==true or false,lookup_error=lookup_error,local_role_preserved=true,network_role=s.network_role,node_id=s.request.node_id,code=s.request.code,expires_at=s.expires_at,transport=transport}
end
function M.profile(include_inactive)
  local s,err=M.saved();if not s then return nil,err or 'not_bound' end
  if not include_inactive and (not s.active or not s.consent or s.phase~='accepted' or s.expires_at<=host.now()) then return nil,'binding_inactive_or_expired' end
  return s
end
function M.authorize(id,key)
  local s=M.profile();if not s then return nil end
  local pinned=false;for _,p in ipairs(s.operators) do if p.node_id==id and p.public_key==key then pinned=true end end
  if not pinned then return nil end
  local service=M.inspect(s.service);if not service.ok or not same_pins(service.operators,s.operators) then return nil end
  local v=request_status(s);if not valid_reply(s,v) or v.binding.state~='accepted' or v.binding.request.expires_at<=host.now() then return nil end
  return {node_id=id,public_key=key,role='master',name=id}
end
function M.unbind()
  local s,err=M.saved();if not s then return failure(err or 'not_bound') end
  local next={};for k,v in pairs(s) do next[k]=v end;next.active=false;next.consent=false;next.phase='revoked'
  local saved,why=cas(s,next);if not saved then return failure(why) end
  local v,problem=request_status(s);if not v or not valid_reply(s,v) then return {ok=false,local_revoked=true,error='binding_registry_revoke_unconfirmed',detail=problem} end
  if v.binding.state=='revoked' or v.binding.state=='expired' then return {ok=true,local_revoked=true,state=v.binding.state} end
  local r=v.binding;local body={id=s.request.id,node_id=s.request.node_id,public_key=s.request.public_key,digest=s.digest,revision=r.revision}
  local result,why=http(s.service,'POST','/bindings/revoke','bind-revoke',body)
  return result and {ok=true,local_revoked=true,state='revoked'} or {ok=false,local_revoked=true,error='binding_registry_revoke_unconfirmed',detail=why}
end
function M.pending()
  local nodes=dofile('lua/core/nodes.lua');local service=nodes.rendezvous_url();local checked=M.inspect(service)
  if not checked.ok then return checked end
  local v,err=http(service,'GET','/bindings/pending','bind-pending');return v or failure('binding_pending_unavailable',err)
end
function M.accept_preview(code)
  local v=M.pending();if not v.ok then return v end
  if v.truncated then return failure('binding_pending_inventory_incomplete') end
  local found;for _,r in ipairs(v.bindings) do if r.request.code==code then if found then return failure('binding_code_ambiguous') end;found=r end end
  if not found then return failure('binding_code_unknown') end
  return {ok=true,service=dofile('lua/core/nodes.lua').rendezvous_url(),binding=found}
end
function M.accept(preview,confirmation)
  if confirmation~='ACCEPT' or not preview or not preview.ok then return failure('binding_accept_confirmation_required') end
  local b=preview.binding;local r=b.request
  local v,err=http(preview.service,'POST','/bindings/accept','bind-accept',{id=r.id,node_id=r.node_id,public_key=r.public_key,code=r.code,digest=b.digest,revision=b.revision})
  return v or failure('binding_accept_outcome_unconfirmed',err)
end
function M.target(selector)
  local nodes=dofile('lua/core/nodes.lua');local matches={}
  for _,n in ipairs(nodes.peers({fresh=true})) do if n.node_id==selector or n.name==selector then matches[#matches+1]=n end end
  if #matches~=1 then return failure(#matches==0 and 'binding_node_unknown' or 'binding_node_name_ambiguous') end
  local n=matches[1];local service=nodes.rendezvous_url()
  local v,err=http(service,'GET','/lookup?node_id='..n.node_id,'lookup');if not v then return failure('binding_node_lookup_failed',err) end
  if v.public_key~=n.public_key or type(v.binding)~='table' or v.binding.state~='accepted' then return failure('binding_target_not_accepted') end
  return {ok=true,service=service,node=v,binding=v.binding}
end
function M.role(preview,role,confirmation)
  if not preview or not preview.ok or confirmation~=(role=='master' and 'PROMOTE' or 'DEMOTE') then return failure('binding_role_confirmation_required') end
  return dofile('lua/core/nodes.lua').network_role(preview.node.node_id,role,preview)
end
function M.revoke(preview,confirmation)
  if not preview or not preview.ok or confirmation~='REVOKE' then return failure('binding_revoke_confirmation_required') end
  local b=preview.binding;local r=b.request
  local v,err=http(preview.service,'POST','/bindings/revoke','bind-revoke',{id=r.id,node_id=r.node_id,public_key=r.public_key,digest=b.digest,revision=b.revision})
  return v or failure('binding_revoke_outcome_unconfirmed',err)
end
function M.set_role(role)
  local s,err=M.profile();if not s then return failure(err) end
  local v,problem=http(s.service,'GET','/lookup?node_id='..s.request.node_id,'lookup')
  if not v or v.public_key~=s.request.public_key or v.role~=role or not v.binding or v.binding.digest~=s.digest or v.binding.state~='accepted' then return failure('network_role_not_granted',problem) end
  local next={};for k,x in pairs(s) do next[k]=x end;next.network_role=role
  local result,why=cas(s,next);return result and {ok=true,role=role,node_id=s.request.node_id,local_role_preserved=true} or failure(why)
end
-- Runs only on the leased outbound runtime, never on the model or a scheduled job.
function M.tick()
  local s,problem=M.saved();if not s then return failure(problem or 'not_bound') end
  if not s.consent or s.expires_at<=host.now() or s.phase=='revoked' then return {state='inactive'} end
  if s.phase~='accepted' then
    if s.request.pairing_expires_at<=host.now() then return {state='pairing_expired'} end
    local v,err=request_status(s);if not v then return failure('binding_status_unavailable',err) end
    if not valid_reply(s,v) then return failure('binding_response_identity_mismatch') end
    if v.binding.state=='accepted' then
      local checked=M.inspect(s.service);if not checked.ok or not same_pins(checked.operators,s.operators) then return failure('binding_service_authority_changed') end
      local next={};for k,x in pairs(s) do next[k]=x end;next.active=true;next.phase='accepted';next.revision=v.binding.revision
      s,problem=cas(s,next);if not s then return failure(problem) end
    elseif v.binding.state~='pending' then return {state=v.binding.state}
    elseif s.request.pairing_expires_at<=host.now() then return {state='pairing_expired'}
    else return {state='pending',code=s.request.code} end
  end
  local checked=M.inspect(s.service);if not checked.ok or not same_pins(checked.operators,s.operators) then return failure('binding_service_authority_changed') end
  local v,err=request_status(s);if not valid_reply(s,v) or v.binding.state~='accepted' then return failure('binding_approval_unavailable',err) end
  if not M.last_heartbeat or host.now()-M.last_heartbeat>=60 then
    local ts=math.floor(host.now());local i=identity();local sig=decode(host.sign(i.node_id..'|'..ts))
    local r,e=http(s.service,'POST','/register',nil,{node_id=i.node_id,public_key=i.public_key,name=s.request.name,role=s.network_role,endpoints={},ts=ts,signature=sig.signature})
    if not r then return failure('binding_registration_failed',e) end;M.last_heartbeat=host.now()
  end
  local response,why=http(s.service,'GET','/relay/poll?node_id='..s.request.node_id,'relay-poll')
  if not response then return failure('binding_relay_unavailable',why) end
  if response.request then
    local r=response.request;local body,status='{"error":"binding_route_not_granted"}',403
    if r.method=='POST' and r.path=='/node/call' then
      local h={};for k,value in pairs(r.headers or {}) do if type(k)=='string' then h[k:lower()]=value end end
      body=wa_node_call(r.body or '',h['x-wa-node'] or '',h['x-wa-pub'] or '',h['x-wa-ts'] or '',h['x-wa-sig'] or '');status=200
    end
    local sent,e=http(s.service,'POST','/relay/respond','relay-respond',{node_id=s.request.node_id,id=r.id,status=status,body=body})
    if not sent then return failure('binding_response_submission_unknown',e) end
  end
  return {state='attached',registered=true,attached=true,node_id=s.request.node_id}
end
return M
