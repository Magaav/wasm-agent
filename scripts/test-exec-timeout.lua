-- Foreground bash is an operation, not a shell PID plus unbounded reader threads.
-- Run with WASM_AGENT_EXEC_TIMEOUT_SECONDS=2 and an isolated home/database.
local json = dofile("lua/vendor/json.lua")
local output = dofile("lua/core/tool_output.lua")
local checks = 0
local function ok(value, label)
  checks=checks+1
  if not value then error(label) end
end
local started=host.monotonic_ms()
local stuck=json.decode(host.exec("printf before; sleep 30 & wait"))
local took=host.monotonic_ms()-started
ok(took < host.exec_timeout()*1000+1800, "deadline and one explicit cleanup budget bound the whole operation")
ok(stuck.ok==false and stuck.code~=0, "timeout is failure")
ok(stuck.error=="deadline_exceeded", "typed timeout reason")
ok(stuck.stdout=="before", "partial output survives cancellation")
ok(stuck.output_complete==true, "both pipes actually drained after termination")
-- A deadline is not evidence of a cause, and the message used to name one anyway - "a call to
-- this node's own busy session cannot serve itself" - for every timeout, including a local
-- command that never addressed this node. It reads as a diagnosis, so it was carried onward as
-- one. The message carries what was measured; the result keeps the breakdown, because a killed
-- operation is the case where the phases are the explanation rather than decoration.
ok(type(stuck.timing)=="table" and tonumber(stuck.timing.execution_ms)~=nil,
  "a terminated operation reports its phases")
ok(tostring(stuck.stderr):find("did not finish within ",1,true)~=nil, "the note says what happened")
ok(tostring(stuck.stderr):find("executing ",1,true)~=nil
   and tostring(stuck.stderr):find("setup ",1,true)~=nil, "and names the measured phases")
ok(tostring(stuck.stderr):find("busy session",1,true)==nil
   and tostring(stuck.stderr):find("independent route",1,true)==nil,
  "and never invents a cause it cannot know")
-- The model-facing half of the same rule: phases on a killed call, not on one that settled.
local killed=output.execution_timing("bash",{ok=false,error="deadline_exceeded",timing={execution_ms=5}})
ok(type(killed)=="table" and killed.execution_ms==5, "a killed call keeps its phases in the result")
local settled={ok=true,timing={execution_ms=5}}
local reported=output.execution_timing("bash",settled)
ok(settled.timing==nil and type(reported)=="table", "a settled shell call keeps them out of the model view")
local failed={ok=false,code=1,timing={execution_ms=5}}
output.execution_timing("bash",failed)
ok(failed.timing==nil, "a command that exited non-zero needs no phase breakdown")
local other={timing={execution_ms=5}}
output.execution_timing("operation",other)
ok(type(other.timing)=="table", "a tool that reports phases itself is left alone")
local before=host.monotonic_ms()
local bg=json.decode(host.exec("sleep 60 & echo started"))
ok(host.monotonic_ms()-before<1800, "shell exit cannot wait for background pipe EOF")
-- A shell that exits leaving a live descendant is no longer a failure: the descendant is
-- adopted as a running operation, and the receipt names it. The shell's own exit code is
-- still the truth about the shell; `output_complete` is false because the process runs on.
ok(bg.promoted==true and bg.ok==true, "a backgrounded descendant is adopted, not failed")
ok(bg.settled==false and bg.output_complete==false, "an adopted tree is running, not finished")
ok(tostring(bg.operation_id):find("^op%-")~=nil, "the receipt names the adopted operation")
ok(tostring(bg.stdout):find("started",1,true), "background case keeps its printed output")
-- Adoption is not abandonment: it is a real operation, readable and cancellable.
local adopted_read=json.decode(host.operation("read",json.encode({id=bg.operation_id,stream="stdout",offset=0,limit=4096})))
ok(tostring(adopted_read.content):find("started",1,true), "the adopted operation's output is readable")
local adopted_status=json.decode(host.operation("status",json.encode({id=bg.operation_id})))
ok(adopted_status.promoted==true and adopted_status.settled==false, "the adopted operation is still running")
ok(adopted_status.shell_exited==true and adopted_status.process_exit_code==0,
  "shell success is visible independently of operation completion")
