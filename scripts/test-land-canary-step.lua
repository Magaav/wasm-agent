-- The release loop's canary step (lua/core/land.lua, impl.canaries): after the fleet read-back, a node
-- that fails its own canary makes the release RED BY NAME - and the step is in the loop, not beside it.
--
-- Everything runs against fixture canaries in this test's own home: no node is deployed, no ring is
-- asked, no release is cut.
--
--   WA_SCRIPT=scripts/test-land-canary-step.lua wa ...   prints "land-canary-step ok (N checks)"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local feature_health = dofile("lua/core/feature_health.lua")
local land = dofile("lua/core/land.lua")

local checks = 0
local function check(value, what)
  checks = checks + 1
  if not value then error(what, 2) end
end
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s\n  got:  %s\n  want: %s", what, tostring(got), tostring(want)), 2)
  end
end
local function contains(text, needle, what)
  checks = checks + 1
  if not tostring(text or ""):find(needle, 1, true) then
    error(what .. ": expected to find " .. tostring(needle) .. " in: " .. tostring(text), 2)
  end
end

-- 1. THE STEP IS IN THE RELEASE LOOP, immediately after the deploy whose read-back it follows.
local position
for index, name in ipairs(land.STEPS or {}) do if name == "canaries" then position = index end end
check(position ~= nil, "the release loop has a canaries step")
eq(land.STEPS[position - 1], "deploy", "it runs right after the deploy read-back")
eq(land.STEPS[position + 1], "linux", "and before the public channel")
local plan = land.plan_steps("docs-only")
check(plan.canaries and plan.canaries.action == "skip", "a docs-only round skips it, saying nothing was installed")
contains(plan.canaries.why, "nothing was installed", "and says why")
local lua_plan = land.plan_steps("lua-scripts-only")
check(lua_plan.canaries and lua_plan.canaries.action == "run", "a Lua round runs it")
contains(lua_plan.canaries.why, "canary", "and says what it asks the node")

-- 2. A FAILING CANARY STOPS THE RUN BY NAME, with the stage and the evidence file.
local canary_dir = test_home .. "/canaries"
check(host.exec("mkdir -p '" .. canary_dir .. "'", "") ~= nil, "the fixture canary directory exists")
check(host.write_file(canary_dir .. "/passes.lua", "return { mode = 'read', run = function() return true, 'done', 'read-only' end }\n"),
  "the passing canary is written")
check(host.write_file(canary_dir .. "/tasks-broken.lua", table.concat({
  "local runner = dofile('lua/core/feature_canary.lua')",
  "local M = { mode = 'loopback' }",
  "function M.run(ctx) return false, 'post', 'the component posted nothing' end",
  "return M",
}, "\n")), "the failing canary is written")

local good = { schema = 1, features = {
  { name = "passing", role = "any", canary = "passes", last_success = "fixture: nothing", stale_after_s = 600 },
} }
local bad = { schema = 1, features = {
  { name = "passing", role = "any", canary = "passes", last_success = "fixture: nothing", stale_after_s = 600 },
  { name = "whatsapp-copilot-reply", role = "any", canary = "tasks-broken", last_success = "fixture: nothing", stale_after_s = 600 },
} }

local run = { id = "canary-step-test", journal = { main_sha = "0123456789abcdef0123456789abcdef01234567" } }
check(host.write_file(feature_health.installed_registry_path(), json.encode(bad)), "the failing registry is written")
local ok, answer = land.impl.canaries(run, { canary_dir = canary_dir, ring = {} })
eq(ok, false, "a failed canary makes the step red")
eq(answer.error, "canary_failed", "and names the reason")
contains(answer.detail, "whatsapp-copilot-reply (post)", "the red names the feature and the stage")
contains(answer.next, "whatsapp-copilot-reply", "with no ring, the next line names the feature to fix")
contains(answer.next, "before cutting again", "and says the cut does not go on")
check(answer.next:find("0123456789abcdef0123456789abcdef01234567", 1, true) == nil,
  "and NEVER the commit this run shipped (the one that failed)")
local evidence = host.read_file(land.evidence_path(run.id, "canaries")) or ""
contains(evidence, "FAIL", "the evidence file keeps the failing row")
contains(evidence, "whatsapp-copilot-reply", "with the feature's name")
contains(evidence, "the component posted nothing", "and the canary's own words")

