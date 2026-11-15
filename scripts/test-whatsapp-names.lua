-- A chat name works wherever a WhatsApp read takes a chat, resolved once through contacts (the most
-- recent of equal names), and the answer says what it became; a send never resolves a name (14/11).
local json=dofile('lua/vendor/json.lua')
local wa=dofile('lua/core/whatsapp.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local asked={}
local real_route,real_invoke=wa.route,wa.invoke
wa.route=function() return nil end
wa.invoke=function(tool,args) asked[#asked+1]={verb=tool.verb,args=args}
 if tool.verb=='contacts' then
  if args.q=='Laura' then return {ok=true,chat='111@lid',picked='most_recent',candidates={{chat='111@lid'},{chat='222@lid'}}} end
  return {ok=true,count=0,candidates={}}
 end
 if tool.verb=='search' then return {ok=true,hits={{chat=args.chat}},count=1} end
 return {ok=true} end
local r=wa.call('search',{chat='Laura',q='oi'},{})
check(r.ok and r.hits[1].chat=='111@lid','search by name searched the resolved chat: '..json.encode(r))
check(r.resolved_chat and r.resolved_chat.asked=='Laura' and r.resolved_chat.chat=='111@lid' and r.resolved_chat.picked=='most_recent','and says what the name became: '..json.encode(r.resolved_chat))
r=wa.call('search',{chat='Nobody'},{})
check(r.ok==false and r.error=='whatsapp_chat_not_found' and r.status==404,'an unknown name is a 404 with the way on: '..json.encode(r))
asked={}
r=wa.call('search',{chat='111@lid',q='x'},{})
check(#asked==1 and asked[1].verb=='search','an exact JID is not looked up')
wa.route,wa.invoke=real_route,real_invoke
-- the script's return value reaches the model as an object named `returned`
local out=dofile('lua/core/tool_output.lua')
local view=out.parse_view(out.project('codemode',{ok=true,status=200,summary='search 200',value='{"hits":[1,2]}',attempts={},calls={}}))
local raw_view=out.project('codemode',{ok=true,status=200,summary='search 200',value='{"hits":[1,2]}',attempts={},calls={}})
check(type(view.returned)=='table' and #view.returned.hits==2 and not raw_view:find('"returned"',1,true) and not raw_view:find('"value"',1,true),'the model sees exactly what the script returned, no wrapper key: '..raw_view:sub(1,200))
-- multi-line text a script returned reaches the model raw, with one header line (no \n or \" escapes)
local text_view=out.project('codemode',{ok=true,status=200,summary='bash 200',value=json.encode('line one\nline "two"'),attempts={},
  calls={{id=1,name='bash',ok=true,status=200,evidence={path='/x/ab.txt',sha256='ab',bytes=5}}}})
check(text_view:match('^status 200 \194\183 bash 200 \194\183 full_result %x+\ncalls: ab:5\n\nline one\nline "two"$'),'multi-line text is raw under the header and the evidence line: '..text_view:sub(1,160))
local parsed=out.parse_view(text_view)
check(parsed and parsed.status==200 and parsed.returned=='line one\nline "two"' and parsed.summary=='bash 200','and the one reader reads it back')
-- the evidence the model gets is the hash and size, not the path, id or ok
local obj_view=out.parse_view(out.project('codemode',{ok=true,status=200,summary='bash 200',value='{"a":1}',attempts={},
  calls={{id=1,name='bash',ok=true,status=200,evidence={path='/x/ab.txt',sha256='ab',bytes=5}}}}))
local c1=obj_view.calls[1]
check(c1.sha256=='ab' and c1.bytes==5 and c1.status==200 and c1.evidence==nil and c1.id==nil and c1.ok==nil,'evidence is sha256 + bytes: '..json.encode(c1))
print(json.encode({ok=true,checks=checks}))
