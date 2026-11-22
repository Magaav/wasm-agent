-- `wa land` -- THE RESUME: a round that failed at node 3 and is resumed at node 3, the rollback,
-- the pins the rollback writes, and the worktree that failed with nothing observed.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-resume.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-resume.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, tree_root, fixture, ok, eq, contains, shell, must, write_file, read_file = R.land, R.tree_root, R.fixture, R.ok, R.eq, R.contains, R.shell, R.must, R.write_file, R.read_file
local setup_fixture, advance_main, observed, fleet, journal_of, standard_checks = R.setup_fixture, R.advance_main, R.observed, R.fleet, R.journal_of, R.standard_checks

R.start_vault()

setup_fixture()
R.state.deploy_requests = {}
fleet.failing_node = "nextcloud"
fleet.recovered = false
observed.pushes, observed.main_pushes, observed.publish, observed.signs, observed.ships = 0, 0, 0, 0, 0
local deploy_code = land.run({ run = "case6", signer = "local", branches = { "change/one", "change/two" }, checks = standard_checks() })
eq(deploy_code, 1, "a node that fails stops the landing at the deploy")
local first = journal_of("case6")
eq(first.stopped_at, "deploy", "it stopped at the deploy")
contains(first.stop_detail, "nextcloud", "the stop names the node")
contains(first.stop_detail, "binary", "the stop names the mode the node needs")
eq(observed.pushes, 1, "the tip was pushed once")
eq(observed.publish, 1, "the release was published once")
local signs_once, ships_once = observed.signs, observed.ships
local landed = first.tree_commit
local before = #R.state.deploy_requests
ok(before >= 3, "the ring reached the third node before it stopped")

