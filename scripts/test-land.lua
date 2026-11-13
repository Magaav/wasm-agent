-- `wa land` (lua/core/land.lua): the pipeline as a state machine, proved against a real repository and
-- scripted nodes.
--
-- What is REAL here: git (a fixture repository with two remotes - the incoming bare repository every node
-- can write, and the source of truth), the merged worktree, the pushes and their readback, the artifacts
-- reference the fixture publisher ships, the rollback script, the journal and the report on disk.
--
-- What is SCRIPTED, and only because it cannot be real in a test: the gate's checks (their commands are
-- pointed at marker scripts, so the same run can be made green, red, or red-then-green-under-load), the
-- nodes (a scripted peer call that answers `queued` and then `installed`/`failed`), `gh` (a route in the
-- runner: this machine has no token and no test may publish), and the weight probe (recorded, then turned
-- off so the rows run at a sane speed).
--
-- The cases are the ones the mission names: the happy path, a red gate, a check that fails under load and
-- passes alone, a resume after the deploy failed on node 3, and the rollback - plus the two conditional
-- channels (sign, reviewer) and the artifacts reference that must carry SHA256SUMS.
--
--   WA_SCRIPT=scripts/test-land.lua wa --db /tmp/wa-land.db
--
-- Prints `land ok (<n> checks)`; a failed check raises, so the gate reads a verdict and not a summary.
local json = dofile("lua/vendor/json.lua")
local land = dofile("lua/core/land.lua")
local real_host = host

local fixture = host.paths().home .. "/land-fixture"
local repo = fixture .. "/repo"
local incoming = fixture .. "/incoming.git"
local origin = fixture .. "/origin.git"
local journal_root = fixture .. "/journal"

local checks = 0
local function ok(condition, message)
  checks = checks + 1
  if not condition then error("check failed: " .. message, 0) end
end

local function flatten(value)
  if type(value) == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = tostring(item) end
    return table.concat(parts, " ")
  end
  return tostring(value)
end

local function eq(actual, expected, message)
  ok(actual == expected, message .. " (got " .. flatten(actual) .. ", want " .. tostring(expected) .. ")")
end

local function contains(haystack, needle, message)
  ok(tostring(haystack or ""):find(needle, 1, true) ~= nil,
    message .. " (looked for " .. tostring(needle) .. " in " .. tostring(haystack):sub(1, 400) .. ")")
end

local function shell(command, cwd)
  local raw = real_host.exec(command, cwd or "")
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return 1, tostring(raw), "" end
  return tonumber(decoded.code) or 1, tostring(decoded.stdout or ""), tostring(decoded.stderr or "")
end

local function must(command, why, cwd)
  local code, out, err = shell(command, cwd)
  if code ~= 0 then
    error("fixture: " .. why .. " failed (" .. tostring(code) .. "): " .. command .. "\n" .. out .. err, 0)
  end
  return (out:gsub("%s+$", ""))
end

-- ---------------------------------------------------------------- the fixture repository
--
-- One checkout with two remotes, exactly the shape a landing works in: `oc-in` is the incoming bare
-- repository (every node may write it), `origin` is the source of truth whose main only a credentialed
-- node may fast-forward. The scripts/binaries the fake publisher and signer need are committed into the
-- tree, so the landing runs them for real from its own merged worktree.

