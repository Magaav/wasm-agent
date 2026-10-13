-- Real SQLite, operations and backend; injected reply loss, never app/provider effects.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup()
local mcp=dofile('lua/core/mcp.lua');local envelope=dofile('lua/core/envelope.lua');local tools=dofile('lua/core/tools.lua')
local root=assert(host.getenv('MCP_TEST_SOURCE'));local phase=assert(host.getenv('MCP_RECOVERY_PHASE'));local home=dofile('lua/core/paths.lua').data()
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local function uncertain()return json.decode(host.sql_query("SELECT key,value FROM meta WHERE key LIKE 'mcp.read_uncertain.v1:%'",'[]'))end
local function config()return json.decode(assert(host.read_file(home..'/recovery-input.json')))end
local function ctx(kind)return {user_id='master',role='master',session_id='recovery-'..kind}end
if phase=='submit' then
 local server={id='recovery',transport='stdio',program=assert(host.getenv('WA_NODE')),args={root..'/scripts/fixtures/mcp-peer.mjs'},env={MCP_TEST_LOG='MCP_TEST_LOG'},tools={echo='read'},timeout_seconds=5}
 local probe=mcp.invoke({action='probe',server=server},ctx('probe'));check(probe.ok and probe.schema_hash,'real probe')
 local input={action='call',server=server,tool='echo',arguments_json='{"value":"fixture"}',read_tools={'echo'},schema_hash=probe.schema_hash,persistent_read=true}
 check(host.write_file(home..'/recovery-input.json',json.encode(input)),'retained config')
 local first=mcp.invoke(config(),ctx('valid'));check(first.ok and first.result_json,'valid read');check(#uncertain()==0,'verified result releases durable reservation')
 local next=mcp.invoke(config(),ctx('valid'));check(next.ok and next.reused,'reuse only after known result');check(#uncertain()==0,'second known result released')
 local original=host.http;local seen=0
 host.http=function(method,url,headers,body)
  local rows=uncertain();check(#rows==1,'reservation exists before actual HTTP submission');check(host.read_file(rows[1].value)~=nil,'reserved exact request retained');seen=seen+1
  local raw=original(method,url,headers,body);local response=json.decode(raw);local request=json.decode(body)
  if seen==1 then response.body=json.encode({request_id=request.request_id});return json.encode(response) end
  error('injected native interruption after backend reply')
 end
 local malformed=mcp.invoke(config(),ctx('malformed'));check(malformed.outcome=='unknown' and malformed.error=='mcp_result_artifact_unverified','malformed acknowledgement held, not Lua nil dereference')
 check(#uncertain()==1,'malformed read held durably');check(mcp.invoke(config(),ctx('malformed')).error=='mcp_connection_uncertain','same-VM no replay')
 -- Second owner adds one marker, so adapt the before-submit assertion without weakening it.
 host.http=function(method,url,headers,body)
  local rows=uncertain();check(#rows==2,'second owner durable before HTTP');local raw=original(method,url,headers,body);check(json.decode(raw).status==200,'actual backend completed before injected loss');error('injected native interruption after backend reply')
 end
 local lost=mcp.invoke(config(),ctx('interrupted'));check(lost.outcome=='unknown' and lost.error=='mcp_session_reply_unverified','lost reply held');check(#uncertain()==2,'both unknowns held')
 host.http=original
 local closed=mcp.close_read_sessions();check(#closed==3,'three owned sessions cleanup observed')
 for _,r in ipairs(closed)do check(r.settled and r.settled.settled,'owned process tree drained') end
 local sid=memory.start_session('','restart-definition',{user_id='master'});local context={session_id=sid,user_id='master',role='master'}
 check(envelope.search(tools.all('master'),{query='web_read',limit=1},context).loaded==1,'definition persisted before restart')
 check(host.write_file(home..'/recovery-context.json',json.encode(context)),'restart context retained')
elseif phase=='reopen' then
 check(#uncertain()==2,'native process restart preserves both unknowns')
 local original=host.http;local issued=0;host.http=function(...)issued=issued+1;return original(...)end
 for _,kind in ipairs({'malformed','interrupted'})do local answer=mcp.invoke(config(),ctx(kind));check(answer.error=='mcp_connection_uncertain' and answer.outcome=='not_submitted','new native process refuses replay '..kind) end
 check(issued==0,'no HTTP issued on reconstruction');check(#mcp.close_read_sessions()==0,'no backend operation started for uncertain owners');check(#uncertain()==2,'unknown originals unchanged')
 host.http=original
 local context=json.decode(assert(host.read_file(home..'/recovery-context.json')));local catalog=tools.all('master')
 check(envelope.resolve(catalog,'web_read',context)~=nil,'exact loaded contract survives native restart')
 for _,item in ipairs(catalog)do if item['function'].name=='web_read' then item['function'].description=item['function'].description..' changed' end end
 local _,err=envelope.resolve(catalog,'web_read',context);check(err and err:find('definition_changed',1,true),'changed contract refused after restart')
else error('invalid recovery phase') end
print('mcp recovery '..phase..' ok ('..checks..' checks)')
