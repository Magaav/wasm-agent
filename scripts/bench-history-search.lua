-- Model-free old/new comparison. Historical mode uses a private SQLite backup only.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local search=dofile('lua/core/history_search.lua')
local replay=host.getenv('WA_HISTORY_REPLAY')=='1'
local checks=0
local function ok(v,label)checks=checks+1;assert(v,label)end
if not replay then
 memory.setup()
 memory.transaction(function()
 for n=1,80 do
  local sid=memory.start_session('','chat',{user_id='bench'})
  for m=1,8 do memory.append_turn(sid,{role='tool',tool_name='bash',content=string.rep('benchmark Pi history command output ',1000)..' source '..n..' row '..m})end
  memory.append_turn(sid,{role='user',content='benchmark Pi request '..n..' matched efficiency and completeness'})
  memory.append_turn(sid,{role='assistant',content='benchmark Pi result '..n..' failed, retain the evidence'})
 end
 end)
end
local queries={'benchmark','benchmark Pi','efficiency','nohistorymatchqxzz'}
local function old(text) return {matches=memory.search_messages(text,nil,20)}end
local function new(text) return search.search(memory,{query=text,limit=20},nil) end
local function timed(fn,text)
 local before=host.now();local result=fn(text);local ms=(host.now()-before)*1000
 ok(not result.error,'search succeeds')
 return result,ms
end
local function percentile(xs,p)table.sort(xs);return xs[math.max(1,math.ceil(#xs*p))]end
local reports={}
for _,text in ipairs(queries) do
 local os,ns={},{}
 local a,acold=timed(old,text);local b,bcold=timed(new,text)
 for i=1,12 do
  local av,bv
  if i%2==0 then _,bv=timed(new,text);_,av=timed(old,text) else _,av=timed(old,text);_,bv=timed(new,text)end
  os[#os+1]=av;ns[#ns+1]=bv
 end
 local tools=0;for _,row in ipairs(a.matches)do if row.role=='tool'then tools=tools+1 end end
 local exact=0;for _,row in ipairs(b.matches)do
  local original=memory.message(row.id)
  ok(original and original.session_id==row.session_id,'source accessible')
  local from=utf8.offset(original.content,row.excerpt_start)
  local to=utf8.offset(original.content,row.excerpt_end+1) or (#original.content+1)
  ok(original.content:sub(from,to-1)==row.content,'returned excerpt source exact');exact=exact+1
 end
 reports[#reports+1]={query=text,old={returned=#a.matches,tool_hits=tools,bytes=#json.encode(a),first_ms=acold,p50_ms=percentile(os,.5),p95_ms=percentile(os,.95)},new={returned=#b.matches,exact_accessible=exact,bytes=#json.encode(b),first_ms=bcold,p50_ms=percentile(ns,.5),p95_ms=percentile(ns,.95),has_more=b.has_more}}
end
-- Known original benchmark request(s), selected independently of the new ranking.
local source= json.decode(host.sql_query("SELECT t.id,t.content FROM messages t WHERE t.role='user' AND t.content LIKE '%benchmark%' AND (t.content LIKE '%pi%' OR t.content LIKE '%Pi%') AND substr(t.content,1,17)<>'[Sentinel notice]' ORDER BY t.created_at ASC LIMIT 5",'[]'))
local known=0
for _,anchor in ipairs(source) do
 local hits=search.search(memory,{query='benchmark',session_id=memory.message(anchor.id).session_id,group_by='message',roles={'user'},limit=50},nil)
 ok(not hits.error,'source-scoped retrieval succeeds')
 local found=false;for _,row in ipairs(hits.matches)do if row.id==anchor.id then found=true end end
 ok(found,'known original request retrieved');known=known+1
end
ok(known>0,'known-source positive controls exist')
local rows=json.decode(host.sql_query('SELECT COUNT(*) AS n FROM messages','[]'))[1].n
print(json.encode({ok=true,checks=checks,skipped=0,paid_calls=0,mode=replay and 'private_historical_snapshot' or 'synthetic',messages=rows,known_sources=known,queries=reports,
 limitation='First-call is process-cold, not OS-cache-cold. Warm timings alternate arms; deterministic source retrieval is not paid-model answer quality or token-cost proof.'}))
