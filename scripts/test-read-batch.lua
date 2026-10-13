-- Exact historical payload plus real native file reads, scope and receipt checks.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua');local pager=dofile('lua/core/read_batch.lua');local output=dofile('lua/core/tool_output.lua');local paths=dofile('lua/core/paths.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
if host.getenv('READ_BATCH_PHASE')=='restart' then
 local saved=json.decode(assert(host.read_file(paths.data()..'/restart-cursor.json')))
 local page=pager.resume(saved.cursor,'historical-owner');check(not page.error and page.complete,'native restart resumes stored cursor')
 local capture=json.decode(assert(host.read_file(assert(host.getenv('READ_BATCH_CAPTURE')))))
 for i,item in ipairs(page.results)do check(json.encode(item)==json.encode(capture.results[page.first_index+i-1]),'native restart exact result') end
 check(#json.encode(page)<=output.MAX_BYTES and not page.omitted,'native restart bounded')
 print('read batch restart ok ('..checks..' checks)');return
end
local raw=assert(host.read_file(assert(host.getenv('READ_BATCH_CAPTURE'))));local captured=json.decode(raw)
check(#raw==59723 and #captured.results==6,'exact seq5193 capture')
local old=json.decode(output.project('read_many',captured));local omitted=0;for _,r in ipairs(old.results)do if r.omitted then omitted=omitted+1 end end
check(omitted==3,'causal old projection needs three artifact reads')
local gathered,pages={},0;local page=pager.start(captured,'historical-owner')
while true do
 pages=pages+1;local projected=json.decode(output.project('read_many',page));if pages==1 then assert(host.write_file(paths.data()..'/restart-cursor.json',json.encode({cursor=projected.next_cursor}))) end;check(not projected.omitted and #json.encode(projected)<=output.MAX_BYTES,'bounded whole-result page')
 check(#projected.outcomes==6,'all outcome slots visible')
 for i,item in ipairs(projected.results)do local index=projected.first_index+i-1;check(json.encode(item)==json.encode(captured.results[index]),'exact original content/version/receipt '..index);gathered[index]=item end
 if not projected.has_more then check(projected.complete and projected.last_index==6,'final completeness');break end
 check(projected.next_cursor~=nil,'explicit continuation');check(pager.resume(projected.next_cursor,'other-owner').error=='read_many_cursor_scope_changed','scope fenced')
 page=dofile('lua/core/read_batch.lua').resume(projected.next_cursor,'historical-owner')
end
check(pages==2 and #gathered==6,'same six results in two bounded calls, zero artifact recovery')
local sid=memory.start_session('','read-packing',{user_id='master'});local ctx={session_id=sid,user_id='master',role='master'}
local root=paths.data()..'/read-packing';local requests={};local texts={}
for i=1,6 do texts[i]=('line-'..i..' 😀 "\\\t\n'):rep(700);local file=root..'/'..i..'.txt';check(host.write_file(file,texts[i]),'fixture file');requests[i]={path=file,limit=700}end
local live=tools.dispatch(memory,'read_many',{requests=requests},'master',ctx);local cursor=live.next_cursor;check(cursor~=nil and not live.omitted,'actual dispatcher paginates')
check(#json.encode(live)<=output.MAX_BYTES,'native view bounded')
local found={};for i,r in ipairs(live.results)do found[live.first_index+i-1]=r end
-- Change the sources after execution: continuation is the immutable captured read, not a replay.
for _,r in ipairs(requests)do assert(host.write_file(r.path,'changed'))end
local continued=tools.dispatch(memory,'read_many',{cursor=cursor},'master',ctx);check(not continued.error,'cached continuation');check(#json.encode(continued)<=output.MAX_BYTES,'continued view bounded')
while true do for i,r in ipairs(continued.results)do found[continued.first_index+i-1]=r end;if not continued.has_more then break end;continued=tools.dispatch(memory,'read_many',{cursor=continued.next_cursor},'master',ctx)end
for i,r in ipairs(found)do check(r.content==texts[i] and r.selection~=nil and r.range_complete,'whole UTF-8 source and edit receipt retained '..i)end
check(#found==6,'no lost live item');check(tools.dispatch(memory,'read_many',{cursor=cursor,requests=requests},'master',ctx).error=='read_many_forms_are_exclusive','exclusive forms')
check(tools.dispatch(memory,'read_many',{cursor=cursor},'guest',ctx).error~=nil,'guest ceiling')
check(tools.dispatch(memory,'read_many',{cursor=cursor},'master',{session_id=sid,user_id='different'}).error=='read_many_cursor_scope_changed','account isolation')
check(tools.dispatch(memory,'read_many',{cursor=cursor},'master',{session_id='different',user_id='master'}).error=='read_many_cursor_scope_changed','session isolation')
check(tools.dispatch(memory,'read_many',{cursor=cursor},'master',{session_id=sid,user_id='master',subagent={allowed={read_many=true}}}).error=='read_many_cursor_scope_changed','profile isolation')
local bound={session_workspace=function()return {required=true,state='allocated',worktree=root}end};check(tools.dispatch(bound,'read_many',{cursor=cursor},'master',ctx).error=='read_many_cursor_scope_changed','workspace binding freshness')
check(pager.resume('invalid','x').error=='read_many_cursor_invalid','bad cursor visible')
local small=tools.dispatch(memory,'read_many',{requests={{path=root..'/missing'}}},'master',ctx);check(small.failed==1 and #small.results==1 and small.first_index==nil,'small/error compatibility')
local near=root..'/near.txt';assert(host.write_file(near,('abc😀\\"'):rep(12000)));local one=tools.dispatch(memory,'read_many',{requests={{path=near,limit=1}}},'master',ctx)
check(#json.encode(one)<=output.MAX_BYTES and not one.omitted and one.results[1].next_column>1,'near-limit long line stays cursor-paged, not artifact-omitted')
local full=assert(host.read_file(live.full_result.path));assert(host.write_file(live.full_result.path,full..'changed'))
check(tools.dispatch(memory,'read_many',{cursor=cursor},'master',ctx).error=='read_many_snapshot_changed','cached artifact integrity fenced')
print('read batch packing ok ('..checks..' checks; historical artifact followups3->0; pages2)')
