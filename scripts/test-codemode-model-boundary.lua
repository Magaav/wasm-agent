-- TRUE model boundary: actual agent -> redaction -> projection/storage -> next
-- mock provider request + serialized SSE + session projection. No network/model.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local env=host.getenv
local secret='fixture_private_value_79a0f12e_not_a_real_credential'
local short_secret='fxt12345' -- 8 bytes -> 10-byte mask; exercises post-redaction expansion
host.getenv=function(k)
 if k=='WASM_AGENT_CODEMODE' then return 'native' end
 if k=='WASM_AGENT_LLM_API_KEY' then return secret end
 if k=='OPENAI_API_KEY' then return short_secret end
 if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
 if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
 return env(k)
end
host.http=function()error('network forbidden')end;host.http_stream=host.http
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local provider=dofile('lua/core/provider.lua')
local original=dofile
local baseline=env('WA_BOUNDARY_OLD_VIEW')
dofile=function(p)
 if p=='lua/core/tools.lua' then return tools end
 if p=='lua/core/provider.lua' then return provider end
 if p=='lua/core/codemode_view.lua' and baseline and baseline~='' then return assert(load(assert(host.read_file(baseline))))() end
 return original(p)
end
local agent=original('lua/core/agent.lua')
local output=original('lua/core/tool_output.lua')
local redact=original('lua/core/redact.lua')
local root=original('lua/core/paths.lua').data()..'/boundary-work'
local checks=0;local measurements={};local tool_rows={};local write_count=0
local function check(v,label)assert(v,label);checks=checks+1 end
local function safe(text,label)check(not text:find(secret,1,true) and not text:find(short_secret,1,true),label..': no configured value')end
local function save(name,text)assert(host.write_file(original('lua/core/paths.lua').data()..'/'..name,text))end
local function raw(ref)local text=assert(host.read_file(ref.path));check(host.sha256(text)==ref.sha256,'exact retained original hash');return text end
local function parse(text)return assert(contract.parse(text))end
local function at(node,path)return assert(contract.at(node,path))end
local function clean_text(text)return (text:gsub(secret,'<redacted>'):gsub(short_secret,'<redacted>'))end
local dispatch=tools.dispatch
local huge={ok=false,failed=1,note='LAST METADATA CAVEAT '..secret,complete=false,results={
 {content=secret..string.rep('\\"🐋',8000),selection='fixture-exact-frame',version='fixture-version',edit_lines={start_line=1,end_line=1}},
 {error='late refusal '..secret,effect='none',metadata={sensitive=secret}},
 {type='image',source='authored-nontext-reference',metadata={sensitive=secret}}
}}
tools.dispatch=function(m,n,a,r,c)
 if n=='write' then write_count=write_count+1 end
 if n=='read' and a.path=='typed-fixture' then
  return contract.materialize(parse('{"ok":true,"data":{"null":null,"object":{},"array":[],"nested":[null,{},[],false,0]},"metadata":{"sensitive":'..json.encode(secret)..','..json.encode(secret)..':"authored secret-key value","caveat":"LAST TYPED CAVEAT"}}'))
 elseif n=='read' and a.path=='collision-fixture' then
  return contract.materialize(parse('{"ok":true,"data":{'..json.encode(secret)..':1,'..json.encode(short_secret)..':2}}'))
 elseif n=='read' and a.path=='refused-fixture' then return {ok=false,error='private refusal '..secret,effect='none',metadata={sensitive=secret}}
 elseif n=='read' and a.path=='unknown-fixture' then error('private unknown '..secret)
 elseif n=='read_many' and a.requests and a.requests[1].path=='oversize-fixture' then return huge
 elseif n=='read_many' and a.requests and a.requests[1].path=='expansion-fixture' then return {ok=true,note=short_secret,results={{content=string.rep(short_secret,5400),eof=true,selection='expansion-frame',version='expansion-version',edit_lines={start_line=1,end_line=1}}}} end
 return dispatch(m,n,a,r,c)
