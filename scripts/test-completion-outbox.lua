local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local original=dofile
local authorized=true
dofile=function(p)
 if p=='lua/core/users.lua' then return {find=function() return {role=authorized and 'master' or 'guest'} end,is_master=function(role) return role=='master' end} end
 if p=='lua/core/nodes.lua' then return {is_master=function() return true end} end
 return original(p)
end
local completions=original('lua/core/completions.lua');dofile=original
local sid=memory.start_session('','parent',{user_id='owner'})
local ctx={user_id='owner',role='master',session_id=sid}
local enqueues=0
host.enqueue_completion=function() enqueues=enqueues+1;return json.encode({accepted=true,run_id=123}) end
local api={control=function(a) return {subagent_id=a.id,state='completed',settled=true,session_id='child'} end}
completions.watch('child',ctx);completions.watch('child',ctx)
completions.tick(api);completions.tick(api)
assert(enqueues==1,'one durable wake per task')
host.sql_exec("UPDATE child_completions SET boot='previous-boot'",'[]')
completions.tick(api)
local rows=json.decode(host.sql_query('SELECT * FROM child_completions','[]'))
assert(rows[1].state=='unknown' and enqueues==1,'ambiguous wake is never replayed')
completions.watch('denied',ctx);authorized=false;completions.tick(api)
assert(enqueues==1,'authority revoked before enqueue')
authorized=true
completions.watch('capacity',ctx)
host.enqueue_completion=function() enqueues=enqueues+1;return json.encode({error='full',not_started=true}) end
completions.tick(api)
rows=json.decode(host.sql_query("SELECT * FROM child_completions WHERE child_id='capacity'",'[]'))
assert(rows[1].state=='ready','proven not-started can retry')
completions.watch('remote',ctx,'remote-run-1');completions.watch('remote',ctx,'remote-run-2')
rows=json.decode(host.sql_query("SELECT * FROM child_completions WHERE target_id='remote'",'[]'))
assert(#rows==2,'remote followups have distinct durable identities')
host.sql_exec("UPDATE child_completions SET state='blocked' WHERE state IN ('watching','ready')",'[]')
for i=1,40 do completions.watch('slow-'..i,ctx) end
completions.watch('last-ready',ctx)
local seen={}
host.enqueue_completion=function(raw)
 local a=json.decode(raw);seen[a.id]=true
 return json.encode({accepted=true,run_id=456})
end
local mixed={control=function(a) return {subagent_id=a.id,state=a.id=='last-ready' and 'completed' or 'running',settled=a.id=='last-ready'} end}
completions.tick(mixed);completions.tick(mixed)
assert(seen['last-ready'],'unfinished first page cannot starve later completed children')
assert(completions.status('last-ready','owner').state=='accepted','delivery state inspectable')
assert(not completions.status('last-ready','other'),'delivery state owner-scoped')
print('completion outbox ok (deduplication, restart ambiguity, revoked authority, capacity retry, fair scan, owner-scoped status)')