ok(adopted_status.waiting_for=="descendants" and type(adopted_status.remaining_ms)=="number",
  "the live operation reports its wait reason and remaining budget")
json.decode(host.operation("cancel",json.encode({id=bg.operation_id})))
local adopted_done=json.decode(host.operation("wait",json.encode({id=bg.operation_id,wait_ms=3000})))
ok(adopted_done.settled==true, "cancelling the adopted operation settles it")

-- The guidance that comes back with an adopted tree is policy, and it has to match what the
-- caller can actually use. A profile with `bash` but not `operation` was being told to read and
-- cancel an operation it cannot reach - the same dead end the old refusal was, reintroduced by
-- the adoption. Drive the real dispatch with a restricted caller context.
local tools=dofile("lua/core/tools.lua")
local memory=dofile("lua/core/memory.lua");memory.setup()
local restricted=tools.dispatch(memory,"bash",{command="sleep 60 & echo started"},"master",
  {subagent={allowed={read=true,bash=true}}})
ok(restricted.promoted==true, "a caller without `operation` still gets the adoption")
ok(not tostring(restricted.note):find("operation read",1,true),
  "but is not told to use a tool its profile does not allow")
ok(tostring(restricted.note):find(tostring(restricted.operation_id),1,true)~=nil,
  "and the note still names the operation it was handed")
local allowed=tools.dispatch(memory,"bash",{command="sleep 60 & echo started"},"master",
  {subagent={allowed={read=true,bash=true,operation=true}}})
ok(allowed.promoted==true and tostring(allowed.note):find("operation read",1,true)~=nil,
  "a caller that does allow `operation` is told to use it")
json.decode(host.operation("cancel",json.encode({id=allowed.operation_id})))
ok(tostring(allowed.note):find("Do not rerun",1,true)~=nil and
  tostring(allowed.note):find("before choosing await",1,true)~=nil,
  "adoption guidance prevents blind replay and premature long waits")
local hello=json.decode(host.exec("echo hello"))
ok(hello.ok and hello.code==0 and hello.stdout:find("hello",1,true), "normal command succeeds")
local slow=json.decode(host.exec("sleep 1; echo done"))
ok(slow.ok and slow.stdout:find("done",1,true), "quiet legitimate work succeeds")
-- A caller may name its own bound: `bash`'s `timeout_seconds`. Below the default it
-- kills sooner; above it, a command the default (2s here) would have killed is allowed
-- to finish. The audit's tail runs into the wall - p99 was 250s against a 300s deadline
-- - and this is what keeps a build or a full gate from being lost to it.
local quick_started=host.monotonic_ms()
local quick=json.decode(host.exec("sleep 30", "", 1))
ok(quick.error=="deadline_exceeded", "a per-call timeout below the default is enforced")
ok(host.monotonic_ms()-quick_started<2500, "the caller's bound, not the default, is what kills it")
local raised_started=host.monotonic_ms()
local raised=json.decode(host.exec("sleep 3; echo raised", "", 20))
ok(raised.ok and raised.stdout:find("raised",1,true), "a per-call timeout above the default lets a longer command finish")
ok(host.monotonic_ms()-raised_started>=2500, "the command really did outlive the default deadline")
local refused=json.decode(host.exec("echo x", "", 0))
ok(refused.error=="invalid_timeout_seconds", "a bound outside 1-86400 is refused, not clamped")
local big=json.decode(host.exec("seq 1 20000 | wc -l"))
ok(big.ok and big.stdout:find("20000",1,true), "output drains concurrently with execution")
local launch=json.decode(host.operation("start",json.encode({command="echo ready; sleep 30",timeout_seconds=20})))
ok(launch.operation_id and not launch.settled, "explicit operation gives a receipt, not a fake result")
local cancel=json.decode(host.operation("cancel",json.encode({id=launch.operation_id})))
local finished=json.decode(host.operation("wait",json.encode({id=launch.operation_id,wait_ms=2000})))
ok(finished.settled and finished.state=="cancelled", "cancellation settles the owned operation")
print("exec timeout ok ("..checks.." checks)")