local ARTIFACTS_SCRIPT = [[
#!/usr/bin/env bash
# A stand-in for scripts/publish-artifacts-branch.sh: builds the artifacts orphan commit from a fake
# payload set and pushes it to the incoming repository, printing the same PUBLISHREADY line the real one
# prints. The one thing it can be made to do wrong is the 13/11 bug: name SHA256SUMS in PUBLISH.sh and not
# carry it (a marker file in the repository's git dir turns that on).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE=""; COMMIT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="$2"; shift 2 ;;
    --commit) COMMIT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$REMOTE" ] && [ -n "$COMMIT" ] || { echo "fake publisher: remote and commit required" >&2; exit 2; }
URL="$(git -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null || printf '%s' "$REMOTE")"
SHORT="${COMMIT:0:12}"
TAG="node-$SHORT"
MARKER="$(git -C "$ROOT" rev-parse --git-common-dir)/land-fixture-omit-sums"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cd "$STAGE"
printf 'fake wa binary for %s\n' "$COMMIT" > "wa-x86_64-unknown-linux-gnu-$SHORT"
printf 'fake sentinel for %s\n' "$COMMIT" > "wa-sentinel-x86_64-unknown-linux-gnu-$SHORT"
printf 'schema=wasm-agent-node-binaries/1\nsource_commit=%s\ncompiled_inputs=%s\n' "$COMMIT" "$SHORT" > "$TAG.manifest"
ASSETS="wa-x86_64-unknown-linux-gnu-$SHORT wa-sentinel-x86_64-unknown-linux-gnu-$SHORT $TAG.manifest"
if [ ! -f "$MARKER" ]; then
  for asset in $ASSETS; do sha256sum "$asset"; done > SHA256SUMS
fi
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "gh release create $TAG -R Magaav/wasm-agent --target $COMMIT --title $TAG --notes fake $ASSETS SHA256SUMS"
} > PUBLISH.sh
git init -q .
git config user.email fake@example.com
git config user.name Fake
git add -A
git commit -q -m "artifacts($TAG): fake payload set for $COMMIT"
# The ref is commit-addressed (`artifacts/node-<sha12>`) and holds an orphan commit, so a second publish of
# the same source REPLACES it - the real script's push is the same shape, and `-f` is what makes it possible.
git push -q -f "$URL" "HEAD:refs/heads/artifacts/$TAG"
printf 'PUBLISHREADY artifacts/%s %s source=%s\n' "$TAG" "$(git rev-parse HEAD)" "$COMMIT"
]]

local SIGN_SCRIPT = [[
#!/usr/bin/env bash
# A stand-in for scripts/publish-sign.sh: proves the step runs the signer with the artifacts commit and
# records that the release was signed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MARKER="$(git -C "$ROOT" rev-parse --git-common-dir)/land-fixture-signed.txt"
printf 'signed %s\n' "${1:-no-commit}" >> "$MARKER"
echo "fake signer: signed $1"
]]

local REVIEW_SCRIPT = [[
#!/usr/bin/env node
// A stand-in for scripts/review-branch.mjs: one finding, and a non-zero exit, so the landing has to prove
// that findings are recorded and never block it.
console.log(JSON.stringify({ schema: 1, findings: [{ severity: 'low', note: 'fake reviewer: a nit in the merged file' }] }));
process.exit(1);
]]

local function write_file(path, text)
  local ok_written, wrote = pcall(real_host.write_file, path, text)
  assert(ok_written and wrote == true, "fixture: cannot write " .. path)
end

