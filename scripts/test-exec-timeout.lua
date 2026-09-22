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
local before=host.monotonic_ms()
local bg=json.decode(host.exec("sleep 60 & echo started"))
ok(host.monotonic_ms()-before<1800, "shell exit cannot wait for background pipe EOF")
ok(bg.process_exit_code==0 and bg.ok==false, "shell exit zero is not operation success")
ok(tostring(bg.error):find("background_descendants",1,true), "unexpected background descendants are explicit")
ok(tostring(bg.stdout):find("started",1,true), "background case keeps its printed output")
ok(not output.outcome("bash",bg), "Lua does not turn incomplete operation into success")
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