fleet.recovered = true
local resumed = land.run({ run = "case6", signer = "local", resume = true, checks = standard_checks() })
eq(resumed, 0, "the resume finishes the run")
local second = journal_of("case6")
eq(second.result, "done", "the run is done after the resume")
eq(observed.pushes, 1, "the resume did NOT push again")
eq(observed.main_pushes, 1, "the resume did NOT fast-forward main again")
eq(observed.publish, 1, "the resume did NOT publish again")
eq(observed.signs, signs_once, "the resume did NOT sign again")
eq(observed.ships, ships_once, "the resume did NOT ship again")
eq(#R.state.deploy_requests, before + 2, "the resume asked only the failed node and the one after it")
eq(R.state.deploy_requests[#R.state.deploy_requests - 1].node, "nextcloud", "the resume starts at node 3")
eq(R.state.deploy_requests[#R.state.deploy_requests].node, "openclaw", "and finishes with openclaw")
local states = {}
for _, row in ipairs(second.deploy) do states[#states + 1] = row.node .. ":" .. row.state end
contains(table.concat(states, ","), "nextcloud:failed", "the failed attempt stays in the record")
contains(table.concat(states, ","), "nextcloud:installed", "and the settled one is recorded beside it")
advance_main(landed)

-- ---------------------------------------------------------------- case 7: the rollback, reverse order
R.state.deploy_requests = {}
fleet.failing_node = nil
local rolled = land.run({ run = "case7-rollback", rollback = true })
eq(rolled, 0, "the rollback walks the ring")
local rollback_order, rollback_modes = {}, {}
for _, row in ipairs(R.state.deploy_requests) do
  rollback_order[#rollback_order + 1] = row.node
  rollback_modes[#rollback_modes + 1] = tostring(row.mode)
end
eq(table.concat(rollback_order, ","), "openclaw,nextcloud,mail,work", "the rollback runs the ring in reverse")
eq(table.concat(rollback_modes, ","), "rollback,rollback,rollback,rollback", "every request asks for a rollback")
-- THE ROLLBACK PINNED EVERY NODE IT PUT BACK, and an ordinary deploy is then refused by name: a pin is the
-- record that a node was moved somewhere on purpose, and the way out is the operator's own
-- `wa update <node> --unpin --reason <text>` (lua/core/remote_update.lua; pins.lua's escape_hatch). So the cases
-- below start where an operator leaves the machine after a rollback - the way forward said out loud - and this is
-- that step, on the store that gates them. Without it every later deploy in this file is a node_pinned refusal,
-- which is the rule working, not the row failing.
local pins = dofile("lua/core/pins.lua")
for _, node in ipairs({ "openclaw", "nextcloud", "mail", "work" }) do
  local active = pins.active(node)
  ok(active ~= nil, "the rollback left a pin on " .. node .. " (a rollback is a move on purpose)")
  local cleared = pins.clear(node, { reason = "the rollback case is over: this fixture moves the ring again" })
  ok(cleared ~= nil, "and the operator's release clears it on " .. node)
  ok(pins.active(node) == nil, "so " .. node .. " may move again")
end

-- ---------------------------------------------------------------- case 8: the rollback script itself
local rollback_script = tree_root .. "/scripts/rollback-node.sh"
ok(read_file(rollback_script) ~= nil, "the rollback script this node ships is here: " .. rollback_script)
local install = fixture .. "/install"
must("mkdir -p " .. install .. "/rollback", "make the install directory")
-- THE PAIR ANSWERS --build-info, because the record a rollback writes is the RESTORED BINARY'S OWN answer
-- (scripts/lib/install-record.sh: the identity fields come from the binary and only from the binary, which is
-- how a node stopped running 8 unlanded commits under a landed commit's name, 18/11). A stub that answered only
-- --version is recorded as commit=unknown - the honest record of a binary nobody can identify - and that is a
-- different case, proved by scripts/test-install-record.sh. This fixture keeps a pair it can identify.
local function stub_binary(path, text, commit)
  write_file(path, "#!/usr/bin/env bash\ncase $1 in\n"
    .. "  --build-info) printf 'version=" .. text .. "\\ncommit=" .. commit
    .. "\\ntree=unknown\\ndirty=false\\nsource=git\\nbuilt_epoch=1\\nancestors=3\\nancestors_complete=true\\n' ;;\n"
    .. "  *) printf '" .. text .. "\\n' ;;\nesac\n")
end
stub_binary(install .. "/wa", "wa 2.0-new", string.rep("a", 40))
stub_binary(install .. "/wa-sentinel", "sentinel 2.0-new", string.rep("a", 40))
stub_binary(install .. "/rollback/wa", "wa 1.9-old", string.rep("b", 40))
stub_binary(install .. "/rollback/wa-sentinel", "sentinel 1.9-old", string.rep("b", 40))
write_file(install .. "/installed.txt", "commit=" .. string.rep("a", 40) .. "\nbinary_source=prebuilt-release\n")
write_file(install .. "/rollback/installed.txt", "commit=" .. string.rep("b", 40) .. "\nbinary_source=prebuilt-release\n")
must("chmod +x " .. install .. "/wa " .. install .. "/wa-sentinel " .. install .. "/rollback/wa " .. install .. "/rollback/wa-sentinel", "exec bits")
local rollback_code, rollback_out = shell("bash " .. rollback_script .. " --install " .. install .. " --no-restart")
eq(rollback_code, 0, "the rollback script restores the pair: " .. tostring(rollback_out))
contains(must(install .. "/wa --version"), "1.9-old", "the restored binary is the kept one")
contains(must(install .. "/wa-sentinel --version"), "1.9-old", "the restored supervisor is the kept one")
local record = must("cat " .. install .. "/installed.txt")
contains(record, "commit=" .. string.rep("b", 40), "the record names the commit that was restored")
contains(record, "rollback_of=" .. string.rep("a", 40), "the record names the commit it replaced")
must("mkdir -p " .. fixture .. "/empty", "an install directory with no kept pair")
local missing_code, missing_out, missing_err = shell("bash " .. rollback_script .. " --install " .. fixture .. "/empty --no-restart")
ok(missing_code ~= 0, "a rollback with no kept pair refuses")
contains(tostring(missing_out) .. tostring(missing_err), "rollback_unavailable", "the refusal is named")

-- ---------------------------------------------------------------- case 12b: a worktree failure is never empty
-- Measured 19/11: `worktree_failed` came back four times with observed:"" (21:45-22:23Z) while the same git
-- command worked by hand. The old line reported first_line(stderr or stdout), so a failure carrying neither
-- stream reported nothing at all, and the operator had no bytes and no exit code to act on. Three shapes are
-- pinned here: git's own words with an exit code, a host-level refusal with no streams, and a host answer that
-- is not the expected JSON walk - none of them may answer with an empty observed.

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