local function setup_fixture()
  must("rm -rf " .. fixture, "clear the fixture")
  must("mkdir -p " .. fixture, "create the fixture directory")
  must("git init -q --bare -b main " .. incoming .. " && git init -q --bare -b main " .. origin ..
    " && git init -q -b main " .. repo .. " && cd " .. repo ..
    " && git config user.email land@example.com && git config user.name 'Land Fixture'" ..
    " && git config core.autocrlf false" ..
    " && git remote add oc-in " .. incoming .. " && git remote add origin " .. origin, "init the repositories and their remotes")
  write_file(repo .. "/a.txt", "base\n")
  write_file(repo .. "/scripts/publish-artifacts-branch.sh", ARTIFACTS_SCRIPT)
  must("chmod +x scripts/publish-artifacts-branch.sh", "exec bit", repo)
  must("git add -A && git commit -q -m base", "the base commit", repo)
  must("git push -q origin main && git push -q oc-in main", "publish the base", repo)

  local function branch(name)
    must("git checkout -q -B " .. name .. " main", "branch " .. name, repo)
  end
  branch("change/one"); write_file(repo .. "/one.txt", "one\n")
  must("git add -A && git commit -q -m one", "commit one", repo)
  branch("change/two"); write_file(repo .. "/two.txt", "two\n")
  must("git add -A && git commit -q -m two", "commit two", repo)
  branch("change/signed"); write_file(repo .. "/scripts/publish-sign.sh", SIGN_SCRIPT)
  must("chmod +x scripts/publish-sign.sh", "exec bit of the signer", repo)
  must("git add -A && git commit -q -m 'the signer arrives'", "commit the signer", repo)
  branch("change/reviewed"); write_file(repo .. "/scripts/review-branch.mjs", REVIEW_SCRIPT)
  must("git add -A && git commit -q -m 'the reviewer arrives'", "commit the reviewer", repo)
  branch("change/artifacts"); write_file(repo .. "/three.txt", "three\n")
  must("git add -A && git commit -q -m three", "commit three", repo)
  must("git checkout -q main", "back to main", repo)
  for _, name in ipairs({ "change/one", "change/two", "change/signed", "change/reviewed", "change/artifacts" }) do
    must("git push -q oc-in " .. name .. ":refs/heads/" .. name, "push " .. name, repo)
  end
  must("rm -rf " .. journal_root .. " && mkdir -p " .. journal_root, "clear the journal root")
end

-- The marker lives in the repository's common git directory, the one place both the main checkout and a
-- linked worktree name identically (`git rev-parse --git-common-dir` answers a relative path from the main
-- worktree, so it is made absolute here).
local function marker(name)
  local common = must("git -C " .. repo .. " rev-parse --git-common-dir")
  if common:sub(1, 1) ~= "/" then common = repo .. "/" .. common end
  return common .. "/" .. name
end

local function advance_main(tip)
  -- What the machine cannot do for itself in this fixture: the incoming repository's main, which the next
  -- landing starts from, moves forward with the landed tip.
  must("git -C " .. repo .. " push -q oc-in " .. tip .. ":refs/heads/main", "advance the incoming main")
end

-- ---------------------------------------------------------------- the runner's routes
--
-- The real runner for everything, with three routes on top: `gh` (no test may publish), the publish script
-- itself (it would call gh), and the counters that prove a done push is never repeated.
local real_exec = land.exec
local observed = { pushes = 0, main_pushes = 0, publish = 0, signed = 0, reviewer = 0 }
local behaviour = { publish_fails = false, release_present = false }

land.exec = function(command, cwd, timeout)
  if command:match("^command %-v gh") then return { code = 0, stdout = "yes\n", stderr = "" } end
  if command:match("^gh release view") then
    return { code = 0, stdout = (behaviour.release_present and "present\n" or "absent\n"), stderr = "" }
  end
  if command:match("^bash '.*PUBLISH%.sh'$") then
    observed.publish = observed.publish + 1
    if behaviour.publish_fails then
      return { code = 1, stdout = "", stderr = "publish_failed: fake gh refused (no token)\n" }
    end
    return { code = 0, stdout = "fake gh: release created\n", stderr = "" }
  end
  if command:find(" push 'oc%-in' ") or command:find(" push 'oc-in' ") then observed.pushes = observed.pushes + 1 end
  if command:find("push 'origin'") or command:find("fetch --quiet 'origin'") then
    if command:find(" push ") then observed.main_pushes = observed.main_pushes + 1 end
  end
  if command:find("publish%-sign%.sh") then observed.signed = observed.signed + 1 end
  if command:find("review%-branch%.mjs") then observed.reviewer = observed.reviewer + 1 end
  return real_exec(command, cwd, timeout)
end

-- ---------------------------------------------------------------- the scripted fleet
local deploy_requests = {}
local fleet = { failing_node = nil, recovered = false }

