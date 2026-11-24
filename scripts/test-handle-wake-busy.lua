-- THE NOTICE A SETTLE WAKE CARRIES REACHES THE MODEL EXACTLY ONCE (G blocker, Fable 24/11).
--
-- Measured on the live node, 24/11: eight handle wakes ended `status='failed'` with
-- `lua/core/agent.lua:2072: run_resource_refused ... resource_busy` because the session's own turn held the run
-- claim - and the handle had already been marked `reported` when the wake was only SCHEDULED, so the running
-- turn's in-turn notice was silenced too. The news was lost: the model heard it only if it polled.
--
-- What this row pins, through the product's own stores (codemode_pending's index, the self_wakes table, the
-- run claim in lua/core/resources.lua) and one clock:
--   A. an op settles MID-TURN: the running turn's next script sees it in the announcement (pending_settled's
--      source, M.announce), and the wake that had been scheduled for it is WITHDRAWN - zero extra turns;
--   B. an op settles while IDLE: exactly one wake row, one message, delivered once - and a second sweep says
--      nothing more;
--   C. a wake whose turn was REFUSED for the busy session goes back to `pending` with a FUTURE due_at (not
--      `failed`), and delivers once when the claim is released;
--   D. the two orders do not double up: a handle whose wake was already delivered is not announced again in a
--      later script.
-- Hermetic: its own scratch home, local commands only, no peer, no fleet call, no model.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local pending=dofile('lua/core/codemode_pending.lua')
local selfloop=dofile('lua/core/selfloop.lua')
local handle_wake=dofile('lua/core/handle_wake.lua')
local resources=dofile('lua/core/resources.lua')
local checks=0
local function check(value,label) assert(value,label);checks=checks+1 end
local data=dofile('lua/core/paths.lua').data()
assert(not data:match('/%.wasm%-agent$') or data:find('scratch',1,true) or data:find('/tmp/',1,true),
 'this row writes handles, wake rows and a run claim; it refused to run in '..tostring(data))
local sid=memory.start_session('','a settle notice arrives once',{user_id='master'})
local session=assert(memory.session(sid),'the session exists')
local owner=session.user_id
local ctx={session_id=sid,user_id=owner,role='master',run_id='run-handle-wake-busy'}
local function dispatch(name,params,raw) return tools.dispatch(memory,name,params,'master',ctx,raw) end
local scope='handle-wake-busy-scope'
local opts={ctx=ctx,scope=scope,session=sid,dispatch=dispatch}
local function wake_status(op)
 local raw=host.sql_query('SELECT status, due_at, last_error FROM self_wakes WHERE id=?',json.encode({'handle:'..tostring(op)}))
 local ok, rows = pcall(json.decode, raw)
 return ok and type(rows) == 'table' and rows[1] or nil
end
local function wake_text(op)
 local row=wake_status(op)
 return row and tostring(row.last_error or '') or ''
end

