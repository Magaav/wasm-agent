-- Integration checks for local subagents against a local mock model.
--
-- The CJS runner starts a mock OpenAI-compatible server and then runs this file
-- through the real host, so a child really is a fresh interpreter on the runtime's
-- own thread, really calls the (mock) provider, and really settles durably. No
-- paid inference.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local subagents = dofile("lua/core/subagents.lua")

local parent_id = memory.start_session("", "chat", { user_id = "alice", node_id = "", title = "parent" })
local function ctx(user, role)
  return { user_id = user or "alice", role = role or "master", session_id = parent_id, run_id = "parent-run", node_id = "" }
end
local function control(args, c) return subagents.control(args, c) end

-- 1. Start, await, and prove the child's transcript is independent of the parent.
local started = control({ action = "start", profile = "explore", prompt = "basic task", idempotency_key = "basic" }, ctx("alice"))
assert(not started.error, "start failed: " .. json.encode(started))
assert(started.state == "accepted" and started.settled == false, "a receipt is not completion: " .. json.encode(started))
-- A caller-supplied id is ignored: the runtime generates a safe path component.
assert(not tostring(started.subagent_id):find("/", 1, true) and not tostring(started.subagent_id):find("%.%."),
  "the runtime must generate the child id: " .. tostring(started.subagent_id))
-- The agreed acceptance aliases (`subagent_id`, `timeout_ms`) are accepted.
local settled = control({ action = "await", subagent_id = started.subagent_id, timeout_ms = 60000 }, ctx("alice"))
assert(settled.state == "completed", "await state=" .. tostring(settled.state) .. " " .. json.encode(settled))
assert(tostring(settled.result.reply):find("child-answer", 1, true), "child reply: " .. tostring(settled.result.reply))
assert(memory.message_count(parent_id) == 0, "the parent transcript must not be written by a child")
local child = memory.session(started.session_id)
assert(child and child.parent_session_id == parent_id, "the child session must link to the parent")
assert(memory.message_count(started.session_id) > 0, "the child must keep its own transcript")
print("MARK ok-success " .. started.subagent_id)

-- 2. Idempotency: a repeat start collects the same child, with no second run.
local first = control({ action = "start", profile = "explore", prompt = "x", idempotency_key = "same" }, ctx("alice"))
local second = control({ action = "start", profile = "explore", prompt = "x", idempotency_key = "same" }, ctx("alice"))
assert(second.deduplicated == true and second.subagent_id == first.subagent_id,
  "idempotency: " .. json.encode(second))
control({ action = "await", id = first.subagent_id, wait_ms = 60000 }, ctx("alice"))
print("MARK ok-idempotency")

-- 3. Per-user isolation: another user cannot inspect or cancel this task.
local blocked = control({ action = "status", subagent_id = started.subagent_id }, ctx("bob"))
assert(blocked.error == "forbidden_subagent", "status isolation: " .. json.encode(blocked))
local cancel_blocked = control({ action = "cancel", subagent_id = started.subagent_id }, ctx("bob"))
assert(cancel_blocked.error == "forbidden_subagent", "cancel isolation: " .. json.encode(cancel_blocked))
print("MARK ok-isolation")

-- 4. Cancellation: the mock streams slowly, so the cancel lands on provider I/O.
local slow = control({ action = "start", profile = "explore", prompt = "SLOW stop now", idempotency_key = "slow" }, ctx("alice"))
assert(not slow.error, "slow start: " .. json.encode(slow))
local cancel_view = control({ action = "cancel", id = slow.subagent_id }, ctx("alice"))
assert(cancel_view.error == nil, "cancel: " .. json.encode(cancel_view))
local final = control({ action = "await", id = slow.subagent_id, wait_ms = 60000 }, ctx("alice"))
assert(final.state == "cancelled", "cancel state=" .. tostring(final.state) .. " " .. json.encode(final))
print("MARK ok-cancel")

-- 5. Queue overflow is an explicit refusal, never invisible loss.
local ids, overflow = {}, nil
for index = 1, 12 do
  local receipt = control({ action = "start", profile = "explore", prompt = "SLOW hold " .. index }, ctx("alice"))
  if receipt.error then overflow = receipt.error break end
  ids[#ids + 1] = receipt.subagent_id
end
assert(overflow == "queue_full", "expected queue_full, got " .. tostring(overflow))
for _, id in ipairs(ids) do control({ action = "cancel", id = id }, ctx("alice")) end
print("MARK ok-overflow")

-- 6. A settled result is retrievable without another model call.
local result = control({ action = "result", id = started.subagent_id }, ctx("alice"))
assert(result.state == "completed", "result: " .. json.encode(result))
print("MARK ok-result")

-- 7. Tool denial under a real (mock) inference turn: the child asks for `bash`,
--    which its profile does not allow, and the dispatch refuses it even though the
--    model produced the call. The refusal is visible in the child's transcript.
local denied = control({ action = "start", profile = "explore", prompt = "DENY tool attempt", idempotency_key = "deny" }, ctx("alice"))
assert(not denied.error, "deny start: " .. json.encode(denied))
local denied_final = control({ action = "await", id = denied.subagent_id, wait_ms = 60000 }, ctx("alice"))
assert(denied_final.state == "completed", "deny state=" .. tostring(denied_final.state) .. " " .. json.encode(denied_final))
local found_denial = false
for _, message in ipairs(memory.session_messages(denied.session_id, { all = true, exclude_summaries = true })) do
  if tostring(message.content):find("capability_not_in_profile:bash", 1, true) then found_denial = true end
end
assert(found_denial, "the child transcript must record the refused capability")
print("MARK ok-tool-denial")

-- 8. A record left running by another boot is unknown, never replayed.
local stale = json.decode(host.subagent("status", json.encode({ id = "stale-child", owner_user = "alice" })))
assert(stale.state == "unknown" and stale.settled == true, "restart unknown: " .. json.encode(stale))
print("MARK ok-restart-unknown")

-- 9. The ordinary-run path: a parent agent calls the `subagent` tool, awaits the
--    child in one bounded wait, and answers from its result. This is the path a
--    real run and a job use; the mock distinguishes parent from child by the
--    system prompt, so both loops really ran.
local agentlib = dofile("lua/core/agent.lua")
local run_session = memory.start_session("", "chat", { user_id = "alice", node_id = "", title = "parent-run" })
local parent = agentlib.new(run_session, function() end, "master", "alice", "")
local parent_reply = parent:run("spawn a child and report its answer")
assert(tostring(parent_reply):find("parent-done", 1, true), "parent reply: " .. tostring(parent_reply))
local saw_start, saw_await = false, false
for _, message in ipairs(memory.session_messages(run_session, { all = true, exclude_summaries = true })) do
  if message.role == "tool" and tostring(message.content):find('"subagent_id"', 1, true) then saw_start = true end
  if message.role == "tool" and tostring(message.content):find('"reply"', 1, true) then saw_await = true end
end
assert(saw_start, "the parent transcript must record the start receipt")
assert(saw_await, "the parent transcript must record the awaited child result")
print("MARK ok-parent-run")

print("SUBAGENTS_INTEGRATION_OK")
