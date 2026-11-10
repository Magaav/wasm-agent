-- Polling never waits for a relayed call, and the bound is named.
--
-- The defect this measures (2026-11-10): `M.tick` used to poll once and then run the request inline,
-- so a call longer than the relay's 40 s attach window left the whole node `node_not_attached`, with
-- nothing written on either side. Here a fake relay, a virtual clock and a coroutine stand in for the
-- transport's two lanes (`rust/wa-rendezvous/src/binding_runtime.rs` runs the real threads): the poll
-- lane keeps polling while a 120 s call is in flight, a second caller is answered throughout, and a
-- call that passes its bound is named as a timeout rather than returning late as if it were fresh.
local json=dofile('lua/vendor/json.lua')
local binding=dofile('lua/core/binding.lua')
local checks=0
local function ok(value,label) checks=checks+1;if not value then error('FAILED: '..tostring(label),2) end end
local function eq(got,want,label) checks=checks+1;if got~=want then error('FAILED: '..tostring(label)..' (got '..tostring(got)..', want '..tostring(want)..')',2) end end

-- A clock the test moves, so 120 s of a slow call costs no real time. It starts at a realistic
-- instant, so a printed log line reads as the node's own would.
local clock=1792000000
host.now=function() return clock end
local function advance(seconds) clock=clock+seconds end

