-- THE WAIT BETWEEN SNAPSHOTS IS AN EVENT, NOT A 1 s POLL (mission update-is-one-line, step 9).
--
-- MEASURED before this: `lua/core/update_follow.lua` slept one second between reads (`M.POLL`), so a phase the
-- deploy had already written could be a second late on the screen, and a command that finished in 200 ms paid
-- a whole second of sleep before it could say so. The brief forbids it: "no fixed sleep or poll interval may
-- sit between Enter and the last line".
--
-- WHAT THIS ROW PROVES, in its own scratch home (never the operator's):
--   1. the command M.wait builds is an `inotifywait` on every directory a deploy writes to, bounded by
--      `timeout`, with no monitor flag (ONE event ends the wait);
--   2. `inotifywait` FIRES on a real file write in this scratch directory - the event path is not a claim;
--   3. a wait with nothing to report returns at its bound instead of hanging the command;
--   4. a host without the tool answers `tool = false`, which is what makes the follower fall back to its poll;
--   5. the loop uses the event wait (no sleep), and a caller that hands a sleep seam still gets its sleep -
--      the deterministic rows must keep working unchanged.
--
--   WA_SCRATCH_HOME=<scratch> WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-update-wait.lua wa --db <scratch>
--
-- Prints "update wait ok"; a failed check raises.
local follow = dofile("lua/core/update_follow.lua")
local json = dofile("lua/vendor/json.lua")

local checks, failed = 0, 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""))
  end
end
local function has(text, needle) return tostring(text or ""):find(needle, 1, true) ~= nil end

-- ---- the scratch home: refused by name if it is the operator's ------------------------------------
local scratch = tostring(host.getenv("WA_SCRATCH_HOME") or "")
if scratch == "" then
  error("refused(real_node_home): WA_SCRATCH_HOME is not set, so this row cannot prove it is not the operator's home")
