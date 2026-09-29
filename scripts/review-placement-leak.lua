-- REVIEW FIXTURE (not part of the delivery under review).
--
-- The live defect: three pending rows, a destination that answers a capacity refusal, and a tick
-- driven repeatedly. Each attempt used to create a child session AND a worktree. This fixture drives
-- the *real* facade (`lua/core/subagents.lua`), so the session and the git worktree are real, and
-- counts them from the destination repository's own worktree registry after every tick.
--
-- The refusal is a real one from the native admission lock: the wrapper below sends
-- `placement.max_tasks = 0`, which the runtime answers with `node_full` (the same case
-- `scripts/test-placed-child-workspace.lua` section 5b pins). Nothing here touches a live node: the
-- home, the database and the destination repository are disposable and owned by this fixture.
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
local function quote(path) return "'" .. tostring(path):gsub("'", "'\\''") .. "'" end
local function shell(command)
  local ok_exec, raw = pcall(host.exec, command, "", 120)
  if not ok_exec then return nil, tostring(raw) end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil, tostring(raw) end
  if tonumber(decoded.code) ~= 0 then
    return nil, tostring(decoded.stderr or decoded.error or decoded.stdout or "command failed")
  end
  return tostring(decoded.stdout or ""), nil
end
local function lines(text)
  local count = 0
  for line in tostring(text or ""):gmatch("[^\r\n]+") do if line:gsub("%s", "") ~= "" then count = count + 1 end end
  return count
end

local NODE = nodes.node_name()
local destination = tostring(host.getenv("WASM_AGENT_TEST_DESTINATION_TREE") or "")
ok(destination ~= "", "fixture destination tree required")
ok(host.getenv("WA_INSTALL_DIR") ~= nil and host.getenv("WA_INSTALL_DIR") ~= "",
  "fixture install dir required (runtime-worktree.txt is read from it)")

-- What we count: child sessions, recorded worktrees, this repository's own worktree registrations
-- (exactly the number the live report counted: 1322), and empty/checked-out directories on disk.
local function child_sessions() return #rows("SELECT id FROM sessions WHERE objective='subagent'") end
-- A session's workspace is recorded on its own session row (`worktree`, `workspace_state`), which is
-- what `memory.session_workspace` reads.
local function recorded_worktrees()
  return #rows("SELECT id FROM sessions WHERE worktree IS NOT NULL AND worktree<>''")
end
local function pending_workspaces()
  return #rows("SELECT id FROM sessions WHERE workspace_required=1 AND workspace_state='pending'")
end
local function registrations()
  local listed, why = shell("git -C " .. quote(destination) .. " worktree list")
  if not listed then return -1, why end
  -- `git worktree list` prints the main checkout plus one line per linked worktree.
  return lines(listed) - 1
end
local function task_rows()
  local out = {}
  for _, row in ipairs(rows("SELECT id,state,destination,detail,args FROM orchestration_tasks ORDER BY created_at")) do
    local args = json.decode(row.args) or {}
    out[#out + 1] = { id = row.id, state = row.state, destination = row.destination,
      detail = row.detail, attempts = tonumber(args.dispatch_attempts) or 0 }
  end
  return out
