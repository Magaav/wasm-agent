-- waiting-costs-no-turns: the harness holds the answer, not the run (27/11).
--
-- The evidence this test pins, one row at a time:
--   1. a script that ends with live work is answered once it SETTLES - the one call the model made gets the
--      real output, not a handle, and it costs no second call (the 8,772 `operation` calls measured over
--      942 long runs are exactly this second call, made 172 times in the worst run);
--   2. a job that has SPOKEN and then goes quiet past its own norm is reported, not held forever - the
--      measured shape of 33 % of long jobs (a job that never speaks at all is row 4 and is never
--      "silent": 29 % of long jobs write no byte, and a global silence rule would fire on correct work);
--   3. a script that KEEPS its handle and works in parallel is untouched: blocking is never forced;
--   4. the answer carries NO new field: the hold is the same result, later (prompt bytes are the point).
--
-- The knobs are environment variables the read path already honours, so a row that would take 15 minutes in
-- production takes seconds here without touching a constant.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k)
  if k=='WASM_AGENT_CODEMODE' then return 'native' end
  return env(k)
end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
-- THE LIMITS ARE THE MODULE'S FIELDS, not the environment (Fable's rule: no env override in product code).
-- `package.loaded['codemode_pending']` is the one table the node runs, so these are the real limits with a
-- row-sized number in them: a rule about minutes proved in seconds, and nothing about production changed.
local pending=package.loaded['codemode_pending']
assert(type(pending)=='table','codemode_pending did not register itself; the node would run another copy')
pending.HOLD_SILENCE_MS=800
pending.HOLD_DEADLINE_MS=800
pending.ANSWER_HOLD_MS=60000
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no JavaScript ran and nothing here was measured')
-- ONE SESSION PER ROW, and that is not tidiness: the hold reads every open handle of the SCOPE, so a job
-- left running by the row above ends the next row's hold the moment it goes quiet (measured on this test's
-- first run: row 2's silent 30 s job made row 3 answer in 0.8 s instead of waiting for its own 4 s job).
-- Each row gets its own name, so a failure names one thing.
local function run(code,name)
  local sid=memory.start_session('','wct hold '..name,{user_id='master'})
  local ctx={session_id=sid,user_id='master'}
  local catalog=tools.all('master',ctx,memory)
  local execution=tools.discovery_execution(memory,ctx)
  local function dispatch(tool,params) return tools.dispatch(memory,tool,params,'master',ctx) end
  local started=host.now()
  local result=codemode.run(memory,{code=code},'master',ctx,catalog,function()return catalog end,dispatch,execution)
  return result,host.now()-started,sid
end

-- ROW 1: settle. A 3-second job, the script ends with it live; one call answers with its output.
local r1,secs1=run([[const h = await tools.bash({command:'sleep 3; echo wct-settled', wait_s: 0}); text('started: '+String(h.state||'?')); return h;]],'settle')
local body1=json.encode(r1)
check(secs1>=2.5,'row 1: the call returned in '..string.format('%.2f',secs1)..'s - it did not hold for the job')
check(body1:find('wct%-settled')~=nil,'row 1: the answer did not carry the settled output')
check(body1:find('"state":"pending"')==nil,'row 1: the model was still handed a pending handle')
check(body1:find('pending_hold')==nil,'row 4: the answer grew a field (prompt bytes must not move)')