local logs={}
host.log=function(text) logs[#logs+1]=tostring(text) end

local id=json.decode(host.node_identity())
local pin={node_id=id.node_id,public_key=id.public_key}
local service='http://127.0.0.1:12345'
local request={schema=1,id=host.uuid():gsub('-',''),code='0123456789ab',node_id=id.node_id,public_key=id.public_key,
  name='relay-test',service=service,operators={pin},scope='user-account-tools',
  expires_at=clock+86400,pairing_expires_at=clock+600}
local raw=json.encode(request)
local saved={schema=1,request=request,raw_request=raw,digest=host.sha256(raw),service=service,operators={pin},
  expires_at=request.expires_at,active=true,consent=true,phase='accepted',network_role='guest'}
ok(json.decode(host.binding_state('cas',json.encode({state=saved}))).ok,'a bound and accepted node')

-- ---- the fake relay ------------------------------------------------------------------------------
local relay={queue={},answers={},polls=0,last_poll=nil,worst_gap=0,failing=nil}
local function queued(entry) relay.queue[#relay.queue+1]=entry end
local function envelope(body,budget_ms)
  return {id=body.id,method='POST',path='/node/call',
    headers={['content-type']='application/json'},
    body=json.encode({capability='bash',args={sleep=body.sleep or 0},to_node_id=id.node_id}),
    budget_ms=budget_ms,deadline_ms=(clock*1000)+budget_ms,timeout_source='relay'}
end
host.http=function(method,url,headers,body)
  local value
  if url:match('/service$') then
    value={protocol=1,binding_protocol=1,enrollment_ready=true,operators={pin}}
  elseif url:find('/bindings/request?',1,true) then
    value={ok=true,binding={digest=saved.digest,request=request,state='accepted',revision=2}}
  elseif url:find('/register',1,true) then
    value={ok=true}
  elseif url:find('/lookup?',1,true) then
    value={public_key=id.public_key,role='guest',online=true,relay_attached=false}
  elseif url:find('/relay/poll',1,true) then
    if relay.failing then return json.encode({status=503,body=json.encode({error=relay.failing})}) end
    local gap=relay.last_poll and (clock-relay.last_poll) or 0
    if gap>relay.worst_gap then relay.worst_gap=gap end
    relay.last_poll=clock;relay.polls=relay.polls+1
    local next=table.remove(relay.queue,1)
    value=next and {request=next} or {}
  elseif url:find('/relay/respond',1,true) then
    local sent=json.decode(body or '') or {}
    relay.answers[#relay.answers+1]=sent
    value={ok=true}
  else error('unexpected request '..tostring(url)) end
  return json.encode({status=200,body=json.encode(value)})
end

-- ---- the node's execution lane, in miniature ------------------------------------------------------
-- `wa_node_call` is the capability dispatch the real worker runs. A slow call advances the clock and
-- yields, which is exactly what a worker thread is: work that does not hold the poll lane.
local calls=0
local stopped=false
function wa_node_call(payload)
  calls=calls+1
  local asked=json.decode(payload) or {}
  if asked.capability=='status' then
    return json.encode({reply=json.encode({ok=true,capability='status',at=clock})})
  end
  local seconds=tonumber(asked.args and asked.args.sleep or 0)
  local slept=0
  while slept<seconds do
    if stopped then cancelled_after=slept;return json.encode({reply=json.encode({error='run_cancelled',after=slept})}) end
    slept=slept+1;advance(1);coroutine.yield()
  end
  return json.encode({reply=json.encode({ok=true,slept=slept})})
end

-- ---- A: a 120 s call does not stop the poll lane -------------------------------------------------
queued(envelope({id='rid-slow',sleep=120},180000))
local view=binding.tick()
ok(view.attached==true,'the node attached on its first poll')
ok(view.dispatch and view.dispatch.request.id=='rid-slow','the poll lane hands the call over')
eq(calls,0,'the poll lane ran nothing')
eq(#logs,1,'one line on the first attach')
ok(logs[1]:find('attach node='..id.node_id,1,true) and logs[1]:find('reason=first poll',1,true),logs[1])

local slow_answer
local polls_before=relay.polls
local worker=coroutine.create(function() slow_answer=binding.serve(json.encode(view.dispatch.request)) end)
for step=1,60 do
  -- Two seconds of the running call, then a poll: the shape the transport runs on (2 s cadence).
  local resumed,problem=coroutine.resume(worker);assert(resumed,problem)
  resumed,problem=coroutine.resume(worker);assert(resumed,problem)
  local tick=binding.tick()
  ok(tick.attached==true,'still attached while the call runs (step '..step..')')
  if step%10==0 then
    -- A second caller asks for status while the 120 s call is in flight, and is answered at once.
    local before=clock
    local answered=binding.serve(json.encode({id='rid-status-'..step,method='POST',path='/node/call',
      headers={},body=json.encode({capability='status',to_node_id=id.node_id}),
      budget_ms=17000,deadline_ms=(clock*1000)+17000}))
    eq(answered.status,200,'a status call is answered during the slow call')
    eq(clock-before,0,'within the second it arrived in, not after the slow call')
  end
end
-- Let the call leave its last yield: it has run its 120 s.
while coroutine.status(worker)~='dead' do local resumed,problem=coroutine.resume(worker);assert(resumed,problem) end
ok(relay.worst_gap<=2,'a poll at least every 2 s for the whole call (worst '..relay.worst_gap..'s)')
local call_gap=relay.worst_gap
eq(relay.polls-polls_before,60,'one poll per 2 s step while the call ran')
eq(#relay.answers,0,'nothing was answered by the poll lane')
ok(slow_answer and slow_answer.status==200,'the 120 s call answered 200 when it finished')
eq(json.decode(json.decode(slow_answer.body).reply).slept,120,'the slow call really ran 120 s')

-- ---- B: a call that passes its bound is stopped and named ---------------------------------------
stopped=false
queued(envelope({id='rid-bound',sleep=30},5000))
local bounded=binding.tick()
ok(bounded.dispatch and bounded.dispatch.request.id=='rid-bound','the bounded call is dispatched')
local bound_answer
local runner=coroutine.create(function() bound_answer=binding.serve(json.encode(bounded.dispatch.request)) end)
while coroutine.status(runner)~='dead' do
  advance(1)
  -- This is the one thing the runtime's bound thread does at the deadline: stop the work.
  if clock*1000>=bounded.dispatch.request.deadline_ms then stopped=true end
  local resumed,problem=coroutine.resume(runner);assert(resumed,problem)
end
eq(bound_answer.status,504,'a call over its bound answers 504')
local named=json.decode(bound_answer.body)
eq(named.error,'relay_request_timeout','and names the timeout')
eq(named.id,'rid-bound','with the rid its caller holds')
ok(bound_answer.late==true,'and says the answer is not fresh')
ok(clock*1000>=bounded.dispatch.request.deadline_ms,'answered at or after the bound the caller was given')
eq(named.budget_ms,5000,'the bound it was told is named in the answer')
ok(cancelled_after and cancelled_after<30,'the work was stopped, not run to its 30 s ('..tostring(cancelled_after)..' s)')

-- ---- C: attach and detach are written once, with node id, time and reason --------------------------
logs={}
relay.failing='relay_down'
ok(binding.tick().ok==false,'a failed poll is reported')
eq(#logs,1,'one detach line for the drop')
local stamp='^%[relay%] detach node='..id.node_id..' at=%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ reason=relay_poll_failed:'
ok(logs[1]:match(stamp)~=nil,logs[1])
relay.failing=nil
ok(binding.tick().attached==true,'the next poll attaches again')
eq(#logs,2,'one attach line on recovery')
ok(logs[2]:match('^%[relay%] attach node='..id.node_id..' at=%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ reason=poll after ')~=nil,logs[2])
ok(binding.tick().attached==true and #logs==2,'a healthy poll writes nothing new')
for _,line in ipairs(logs) do print(line) end

-- ---- D: a request that cannot be read is refused, and marked not started --------------------------
local refused=binding.serve('not json')
eq(refused.status,400,'an unreadable request is refused')
ok(json.decode(refused.body).not_started==true,'and says nothing ran')

print(string.format('relay attach ok (%d checks, 0 skipped): %d polls during a 120 s call, worst gap %ss, %d log lines',
  checks,relay.polls-polls_before,call_gap,#logs))