local function remote_call(selector, capability, args)
  args = type(args) == "table" and args or {}
  if args.action == "request" then
    local id = "rec-" .. tostring(#deploy_requests + 1)
    deploy_requests[#deploy_requests + 1] = { node = selector, id = id, mode = args.mode, commit = args.commit,
      rollback = args.rollback, reason = args.reason }
    return { ok = true, status = "queued", record = id, commit = args.commit,
             kind = args.rollback and "rollback" or (args.mode or "node"),
             target_node = { name = selector, node_id = "id-" .. selector } }
  end
  if args.action == "status" then
    local row = nil
    for _, candidate in ipairs(deploy_requests) do if candidate.id == args.id then row = candidate end end
    if not row then return { error = "unknown_remote_update", id = tostring(args.id) } end
    if fleet.failing_node == selector and not fleet.recovered then
      return { ok = true, state = "failed", record = args.id, commit = row.commit,
               detail = "fake: the sentinel refused (disk floor)" }
    end
    return { ok = true, state = "installed", verified = true, record = args.id, commit = row.commit,
             installed_commit = row.commit, detail = "installed.txt names it" }
  end
  return { error = "unknown_action", action = tostring(args.action) }
end

-- ---------------------------------------------------------------- the module's seams

land.root_dir = journal_root
land.repo_dir = repo
land.incoming_remote = "oc-in"
land.origin_remote = "origin"
land.remote_call = remote_call
land.weight_decorator = ""          -- exercised in its own check below; the rows run unweighted and fast
land.sleep = function() end         -- the deploy poll must not cost the suite five seconds a lap

local function journal_of(id)
  local text = real_host.read_file(land.journal_path(id))
  if not text then return nil end
  local decoded_ok, value = pcall(json.decode, text)
  return (decoded_ok and value) or nil
end

local function step_of(id, name)
  local journal = journal_of(id)
  return journal and journal.steps and journal.steps[name]
end

-- The gate's rows are marker scripts OUTSIDE the fixture directory: `setup_fixture` clears the fixture
-- between cases, and a check whose command vanished would fail with 127 rather than the verdict meant.
local gate_dir = host.paths().home .. "/land-gate"
must("mkdir -p " .. gate_dir, "create the gate directory")

local function gate_script(name)
  local path = gate_dir .. "/" .. name .. ".sh"
  write_file(path, string.format([[#!/usr/bin/env bash
# A gate row whose verdict is read from its own counter file: "pass", "fail", or "fail once then pass"
# (the flaky-under-load shape: red beside other work, green alone).
STATE="%s/%s.state"
MODE="$(cat "$STATE" 2>/dev/null || echo pass)"
case "$MODE" in
  pass) echo "fast: 12 rows ok"; exit 0 ;;
  fail) echo "FAIL fast: fake red check"; exit 1 ;;
  flaky)
    echo pass > "$STATE"
    echo "FAIL fast: fork failure under load (fake)"; exit 1 ;;
esac
exit 1
]], gate_dir, name))
  return path
end

local function set_gate(name, mode) write_file(gate_dir .. "/" .. name .. ".state", mode .. "\n") end

local gate_pass = gate_script("gate-pass")
set_gate("gate-pass", "pass")

-- The ring the machine deploys is proved once (case 1) and resumed once (case 5). Every other case is about
-- a STEP, so it walks a one-node ring: same code, four times fewer peers.
local SOLO_RING = { { node = "work", mode = "tree" } }

local function standard_checks(which)
  return { { name = "fast", command = "bash " .. tostring(which or gate_pass), timeout = 120 } }
end

