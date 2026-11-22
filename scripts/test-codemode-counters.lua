-- The three counters the next mission is planned from (21/11; docs/CODEMODE.md, "The three counters").
--
-- Telemetry only: nothing here changes a decision. What is asserted is that each counter is counted
-- where the thing it names happens, once per event and never per call:
--
--   * script_cut_at_cap - a script that was told "not yet" (a pending answer) increments once;
--   * handle_mishandled - a script that used a pending answer as if it had settled increments once;
--   * wake_only_round   - the read/write half is held here (an unknown name is refused, a count that
--     was never bumped is 0); the increment itself is in selfloop.run_wake, on the handle-wake turn,
--     which needs a model and is covered there rather than here.
-- Hermetic: its own scratch home, local commands only.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local counters=dofile('lua/core/counters.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
local data=dofile('lua/core/paths.lua').data()
assert(not data:match('/%.wasm%-agent$') or data:find('scratch',1,true) or data:find('/tmp/',1,true),
 'this row needs a scratch HOME (it writes counters); it refused to run in '..tostring(data))
local sid=memory.start_session('','the three counters',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local function dispatch(name,params,raw) return tools.dispatch(memory,name,params,'master',ctx,raw) end
local function run(code,timeout_ms)
 local args={code=code}
 if timeout_ms then args.timeout_ms=timeout_ms end
 local result=codemode.run(memory,args,'master',ctx,catalog,function()return catalog end,dispatch,execution)
 return result
end

-- Nothing counted before anything happened: a counter nobody bumped is 0, not absent.
local start=counters.read()
check(start.script_cut_at_cap==0 and start.handle_mishandled==0 and start.wake_only_round==0,
 'every counter starts at 0 in a fresh home: '..json.encode(start))
check(counters.bump('not_a_counter')==nil and counters.read().not_a_counter==nil,
 'an unknown counter name is refused instead of creating a key nobody reads')

-- 1. A script told "not yet": one increment, and one only, however many handles it leaves.
local left=run([==[
const first = await tools.bash({command: 'sleep 5', wait_s: 0});
const second = await tools.bash({command: 'sleep 5', wait_s: 0});
return {first: first.state, second: second.state};
]==],60000)
check(left.ok==true,'a script that leaves two handles runs: '..tostring(left.error))
local after_cut=counters.read()
check(after_cut.script_cut_at_cap==1,
 'a script that was told not yet increments script_cut_at_cap ONCE, not once per handle: '
 ..json.encode(after_cut))
check(after_cut.handle_mishandled==0,'and handling the handle properly is not a mishandling')

-- 2. A script that used a pending answer as a result: the pending-value TypeError, counted once.
local misused=run([==[
const started = await tools.bash({command: 'sleep 5', wait_s: 0});
const promise = tools.bash({command: 'sleep 5', wait_s: 0});
return {out: promise.stdout};
]==],60000)
check(misused.ok==false and tostring(misused.error or ''):find('has not resolved yet',1,true)~=nil,
 'using a pending answer as a result still throws the pending-value TypeError: '
 ..tostring(misused.error):sub(1,200))
local after_misuse=counters.read()
check(after_misuse.handle_mishandled==1,
 'and that is counted once as handle_mishandled: '..json.encode(after_misuse))
-- The same script also left a handle behind, and that is its own increment: the two counters answer
-- two different questions about one script.
check(after_misuse.script_cut_at_cap==2,
 'and the handle it left is the same script being cut at its cap once more: '..json.encode(after_misuse))

-- 3. A plain script that waits properly counts nothing.
local clean=run([==[
const done = await tools.bash({command: 'echo fine'});
return {code: done.code};
]==],60000)
check(clean.ok==true,'a plain script runs: '..tostring(clean.error))
local after_clean=counters.read()
check(after_clean.script_cut_at_cap==after_misuse.script_cut_at_cap
  and after_clean.handle_mishandled==after_misuse.handle_mishandled,
 'a script that waits for its calls moves neither counter: '..json.encode(after_clean))

-- 4. The wake-only round's own counter is readable and writable through the same door.
check(counters.bump('wake_only_round')==1 and counters.read().wake_only_round==1,
 'wake_only_round counts the steps whose only input was a settled handle')

-- 5. THE THREE-NAME ANSWER IS UNCHANGED (parity): the day book is beside the totals, never in them,
-- so every existing reader (/stats, and the run turn's own report) sees exactly what it saw before.
local three=counters.read()
local seen=0
for _ in pairs(three) do seen=seen+1 end
check(three.days==nil and seen==3,
 'read() answers the three numbers and nothing else: '..json.encode(three))

-- 6. A DAY BOOK, because "high" is a rate and not a total: a bump lands in today\'s bucket on the
-- node's own clock, and the total moves the same amount.
local now=host.now()
local today=counters.day_of(now)
local yesterday=counters.day_of(now-86400)
local before=counters.read()
local book_before=counters.book()
local today_before=(book_before[today] and book_before[today].wake_only_round) or 0
check(counters.bump('wake_only_round')==before.wake_only_round+1
  and counters.read().wake_only_round==before.wake_only_round+1,
 'the bump still answers the new total: '..json.encode(counters.read()))
local book=counters.book()
check(type(book[today])=='table' and book[today].wake_only_round==today_before+1,
 'and it is in today\'s bucket: '..json.encode(book))

-- 7. A bump that names a day lands there and only there.
local mis_before=before.handle_mishandled
check(counters.bump('handle_mishandled',2,{now=now-86400})==mis_before+2,
 'a bump with a named time still answers the new total')
local dated=counters.book()
local yesterday_before=(book_before[yesterday] and book_before[yesterday].handle_mishandled) or 0
local today_mis=(book[today] and book[today].handle_mishandled) or 0
check(dated[yesterday] and dated[yesterday].handle_mishandled==yesterday_before+2
  and dated[today].handle_mishandled==today_mis,
 'and it is counted into THAT day, not today: '..json.encode(dated))

-- 8. A day the store never saw is NOT RECORDED, never three zeros: unknown is not yes.
local window=counters.window(3,now)
check(#window==3 and window[1].day==today and window[2].day==yesterday,
 'the window is the last three calendar days, today first: '..json.encode(window))
check(window[1].recorded==true and window[2].recorded==true and window[3].recorded==false,
 'a day with a bucket is recorded and a day without one says so: '..json.encode(window))
check(window[3].wake_only_round==0 and window[3].script_cut_at_cap==0,
 'and an unrecorded day carries no claim about its numbers')

-- 9. The book is BOUNDED: the newest M.DAYS_KEPT days are kept and the oldest go, so the document a node
-- rewrites on every bump cannot grow without a ceiling.
for back=10,10+counters.DAYS_KEPT+1 do
 pcall(function() counters.bump('wake_only_round',1,{now=now-back*86400}) end)
end
local bounded=counters.book()
local kept=0
for _ in pairs(bounded) do kept=kept+1 end
check(kept==counters.DAYS_KEPT,
 string.format('the day book keeps exactly %d days, not %d: the document stays bounded',
  counters.DAYS_KEPT,kept))
check(bounded[counters.day_of(now-(10+counters.DAYS_KEPT+1)*86400)]==nil,
 'and the oldest day written is the one that was dropped')


-- 10. THE COMMAND (cross-process, which is how the operator reads it): `wa counters` prints these
-- numbers from this node's own ledger. A check that cannot run - no binary, no ledger path - FAILS by
-- name rather than passing, and the binary is the one this run is about (WA_FAST_BIN, else the node
-- this row IS), so the row judges the tree and not whatever is on PATH.
local info={}
if type(host.runtime_info)=='function' then
 local ok,raw=pcall(host.runtime_info)
 if ok then
  local decoded=type(raw)=='string' and json.decode(raw) or raw
  info=type(decoded)=='table' and decoded or {}
 end
end
local binary=tostring(host.getenv('WA_FAST_BIN') or info.binary_path or '')
local root=tostring(host.getenv('WASM_AGENT_LUA_ROOT') or '')
local db=tostring(host.getenv('WASM_AGENT_DB') or '')
local home=tostring(dofile('lua/core/paths.lua').home())
check(binary~='' and db~='' and root~='',
 'the command half needs the node binary, this tree and this ledger: binary='..binary..' root='..root..' db='..db)
local function shell(command)
 local ok,raw=pcall(host.exec,command)
 if not ok then return nil,tostring(raw) end
 local decoded_ok,decoded=pcall(json.decode,raw)
 if not decoded_ok or type(decoded)~='table' then return nil,'unreadable answer: '..tostring(raw):sub(1,200) end
 return decoded
end
local child="env WASM_AGENT_HOME='"..home.."' WASM_AGENT_LUA_ROOT='"..root.."' '"..binary.."' --db '"..db.."'"
local as_json,why=shell(child.." counters --json 2>&1")
check(type(as_json)=='table','`wa counters --json` ran: '..tostring(why or (as_json and (as_json.stderr or as_json.stdout))))
local printed=json.decode(tostring(as_json.stdout or ''))
check(type(printed)=='table',
 'and printed one JSON document: '..tostring(as_json.stdout):sub(1,300)..tostring(as_json.stderr):sub(1,300))
local totals=counters.read()
check(printed.wake_only_round==totals.wake_only_round
  and printed.script_cut_at_cap==totals.script_cut_at_cap
  and printed.handle_mishandled==totals.handle_mishandled,
 'and its numbers are this row\'s own ledger, read from another process: '
 ..json.encode({printed=printed,totals=totals}))
check(type(printed.window)=='table' and printed.window[1] and printed.window[1].day==today
  and printed.window[1].recorded==true,
 'with the same per-day window: '..json.encode(printed.window))
local human=shell(child.." counters 2>&1")
check(type(human)=='table' and human.ok==true,'and the plain command exits 0')
local text=tostring(human.stdout or '')
local named=true
for _,name in ipairs(counters.NAMES) do if not text:find(name,1,true) then named=false end end
check(named,'and names all three counters in words an operator reads: '..text:sub(1,400))
-- A window the store does not keep is refused by name rather than printed as a different number.
local refused=shell(child.." counters --days 0 2>&1")
check(type(refused)=='table' and tostring(refused.code)~='0'
  and tostring(refused.stdout or ''):find('1..',1,true)~=nil,
 'a window of 0 days is refused, not silently read as something else: '
 ..json.encode({code=refused and refused.code,out=tostring(refused and refused.stdout):sub(1,200)}))


-- Leave nothing running.
local pending=dofile('lua/core/codemode_pending.lua')
local opened=pending.list(dispatch,{ctx=ctx})
for _, handle in ipairs(type(opened)=='table' and opened.ops or {}) do
 pcall(function() pending.cancel(dispatch,{ctx=ctx},handle.op) end)
end
print(string.format('codemode counters: %d checks',checks))
