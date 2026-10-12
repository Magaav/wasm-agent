-- Model-free native filesystem/SQLite batch contracts. Private WASM_AGENT_HOME only.
local json=dofile('lua/vendor/json.lua')
local tools=dofile('lua/core/tools.lua')
local files=dofile('lua/core/file_tools.lua')
local batch=dofile('lua/core/batch_tools.lua')
local output=dofile('lua/core/tool_output.lua')
local changes=dofile('lua/core/changeset.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local root=dofile('lua/core/paths.lua').data()..'/batch-fixtures'
local checks=0
local function check(value,label)checks=checks+1;assert(value,label)end
local function save(name,text)local p=root..'/'..name;assert(host.write_file(p,text));return p end
local function call(name,requests,ctx,role)return tools.dispatch(memory,name,{requests=requests},role or 'master',ctx or {user_id='master'})end
local function edit(path,old,new)return {path=path,edits={{old_text=old,new_text=new}}}end
local names={'edit_many','write_many','grep_many','session_many','search_messages_many','symbol_source_many'}
local schemas={};for _,s in ipairs(tools.catalog('master'))do schemas[s['function'].name]=s['function']end
for _,name in ipairs(names)do
 check(schemas[name] and schemas[name].parameters.properties.requests.maxItems==8,'bounded schema '..name)
 check(tools.dispatch(memory,name,{requests={}},'guest',{user_id='alice'}).error=='forbidden_for_role:guest','guest unchanged '..name)
end
check(not tools.has_effect('grep_many') and not tools.has_effect('session_many') and tools.has_effect('edit_many') and tools.has_effect('write_many'),'effect fences classify batches')
check(dofile('lua/core/workspaces.lua').requires_write_tools({'write_many'}),'batch-only profile requires a workspace')
local a,b,c=save('a.txt','alpha\n'),save('b.txt','beta\n'),save('c.txt','gamma\n')
local ctx={changes=changes.new(),user_id='master'}
local r=call('write_many',{{path=a,content='ALPHA\n'},{path=b,content='BETA\n'}},ctx)
check(r.ok and r.applied==2 and #ctx.changes.files==2,'both write effects recorded')
check(host.read_file(a)=='ALPHA\n' and host.read_file(b)=='BETA\n','both actual files written')
check(changes.undo(ctx.changes) and host.read_file(a)=='alpha\n' and host.read_file(b)=='beta\n','batch undo restores original files')
r=call('write_many',{{path=root..'/new.txt',content='created\n'}})
check(r.ok and r.applied==1 and host.read_file(root..'/new.txt')=='created\n','new text file creation')
r=call('write_many',{{path=a,content='wrong',version='stale'},{path=b,content='wrong'}})
check(not r.ok and r.phase=='preflight' and r.applied==0 and r.not_run==1 and host.read_file(b)=='beta\n','write version refuses whole preflight')
r=call('write_many',{{path=a,content='wrong'},{path=b,content=42}})
check(not r.ok and r.effect=='none' and host.read_file(a)=='alpha\n','invalid later shape prevents first write')
r=call('write_many',{{path=a,content='wrong'},{path=root..'/./a.txt',content='wrong'}})
check(r.results[2].error=='overlapping_batch_paths' and r.applied==0,'lexical/canonical aliases refuse before writes')
r=call('write_many',{{path=root..'/future',content='wrong'},{path=root..'/future/child',content='wrong'}})
check(not r.ok and r.applied==0 and host.path_kind(root..'/future')=='missing','ancestor targets refuse before writes')
local count,write=0,host.write_file
host.write_file=function(p,t)if p==a then count=count+1 end;return write(p,t)end
r=call('write_many',{{path=a,content='alpha\n'}})
host.write_file=write
check(r.ok and r.applied==0 and r.results[1].no_change and count==0,'no-op batch does not rewrite')
local huge={};for i=1,9 do huge[i]={path=a,content='wrong'}end
check(call('write_many',huge).error=='requests_required_1_to_8','batch length bound')
check(call('write_many',{[1]={path=a,content='wrong'},[3]={path=b,content='wrong'}}).error=='requests_required_1_to_8','sparse batches refused')
check(call('write_many',{{path=a,content='wrong',action='bash'}}).effect=='none','no arbitrary effect options')
r=call('edit_many',{edit(a,'alpha','ALPHA'),edit(b,'missing','BETA')})
check(not r.ok and r.applied==0 and r.results[2].error=='old_text_not_found' and host.read_file(a)=='alpha\n','invalid later anchor prevents first edit')
local page=files.read({path=a,limit=1})
ctx={changes=changes.new()}
r=call('edit_many',{{path=a,range_edits={{selection=page.selection,replacement_lines={'ALPHA'}}}},edit(b,'beta','BETA')},ctx)
check(r.ok and r.applied==2 and r.results[1].replaced[1].first=='alpha','mixed per-file forms retain exact address echoes')
check(changes.undo(ctx.changes) and host.read_file(a)=='alpha\n','edit batch retained real undo')
r=call('edit_many',{{path=a,edits={{old_text='alpha',new_text='wrong'}},range_edits={{selection=page.selection,replacement_lines={'wrong'}}}},edit(b,'beta','wrong')})
check(r.results[1].error=='mixed_edit_forms' and r.applied==0,'single-file form exclusivity unchanged')
write(a,'changed\n')
r=call('edit_many',{{path=a,range_edits={{selection=page.selection,replacement_lines={'wrong'}}}},edit(b,'beta','wrong')})
check(r.results[1].error=='stale_selection' and r.applied==0 and host.read_file(b)=='beta\n','genuine stale receipt fences batch')
write(a,'alpha\n')
-- A file changed while later items were prepared: final preflight rechecks all.
local read=host.read_file;local changed=false
host.read_file=function(p)if p==b and not changed then changed=true;write(a,'external\n')end;return read(p)end
r=call('write_many',{{path=a,content='wrong'},{path=b,content='wrong'}})
host.read_file=read
check(r.phase=='preflight' and r.applied==0 and read(a)=='external\n' and read(b)=='beta\n','changed prepared snapshot refuses before first write')
write(a,'alpha\n')
-- A write failure may have changed bytes. Preserve uncertainty and earlier effects.
ctx={changes=changes.new()}
host.write_file=function(p,t)if p==b then return false end;return write(p,t)end
r=call('write_many',{{path=a,content='ALPHA\n'},{path=b,content='BETA\n'},{path=c,content='GAMMA\n'}},ctx)
host.write_file=write
check(not r.ok and r.partial and r.applied==1 and r.unknown==1 and r.not_run==1,'unknown write stops later effects without rollback/retry')
check(r.results[2].outcome=='unknown' and r.results[3].executed==false and read(a)=='ALPHA\n' and read(c)=='gamma\n','actual earlier effect retained, later untouched')
check(#ctx.changes.files==1 and changes.undo(ctx.changes),'known earlier effect keeps undo')
ctx={changes=changes.new()}
host.write_file=function(p,t)if p:find('/changes/',1,true) then error('fixture record failure')end;return write(p,t)end
r=call('write_many',{{path=a,content='record-failure\n'},{path=b,content='wrong'}},ctx)
host.write_file=write
check(r.applied==1 and r.results[1].error=='edit_applied_but_record_failed' and r.not_run==1 and read(a)=='record-failure\n','post-write record failure is explicit applied effect')
write(a,'alpha\n')
r=call('write_many',{{path=a,content='never'},{path=b,content='never'}},{steering_admit=function()return false end})
check(output.cancelled(r) and r.applied==0 and r.not_run==1,'batch fenced before any effect is typed neutral cancellation')
local admissions=0
r=call('write_many',{{path=a,content='ALPHA\n'},{path=b,content='BETA\n'},{path=c,content='GAMMA\n'}},{steering_admit=function()admissions=admissions+1;return admissions==1 end})
check(r.applied==1 and r.results[2].error=='superseded_by_steering' and r.not_run==1 and read(b)=='beta\n','steering fences later batch effects')
write(a,'alpha\n')
local fake=setmetatable({session_worktree=function()return root end,session_workspace=function()return {required=true,state='allocated',worktree=root}end},{__index=memory})
r=tools.dispatch(fake,'write_many',{requests={{path='a.txt',content='wrong'},{path=root..'/../outside.txt',content='wrong'}}},'master',{session_id='private-fixture'})
check(r.effect=='none' and r.applied==0 and r.results[2].error=='workspace_path_outside_binding' and read(a)=='alpha\n','every batch path obeys owned binding')
r=tools.dispatch(fake,'write_many',{requests={{path='a.txt',content='ALPHA\n'}}},'master',{session_id='private-fixture'})
check(r.ok and read(a)=='ALPHA\n','valid relative path resolves to owned tree: '..json.encode(r))
write(a,'alpha\n')
local allowed={write_many=true}
check(call('write_many',{{path=a,content='wrong'}},{subagent={allowed=allowed}}).error=='capability_not_in_profile:write','batch cannot smuggle missing primitive permission')
check(call('edit_many',{edit(a,'alpha','wrong')},{subagent={allowed={read=true}}}).error=='capability_not_in_profile:edit_many','read-only profile cannot call mutation batch')
-- Native scoped grep parity, including independently invalid request.
local queries={{pattern='alpha',path=a,ignore_case=false,limit=2},{pattern='beta',path=b,ignore_case=true,limit=1},{pattern='x',path=a,limit=0}}
r=call('grep_many',queries)
check(r.failed==1 and r.succeeded==2 and #r.results==3,'read failures do not discard siblings')
for i=1,2 do check(json.encode(r.results[i])==json.encode(tools.dispatch(memory,'grep',queries[i],'master')),'native search result parity '..i)end
-- Cross-session source IDs and independently filtered history queries.
local s1=memory.start_session('','chat',{user_id='alice'});local s2=memory.start_session('','chat',{user_id='bob'})
local function add(s,role,text,name)local id=host.uuid();memory.append_turn(s,{id=id,role=role,content=text,tool_name=name});return id end
local mid=add(s1,'user','batchneedle original question');add(s2,'assistant','batchneedle original answer')
add(s1,'tool','batchneedle real execution','bash');add(s1,'tool','batchneedle copied search','search_messages_many');add(s1,'tool','batchneedle copied session','session_many')
r=call('session_many',{{session_id=s1,message_id=mid},{session_id=s2,limit=1},{session_id='missing'}})
check(r.failed==1 and r.results[1].message.id==mid and r.results[2].session_id==s2,'cross-session exact identities and per-item failure')
queries={{query='batchneedle',session_id=s1,scope='evidence'},{query='batchneedle',session_id=s2,roles={'assistant'}},{query='absentbatchneedle'}}
r=call('search_messages_many',queries)
check(r.ok and #r.results[1].matches==1 and r.results[1].matches[1].tool_name=='bash','batch retrieval echoes excluded from evidence scope')
for i,q in ipairs(queries)do
 local primitive=tools.dispatch(memory,'search_messages',q,'master')
 local single,many=batch.copy(primitive),batch.copy(r.results[i])
 check(type(single.search_ms)=='number' and type(many.search_ms)=='number','search latency stays measured '..i)
 single.search_ms=nil;many.search_ms=nil
 check(json.encode(single)==json.encode(many),'history result parity '..i)
end
check(tools.dispatch(memory,'session',{session_id=s2},'guest',{user_id='alice'}).error=='forbidden','primitive account boundary unchanged')
-- Graph batching admits selected-source reads on one snapshot per root.
local graphsource=host.graph_sources;local seen={}
host.graph_sources=function(options)local p=json.decode(options);local results={};for _,item in ipairs(p.requests) do seen[#seen+1]=item;results[#results+1]={source='function fixture() end',eof=true,path=item.path,name=item.name,line=item.line} end;return json.encode({ok=true,results=results}) end
r=call('symbol_source_many',{{path='fixture.lua',name='fixture',line=1,cwd=root},{path='fixture.lua',name='other',line=2,cwd=root},{path='fixture.lua',name='bad',line=3,action='index'}})
host.graph_sources=graphsource
check(r.failed==1 and #seen==2 and r.results[1].source=='function fixture() end','source batch is selected reads only')
-- Oversized batches preserve every outcome and exact full item JSON.
local big={ok=false,failed=1,results={}}
for i=1,8 do big.results[i]={ok=true,content=string.rep('"\\',40000),marker=i}end
big.results[8]={error='late_item_failed',outcome='unknown',path=b}
local view=json.decode(output.project('session_many',big))
check(view.omitted and #view.results==8 and view.results[8].error=='late_item_failed' and #json.encode(view)<=output.MAX_BYTES,'oversized batch retains all slots and later failure')
local pointer=view.results[1].full_result;local chunks,cursor={},1
repeat local p=output.read(pointer.sha256,cursor,20000);chunks[#chunks+1]=p.content;cursor=p.next_offset;if p.eof then break end until false
check(table.concat(chunks)==json.encode(big.results[1]),'omitted item original bytes recovered exactly')
local cli=dofile('lua/core/cli_view.lua');local worked,detail=cli.outcome('write_many',{ok=false,failed=1,not_run=1,results={{},{},{}}})
check(not worked and detail:find('1 failed',1,true) and cli.call_line('grep_many',{requests={{},{}}}):find('2 independent',1,true),'batch caller-visible outcome is truthful')
-- Deterministic equivalent tool-exchange envelopes, not model-token billing.
local calls,results,requests={},{},{}
for i=1,8 do
 local req={path=root..'/file'..i..'.txt',content='verified text\n'};requests[i]=req
 calls[i]={id='call-'..i,type='function',['function']={name='write',arguments=json.encode(req)}}
 results[i]={role='tool',tool_call_id='call-'..i,content=json.encode({ok=true,path=req.path})}
end
local single_bytes=#json.encode({calls=calls,results=results})
local batch_bytes=#json.encode({calls={{id='batch-call',type='function',['function']={name='write_many',arguments=json.encode({requests=requests})}}},results={{role='tool',tool_call_id='batch-call',content=json.encode({ok=true,failed=0,results=(function()local items={};for _,req in ipairs(requests)do items[#items+1]={ok=true,path=req.path}end;return items end)()})}}})
local old_schemas,new_schemas={},{}
for _,s in ipairs(tools.catalog('master'))do new_schemas[#new_schemas+1]=s;if not s['function'].name:match('_many$') or s['function'].name=='read_many' then old_schemas[#old_schemas+1]=s end end
print('batch envelope measurement '..json.encode({items=8,single_calls=8,batch_calls=1,single_bytes=single_bytes,batch_bytes=batch_bytes,schema_bytes_added=#json.encode(new_schemas)-#json.encode(old_schemas),inference_round_saving_proven=false}))
check(batch_bytes<single_bytes,'actual repeated exchange metadata reduced')
-- Explicit rollback keeps ordinary capabilities and denies batch effects.
local getenv=host.getenv
host.getenv=function(key)if key=='WASM_AGENT_BATCH_TOOLS' then return '0' end;return getenv(key)end
local disabled=dofile('lua/core/tools.lua')
check(disabled.dispatch(memory,'write_many',{requests={{path=a,content='wrong'}}},'master').error=='batch_tools_disabled','explicit rollback refuses batch dispatch')
check(disabled.dispatch(memory,'write_many',{requests={{path=a,content='wrong'}}},'guest').error=='forbidden_for_role:guest','disabled schema cannot erase role boundary')
for _,s in ipairs(disabled.catalog('master'))do check(s['function'].name~='edit_many' and s['function'].name~='write_many','disabled schemas absent')end
local rollback_explore,rollback_problem=dofile('lua/core/subagents.lua').resolve('explore',{role='master',user_id='master'})
check(rollback_explore and rollback_explore.allowed.grep and not rollback_explore.allowed.grep_many,'rollback preserves ordinary built-in profiles: '..tostring(rollback_problem))
host.getenv=getenv
local subagents=dofile('lua/core/subagents.lua')
local profile_path=dofile('lua/core/paths.lua').config()..'/subagent-profiles/batch-fixture.json'
write(profile_path,json.encode({schema_version=1,id='batch-fixture',operator_authorized=true,allowed_tools={'write_many'},limits={max_depth=0}}))
local resolved,problem=subagents.resolve('batch-fixture',{role='master',user_id='master'})
check(not resolved and problem=='profile_batch_requires_primitive:write','incomplete batch profile refuses before task admission')
write(profile_path,json.encode({schema_version=1,id='batch-fixture',allowed_tools={'write_many','write'},limits={max_depth=0}}))
resolved,problem=subagents.resolve('batch-fixture',{role='master',user_id='master'})
check(not resolved and problem=='profile_not_authorized:write_many','batch effects require explicit operator authorization')
-- Real agent/tool/ledger loop with mock inference. Equal tasks, both arms use
-- identical schemas and TWO provider calls, never eight sequential model rounds.
local settings={WASM_AGENT_LLM_API_KEY='fixture',WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-fixture-store',WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='3',WASM_AGENT_PROVIDER_TRANSIENT_RETRIES='0',WASM_AGENT_PROVIDER_RESPONSE_RETRIES='0'}
host.getenv=function(key)if settings[key]~=nil then return settings[key] end;return getenv(key)end
host.http=function()error('unexpected network')end
local agent=dofile('lua/core/agent.lua')
local timings={primitive={},batch={}}
for pair=1,4 do
 for _,arm in ipairs(pair%2==0 and {'batch','primitive'} or {'primitive','batch'})do
  local sid=memory.start_session('',arm,{user_id='master'});local requests,calls={},{}
  for i=1,8 do
   local p=save('task-'..pair..'-'..arm..'-'..i..'.txt','initial\n')
   requests[i]={path=p,content='verified task result\n'}
   calls[i]={id='task-'..i,type='function',['function']={name='write',arguments=json.encode(requests[i])}}
  end
  if arm=='batch' then calls={{id='batch-task',type='function',['function']={name='write_many',arguments=json.encode({requests=requests})}}}end
  local invoked=0
  host.http_stream=function()
   invoked=invoked+1
   return json.encode({status=200,stream_complete=true,content=invoked==1 and '' or 'verified',finish_reason=invoked==1 and 'tool_calls' or 'stop',tool_calls=invoked==1 and calls or {},usage={prompt_tokens=1000,completion_tokens=100,total_tokens=1100}})
  end
  local bot=agent.new(sid,function()end,'master','master','');local started=host.now()
  check(bot:run('Write the eight specified files, then answer verified.')=='verified','real '..arm..' agent task finishes')
  timings[arm][#timings[arm]+1]=(host.now()-started)*1000
  check(invoked==2,'same two mock inference calls '..arm)
  for _,req in ipairs(requests)do check(host.read_file(req.path)==req.content,'verified task file '..arm)end
  local rows=memory.session_messages(sid,{limit=1000});local tool_rows=0;local retained
  for _,row in ipairs(rows)do
   if row.role=='tool' then tool_rows=tool_rows+1;check(row.ok~=false,'retained tool result success')end
   for _,span in ipairs(row.trace or {})do if span.kind=='run_counts' then retained=span end end
  end
  check(tool_rows==(arm=='batch' and 1 or 8),'actual ledger tool rows '..arm)
  check(retained and retained.tool_calls==tool_rows,'actual invocation counters not fabricated '..arm)
 end
end
print('batch task measurement '..json.encode({pairs=4,interleaved=true,mock_inference=true,schemas_identical=true,inference_calls_per_task=2,files_per_task=8,wall_ms=timings,paid_model_quality_proven=false}))
print('batch tools ok ('..checks..' checks)')
