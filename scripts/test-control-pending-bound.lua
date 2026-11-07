-- A served `/bind` (or promote/demote) leaves one pending confirmation per session in
-- `lua/core/server.lua`'s `control_pending`. It used to be pruned only when *that* session came back,
-- so a session that asked once and never returned left an entry behind for the life of the
-- interpreter: a table that only grew. This proves the two bounds that replaced that - the TTL is
-- swept on insert, and the size is capped - and that neither breaks a session confirming its own
-- request.
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(v,label) assert(v,label); checks=checks+1 end
local id=json.decode(host.node_identity())
local pin={node_id=id.node_id,public_key=id.public_key}
local service='http://127.0.0.1:12432'

-- A clock this test owns, so the TTL is exercised without waiting ten minutes. It starts at the real
-- node time, so nothing in the binding flow looks skewed.
local clock=host.now()
host.now=function() return clock end

host.http=function(method,url,headers,body)
  local value
  if url:match('/service$') then
    value={protocol=1,binding_protocol=1,binding_lifetimes={'standard','permanent'},enrollment_ready=true,operators={pin}}
  elseif method=='POST' and url:match('/bindings/request$') then
    value={ok=true,binding={digest=host.sha256(body),request=json.decode(body),state='pending',revision=1}}
  elseif method=='GET' and url:find('/bindings/request?',1,true) then
    local stored=json.decode(host.binding_state('read','{}')).state or {}
    value={ok=true,binding={digest=stored.digest,request=stored.request or {},state='pending',revision=1}}
  else error('unexpected request '..tostring(method)..' '..url) end
  return json.encode({status=200,body=json.encode(value)})
end
host.binding_transport=function(action)
  if action=='preflight' then return json.encode({ok=false,error='binding_existing_server_owned; bind in its owner runtime or stop it explicitly'}) end
  if action=='start' then return json.encode({ok=true,state='standby',owner='another process'}) end
  return json.encode({state='standby',owner='another process'})
end

dofile('lua/core/server.lua')  -- defines the served entry points as globals
check(type(wa_served_control)=='function','the served entry points load')
check(type(wa_control_pending_count)=='function','the pending count is observable, so the bound is not assumed')
check(wa_control_pending_count()==0,'a fresh interpreter has no pending confirmation')

-- One session asks, is told to say the word, and does: the sweep on insert must not take the entry
-- of the session that is asking.
local asked=json.decode(wa_reply('/bind permanent '..service,'s1'))
check(asked.local_control==true and tostring(asked.reply):find('PERMANENT',1,true)~=nil,'/bind permanent asks for the word')
check(wa_control_pending_count()==1,'the asking session has one pending confirmation')
check(wa_served_control('a normal message','s1')==nil,'an ordinary message does not consume it')
check(wa_control_pending_count()==1,'and does not touch it')
local done=json.decode(wa_reply('PERMANENT','s1'))
check(done.local_control==true,'the word still completes the request the sweep kept')
check(wa_control_pending_count()==0,'confirming clears its own entry')

-- The cap: many sessions ask inside one TTL. Each insert sweeps and evicts the oldest, so the table
-- stays at its bound instead of growing with the number of sessions.
local many=80
for i=1,many do
  wa_served_control('/bind permanent '..service,'burst-'..i)
end
local capped=wa_control_pending_count()
check(capped>0 and capped<=64,'a burst of '..many..' sessions stays inside the documented bound (64), got '..capped)

-- The TTL: past it, a single new ask sweeps every expired session, so the table holds only the ones
-- still inside their ten minutes - here, exactly the one that just asked.
clock=clock+601
wa_served_control('/bind permanent '..service,'after-the-ttl')
local swept=wa_control_pending_count()
check(swept==1,'expired sessions are swept by the next insert, not when they happen to come back (got '..swept..')')
check(wa_served_control('PERMANENT','after-the-ttl')~=nil,'the session that asked after the sweep still confirms')
check(wa_control_pending_count()==0,'and the table is empty again')

print(json.encode({ok=true,checks=checks}))