-- 2b. THE FLEET (review item 1): every node the ring deployed to is ASKED, its answer is collected, and an
--     unreachable node is NOT PROVEN - red, by name, never green. The peer call is stubbed here
--     (`options.remote_call`), so no live node is ever reached.
check(host.write_file(feature_health.installed_registry_path(), json.encode(good)), "the passing registry is written")
local ring = { { node = "scratch-a", mode = "tree" }, { node = "scratch-b", mode = "tree" } }
local asked = {}
local function remote(answer_for)
  return function(node, capability, args)
    asked[#asked + 1] = node .. ":" .. capability .. ":" .. tostring(args.command)
    return answer_for(node)
  end
end
local passing_answer = json.encode({ ok = true, failed = 0, features = {
  { feature = "chat", ok = true, stage = "answered" },
  { feature = "whatsapp-copilot-reply", ok = false, off = true, stage = "off (posting disabled)" },
} })
local ok_fleet, fleet = land.impl.canaries(run, { canary_dir = canary_dir, ring = ring,
  remote_call = remote(function() return { output = passing_answer } end) })
check(ok_fleet == true, "a ring whose nodes all answer their canaries lets the release continue: " .. json.encode(fleet))
check(#asked == 2, "both ring nodes were asked, not just this one: " .. #asked)
contains(asked[1], "scratch-a:bash:wa features canary json", "each node is asked to run its own canaries")
contains(asked[2], "scratch-b:bash:wa features canary json", "and so is the second one")
eq(fleet.nodes_answered, 2, "and both answers were collected")
contains(fleet.observed, "off (posting disabled)", "an off feature is reported by name, not as a failure")
local fleet_evidence = host.read_file(land.evidence_path(run.id, "canaries")) or ""
contains(fleet_evidence, "## scratch-a", "the evidence keeps the node's own section")
contains(fleet_evidence, "whatsapp-copilot-reply", "and its rows")

-- 2c. AN UNREACHABLE NODE IS NOT PROVEN: red, with the node named.
local ok_unproven, unproven = land.impl.canaries(run, { canary_dir = canary_dir, ring = { { node = "scratch-a", mode = "tree" } },
  remote_call = function() return { error = "relay_timeout", detail = "the relay did not answer" } end })
eq(ok_unproven, false, "a node that cannot be asked is not green")
eq(unproven.error, "canary_unproven", "and it is named as unproven, not as a canary failure")
contains(unproven.detail, "scratch-a", "the node is named")
contains(unproven.observed, "relay_timeout", "with the peer's own reason")

-- 2d. A PEER'S CANARY FAILS: red by name, with the NODE and the stage.
local peer_failure = json.encode({ ok = false, failed = 1, features = {
  { feature = "whatsapp-transcription", ok = false, stage = "no_transcript", detail = "3 voice note(s), none carrying a transcript" },
} })
local ok_peer_failed, peer_failed = land.impl.canaries(run, { canary_dir = canary_dir, ring = { { node = "scratch-b", mode = "tree" } },
  remote_call = function() return { output = peer_failure } end })
eq(ok_peer_failed, false, "a peer's failing canary stops the release")
eq(peer_failed.error, "canary_failed", "as a canary failure")
contains(peer_failed.detail, "scratch-b whatsapp-transcription (no_transcript)", "naming the node, the feature and the stage")

-- 2e. THE ROLLBACK LINE NAMES THE PREVIOUS RELEASE, per node (review item 2) - never the commit that just
--     failed. The previous journal is a fixture written under this test's own run root.
local previous_commit = "1111111111111111111111111111111111111111"
local previous_dir = land.run_dir("fixture-previous-release")
host.exec("mkdir -p '" .. previous_dir .. "'", "")
check(host.write_file(previous_dir .. "/journal.json", json.encode({ run = "fixture-previous-release", result = "done",
  tree_commit = previous_commit, publish = { tag = "v0.2.9" } })), "the previous release's journal is written")
local ok_rollback, rollback = land.impl.canaries(run, { canary_dir = canary_dir, ring = { { node = "scratch-b", mode = "tree" } },
  remote_call = function() return { output = peer_failure } end })
eq(ok_rollback, false, "the same failure is still red")
contains(rollback.next, "scratch-b: wa update scratch-b --commit " .. previous_commit, "the rollback names the previous release's commit for that node")
contains(rollback.next, "back to v0.2.9", "and the tag it was published as")
local not_this_run = rollback.next:find("0123456789abcdef0123456789abcdef01234567", 1, true) == nil
check(not_this_run, "the rollback does NOT name the commit this run shipped")

-- 3. ALL GREEN: the step passes and says what it asked.
check(host.write_file(feature_health.installed_registry_path(), json.encode(good)), "the passing registry is written")
local ok2, answer2 = land.impl.canaries(run, { canary_dir = canary_dir, ring = {} })
eq(ok2, true, "a node whose canaries pass lets the release continue: " .. json.encode(answer2))
eq(answer2.canaries, 1, "it says how many canaries ran")
contains(answer2.observed, "canary(ies) ran on this node and 0 peer node(s) ran their own", "and says what it asked")
eq(answer2.nodes_asked, 0, "with an explicit empty ring no peer is asked")

-- 4. A REGISTRY THAT CANNOT BE READ IS A REFUSAL, not a green step.
check(host.write_file(feature_health.installed_registry_path(), "{ not json"), "the registry is corrupted on purpose")
local ok3, answer3 = land.impl.canaries(run, { canary_dir = canary_dir, ring = {} })
eq(ok3, false, "an unreadable registry stops the step")
eq(answer3.error, "canaries_unreadable", "by name")

print(string.format("land-canary-step ok (%d checks)", checks))
