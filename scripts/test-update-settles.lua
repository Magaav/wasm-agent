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

-- 4. A FAILED INSTALL: OPEN QUESTION, measured, not asserted. With a ledger outcome 'failed' for a request whose
-- installed.txt names the target commit, the reader answered `unknown` with the detail "installed.txt names <c>",
-- not `failed` - the ledger branch and the commit check disagree about which one speaks for the record. That is a
-- real question for this mission (item 2 says failed + why), and this row does not pretend to answer it:
--   measured 2026-11-26: state=unknown, detail="installed.txt names abab..."

print("update settles ok (" .. n .. " checks)")

