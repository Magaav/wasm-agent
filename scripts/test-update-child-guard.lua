-- A CHILD SHELL DOES NOT INSTALL, AND THE ACCEPTED TAIL IS NOT A CHILD (mission release-node-updates, D7).
--
-- MEASURED (fleet-dry-run ready-2, D7, at ebf6d2ec): a coordinator's `wa update <tree node> --commit` was
-- accepted and then refused by the peer's own detached child, one line before any work:
--   FAILED on omarchy: update_coordinator_only
-- because rust/wa-capabilities/src/operations.rs:1020 stamps every detached operation with the spawning
-- process's provenance, and lua/core/update.lua refused `update.run` for `WASM_AGENT_PROVENANCE=child` before
-- it looked at anything else. So the fleet step was closed on BOTH kinds of node: a release node answered
-- no_runtime_tree (D1), a tree node answered update_coordinator_only.
--
-- WHAT IS DRIVEN: the real lua/core/update.lua M.run and the real lua/core/remote_update.lua M.run_accepted,
-- with one host capability overridden (host.getenv, the marker it reads). The checks are about the DECISION
-- each entry point makes, which is where the defect was; the end-to-end install is proved on a real peer in
-- the mission report's row, not here.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-update-child-guard.lua wa --db <scratch>
--
-- Prints "update child guard ok"; a failed check raises.
io.stdout:setvbuf("line")
local guard = dofile("scripts/lib/test-home-guard.lua")
local why = guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if why then error("this row refuses to run (" .. why .. ")") end

local real_getenv = host.getenv
local marker = nil
host.getenv = function(key)
  if key == "WASM_AGENT_PROVENANCE" then return marker end
  return real_getenv(key)
end
local updater = dofile("lua/core/update.lua")
local remote = dofile("lua/core/remote_update.lua")

local checks = 0
local function ok(value, label, detail)
  checks = checks + 1
  if not value then error("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""), 2) end
  print("  ok: " .. label)
end
local function refusal(verdict)
  return tostring((type(verdict) == "table" and verdict.error) or "")
end

-- ---- (a) a child shell is still refused: this is the guard the fleet step must not have opened -----------
marker = "child"
local child = updater.run({})
ok(refusal(child) == "update_coordinator_only",
  "a child shell that runs update.run is still refused by name", refusal(child))
ok(child and child.message == "Workers merge/report; only coordinator requests installation.",
  "with the sentence it has always answered", child and child.message)

-- ---- (b) the accepted tail is not a child: it reaches the next gate instead of this one ------------------
-- In this fixture there is no install to run, so the call must fail LATER - the point is that it is no longer
-- stopped here, one line before the work, with the answer D7 measured.
marker = "child"
local tail = updater.run({ signed_request = true })
ok(refusal(tail) ~= "update_coordinator_only",
  "the accepted tail (signed_request) is NOT refused as a child", refusal(tail))
ok(type(tail) == "table", "and it answers a table, not nothing", type(tail))

-- ---- (c) the refusal is unchanged for everything else ---------------------------------------------------
marker = nil
local plain = updater.run({})
ok(refusal(plain) ~= "update_coordinator_only", "a coordinator/!human path is not refused as a child", refusal(plain))
marker = "orchestrator"
local orch = updater.run({})
ok(refusal(orch) ~= "update_coordinator_only", "an orchestrator's own shell is not refused as a child", refusal(orch))

-- ---- (d) the flag is not a thing a worker can wave: --accept runs only a record this node wrote ---------
-- No record: the tail refuses by name and starts nothing.
marker = "child"
local missing = remote.run_accepted("00000000-0000-4000-8000-000000000000")
ok(refusal(missing) == "accept_record_missing",
  "`--accept` on an id this node never wrote is refused by name and prepares nothing", refusal(missing))
ok(missing and tostring(missing.effect) == "none", "and it says its effect is none", missing and missing.effect)
-- ...and the id it takes is the only input: no commit, no mode, no reason.
local cli_source = host.read_file("lua/core/remote_update.lua") or ""
ok(cli_source:find("signed_request = true", 1, true) ~= nil,
  "the tail is the one caller that passes signed_request (lua/core/remote_update.lua M.run_accepted)")
-- The update capability has exactly TWO doors that continue a verified master request: the inline one
-- (request_node, the shape v0.1.1 always had) and the accepted tail (run_accepted, what 89eb3325 moved the
-- work into). Both pass the flag; nothing else in the node does.
local sites = select(2, cli_source:gsub("signed_request = true", ""))
ok(sites == 2, "the exemption has exactly two call sites, both in remote_update.lua's two update doors", sites)
ok(not cli_source:find("--signed_request", 1, true),
  "and no command-line flag spells it: `wa update` cannot be asked to set it")

host.getenv = real_getenv
print("update child guard ok (" .. checks .. " checks)")