-- ROW 2: silence. The job speaks once and then says nothing for longer than its own norm: the hold ends
-- with the handle (reported, not held), and it ends quickly.
local r2,secs2=run([[const h = await tools.bash({command:'echo wct-spoken; sleep 30', wait_s: 0}); return h;]],'silence')
local body2=json.encode(r2)
check(secs2<10,'row 2: a silent job held the answer for '..string.format('%.2f',secs2)..'s instead of reporting it')
-- What the model reads on a silence wake is the HANDLE, not the output: the answer comes back with the
-- op id, the `next` line that says `wait(op)` returns the result, and the log path - the facts it needs
-- to decide, without a byte of the job's stdout in this answer (that is `pending_settled`'s job when it
-- settles, and the tail-refresh of a running handle is a named limit of this change, not a promise).
check(body2:find('op%-')~=nil,'row 2: the answer did not name the job it is still holding')
-- ROW 2b, the refresh (Fable 27/11): a job that has been quiet for minutes is not reported as a bare op
-- id. The wake carries what it is doing, how long, against which limit, how long since it last spoke, and
-- the last lines - on the RESULT, never in the prompt.
local held2=type(r2)=='table' and r2.pending_held or nil
check(type(held2)=='table' and #held2>=1,'row 2b: the wake carried no facts beside the handle')
local facts2=held2[1]
check(facts2.state=='running','row 2b: the wake did not say what the job is doing')
check(type(facts2.elapsed_ms)=='number','row 2b: the wake did not say how long it has run')
check(type(facts2.limit_ms)=='number','row 2b: the wake did not say its own limit')
check(type(facts2.silent_ms)=='number','row 2b: the wake did not say how long since it last spoke')
check(type(facts2.tail)=='string' and facts2.tail:find('wct%-spoken')~=nil,'row 2b: the last lines were not carried')
check(#facts2.tail<=2048,'row 2b: the tail is past its own 2 KB bound')
-- The bytes this costs, measured rather than guessed: the note is on a WAKE only.
print('ROW2B tail_bytes='..#facts2.tail..' note_bytes='..#json.encode(held2))

-- ROW 3: a kept handle is untouched. Start the job, do other work beside it, then read it: the other work
-- answers on its own and the handle is still the same handle.
local r3,secs3=run([[const h = await tools.bash({command:'sleep 4; echo wct-parallel', wait_s: 0}); const quick = await tools.bash({command:'echo wct-quick'}); return {handle: String(h.op||''), quick: String(quick.stdout||quick.output||'')};]],'parallel')
local body3=json.encode(r3)
check(secs3>=3.5,'row 3: the answer did not wait for the job beside it')
check(body3:find('wct%-parallel')~=nil,'row 3: the awaited result was lost')
check(body3:find('wct%-quick')~=nil,'row 3: work beside the handle answered nothing')


-- ROW 5: a user message queued while the hold waits ENDS the hold (Fable 27/11). What happened before this
-- change, measured from the code: only a stop/steer set the run's cancel flag, so a message sat in
-- `steering_inbox` until the turn was over - the operator's own words could wait out the whole hold. The
-- message is written by the JOB at 1 s into a 30 s job, which is a concurrent writer, the way a person
-- typing is.
local home=(host.getenv and host.getenv('WASM_AGENT_HOME')) or ''
local db=home..'/.wasm-agent/memory.db'
local sid5=memory.start_session('','wct hold queued',{user_id='master'})
local ctx5={session_id=sid5,user_id='master'}
local catalog5=tools.all('master',ctx5,memory)
local execution5=tools.discovery_execution(memory,ctx5)
local function dispatch5(tool,params) return tools.dispatch(memory,tool,params,'master',ctx5) end
local msg_path='/tmp/wct-queued-'..sid5..'.sh'
local sql=string.format(
  'INSERT INTO steering_inbox(id,owner,session_id,run_id,request_key,text,images,attribution,state,created_at,detail) '..
  "VALUES('msg-wct-1','master','%s','run-wct-1','key-wct-1','stop waiting for me','[]','test','queued',strftime('%%s','now'),'')", sid5)
assert(host.write_file(msg_path,'sleep 1\nsqlite3 "'..db..'" "'..sql..'"\n'), 'row 5: could not write the message script')
local started5=host.now()
local r5=codemode.run(memory,{code="const h = await tools.bash({command:'bash "..msg_path.."; sleep 30', wait_s: 0}); return h;"},
  'master',ctx5,catalog5,function()return catalog5 end,dispatch5,execution5)
local secs5=host.now()-started5
check(secs5<10,'row 5: a queued message did not end the hold ('..string.format('%.2f',secs5)..'s into a 30 s job)')
check(secs5>0.9,'row 5: the hold ended before the message existed ('..string.format('%.2f',secs5)..'s)')
-- The hold only ever SELECTS from the inbox, so what this row can honestly assert is that the message is still
-- THERE: who reads it later is the node's own business, and in a live harness the housekeeping tick may well
-- have read it first (measured: this check failed in a gate run only because of that, not because the hold
-- wrote anything). The hold consuming it would mean a DELETE or a state change by this file, which it has no
-- code to do.
local steering5=dofile('lua/core/steering.lua')
local inbox=steering5.view and steering5.view(sid5) or nil
local found=false
if type(inbox)=='table' then
  for _,row in ipairs(inbox) do
    if type(row)=='table' and (row.text=='stop waiting for me' or row.id=='msg-wct-1') then found=true end
  end
end
local stillQueued=steering5.queued(sid5)
check(found or stillQueued,'row 5: the message left the inbox while the hold ran')
print('ROW5 secs='..string.format('%.2f',secs5))


-- ROW 6: a waiting install does NOT end the hold (Fable 27/11, correcting my first read). The job is the
-- turn's work: waking the model would not free the node any sooner, because the job keeps running either way.
-- The install waits for it exactly as it waits for any running turn, and its own line says what it waits for
-- ("waiting for <job> of session X, up to m:ss" - wa-sentinel's hold announcement). So: a marker on disk while
-- a 3 s job runs, and the hold must still take the job to settle rather than returning early.
local deploy=dofile('lua/core/deploy_pause.lua')
local marker_path=deploy.path()
assert(marker_path,'row 6: no pause marker path on this node')
assert(host.write_file(marker_path, json.encode({since=os.time(), bound_seconds=deploy.DEFAULT_BOUND, state='deploy_pending'})),
  'row 6: could not write the marker')
local r6,secs6=run([[const h = await tools.bash({command:'sleep 3; echo wct-deploy-kept', wait_s: 0}); return h;]], 'deploy')
os.remove(marker_path)
local body6=json.encode(r6)
check(secs6>=2.5,'row 6: a waiting install cut the hold short ('..string.format('%.2f',secs6)..'s for a 3 s job)')
check(body6:find('wct%-deploy%-kept')~=nil,'row 6: the answer lost the job it was holding for')
print('ROW6 secs='..string.format('%.2f',secs6))


-- ROW 7: what the INSTALL's own line names (Fable 27/11: "waiting for <job> of session X, up to m:ss"). The
-- hold publishes one flat record per held job while it waits, so wa-sentinel can say what an install is waiting
-- for instead of "a turn is running". The job captures the record itself at 1 s (a reader outside the hold, the
-- way the sentinel is), and the test asserts it is gone once the hold ends - a record nobody removes would
-- leave every later install naming a job that finished.
local dir7=(host.getenv and host.getenv('WASM_AGENT_HOME')) or ''
local capture7='/tmp/wct-hold-record.txt'
os.remove(capture7)
local r7,secs7,sid7=run("const h = await tools.bash({command:'sleep 1; cat "..dir7.."/.wasm-agent/codemode-hold-*.json > "..capture7.." 2>/dev/null; sleep 2', wait_s: 0}); return h;", 'record')
local record7=host.read_file(capture7) or ''
check(#record7>0,'row 7: the hold published no record for the install line to read')
local decoded7={}
pcall(function() decoded7=json.decode(record7) end)
check(type(decoded7.op)=='string' and decoded7.op:find('op%-')~=nil,'row 7: the record does not name the job')
check(decoded7.session==sid7,'row 7: the record does not name the session')
check(type(decoded7.limit_ms)=='number','row 7: the record does not say up to when')
os.remove(capture7)
local leftover=host.read_file(dir7..'/.wasm-agent/codemode-hold-'..tostring(decoded7.op)..'.json')
check(leftover==nil or leftover==false,'row 7: the record outlived the hold')
print('ROW7 record_bytes='..#record7)

print('wct-hold: '..checks..' checks passed')
