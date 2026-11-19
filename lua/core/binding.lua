-- Two-sided binding controller. No provider, shell, credentials or conversation changes.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local M={}
-- No built-in fabric: a node joins the service its operator names, never one baked into the code.
-- The suggestion is the one this node already uses - its saved binding, else WASM_AGENT_RENDEZVOUS.
function M.default_service()
  local raw=host.binding_state and host.binding_state('read','{}')
  local ok,v=pcall(json.decode,raw or '')
  if ok and type(v)=='table' and type(v.state)=='table' and type(v.state.service)=='string' and v.state.service~='' then return v.state.service end
  local env=host.getenv and host.getenv('WASM_AGENT_RENDEZVOUS') or ''
  return env or ''
end
-- Lifetime intent. 'standard' is the ordinary 24-hour consent and stays the default for every node;
-- 'permanent' is the operator's explicit no-expiry choice for his own node and the only intent allowed
-- to exceed 86400. The node asks for fifty years and the registry accepts at most a hundred
-- (rust/wa-host/src/rendezvous/bindings.rs), so an honest request cannot be refused by ordinary clock
-- skew and the stored value stays finite. Neither intent grants anything on its own: a registry
-- administrator must affirm the exact intent at acceptance, and `lifetime` is carried inside the
-- signed request, so no flag here can talk the registry into a longer grant.
local STANDARD_CONSENT_SECONDS=86400
local PERMANENT_CONSENT_SECONDS=50*365*24*3600
local function lifetime_of(t)
  if type(t)~='table' then return 'standard' end
  local v=t.lifetime
  if v==nil and type(t.request)=='table' then v=t.request.lifetime end
  return v=='permanent' and 'permanent' or 'standard'
end
local function lifetime_valid(t)
  if type(t)~='table' then return false end
  return t.lifetime==nil or t.lifetime=='standard' or t.lifetime=='permanent'
end
local function service_supports(lifetimes,name)
  if name=='standard' then return true end
  if type(lifetimes)~='table' then return false end
  for _,v in ipairs(lifetimes) do if v==name then return true end end
  return false
end
function M.lifetime_of(t) return lifetime_of(t) end
-- One wording for both status and the CLI's consent line: a permanent grant says so in words, never as
-- a very large timestamp and never as an empty field.
function M.lifetime_label(t)
  if lifetime_of(t)=='permanent' then return 'no expiry (permanent binding; revoke to end it)' end
  local at=type(t)=='table' and (t.expires_at or (type(t.request)=='table' and t.request.expires_at)) or nil
  return 'expires '..tostring(at)..' (24-hour standard consent)'
end
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
  -- The intent lives in the signed request body; a state file naming a lifetime the body does not is
  -- corrupt and refuses rather than being read as either.
  if not lifetime_valid(s.request) then return nil,'binding_state_lifetime_invalid' end
  local original=decode(s.raw_request);local i=decode(host.node_identity())
  if not original or json.encode(original)~=json.encode(s.request) or s.request.node_id~=i.node_id or s.request.public_key~=i.public_key
      or s.request.service~=s.service or s.request.expires_at~=s.expires_at or json.encode(s.request.operators)~=json.encode(s.operators) then return nil,'binding_state_identity_invalid' end
  return s
end
local function cas(old,new)
  local v=decode(host.binding_state('cas',json.encode({expected=old,state=new})))
  if not v or not v.ok then return nil,v and v.error or 'binding_state_write_failed' end;return v.state
end

-- ---- the fleet roster as this node's admission (docs/MESH.md §§5-6) ---------------------------
--
-- A node whose own `policy.json` carries a verified fleet roster (`mesh.roster_key` + the signed
-- roster, with `mesh.enabled` or `WA_MESH=1`) decides a peer call by the roster's hierarchy and its
-- grants, not by the operator pins its binding froze at bind time. The decision is the host's
-- (`rust/wa-mesh/src/admission.rs`), because the same function admits a relayed call, a direct one
-- and the node's own listener; what arrives here is that decision, for exactly one call.
--
-- The handshake is one-shot and lives in the interpreter's global table, because `dofile` re-executes
-- a module in this tree: the host sets the admission immediately before it calls `wa_node_call`, the
-- admission is read by `M.authorize`, stays *in force* while that one call executes (so the author
-- attribution sees the same caller), and the host clears it when the call returns. It is not a
-- permission: it records that this node's own signed roster already said yes to this caller for this
-- capability. The minute bound is the backstop if a holder ever forgot to clear it.
local MESH_ADMISSION='_WA_MESH_ADMISSION'

local function mesh_pending()
  local a=rawget(_G,MESH_ADMISSION)
  if type(a)~='table' then return nil end
  if not tonumber(a.at) or host.now()-(tonumber(a.at) or 0)>60 then rawset(_G,MESH_ADMISSION,nil);return nil end
  return a
end

-- The pending admission when it names this caller and this key, marked in force for the call.
local function mesh_take(id,key)
  local a=mesh_pending();if not a then return nil end
  if id~=nil and (a.node_id~=id or a.public_key~=key) then return nil end
  a.in_force=true
  return a
end

-- Set by the host, immediately before it runs one roster-authorized call (`serve.rs`, `M.tick`).
function wa_mesh_admit(payload)
  local ok,value=pcall(json.decode,payload or '')
  if not ok or type(value)~='table' or type(value.node_id)~='string' or #value.node_id~=32
      or type(value.public_key)~='string' or #value.public_key~=64 then
    return json.encode({ok=false,error='mesh_admission_invalid'})
  end
  rawset(_G,MESH_ADMISSION,{node_id=value.node_id,public_key=value.public_key,
    capability=tostring(value.capability or ''),request_id=tostring(value.request_id or ''),
    name=tostring(value.name or ''),level=tonumber(value.level),at=host.now(),in_force=false})
  return json.encode({ok=true})
end

function wa_mesh_clear()
  rawset(_G,MESH_ADMISSION,nil)
  return json.encode({ok=true})
end