-- ---------------------------------------------------------------- case 0: the weight probe
-- A landing runs its gate under the highest weight this machine will actually grant, and says which.
local decorator = land.weight()
ok(decorator == nil or type(decorator) == "string", "the weight probe answers a decorator or nothing")
ok(#land.WEIGHT_CANDIDATES >= 2, "there is more than one weight candidate to fall back through")
contains(land.WEIGHT_CANDIDATES[1].decorator, "CPUWeight", "the first candidate is a systemd CPU/IO weight")
land.weight_decorator = ""   -- the rest of the suite runs unweighted; the decorator is proved above

-- ---------------------------------------------------------------- case 1: the happy path

setup_fixture()
local happy = land.run({ run = "case1", branches = { "change/one", "change/two" }, checks = standard_checks() })
eq(happy, 0, "the happy path lands")
local journal = journal_of("case1")
ok(journal ~= nil, "the journal is written")
eq(journal.result, "done", "the run is recorded done")
local expected_state = { review = "skipped" }   -- the reviewer is not on main: a named skip, never a done
for _, name in ipairs(land.STEPS) do
  eq(step_of("case1", name) and step_of("case1", name).state, expected_state[name] or "done",
    "step " .. name .. " is " .. (expected_state[name] or "done"))
end
local tip = journal.tree_commit
ok(tostring(tip):match("^%x+$") ~= nil, "the journal names a landed tip")
contains(must("git -C " .. repo .. " ls-remote oc-in refs/heads/" .. journal.land_branch), tip,
  "the landed tip is on the incoming repository")
contains(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), tip, "main was fast-forwarded to it")
contains(must("git -C " .. repo .. " ls-tree -r --name-only oc-in/artifacts/node-" .. tip:sub(1, 12) .. " 2>/dev/null || git -C " .. repo .. " fetch -q oc-in refs/heads/artifacts/node-" .. tip:sub(1, 12) .. " && git -C " .. repo .. " ls-tree -r --name-only FETCH_HEAD"),
  "SHA256SUMS", "the artifacts reference carries SHA256SUMS")