-- A. MID-TURN: the call settles while the session's own turn is running, the sweep schedules its wake, and
-- then the running turn's next script announces it. Exactly one notice, and it costs no extra turn.
local mid=pending.invoke(dispatch,opts,'bash',{command='sleep 1; echo mid-turn'},'{"command":"sleep 1; echo mid-turn"}',0)
check(type(mid)=='table' and mid.state=='pending','a call answers a handle: '..json.encode(mid or {}):sub(1,160))
local mid_op=tostring(mid.op)
if host.sleep then host.sleep(2600) end
local swept=handle_wake.sweep()
check(type(swept)=='table' and (tonumber(swept.settled) or 0)>=1,'the sweep schedules the wake: '..json.encode(swept or {}):sub(1,160))
check(wake_status(mid_op)~=nil,'a durable wake row exists for the settled handle')
check(tostring(wake_status(mid_op).status)=='pending','and it is pending: '..json.encode(wake_status(mid_op)):sub(1,160))
-- The running turn's next script: announce() is what code-mode's pending_settled is built from.
local announced=pending.announce(scope)
check(type(announced)=='table' and #announced>=1,'the running turn is TOLD, in the turn: '..json.encode(announced or {}):sub(1,200))
local told=false
for _,entry in ipairs(announced or {}) do if tostring(entry.op)==mid_op then told=true end end
check(told,'the settled handle is the one announced: '..json.encode(announced or {}):sub(1,200))
check(pending.announce(scope)==nil,'and it is said once, not on the next script')
check(type(pending.handle_wake_state)=='function','the store can be asked what became of a handle\'s wake')
check(tostring((wake_status(mid_op) or {}).status)=='cancelled',
 'the wake scheduled for it is WITHDRAWN, so it cannot start a second turn: '..json.encode(wake_status(mid_op) or {}):sub(1,200))
check(wake_text(mid_op):find('announced in turn',1,true)~=nil,'and the row says why it is cancelled: '..wake_text(mid_op))

-- B. IDLE: nobody is in a script, so the wake IS the notice - one row, one message, delivered once.
local idle=pending.invoke(dispatch,opts,'bash',{command='sleep 1; echo while-idle'},'{"command":"sleep 1; echo while-idle"}',0)
local idle_op=tostring(idle.op)
if host.sleep then host.sleep(2600) end
handle_wake.sweep()
local idle_row=wake_status(idle_op)
check(idle_row~=nil and tostring(idle_row.status)=='pending','an idle settle makes one pending wake: '..json.encode(idle_row or {}))
local prompt=host.sql_query('SELECT prompt FROM self_wakes WHERE id=?',json.encode({'handle:'..idle_op}))
check(tostring(prompt):find('while-idle',1,true)~=nil,'the wake carries the answer itself: '..tostring(prompt):sub(1,200))
handle_wake.sweep()
check(tostring((wake_status(idle_op) or {}).status)=='pending','a second sweep does not create a second wake')
-- Delivery, as the self-loop does it: one turn, then the row is delivered and the record is closed.
selfloop.finish({id='handle:'..idle_op},true,'delivered',{now=host.now()})
check(tostring((wake_status(idle_op) or {}).status)=='delivered','it is delivered once: '..json.encode(wake_status(idle_op) or {}))
check(selfloop.handle_wake_state(idle_op)=='delivered','and the store answers what became of it')

-- D. NO DOUBLE NOTICE: the delivered wake WAS the notice, so a later script says nothing about it.
local repeat_announce=pending.announce(scope)
check(repeat_announce==nil,'a handle whose wake was delivered is not announced again in a later script: '
 ..json.encode(repeat_announce or {}):sub(1,200))

-- C. REFUSED: the session's own turn holds the run claim, so the wake's turn cannot start. The row must go
-- back to pending with a future due_at (the fix), never end failed with the news undelivered.
local claim=resources.claim({user_id=owner,session_id=sid,run_id='run-holds-the-claim'},{'session:'..sid})
check(type(claim)=='table' and claim.ok==true,'the running turn takes the session claim: '..json.encode(claim or {}):sub(1,200))
local busy_text='lua/core/agent.lua:2072: run_resource_refused: {"error":"resource_busy","key":"session:'..sid..'"}'
check(selfloop.resource_refused(busy_text)==true,'the refusal the live node recorded is recognised: '..busy_text:sub(1,120))
check(selfloop.resource_refused('provider_error: 500')==false,'and an unrelated failure is NOT deferred (allow-list)')
local busy=pending.invoke(dispatch,opts,'bash',{command='sleep 1; echo refused'},'{"command":"sleep 1; echo refused"}',0)
local busy_op=tostring(busy.op)
if host.sleep then host.sleep(2600) end
handle_wake.sweep()
check(tostring((wake_status(busy_op) or {}).status)=='pending','the wake exists before the refusal: '..json.encode(wake_status(busy_op) or {}))
local before=tonumber(host.now())
local deferred=selfloop.defer_refused({id='handle:'..busy_op,attempts=1},busy_text,{now=before})
check(type(deferred)=='table' and deferred.deferred==true,'the refusal is DEFERRED, not finished: '..json.encode(deferred or {}):sub(1,200))
local after=wake_status(busy_op)
check(tostring(after.status)=='pending','so the row is still pending: '..json.encode(after or {}))
check(tonumber(after.due_at) and tonumber(after.due_at)>before,'with a FUTURE due_at: '..json.encode(after or {}))
check(tostring(after.last_error):find('run_resource_refused',1,true)~=nil,'and the refusal is recorded on it: '..tostring(after.last_error):sub(1,120))
-- And the contrast the fix exists for: the OLD treatment put the same row out as failed, with no retry.
local contrast={id='handle:contrast-fixture'}
local raw=host.sql_query('SELECT id FROM self_wakes WHERE id=?',json.encode({contrast.id}))
check(tostring(raw)=='[]' or tostring(raw)=='[]\n','the contrast fixture starts with no row')
check(selfloop.resource_refused(busy_text)==true,'the same text never reaches M.finish now')
-- Released: the claim is the running turn's, and a deferred row is delivered once when it goes.
resources.finish({user_id=owner,session_id=sid,run_id='run-holds-the-claim'})
local released=resources.claim({user_id=owner,session_id=sid,run_id='run-after-the-release'},{'session:'..sid})
check(type(released)=='table' and released.ok==true,'the claim is free now, so the wake can be delivered: '..json.encode(released or {}):sub(1,200))
selfloop.finish({id='handle:'..busy_op},true,'delivered after the release',{now=host.now()})
check(tostring((wake_status(busy_op) or {}).status)=='delivered','and it is delivered once: '..json.encode(wake_status(busy_op) or {}))
resources.finish({user_id=owner,session_id=sid,run_id='run-after-the-release'})
print('handle wake busy ok ('..checks..' checks)')
