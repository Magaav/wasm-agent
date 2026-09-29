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
  orchestrator.control({ action = "placement", policy = { enabled = false, nodes = {} } }, ctx)
  local before_removal = calls
  orchestrator.tick(spill_api)
  ok(calls == before_removal, "a destination that is no longer in the policy is not tried (" .. calls .. ")")

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
