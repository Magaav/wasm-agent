-- Current WhatsApp facade: scope/approval retained; no browser or general-send route.
local whatsapp=dofile('lua/core/whatsapp.lua')
local n=0
local function check(value,label) n=n+1;assert(value,label) end
local cid='200@s.whatsapp.net'
local profile={schema_version=1,id='whatsapp-responder',allowed_tools={'whatsapp_read','whatsapp_decide','whatsapp_send'},resources={allowed_conversations={cid},actions={'read','send'},account='100@s.whatsapp.net',send_path='linked_device',send_approved=true},limits={body_bytes=4096,sends_per_run=1,context_messages=5}}
local reservations,sends=0,0
local ctx={profile=profile,event={conversation_id=cid,message_id='fixture',sent_at=100,observed_at=100},effects={reserve=function() reservations=reservations+1;error('must not reserve') end},send=function() sends=sends+1;error('must not send') end}
local memory={conversation=function(id,limit)return {{message_id='fixture',conversation_id=id,body='synthetic'}}end,conversation_record=function(id)return {id=id,title='fixture',kind='direct'}end}
local function call(args)return whatsapp.dispatch(memory,'whatsapp_send',args or {body='fixture',confirm=true},ctx)end
check(call().error=='general_send_refused_draft_visibility_unsupported','draft visibility unknown is not permission')
profile.resources.send_path='store'
check(call().error=='browser_whatsapp_retired','old profile cannot revive browser route')
profile.resources.send_path='ui'
check(call().error=='ui_input_route_retired','no simulated input')
profile.resources.send_path='linked_device'
check(call({conversation_id='foreign',body='fixture',confirm=true}).error=='event_conversation_immutable','trusted event scope retained')
profile.resources.send_approved=false
check(call().error=='send_not_approved','approval retained')
profile.resources.send_approved=true
profile.resources.actions={'read'}
check(call().error=='action_not_in_profile','capability retained')
profile.resources.actions={'read','send'}
check(call({body='fixture',confirm=false}).error=='confirm_required','explicit confirmation retained')
ctx.event={}
check(call().error=='event_context_required','trusted event required')
ctx.event={conversation_id=cid,message_id='fixture',sent_at=100}
profile.resources.allowed_conversations={'other'}
check(call().error=='conversation_not_in_profile','profile scope retained')
profile.resources.allowed_conversations={cid}
profile.allowed_tools={'whatsapp_read','whatsapp_decide'}
check(call().error=='tool_not_in_profile','current read-only profile blocks sends')
check(reservations==0 and sends==0,'retired route refuses before effect budget or external dispatch')
local event=whatsapp.trusted_event({conversation_id='injected',message_id='injected'})
check(event.conversation_id=='','arguments cannot forge trusted event')
print('whatsapp scoped retirement ok ('..n..' checks)')