-- Is a roster admission in force right now? (Read by a caller that wants to say *why* it admitted.)
function M.mesh_in_force()
  local a=mesh_pending()
  return (a and a.in_force==true) and a or nil
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
  if not service or service=='' then return failure('binding_service_required') end
  local origin,problem=url(service);if not origin then return failure(problem) end
  local v,err=http(origin,'GET','/service');if not v then return failure('binding_service_unavailable',err) end
  if v.protocol~=1 or v.binding_protocol~=1 or v.enrollment_ready~=true or type(v.operators)~='table' or #v.operators==0 or #v.operators>32 then return failure('binding_service_protocol_unsupported') end
  -- Lifetime discovery: an older registry advertises nothing and therefore gets standard only, so a
  -- permanent intent refuses locally with a named reason instead of failing as a raw 400 after local
  -- consent has already been stored.
  local lifetimes={'standard'}
  if v.binding_lifetimes~=nil then
    if type(v.binding_lifetimes)~='table' or #v.binding_lifetimes<1 or #v.binding_lifetimes>2 then return failure('binding_service_protocol_unsupported') end
    local advertised={}
    for _,name in ipairs(v.binding_lifetimes) do
      if (name~='standard' and name~='permanent') or advertised[name] then return failure('binding_service_protocol_unsupported') end
      advertised[name]=true
    end
    if not advertised['standard'] then return failure('binding_service_protocol_unsupported') end
    lifetimes={'standard'}
    if advertised['permanent'] then lifetimes[#lifetimes+1]='permanent' end
  end
  local seen={};local pins={}
  for _,pin in ipairs(v.operators) do
    if type(pin.node_id)~='string' or not pin.node_id:match('^%x+$') or #pin.node_id~=32 or type(pin.public_key)~='string' or #pin.public_key~=64 or not pin.public_key:match('^%x+$') or seen[pin.node_id] then return failure('binding_operator_pins_invalid') end
    -- host SHA takes text, not decoded key bytes; key-derived IDs are validated by the registry.
    seen[pin.node_id]=true;pins[#pins+1]={node_id=pin.node_id,public_key=pin.public_key}
  end
  table.sort(pins,function(a,b)return a.node_id<b.node_id end)
  return {ok=true,service=origin,operators=pins,identity=identity(),scope='user-account-tools',hours=24,lifetimes=lifetimes}
end
local function pin_set(pins)
  local set={}
  for _,p in ipairs(pins or {}) do
    if type(p)=='table' and type(p.node_id)=='string' and type(p.public_key)=='string' then
      set[p.node_id..'\0'..p.public_key]=true
    end
  end
  return set
end
-- What the service's current operator list is, relative to the set this node consented to. `same` and
-- `added` are both admissible: a new operator being vouched for does not take the vouch away from any
-- operator this node pinned. `removed`/`changed` mean a pinned operator lost that vouch, which is the
-- only case admission must refuse. Compared as (node_id, public_key) pairs, never by position: the
-- order in WASM_AGENT_NETWORK_ADMINS is presentation, not consent.
-- The node ids the VERIFIED fleet roster revokes (host.mesh_call {revoked=true}), read only when a pin is
-- actually missing and kept a minute. Operator 17/11 ("make nodes removable"): the fleet key revoking a
-- node is the authority to drop it, so an operator the roster revoked may leave the service's list without
-- that loss detaching every node that once pinned it. No roster, or one that does not verify: an empty set,
-- and every loss counts as before.
local revoked_cache={at=-1e9,set={}}
local function roster_revoked()
  local now=tonumber(host.now()) or 0
  if now-revoked_cache.at<60 then return revoked_cache.set end
  local set={}
  if type(host.mesh_call)=='function' then
    local ok,raw=pcall(host.mesh_call,json.encode({revoked=true}))
    local answer=ok and type(raw)=='string' and (pcall(json.decode,raw) and json.decode(raw)) or nil
    if type(answer)=='table' and answer.ok==true and type(answer.revoked)=='table' then
      for _,id in ipairs(answer.revoked) do set[tostring(id)]=true end
    end
  end
  revoked_cache.at,revoked_cache.set=now,set
  return set
end
M._roster_revoked_cache=revoked_cache
local function pins_relation(service_pins,pinned_pins)
  local service,pinned=pin_set(service_pins),pin_set(pinned_pins)
  local lost,gained=false,false
  for k in pairs(pinned) do
    if not service[k] and not roster_revoked()[k:sub(1,(k:find('\0',1,true) or #k+1)-1)] then lost=true end
  end
  for k in pairs(service) do if not pinned[k] then gained=true end end
  if lost then return gained and 'changed' or 'removed' end
  return gained and 'added' or 'same'
end
local function same_pins(a,b) return pins_relation(a,b)=='same' end
-- The service's current authority, read as an observation rather than as a verdict. Used by the attach
-- tick and by every relayed call's admission. It used to be one boolean: any difference in the operator
-- list stopped the outbound runtime, so adding one administrator detached a healthy fleet from the
-- directory (measured 2026-11-09: work, mail and nextcloud, the third occurrence of this class). An
-- unreadable service is still a failure; a different operator LIST is a fact the caller decides about.
local function authority(s)
  local checked=M.inspect(s.service)
  if not checked.ok then return nil,'binding_service_unavailable',checked and checked.error end
  local relation=pins_relation(checked.operators,s.operators)
  local current,pinned=pin_set(checked.operators),pin_set(s.operators)
  local lost,gained={},{}
  for _,p in ipairs(s.operators or {}) do
    if not current[tostring(p.node_id)..'\0'..tostring(p.public_key)] and not roster_revoked()[tostring(p.node_id)] then lost[#lost+1]=tostring(p.node_id) end
  end
  for _,p in ipairs(checked.operators or {}) do
    if not pinned[tostring(p.node_id)..'\0'..tostring(p.public_key)] then gained[#gained+1]=tostring(p.node_id) end
  end
  return {relation=relation,operators=checked.operators,service=checked.service,
    lost=lost,gained=gained,admissible=(relation=='same' or relation=='added')}
end
function M.begin(preview,consent,renew,lifetime)
  lifetime=lifetime or 'standard'
  if lifetime~='standard' and lifetime~='permanent' then return failure('binding_lifetime_invalid') end
  -- The no-expiry intent takes its own word, so the ordinary `BIND` can never carry it by accident.
  if lifetime=='permanent' then
    if consent~='PERMANENT' then return failure('binding_permanent_consent_required') end
  elseif consent~='BIND' then return failure('binding_consent_required') end
  if host.getenv('WASM_AGENT_MANAGED')=='1' and not M.present() then return failure('binding_existing_managed_enrollment_preserved') end
  if not preview or not preview.ok then return failure('binding_preview_required') end
  local fresh=M.inspect(preview.service);if not fresh.ok then return fresh end
  if not same_pins(fresh.operators,preview.operators) then return failure('binding_operator_pins_changed') end
  if not service_supports(fresh.lifetimes,lifetime) then return failure('binding_lifetime_unsupported') end
  local old,err=M.saved();if err then return failure(err) end
  if old and (old.consent or old.active or old.phase=='submitting' or old.phase=='unknown') and not renew then return failure('binding_existing_request_inspect_first') end
  if renew and old then
    if old.service~=fresh.service or not same_pins(old.operators,fresh.operators) then return failure('binding_renew_pins_changed') end
    local revoked=M.unbind();if not revoked.ok then return revoked end;old=M.saved()
  end
  -- A server of this same ledger holding the outbound transport must not stop a CLI from ENROLLING: on a
  -- sentinel-managed node the sentinel owns the ledger, so this refusal left `/bind` with no possible
  -- runtime (`bind in its owner runtime` named a conversation surface that does not exist headless) and the
  -- operator had to stop the node by hand (31/10). Enrolling is safe beside it: the state CAS below admits
  -- one submission, and the transport lease - not this check - guarantees one owner, so the CLI's start
  -- stands by and the node keeps attaching. Any other preflight failure is still fatal.
  local preflight=decode(host.binding_transport('preflight'))
  local server_owned=preflight and not preflight.ok and tostring(preflight.error):find('binding_existing_server_owned',1,true)~=nil
  if not server_owned and (not preflight or not preflight.ok) then return failure('binding_attachment_preflight_refused',preflight and preflight.error) end
  local now=math.floor(host.now());local i=identity();local id=host.uuid():gsub('-','');local code=host.uuid():gsub('-',''):sub(1,12)
  -- Unnamed nodes used to enrol as the literal 'bound-node', so every unnamed machine shared one name in the
  -- registry (04/11: nextcloud and a second node both listed as bound-node). The machine name says which one.
  local machine=host.getenv('COMPUTERNAME') or host.getenv('HOSTNAME') or (host.read_file('/etc/hostname') or '')
  machine=tostring(machine):gsub('%s+$',''):gsub('^%s+','')
  local name=host.read_file(paths.config()..'/node.name') or host.getenv('WASM_AGENT_NODE_NAME') or (machine~='' and machine) or 'bound-node'
  name=name:gsub('^%s+',''):gsub('%s+$','')
  -- The pairing window is ten minutes and a test may only shorten it: the knob exists so the late-accept
  -- path can be exercised with authentic digests and a genuinely elapsed window instead of a forged
  -- request, which the digest check refuses (measured here: a rewritten `pairing_expires_at` answered
  -- `binding_response_identity_mismatch`). Anything above ten minutes is ignored.
  local pairing_seconds=tonumber(host.getenv and host.getenv('WA_BINDING_PAIRING_SECONDS') or '') or 600
  if pairing_seconds<1 or pairing_seconds>600 then pairing_seconds=600 end
  local request={schema=1,id=id,node_id=i.node_id,public_key=i.public_key,code=code,name=name,service=fresh.service,operators=fresh.operators,scope='user-account-tools',expires_at=now+(lifetime=='permanent' and PERMANENT_CONSENT_SECONDS or STANDARD_CONSENT_SECONDS),pairing_expires_at=now+pairing_seconds}
  -- A standard request keeps the deployed shape byte-for-byte (eleven fields, no `lifetime`); only the
  -- explicit permanent intent adds the twelfth. The capability asked for never grows: the scope stays
  -- exactly 'user-account-tools' either way.
  if lifetime=='permanent' then request.lifetime='permanent' end
  local raw_request=json.encode(request)
  local s={schema=1,request=request,raw_request=raw_request,digest=host.sha256(raw_request),active=false,consent=true,phase='submitting',network_role='guest',operators=fresh.operators,service=fresh.service,expires_at=request.expires_at}
  local written,why=cas(old,s);if not written then return failure(why) end
  local result,problem=http(s.service,'POST','/bindings/request','bind-request',raw_request)
  if not result then s.phase='unknown';s.error=problem;local kept,save_error=cas(written,s);return failure('binding_submission_unknown',save_error or problem) end
  if type(result.binding)~='table' or result.binding.digest~=s.digest or type(result.binding.request)~='table' or result.binding.request.id~=id then s.phase='unknown';local kept,save_error=cas(written,s);return failure('binding_response_identity_mismatch',save_error) end
  s.phase='pending';s.revision=result.binding.revision;s.error=nil
  local saved,save_error=cas(written,s);if not saved then return failure(save_error) end
  -- The CLI never takes the transport away from a running node: `start` stands by when this ledger is
  -- already served (the host knows if it is the server) and takes the lease only when nothing else does.
  -- Asking for `serve` here made a CLI steal the lease, exit, and leave the consent with no runtime at
  -- all - which is why an operator stopped a supervised node by hand (measured 2026-11-01).
  local action='start'
  local transport=decode(host.binding_transport(action))
  if not transport or not transport.ok then
    -- The request is already submitted: a serve that cannot take the lease is reported, never hidden,
    -- and never turned into a failure the operator would answer by submitting a second request.
    if not server_owned then return failure('binding_transport_unavailable',transport and transport.error) end
  end
  local attachment=(transport and transport.state=='standby') and 'standby' or 'owned'
  return {ok=true,state='pending',node_id=i.node_id,code=code,phrase=code:sub(1,4)..'-'..code:sub(5,8)..'-'..code:sub(9,12),pairing_expires_at=request.pairing_expires_at,expires_at=request.expires_at,lifetime=lifetime,attachment=attachment,transport=transport}
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
  -- The service's current operator set, reported, never used to hide the rest of this answer: a changed
  -- list is the fact an operator needs to see, and the calls it permits are decided per call.
  local observed,auth_error=authority(s)
  local own,lookup_error=http(s.service,'GET','/lookup?node_id='..s.request.node_id,'lookup')
  local registered=own and own.public_key==s.request.public_key and own.online==true or false
  local active=s.active==true and s.consent==true and s.expires_at>host.now() and v.binding.state=='accepted'
  -- A registry acceptance with a node that never attached used to look healthy here: `state` said
  -- `accepted`, the consent line said `no expiry`, and nothing said the local phase was still `pending`
  -- - the one fact that decides whether this node can do anything at all (measured 2026-11-01: a
  -- permanent grant that was silent for an hour while every field read as if it were fine). Name it.
  local note
  if observed and observed.relation=='added' then
    note='the service now vouches for operators this node did not consent to ('..table.concat(observed.gained,',')..'); the pins it consented to are unchanged, and this node keeps attaching'
  elseif observed and (observed.relation=='removed' or observed.relation=='changed') then
    note='a pinned operator is no longer vouched for by the service ('..table.concat(observed.lost,',')..'); calls from it are refused until this node is re-bound'
  end
  if v.binding.state=='accepted' and s.phase~='accepted' then
    note='accepted at the registry, but this node has not attached it yet: no outbound runtime has run the tick (phase '..tostring(s.phase)..')'
  elseif v.binding.state=='pending' and s.request.pairing_expires_at<=host.now() then
    note='no administrator has accepted this request and the ten-minute pairing window has closed; submit a new request'
  end
  return {ok=true,state=v.binding.state,active=active,registered=registered,attached=registered and own.relay_attached==true or false,lookup_error=lookup_error,local_role_preserved=true,phase=s.phase,attachment_note=note,authority=observed and {relation=observed.relation,vouched=#observed.operators,consented=#(s.operators or {}),gained=observed.gained,lost=observed.lost} or {ok=false,error=auth_error},pairing_expires_at=s.request.pairing_expires_at,network_role=s.network_role,node_id=s.request.node_id,code=s.request.code,expires_at=s.expires_at,lifetime=lifetime_of(s),consent=M.lifetime_label(s),transport=transport}
end
function M.profile(include_inactive)
  local s,err=M.saved()
  local mesh=mesh_take(nil,nil)
  if not s then
    -- A roster-authorized call does not need this node's binding at all: the roster is the authority.
    if mesh and mesh.in_force then
      return {schema=1,operators={{node_id=mesh.node_id,public_key=mesh.public_key,mesh='roster'}},mesh_admission=true}
    end
    return nil,err or 'not_bound'
  end
  local active=s.active and s.consent and s.phase=='accepted' and s.expires_at>host.now()
  if not include_inactive and not active and not (mesh and mesh.in_force) then return nil,'binding_inactive_or_expired' end
  if mesh and mesh.in_force then
    -- The caller the roster admitted, added to the operator list for the length of this one call:
    -- `enrollment.author` attributes the work to whoever the roster said asked for it.
    local copy={};for k,v in pairs(s) do copy[k]=v end
    local operators={};for _,p in ipairs(s.operators or {}) do operators[#operators+1]=p end
    operators[#operators+1]={node_id=mesh.node_id,public_key=mesh.public_key,mesh='roster'}
    copy.operators=operators;copy.mesh_admission=true
    return copy
  end
  return s
end
-- Cached admissions, so a rendezvous OUTAGE does not turn an already-bound operator into a stranger.
--
-- Measured 19/11 ~12:17 UTC, home network down: the work node answered no relayed call for the length
-- of the drop, because every call ran M.authorize, which asks the registry twice (the operator list
-- and the binding status), and an unreadable registry refused by returning nil. The node could not
-- answer the very calls whose answers would have let the fleet drain - the second half of the storm.
--
-- The rule, and it is an allow-list: a POSITIVE decision (this exact node_id+public_key, vouched for
-- by the registry, with an accepted binding) is remembered with the time it was made. When a later
-- check cannot REACH the registry - a transport failure, never a refusal - the remembered decision
-- stands until it expires. Anything the registry actually answers still wins: revoked, removed,
-- expired or unknown refuses at once. A caller with no remembered decision is refused as before, so
-- this can never admit a NEW binding while the registry is unreachable.
M.ADMISSION_CACHE_SECONDS = tonumber(host.getenv('WASM_AGENT_BINDING_CACHE_SECONDS') or '') or 600
local admitted = {}

local function admission_key(id, key) return tostring(id) .. '\0' .. tostring(key) end

-- True when a failure is the LINK, not the registry's judgement. Only these use the cache.
local function unreachable_detail(detail)
  local text = tostring(detail or ''):lower()
  if text == '' then return true end
  if text:find('binding_service_unavailable', 1, true) then return true end
  -- The native transport's words for a socket that died mid-read, and this module's own wrapper for a
  -- call that returned nothing at all (binding_http_nil). Measured by tests/storm.rs: during a 60 s cut
  -- the tick answered binding_approval_unavailable/binding_http_nil:io: Peer disconnected, which matched
  -- NOTHING here, so the node stopped polling for the rest of the outage and never re-attached.
  if text:find('peer disconnected', 1, true) then return true end
  if text:find('binding_http_nil', 1, true) then return true end
  if text:find('connection closed', 1, true) then return true end
  if text:find('unexpected eof', 1, true) then return true end
  if text:find('broken pipe', 1, true) then return true end
  if text:find('connection aborted', 1, true) then return true end
  if text:find('os error 10053', 1, true) then return true end
  if text:find('binding_http_5', 1, true) then return true end
  if text:find('binding_http_unreadable', 1, true) then return true end
  if text:find('binding_reply_invalid', 1, true) then return true end
  if text:find('timeout', 1, true) or text:find('timed out', 1, true) then return true end
  if text:find('connection refused', 1, true) or text:find('connection reset', 1, true) then return true end
  if text:find('network is unreachable', 1, true) or text:find('no route to host', 1, true) then return true end
  if text:find('name resolution', 1, true) or text:find('dns', 1, true) then return true end
  return false
end

function M.admission_cache_size() return (function() local n=0; for _ in pairs(admitted) do n=n+1 end; return n end)() end
function M.admission_cache_clear() admitted = {}; return true end

function M.authorize(id,key)
  -- The roster first: when the fleet said yes, the pins of a binding made before the fleet existed
  -- are not the authority any more. This is the one place a relayed call is admitted.
  local mesh=mesh_take(id,key)
  if mesh then
    return {node_id=id,public_key=key,role='master',name=(mesh.name~='' and mesh.name or id),level=mesh.level,mesh='roster',capability=mesh.capability}
  end
  local s=M.profile();if not s then return nil end
  local pinned=false;for _,p in ipairs(s.operators) do if p.node_id==id and p.public_key==key then pinned=true end end
  if not pinned then return nil end
  local remember=admitted[admission_key(id,key)]
  local now=tonumber(host.now()) or 0
  -- Admission is per caller: the service must still vouch for this exact (node_id, public_key) pair.
  -- A removed operator is refused; whether some other pinned operator was also removed is not this
  -- caller's business and must not stop the node from answering the ones still vouched for.
  local service,service_problem=M.inspect(s.service)
  if not service.ok then
    -- The registry could not be READ. For a caller this node already admitted, that is not a verdict:
    -- an outage must not turn an operator into a stranger (see ADMISSION_CACHE_SECONDS).
    local detail=service.detail or service.error or service_problem
    if remember and unreachable_detail(detail) and (now - remember.at) <= M.ADMISSION_CACHE_SECONDS then
      remember.used=remember.used+1
      return {node_id=id,public_key=key,role='master',name=id,cached=true,cached_age_s=now-remember.at}
    end
    return nil
  end
  local vouched=false
  for _,p in ipairs(service.operators or {}) do if p.node_id==id and p.public_key==key then vouched=true end end
  if not vouched then
    -- The registry ANSWERED and does not vouch for this pair: the cache must not stand in its way.
    admitted[admission_key(id,key)]=nil
    return nil
  end
  local v,status_problem=request_status(s)
  if not valid_reply(s,v) then
    if remember and unreachable_detail(status_problem) and (now - remember.at) <= M.ADMISSION_CACHE_SECONDS then
      remember.used=remember.used+1
      return {node_id=id,public_key=key,role='master',name=id,cached=true,cached_age_s=now-remember.at}
    end
    return nil
  end
  if v.binding.state~='accepted' or v.binding.request.expires_at<=now then
    -- A real answer about this binding: revoked or expired drops the remembered decision.
    admitted[admission_key(id,key)]=nil
    return nil
  end
  admitted[admission_key(id,key)]={at=now,used=0}
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
  if not preview or not preview.ok then return failure('binding_accept_confirmation_required') end
  local b=preview.binding;local r=b.request
  -- Accepting a no-expiry request takes its own word too, and the affirmation travels in the signed
  -- acceptance body: the registry refuses a permanent request without it and refuses it on a standard
  -- request, so approval cannot quietly change the lifetime in either direction.
  local permanent=lifetime_of(r)=='permanent'
  if confirmation~=(permanent and 'ACCEPT-PERMANENT' or 'ACCEPT') then
    return failure(permanent and 'binding_accept_permanent_confirmation_required' or 'binding_accept_confirmation_required')
  end
  local v,err=http(preview.service,'POST','/bindings/accept','bind-accept',{id=r.id,node_id=r.node_id,public_key=r.public_key,code=r.code,digest=b.digest,revision=b.revision,authorize_lifetime=permanent and 'permanent' or nil})
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
-- ---- the two calls a bound node answers differently from a turn -------------------------------
--
-- `/node/call` arrives here only when this node's transport is the relay (a bound node long-polls its
-- service; `rust/wa-rendezvous/src/relay_client.rs` is the other owner). Two kinds of call mean
-- something other than "run a capability as this node's peer":
--
--   * a **mesh envelope** (`x-wa-mesh: 1`), when this node has a verified roster: the roster's
--     hierarchy and its grants decide, not the operator pins its binding froze at bind time. The
--     relay is transport only, so this is the same decision a direct mesh call gets;
--   * `capability == "roster"`: `wa fleet push-roster`, the call that installs the roster in the
--     first place. It is deliberately not a mesh call: the pins must authorize the one call that
--     brings the roster into being.

-- The reply envelope `server.lua` sends, byte for byte: signed over the caller's own signature and
-- the answer, so the relay (or anything on a plain-HTTP hop) cannot hand the caller a different result.
local function signed_reply(signature, ts, out)
  local i=identity()
  local signed=decode(host.sign('reply|'..i.node_id..'|'..tostring(ts)..'|'..host.sha256(tostring(signature or '')..'\n'..out)))
  return json.encode({reply=out,reply_sig=(signed and signed.signature) or ''})
end

-- Headers as a lowered map, from either shape a carrier hands over: the **object** `{name: value}`
-- the relayed envelope carries, and the **array** `[[name, value], …]` a mesh call carries (the Rust
-- client writes `MeshCall.inner_headers` this way). Reading only one shape loses every header of the
-- other: the target then finds no `x-wa-mesh`, takes the plain peer path, verifies a mesh envelope as
-- if it were a call body and answers `bad_signature` (measured 16/11, and the same class as
-- `header_pairs` in rust/wa-mesh/src/host_call.rs).
local function lowered(headers)
  local out={}
  for k,value in pairs(headers or {}) do
    if type(k)=='string' then
      out[k:lower()]=tostring(value)
    elseif type(value)=='table' and type(value[1])=='string' then
      out[value[1]:lower()]=tostring(value[2])
    end
  end
  return out
end

local function inner_lowered(pairs_list)
  local out={}
  for _,pair in ipairs(pairs_list or {}) do
    if type(pair)=='table' then out[tostring(pair[1]):lower()]=tostring(pair[2]) end
  end
  return out
end

-- Ask the host to seal a reply for a relayed answer: the relay drops response headers, so the
-- signature travels inside the body. Identical signed message as the direct path.
local function seal_relayed_reply(reply, caller)
  if type(host.mesh_call)~='function' then return nil end
  local ok,raw=pcall(host.mesh_call,json.encode({seal={reply=reply,caller=tostring(caller or ''),transport='relay'}}))
  if not ok or type(raw)~='string' then return nil end
  local v=decode(raw)
  if not v or v.ok~=true then return nil end
  return tostring(v.body or '')
end

-- A relayed call that carries a mesh envelope, decided by this node's own roster. Returns the body to
-- send back to the relay, or nil when this is not a mesh call at all (today's path then applies).
-- A relayed mesh call already decided by the host, on the lane's worker thread and outside this
-- interpreter (`pre_admit_relayed`, rust/wa-mesh/src/host_call.rs). Nothing here asks the mesh mount
-- anything: the admission arrives in a header, the run happens with it in force, and the reply is
-- sealed below. This is the path that used to stall (docs/MESH-MODULE.md, "Known defect").
local function mesh_admitted_call(preadm, body, headers)
  local a = decode(preadm)
  if not a or type(a.node_id) ~= 'string' then return nil end
  local call = decode(body)
  if type(call) ~= 'table' then return nil end
  local inner = inner_lowered(call.inner_headers)
  wa_mesh_admit(json.encode({node_id=a.node_id,public_key=a.public_key,name=a.name,level=a.level,
    capability=a.capability,request_id=a.request_id}))
  local ran,answer=pcall(wa_node_call,call.inner_body or '',inner['x-wa-node'] or '',
    inner['x-wa-pub'] or '',inner['x-wa-ts'] or '',inner['x-wa-sig'] or '')
  wa_mesh_clear()
  -- PROBE (remove with the fix): the inner call's own signature is what the target refuses, so report
  -- what arrived: field lengths only, never a value.
  if not ran or (type(answer)=='string' and answer:find('bad_signature',1,true)) then
    local count=0
    for _ in pairs(inner) do count=count+1 end
    answer=json.encode({error='bad_signature',diag={
      inner_body_len=#tostring(call.inner_body or ''),
      inner_headers=count,
      sig_len=#tostring(inner['x-wa-sig'] or ''),
      pub_len=#tostring(inner['x-wa-pub'] or ''),
      ts=tostring(inner['x-wa-ts'] or ''),
      raw_headers=#(type(call.inner_headers)=='table' and call.inner_headers or {})}})
  end
  local out=ran and tostring(answer) or json.encode({error='internal_error'})
  local i=identity()
  local reply=json.encode({schema=1,request_id=tostring(a.request_id or ''),from_node_id=i.node_id,
    ok=true,status=200,body=out,verb=tostring(a.verb or '')})
  return seal_relayed_reply(reply, a.node_id) or out
end

local function mesh_relayed_call(headers, body)
  if tostring(headers['x-wa-mesh'] or '')~='1' then return nil end
  if type(host.mesh_call)~='function' then return nil end
  headers['x-wa-mesh-carrier']='relay'
  local pairs_list={}
  for name,value in pairs(headers) do pairs_list[#pairs_list+1]={name,tostring(value)} end
  local ok,raw=pcall(host.mesh_call,json.encode({admit={headers=pairs_list,body=tostring(body or ''),transport='relay'}}))
  if not ok or type(raw)~='string' then return nil end
  local decoded=decode(raw)
  if not decoded then return nil end
  if decoded.ok then
    local inner=inner_lowered(decoded.inner_headers)
    -- The roster said yes: run the caller's own `/node/call` request with that decision in force.
    wa_mesh_admit(json.encode({node_id=decoded.caller_node_id,public_key=decoded.caller_public_key,
      name=decoded.caller_name,level=decoded.caller_level,capability=decoded.capability,request_id=decoded.request_id}))
    local ran,answer=pcall(wa_node_call,decoded.inner_body or '',inner['x-wa-node'] or '',
      inner['x-wa-pub'] or '',inner['x-wa-ts'] or '',inner['x-wa-sig'] or '')
    wa_mesh_clear()
    if not ran or (type(answer)=='string' and answer:find('bad_signature',1,true)) then
      answer=json.encode({error='bad_signature',diag={
        inner_body_len=#tostring(decoded.inner_body or ''),
        sig_len=#tostring(inner['x-wa-sig'] or ''),
        pub_len=#tostring(inner['x-wa-pub'] or ''),
        ts=tostring(inner['x-wa-ts'] or ''),
        node_len=#tostring(inner['x-wa-node'] or '')}})
    end
    local out=ran and tostring(answer) or json.encode({error='internal_error'})
    local i=identity()
    local reply=json.encode({schema=1,request_id=tostring(decoded.request_id or ''),from_node_id=i.node_id,
      ok=true,status=200,body=out,verb=tostring(decoded.verb or '')})
    local sealed = seal_relayed_reply(reply, decoded.caller_node_id)
    return sealed or out
  end
  if decoded.error=='mesh_legacy' then
    -- No verified roster on this node yet: today's pins decide, with the caller's own request.
    local inner=inner_lowered(decoded.inner_headers)
    return wa_node_call(decoded.inner_body or tostring(body or ''),inner['x-wa-node'] or '',
      inner['x-wa-pub'] or '',inner['x-wa-ts'] or '',inner['x-wa-sig'] or '')
  end
  if decoded.error=='mesh_refused' then
    -- Already the answer to send: a signed refusal for a relayed call, an allow-listed code otherwise.
    return tostring(decoded.answer or '{"error":"mesh_denied"}')
  end
  return nil
end

-- `wa fleet push-roster`, answered over the relay by a node this node ALREADY accepts under today's
-- binding. Everything is checked before a single file is written; the fleet private key never travels.
local function roster_call(body, headers)
  local ok,request=pcall(json.decode,body or '')
  if not ok or type(request)~='table' then return json.encode({error='bad_request'}) end
  local from=headers['x-wa-node'] or ''
  local public_key=headers['x-wa-pub'] or ''
  local stamp=math.floor(tonumber(headers['x-wa-ts']) or 0)
  local signature=headers['x-wa-sig'] or ''
  local function finish(value) return signed_reply(signature, stamp, json.encode(value)) end
  if from=='' then return json.encode({error='bad_request'}) end
  -- The caller's own signature over its body, exactly as every peer call proves it.
  if not host.verify(public_key,'call|'..from..'|'..stamp..'|'..host.sha256(tostring(body or '')),signature) then
    return json.encode({error='bad_signature'})
  end
  if math.abs(host.now()-stamp)>120 then return json.encode({error='stale_request'}) end
  local me=identity()
  if request.to_node_id~=me.node_id then return json.encode({error='wrong_target'}) end
  -- "ALREADY an accepted operator of this node": the same admission every peer call gets while this
  -- node has no roster, which reaches the registry so a revoked or expired binding refuses here too.
  if not M.authorize(from,public_key) then return json.encode({error='unknown_caller'}) end
  local seen=dofile('lua/core/enrollment.lua').seen_before(table.concat({from,'roster',tostring(stamp),tostring(signature)},'|'))
  if seen then return json.encode({error='replayed_request'}) end
  local args=type(request.args)=='table' and request.args or {}
  if tostring(args.action or '')~='push' then return json.encode({error='roster_action_required'}) end
  if type(args.roster)~='string' or args.roster=='' or type(args.roster_key)~='string' or args.roster_key=='' then
    return finish({ok=false,error='roster_request_invalid'})
  end
  if type(host.mesh_call)~='function' then return finish({ok=false,error='mesh_disabled'}) end
  -- Verify before writing: the roster against the key being pinned.
  local ok_verify,verified=pcall(host.mesh_call,json.encode({verify_roster={text=args.roster,key=args.roster_key}}))
  local v=ok_verify and decode(verified) or nil
  if not v then return finish({ok=false,error='mesh_unavailable',detail='verify_roster'}) end
  if v.ok~=true then
    -- The host's own word: `roster_unverified:<why>` when the document does not verify, and the host's
    -- error code when the check could not run at all. Never one masked as the other.
    return finish({ok=false,error=tostring(v.error or 'roster_unverified'),detail=tostring(v.detail or '')})
  end
  local ok_install,installed=pcall(host.mesh_call,json.encode({install_roster={
    config=paths.config(),roster=args.roster,roster_key=args.roster_key,
    caller_node_id=from,caller_public_key=public_key,target_node_id=me.node_id,
    replace_key_signature=args.replace_key_signature}}))
  local result=ok_install and decode(installed) or nil
  if not result then return finish({ok=false,error='roster_install_unavailable'}) end
  return finish(result)
end

-- ---- the poll lane's own record: attach and detach, said once ---------------------------------
--
-- Polling and execution are separate lanes (`binding_runtime.rs`): this module only ever polls, so
-- a line here means the transport itself changed state, never that a request took long. That is what
-- lets a drop be told apart from a slow call afterwards - with the old inline shape both showed up
-- as `node_not_attached` at the registry and neither side wrote a line (measured 2026-11-10).
local function log(text)
  if type(host.log)=='function' then pcall(host.log,'[relay] '..text) end
end
local function stamp() return os.date('!%Y-%m-%dT%H:%M:%SZ',math.floor(host.now())) end
local function observe_attached(node_id)
  if M.transport_attached==true then return end
  local away=M.attached_lost_at and (host.now()-M.attached_lost_at) or nil
  M.transport_attached=true;M.attached_lost_at=nil
  log('attach node='..tostring(node_id)..' at='..stamp()..' reason='..
    (away and ('poll after '..string.format('%.1f',away)..'s away') or 'first poll'))
end
local function observe_detached(node_id,reason)
  -- Once per transition, including the first failure of a fresh process: a node that cannot attach
  -- must say so, and a node that keeps failing must not fill the log with the same line.
  if M.transport_attached==false then return end
  M.transport_attached=false;M.attached_lost_at=host.now()
  log('detach node='..tostring(node_id)..' at='..stamp()..' reason='..tostring(reason))
end

-- One poll. Runs only on the leased outbound runtime, never on the model or a scheduled job.
--
-- It never runs the request it receives: a relayed call can take minutes, and polling has to keep
-- going while it does - a node that polls late is detached, and then every caller is told
-- `node_not_attached` until it happens to poll again (the defect this replaced). The request is
-- handed back in `dispatch` and executed on the transport's worker lane, which answers it.
function M.tick()
  local s,problem=M.saved();if not s then return failure(problem or 'not_bound') end
  if not s.consent or s.expires_at<=host.now() or s.phase=='revoked' then return {state='inactive'} end
  if s.phase~='accepted' then
    -- The registry's `accepted` outranks this node's ten-minute PAIRING window: that window bounds how
    -- long a request may sit unanswered, not how long an acceptance stays usable. Checked first, it made
    -- a late tick - a node that was not running when its administrator approved, a restart, an offline
    -- device - refuse an already-accepted grant forever: `accepted` at the registry, local phase
    -- `pending` for good, no `/register`, and nothing anywhere naming the reason (measured 2026-11-01:
    -- pairing_expires_at passed at 18:15:36, transport `starting`, heartbeat still frozen an hour later).
    local v,err=request_status(s);if not v then return failure('binding_status_unavailable',err) end
    if not valid_reply(s,v) then return failure('binding_response_identity_mismatch') end
    if v.binding.state=='accepted' then
      local auth0,auth0_error,auth0_detail=authority(s)
      if not auth0 then return failure(auth0_error,auth0_detail) end
      local next={};for k,x in pairs(s) do next[k]=x end;next.active=true;next.phase='accepted';next.revision=v.binding.revision
      s,problem=cas(s,next);if not s then return failure(problem) end
      -- Bound: the cluster's connectors are usable from this node at once (lua/core/federation.lua).
      pcall(function() return dofile('lua/core/federation.lua').refresh() end)
    elseif v.binding.state~='pending' then return {state=v.binding.state}
    elseif s.request.pairing_expires_at<=host.now() then return {state='pairing_expired'}
    else return {state='pending',code=s.request.code} end
  end
  -- Attaching is reachability, not permission: every inbound call is still decided by M.authorize
  -- (the roster, else the pins). An operator list that gained a name used to stop this tick and detain
  -- a healthy node; it is now reported on the result and the node keeps answering its operators.
  local observed,auth_error,auth_detail=authority(s)
  -- Named, never silent: set when the tick kept polling through an unreadable registry.
  local outage_error=nil
  if not observed then
    -- Item 7: the TICK path needs the same cached authority M.authorize already has. A registry that
    -- could not be READ is not a verdict, and a tick that returns here is a node that stops polling -
    -- it goes unreachable itself, which is the 19/11 deadlock. So a good observation is remembered and
    -- stands through a LINK failure inside its window; a registry that ANSWERS still wins, and stops
    -- the tick exactly as before ('an unreadable service is named unavailable, not an authority change').
    local cached=M.last_authority
    local now=tonumber(host.now()) or 0
    if cached and unreachable_detail(auth_detail) and (now-cached.at)<=M.ADMISSION_CACHE_SECONDS then
      -- The registry could not be READ, inside the window of a good observation: the tick still POLLS
      -- (below), so this node stays reachable - but the answer keeps naming the outage, because a
      -- reader must still be able to tell a healthy attach from one made during an outage.
      observed={relation='unreadable',gained={},lost={},cached=true,cached_age_s=now-cached.at}
      M.last_authority_outage={at=now,reason=tostring(auth_error or auth_detail)}
      outage_error=tostring(auth_error or 'binding_service_unavailable')
    else
      observe_detached(s.request.node_id,'authority_lost:'..tostring(auth_error or auth_detail))
      return failure(auth_error,auth_detail)
    end
  else
    M.last_authority={at=tonumber(host.now()) or 0,relation=observed.relation}
  end
  local v,err=request_status(s)
  if not valid_reply(s,v) or v.binding.state~='accepted' then
    local status_detail=tostring(err or (v and v.binding and v.binding.state))
    local cached_ok=M.last_authority
      and (tonumber(host.now()) or 0)-M.last_authority.at<=M.ADMISSION_CACHE_SECONDS
    if not (cached_ok and unreachable_detail(status_detail)) then
      observe_detached(s.request.node_id,'binding_approval_unavailable:'..status_detail)
      return failure('binding_approval_unavailable',err)
    end
    -- The status check could not REACH the registry either, inside the same window: keep polling.
    M.last_authority_outage={at=host.now(),reason='binding_approval_unavailable:'..status_detail}
    outage_error=outage_error or 'binding_approval_unavailable'
  end
  if not M.last_heartbeat or host.now()-M.last_heartbeat>=60 then
    -- Same v2 announcement as node.rs: the signature covers the name and the (empty) endpoint list.
    -- The name a node answers to now, not the one frozen into its binding request: a node bound before it
    -- was named stayed 'bound-node' in the registry forever (04/11: work and nextcloud). The name is
    -- display only - the registry binds by key - so the signed announcement carries the current one.
    local current=tostring(host.read_file(paths.config()..'/node.name') or ''):gsub('^%s+',''):gsub('%s+$','')
    local name=current~='' and current or tostring(s.request.name or '')
    local ts=math.floor(host.now());local i=identity();local sig=decode(host.sign('v2|'..i.node_id..'|'..ts..'|'..name..'|[]'))
    local r,e=http(s.service,'POST','/register',nil,{node_id=i.node_id,public_key=i.public_key,name=name,role=s.network_role,endpoints={},ts=ts,signature=sig.signature})
    if not r then
      -- MUST 3: this used to `return` before the /relay/poll below, WITHOUT advancing the heartbeat -
      -- so every 2 s it retried only the register and never polled the relay, which is the 19/11
      -- deadlock in miniature: the node cannot be reached, so the calls waiting for it cannot be
      -- answered, so the queue never drains. A register failure is reported and the poll still runs.
      observe_detached(s.request.node_id,'binding_registration_failed:'..tostring(e))
      M.last_registration_failure = {at=host.now(),reason=tostring(e)}
    else
      M.last_heartbeat=host.now()
      M.last_registration_failure = nil
    end
  end
  local response,why=http(s.service,'GET','/relay/poll?node_id='..s.request.node_id,'relay-poll')
  if not response then
    observe_detached(s.request.node_id,'relay_poll_failed:'..tostring(why))
    return failure('binding_relay_unavailable',why)
  end
  observe_attached(s.request.node_id)
  -- During an outage there IS no authority observation to report, and saying "same" would be a lie:
  -- the view says the authority was unreadable and names why, so a reader can tell a healthy attach
  -- from a node that is attached while the registry is unreachable.
  local outage=M.last_authority_outage
  local view={state='attached',registered=true,attached=true,node_id=s.request.node_id,
    authority=observed and observed.relation or 'unreadable',
    authority_gained=observed and observed.gained or {},
    authority_lost=observed and observed.lost or {},
    authority_note=(not observed) and ('the registry could not be read ('..tostring(outage and outage.reason or 'unavailable')
      ..'); this node kept polling and serving its operators') or nil}
  -- An outage is reported by its own name, and the poll above still happened: the node is reachable
  -- and the reader knows the registry was not.
  if outage_error then view.error=outage_error end
  if response.request then
    -- Hand it to the runtime, never run it here (see the note on M.tick).
    view.dispatch={service=s.service,node_id=s.request.node_id,request=response.request}
  end
  return view
end

-- Executes one relayed request and answers it, on the transport's worker lane.
--
-- A fresh interpreter per admitted call (`binding_runtime.rs`, bounded): this function is what the
-- node did inline before, with two additions - the bound and the answer's honesty. The bound is the
-- relay's `deadline_ms`, stamped from the wait the caller was given, and it is already installed as
-- this call's exec/cancel budget by the runtime that started this lane, so work that can be stopped
-- (a `bash`, a provider read) stops at it. If the call nonetheless returns after the bound, the
-- result is named as a timeout instead of being handed back as a fresh answer.
function M.serve(raw)
  local r=decode(raw)
  local hdr=r and r.headers
  local meshflag='?'
  pcall(function() for _,h in ipairs(hdr or {}) do
    if type(h)=='table' and tostring(h[1]):lower()=='x-wa-mesh' then meshflag=tostring(h[2]) end
    if type(h)=='table' and tostring(h[1]):lower()=='x-wa-node' then meshflag=meshflag..'/'..tostring(h[2]) end
  end end)
  if not r or type(r.id)~='string' then
    return {status=400,body=json.encode({error='relay_request_unreadable',not_started=true})}
  end
  local started=host.now()
  local deadline_ms=tonumber(r.deadline_ms)
  local budget_ms=tonumber(r.budget_ms)
  local body,status='{"error":"binding_route_not_granted"}',403
  if r.method=='POST' and r.path=='/node/call' then
    local h=lowered(r.headers)
    status=200
    -- A mesh envelope is admitted by this node's roster (when it has a verified one); a `roster`
    -- call installs that roster and is admitted by today's operator pins. Everything else is a
    -- peer capability call, exactly as before.
    local preadm=h['x-wa-mesh-admission']
    local mesh=preadm and mesh_admitted_call(preadm,r.body or '',h) or mesh_relayed_call(h,r.body or '')
    local asked=decode(r.body or '')
    if mesh then body=mesh
    elseif asked and asked.capability=='roster' then body=roster_call(r.body or '',h)
    else
      body=wa_node_call(r.body or '',h['x-wa-node'] or '',h['x-wa-pub'] or '',h['x-wa-ts'] or '',h['x-wa-sig'] or '')
    end
  end
  local elapsed_ms=math.floor((host.now()-started)*1000)
  if deadline_ms and host.now()*1000>=deadline_ms then
    return {status=504,late=true,elapsed_ms=elapsed_ms,body=json.encode({
      error='relay_request_timeout',id=r.id,budget_ms=budget_ms or 0,elapsed_ms=elapsed_ms,
      hint='the call passed the deadline its caller was given; the work was stopped and this answer is not fresh'})}
  end
  return {status=status,body=body,elapsed_ms=elapsed_ms}
end
return M
