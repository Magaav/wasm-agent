-- A placed child's workspace: which checkout it forks from, and what a destination that cannot fork
-- one says instead.
--
-- Measured, before this fixture existed: with placement enabled and the cloud node ranked first, a
-- `task-worker` child dispatched to a second node answered
--   {"error":"workspace_allocation_failed","detail":"workspace_session_not_found","node":"openclaw",
--    "session_id":"e42bb0ca-...","workspace":{"state":"pending","workspace_required":1,
--    "workspace_source_path":"","worktree":"","base_commit":"","branch":""}}
-- The destination was healthy and prepared; what it did not have was a source path for the incoming
-- session - the coordinator's `C:/Users/.../wasm_the_first` means nothing on that machine. So the
-- checks below pin the rule that replaced it:
--
--   * a placed child forks from the tree *this* node runs from (`runtime-worktree.txt`), which is
--     what a local child gets,
--   * a path recorded by a session of another node is never the source, even when that same path
--     exists here (one path on two machines is two different repositories),
--   * a path that is gone on this machine falls back to this node's checkout rather than refusing,
--   * a destination with no usable checkout at all refuses by name, records it on the child's own
--     workspace (never `pending`), and does so *before* it creates a session shell,
--   * and the coordinator's rule for a destination's answer: spill on what another candidate can
--     take, end the attempt on what none can, and stay pinned when nothing is proven.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local workspaces = dofile("lua/core/workspaces.lua")
local orchestrator = dofile("lua/core/orchestrator.lua")
local nodes = dofile("lua/core/nodes.lua")
memory.setup()

local checks = 0
local function ok(value, label) checks = checks + 1; if not value then error(label, 0) end end
local function normalized(path)
  return (tostring(path or ""):gsub("\\", "/"):gsub("/$", "")):lower()
