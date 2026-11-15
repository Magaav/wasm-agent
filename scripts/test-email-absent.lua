-- A node whose wa-email service is not stored answers an email question at once, with the working way
-- to read mail, and queues nothing (15/11 replays: email_search sat at 202 'running' for ever); a request
-- missing its essentials is still the validator's refusal first.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local ctx={user_id='master',role='master'}
local r=tools.dispatch(memory,'email_search',{q='fatura'},'master',ctx)
check(r.ok==false and r.error=='email_component_absent' and r.status==404 and tostring(r.note or r.fix):find('mcp_google_imap',1,true),'no stored service: an immediate answer naming the working tools: '..json.encode(r):sub(1,240))
check(r.state=='not_stored' and r.effect=='none','and nothing was queued')
local empty=tools.dispatch(memory,'email_search',{},'master',ctx)
check(empty.error~='email_component_absent','an empty search is the validator refusal first: '..json.encode(empty):sub(1,200))
print(json.encode({ok=true,checks=checks}))
