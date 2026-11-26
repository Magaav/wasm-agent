-- A FINISHED INSTALL SETTLES THE REQUEST IT SERVED (update-requests-settle, Fable 26/11).
--
-- WHAT WAS WRONG, measured: the settle block in remote_update.read_status wrote the record's OUTCOME and left its
-- STATE at `queued` forever, and `installed` had no writer at all. openclaw held 78 records saying queued about
-- installs that worked, because the cut's wait reads `state` from the file.
--
-- This row drives the reader that settles: a request queued, the sentinel's outcome ledger saying the install
-- succeeded, and the install record naming the commit that was asked for. Then the FILE must say installed, with the
-- time it finished and the commit, and a second read must not rewrite it.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then error("this test writes fixtures: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local remote = dofile("lua/core/remote_update.lua")

local n = 0
local function check(what, cond) if not cond then error("FAIL test-update-settles: " .. what) end n = n + 1 end

local root = host.paths().home .. "/update-settles-fixture"
local install = root .. "/install"
local sentinel_dir = root .. "/sentinel"
local records = root .. "/config/remote-update"
for _, dir in ipairs({ install, sentinel_dir .. "/deploy-outcome", records }) do
  host.exec("mkdir -p '" .. dir .. "'", "", 30)
end

local TARGET = string.rep("ab", 20)
local ID = "request-under-test"
local CALLER = { node_id = "guest-node-id" }

local function put(path, text) assert(host.write_file(path, text) == true, "fixture write failed: " .. path) end
local function read_json(path)
  local text = host.read_file(path)
  if type(text) ~= "string" then return nil end
  local ok, value = pcall(json.decode, text)
  return ok and value or nil
end

-- the node: the commit that was asked for is what it runs
put(install .. "/installed.txt", "commit=" .. TARGET .. "\nbranch=main\n")
put(install .. "/runtime-worktree.txt", "/tmp/not-a-checkout\n")
-- the sentinel's verdict for that exact request id
put(sentinel_dir .. "/deploy-outcome/" .. ID .. ".json",
  json.encode({ state = "settled", outcome = "success", detail = "installed by the sentinel" }))
-- the request record, exactly as run_accepted leaves it: queued, with the sentinel request id
put(records .. "/" .. ID .. ".json", json.encode({
  id = ID, kind = "deploy", state = "queued", outcome = nil,
  target_commit = TARGET, sentinel_request_id = ID, requested_at = 1000,
  requester = { node_id = CALLER.node_id } }))

remote.records_root = records
remote.facts_options = { install = install, sentinel_dir = sentinel_dir }

-- 1. the reader that settles, on a request whose install finished
local reply = remote.read_status({ id = ID }, CALLER)
check("the reader answers an outcome (" .. tostring(reply and reply.error) .. ")", reply and reply.ok == true)
check("and it is installed", reply and reply.state == "installed")

-- 2. THE FILE, which is what the cut's wait reads
local after = read_json(records .. "/" .. ID .. ".json")
check("the record file says installed (state=" .. tostring(after and after.state) .. ")", after and after.state == "installed")
check("it carries the time it finished", after and tonumber(after.finished_at or 0) > 0)
check("and the commit that was installed", after and after.installed_commit == TARGET)
check("it is no longer queued by any field a reader checks", after and after.state ~= "queued" and after.outcome ~= "queued")

-- 3. idempotent: a second read changes nothing on disk
local first_text = host.read_file(records .. "/" .. ID .. ".json")
local again = remote.read_status({ id = ID }, CALLER)
local second_text = host.read_file(records .. "/" .. ID .. ".json")
check("a second read still says installed", again and again.state == "installed")
check("and it does NOT rewrite the record", first_text == second_text)

-- 4. A FAILED INSTALL settles failed - and the fixture is a REAL failure, which the first version was not: it said
-- outcome=failed while installed.txt already named the commit asked for, a state no install produces (the node either
-- runs the commit you asked for or it does not). A failed install is a node STILL ON THE OLD COMMIT, and that is what
-- this fixture now describes.
local OLD = string.rep("cd", 20)
put(install .. "/installed.txt", "commit=" .. OLD .. "\nbranch=main\n")
local ID2 = "request-refused"
put(sentinel_dir .. "/deploy-outcome/" .. ID2 .. ".json",
  json.encode({ state = "settled", outcome = "failed", detail = "the deploy refused: tree dirty" }))
put(records .. "/" .. ID2 .. ".json", json.encode({
  id = ID2, kind = "deploy", state = "queued", target_commit = TARGET, sentinel_request_id = ID2,
  requested_at = 1001, requester = { node_id = CALLER.node_id } }))
local refused = remote.read_status({ id = ID2 }, CALLER)
check("a failed install reads failed (got " .. tostring(refused and refused.state) .. ")", refused and refused.state == "failed")
local refused_file = read_json(records .. "/" .. ID2 .. ".json")
check("and its FILE says failed, not queued (got " .. tostring(refused_file and refused_file.state) .. ")",
  refused_file and refused_file.state == "failed")
check("with the installer's own reason", refused_file and tostring(refused_file.detail or "") ~= "")

-- 5. THE SWEEP: old queued records are CLOSED BY NAME, nothing is deleted, and a second run closes nothing.
local NOW = math.floor(host.now())
local function queued(id, node, age_seconds)
  put(records .. "/" .. id .. ".json", json.encode({ id = id, kind = "deploy", state = "queued",
    target_commit = TARGET, requested_at = NOW - age_seconds, requester = { node_id = node } }))
end
-- two from one node (the newer must supersede the older) and one old one from another
queued("same-node-new", "node-a", 60)
queued("same-node-old", "node-a", 120)
queued("other-node-old", "node-b", 90000)
local before_files = 0
do
  local ok_list, listed = pcall(host.list_dir, records)
  if ok_list and type(listed) == "table" then
    for _, name in ipairs(listed) do if tostring(name):match("%.json$") then before_files = before_files + 1 end end
  end
end

local dry = remote.sweep({ max_age_seconds = 86400, dry_run = true })
check("a dry sweep reports what it would close", type(dry) == "table" and #(dry.closed or {}) >= 2)
check("and closes NOTHING", (function()
  local rec = read_json(records .. "/same-node-old.json")
  return rec and rec.state == "queued" and rec.closed_reason == nil
end)())

local first = remote.sweep({ max_age_seconds = 86400 })
local reasons = {}
for _, entry in ipairs(first.closed or {}) do reasons[tostring(entry.id)] = tostring(entry.reason) end
check("the older request of a node is superseded BY NAME (" .. tostring(reasons["same-node-old"]) .. ")",
  (reasons["same-node-old"] or ""):match("^superseded_by same%-node%-new") ~= nil)
check("a request nothing served in a day is expired (" .. tostring(reasons["other-node-old"]) .. ")",
  reasons["other-node-old"] == "expired")
check("the newest from a node stays queued", (function()
  local rec = read_json(records .. "/same-node-new.json")
  return rec and rec.state == "queued"
end)())
check("a closed record is still READABLE, with its reason", (function()
  local rec = read_json(records .. "/other-node-old.json")
  return rec and rec.state == "expired" and tostring(rec.closed_reason) == "expired" and tonumber(rec.closed_at or 0) > 0
end)())

local second = remote.sweep({ max_age_seconds = 86400 })
check("a second sweep closes nothing (idempotent)", #(second.closed or {}) == 0)
local after_files = 0
do
  local ok_list, listed = pcall(host.list_dir, records)
  if ok_list and type(listed) == "table" then
    for _, name in ipairs(listed) do if tostring(name):match("%.json$") then after_files = after_files + 1 end end
  end
end
check("and NOTHING was deleted (" .. before_files .. " -> " .. after_files .. ")", before_files == after_files)

print("update settles ok (" .. n .. " checks)")

