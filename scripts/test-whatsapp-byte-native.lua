-- Actual scoped native facade -> MCP -> Go byte page/chunk, no real account.
local w=dofile('lua/core/whatsapp.lua')
local cid='200@s.whatsapp.net'
local p={schema_version=1,id='whatsapp-responder',allowed_tools={'whatsapp_read'},resources={backend='linked_device',account='100@s.whatsapp.net',generation=1,allowed_conversations={cid},actions={'read'},connector_url=host.getenv('WA_TEST_CONNECTOR_URL'),token_file=host.getenv('WA_TEST_CONNECTOR_TOKEN_FILE')},limits={context_messages=1}}
local ctx={role='master',profile=p,event={conversation_id=cid,message_id='synthetic'}}
local page=w.dispatch({},'whatsapp_read',{limit=1},ctx)
assert(not page.error and page.rows_delivered==1 and page.count==0)
assert(page.page_version==2 and page.inline_complete==false and #page.oversized_rows==1)
assert(page.order[1].kind=='oversized' and page.encoded_bytes<=page.byte_limit)
local d=page.oversized_rows[1]
local field=w.dispatch({},'whatsapp_read',{row=d.row,field='body',version=d.fields.body.field_version,offset=0,length=16384},ctx)
assert(field.ok==true and field.complete==true and field.content_encoding=='base64')
assert(field.data_base64==host.getenv('WA_TEST_EXPECTED_BODY_BASE64'))
local foreign=w.dispatch({},'whatsapp_read',{conversation_id='300@s.whatsapp.net',row=d.row,field='body',version=d.fields.body.field_version},ctx)
assert(foreign.error=='event_conversation_immutable')
print('whatsapp byte native ok (6 checks)')
