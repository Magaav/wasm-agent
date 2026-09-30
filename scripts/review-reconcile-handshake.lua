-- REVIEW FIXTURE (not part of the delivery under review): the reconcile handshake, one node, real
-- runtime. The destination's `resolve` is answered by the real `host.subagent("resolve")` (durable
-- records), while the *start* hop is stubbed to an unobserved failure so the coordinator parks the
-- row. Nothing here touches a live node: disposable home, disposable checkout, no model.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local nodes = dofile("lua/core/nodes.lua")
local subagents = dofile("lua/core/subagents.lua")
local orchestrator = dofile("lua/core/orchestrator.lua")
memory.setup()

local checks = 0
local function ok(value, label) checks = checks + 1; if not value then error(label, 0) end end
local function rows(statement)
  local decoded = json.decode(host.sql_query(statement, json.encode({}))) or {}
  if decoded.error then error("fixture query failed: " .. tostring(decoded.error)) end
  return decoded
end
local function task_row(id)
  return rows("SELECT id,state,destination,detail,receipt FROM orchestration_tasks WHERE id='" .. id .. "'")[1]
end
local NODE = nodes.node_name()

-- The runtime's own ledger, read through the public facade: every task it has admitted for the owner.
local function runtime_count(ctx)
  local listed = subagents.control({ action = "list" }, ctx)
  return tonumber(listed.count) or #(listed.subagents or {})
end
-- `view` deliberately does not expose the idempotency key (rust/wa-host/src/subagents.rs:239), so the
-- runtime's own answer about a key is the only way to ask "how many runs does this key own".
local function owns_run(ctx, key)
  local answer = subagents.control({ action = "resolve", idempotency_key = key }, ctx)
  return answer.found == true, answer
end
local function child_sessions() return #rows("SELECT id FROM sessions WHERE objective='subagent'") end

local parent = memory.start_session("local", "chat", { id = "review-reconcile-coordinator", user_id = "master", node_id = NODE })
local ctx = { user_id = "master", role = "master", node_id = NODE, session_id = parent, run_id = "review-run" }
orchestrator.control({ action = "placement", policy = { enabled = true, nodes = { { node = "local", max_tasks = 4 } } } }, ctx)

-- The destination's own context, exactly as the peer hop builds it for a dispatched request.
local destination_ctx = { user_id = "master", role = "master", node_id = NODE, session_id = parent,
  remote = true, placement = { max_tasks = 4 } }
local function deliver(key, prompt)
  return subagents.control({ action = "start", prompt = prompt, profile = "task-worker",
    idempotency_key = key }, destination_ctx)
end

-- A transport that loses the answer to every `start`, and nothing else: `resolve` is real.
local lost = { control = function(args, caller_ctx)
  if tostring(args.action or "") == "start" then return { error = "remote_unreachable" } end
  return subagents.control(args, caller_ctx)
end }
local real = { control = function(args, caller_ctx) return subagents.control(args, caller_ctx) end }
local function reconcile(id)
  local handled, answer = orchestrator.control({ action = "reconcile", id = id }, ctx, real)
  ok(handled == true, "reconcile is handled: " .. json.encode(answer))
  return answer
end

-- A. The delivery arrived and was admitted; only its answer was lost. `resolve` must find the run, so
-- the row adopts that receipt and the runtime must not gain a second run for the key.
local first = orchestrator.enqueue({ prompt = "delivered but unanswered", profile = "task-worker",
  idempotency_key = "review-adopt" }, ctx)
local first_key = first.subagent_id
local already = deliver(first_key, "the run that was really admitted")
ok(already.subagent_id and not already.error, "the destination really admitted a run: " .. json.encode(already))
ok(owns_run(destination_ctx, first_key), "and the runtime resolves that key to it")
local runs_before, total_before = true, runtime_count(destination_ctx)
orchestrator.tick(lost)
ok(task_row(first_key).state == "unknown", "the unobserved delivery is parked: " .. json.encode(task_row(first_key)))
local adopted = reconcile(first_key)
ok(adopted.dispatch_state == "admitted" and adopted.remote_subagent_id == already.subagent_id,
  "a real resolve adopts the run that exists there: " .. json.encode(adopted))
ok(runs_before and owns_run(destination_ctx, first_key) and runtime_count(destination_ctx) == total_before,
  "and nothing was re-sent, so the runtime gained no second run: " .. tostring(runtime_count(destination_ctx)) ..
  " tasks, was " .. tostring(total_before))

-- B. Nothing was admitted there: `found:false` from the real runtime is what makes a retry safe.
local second = orchestrator.enqueue({ prompt = "never admitted", profile = "task-worker",
  idempotency_key = "review-replace" }, ctx)
local second_key = second.subagent_id
local not_yet, _ = owns_run(destination_ctx, second_key)
ok(not_yet == false, "the destination holds no run for this key yet")
orchestrator.tick(lost)
ok(task_row(second_key).state == "unknown", "the second unobserved delivery is parked too")
local requeued = reconcile(second_key)
ok(requeued.dispatch_state == "queued" and task_row(second_key).destination == "",
  "a proven-unadmitted delivery returns to the queue with the pin dropped: " .. json.encode(requeued))