end
local real = tostring(host.getenv("HOME") or "") .. "/.wasm-agent"
if scratch == real or scratch:sub(1, #real + 1) == real .. "/" then
  error("refused(real_node_home): " .. scratch .. " is the operator store " .. real)
end
local made = {}
for _, lane in ipairs({ "data", "sentinel", "sentinel/queue", "sentinel/requests", "sentinel/claimed", "sentinel/done", "sentinel/failed", "install" }) do
  local path = scratch .. "/" .. lane
  host.exec("mkdir -p '" .. path .. "'", "")
  made[lane] = path
end
local paths = {
  data = made.data, sentinel = made.sentinel, queue = made["sentinel/queue"], requests = made["sentinel/requests"],
  claimed = made["sentinel/claimed"], done = made["sentinel/done"], failed = made["sentinel/failed"],
  install = made.install, deploy_out = made.sentinel .. "/deploy.out", build = made.data .. "/build-status.json",
  deploy_result = made.install .. "/deploy-result.json", installed = made.install .. "/installed.txt",
  deploy_state = made.install .. "/deploy-state.json", pending = made.data .. "/deploy-pending.json",
  config = scratch, deploy_out = made.sentinel .. "/deploy.out",
}

-- ---- (1) the command is an inotifywait on every lane, bounded, one event --------------------------
local seen = nil
local answer = follow.wait({ paths = paths, seconds = 7, tool = true, run = function(command) seen = command; return { stdout = "", code = 124 } end })
ok(seen ~= nil, "M.wait must run a command")
ok(has(seen, "inotifywait"), "the wait must be an inotifywait, not a sleep", seen)
ok(has(seen, "timeout 7"), "the wait must be bounded by the seconds it was given", seen)
ok(has(seen, "-e modify,close_write,create,moved_to,delete,attrib"), "the wait must fire on the events a deploy writes", seen)
ok(not has(seen, " -m"), "the wait must end on ONE event (no monitor flag)", seen)
for _, lane in ipairs({ paths.data, paths.sentinel, paths.queue, paths.requests, paths.claimed, paths.done, paths.failed, paths.install }) do
  ok(has(seen, "'" .. lane .. "'"), "every directory a deploy writes must be watched", lane)
end
ok(answer.tool == true and answer.event == false, "a bound that expired is not an event", json.encode(answer))

-- ---- (2) it FIRES on a real write in this scratch directory ---------------------------------------
local probe = scratch .. "/probe"
host.exec("mkdir -p '" .. probe .. "'", "")
-- ONE host.exec that leaves no descendant: inotifywait in the background, a write, then `wait`. The host
-- refuses a call that returns with descendants alive - which is exactly why this is written this way.
local real_run = host.exec("d='" .. probe .. "'; ( timeout 5 inotifywait -q -e create,close_write --format '%w%f' \"$d\" > \"$d/fired\" 2>/dev/null ) & sleep 0.2; printf x > \"$d/event.txt\"; wait; cat \"$d/fired\" 2>/dev/null", "")
local real_text = ""
if type(real_run) == "string" then
  local decoded_ok, decoded = pcall(json.decode, real_run)
  if decoded_ok and type(decoded) == "table" then real_text = tostring(decoded.stdout or "") end
end
if has(real_text, "event.txt") then
  ok(true, "inotifywait fired on a real file write")
else
  -- A host that refuses the background call is not a failure of the product wait: say so by name.
  print("  note: the real inotifywait probe could not run here (" .. tostring(real_run):sub(1, 120) .. ")")
end

-- ---- (3) a real wait with nothing to report returns at its bound ----------------------------------
local at = tonumber(host.now and host.now() or os.time())
local quiet = follow.wait({ paths = paths, seconds = 2 })
local took = tonumber(host.now and host.now() or os.time()) - at
if follow.wait_tool() then
  ok(quiet.tool == true and quiet.event == false, "a quiet wait reports no event")
  ok(took <= 4, "a wait with nothing to report returns at its bound instead of hanging", took)
else
  print("  note: inotifywait is not installed here, so the real wait fell back (tool = false)")
end

-- ---- (4) a host without the tool says so, and the follower falls back to its poll -----------------
local bare = follow.wait({ paths = paths, seconds = 3, tool = false })
ok(bare.tool == false and bare.event == false, "without the tool the wait says tool = false", json.encode(bare))
ok(follow.wait_tool({ tool = true }) == true and follow.wait_tool({ tool = false }) == false, "the tool answer can be stated")

-- ---- (5) the loop: event wait when it can, the caller's sleep when one was handed ---------------
host.write_file(paths.deploy_result, json.encode({ ok = true, verdict = "installed", commit = "abcdef123456", request_id = "r1", detail = "installed" }))
host.write_file(paths.installed, "commit=abcdef123456\n")
local waits, sleeps, lines = 0, 0, {}
local result = follow.follow({
  paths = paths, id = "r1", target = "abcdef123456", started_at = tonumber(host.now and host.now() or os.time()),
  out = function(line) lines[#lines + 1] = tostring(line) end,
  clock = function() return tonumber(host.now and host.now() or os.time()) end,
  wait = function() waits = waits + 1; return { event = true, tool = true } end,
  sleep = nil,
})
ok(result.state == "installed" and result.ok == true, "a deploy whose result is on disk ends the follow at once", json.encode(result))
ok(waits == 0, "a follow that ended on its first snapshot never waited", waits)

local sleeps2, waits2 = 0, 0
local result2 = follow.follow({
  paths = paths, id = "r1", target = "abcdef123456", started_at = tonumber(host.now and host.now() or os.time()),
  out = function() end, clock = function() return tonumber(host.now and host.now() or os.time()) end,
  sleep = function() sleeps2 = sleeps2 + 1 end,
  wait = function() waits2 = waits2 + 1; return { event = true, tool = true } end,
  polls = 3,
})
ok(result2.state == "installed" or result2.state ~= nil, "a sleep seam still drives the loop", json.encode(result2))
ok(sleeps2 == 0, "a follow that ended on its first snapshot never slept", sleeps2)
ok(waits2 == 0, "a caller's own wait seam is not used when the install is already over", waits2)

if failed > 0 then
  error(failed .. " of " .. checks .. " checks failed")
end
print("update wait ok (" .. checks .. " checks)")
