
local json=dofile('lua/vendor/json.lua');local nodes=dofile('lua/core/nodes.lua');local o=dofile('lua/core/orchestrator.lua')
local destination='5fcb07bce692edc474b7478d536fb3d2'
local checks=0;local function check(v,label) assert(v,label);checks=checks+1;print('ok '..label) end
for i=1,100 do if nodes.find(destination) then break end host.sleep(100) end
local raw=nodes.remote_call(destination,'status',{model='fixture',provider='opencode-go',serving_identity_only=true})
print('SIGNED_IDENTITY '..json.encode(raw));local identity=raw.serving_identity
check(identity and identity.node_id==destination and identity.model=='fixture' and identity.provider=='opencode-go','actual authenticated peer establishes requested identity')
local response=nodes.remote_call(destination,'status',{model='fixture',serving_identity=identity})
print('SIGNED_STATUS '..json.encode(response))
check(response.serving and response.serving.state=='blocked','signed status reads durable monthly account block')
check(o.serving_eligible(destination,'fixture','opencode-go')==false,'actual signed exact tuple skips blocked peer')
check(o.serving_eligible(destination,'fixture','foreign-provider')==true,'explicit unsupported provider override remains unknown')
identity.account_profile='foreign-account'
local changed=nodes.remote_call(destination,'status',{model='fixture',serving_identity=identity})
check(changed.serving.state=='unknown' and changed.serving.reason=='serving_identity_changed','foreign requested account cannot inherit default account block')

identity.account_profile='account-a'
local raw_http=host.http
local attack
host.http=function(method,url,headers,body)
 if url:find('/node/call',1,true) then
  local req=json.decode(body)
  if attack=='tamper-request' then req.args.model='changed-after-signing';body=json.encode(req) end
  local response=json.decode(raw_http(method,url,headers,body))
  local value=json.decode(response.body or '{}')
  if attack and attack:find('first-',1,true) and req.args.serving_identity_only and value.serving_identity then
   value.serving_identity[attack:sub(7)]='foreign'
  elseif attack=='second-binding' and req.args.serving_identity and value.serving then value.serving.binding=string.rep('b',64)
  elseif attack=='bare-error' and req.args.serving_identity then value={model_error='provider_monthly_quota'}
  elseif attack=='drift' and req.args.serving_identity then value.serving.account_profile='drift-account'
  end
  response.body=json.encode(value);return json.encode(response)
 end
 return raw_http(method,url,headers,body)
end
for _,variant in ipairs({'first-node_id','first-model','first-provider','second-binding','bare-error','drift','tamper-request'}) do
 attack=variant
 local eligible,reason=o.serving_eligible(destination,'fixture','opencode-go')
 check(eligible==true,'real signed route rejects '..variant..' as unknown: '..tostring(reason))
end
attack=nil
check(o.serving_eligible(destination,'fixture')==false,'real default-provider discovery still blocks bound account')
-- Receiver checks requested exact tuple, even with valid signature from caller.
local foreign=json.decode(json.encode(identity));foreign.node_id='foreign-node'
check(nodes.remote_call(destination,'status',{serving_identity=foreign}).serving.state=='unknown','signed foreign target tuple unknown')
foreign=json.decode(json.encode(identity));foreign.provider='foreign-provider'
check(nodes.remote_call(destination,'status',{serving_identity=foreign}).serving.state=='unknown','signed foreign provider tuple unknown')
host.http=raw_http

print('signed two-node serving: '..checks..' checks, 0 skips, 0 paid calls')
