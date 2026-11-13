-- Model-free native presentation proof; private files and SQLite only.
--
-- Two surfaces, because the retirement of the `*_many` tools moved the paged batch rather than removing
-- it: `tool_call({calls:[...]})` is the OUTER batch (1-8 known reads in one call, paged with a cached
-- `next_cursor`), and a script's batch is its own `Promise.all` - a script value, not a native page. So
-- the cursor/fence/integrity half of this row drives the routed batch, and the presentation half drives
-- what `showCall` still has to present: any native result, including one that carries a `results` array.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return 'native' end;return getenv(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
if getenv('WA_PRESENTATION_PHASE')=='restart' then
 local sid=assert(memory.meta_get('presentation-session'))
 local r=tools.dispatch(memory,'tool_call',{cursor=assert(memory.meta_get('presentation-cursor'))},'master',{session_id=sid,user_id='master',role='master'})
 assert(not r.error and r.results[1].content:find('CONSEQUENTIAL FINAL CAVEAT',1,true),'restart resumes original cached documents')
 print(json.encode({ok=true,checks=1,paid_calls=0}));return
end
local output=dofile('lua/core/tool_output.lua')
local sid=memory.start_session('','presentation fixture',{user_id='master'})
local ctx={session_id=sid,user_id='master',role='master'}
local root=dofile('lua/core/paths.lua').data()..'/work'
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local function call(code)return tools.dispatch(memory,'codemode',{code=code},'master',ctx)end
local function raw(ref)local s=assert(host.read_file(ref.path));check(host.sha256(s)==ref.sha256,'exact original hash');return s end
local function keep(name,value)assert(host.write_file(dofile('lua/core/paths.lua').data()..'/'..name,json.encode(value)))end
local text=string.rep('\\"\t café 🐋\n',650)..'CONSEQUENTIAL FINAL CAVEAT: do not publish.\n'
local requests={}
for i=1,8 do local p=root..'/doc'..i..'.txt';assert(host.write_file(p,text));requests[i]={path=p,limit=2000} end
local calls={}
for _,request in ipairs(requests) do calls[#calls+1]={name='read',arguments=request} end

-- 1. The routed batch pages itself: whole items, in request order, with a cached continuation.
local batch=tools.dispatch(memory,'tool_call',{calls=calls},'master',ctx)
check(type(batch)=='table' and batch.next_cursor~=nil,'a batch over the view budget answers a cached next_cursor')
check(batch.first_index==1 and batch.has_more==true and batch.total==8,'the page names its own bounds and total')
for _,item in ipairs(batch.results)do check(item.content==text and item.eof and item.selection and item.edit_lines,'page item complete source/edit frame and final caveat')end
local reference=batch.full_result
check(reference and reference.sha256 and host.read_file(reference.path)~=nil,'the complete batch original is retained')
-- Continue through the cache, after the live files changed: a cached page is evidence, not a refetch.
for _,request in ipairs(requests)do assert(host.write_file(request.path,'changed after capture'))end
local covered=#batch.results
local cursor=batch.next_cursor
while cursor do
 local page=tools.dispatch(memory,'tool_call',{cursor=cursor},'master',ctx)
 check(not page.error,'cached continuation accepted')
 for _,item in ipairs(page.results)do
  check(item.content==text and item.eof and item.selection,'cached full document, not the changed live file')
  covered=covered+1
 end
 cursor=page.next_cursor
end
check(covered==8,'all eight document results covered by the cache: '..covered)
-- 2. The continuation is fenced by the scope it was written for.
check(tools.dispatch(memory,'tool_call',{cursor=batch.next_cursor},'master',{session_id=sid,user_id='other'}).error~=nil,'changed account refused')
check(tools.dispatch(memory,'tool_call',{cursor=batch.next_cursor},'guest',ctx).error~=nil,'changed role refused')
check(tools.dispatch(memory,'tool_call',{cursor=batch.next_cursor},'master',{session_id=sid,user_id='master',subagent={allowed={read=true,tool_call=true}}}).error~=nil,'changed profile refused')
local bound={session_workspace=function()return {required=true,state='allocated',worktree=root}end}
check(tools.dispatch(bound,'tool_call',{cursor=batch.next_cursor},'master',ctx).error=='batch_cursor_scope_changed','changed workspace refused')
-- 3. A damaged original refuses visibly instead of answering an empty page.
local cache=raw(reference)
assert(host.write_file(reference.path,cache..'CORRUPT'))
check(tools.dispatch(memory,'tool_call',{cursor=batch.next_cursor},'master',ctx).error=='batch_snapshot_changed','corrupt cache refuses, not empty success')
assert(host.write_file(reference.path,cache)) -- restored deliberately, for the restart proof
memory.meta_set('presentation-cursor',batch.next_cursor)
memory.meta_set('presentation-session',sid)

-- 4. Presentation of a script's own call: a big single read, `text` versus `showCall`. The live file is
-- restored first: the cache above proved it answers the CAPTURED bytes, and this step reads live bytes.
local big=root..'/doc1.txt'
assert(host.write_file(big,text))
local script='await tools.read('..json.encode({path=big,limit=2000})..'); await showCall({version:1,call:1});'
local r=call(script)
check(r.ok and r.presentation_version==1,'actual native helper available')
check(#r.calls==1 and #r.attempts==2,'one native call, one pure presentation request')
local captured=json.decode(raw(r.calls[1].evidence))
check(captured.content==text and captured.eof and captured.selection and captured.edit_lines,'the presented read is the whole source with its receipt')
local old=call('text(await tools.read('..json.encode({path=big,limit=2000})..'));')
local oldbytes=#json.encode(old);local newbytes=#json.encode(r)
local oldcontent=output.project('codemode',old);local newcontent=output.project('codemode',r)
keep('comparison.json',{old_tool_content_bytes=#oldcontent,old_unprojected_bytes=oldbytes,new_tool_content_bytes=#newcontent,new_unprojected_bytes=newbytes,
 old_model_message_bytes=#json.encode({role='tool',tool_call_id='fixture',content=oldcontent}),new_model_message_bytes=#json.encode({role='tool',tool_call_id='fixture',content=newcontent}),
 measurement='Exact serialized tool-message fixture, not a complete provider request, tokens, billing or quality.',native_calls=#r.calls,paid_calls=0,
 batch_page={first=batch.first_index,last=batch.last_index,total=batch.total}})
check(#output.project('codemode',r)<=output.MAX_BYTES,'actual encoded model-facing size fits')
-- A partial presentation names exact unread ranges, and `tool_result` recovers them.
local payload={ok=false,failed=1,results={{content=string.rep('\\"🐋',8000),selection='exact receipt',edit_lines={start_line=1,end_line=1},version='v'}, {error='consequential refusal',effect='none'}, {type='image',image={id='private-fixture-image',mime='image/png'},source='private-fixture',note='Nontext reference, not rendered image output'}},note='LATE CAVEAT',next_cursor='existing-cursor',complete=false}
local view=dofile('lua/core/codemode_view.lua')
local ref=output.store(json.encode(payload))
r=view.finish({ok=true,calls={{name='remote',evidence=ref}},attempts={},items={}}, {1})
check(r.presentation_partial and #json.encode(r)<=output.MAX_BYTES,'encoded overflow is explicit and bounded')
local shown=r.shown[1];local decoded=json.decode(json.encode(shown))
check(decoded.metadata.note=='LATE CAVEAT' and decoded.metadata.next_cursor=='existing-cursor','late metadata and cached continuation retained')
check(decoded.coverage[2].error=='consequential refusal' and decoded.coverage[2].effect=='none','unread failure/effect stays visible')
local retrievals=0
for i,slot in ipairs(shown.coverage)do
 if slot.visible then check(json.encode(shown.results[i])==json.encode(payload.results[i]),'whole visible item exact')
 else
  local range=slot.unread;local offset=range.offset;local last=offset+range.bytes;local pieces={}
  while offset<last do
   local page=tools.dispatch(memory,'tool_result',{sha256=range.sha256,offset=offset,limit=math.min(51200,last-offset)},'master',ctx)
   retrievals=retrievals+1;check(not page.error and page.next_offset>offset,'bounded native original retrieval advances')
   pieces[#pieces+1]=page.content:sub(1,last-offset);offset=page.next_offset
  end
  check(table.concat(pieces)==json.encode(payload.results[i]),'native tool_result retrieval recovers exact source/edit frame or failure')
 end
end
keep('boundary-retrieval.json',{artifact_retrievals=retrievals,partial=true,source_ref=ref,coverage=shown.coverage})
-- 5. Typed survivors and a corrupt original.
local typed='{"results":[{"value":null,"object":{},"array":[]},{"error":"binary","effect":"none"}],"ok":false,"late":null}'
local typedref=output.store(typed)
local typedview=view.finish({ok=true,calls={{name='remote',evidence=typedref}}},{1})
local typed_tree=assert(dofile('lua/core/json_contract.lua').parse(json.encode(typedview.shown[1].result)))
check(dofile('lua/core/json_contract.lua').at(typed_tree,{'results',1,'value'}).kind=='null' and dofile('lua/core/json_contract.lua').at(typed_tree,{'results',1,'object'}).kind=='object' and dofile('lua/core/json_contract.lua').at(typed_tree,{'results',1,'array'}).kind=='array' and host.read_file(typedref.path)==typed,'typed shapes survive in model view; original bytes stay exact')
assert(host.write_file(typedref.path,typed..'broken'))
local intact,problem=pcall(view.finish,{ok=true,calls={{name='remote',evidence=typedref}}},{1})
check(not intact and tostring(problem):find('evidence_changed',1,true),'corrupt presentation original refuses visibly')
local help=call('return await describeTool("showCall");')
check(help.ok and json.decode(help.value).version==1,'helper guidance available on demand')
local caught=call('try { await tools.read({path:'..json.encode(root..'/missing-file')..'}); } catch (_) {} await showCall({version:1,call:1});')
check(caught.ok and not caught.calls[1].ok and json.decode(json.encode(caught.shown[1].result)).error,'caught native failure retains exact actionable result')
-- 6. A stale receipt refuses with no write; an explicit fresh read then edits exactly.
local p=root..'/formatted.txt';assert(host.write_file(p,'alpha\n'))
local before=tools.dispatch(memory,'read',{path=p},'master',ctx)
assert(host.write_file(p,'  alpha\n'))
local stale=tools.dispatch(memory,'edit',{path=p,range_edits={{selection=before.selection,replacement_lines={'beta'}}}},'master',ctx)
check(stale.error and host.read_file(p)=='  alpha\n','stale formatted receipt refuses with no write')
local fresh=tools.dispatch(memory,'read',{path=p},'master',ctx)
local edited=tools.dispatch(memory,'edit',{path=p,range_edits={{selection=fresh.selection,replacement_lines={'beta'}}}},'master',ctx)
check(not edited.error and host.read_file(p):find('beta',1,true),'fresh receipt/exact edit succeeds')
-- 7. An earlier effect survives a later refusal, and an unknown effect is never replayed.
local mock=tools.dispatch
r=call('await tools.write({path:'..json.encode(root..'/once.txt')..',content:"once"}); await showCall({version:1,call:1}); await tools.read({path:42});')
check(not r.ok and #r.calls==1 and host.read_file(root..'/once.txt')=='once' and r.shown[1],'earlier effect and selected receipt survive later refusal')
tools.dispatch=function(m,n,a,role,c)if n=='read' then error('fixture unknown dispatch effect')end;return mock(m,n,a,role,c)end
r=call('await tools.write({path:'..json.encode(root..'/twice.txt')..',content:"once"}); await showCall({version:1,call:1}); await tools.read({path:"fixture"});')
tools.dispatch=mock
check(not r.ok and #r.calls==2 and json.decode(raw(r.calls[2].evidence)).effect=='unknown','unknown later effect retained, no replay')
local bad=call('await showCall({version:2,call:1});')
check(not bad.ok and #bad.calls==0,'invalid helper version cannot dispatch anything')
keep('last-result.json',r)
print(json.encode({ok=true,checks=checks,paid_calls=0,old_unprojected_bytes=oldbytes,new_model_bytes=newbytes}))