eq(journal.artifacts and journal.artifacts.commit, tip, "the artifacts commit names the landed source")
eq(observed.pushes, 1, "exactly one push to the incoming repository")
eq(observed.main_pushes, 1, "exactly one push to main")
eq(observed.publish, 1, "exactly one publish")
eq(journal.publish and journal.publish.state, "published", "the release is recorded published")
eq(journal.publish and journal.publish.signed, false, "an unsigned release says so")
local nodes = {}
for _, row in ipairs(journal.deploy) do nodes[#nodes + 1] = row.node .. ":" .. row.mode end
eq(table.concat(nodes, ","), "work:tree,mail:tree,nextcloud:binary,openclaw:tree",
  "the ring deploys in order, with openclaw last and nextcloud binary-only")
for _, row in ipairs(journal.deploy) do eq(row.state, "installed", "node " .. row.node .. " is installed") end
local todo_items = {}
for _, todo in ipairs(journal.todos or {}) do todo_items[#todo_items + 1] = todo.item end
eq(table.concat(todo_items, ","), "reviewer,sign", "the two absent channels are recorded as TODOs")
local report = real_host.read_file(land.report_path("case1")) or ""
contains(report, "# wa land case1", "the report is written to a file")
contains(report, "nextcloud", "the report carries the per-node results")
contains(report, "TODO", "the report carries the TODOs")
advance_main(tip)

-- ---------------------------------------------------------------- case 2: a red gate stops the landing

local red = gate_script("gate-red")
set_gate("gate-red", "fail")
observed.pushes = 0
local red_code = land.run({ run = "case2", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks(red) })
eq(red_code, 1, "a red gate stops the landing")
eq(journal_of("case2").result, "stopped", "the run is recorded stopped")
eq(journal_of("case2").stopped_at, "gate", "it stopped at the gate")
eq(step_of("case2", "gate").state, "failed", "the gate step is failed")
contains(step_of("case2", "gate").detail, "failed twice", "the failure names both runs")
ok(real_host.read_file(step_of("case2", "gate").evidence) ~= nil, "the gate's evidence file exists")
local push_step = step_of("case2", "push")
ok(push_step == nil or push_step.state == "pending", "nothing was pushed")
eq(observed.pushes, 0, "no push happened")

-- ---------------------------------------------------------------- case 3: flaky under load

local flaky = gate_script("gate-flaky")
set_gate("gate-flaky", "flaky")
observed.pushes = 0
local flaky_code = land.run({ run = "case3", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks(flaky) })
eq(flaky_code, 1, "a flaky check stops the landing")
local flaky_step = step_of("case3", "gate")
eq(flaky_step.state, "flaky", "the gate step is recorded flaky, not done")
contains(flaky_step.detail, "flaky under load: fast", "the detail says flaky under load, by name")
eq(journal_of("case3").result, "stopped", "the run is stopped, never silently green")
eq(observed.pushes, 0, "a flaky gate pushes nothing")
local flaky_push = step_of("case3", "push")
ok(flaky_push == nil or flaky_push.state == "pending", "the push step never ran")

-- ---------------------------------------------------------------- case 4: a check that proves nothing

write_file(gate_dir .. "/gate-vacuous.sh", "#!/usr/bin/env bash\nexit 0\n")
local vacuous = land.run({ run = "case4", ring = SOLO_RING, branches = { "change/one" },
  checks = { { name = "cargo-codemode", command = "bash " .. gate_dir .. "/gate-vacuous.sh", min_tests = 1 } } })
eq(vacuous, 1, "a check that proves nothing is not green")
eq(step_of("case4", "gate").error, "gate_vacuous", "the refusal is named")
contains(step_of("case4", "gate").detail, "proved nothing", "the detail says the run proved nothing")

-- ---------------------------------------------------------------- case 5: resume after the deploy failed on node 3

setup_fixture()
deploy_requests = {}
fleet.failing_node = "nextcloud"
fleet.recovered = false
observed.pushes = 0
observed.main_pushes = 0
observed.publish = 0
local deploy_code = land.run({ run = "case5", branches = { "change/one", "change/two" }, checks = standard_checks() })
eq(deploy_code, 1, "a node that fails stops the landing at the deploy")
local first = journal_of("case5")
eq(first.stopped_at, "deploy", "it stopped at the deploy")
contains(first.stop_detail, "nextcloud", "the stop names the node")
contains(first.stop_detail, "binary", "the stop names the mode the node needs")
local pushed_once = observed.pushes
eq(pushed_once, 1, "the tip was pushed once")
eq(observed.publish, 1, "the release was published once")
local landed = first.tree_commit
local before = #deploy_requests
ok(before >= 3, "the ring reached the third node before it stopped")

fleet.recovered = true
local resumed = land.run({ run = "case5", resume = true, checks = standard_checks() })
eq(resumed, 0, "the resume finishes the run")
local second = journal_of("case5")
eq(second.result, "done", "the run is done after the resume")
eq(observed.pushes, pushed_once, "the resume did NOT push again")
eq(observed.main_pushes, 1, "the resume did NOT fast-forward main again")
eq(observed.publish, 1, "the resume did NOT publish again")
eq(#deploy_requests, before + 2, "the resume asked only the failed node and the one after it")
eq(deploy_requests[#deploy_requests - 1].node, "nextcloud", "the resume starts at node 3")
eq(deploy_requests[#deploy_requests].node, "openclaw", "and finishes with openclaw")
local states = {}
for _, row in ipairs(second.deploy) do states[#states + 1] = row.node .. ":" .. row.state end
contains(table.concat(states, ","), "nextcloud:failed", "the failed attempt stays in the record")
contains(table.concat(states, ","), "nextcloud:installed", "and the settled one is recorded beside it")
advance_main(landed)

-- ---------------------------------------------------------------- case 6: the rollback, reverse order

deploy_requests = {}
fleet.failing_node = nil
local rolled = land.run({ run = "case6-rollback", rollback = true })
eq(rolled, 0, "the rollback walks the ring")
local rollback_order, rollback_modes = {}, {}
for _, row in ipairs(deploy_requests) do
  rollback_order[#rollback_order + 1] = row.node
  rollback_modes[#rollback_modes + 1] = tostring(row.mode)
end
eq(table.concat(rollback_order, ","), "openclaw,nextcloud,mail,work", "the rollback runs the ring in reverse")
eq(table.concat(rollback_modes, ","), "rollback,rollback,rollback,rollback", "every request asks for a rollback")

-- ---------------------------------------------------------------- case 7: the rollback script itself
--
-- Real files, a real swap: the pair an install keeps in <install>/rollback/ is put back, the record is
-- rewritten with what was undone, and --no-restart leaves the supervisor alone.

local tree_root = (host.getenv("WASM_AGENT_LUA_ROOT") or ""):gsub("%s+$", "")
if tree_root == "" then tree_root = "." end
local rollback_script = tree_root .. "/scripts/rollback-node.sh"
ok(real_host.read_file(rollback_script) ~= nil, "the rollback script this node ships is here: " .. rollback_script)
local install = fixture .. "/install"
must("mkdir -p " .. install .. "/rollback", "make the install directory")
write_file(install .. "/wa", "#!/usr/bin/env bash\nprintf 'wa 2.0-new\\n'\n")
write_file(install .. "/wa-sentinel", "#!/usr/bin/env bash\nprintf 'sentinel 2.0-new\\n'\n")
write_file(install .. "/rollback/wa", "#!/usr/bin/env bash\nprintf 'wa 1.9-old\\n'\n")
write_file(install .. "/rollback/wa-sentinel", "#!/usr/bin/env bash\nprintf 'sentinel 1.9-old\\n'\n")
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
local absent_code, absent_out, absent_err = shell("bash " .. rollback_script .. " --install " .. fixture .. "/nope --no-restart")
ok(absent_code ~= 0, "a rollback against a directory that is not an install refuses")
contains(tostring(absent_out) .. tostring(absent_err), "install_missing", "the refusal names the missing install")

-- ---------------------------------------------------------------- case 8: the signing channel
--
-- Reuses the fixture case 5 landed on, which is the state a real signing channel arrives in later: main is
-- where it was, the branch brings the signer.

local signed_code = land.run({ run = "case8", ring = SOLO_RING, branches = { "change/signed" }, checks = standard_checks() })
eq(signed_code, 0, "a tree that carries the signer still lands")
local signed_journal = journal_of("case8")
eq(signed_journal.publish and signed_journal.publish.signed, true, "the release is recorded signed")
ok(observed.signed > 0, "the signer was run")
ok(real_host.read_file(marker("land-fixture-signed.txt")) ~= nil, "the signer saw the artifacts commit")
local sign_todos = 0
for _, todo in ipairs(signed_journal.todos or {}) do if todo.item == "sign" then sign_todos = sign_todos + 1 end end
eq(sign_todos, 0, "a signed release records no signing TODO")
advance_main(signed_journal.tree_commit)

-- ---------------------------------------------------------------- case 9: the reviewer, never blocking

setup_fixture()
-- The reviewer is a channel that must already be ON MAIN: it reviews a branch BEFORE that branch is merged,
-- so a reviewer that arrived with the branch could never have looked at it.
must("git checkout -q main", "back to main", repo)
write_file(repo .. "/scripts/review-branch.mjs", REVIEW_SCRIPT)
must("git add -A && git commit -q -m 'the reviewer arrives on main'", "commit the reviewer on main", repo)
must("git push -q origin main && git push -q oc-in main", "publish the reviewer on main", repo)
local reviewed_code = land.run({ run = "case9", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(reviewed_code, 0, "a reviewer's findings do not block a landing")
local reviewed = journal_of("case9")
ok(reviewed.review and #reviewed.review == 1, "the reviewer ran once, on the branch")
eq(reviewed.review[1].exit_code, 1, "its non-zero exit is recorded as a fact")
contains(reviewed.review[1].findings, "fake reviewer", "its findings are recorded")
contains(real_host.read_file(land.report_path("case9")) or "", "review", "the report carries the review step")
ok(observed.reviewer > 0, "the reviewer script was actually executed")
advance_main(reviewed.tree_commit)

-- ---------------------------------------------------------------- case 10: artifacts that name a file they do not carry

write_file(marker("land-fixture-omit-sums"), "omit\n")
local broken_code = land.run({ run = "case10", ring = SOLO_RING, branches = { "change/artifacts" }, checks = standard_checks() })
eq(broken_code, 1, "an incomplete artifacts reference stops the landing")
local broken = step_of("case10", "artifacts")
eq(broken.state, "failed", "the artifacts step failed")
eq(broken.error, "artifacts_incomplete", "the refusal is named")
contains(broken.observed, "SHA256SUMS", "the refusal names the file the reference does not carry")
must("rm -f " .. marker("land-fixture-omit-sums"), "clear the marker")

-- ---------------------------------------------------------------- case 11: the ready box

must("rm -f " .. land.ready_file(), "an empty ready box")
local tip_one = must("git -C " .. repo .. " rev-parse change/one")
eq(land.cli({ "land", "ready", "change/one", tip_one }), 0, "a READY line is recorded")
contains(real_host.read_file(land.ready_file()) or "", "READY change/one " .. tip_one, "the box holds the line")
local ready_code = land.run({ run = "case11", ring = SOLO_RING, ready = true, no_deploy = true, checks = standard_checks() })
eq(ready_code, 0, "the ready box is enough to land")
local ready_journal = journal_of("case11")
eq(#ready_journal.branches, 1, "one branch was collected from the box")
eq(ready_journal.branches[1].name, "change/one", "the branch named in the line")
eq(step_of("case11", "deploy").state, "skipped", "--no-deploy skips the deploy, by name")
contains(step_of("case11", "deploy").detail, "--no-deploy", "the skip says why")
advance_main(ready_journal.tree_commit)

-- A recorded sha that no longer matches the branch is a refusal, not a silent upgrade.
must("rm -f " .. land.ready_file(), "an empty ready box")
local stale = string.rep("0", 40)
land.ready_mark("change/one", stale)
local moved_code = land.run({ run = "case12", ring = SOLO_RING, ready = true, no_deploy = true, checks = standard_checks() })
eq(moved_code, 1, "a moved branch is refused")
eq(step_of("case12", "collect").error, "ready_sha_moved", "the refusal is named")
contains(step_of("case12", "collect").next, "moved", "the refusal says what to do")

-- ---------------------------------------------------------------- case 13: publish without a credential

local saved_route = land.exec
land.exec = function(command, cwd, timeout)
  if command:match("^command %-v gh") then return { code = 0, stdout = "no\n", stderr = "" } end
  return saved_route(command, cwd, timeout)
end
local no_gh = land.run({ run = "case13", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(no_gh, 1, "a machine without gh stops at the publish")
local publish_step = step_of("case13", "publish")
eq(publish_step.error, "publish_needs_credentials", "the stop is named")
contains(publish_step.next, "PUBLISH.sh", "the stop names the exact command that publishes elsewhere")
eq(observed.pushes > 0 and step_of("case13", "push").state, "done", "the landed tip was still pushed")
land.exec = saved_route

-- ---------------------------------------------------------------- case 14: the CLI

eq(land.cli({ "chat" }), nil, "not a land request: the dispatcher keeps its own path")
eq(land.cli({ "land", "--help" }), 0, "the help is free")
eq(land.cli({ "land" }), 2, "no arguments is a usage answer")
eq(land.cli({ "land", "--branches" }), 2, "a flag without a value is refused")

-- The dry run changes nothing: no journal, no worktree, no push.
local function journal_count()
  local out = must("ls -1 " .. journal_root .. " 2>/dev/null | wc -l")
  return tonumber((out:gsub("%s+", ""))) or 0
end
local before_journals = journal_count()
local before_branches = must("git -C " .. repo .. " branch --list 'land*' | wc -l")
local dry_pushes = observed.pushes
eq(land.cli({ "land", "--branches", "change/one", "--dry-run" }), 0, "the dry run answers zero")
eq(observed.pushes, dry_pushes, "the dry run pushed nothing")
eq(journal_count(), before_journals, "the dry run wrote no journal")
eq(must("git -C " .. repo .. " branch --list 'land*' | wc -l"), before_branches, "the dry run created no land branch")

print(string.format("land ok (%d checks)", checks))
