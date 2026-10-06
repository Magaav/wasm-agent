-- Target/request-bound result checks; real ed25519 signing, no network/inference.
local json=dofile('lua/vendor/json.lua')
local nodes=dofile('lua/core/nodes.lua')
local id=json.decode(host.node_identity())
local target={node_id=id.node_id,public_key=id.public_key}
local headers={['X-WA-Ts']=tostring(math.floor(host.now())),['X-WA-Sig']='original-request-signature'}
local reply=json.encode({ok=true,applied=2})
local _,sig=nodes.sign_action('reply',tonumber(headers['X-WA-Ts']),headers['X-WA-Sig']..'\n'..reply)
local envelope=json.encode({reply=reply,reply_sig=sig})
assert(nodes.verified_reply(target,headers,envelope).applied==2)
assert(not nodes.verified_reply(target,headers,'{"ok":true,"applied":2}'))
assert(not nodes.verified_reply(target,headers,json.encode({reply=reply..' ',reply_sig=sig})))
assert(not nodes.verified_reply({node_id='other',public_key=id.public_key},headers,envelope))
assert(not nodes.verified_reply(target,{['X-WA-Ts']=headers['X-WA-Ts'],['X-WA-Sig']='other'},envelope))
local provider=dofile('lua/core/provider.lua')
assert(provider.transient_retries()==0,'new retries are opt-in by default')
print('peer signed reply verification ok (6 checks, 0 skipped)')