end
local function trimmed(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function git(path, ...)
  local command = "git -C '" .. tostring(path):gsub("'", "'\\''") .. "'"
  for _, argument in ipairs({ ... }) do command = command .. " " .. tostring(argument) end
  local raw = host.exec(command, "")
  local decoded
  local read = pcall(function() decoded = json.decode(raw) end)
  if not read or type(decoded) ~= "table" or tonumber(decoded.code) ~= 0 then
    return nil, tostring((type(decoded) == "table" and (decoded.stderr or decoded.error)) or "git failed")
  end
  return trimmed(decoded.stdout)
end

local NODE = nodes.node_name()
local scenario = tostring(host.getenv("WASM_AGENT_TEST_PLACED_SCENARIO") or "")
local destination = tostring(host.getenv("WASM_AGENT_TEST_DESTINATION_TREE") or "")
local foreign = tostring(host.getenv("WASM_AGENT_TEST_FOREIGN_TREE") or "")
ok(scenario == "prepared" or scenario == "unprepared", "fixture scenario required")
ok(destination ~= "" and foreign ~= "", "fixture trees required")
local destination_head, destination_error = git(destination, "rev-parse", "HEAD")
local foreign_head, foreign_error = git(foreign, "rev-parse", "HEAD")
ok(destination_head and foreign_head, "both fixture trees are checkouts: " ..
  tostring(destination_error or foreign_error))
ok(destination_head ~= foreign_head, "the two trees are different commits, so the fork base proves which one was read")

local function child_session(id, source_session)
  return memory.start_session("local", "subagent", {
    id = id, user_id = "master", node_id = NODE,
    parent_session_id = source_session, workspace_required = true,
  })
end
local function session_ids()
  local seen = {}
  local rows = json.decode(host.sql_query("SELECT id FROM sessions", json.encode({}))) or {}
  for _, row in ipairs(rows) do seen[row.id] = true end
  return seen
end
local function selected_sql(statement)
  return json.decode(host.sql_query(statement, json.encode({}))) or {}
end

if scenario == "prepared" then
  -- 1. The measured case: the parent session is not on this node at all, and the incoming source
  -- path arrived empty. The child must still get the same thing a local child gets.
  local absent = "e42bb0ca-9c95-47fe-beae-514dd9fe8956"
  local placed = child_session("placed-child", absent)
  local placed_workspace, placed_error = workspaces.ensure(memory, placed, absent)
  ok(placed_workspace, "a placed child allocates on the destination: " .. tostring(placed_error))
  local placed_state = placed_workspace.start_state
  ok(normalized(placed_state.source_root) == normalized(destination),
    "the placed child forked from the destination's own checkout: " .. tostring(placed_state.source_root))
  ok(placed_state.source_origin == "runtime-worktree.txt",
    "the record names which tree it used: " .. tostring(placed_state.source_origin))
  ok(placed_state.source_requested == "" and placed_state.base_commit == destination_head
      and placed_state.base_commit ~= foreign_head,
    "the fork base is the destination's HEAD, not anything the coordinator sent")
  local placed_head = git(placed_workspace.worktree, "rev-parse", "HEAD")
  ok(placed_head == destination_head,
    "the worktree on disk is at the destination's commit: " .. tostring(placed_head))
  print("placed child forked from " .. placed_state.source_root .. " at " .. placed_state.base_commit ..
    " (origin=" .. tostring(placed_state.source_origin) .. ")")

  -- 2. A session of another node as the source, naming a path that exists on this machine. That path
  -- is another machine's meaning of the same string, so it is not a source here.
  local coordinator = memory.start_session("local", "chat",
    { id = "coordinator-session", user_id = "master", node_id = "openclaw" })
  memory.set_session_worktree(coordinator, foreign)
  local child2 = child_session("placed-child-foreign", coordinator)
  local ws2, err2 = workspaces.ensure(memory, child2, coordinator)
  ok(ws2, "a foreign source session still allocates: " .. tostring(err2))
  ok(normalized(ws2.start_state.source_root) == normalized(destination)
      and normalized(ws2.start_state.source_root) ~= normalized(foreign),
    "a path recorded on another node is never the source, even when it exists here")
  ok(normalized(ws2.start_state.source_requested) == normalized(foreign),
    "the record repeats what the incoming session named: " .. tostring(ws2.start_state.source_requested))
  ok(tostring(ws2.start_state.source_fallback):find("workspace_source_foreign_node", 1, true) ~= nil,
    "and why it was not used: " .. tostring(ws2.start_state.source_fallback))

  -- 3. Unchanged: a session of *this* node is a source, and its own checkout is used as it is.
  local local_source = memory.start_session("local", "chat",
    { id = "local-source", user_id = "master", node_id = NODE })
  memory.set_session_worktree(local_source, foreign)
  local child3 = child_session("local-child", local_source)
  local ws3, err3 = workspaces.ensure(memory, child3, local_source)
  ok(ws3, "a session of this node is still a source: " .. tostring(err3))
  ok(ws3.start_state.source_origin == "source-session" and ws3.start_state.base_commit == foreign_head,
    "it forks from that session's own checkout, unchanged: " .. tostring(ws3.start_state.source_origin))

  -- 4. A same-node source whose recorded path is gone: the incoming source names nothing here, so the
  -- child forks from this node's checkout and the record says both things.
  local gone = memory.start_session("local", "chat",
    { id = "gone-source", user_id = "master", node_id = NODE })
  memory.set_session_worktree(gone, destination .. "/not-a-repository")
  local child4 = child_session("gone-child", gone)
  local ws4, err4 = workspaces.ensure(memory, child4, gone)
  ok(ws4, "a source path that is gone on this machine is not a refusal: " .. tostring(err4))
  ok(ws4.start_state.source_origin == "runtime-worktree.txt"
      and tostring(ws4.start_state.source_fallback):find("workspace_source_path_missing", 1, true) ~= nil,
    "it falls back to this node's checkout and records why: " .. tostring(ws4.start_state.source_fallback))

  -- 4b. A destination whose `git worktree add` fails must report git's own reason. A branch of the
  -- same name already in that repo is the case that was measured as a lie: the failed add was
  -- followed by reads that answered with empty stdout, so the refusal read
  -- `workspace_binding_branch_mismatch` while the truth was on git's stderr.
  git(destination, "branch", "change/wa-session-collision")
  local collision = child_session("collision", absent)
  local collision_ws, collision_why = workspaces.ensure(memory, collision, absent)
  ok(not collision_ws and tostring(collision_why):find("already exists", 1, true) ~= nil,
    "a failed worktree add names git's own reason: " .. tostring(collision_why))
  ok(tostring(collision_why):find("workspace_binding_branch_mismatch", 1, true) == nil,
    "and does not mis-report it as a branch mismatch")
  ok(memory.session_workspace(collision).state ~= "pending",
    "the failed allocation is not left pending: " .. tostring(memory.session_workspace(collision).state))

  -- 5. Through the facade a peer actually calls: the same placement, with a write-capable profile.
  local known = session_ids()
  local started = dofile("lua/core/subagents.lua").control({
    action = "start", prompt = "fork a workspace on this node", profile = "task-worker",
  }, { user_id = "master", role = "master", node_id = NODE, session_id = absent, remote = true,
       placement = { max_tasks = 1 } })
  ok(type(started) == "table", "the facade answers a placed start: " .. json.encode(started))
  local child_id
  for id in pairs(session_ids()) do if not known[id] then child_id = id end end
  ok(child_id, "the child's session was created: " .. json.encode(started))
  local child_workspace = memory.session_workspace(child_id)
  ok(child_workspace and child_workspace.state == "allocated",
    "its workspace is allocated through the facade: " .. json.encode(child_workspace))
  ok(normalized(child_workspace.start_state.source_root) == normalized(destination),
    "and it forked from the destination's own checkout: " .. tostring(child_workspace.start_state.source_root))
  print("facade start on the prepared destination: " .. json.encode(started))

  -- 5b. The invariant that made 840 shells possible: a retry must have the effect of the attempt
  -- before it. An admission refusal is a real one here - a placement limit of zero slots makes the
  -- runtime answer `node_full` - and two attempts with the same idempotency key must leave one child
  -- session and one checkout, not two.
  local subagents = dofile("lua/core/subagents.lua")
  local function attempts_with(key, limit)
    return subagents.control({ action = "start", prompt = "retry me", profile = "task-worker",
      idempotency_key = key },
      { user_id = "master", role = "master", node_id = NODE, session_id = absent, remote = true,
        placement = { max_tasks = limit } })
  end
  local function children()
    local count = 0
    for _, child in pairs(json.decode(host.sql_query(
        "SELECT id FROM sessions WHERE objective='subagent'", json.encode({})) or {})) do count = count + 1 end
    return count
  end
  local before_attempts = children()
  local full_first = attempts_with("placed-retry", 0)
  ok(full_first.error == "node_full", "a zero-slot placement limit is refused by the runtime: " .. json.encode(full_first))
  ok(children() == before_attempts + 1, "the refused attempt wrote one child session")
  local shell_id = "child:placed-retry"
  local shell = memory.session(shell_id)
  ok(shell ~= nil, "the shell is named by its key, so the retry can find it: " .. tostring(shell_id))
  local shell_workspace = memory.session_workspace(shell_id)
  ok(shell_workspace and shell_workspace.state == "allocated" and shell_workspace.worktree ~= "",
    "and it holds the checkout the retry will run in: " .. json.encode(shell_workspace))
  local full_second = attempts_with("placed-retry", 0)
  ok(full_second.error == "node_full", "the retry is refused the same way: " .. json.encode(full_second))
  ok(children() == before_attempts + 1,
    "and it reused that shell instead of writing another (" .. children() .. " children, not " .. (before_attempts + 2) .. ")")
  local reused = memory.session_workspace(shell_id)
  ok(reused and reused.worktree == shell_workspace.worktree and reused.state == "allocated",
    "with the same checkout, so a retry costs no second worktree")
  ok(shell.user_id == "master" and shell.node_id == NODE and shell.parent_session_id == absent,
    "the reused shell belongs to the same caller, node and parent")
  local conflict = subagents.control({ action = "start", prompt = "another caller", profile = "task-worker",
    idempotency_key = "placed-retry" },
    { user_id = "master", role = "master", node_id = NODE, session_id = "someone-else", remote = true,
      placement = { max_tasks = 1 } })
  ok(conflict.error == "idempotency_key_conflict" and conflict.not_started == true,
    "a key is a name, not a capability: another parent may not reuse that shell: " .. json.encode(conflict))

  -- 5c. A refusal that ends the request retires the shell: nothing is kept for a retry that will not
  -- come, and the retry of that same key reuses the same row rather than adding one.
  git(destination, "branch", "change/wa-session-childplaced-nonretry")
  local nonretry_before = children()
  local nonretry = attempts_with("placed-nonretry", 1)
  ok(tostring(nonretry.detail):find("already exists", 1, true) ~= nil,
    "a non-retryable failure names git's reason: " .. json.encode(nonretry))
  ok(children() == nonretry_before + 1, "it wrote one session for the attempt")
  ok(memory.session("child:placed-nonretry").ended_at ~= nil,
    "and retired it, because nothing will reuse a request that ended")

  -- 5d. The verb reconcile calls on the destination, through the facade a peer reaches: the runtime
  -- answers from its durable records, so `found:false` is proof that key was never admitted here.
  local destination_ctx = { user_id = "master", role = "master", node_id = NODE, remote = true }
  local never = subagents.control({ action = "resolve", idempotency_key = "never-used-key" }, destination_ctx)
  ok(never.found == false and never.unadmitted == true,
    "a key with no run there is reported as not admitted: " .. json.encode(never))
  local admitted = attempts_with("placed-resolve", 1)
  ok(admitted.subagent_id, "a keyed start is admitted: " .. json.encode(admitted))
  local found = subagents.control({ action = "resolve", idempotency_key = "placed-resolve" }, destination_ctx)
  ok(found.found == true and type(found.receipt) == "table" and found.receipt.subagent_id == admitted.subagent_id,
    "and the key it was admitted under resolves to that run: " .. json.encode(found))
  local keyless = subagents.control({ action = "resolve" }, destination_ctx)
  ok(keyless.error == "idempotency_key_required" and keyless.not_started == true,
    "a resolve without a key is refused: " .. json.encode(keyless))

  -- 6. What a destination's answer means for the attempt.
  ok(orchestrator.classify({ subagent_id = "x" }) == "admitted", "a receipt with an id is admission")
  ok(orchestrator.classify({ error = "node_full" }) == "spilled", "capacity moves to the next candidate")
  ok(orchestrator.classify({ error = "workspace_destination_source_missing", not_started = true }) == "spilled",
    "a destination with no checkout of its own moves to the next candidate")
  ok(orchestrator.classify({ error = "workspace_source_dirty", not_started = true }) == "refused",
    "a refusal no candidate can take ends the attempt")
  ok(orchestrator.classify({ error = "remote_unreachable" }) == "uncertain", "transport stays pinned")
  ok(orchestrator.classify({ error = "dispatch_uncertain" }) == "uncertain", "an uncertain delivery stays pinned")
  ok(orchestrator.classify({}) == "uncertain", "an answer that proves nothing stays pinned")
  ok(orchestrator.classify({ error = "an_error_from_the_future" }) == "uncertain",
    "an unrecognised error keeps the pinned retry rather than guessing")
  -- The two halves of one rule: a refusal that keeps the destination's shell for a retry is exactly a
  -- refusal that may move to the next candidate. If they ever disagree, a kept shell is orphaned or a
  -- reused shell is written twice.
  for code in pairs(subagents.RETRYABLE_ADMISSION) do
    ok(orchestrator.spills_on(code), "a retryable admission refusal may also move on: " .. code)
  end
  ok(orchestrator.spills_on("workspace_source_dirty") == false,
    "and a refusal about the request itself may not")

  -- 7. The same decision through the queue the serve worker calls, with only the peer transport
  -- stubbed: a refusal ends the row, is retractable, and is not dispatched again; a spillable
  -- refusal drops the pin, so a node that leaves the policy stops being tried.
  local parent = memory.start_session("local", "chat", { id = "fixture-coordinator", user_id = "master", node_id = NODE })
  local ctx = { user_id = "master", role = "master", node_id = NODE, session_id = parent, run_id = "fixture-run" }
  local handled, placement = orchestrator.control({ action = "placement", policy = {
    enabled = true, nodes = { { node = "local", max_tasks = 1 } } } }, ctx)
  ok(handled == true and placement.policy and placement.policy.enabled == true,
    "placement policy saved: " .. json.encode(placement))

  local calls = 0
  local refusal = { error = "workspace_source_dirty",
    detail = "workspace_source_dirty: commit or clean the source checkout before allocating", not_started = true }
  local api = { control = function() calls = calls + 1; return refusal end }
  local queued = orchestrator.enqueue({ prompt = "refuse me on this destination", idempotency_key = "placed-refuse" }, ctx)
  ok(queued and queued.subagent_id, "the task is queued durably: " .. json.encode(queued))
  orchestrator.tick(api)
  local row = json.decode(host.sql_query("SELECT * FROM orchestration_tasks WHERE id=?", json.encode({ queued.subagent_id })))[1]
  ok(row and row.state == "refused", "a refused attempt ends the attempt: " .. json.encode(row))
  local dispatched = calls
  orchestrator.tick(api)
  ok(calls == dispatched, "a refused row is not dispatched again (calls " .. calls .. ")")
  local cancelled = select(2, orchestrator.control({ action = "cancel", id = queued.subagent_id }, ctx))
  ok(cancelled and cancelled.dispatch_state == "cancelled",
    "and it is retractable without reconciliation: " .. json.encode(cancelled))

  local spill_refusal = { error = "workspace_destination_source_missing",
    detail = "workspace_destination_source_missing: this node has no checkout of its own to fork from",
    not_started = true }
  local spill_api = { control = function() calls = calls + 1; return spill_refusal end }
  local spill = orchestrator.enqueue({ prompt = "run somewhere that can fork", idempotency_key = "placed-spill" }, ctx)
  orchestrator.tick(spill_api)
  local spill_row = json.decode(host.sql_query("SELECT * FROM orchestration_tasks WHERE id=?", json.encode({ spill.subagent_id })))[1]
  ok(spill_row and spill_row.state == "queued" and spill_row.destination == "",
    "a spillable refusal returns the task to the queue with the pin dropped: " .. json.encode(spill_row))
  local attempts = calls
  orchestrator.tick(spill_api)
  ok(calls > attempts, "and the next tick asks the policy again rather than the refused node")
  local spill_again = select(2, orchestrator.control({ action = "status", id = spill.subagent_id }, ctx))
  ok(spill_again and spill_again.attempts == 2,
    "and how many times a destination was asked is on the receipt: " .. json.encode(spill_again))
  orchestrator.control({ action = "placement", policy = { enabled = false, nodes = {} } }, ctx)
  local before_removal = calls
  orchestrator.tick(spill_api)
  ok(calls == before_removal, "a destination that is no longer in the policy is not tried (" .. calls .. ")")

  -- 8. A delivery whose outcome was never observed is parked, not re-sent: sending it again could
  -- start a second child for one task. Nothing moves until `reconcile` asks the destination what it
  -- holds for this task's key.
  orchestrator.control({ action = "placement", policy = {
    enabled = true, nodes = { { node = "local", max_tasks = 1 } } } }, ctx)
  local per_key = {}
  local uncertain_api = { control = function(args)
    calls = calls + 1
    local key = tostring((args or {}).idempotency_key or "")
    per_key[key] = (per_key[key] or 0) + 1
    -- The spillable task keeps being refused (it may be placed again); everything else is lost in
    -- transit without an answer, which is the case this section is about.
    if key == spill.subagent_id then return spill_refusal end
    return { error = "remote_unreachable" }
  end }
  local function task_row(id)
    return json.decode(host.sql_query("SELECT * FROM orchestration_tasks WHERE id=?", json.encode({ id })))[1]
  end
  local lost = orchestrator.enqueue({ prompt = "did you get this?", idempotency_key = "placed-uncertain" }, ctx)
  orchestrator.tick(uncertain_api)
  local lost_row = task_row(lost.subagent_id)
  ok(lost_row.state == "unknown" and lost_row.destination == "local",
    "an unobserved delivery is parked with its destination kept: " .. json.encode(lost_row))
  local parked_calls = per_key[lost.subagent_id]
  orchestrator.tick(uncertain_api)
  ok(parked_calls == 1 and per_key[lost.subagent_id] == 1,
    "and it is asked exactly once while it is unknown (" .. tostring(per_key[lost.subagent_id]) .. ")")
  local refused_cancel = select(2, orchestrator.control({ action = "cancel", id = lost.subagent_id }, ctx, uncertain_api))
  ok(refused_cancel.error == "placement_uncertain_reconcile_before_cancelling",
    "cancel still needs the outcome, not a guess: " .. json.encode(refused_cancel))

  -- `reconcile` is the verb that was missing: the destination is asked whether it holds a run for the
  -- key, and its answer decides. Here it answers that nothing was admitted, which makes a retry safe.
  local unadmitted_api = { control = function() return { idempotency_key = lost.subagent_id, found = false, unadmitted = true } end }
  local reconciled = select(2, orchestrator.control({ action = "reconcile", id = lost.subagent_id }, ctx, unadmitted_api))
  ok(reconciled and reconciled.dispatch_state == "queued" and reconciled.attempts == 1,
    "a proven-unadmitted delivery returns to the queue for another try: " .. json.encode(reconciled))

  -- And when the destination does hold a run, the receipt is adopted: nothing is re-sent.
  local second = orchestrator.enqueue({ prompt = "adopt me", idempotency_key = "placed-adopt" }, ctx)
  orchestrator.tick(uncertain_api)
  ok(task_row(second.subagent_id).state == "unknown", "a second lost delivery is parked too")
  local adopted_api = { control = function() return { idempotency_key = second.subagent_id, found = true,
    receipt = { subagent_id = "remote-child-1", session_id = "remote-session-1", state = "running", settled = false } } end }
  local adopted = select(2, orchestrator.control({ action = "reconcile", id = second.subagent_id }, ctx, adopted_api))
  ok(adopted and adopted.dispatch_state == "admitted" and adopted.remote_subagent_id == "remote-child-1",
    "a run that exists there is adopted, not re-sent: " .. json.encode(adopted))
  -- A destination that cannot be reached while reconciling answers nothing, so the row stays parked.
  local third = orchestrator.enqueue({ prompt = "still unknown", idempotency_key = "placed-unknown" }, ctx)
  orchestrator.tick(uncertain_api)
  local silent_api = { control = function() return { error = "remote_unreachable" } end }
  local silent = select(2, orchestrator.control({ action = "reconcile", id = third.subagent_id }, ctx, silent_api))
  ok(silent.error == "reconcile_failed" and task_row(third.subagent_id).state == "unknown",
    "an unreachable destination leaves the row unknown: " .. json.encode(silent))
  -- Nothing that ended, was adopted elsewhere or is still unknown is left where a tick would pick it
  -- up again: after the reconcile above, the only rows a tick may touch are the ones whose refusals
  -- proved nothing was started.
  local queued_ids = {}
  local queued_rows = selected_sql("SELECT id FROM orchestration_tasks WHERE state IN ('queued','placing')")
  for _, item in ipairs(queued_rows) do queued_ids[item.id] = true end
  ok(not queued_ids[queued.subagent_id] and not queued_ids[second.subagent_id] and not queued_ids[third.subagent_id],
    "a refused, an adopted and an unknown task are not in the queue: " .. json.encode(queued_rows))
  ok(queued_ids[spill.subagent_id] == true or task_row(spill.subagent_id).state == "unknown",
    "and the one that may be asked again is the one whose refusal proved nothing started")
  ok(per_key[lost.subagent_id] == 2 and task_row(lost.subagent_id).state == "unknown",
    "the task reconciled to unadmitted was placed once more and is parked again (" ..
    tostring(per_key[lost.subagent_id]) .. " asks)")

  print("placed child workspace ok (" .. checks .. " checks)")
  return
end

-- The unprepared destination: no `runtime-worktree.txt`, and a working directory that is not a
-- checkout. This is the case that must refuse by name - and must not leave a session shell.
local before = session_ids()
local refusal = dofile("lua/core/subagents.lua").control({
  action = "start", prompt = "fork a workspace", profile = "task-worker",
}, { user_id = "master", role = "master", node_id = NODE, session_id = "e42bb0ca-9c95-47fe-beae-514dd9fe8956",
     remote = true, placement = { max_tasks = 1 } })
ok(refusal.error == "workspace_destination_source_missing",
  "a destination with no usable source refuses by name: " .. json.encode(refusal))
ok(refusal.not_started == true, "and says nothing of its was started: " .. json.encode(refusal))
ok(tostring(refusal.detail):find("runtime-worktree.txt", 1, true) ~= nil
    and tostring(refusal.detail):find("workspace_source_session_not_found", 1, true) ~= nil,
  "the refusal names what is missing on both sides: " .. tostring(refusal.detail))
ok(refusal.session_id == nil, "the refusal created no session: " .. json.encode(refusal))
local after = session_ids()
for id in pairs(after) do ok(before[id], "no session shell is left behind on the refusing node: " .. tostring(id)) end

-- The same refusal recorded on a child's own workspace, never left `pending`.
local child = child_session("unprepared-child", "e42bb0ca-9c95-47fe-beae-514dd9fe8956")
local workspace, why = workspaces.ensure(memory, child, "e42bb0ca-9c95-47fe-beae-514dd9fe8956")
ok(not workspace and tostring(why):find("workspace_destination_source_missing", 1, true) ~= nil,
  "the allocator refuses the same way: " .. tostring(why))
ok(workspaces.refusal_code(why) == "workspace_destination_source_missing",
  "and the code is the one a coordinator branches on: " .. tostring(why))
ok(memory.session_workspace(child).state == "failed",
  "the refusal is recorded on the child's workspace, not left pending")
print("unprepared destination refused: " .. tostring(why))
print("placed child workspace ok (" .. checks .. " checks)")
