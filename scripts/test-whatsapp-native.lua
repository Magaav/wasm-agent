-- Real native Lua -> scoped owned MCP -> real unpaired Go HTTP/SQLite read.
local json=dofile('lua/vendor/json.lua')
local whatsapp=dofile('lua/core/whatsapp.lua')
local cid='200@s.whatsapp.net'
local profile={schema_version=1,id='whatsapp-responder',allowed_tools={'whatsapp_read','whatsapp_send'},resources={allowed_conversations={cid},actions={'read','send'},backend='linked_device',account='100@s.whatsapp.net',generation=1,connector_url=host.getenv('WA_TEST_CONNECTOR_URL'),token_file=host.getenv('WA_TEST_CONNECTOR_TOKEN_FILE'),send_path='linked_device',send_approved=true},limits={context_messages=5,body_bytes=4096,sends_per_run=1}}
local reserved=0
local ctx={role='master',profile=profile,event={conversation_id=cid,message_id='synthetic',sent_at=100},effects={reserve=function()reserved=reserved+1;error('must not reserve')end}}
local read=whatsapp.dispatch({},'whatsapp_read',{},ctx)
assert(not read.error,json.encode(read))
assert(read.conversation_id==cid and read.count==0 and read.coverage=='partial')
assert(read.draft_visibility=='unsupported')
local denied=whatsapp.dispatch({},'whatsapp_read',{conversation_id='foreign'},ctx)
assert(denied.error=='event_conversation_immutable')
local send=whatsapp.dispatch({},'whatsapp_send',{body='not sent',confirm=true},ctx)
assert(send.error=='general_send_refused_draft_visibility_unsupported' and reserved==0)
profile.resources.generation=2
local stale=whatsapp.dispatch({},'whatsapp_read',{},ctx)
assert(stale.ok==false or stale.error,'stale account generation must refuse')
print('whatsapp native linked boundary ok (6 checks)')
