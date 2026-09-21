-- Foreground bash is an operation, not a shell PID plus unbounded reader threads.
-- Run with WASM_AGENT_EXEC_TIMEOUT_SECONDS=2 and an isolated home/database.
local json = dofile("lua/vendor/json.lua")
local output = dofile("lua/core/tool_output.lua")
local tools = dofile("lua/core/tools.lua")
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
local short_started=host.monotonic_ms()
local short=json.decode(host.exec("sleep 30", "", "1"))
ok(short.error=="deadline_exceeded" and short.timeout_ms==1000, "a call may shorten the configured deadline")
ok(host.monotonic_ms()-short_started<1800, "the shorter per-call deadline is enforced")
local invalid=json.decode(host.exec("echo never", "", "0"))
ok(invalid.error=="invalid_exec_timeout", "an invalid per-call deadline is refused before execution")
local bash_schema
for _,tool in ipairs(tools.all("master")) do if tool["function"].name=="bash" then bash_schema=tool["function"] end end
ok(bash_schema.parameters.properties.timeout_seconds.maximum==86400
  and bash_schema.description:find("shorten",1,true), "the model is told the deadline can only be shortened")
ok(tools.dispatch(nil,"bash",{command="echo never",timeout_seconds=0},"master").error=="invalid_timeout_seconds",
  "direct dispatch refuses an invalid deadline before execution")
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
local big=json.decode(host.exec("seq 1 20000 | wc -l"))
ok(big.ok and big.stdout:find("20000",1,true), "output drains concurrently with execution")
local launch=json.decode(host.operation("start",json.encode({command="echo ready; sleep 30",timeout_seconds=20})))
ok(launch.operation_id and not launch.settled, "explicit operation gives a receipt, not a fake result")
local cancel=json.decode(host.operation("cancel",json.encode({id=launch.operation_id})))
local finished=json.decode(host.operation("wait",json.encode({id=launch.operation_id,wait_ms=2000})))
ok(finished.settled and finished.state=="cancelled", "cancellation settles the owned operation")
print("exec timeout ok ("..checks.." checks)")
