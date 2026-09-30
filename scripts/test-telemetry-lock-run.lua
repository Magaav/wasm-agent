-- The thing that died: one run's telemetry, in a fresh process, against the node's real database,
-- while another connection holds the write lock. This is the sequence tonight's kill came from -
-- `lua/core/telemetry.lua:12: database is locked` - and here it must always end in a completed run,
-- with the loss of any record visible on stderr instead of raised into the caller.
--
--   WA_SCRIPT=scripts/test-telemetry-lock-run.lua wa --db <db>
--
-- Prints one machine-readable line the driver asserts on:
--   subject: completed events=<n> drops=<n> ...
local json = dofile("lua/vendor/json.lua")
local telemetry = dofile("lua/core/telemetry.lua")

local session, run = "telemetry-lock-session", "telemetry-lock-run"
local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label)
  else print("FAIL " .. label); failures = failures + 1 end
end

-- 1. A fresh interpreter's first telemetry write also applies this module's schema: the DDL is a write,
--    so it is on the same contended path as the record itself.
telemetry.setup()

-- 2. One run, in the order `lua/core/agent.lua` drives it: a run span, a decision step, a model call, a
--    tool call, then the run's own end event. Seven records when nothing is lost.
local run_span = telemetry.start({session_id=session, run_id=run}, "run", {})
telemetry.event(session, run, "", "step", "end", {outcome="answered"})
local call = telemetry.start({session_id=session, run_id=run}, "model_call", {provider="mock", model="mock-1"})
telemetry.finish(call, {ok=true, usage={prompt_tokens=10, completion_tokens=1, total_tokens=11}})
local tool = telemetry.start({session_id=session, run_id=run}, "tool", {name="ls"})
telemetry.finish(tool, {name="ls", ok=true})
telemetry.finish(run_span, {ok=true})

-- 3. The read a control call makes while a run settles (`wa_model`, a child's receipt): a read must
--    answer - even if the answer is "unreadable" - rather than raise into the caller.
local report = telemetry.snapshot(session)
check(type(report) == "table", "the run's own snapshot returned a report")
check(type(report.events) == "number" or report.reason ~= nil, "the report says what it could read")

local drops = telemetry.drops()
print(string.format("subject: completed events=%s drops=%d last=%s",
  tostring(report.events), drops.count, tostring(drops.label)))
if report.reason then print("subject: snapshot unreadable: " .. tostring(report.reason)) end
print("subject: run survived")
os.exit(failures == 0 and 0 or 1)
