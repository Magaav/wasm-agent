-- Private real SQLite; exact aggregation and unchanged-query work, no inference.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local telemetry=dofile('lua/core/telemetry.lua')
local cases=0
local function check(v,m) assert(v,m);cases=cases+1 end
local function sql(q,p) local r=json.decode(host.sql_exec(q,json.encode(p or {})));assert(not r.error,r.error) end
local sid=memory.start_session('','incremental',{user_id='master'})
local native=host.sql_query
local payloadRows,payloadBytes=0,0
host.sql_query=function(q,p)
 local raw=native(q,p)
 if q:find('FROM harness_events',1,true) and q:find('payload',1,true) then
  local r=json.decode(raw);for _,row in ipairs(r) do payloadRows=payloadRows+1;payloadBytes=payloadBytes+#(row.payload or '') end
 end
 return raw
end
local u=telemetry.normalize({prompt_tokens=100,completion_tokens=20,prompt_tokens_details={cached_tokens=80},completion_tokens_details={reasoning_tokens=5}},{input=1,output=2,cacheRead=.1})
for i=1,1000 do
 telemetry.event(sid,'run'..i,'span'..i,'model_call','start',{model='test',padding=string.rep('x',400)})
 telemetry.event(sid,'run'..i,'span'..i,'model_call','end',{ok=i%13~=0,normalized=u,ms=i,error=i%13==0 and 'fixture failure' or nil})
end
local a=telemetry.snapshot(sid)
check(a.total.calls==1000 and a.total.prompt==100000 and a.pending==0,'full exact accounting')
check(a.request_p50_ms==500 and a.request_p95_ms==950,'exact percentiles')
check(#a.errors==10,'retained latest failures')
local firstRows,firstBytes=payloadRows,payloadBytes
local clock,clockDelta=host.monotonic_ms,0
host.monotonic_ms=function()return clock()+clockDelta end
local began=clock()
for i=1,20 do clockDelta=clockDelta+5000;local b=telemetry.snapshot(sid);check(b.total.prompt==a.total.prompt,'unchanged accounting') end
local unchangedMs=clock()-began
host.monotonic_ms=clock
check(payloadRows==firstRows and payloadBytes==firstBytes,'unchanged status reads zero historical payloads')
a.total.prompt=-1;check(telemetry.snapshot(sid).total.prompt==100000,'detached public snapshot')
local span=telemetry.start({session_id=sid,run_id='new'},'summary',{})
check(telemetry.snapshot(sid).pending==1,'new start immediately fresh')
telemetry.finish(span,{ok=false,normalized=telemetry.normalize(nil),ms=1001,error='new failure'})
local b=telemetry.snapshot(sid)
check(b.total.calls==1001 and b.compaction.failed==1 and b.pending==0,'append exact and failed summary counted')
check(not b.total.cost_known and b.total.missing_usage==1,'unknown usage remains unknown')
check(payloadRows==firstRows+2,'only two appended payloads fetched')
local reloaded=dofile('lua/core/telemetry.lua').snapshot(sid)
check(json.encode(reloaded.total)==json.encode(b.total) and reloaded.request_p95_ms==b.request_p95_ms,'module restart equivalence')
sql("UPDATE harness_events SET payload=? WHERE session_id=? AND span_id='span1' AND phase='end'",{json.encode({ok=true,normalized=u,ms=9999}),sid})
check(telemetry.snapshot(sid).request_p95_ms==951,'same-count repair invalidates percentiles')
sql("DELETE FROM harness_events WHERE session_id=? AND span_id='span2'",{sid})
check(telemetry.snapshot(sid).total.calls==1000,'delete invalidates without deleting anything outside private fixture')
sql("UPDATE sessions SET summary=?,summarized_until=3 WHERE id=?",{'é🙂',sid})
check(telemetry.snapshot(sid).context.summary_bytes==6,'fresh summary byte count, not Unicode character count')
local other=memory.start_session('','other',{user_id='master'})
check(not telemetry.snapshot(other).available,'session isolation')
local cursor=json.decode(native('SELECT MAX(seq) AS seq FROM harness_events WHERE session_id=?',json.encode({sid})))[1].seq
-- Make a private unused sequence below the cursor, establish a cache, then import it.
sql("DELETE FROM harness_events WHERE session_id=? AND span_id='span10' AND phase='start'",{sid})
local beforeImport=telemetry.snapshot(sid)
local hole=json.decode(native("SELECT seq FROM harness_events WHERE session_id=? AND span_id='span10' AND phase='end'",json.encode({sid})))[1].seq-1
sql('INSERT INTO harness_events(seq,id,session_id,run_id,span_id,kind,phase,at,payload) VALUES(?,?,?,?,?,?,?,?,?)',{hole,host.uuid(),sid,'import','import','tool','end',host.now(),json.encode({ok=false,ms=10,error='imported failure'})})
local imported=telemetry.snapshot(sid)
check(imported.events==beforeImport.events+1 and imported.tool_failures==beforeImport.tool_failures+1,'below-highwater import invalidates and is accounted')
check(json.decode(native('SELECT MAX(seq) AS seq FROM harness_events WHERE session_id=?',json.encode({sid})))[1].seq==cursor,'import did not move highwater')
for i=1,10 do local s=memory.start_session('','lru '..i,{user_id='master'});telemetry.snapshot(s) end
check(telemetry.snapshot(sid).total.calls==1000,'LRU eviction rebuilds exact totals')
local plan=json.encode(json.decode(native("EXPLAIN QUERY PLAN SELECT COUNT(*) AS rows,MIN(seq),MAX(seq) FROM messages WHERE session_id=? AND seq>? AND role<>'summary'",json.encode({sid,0}))))
check(plan:find('messages_status_coverage',1,true)~=nil,'context coverage uses narrow partial index')
sql("UPDATE harness_events SET payload='bad-json' WHERE session_id=? AND span_id='span3' AND phase='end'",{sid})
check(telemetry.snapshot(sid).reason=='ledger_unreadable','malformed evidence visible, never silently omitted')
local saved=host.sql_query;host.sql_query=function() return json.encode({error='fixture busy'}) end
check(telemetry.snapshot(other).reason=='ledger_unreadable','read refusal cannot serve stale success')
host.sql_query=saved
print('telemetry incremental ok '..cases..' checks; historical rows '..firstRows..' bytes '..firstBytes..'; repeated payload rows 0; 20 reads ms '..unchangedMs)
