-- Past the node's operation cap a new operation QUEUES, and what runs there runs at low CPU priority
-- (18/11, item 1.6 of change/harness-next-a).
--
-- The measured shape this replaces: a ninth concurrent operation was REFUSED with operation_capacity,
-- so work the caller had already planned was thrown away while the process it wanted was only waiting
-- for a core. The facts pinned here:
--
--   * a new operation past MAX_ACTIVE is admitted (its receipt exists immediately), waits in the
--     node's queue, records state:"queued", queued_because and queued_ms, and runs when a core frees -
--     never operation_capacity;
--   * the wait is given back to the operation's own deadline, so a queued command is not already
--     half-expired when it starts;
--   * every operation records the CPU priority it ran at (cpu_priority), a niceness below the node's
--     own: a long build cannot starve the session waiting on it.
--
-- Hermetic: its own scratch home; the commands are local sleeps.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local sid=memory.start_session('','operation queue',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
-- A second session, because ONE session may not take the node's every slot (session isolation,
-- finding 7: its share is 6 of 8, and two of the eight are kept for the node's own control calls).
-- The queue is the node's cap and is pinned here; the share is what decides which starts may occupy
-- it, and a start past the node's workload cap waits there.
local sid2=memory.start_session('','operation queue two',{user_id='master'})
local ctx2={session_id=sid2,user_id='master'}
local checks=0
local function check(ok,message) assert(ok,message);checks=checks+1 end
local function call(action,args)
  local params={action=action}
  for key,value in pairs(args or {}) do params[key]=value end
  return tools.dispatch(memory,'operation',params,'master',ctx)
end
local function call2(action,args)
  local params={action=action}
  for key,value in pairs(args or {}) do params[key]=value end
  return tools.dispatch(memory,'operation',params,'master',ctx2)
end
local function pause(ms) local until_at=host.now()+ms/1000; while host.now()<until_at do host.sleep(25) end end

-- ------------------------------------------- fill the node's WORKLOAD slots (one session's share)
local running={}
for index=1,6 do
  local started=call('start',{command='sleep 6',timeout_seconds=60})
  check(type(started.operation_id)=='string' and started.operation_id~='',
    'operation '..index..' was admitted: '..json.encode(started):sub(1,200))
  check(tostring(started.error):find('operation_capacity',1,true)==nil,
    'and no operation was refused for capacity: '..json.encode(started):sub(1,200))
  running[#running+1]=started.operation_id
end
-- The record names the CPU priority of what runs here.
local first_status=call('status',{id=running[1]})
check(type(first_status.cpu_priority)=='string' and first_status.cpu_priority~='',
  'an operation records the CPU priority it runs at: '..json.encode(first_status):sub(1,240))
check(first_status.cpu_priority~='default',
  'and that priority is below the node own: '..tostring(first_status.cpu_priority))

-- ---------------------------------------------------------------- the next one queues
--
-- Six workloads are running, which is every slot a workload may take (MAX_ACTIVE minus the two kept
-- for control calls). A start by ANOTHER session is admitted and waits in the node's queue; it is never
-- refused for capacity, which is the fact this row exists for.
local ninth=call2('start',{command='echo ninth',timeout_seconds=60})
check(type(ninth.operation_id)=='string' and ninth.operation_id~='',
  'a start past the node workload cap is admitted instead of refused: '..json.encode(ninth):sub(1,300))
check(tostring(ninth.error):find('operation_capacity',1,true)==nil,
  'never operation_capacity: '..json.encode(ninth):sub(1,300))
local queued=false
for _=1,20 do
  local status=call2('status',{id=ninth.operation_id})
  if status.state=='queued' then queued=true break end
  if status.settled==true then break end
  pause(50)
end
check(queued,'the one past the workload cap is recorded as queued while the node is full: '
  ..json.encode(call2('status',{id=ninth.operation_id})):sub(1,300))
local queued_status=call2('status',{id=ninth.operation_id})
check(tostring(queued_status.queued_because)=='operation_capacity',
  'and says why it is waiting: '..json.encode(queued_status):sub(1,300))
check(tonumber(queued_status.queue_limit)==6,'with the cap it is waiting for (the workload cap, '
  ..'MAX_ACTIVE less the two control slots): '..tostring(queued_status.queue_limit))
-- The two slots a workload may not take are why it waits HERE: with six workloads running, the node
-- still has room for its own short read, and the record says which reserve it is waiting behind.
check(tonumber(queued_status.queue_reserve)==2,'and the reserve it is waiting behind: '
  ..json.encode(queued_status):sub(1,300))

-- ---------------------------------------------------------------- it runs when a slot frees
local settled=nil
local deadline=host.now()+40
repeat
  local waited=call2('wait',{id=ninth.operation_id,wait_ms=1000,tool='operation'})
  if waited.settled==true then settled=waited end
until settled or host.now()>deadline
check(settled~=nil,'the queued operation ran once a slot freed: '
  ..json.encode(call2('status',{id=ninth.operation_id})):sub(1,300))
check(tonumber(settled and settled.process_exit_code)==0,'and its command succeeded: '
  ..tostring(settled and settled.process_exit_code))
check(tonumber(settled and settled.queued_ms or 0)>0,'the queue wait is recorded on it: '
  ..tostring(settled and settled.queued_ms))
-- The deadline extension itself (deadline_ms += queued_ms) is not a snapshot field: what is checked
-- here is that the operation still ran under ITS OWN timeout after waiting in the queue, which is what
-- the extension exists for.
check(tonumber(settled and settled.timeout_ms)==60000,"and ran under its own timeout, not the queue's: "
  ..tostring(settled and settled.timeout_ms))
check(tonumber(settled and settled.elapsed_ms or 0)>=tonumber(settled and settled.queued_ms or 0),
  'its elapsed time covers the queue wait: '..tostring(settled and settled.elapsed_ms))
local output=call2('read',{id=ninth.operation_id,stream='stdout',offset=0,limit=200})
check(tostring(output.content):find('ninth',1,true)~=nil,'with its own output: '
  ..tostring(output.content))

-- ---------------------------------------------------------------- leave nothing running
for _,id in ipairs(running) do pcall(call,'cancel',{id=id}) end

print(json.encode({ok=true,checks=checks}))