end
local function run(name,tool,args,verify,saved_sid)
 local sid=saved_sid or memory.start_session('','model boundary '..name,{user_id='master'})
 if not saved_sid then memory.set_session_workspace(sid,{required=true,state='allocated',worktree=root}) end
 local ctx={session_id=sid,user_id='master',role='master'}
 local rounds=0;local observed;local content;local events={}
 provider.complete_with=function(_,messages)
  rounds=rounds+1
  local request=json.encode(messages);safe(request,name..' actual provider messages')
  save(name..'-request-'..rounds..'.json',request)
  if rounds==1 then return {content='',finish_reason='tool_calls',tool_calls={{id='boundary-'..name,type='function',['function']={name=tool,arguments=json.encode(args)}}}} end
  check(rounds==2,'exact two mock rounds, no effect replay')
  for _,message in ipairs(messages)do if message.role=='tool' and message.tool_call_id=='boundary-'..name then content=message.content;observed=json.decode(content) end end
  check(observed~=nil,name..' provider tool message exists')
  check(#content<=output.MAX_BYTES,name..' FINAL encoded projected tool content budget')
  measurements[#measurements+1]={name=name,tool_content_bytes=#content,serialized_provider_messages_bytes=#request}
  save(name..'-observed.json',content)
  verify(observed,parse(content),ctx)
  return {content='BOUNDARY-DONE',finish_reason='stop',tool_calls={}}
 end
 local bot=agent.new(sid,function(event)
  local encoded=json.encode(event);safe(encoded,name..' serialized SSE event');events[#events+1]=encoded
 end,'master','master','')
 check(bot:run('Execute the private authored '..name..' fixture')=='BOUNDARY-DONE',name..' actual agent completed')
 check(rounds==2,name..' no extra inference rounds')
 local sse_tool,sse_text
 for _,encoded in ipairs(events)do
  local event=json.decode(encoded)
  if event.type=='tool_result' and event.name==tool then
   sse_text=contract.raw(encoded,at(parse(encoded),{'result'}));sse_tool=json.decode(sse_text)
  end
 end
 check(sse_tool~=nil,name..' SSE tool event present')
 -- Assert the EXACT serialized SSE JSON, not lossy ordinary json.decode/re-encode.
 if tool=='codemode' then verify(sse_tool,parse(sse_text),ctx) end
 save(name..'-sse.json','['..table.concat(events,',')..']')
 local row
 for _,message in ipairs(memory.session_messages(sid,{limit=100}))do if message.role=='tool' and message.tool_call_id=='boundary-'..name then row=message end end
 check(row and row.content==content,name..' stored tool row matches provider content')
 safe(json.encode(row),name..' stored row')
 -- Use the real exact session-tool projection rather than inspecting SQLite only.
 local session_parts,session_pages={},{};local session_offset=1;local session_version
 while true do
  local selected=dispatch(memory,'session',{session_id=sid,message_id=row.id,view='tool_calls',byte_offset=session_offset,byte_limit=output.MAX_BYTES-2048,message_version=session_version},'master',ctx)
  local projected=output.project('session',redact.value(selected));safe(projected,name..' session projection')
  local page=json.decode(projected);check(not page.error and page.content and page.next_offset>session_offset,name..' exact session projection advances')
  session_parts[#session_parts+1]=page.content;session_pages[#session_pages+1]=page
  session_offset=page.next_offset;session_version=page.message_version;if page.eof then break end
 end
 local session_content=json.decode(table.concat(session_parts)).content
 check(session_content==content,name..' session projected tool content preserved')
 if tool=='codemode' then verify(json.decode(session_content),parse(session_content),ctx) end
 save(name..'-session.json',json.encode(session_pages))
 tool_rows[#tool_rows+1]={sid=sid,id=row.id,content=content}
 return observed,ctx
end
local function code(name,source,verify,sid)return run(name,'codemode',{code=source},verify,sid)end
if env('WA_BOUNDARY_PHASE')=='restart' then
 local sid=assert(memory.meta_get('boundary-cached-session'));local cursor=assert(memory.meta_get('boundary-cached-cursor'))
 code('restart','await tools.read_many({cursor:'..json.encode(cursor)..'}); await showCall({version:1,call:1});',function(r)
  check(r.ok and r.shown[1].complete and r.shown[1].result.results[1].content:find('FINAL DOC4 CAVEAT',1,true),'restart captured last caveat visible after all boundaries')
  check(r.shown[1].result.results[1].content:find('<redacted>',1,true)~=nil,'restart captured content still sanitized')
 end,sid)
 save('restart-measurements.json',json.encode(measurements));print(json.encode({ok=true,checks=checks,paid_calls=0,phase='restart'}));return
end
-- First test reproduces the installed empty-array defect with old source.
local small=root..'/small.txt';local smalltext='# Authored presentation 🐋\n'..secret..'\nEND SMALL CAVEAT\nnext source line\n'
assert(host.write_file(small,smalltext))
code('small','await tools.read_many({requests:[{path:"small.txt",offset:1,limit:3}]}); await showCall({version:1,call:1});',function(r,t)
 local shown=r.shown and r.shown[1]
 check(shown and shown.result and shown.result.results and shown.result.results[1] and shown.result.results[1].content,'MODEL_BOUNDARY_CONTENT_REQUIRED: complete must not display empty or missing data')
 check(r.ok and shown.complete and not shown.result.results[1].eof,'complete result is not falsely file EOF')
 local original_result=json.decode(raw(r.calls[1].evidence));local item=shown.result.results[1];local original_item=original_result.results[1]
 check(item.content==clean_text(original_item.content) and item.content:find('END SMALL CAVEAT',1,true),'all authored visible source including caveat')
 check(item.selection==original_item.selection and item.version==original_item.version and json.encode(item.edit_lines)==json.encode(original_item.edit_lines),'actionable selection/source version/edit frame unchanged')
 check(at(t,{'shown',1,'result'}).kind=='object' and at(t,{'shown',1,'result','results'}).kind=='array','real model-facing object/array shapes')
 check(r.presentation_sanitized and r.presentation_redacted,'honest sanitized view vs unchanged private original')
 check(raw(r.calls[1].evidence):find(secret,1,true)~=nil,'original still exact/private, not rewritten by redaction')
end)
code('typed','await tools.read({path:"typed-fixture"}); await showCall({version:1,call:1});',function(r,t)
 check(r.shown[1].result.metadata.caveat=='LAST TYPED CAVEAT' and r.shown[1].result.metadata.sensitive=='<redacted>','nested metadata traversed/sanitized')
 check(r.shown[1].result.metadata['<redacted>']=='authored secret-key value' and r.presentation_key_redacted,'selected secret-bearing JSON keys sanitized too')
 for key,kind in pairs({null='null',object='object',array='array',nested='array'})do check(at(t,{'shown',1,'result','data',key}).kind==kind,'post-boundary typed '..key)end
 for i,kind in ipairs({'null','object','array','boolean','number'})do check(at(t,{'shown',1,'result','data','nested',i}).kind==kind,'post-boundary nested shape '..i)end
end)
code('collision','await tools.read({path:"collision-fixture"}); await showCall({version:1,call:1});',function(r)
 check(not r.ok and r.presentation_partial and not r.shown and r.presentation_error:find('key_collision',1,true),'redacted key collision refuses visibly, never complete empty data')
 check(#r.calls==1 and raw(r.calls[1].evidence):find(secret,1,true)~=nil,'collision original retained without replay')
end)
code('caught','try { await tools.read({path:"refused-fixture"}); } catch (_) {} await showCall({version:1,call:1});',function(r)
 local value=r.shown[1].result;check(r.ok and not r.calls[1].ok and value.effect=='none' and value.error=='private refusal <redacted>','caught native failure visible and sanitized')
end)
-- Several whole docs, then ordinary cached continuation from the same session.
local docs={};local contents={}
for i=1,4 do contents[i]=string.rep('\\"\t café 🐋\n',650)..secret..' FINAL DOC'..i..' CAVEAT\n';assert(host.write_file(root..'/doc'..i..'.txt',contents[i]));docs[i]={path='doc'..i..'.txt',limit=2000}end
local captured,docctx=code('docs','await tools.read_many('..json.encode({requests=docs})..'); await showCall({version:1,call:1});',function(r)
 local page=r.shown[1].result;check(r.shown[1].complete and page.next_cursor and page.last_index==3 and page.total==4,'honest captured-page and unread batch coverage')
 for i,item in ipairs(page.results)do check(item.content==clean_text(contents[i]) and item.eof and item.selection~=nil,'whole authored doc/frame visible '..i)end
end)
local cursor=captured.shown[1].result.next_cursor
memory.meta_set('boundary-cached-session',docctx.session_id);memory.meta_set('boundary-cached-cursor',cursor)
for i=1,4 do assert(host.write_file(root..'/doc'..i..'.txt','changed live file'))end
code('cached','await tools.read_many({cursor:'..json.encode(cursor)..'}); await showCall({version:1,call:1});',function(r)
 local page=r.shown[1].result;check(page.complete and not page.next_cursor and #page.results==1 and page.results[1].content==clean_text(contents[4]),'cached captured final doc/caveat, no changed-source refetch')
end,docctx.session_id)
code('expansion','await tools.read_many({requests:[{path:"expansion-fixture"}]}); await showCall({version:1,call:1});',function(r)
 check(r.calls[1].evidence.bytes<output.MAX_BYTES and r.presentation_partial and not r.shown[1].complete and not r.shown[1].coverage[1].visible,'budget measures FINAL sanitized expansion, not fitting raw bytes')
 check(r.shown[1].metadata.note=='<redacted>' and r.presentation_redacted,'short configured secret sanitized in partial metadata')
end)
local partial,partialctx=code('partial','try { await tools.read_many({requests:[{path:"oversize-fixture"}]}); } catch (_) {} await showCall({version:1,call:1});',function(r)
 local shown=r.shown[1]
 check(r.presentation_partial and not shown.complete and not r.calls[1].ok,'oversized failed capture honestly partial after boundary')
 check(shown.metadata.note=='LAST METADATA CAVEAT <redacted>' and shown.coverage[2].error=='late refusal <redacted>' and shown.coverage[2].effect=='none','late caveat/error/effect survives normal boundaries')
 check(#shown.coverage==3 and not shown.coverage[1].visible and shown.coverage[1].unread.offset>0,'all unread slots/ranges explicit')
end)
-- Retrieve the original using the REAL agent/tool_result boundary. Raw artifact
-- and byte offsets remain exact; displayed text is subject to normal redaction.
local ref=partial.calls[1].evidence;local original_bytes=raw(ref);local reads=0
for slot_index,slot in ipairs(partial.shown[1].coverage)do
 local range=assert(slot.unread);local expected=original_bytes:sub(range.offset,range.offset+range.bytes-1)
 local pieces={};local offset=range.offset;local last=offset+range.bytes
 while offset<last do
  local remain=last-offset;local original_page=output.read(range.sha256,offset,math.min(51200,remain))
  local visible=run('recover'..reads,'tool_result',{sha256=range.sha256,offset=offset,limit=math.min(51200,remain)},function(r)
   check(r.content==clean_text(original_page.content) and r.next_offset==original_page.next_offset,'native original retrieval sanitized with original byte continuation')
   if slot_index==3 then check(r.content:find('authored-nontext-reference',1,true) and r.content:find('"type":"image"',1,true),'actual model receives recovered nontext reference, not an empty value')end
  end)
  pieces[#pieces+1]=original_page.content:sub(1,remain);offset=visible.next_offset;reads=reads+1
 end
 check(table.concat(pieces)==expected and host.sha256(raw(ref))==ref.sha256,'whole original range recovered unchanged; sanitized display distinct')
end
local before=write_count
code('partial-effect','await tools.write({path:"once.txt",content:"one"}); await showCall({version:1,call:1}); try { await tools.read({path:"unknown-fixture"}); } catch (_) {} await showCall({version:1,call:2}); throw new Error("later fixture failure");',function(r)
 check(not r.ok and #r.calls==2 and r.shown[1].complete and r.shown[2].result.effect=='unknown' and r.shown[2].result.replay_allowed==false,'earlier effect/later unknown and script failure stay explicit')
 check(r.shown[2].result.error:find('<redacted>',1,true)~=nil,'selected unknown failure is sanitized')
end)
check(write_count==before+1 and host.read_file(root..'/once.txt')=='one','actual write once; no automatic replay')
-- Local compatibility/privacy checks for the minimal shared serialization seam.
local ordinary={plain={a='x'},empty={},value=secret};local cleaned=redact.value(ordinary)
check(json.encode(cleaned)==json.encode({plain={a='x'},empty={},value='<redacted>'}) and ordinary.value==secret,'ordinary copy/redaction unchanged and input untouched')
local disguised=setmetatable({value=secret},{__json_empty='null'})
check(json.encode(redact.value(disguised))=='{"value":"<redacted>"}','nonempty shape tag cannot hide data')
local opaque=setmetatable({}, {__json_raw='{"hidden":'..json.encode(secret)..'}'})
check(json.encode(redact.value(opaque))=='[]','arbitrary opaque raw metatable is NOT preserved')
local typed=contract.materialize(parse('{"n":null,"o":{},"a":[],"s":'..json.encode(secret)..'}'))
for _=1,3 do typed=redact.value(typed)end
local typed_tree=parse(json.encode(typed));check(at(typed_tree,{'n'}).kind=='null' and at(typed_tree,{'o'}).kind=='object' and at(typed_tree,{'a'}).kind=='array' and typed.s=='<redacted>','repeated privacy boundaries preserve only safe typed shapes')
check(not contract.parse('{"a":1,"a":2}') and not contract.parse('{"a":1e9999}'),'strict raw evidence validation unchanged')
save('boundary-measurements.json',json.encode({measurements=measurements,artifact_retrievals=reads,write_calls=write_count,paid_calls=0}))
save('tool-rows.json',json.encode(tool_rows));safe(json.encode(tool_rows),'all collected stored tool rows')
local telemetry=original('lua/core/telemetry.lua');local logs={}
for _,row in ipairs(tool_rows)do
 local log=telemetry.events(row.sid,0,1000);safe(json.encode(log),'actual telemetry/tool logs');logs[#logs+1]=log
end
save('tool-logs.json',json.encode(logs))
print(json.encode({ok=true,checks=checks,artifact_retrievals=reads,write_calls=write_count,paid_calls=0,phase='seed'}))
