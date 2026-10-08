-- Private native SQLite contract tests; no live node/provider/account.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local search=dofile('lua/core/history_search.lua')
local tools=dofile('lua/core/tools.lua')
local view=dofile('lua/core/session_view.lua')
local checks=0
local function ok(v,label) checks=checks+1;assert(v,label) end
local a=memory.start_session('','chat',{user_id='alice'})
local b=memory.start_session('','chat',{user_id='alice'})
local foreign=memory.start_session('','chat',{user_id='bob'})
local function add(s,role,text,name)
 local id=host.uuid();memory.append_turn(s,{id=id,role=role,content=text,tool_name=name});return id
end
memory.transaction(function()
add(a,'user','benchmark Pi efficiency and verified task completion')
add(a,'assistant','benchmark Pi pilot failed; do not claim a ranking')
add(a,'user','benchmark Pi: correction, use matching source and reasoning')
add(a,'assistant','benchmark Pi needs retained original traces')
add(a,'tool',string.rep('benchmark Pi logfile ',10000)..'fatal tool-only failure','bash')
add(a,'tool',string.rep('benchmark Pi echo ',10000),'search_messages')
add(a,'summary','benchmark Pi interpreted summary')
add(a,'user','[Sentinel notice] benchmark Pi automatic deployment status')
add(b,'user','benchmark Pi second independent request')
add(b,'assistant','benchmark Pi second result')
add(foreign,'user','benchmark Pi confidential other account')
add(b,'assistant','An unchanged scope statement, followed by a correction without matching words')
add(b,'user',string.rep('padding ',1500)..'configuração naïve café 你好 exactneedle '..string.rep('tail ',1000))
add(b,'user','quotes "slashes\\" exactneedle and escaped text')
end)
local function run(args,owner)
  local p=search.search(memory,args,owner)
  ok(not p.error,json.encode(p))
  ok(#json.encode(p)<=(args.byte_limit or 16000),'encoded search budget')
  return p
end
local p=run({query='benchmark Pi'},'alice')
ok(#p.matches==4,'session grouping returns two per session')
for _,row in ipairs(p.matches) do
  ok(row.role=='user' or row.role=='assistant','dialogue roles')
  ok(not row.content:find('[Sentinel notice]',1,true),'automated notice excluded')
  local original=memory.message(row.id)
  ok(row.evidence.message_id==row.id and row.evidence.session_id==row.session_id,'exact identity')
  local first=utf8.offset(original.content,row.excerpt_start)
  local last=utf8.offset(original.content,row.excerpt_end+1) or (#original.content+1)
  ok(original.content:sub(first,last-1)==row.content,'excerpt exact UTF-8 source coordinates')
end
p=run({query='benchmark Pi',scope='evidence'},'alice')
ok(#p.matches==1 and p.matches[1].tool_name=='bash','execution evidence excludes retrieval echoes')
ok(p.matches[1].omitted and p.matches[1].content_bytes>100000,'large evidence excerpt explicitly omitted')
p=run({query='benchmark Pi',scope='all',group_by='message',limit=50},'alice')
ok(#p.matches==10,'all includes tools, notices and summaries')
p=run({query='benchmark Pi',scope='all',roles={'tool'},tool_name='search_messages'},'alice')
ok(#p.matches==1,'explicit all scope permits inspecting native echoes')
p=run({query='benchmark Pi',roles={'user'},group_by='message'},'alice')
ok(#p.matches==3,'roles filter before ranking')
p=run({query='benchmark Pi',session_id=foreign},'alice')
ok(#p.matches==0,'foreign session filter cannot expand authority')
p=run({query='benchmark Pi',session_id=foreign},nil)
ok(#p.matches==1,'master unrestricted account authority')
p=tools.dispatch(memory,'search_messages',{query='benchmark Pi',session_id=foreign},'master',{user_id='master'})
ok(#p.matches==1,'master facade does not accidentally filter to master account')
p=tools.dispatch(memory,'search_messages',{query='benchmark Pi',session_id=foreign},'guest',{user_id='alice'})
ok(#p.matches==0,'guest facade scope safe')
p=tools.dispatch(memory,'session',{session_id=foreign,around_seq=1},'guest',{user_id='alice'})
ok(p.error=='forbidden','around retrieval preserves guest boundary')
p=run({query='configuracao cafe 你好'},'alice')
ok(#p.matches==1 and p.matches[1].content:find('configuração',1,true),'case/diacritics Unicode tokenizer retained')
local unicode=p.matches[1];local original=memory.message(unicode.id)
local first=utf8.offset(original.content,unicode.excerpt_start)
local last=utf8.offset(original.content,unicode.excerpt_end+1) or #original.content+1
ok(original.content:sub(first,last-1)==unicode.content,'late Unicode match exact addressing')
ok(unicode.excerpt_start>1000,'match centred rather than first characters')
p=run({query='Pi benchmark',match='phrase'},'alice')
ok(#p.matches==0,'phrase respects order')
p=run({query='Pi benchmark'},'alice')
ok(#p.matches==4,'terms AND permits either order')
p=run({query='no-such-knownsource-negative'},'alice')
ok(#p.matches==0 and not p.has_more,'negative control')
p=run({query='" OR NOT * ()'},'alice')
ok(#p.matches==0,'query syntax cannot become FTS operators')
local seen={};local offset=0;local count=0
repeat
 p=run({query='benchmark Pi',scope='all',group_by='message',limit=2,offset=offset,byte_limit=2048},'alice')
 for _,row in ipairs(p.matches) do ok(not seen[row.id],'no pagination duplicate');seen[row.id]=true;count=count+1 end
 if not p.has_more then break end
 ok(p.next_offset>offset,'pagination advances');offset=p.next_offset
until false
ok(count==10,'pagination no gaps')
p=run({query='benchmark Pi',scope='all',group_by='message',view='full',limit=50,byte_limit=4096},'alice')
local large
for _,row in ipairs(p.matches) do if row.omitted then large=row end end
ok(large and large.evidence.byte_offset==1,'full large rows have exact pointers')
local parts,at,version={},1,nil
repeat
 local r=view.get(memory,large.session_id,{message_id=large.id,byte_offset=at,byte_limit=20000,message_version=version})
 ok(not r.error and r.next_offset>at,'exact original pagination')
 parts[#parts+1]=r.content;at=r.next_offset;version=r.message_version
 if r.eof then break end
until false
ok(table.concat(parts)==json.encode(memory.message(large.id)),'original full body recovered byte exact')
local window=view.get(memory,a,{around_seq=2,before=1,after=2,view='compact'})
ok(not window.error and #window.messages==4 and window.messages[1].seq==1 and window.messages[4].seq==4,'centred chronology')
local centred=view.get(memory,b,{around_seq=2,before=0,after=1,view='compact'})
ok(centred.messages[2].content:find('correction',1,true),'nonmatching context preserved')
local rows=memory.session_messages(a,{limit=3,before_seq=4})
local batch=view.get(memory,a,{message_ids={rows[3].id,rows[1].id},view='compact'})
ok(#batch.messages==2 and batch.messages[1].seq==1 and batch.messages[2].seq==3,'batch chronological exact selected originals')
ok(view.get(memory,a,{message_ids={rows[1].id,memory.session_messages(foreign,{limit=1})[1].id}}).error=='unknown_message','mixed ownership batch atomically refused')
ok(view.get(memory,a,{message_ids={rows[1].id,rows[1].id}}).error=='duplicate_message_id','duplicate ids refused')
ok(view.get(memory,a,{around_seq=999}).error=='unknown_message','missing anchor refused')
ok(view.get(memory,a,{around_seq=1,before_seq=2}).error=='session_cursor_conflict','mixed cursor refused')
ok(view.get(memory,a,{before=2}).error=='session_window_anchor_required','unanchored window refused')
local latest=memory.message(memory.session_messages(b,{limit=1})[1].id)
p=run({query='exactneedle',before=latest.created_at,after=latest.created_at},'alice')
ok(#p.matches>=1,'inclusive dates')
for _,bad in ipairs({{scope='unknown'},{sort='random'},{match='regex'},{group_by='other'},{view='bad'},{offset=-1},{byte_limit=1},{limit=51},{roles={}},{roles={'foreign'}},{after='today'},{after=2,before=1},{session_id=123}}) do
 bad.query='benchmark';ok(search.search(memory,bad,'alice').error,'invalid option fails visibly')
end
p=run({query='new correction source'},'alice');ok(#p.matches==0,'before append')
add(b,'assistant','new correction source')
p=run({query='new correction source'},'alice');ok(#p.matches==1,'no result cache hides new correction')
ok(memory.message_count(a)==8 and memory.message_count(b)==6,'search did not rewrite history')
local rare=memory.start_session('','chat',{user_id='alice'})
add(rare,'user',string.rep('long context ',800)..'separatedfirst '..string.rep('middle ',800)..'separatedlast end')
p=run({query='separatedfirst separatedlast'},'alice')
ok(#p.matches==1 and p.matches[1].omitted,'distant terms still have contiguous source excerpt')
local short=add(rare,'user',string.rep('complete short body ',20)..'shortneedle tail')
p=run({query='shortneedle'},'alice')
ok(not p.matches[1].omitted and p.matches[1].content==memory.message(short).content,'short body complete beyond 32 tokens')
local newest=run({query='benchmark Pi',sort='newest',group_by='message'},'alice')
for i=2,#newest.matches do ok(newest.matches[i-1].created_at>=newest.matches[i].created_at,'newest explicitly ordered') end
local repl=host.uuid()
ok(memory.apply_entry({kind='message',payload={id=repl,session_id=rare,seq=3,role='assistant',content='replicated unique correction',created_at=host.now()}}),'replicated mutation accepted')
p=run({query='replicated unique correction'},'alice');ok(#p.matches==1 and p.matches[1].id==repl,'replicated history searchable without rebuild')
local raw_query=host.sql_query
host.sql_query=function(sql,params)
 if sql:find('AS excerpt',1,true) then ok(sql:find('messages_fts.rowid IN',1,true),'body phase rowid-targeted') end
 if sql:find('WITH matched',1,true) then ok(not sql:find('t.*',1,true),'candidate phase never materializes full rows') end
 return raw_query(sql,params)
end
p=run({query='benchmark Pi'},'alice');host.sql_query=raw_query
ok(view.get(memory,a,{around_seq=1,byte_offset=1}).error=='session_cursor_conflict','window byte cursor refused')
ok(view.get(memory,a,{message_ids={rows[1].id},before=1}).error=='session_window_anchor_required','batch window parameters refused')
print(json.encode({ok=true,checks=checks,skipped=0,paid_calls=0,contract='history-search',originals_preserved=true}))
