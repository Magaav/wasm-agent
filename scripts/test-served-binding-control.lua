-- `/bind` in the served conversation (1/11): the node's own UI is the runtime that owns its transport, so a
-- control typed there must run the same local front door as the terminal REPL - never a model prompt.
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(v,label) assert(v,label); checks=checks+1 end
local id=json.decode(host.node_identity())
local pin={node_id=id.node_id,public_key=id.public_key}
local service='http://127.0.0.1:12432'

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
check(type(wa_reply)=='function' and type(wa_served_control)=='function','the served entry points load')
check(wa_served_control('just a normal message','s1')==nil,'ordinary conversation is not a control')
check(wa_served_control('hello /bind not at the start','s1')==nil,'a slash inside a sentence is not a control')

local status=json.decode(wa_reply('/bind status','s1'))
check(status.local_control==true,'/bind status is intercepted, not sent to the model: '..json.encode(status))
check(tostring(status.reply):find('not_bound',1,true)~=nil,'it answers from the local binding state: '..tostring(status.reply))

local preview=json.decode(wa_reply('/bind permanent '..service,'s1'))
check(preview.local_control==true,'/bind permanent is a control')
check(tostring(preview.reply):find('Operator: ',1,true)~=nil,'the operator pins are shown')
check(tostring(preview.reply):find('PERMANENT: this consent has NO EXPIRY',1,true)~=nil,'the no-expiry intent is stated')
check(tostring(preview.reply):find('Type PERMANENT to confirm',1,true)~=nil,'it asks for the word instead of assuming it')
check(host.binding_state and (json.decode(host.binding_state('read','{}')).state==nil),'nothing is submitted before the word')

local done=json.decode(wa_reply('PERMANENT','s1'))
check(done.local_control==true,'the confirmation word is the control continuing')
check(tostring(done.reply):find('wa accept %x+   # phrase %x%x%x%x%-%x%x%x%x%-%x%x%x%x')~=nil,'it ends in the one copy-able accept line: '..tostring(done.reply):sub(-120))
local saved=json.decode(host.binding_state('read','{}')).state or {}
check(saved.phase=='pending' and saved.request and saved.request.lifetime=='permanent','the request is persisted with the permanent intent')

check(wa_served_control('PERMANENT','s2')==nil,'the word only continues the session that asked for it')

print(json.encode({ok=true,checks=checks}))