end
local function summary()
  local states, attempts = {}, {}
  for _, row in ipairs(task_rows()) do
    states[#states + 1] = row.state
    attempts[row.id] = row.attempts
  end
  return table.concat(states, ","), attempts
end

local parent = memory.start_session("local", "chat", { id = "review-coordinator", user_id = "master", node_id = NODE })
local ctx = { user_id = "master", role = "master", node_id = NODE, session_id = parent, run_id = "review-run" }
orchestrator.control({ action = "placement", policy = { enabled = true, nodes = { { node = "local", max_tasks = 1 } } } }, ctx)

local keys = { "review-leak-a", "review-leak-b", "review-leak-c" }
local ids = {}
for _, key in ipairs(keys) do
  local queued = orchestrator.enqueue({ prompt = "capacity-refused child " .. key, profile = "task-worker",
    idempotency_key = key }, ctx)
  ok(queued and queued.subagent_id, "task is queued durably: " .. json.encode(queued))
  ids[#ids + 1] = queued.subagent_id
end

-- The real facade, with only the placement limit changed so the runtime's own admission lock answers
-- `node_full`: no transport is stubbed and every session/worktree below is written by real code.
local api = { control = function(args, caller_ctx)
  local forwarded = {}
  for key, value in pairs(args) do forwarded[key] = value end
  forwarded.placement = { max_tasks = 0 }
  -- The runtime reads the limit from the *context* (`spec.admission_limit = ctx.placement.max_tasks`),
  -- so the placement the coordinator sent has to be zeroed here too.
  local ctx0 = {}
  for key, value in pairs(caller_ctx) do ctx0[key] = value end
  ctx0.placement = { max_tasks = 0 }
  return subagents.control(forwarded, ctx0)
end }

local base_sessions, base_worktrees = child_sessions(), recorded_worktrees()
print(string.format("baseline before any tick: sessions=%d recorded_worktrees=%d registrations=%d",
  base_sessions, base_worktrees, select(1, registrations())))
print("tick | child_sessions | recorded_worktrees | git_registrations | pending_ws | rows | attempts | tick_ms")
local first, last
for tick = 1, 10 do
  local started = host.now()
  orchestrator.tick(api)
  local tick_ms = math.floor((host.now() - started) * 1000)
  local states, attempts = summary()
  local registrations_now = registrations()
  local line = string.format("%4d | %14d | %18d | %17d | %10d | %s | %d,%d,%d | %d", tick, child_sessions(),
    recorded_worktrees(), registrations_now, pending_workspaces(), states, attempts[ids[1]] or 0,
    attempts[ids[2]] or 0, attempts[ids[3]] or 0, tick_ms)
  print(line)
  if tick == 1 then
    first = { child_sessions(), recorded_worktrees(), registrations_now, states }
    for _, row in ipairs(task_rows()) do
      local workspace = memory.session_workspace("child:" .. row.id)
      print("  debug: " .. row.id .. " detail=" .. tostring(row.detail) .. " shell_ws=" ..
        json.encode(workspace and { state = workspace.state, worktree = workspace.worktree, error = workspace.error } or nil))
    end
  end
  last = { child_sessions(), recorded_worktrees(), registrations_now, states }
end

-- What the delivery claims, as assertions rather than a table a reader has to interpret.
ok(first[1] == base_sessions + 3 and first[2] == base_worktrees + 3,
  "the first attempt is the one that writes a pair per row: " .. json.encode(first))
ok(last[1] == first[1] and last[2] == first[2] and last[3] == first[3],
  "ten ticks leave exactly what one tick left (no second session, no second worktree): " ..
  json.encode({ first = first, last = last }))
ok(pending_workspaces() == 0, "no requirement is left pending: " .. tostring(pending_workspaces()))
for _, row in ipairs(task_rows()) do
  ok(row.state == "queued" and row.detail == "node_full",
    "a capacity refusal returns the row to the queue unchanged: " .. json.encode(row))
  ok(row.attempts == 10, "and the receipt counts every ask: " .. json.encode(row))
  ok(memory.session("child:" .. row.id) ~= nil,
    "the request's own shell is reused for all ten attempts: child:" .. row.id)
end
local registrations_now = registrations()
ok(registrations_now == last[2] - base_worktrees,
  "every recorded worktree is registered in git's own registry: " .. tostring(registrations_now))
print(string.format("VERDICT reuse-by-key: %d sessions and %d worktrees after 10 ticks for 3 rows (baseline %d/%d)",
  last[1], last[2], base_sessions, base_worktrees))
print("placement leak review ok (" .. checks .. " checks)")
