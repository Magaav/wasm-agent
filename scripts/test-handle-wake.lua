-- A settled pending handle wakes its session (21/11).
--
-- The rule (Victor, copying Claude Code): a script that hands back a handle leaves work running, and
-- when that work ends the model must be told BY ITSELF - the node does not wait for the operator to
-- type, and the model never has to poll with wait(). This row holds the whole route without a model,
-- a provider or a terminal:
--
--   1. a handle settles while nobody waits on it;
--   2. the sweep schedules ONE durable wake row for it - a self_wakes row, the same table the model's
--      own wakes live in, which the node's placement tick and the CLI's idle prompt both claim;
--   3. the row's words are the answer itself in the flat shape wait(op) answers, plus the handles
--      that are STILL pending with their age;
--   4. exactly once: a second sweep, a reloaded sweep (a restart) and the next script's
--      pending_settled never say it again, and no effect is ever re-run.
--
-- Hermetic: its own scratch home, local commands only, no peer and no fleet call.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local pending=dofile('lua/core/codemode_pending.lua')
local selfloop=dofile('lua/core/selfloop.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
-- A scratch home of this row's own, and a refusal to run anywhere else: this row writes handle
-- indexes and wake rows.
local data=dofile('lua/core/paths.lua').data()
assert(not data:match('/%.wasm%-agent$') or data:find('scratch',1,true) or data:find('/tmp/',1,true),
 'this row needs a scratch HOME (it writes handles and wakes); it refused to run in '..tostring(data))
local sid=memory.start_session('','a settled handle wakes its session',{user_id='master'})
local session=assert(memory.session(sid),'the session exists')
local owner=session.user_id
local ctx={session_id=sid,user_id=owner,role='master'}
local function dispatch(name,params,raw) return tools.dispatch(memory,name,params,'master',ctx,raw) end
local scope='handle-wake-scope'
local opts={ctx=ctx,scope=scope,session=sid,dispatch=dispatch}
local function wake_rows()
 local rows=selfloop.list({session_id=sid},ctx)
 return type(rows)=='table' and rows.wakes or {}
end
local function wake_row(op)
 local id='handle:'..tostring(op)
 for _,row in ipairs(wake_rows()) do if tostring(row.id)==id then return row end end
end
local function wake_prompt(op)
 local raw=host.sql_query('SELECT prompt, status, due_at FROM self_wakes WHERE id=?',json.encode({'handle:'..tostring(op)}))
 local decoded=json.decode(raw)
 return decoded[1]
end

-- 1. Two calls: one that settles while nobody waits, one that is still running when the wake is made.
local long=pending.invoke(dispatch,opts,'bash',{command='sleep 30'},'{"command":"sleep 30"}',0)
check(type(long)=='table' and long.state=='pending' and type(long.op)=='string','a long call answers a handle')
local short=pending.invoke(dispatch,opts,'bash',{command='sleep 1; echo woke up'},'{"command":"sleep 1; echo woke up"}',0)
check(type(short)=='table' and short.state=='pending','a second call answers its handle too')
local short_op,long_op=tostring(short.op),tostring(long.op)
-- The short one settles with nobody looking: this row never calls wait() on it.
if host.sleep then host.sleep(2500) end
local handle_wake=dofile('lua/core/handle_wake.lua')
local swept=handle_wake.sweep()
check(type(swept)=='table' and (tonumber(swept.settled) or 0)>=1,
 'the sweep settles the finished call and wakes the session: '..json.encode(swept or {}):sub(1,220))
local row=wake_row(short_op)
check(row~=nil,'one durable wake row exists for the settled handle: '..json.encode(wake_rows()):sub(1,240))
check(row and tostring(row.status)=='pending','and it is pending, so the next claim runs the turn: '..json.encode(row or {}):sub(1,200))
check(row and tostring(row.reason)=='a pending call settled','the row says what woke the session: '..tostring(row and row.reason))
local stored=(wake_prompt(short_op) or {}).prompt or ''
check(stored:find('woke up',1,true)~=nil,
 'the row carries the answer itself, not a hash to look up: '..tostring(stored):sub(1,320))
check(stored:find('Still pending (1)',1,true)~=nil and stored:find(long_op,1,true)~=nil,
 'and lists the handles still pending, with the op that is still running: '..tostring(stored):sub(1,420))
check(stored:find(string.format('%s (bash',long_op),1,true)~=nil,
 'each still-pending handle names its tool and age: '..tostring(stored):sub(1,420))
check(stored:find(string.format('%s (bash, running, ',long_op),1,true)~=nil,
 'and names its STATE, not only its tool: unknown is not the same news as running: '..tostring(stored):sub(1,420))
check(stored:find('"result"',1,true)==nil,
 'the answer is the flat shape - nothing is nested under a result key: '..tostring(stored):sub(1,320))

-- 2. Exactly once: the same sweep again, a fresh module (a restart), and the next script's announcement.
local again=handle_wake.sweep()
check(wake_row(short_op)~=nil and #wake_rows()==#wake_rows(),'a second sweep keeps the one row')
local before=#wake_rows()
local reloaded=dofile('lua/core/handle_wake.lua')
reloaded.sweep()
check(#wake_rows()==before,'a restart between settle and wake does not schedule it twice: '
 ..json.encode({before=before,after=#wake_rows()}):sub(1,200))
-- THE ONE-NOTICE CONTRACT (G blocker, Fable 24/11). Before this, scheduling the wake also marked the handle
-- `reported`, so a script that ran before the wake was claimed was told NOTHING - and a wake whose turn was
-- then refused (a busy session) meant the model never heard at all. Now the script IS the notice when it gets
-- there first, and the wake scheduled for the same handle is withdrawn so it cannot say the same thing again.
local announced=pending.announce(scope)
local told_once=false
for _,entry in ipairs(type(announced)=='table' and announced or {})do if entry.op==short_op then told_once=true end end
check(told_once==true,'the next script tells the model the call settled: '..json.encode(announced or {}):sub(1,200))
local withdrawn=wake_row(short_op)
check(withdrawn==nil or tostring(withdrawn.status)=='cancelled',
 'and the wake scheduled for it is withdrawn, so it cannot spend a turn repeating it: '..json.encode(withdrawn or {}):sub(1,200))
local second=pending.announce(scope)
local said_again=false
for _,entry in ipairs(type(second)=='table' and second or {})do if entry.op==short_op then said_again=true end end
check(said_again==false,'and a second script says nothing: exactly once, by construction')
-- The effect ran once: the wake scheduled a turn, it never re-ran anything.
local retained,why=pending.retained(short_op,scope)
check(type(retained)=='table' and tostring(retained.stdout or ''):find('woke up',1,true)~=nil,
 'the handle keeps its own answer for results.get: '..tostring(why))

-- 3. The route both surfaces use: the row is claimable, which is exactly what the node's placement
-- tick and the CLI's idle prompt do with a due wake. Its own handle, because the script above already
-- WITHDREW the first one's (that is the one-notice contract, and both halves have to be true).
local idle=pending.invoke(dispatch,opts,'bash',{command='sleep 1; echo while nobody looked'},'{"command":"sleep 1; echo while nobody looked"}',0)
local idle_op=tostring(idle.op)
if host.sleep then host.sleep(2500) end
handle_wake.sweep()
local claimed=selfloop.claim_due(sid,owner)
check(type(claimed)=='table' and tostring(claimed.id)=='handle:'..idle_op,
 'the CLI idle prompt / node tick claims a due wake as its own row: '..json.encode(claimed or {}):sub(1,200))
selfloop.finish(claimed,true,'a delivered wake',{now=host.now()})
check(tostring((wake_prompt(idle_op) or {}).status)=='delivered',
 'and delivering it closes the row: '..json.encode(wake_prompt(idle_op) or {}):sub(1,160))
local after_delivery=pending.announce(scope)
local repeated_after_wake=false
for _,entry in ipairs(type(after_delivery)=='table' and after_delivery or {})do if entry.op==idle_op then repeated_after_wake=true end end
check(repeated_after_wake==false,'a handle whose wake was delivered is not announced again in a script')

-- Leave nothing running: the long call is stopped, and the row is settled the way a failed turn settles.
local stopped=pending.cancel(dispatch,opts,long_op)
check(type(stopped)=='table','the long call is stopped so this row leaves nothing running')
selfloop.finish(claimed,false,'a test does not run a model turn')

print(string.format('handle wake: %d checks',checks))