local total_before_retry = runtime_count(destination_ctx)
orchestrator.tick(real)
ok(owns_run(destination_ctx, second_key) and runtime_count(destination_ctx) == total_before_retry + 1,
  "the retry admits exactly one run: " .. tostring(runtime_count(destination_ctx)) .. " tasks, was " ..
  tostring(total_before_retry))
ok(task_row(second_key).state == "admitted", "and the row is admitted: " .. json.encode(task_row(second_key)))

-- C. The attack: the first request was only *slow*. The coordinator asked, was told "never admitted",
-- re-placed the task, and the original request then arrives at the destination under the same key.
local third = orchestrator.enqueue({ prompt = "slow but real", profile = "task-worker",
  idempotency_key = "review-late" }, ctx)
local third_key = third.subagent_id
orchestrator.tick(lost)
ok(task_row(third_key).state == "unknown", "the third unobserved delivery is parked")
ok(reconcile(third_key).dispatch_state == "queued", "and reconcile is told that key was never started")
local late = deliver(third_key, "the original request, arriving late")
ok(late.subagent_id and not late.error, "the late arrival is admitted by the runtime: " .. json.encode(late))
local sessions_before_tick = child_sessions()
local total_before_replay = runtime_count(destination_ctx)
orchestrator.tick(real)
ok(runtime_count(destination_ctx) == total_before_replay and owns_run(destination_ctx, third_key),
  "the re-placed attempt is deduplicated to the run that already exists: " .. tostring(runtime_count(destination_ctx)) ..
  " tasks, was " .. tostring(total_before_replay))
ok(task_row(third_key).state == "admitted", "the row is admitted: " .. json.encode(task_row(third_key)))
local receipt = json.decode(task_row(third_key).receipt) or {}
ok(tostring(receipt.subagent_id) == tostring(late.subagent_id),
  "and it adopted the late run's id, not a new one: " .. tostring(receipt.subagent_id) .. " vs " .. tostring(late.subagent_id))
ok(child_sessions() == sessions_before_tick,
  "the retry wrote no second child session (" .. child_sessions() .. " vs " .. sessions_before_tick .. ")")

-- D. A destination that answers "found" for something it never started: what the coordinator does
-- with a peer's word. Nothing is re-sent, so a wrong "found" loses the task; it cannot duplicate it.
local fourth = orchestrator.enqueue({ prompt = "lied about", profile = "task-worker",
  idempotency_key = "review-forged" }, ctx)
local fourth_key = fourth.subagent_id
orchestrator.tick(lost)
local forged = { control = function() return { idempotency_key = fourth_key, found = true, unadmitted = false,
  receipt = { subagent_id = "not-a-real-run", state = "running", settled = false } } end }
local handled, answer = orchestrator.control({ action = "reconcile", id = fourth_key }, ctx, forged)
ok(handled and answer.dispatch_state == "admitted" and answer.remote_subagent_id == "not-a-real-run",
  "a forged found is adopted: " .. json.encode(answer))
ok(not owns_run(destination_ctx, fourth_key) and
   #rows("SELECT id FROM orchestration_tasks WHERE id='" .. fourth_key .. "' AND state IN ('queued','placing')") == 0,
  "nothing is re-sent and the row is not in any queue: a wrong 'found' loses the task, never duplicates it")
local status = select(2, orchestrator.control({ action = "status", id = fourth_key }, ctx, real))
ok(status and status.error == "unknown_subagent" and task_row(fourth_key).state == "admitted",
  "and every later read of it is the destination's `unknown_subagent`, with the row still admitted: " ..
  json.encode(status) .. " state=" .. task_row(fourth_key).state)


-- E. A destination that cannot answer `resolve` at all (an older peer: `resolve` is refused by its
-- own capability list). The row stays `unknown`, and no verb in this code can move it again.
local fifth = orchestrator.enqueue({ prompt = "destination cannot answer", profile = "task-worker",
  idempotency_key = "review-stuck" }, ctx)
local fifth_key = fifth.subagent_id
orchestrator.tick(lost)
ok(task_row(fifth_key).state == "unknown", "the fifth delivery is parked too")
local mute = { control = function() return { error = "forbidden_peer_action" } end }
local handled, answer = orchestrator.control({ action = "reconcile", id = fifth_key }, ctx, mute)
ok(handled and answer.error == "reconcile_failed" and task_row(fifth_key).state == "unknown",
  "a destination that cannot answer leaves the row unknown: " .. json.encode(answer))
local refused_cancel = select(2, orchestrator.control({ action = "cancel", id = fifth_key }, ctx, real))
ok(refused_cancel.error == "placement_uncertain_reconcile_before_cancelling",
  "and cancel still refuses it: " .. json.encode(refused_cancel))
orchestrator.tick(real)
ok(task_row(fifth_key).state == "unknown" and not owns_run(destination_ctx, fifth_key),
  "no tick re-places it and the destination still holds no run: the row is stuck until an operator edits it")
print("STUCK ROW: " .. json.encode({ id = fifth_key, state = task_row(fifth_key).state,
  detail = tostring(task_row(fifth_key).detail):sub(1, 80) }))
print("reconcile handshake review ok (" .. checks .. " checks)")
