local json=dofile('lua/vendor/json.lua')
local files=dofile('lua/core/file_tools.lua')
local tools=dofile('lua/core/tools.lua')
local output=dofile('lua/core/tool_output.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local root=dofile('lua/core/paths.lua').data()..'/efficiency-fixtures/'
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local function save(name,text) local path=root..name;assert(host.write_file(path,text));return path end
-- Every page is measured after the real model-facing projection, including long lines and escaping.
for i,text in ipairs({'','a\n','a\r\nb','é日本語\n'..string.rep('é',70000)..'\nlast',string.rep('"\\\n',4001)}) do
  local path=save('read'..i,text);local args={path=path,offset=1,column=1,limit=2000};local parts={};local count=0
  repeat
    local page=json.decode(output.project('read',files.read(args)))
    check(not page.error and not page.omitted and utf8.len(page.content),'valid exact read view')
    parts[#parts+1]=page.content;count=count+1;check(count<50,'cursor terminates')
    if page.eof then break end
    check(page.next_offset>args.offset or page.next_column>(args.column or 1),'cursor advances')
    args={path=path,offset=page.next_offset,column=page.next_column,version=page.version,limit=2000}
  until false
  check(table.concat(parts)==text,'projected pages recover exact bytes')
end
local dense=save('dense-lines',string.rep('\n',140000))
local dense_page=files.read({path=dense,offset=139999,limit=2})
check(files.cache_stats().fallbacks>0 and dense_page.total_lines==140000 and dense_page.content=='\n\n' and dense_page.eof,'oversized indexes fall back to bounded range indexing')
local path=save('edits','one\ntwo\nthree\n');local before=files.read({path=path})
local stats=files.cache_stats();files.read({path=path});check(files.cache_stats().hits>stats.hits,'immutable line index reused')
host.write_file(path,'ONE\ntwo\nthree\n')
check(files.read({path=path,version=before.version}).error=='file_changed','stale continuation rejected')
check(files.read({path=path}).content:sub(1,3)=='ONE','fresh bytes never replaced by cached success')
local original=host.read_file(path)
local r=files.edit({path=path,edits={{old_text='ONE',new_text='two'},{old_text='two',new_text='TWO'}}})
check(r.ok and host.read_file(path)=='two\nTWO\nthree\n','all edits matched original snapshot')
check(files.edit({path=path,version=before.version,old_text='three',new_text='THREE'}).error=='file_changed','stale edit refused')
host.write_file(path,'abcdef')
check(files.edit({path=path,edits={{old_text='abc',new_text='A'},{old_text='bc',new_text='B'}}}).error=='overlapping_edits','overlap refused')
check(host.read_file(path)=='abcdef','failed batch leaves bytes untouched')
check(files.edit({path=path,edits={{old_text='abc',new_text='A'},{old_text='missing',new_text='B'}}}).error=='old_text_not_found','validate whole batch before write')
-- The measured cause of a miss is not whitespace: the model writes an anchor it never read,
-- and in 42 of 44 failures over 24h it was in nothing the session had seen. So the hint has to
-- locate the *region* the model meant even when it misremembered the first line as well.
local region=save('region','function alpha(value)\n  return value + 1\nend\n')
local paraphrased=files.edit({path=region,edits={{old_text='function alpha(value)\n  return value + 2\nend',new_text='X'}}})
check(paraphrased.error=='old_text_not_found' and paraphrased.nearest~=nil
  and paraphrased.nearest.line==1 and paraphrased.nearest.last_line==3
  and paraphrased.nearest.text:find('return value + 1',1,true)~=nil,
  'a paraphrased anchor points at the region that actually exists')
-- The other line ending is a *different* miss from a misquote, and it must be named: the same
-- bytes with LF where the file has CRLF used to read as "your anchor is not in the file", which
-- cost four rounds of re-deriving anchors before anyone measured the bytes.
local crlf=path..'.crlf'
host.write_file(crlf,'alpha\r\nbeta\r\ngamma\r\n')
local ending=files.edit({path=crlf,edits={{old_text='alpha\nbeta\ngamma',new_text='alpha\nBETA\ngamma'}}})
check(ending.ok==true, 'an LF anchor against a CRLF file must apply, got: '..tostring(ending.error))
local kept=host.read_file(crlf)
check(kept:find('\r\n',1,true)~=nil and kept:find('alpha\r\nBETA\r\ngamma',1,true)~=nil,
  'and the file must keep its own endings, got: '..tostring(kept))
local absent=files.edit({path=crlf,edits={{old_text='nothing like this is here at all',new_text='X'}}})
check(absent.error=='old_text_not_found', 'a genuinely absent anchor must still fail')

local unrelated=files.edit({path=path,edits={{old_text='nothing like this is in the file at all',new_text='A'}}})
check(unrelated.error=='old_text_not_found' and unrelated.nearest==nil,
  'and a miss with no candidate invents none')
check(host.read_file(path)=='abcdef','later mismatch leaves bytes untouched')
host.write_file(path,'aaa');check(files.edit({path=path,old_text='aa',new_text='x'}).error=='old_text_ambiguous','overlapping occurrences ambiguous')
for i=1,25 do save('cache','line '..i);files.read({path=root..'cache'}) end
check(files.cache_stats().entries<=16 and files.cache_stats().index_bytes_estimate<=2*1024*1024,'index bounded')
local read=host.read_file;local n=0
host.read_file=function(p) if p==path then n=n+1;return n==1 and 'original' or 'changed' end;return read(p) end
check(files.edit({path=path,old_text='original',new_text='new'}).error=='file_changed_before_write','intervening change refused')
host.read_file=read
local grep=tools.dispatch(memory,'grep',{path=path,pattern='aa',ignore_case=false,limit=1},'master')
check(grep.count==1 and grep.complete,'supported search semantics')
check(tools.dispatch(memory,'grep',{pattern='x',regex=true},'master').error=='unsupported_search_option','unsupported matching cannot silently succeed')
local called=0
local diagnosis=dofile('lua/core/diagnose.lua')
local steps={{tool='read',args={path=path},expect={contains='missing'}},{tool='read',args={path=path}}}
r=diagnosis.run(steps,function(_,args)called=called+1;return files.read(args)end)
check(not r.ok and r.stopped_at==1 and r.not_run==1 and called==1,'workflow stops without repair or retry')
called=0;r=diagnosis.run({{tool='read',args={path=path}},{tool='bash',args={command='never'}}},function()called=called+1 end)
check(r.error and called==0,'entire workflow validated before first step')
r=diagnosis.run({[1]={tool='read',args={path=path}},[3]={tool='read',args={path=path}}},function()called=called+1 end)
check(r.error and called==0,'sparse plans cannot silently skip requested steps')
r=diagnosis.run({{tool='read',args={path=path}},{tool='grep',args={path=path,pattern='aa'},expect={contains='aa'}}},function()called=called+1;return {complete=true,matches={{text='aaa'}},count=1} end)
check(r.error=='contains_requires_read' and r.step==2 and called==0,'unsupported grep content assertion rejected before any step')
r=tools.dispatch(memory,'diagnose',{steps={{tool='read',args={path=path},expect={contains='aaa'}},{tool='grep',args={path=path,pattern='aa'},expect={min_matches=1,max_matches=1}}}},'master')
check(r.ok and #r.results==2,'predetermined diagnostics complete with evidence')
local range_path=save('range','first\nsecond\n')
r=tools.dispatch(memory,'diagnose',{steps={{tool='read',args={path=range_path,limit=1},expect={contains='first'}}}},'master')
check(r.ok and not r.results[1].result.eof and r.results[1].result.range_complete,'explicit complete range does not require an unrequested whole-file read')
local long_path=save('long-range',string.rep('x',100000))
r=tools.dispatch(memory,'diagnose',{steps={{tool='read',args={path=long_path,limit=1}}}},'master')
check(not r.ok and r.results[1].error=='read_incomplete','byte-clipped range cannot satisfy a diagnostic step')
check(tools.dispatch(memory,'diagnose',{steps=steps},'guest').error~=nil,'workflow respects role gate')
local repo_path=root..'repo-scope'
save('repo-scope/.git/HEAD','ref: refs/heads/fixture\n');save('repo-scope/source.lua','needle\n')
r=tools.dispatch(memory,'diagnose',{steps={{tool='grep',args={path=repo_path,pattern='needle'}},{tool='read',args={path=path}}}},'master')
check(not r.ok and r.not_run==1 and r.results[1].result.skipped.excluded_name==1,'declared exclusions remain incomplete; repo diagnostics do not silently continue')
check(tools.dispatch(memory,'remote',{node='local-fixture',capability='session',args={session_id='operator'}},'guest',{user_id='other'}).error=='forbidden_for_role:guest','guest remote refused before local recursion or network lookup')
local sid=memory.ensure_session('efficiency-owner','efficiency-node')
local mid=memory.append_turn(sid,{role='assistant',content='EXACT CONTENT',ok=false,tool_calls={{id='c',type='function',['function']={name='read',arguments='{"path":"SECRET_ARGUMENT"}'}}},trace={{kind='tool',name='read',ok=false,error='visible failure'}}})
local rows=memory.session_messages(sid);mid=rows[#rows].id
local compact=tools.dispatch(memory,'session',{session_id=sid,view='compact'},'master').messages
check(compact[#compact].content=='EXACT CONTENT' and compact[#compact].trace[1].error=='visible failure','compact view keeps content and failures')
check(not json.encode(compact):find('SECRET_ARGUMENT',1,true),'compact view does not duplicate arguments')
local exact=tools.dispatch(memory,'session',{session_id=sid,message_id=mid,view='full'},'master').message
check(exact.tool_calls[1]['function'].arguments:find('SECRET_ARGUMENT',1,true),'exact row retrieval preserves evidence')
check(tools.dispatch(memory,'session',{session_id=sid,message_id=mid},'guest',{user_id='other'}).error=='forbidden','exact row cannot bypass ownership')
local sid2=memory.ensure_session('other','efficiency-node')
check(tools.dispatch(memory,'session',{session_id=sid2,message_id=mid},'guest',{user_id='other'}).error=='unknown_message','row/session substitution refused')
local prefix=dofile('lua/core/prefix_audit.lua')
local body={model='fixture',messages={{role='system',content='SECRET_SYSTEM'}},tools={{name='read'}}}
check(prefix.observe('a','model_call',body,{}).reason=='baseline_missing','first request unknown')
body.messages[2]={role='user',content='SECRET_USER'}
r=prefix.observe('a','model_call',body,{})
check(r.relation=='append_only' and r.shared_messages==1,'exact append-only detection')
body.messages[2].content='changed';r=prefix.observe('a','model_call',body,{})
check(r.relation=='rewritten' and r.first_changed_message==2,'first differing message located')
body.tools[1].name='read_many';body.model='other';r=prefix.observe('a','model_call',body,{session='other'})
check(r.tools_changed and r.settings_changed and r.routing_changed,'tools settings and routing measured separately')
check(not json.encode(r):find('SECRET',1,true),'prefix report contains no prompt text')
check(prefix.observe('b','model_call',body,{}).reason=='baseline_missing','sessions isolated')
check(prefix.observe('a','summary',body,{}).reason=='baseline_missing','summary baseline isolated')
-- A single await waits for the existing operation, never launches another one.
local op=tools.dispatch(memory,'operation',{action='start',command='echo fixture',timeout_seconds=10},'master',{session_id=sid})
check(op.operation_id~=nil,'operation launched')
r=tools.dispatch(memory,'operation',{action='await',id=op.operation_id},'master',{session_id=sid})
check(r.settled and r.ok and r.stdout:find('fixture',1,true),'await returns settled evidence without model polling')
check(tools.dispatch(memory,'operation',{action='await',id=op.operation_id},'guest').error~=nil,'await respects role gate')
local unicode=tools.dispatch(memory,'operation',{action='start',command="printf '\\303\\251'",timeout_seconds=10},'master')
assert(tools.dispatch(memory,'operation',{action='await',id=unicode.operation_id},'master').ok)
local byte=json.decode(output.project('operation',tools.dispatch(memory,'operation',{action='read',id=unicode.operation_id,stream='stdout',offset=0,limit=1},'master')))
check(byte.text_lossy and byte.content_base64=='ww==' and byte.next_offset==1,'model-facing operation page exposes exact bytes rather than silent UTF-8 damage')
local bigid=memory.append_turn(sid,{role='user',content=string.rep('large exact é evidence ',4000)})
local bigrows=memory.session_messages(sid,{limit=1});bigid=bigrows[1].id
local view=json.decode(output.project('session',tools.dispatch(memory,'session',{session_id=sid,limit=1,view='compact'},'guest',{user_id='efficiency-owner'})))
check(view.latest_turn.evidence.message_id==bigid,'oversized guest message keeps an authorized exact-evidence pointer')
local offset,version,parts=1,nil,{}
repeat
  local page=json.decode(output.project('session',tools.dispatch(memory,'session',{session_id=sid,message_id=bigid,byte_offset=offset,message_version=version},'guest',{user_id='efficiency-owner'})))
  check(not page.omitted and page.next_offset>offset,'authorized message bytes advance without generic truncation')
  parts[#parts+1]=page.content;offset=page.next_offset;version=page.message_version
until page.eof
check(table.concat(parts)==json.encode(memory.message(bigid)),'guest exact message roundtrip needs no operator artifact access')
check(tools.dispatch(memory,'session',{session_id=sid,message_id=bigid,byte_offset=1,message_version='stale'},'guest',{user_id='efficiency-owner'}).error=='message_changed','stale message receipt refused')
-- Escape-heavy pages. A session row is already JSON text, so its escapes are escaped again in
-- the model view, and a page sized from the *raw* slice then overflows the budget and is
-- replaced by the omitted envelope - which drops `next_offset` and makes the page
-- uncontinuable. Measured before the fix: omitted=true, cursor=nil, at the default budget as
-- well as a smaller one. Same for tool_result, whose slice is sized the same way.
local esid=memory.start_session('','escapes',{user_id='master',node_id='',title='escapes'})
memory.append_turn(esid,{role='user',content='x'})
memory.append_turn(esid,{role='assistant',content=string.rep('\\"',4000)})
local erow=memory.session_messages(esid,{limit=1})[1]
local eoffset,every,eparts,epages=1,nil,{},0
repeat
  local page=json.decode(output.project('session',tools.dispatch(memory,'session',{session_id=esid,message_id=erow.id,byte_offset=eoffset,message_version=every},'master',{user_id='master'})))
  check(not page.omitted and page.next_offset and page.next_offset>eoffset,'an escape-heavy session page keeps its cursor')
  eparts[#eparts+1]=page.content;eoffset,every=page.next_offset,page.message_version;epages=epages+1
  check(epages<200,'escape-heavy session cursor terminates')
until page.eof
check(table.concat(eparts)==json.encode(memory.message(erow.id)),'escape-heavy session pages recover exact bytes')
local eref=output.store(string.rep('\\"',4000))
local toffset,tparts,tpages=1,{},0
repeat
  local page=json.decode(output.project('tool_result',output.read(eref.sha256,toffset,51200)))
  check(not page.omitted and page.next_offset and page.next_offset>toffset,'an escape-heavy tool_result page keeps its cursor')
  tparts[#tparts+1]=page.content;toffset=page.next_offset;tpages=tpages+1
  check(tpages<200,'escape-heavy tool_result cursor terminates')
until toffset>eref.bytes
check(table.concat(tparts)==string.rep('\\"',4000),'escape-heavy tool_result pages recover exact bytes')
local plugins=host.plugins
host.plugins=function()return json.encode({{name='z-fixture'},{name='a-fixture'}})end
local ordering=json.encode(tools.all('master'))
host.plugins=function()return json.encode({{name='a-fixture'},{name='z-fixture'}})end
check(json.encode(tools.all('master'))==ordering,'plugin discovery order cannot shuffle schemas')
host.plugins=plugins
local available=tools.all('master');local cap=tools.dispatch(memory,'capabilities',{},'master')
check(#available==#cap.capabilities,'capabilities exactly match full advertised surface')
print('efficiency ok ('..checks..' checks)')
