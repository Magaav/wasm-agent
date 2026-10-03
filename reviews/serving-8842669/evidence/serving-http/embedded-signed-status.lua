
local json=dofile('lua/vendor/json.lua');local nodes=dofile('lua/core/nodes.lua');local o=dofile('lua/core/orchestrator.lua')
local destination='d80aa0d48bf13fe771cb462b80b02023'
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
print('signed two-node serving: '..checks..' checks, 0 skips, 0 paid calls')
