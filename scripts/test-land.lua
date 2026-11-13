-- `wa land` (lua/core/land.lua): the pipeline as a state machine, proved against a real repository, a real
-- wa-vault and scripted nodes.
--
-- What is REAL here: git (a fixture repository with two remotes - the incoming bare repository every node
-- can write, and the source of truth), the merged worktree, the pushes and their readback, the release set
-- the fixture publisher writes, the ed25519 signature made by a SCRATCH wa-vault through the admin API
-- (`scripts/lib/test-release-vault.sh`, its own data directory and ports, never the operator's vault), its
-- verification against the trusted keys of the tree, the artifacts reference, the rollback script, the
-- journal and the report on disk.
--
-- What is SCRIPTED, and only because it cannot be real in a test: the gate's checks (their commands point at
-- marker scripts, so one run can be green, red, or red-then-green-under-load), the release BUILD (`cargo`
-- and `zig` for two triples is not a test's business: the fixture publisher writes a fake payload set with
-- the real manifest/checksum shape), `gh` (a route in the runner: this machine has no token and no test may
-- publish), the nodes (a scripted peer call that answers `queued`/`installed`/`failed`, and - for the
-- signing hand-back - runs the command it was given, which is exactly what a signer node does), and the
-- weight probe (exercised once, then turned off so the rows run at a sane speed).
--
-- The cases are the ones the mission names - the happy path, a red gate, a check that fails under load and
-- passes alone, a resume after the deploy failed on node 3, the rollback - plus the release signature: made
-- locally, made on a named node and handed back, refused without a signer, refused when the key is not
-- trusted, and never shipped or published unsigned; and the reviewer channel, the ready box and the CLI.
--
--   WA_SCRIPT=scripts/test-land.lua wa --db /tmp/wa-land.db
--
-- Prints `land ok (<n> checks)`; a failed check raises, so the gate reads a verdict and not a summary.
local json = dofile("lua/vendor/json.lua")
local land = dofile("lua/core/land.lua")
local real_host = host

local tree_root = (host.getenv("WASM_AGENT_LUA_ROOT") or ""):gsub("%s+$", "")
if tree_root == "" then tree_root = "." end

local fixture = host.paths().home .. "/land-fixture"
local repo = fixture .. "/repo"
local incoming = fixture .. "/incoming.git"
local origin = fixture .. "/origin.git"
local journal_root = fixture .. "/journal"
local vault = host.paths().home .. "/land-vault"

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

local function write_file(path, text)
  local ok_written, wrote = pcall(real_host.write_file, path, text)
  assert(ok_written and wrote == true, "fixture: cannot write " .. path)
end

local function read_file(path) return real_host.read_file(path) end

-- ---------------------------------------------------------------- a scratch wa-vault
--
-- The release signature comes from wa-vault's `release-signing` key, and the vault's ADMIN listener answers
-- only where the vault runs - so a test that wants a real signature needs a real vault. This one has its own
-- data directory and ports, makes its own key through the admin API, and is stopped again at the end of the
-- row. When python3 or curl is missing the signing cases are SKIPPED BY NAME and the rest of the machine is
-- still proved (a test that cannot sign cannot tell a refusal from a bug).

local VAULT_AVAILABLE = true
local vault_env = ""

local function start_vault()
  local probe = "command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && echo yes || echo no"
  local _, out = shell(probe)
  if (out or ""):gsub("%s", "") ~= "yes" then VAULT_AVAILABLE = false end
  if not VAULT_AVAILABLE then return false end
  must("rm -rf " .. vault .. " && mkdir -p " .. vault, "clear the scratch vault directory")
  write_file(vault .. "/start.sh", string.format([[#!/usr/bin/env bash
# Start a scratch wa-vault, keep its key id/token/ports in files, and leave the vault running: the row needs
# it across several commands, and a vault per command would make a new key per command.
set -uo pipefail
. %q || exit 7
test_release_vault_start || exit 7
printf '%%s\n' "$WA_VAULT_ADMIN_URL" > %q
printf '%%s\n' "$WA_VAULT_ADMIN_TOKEN" > %q
printf '%%s\n' "$TEST_RELEASE_VAULT_KEYS" > %q
printf '%%s\n' "$TEST_RELEASE_VAULT_KEY_ID" > %q
printf '%%s\n' "$TEST_RELEASE_VAULT_PID" > %q
cp -f "$TEST_RELEASE_VAULT_KEYS" %q
printf 'scratch vault up: %%s (key %%s, pid %%s)\n' "$WA_VAULT_ADMIN_URL" "$TEST_RELEASE_VAULT_KEY_ID" "$TEST_RELEASE_VAULT_PID"
disown 2>/dev/null || true
]], tree_root .. "/scripts/lib/test-release-vault.sh", vault .. "/url", vault .. "/token", vault .. "/keys",
    vault .. "/key_id", vault .. "/pid", vault .. "/trusted-keys.txt"))
  local code, out, err = shell("setsid bash " .. vault .. "/start.sh")
  if code ~= 0 then
    VAULT_AVAILABLE = false
    print("SKIP test-land: the scratch wa-vault did not start, so the release signature was not exercised: " ..
      tostring(err ~= "" and err or out))
    return false
  end
  -- A signing NODE has the signer beside its binary, which is where `wa update <node> --binary` puts it
  -- (scripts/deploy.sh). The simulated node here is this machine's install directory, with the real signer,
  -- library and verifier in it, so the remote path resolves the command the way a deployed node does.
  local install = host.paths().home .. "/.local/bin"
  must("mkdir -p " .. install .. "/scripts/lib", "create the simulated install")
  for _, relative in ipairs({ "scripts/sign-release.sh", "scripts/lib/release-signing.sh", "scripts/lib/release_verify.py" }) do
    must("cp -f " .. tree_root .. "/" .. relative .. " " .. install .. "/" .. relative, "install " .. relative)
  end
  local url = (read_file(vault .. "/url") or ""):gsub("%s+$", "")
  local token = (read_file(vault .. "/token") or ""):gsub("%s+$", "")
  -- `export ...;` rather than an assignment prefix: a prefix only works in front of a SIMPLE command, and the
  -- step commands are loops and pipelines (`for n in ...; do ...`), where `VAR=x for ...` is a syntax error.
  vault_env = string.format("export WA_VAULT_ADMIN_URL=%q WA_VAULT_ADMIN_TOKEN=%q; ", url, token)
  return true
end

local function stop_vault()
  local pid = (read_file(vault .. "/pid") or ""):gsub("%s+$", "")
  if pid ~= "" then shell("kill " .. pid .. " 2>/dev/null || true") end
end

-- ---------------------------------------------------------------- the fixture repository
--
-- One checkout with two remotes, exactly the shape a landing works in: `oc-in` is the incoming bare
-- repository (every node may write it), `origin` is the source of truth whose main only a credentialed node
-- may fast-forward. The publisher and shipper stand-ins are committed into the tree, so the landing runs
-- them from its own merged worktree - and the signer `scripts/sign-release.sh`, the signing library and the
-- verifier are the REAL ones, copied in.

local PUBLISHER_SCRIPT = [[
#!/usr/bin/env bash
# A stand-in for scripts/publish-node-binaries.sh: a fake payload set with the REAL contract around it - a
# manifest that pins this commit, SHA256SUMS over the payloads, the signature deferred (`WA_RELEASE_SIGN_DEFER`)
# or made here, and a refusal to publish an unsigned set. No cargo, no zig, no network.
set -uo pipefail
COMMIT=""; OUT=""; FROM=""; TARGETS=""; PUBLISH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --target) TARGETS="$TARGETS $2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) shift ;;
  esac
done
[ -n "$COMMIT" ] && [ -n "$OUT" ] || { echo "publisher: commit and out required" >&2; exit 2; }
SHORT="${COMMIT:0:12}"
TRIPLE="${TARGETS:-x86_64-unknown-linux-gnu}"; TRIPLE="${TRIPLE# }"; TRIPLE="${TRIPLE%% *}"
mkdir -p "$OUT" || exit 2
if [ -n "$FROM" ]; then
  cp -f "$FROM/node-$SHORT.manifest" "$OUT/node-$SHORT.manifest" || exit 2
  for f in "$FROM"/wa-"$TRIPLE"-"$SHORT" "$FROM"/wa-sentinel-"$TRIPLE"-"$SHORT"; do
    [ -f "$f" ] || continue; cp -f "$f" "$OUT/"
  done
fi
[ -f "$OUT/wa-$TRIPLE-$SHORT" ] || printf 'fake wa %s\n' "$COMMIT" > "$OUT/wa-$TRIPLE-$SHORT"
[ -f "$OUT/wa-sentinel-$TRIPLE-$SHORT" ] || printf 'fake sentinel %s\n' "$COMMIT" > "$OUT/wa-sentinel-$TRIPLE-$SHORT"
if [ ! -f "$OUT/node-$SHORT.manifest" ]; then
  {
    printf 'schema=wasm-agent-node-binaries/1\nsource_commit=%s\ncompiled_inputs=%s\ncodemode=embedded\n' "$COMMIT" "$SHORT"
    echo '# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes'
    printf '%s %s %s %s %s\n' "$TRIPLE" \
      "$(sha256sum < "$OUT/wa-$TRIPLE-$SHORT" | awk '{print $1}')" "$(wc -c < "$OUT/wa-$TRIPLE-$SHORT" | tr -d ' ')" \
      "$(sha256sum < "$OUT/wa-sentinel-$TRIPLE-$SHORT" | awk '{print $1}')" "$(wc -c < "$OUT/wa-sentinel-$TRIPLE-$SHORT" | tr -d ' ')"
  } > "$OUT/node-$SHORT.manifest"
fi
( cd "$OUT" && for a in "wa-$TRIPLE-$SHORT" "wa-sentinel-$TRIPLE-$SHORT" "node-$SHORT.manifest"; do sha256sum "$a"; done ) \
  > "$OUT/.SHA256SUMS.$$" && mv -f "$OUT/.SHA256SUMS.$$" "$OUT/SHA256SUMS" || exit 2
SIG="$OUT/SHA256SUMS.sig"
if [ "${WA_RELEASE_SIGN_DEFER:-0}" = 1 ]; then
  if [ -f "$SIG" ]; then
    . scripts/lib/release-signing.sh || exit 2
    wa_release_verify_sums "$OUT" || { echo "publisher: release_signature_invalid" >&2; exit 6; }
  elif [ "$PUBLISH" = 1 ]; then
    echo "publisher: release_not_signed (deferred, and no signature arrived)" >&2; exit 6
  fi
else
  bash scripts/sign-release.sh "$OUT/SHA256SUMS" "$SIG" >/dev/null || { echo "publisher: release_not_signed" >&2; exit 6; }
fi
printf 'publish-node-binaries: bundle: %s\n' "$OUT"
exit 0
]]

local SHIPPER_SCRIPT = [[
#!/usr/bin/env bash
# A stand-in for scripts/publish-artifacts-branch.sh with the rules that matter to the pipeline: the set is
# signed (SHA256SUMS + SHA256SUMS.sig, verified with the real library against the trusted keys of this tree),
# the commit is an ORPHAN one carrying exactly those files plus PUBLISH.sh, and the ref is pushed and read
# back. `WA_TEST_OMIT_SUMS=1` reproduces the 13/11 defect on purpose: name SHA256SUMS in PUBLISH.sh and do
# not carry it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE=""; COMMIT=""; FROM=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="$2"; shift 2 ;;
    --commit) COMMIT="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$REMOTE" ] && [ -n "$COMMIT" ] || { echo "shipper: remote and commit required" >&2; exit 2; }
DIR="${FROM:-$OUT}"
[ -n "$DIR" ] || { echo "shipper: no directory to ship" >&2; exit 2; }
SHORT="${COMMIT:0:12}"; TAG="node-$SHORT"
[ -f "$DIR/$TAG.manifest" ] || { echo "shipper: manifest_missing" >&2; exit 2; }
[ -f "$DIR/SHA256SUMS" ] || { echo "shipper: checksums_missing" >&2; exit 6; }
[ -f "$DIR/SHA256SUMS.sig" ] || { echo "shipper: release_not_signed: SHA256SUMS.sig is missing" >&2; exit 6; }
. "$ROOT/scripts/lib/release-signing.sh" || { echo "shipper: signing_library_missing" >&2; exit 2; }
wa_release_verify_sums "$DIR" || { echo "shipper: release_signature_invalid" >&2; exit 6; }
TRIPLE="$(awk '!/^#/ && !/=/ {print $1; exit}' "$DIR/$TAG.manifest")"
ASSETS="wa-$TRIPLE-$SHORT wa-sentinel-$TRIPLE-$SHORT $TAG.manifest SHA256SUMS SHA256SUMS.sig"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
for a in $ASSETS; do
  if [ "${WA_TEST_OMIT_SUMS:-0}" = 1 ] && [ "$a" = SHA256SUMS ]; then continue; fi
  cp -f "$DIR/$a" "$STAGE/$a" || exit 2
done
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "gh release create $TAG -R Magaav/wasm-agent --target $COMMIT --title $TAG --notes fake $ASSETS"
} > "$STAGE/PUBLISH.sh"
URL="$(git -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null || printf '%s' "$REMOTE")"
git -C "$STAGE" init -q . || exit 8
git -C "$STAGE" -c user.email=fake@example.com -c user.name=Fake add -A || exit 8
git -C "$STAGE" -c user.email=fake@example.com -c user.name=Fake commit -q -m "artifacts($TAG): $COMMIT" || exit 8
git -C "$STAGE" push -q -f "$URL" "HEAD:refs/heads/artifacts/$TAG" || exit 8
printf 'PUBLISHREADY artifacts/%s %s source=%s\n' "$TAG" "$(git -C "$STAGE" rev-parse HEAD)" "$COMMIT"
]]

local REVIEW_SCRIPT = [[
#!/usr/bin/env node
// A stand-in for scripts/review-branch.mjs: one finding and a non-zero exit, so the landing has to prove that
// findings are recorded and never block it.
console.log(JSON.stringify({ schema: 1, findings: [{ severity: 'low', note: 'fake reviewer: a nit in the merged file' }] }));
process.exit(1);
]]

local function setup_fixture()
  must("rm -rf " .. fixture, "clear the fixture")
  must("mkdir -p " .. fixture, "create the fixture directory")
  must("git init -q --bare -b main " .. incoming .. " && git init -q --bare -b main " .. origin ..
    " && git init -q -b main " .. repo .. " && cd " .. repo ..
    " && git config user.email land@example.com && git config user.name 'Land Fixture'" ..
    " && git config core.autocrlf false" ..
    " && git remote add oc-in " .. incoming .. " && git remote add origin " .. origin,
    "init the repositories and their remotes")
  write_file(repo .. "/a.txt", "base\n")
  write_file(repo .. "/scripts/publish-node-binaries.sh", PUBLISHER_SCRIPT)
  write_file(repo .. "/scripts/publish-artifacts-branch.sh", SHIPPER_SCRIPT)
  -- The REAL signer, library and verifier: the signature this test checks is made and verified by the code
  -- that ships, not by a second implementation of it.
  for _, relative in ipairs({ "scripts/sign-release.sh", "scripts/lib/release-signing.sh", "scripts/lib/release_verify.py" }) do
    must("mkdir -p " .. repo .. "/" .. (relative:match("^(.*)/[^/]+$") or "."), "mkdir for " .. relative)
    must("cp -f " .. tree_root .. "/" .. relative .. " " .. repo .. "/" .. relative, "copy " .. relative)
  end
  if VAULT_AVAILABLE then
    -- The trust anchor: the tree trusts the key this run's vault made, which is what `config/release-keys.txt`
    -- is for. A release signed by a key that is not in it is refused (case 11).
    local trusted = read_file(vault .. "/trusted-keys.txt") or "wa-trusted-keys v1\n"
    write_file(repo .. "/config/release-keys.txt", trusted)
  else
    write_file(repo .. "/config/release-keys.txt", "wa-trusted-keys v1\n")
  end
  must("chmod +x scripts/publish-node-binaries.sh scripts/publish-artifacts-branch.sh scripts/sign-release.sh", "exec bits", repo)
  must("git add -A && git commit -q -m base", "the base commit", repo)
  must("git push -q origin main && git push -q oc-in main", "publish the base", repo)

  local function branch(name)
    must("git checkout -q -B " .. name .. " main", "branch " .. name, repo)
  end
  branch("change/one"); write_file(repo .. "/one.txt", "one\n")
  must("git add -A && git commit -q -m one", "commit one", repo)
  branch("change/two"); write_file(repo .. "/two.txt", "two\n")
  must("git add -A && git commit -q -m two", "commit two", repo)
  branch("change/artifacts"); write_file(repo .. "/three.txt", "three\n")
  must("git add -A && git commit -q -m three", "commit three", repo)
  must("git checkout -q main", "back to main", repo)
  for _, name in ipairs({ "change/one", "change/two", "change/artifacts" }) do
    must("git push -q oc-in " .. name .. ":refs/heads/" .. name, "push " .. name, repo)
  end
  must("rm -rf " .. journal_root .. " && mkdir -p " .. journal_root, "clear the journal root")
end

local function marker(name)
  local common = must("git -C " .. repo .. " rev-parse --git-common-dir")
  if common:sub(1, 1) ~= "/" then common = repo .. "/" .. common end
  return common .. "/" .. name
end

local function advance_main(tip)
  must("git -C " .. repo .. " push -q oc-in " .. tip .. ":refs/heads/main", "advance the incoming main")
end

-- ---------------------------------------------------------------- the runner's routes
--
-- The real runner for everything, with three routes on top: `gh` (no test may publish), the publish script
-- itself (it would call gh), and the counters that prove a done push, sign or ship is never repeated. Every
-- command also carries the scratch vault's admin URL and token, exactly as the signing host's environment
-- does - the token is never printed by the code under test, and this is the only place it exists.
local real_exec = land.exec
local observed = { pushes = 0, main_pushes = 0, publish = 0, signs = 0, ships = 0, builds = 0 }
local behaviour = { publish_fails = false, release_present = false, omit_sums = false }

local function with_vault(command)
  if vault_env == "" then return command end
  return vault_env .. command
end

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
  if command:find("scripts/sign-release.sh", 1, true) then observed.signs = observed.signs + 1 end
  if command:find("publish%-artifacts%-branch%.sh") then observed.ships = observed.ships + 1 end
  if command:find("publish%-node%-binaries%.sh") then observed.builds = observed.builds + 1 end
  if command:find(" push 'oc%-in' ") then observed.pushes = observed.pushes + 1 end
  if command:find("push 'origin'") and command:find(" push ") then observed.main_pushes = observed.main_pushes + 1 end
  local routed = command
  if behaviour.omit_sums and command:find("publish%-artifacts%-branch%.sh") then
    routed = "WA_TEST_OMIT_SUMS=1 " .. command
  end
  return real_exec(with_vault(routed), cwd, timeout)
end

-- ---------------------------------------------------------------- the scripted fleet
local deploy_requests = {}
local fleet = { failing_node = nil, recovered = false, sign_node = "laptop", sign_null = false }
local sign_calls = 0

local function remote_call(selector, capability, args)
  args = type(args) == "table" and args or {}
  if capability == "bash" then
    local command = tostring(args.command or "")
    if command:find("printenv") then
      -- The signer probe: only a node that sets a vault operator URL answers with one.
      if selector == fleet.sign_node and not fleet.sign_null then
        return { code = 0, stdout = "http://127.0.0.1:8801\n", stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "" }
    end
    -- The signing request: the signer node runs the command it was given (which is what a real node does -
    -- its own `scripts/sign-release.sh`, with its own environment) and answers with its exit and streams.
    sign_calls = sign_calls + 1
    local code, out, err = shell(with_vault(command))
    return { code = code, stdout = out, stderr = err }
  end
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
  local text = read_file(land.journal_path(id))
  if not text then return nil end
  local decoded_ok, value = pcall(json.decode, text)
  return (decoded_ok and value) or nil
end

local function step_of(id, name)
  local journal = journal_of(id)
  return journal and journal.steps and journal.steps[name]
end

local function gate_script(name)
  local path = host.paths().home .. "/land-gate/" .. name .. ".sh"
  must("mkdir -p " .. host.paths().home .. "/land-gate", "create the gate directory")
  write_file(path, string.format([[#!/usr/bin/env bash
# A gate row whose verdict is read from its own counter file: "pass", "fail", or "flaky" (red beside other
# work, green alone - the flaky-under-load shape).
STATE="%s/land-gate/%s.state"
MODE="$(cat "$STATE" 2>/dev/null || echo pass)"
case "$MODE" in
  pass) echo "fast: 12 rows ok"; exit 0 ;;
  fail) echo "FAIL fast: fake red check"; exit 1 ;;
  flaky)
    echo pass > "$STATE"
    echo "FAIL fast: fork failure under load (fake)"; exit 1 ;;
esac
exit 1
]], host.paths().home, name))
  return path
end

local function set_gate(name, mode)
  write_file(host.paths().home .. "/land-gate/" .. name .. ".state", mode .. "\n")
end

-- The ring the machine deploys is proved once (case 2) and resumed once (case 6). Every other case is about a
-- step, so it walks a one-node ring: same code, four times fewer peers.
local SOLO_RING = { { node = "work", mode = "tree" } }

local function standard_checks(which)
  return { { name = "fast", command = "bash " .. tostring(which or gate_script("gate-pass")), timeout = 120 } }
end

set_gate("gate-pass", "pass")

-- ---------------------------------------------------------------- case 1: the weight probe
local decorator = land.weight()
ok(decorator == nil or type(decorator) == "string", "the weight probe answers a decorator or nothing")
ok(#land.WEIGHT_CANDIDATES >= 2, "there is more than one weight candidate to fall back through")
contains(land.WEIGHT_CANDIDATES[1].decorator, "CPUWeight", "the first candidate is a systemd CPU/IO weight")
land.weight_decorator = ""

-- ---------------------------------------------------------------- case 2: the happy path
start_vault()
setup_fixture()

local happy = land.run({ run = "case2", signer = "local", branches = { "change/one", "change/two" }, checks = standard_checks() })
eq(happy, 0, "the happy path lands")
local journal = journal_of("case2")
ok(journal ~= nil, "the journal is written")
eq(journal.result, "done", "the run is recorded done")
local expected_state = { review = "skipped" }   -- the reviewer is not on main: a named skip, never a done
for _, name in ipairs(land.STEPS) do
  eq(step_of("case2", name) and step_of("case2", name).state, expected_state[name] or "done",
    "step " .. name .. " is " .. (expected_state[name] or "done"))
end
local tip = journal.tree_commit
ok(tostring(tip):match("^%x+$") ~= nil, "the journal names a landed tip")
contains(must("git -C " .. repo .. " ls-remote oc-in refs/heads/" .. journal.land_branch), tip,
  "the landed tip is on the incoming repository")
contains(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), tip, "main was fast-forwarded to it")
-- The release set, the signature and the reference.
eq(journal.artifacts.commit, tip, "the release set is this commit's")
contains(journal.artifacts.manifest, "node-" .. tip:sub(1, 12) .. ".manifest", "the journal names the manifest")
ok(read_file(journal.artifacts.manifest) ~= nil, "the manifest is on disk")
if VAULT_AVAILABLE then
  eq(journal.artifacts.signed, true, "the release is signed")
  eq(journal.artifacts.signer, "local", "signed on this node (which sets the vault's admin URL)")
  contains(journal.artifacts.key_id, "release-signing-", "the journal names the signing key")
  ok(read_file(journal.artifacts.dir .. "/SHA256SUMS.sig") ~= nil, "SHA256SUMS.sig exists")
  eq(observed.signs, 1, "exactly one signing run")
end
eq(observed.builds, 1, "exactly one build")
eq(observed.ships, 1, "exactly one ship")
contains(must("git -C " .. repo .. " fetch -q oc-in refs/heads/" .. journal.artifacts.ref .. " && git -C " .. repo ..
  " ls-tree -r --name-only FETCH_HEAD"), "SHA256SUMS.sig", "the artifacts ref carries the signature")
contains(must("git -C " .. repo .. " ls-tree -r --name-only FETCH_HEAD"), "SHA256SUMS",
  "the artifacts ref carries SHA256SUMS")
eq(observed.pushes, 1, "exactly one push to the incoming repository")
eq(observed.main_pushes, 1, "exactly one push to main")
eq(observed.publish, 1, "exactly one publish")
eq(journal.publish and journal.publish.state, "published", "the release is recorded published")
eq(journal.publish and journal.publish.signed, true, "and recorded signed")
local nodes = {}
for _, row in ipairs(journal.deploy) do nodes[#nodes + 1] = row.node .. ":" .. row.mode end
eq(table.concat(nodes, ","), "work:tree,mail:tree,nextcloud:binary,openclaw:tree",
  "the ring deploys in order, with openclaw last and nextcloud binary-only")
for _, row in ipairs(journal.deploy) do eq(row.state, "installed", "node " .. row.node .. " is installed") end
local todo_items = {}
for _, todo in ipairs(journal.todos or {}) do todo_items[#todo_items + 1] = todo.item end
eq(table.concat(todo_items, ","), "reviewer", "the one absent channel (reviewer) is recorded as a TODO")
local report = read_file(land.report_path("case2")) or ""
contains(report, "# wa land case2", "the report is written to a file")
contains(report, "signature", "the report carries the signature row")
contains(report, "nextcloud", "the report carries the per-node results")
advance_main(tip)

-- ---------------------------------------------------------------- case 3: a red gate stops the landing
local red = gate_script("gate-red")
set_gate("gate-red", "fail")
observed.pushes = 0
local red_code = land.run({ run = "case3", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks(red) })
eq(red_code, 1, "a red gate stops the landing")
eq(journal_of("case3").result, "stopped", "the run is recorded stopped")
eq(journal_of("case3").stopped_at, "gate", "it stopped at the gate")
eq(step_of("case3", "gate").state, "failed", "the gate step is failed")
contains(step_of("case3", "gate").detail, "failed twice", "the failure names both runs")
ok(read_file(step_of("case3", "gate").evidence) ~= nil, "the gate's evidence file exists")
eq(observed.pushes, 0, "no push happened")

-- ---------------------------------------------------------------- case 4: flaky under load
local flaky = gate_script("gate-flaky")
set_gate("gate-flaky", "flaky")
observed.pushes = 0
local flaky_code = land.run({ run = "case4", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks(flaky) })
eq(flaky_code, 1, "a flaky check stops the landing")
local flaky_step = step_of("case4", "gate")
eq(flaky_step.state, "flaky", "the gate step is recorded flaky, not done")
contains(flaky_step.detail, "flaky under load: fast", "the detail says flaky under load, by name")
eq(journal_of("case4").result, "stopped", "the run is stopped, never silently green")
eq(observed.pushes, 0, "a flaky gate pushes nothing")

-- ---------------------------------------------------------------- case 5: a check that proves nothing
write_file(host.paths().home .. "/land-gate/vacuous.sh", "#!/usr/bin/env bash\nexit 0\n")
local vacuous = land.run({ run = "case5", ring = SOLO_RING, branches = { "change/one" },
  checks = { { name = "cargo-codemode", command = "bash " .. host.paths().home .. "/land-gate/vacuous.sh", min_tests = 1 } } })
eq(vacuous, 1, "a check that proves nothing is not green")
eq(step_of("case5", "gate").error, "gate_vacuous", "the refusal is named")
contains(step_of("case5", "gate").detail, "proved nothing", "the detail says the run proved nothing")

-- ---------------------------------------------------------------- case 6: resume after the deploy failed on node 3
-- A fresh repository: case 2 landed these branches and advanced main, so merging them again here would be a
-- no-op and the tip would already BE main - the run would have nothing to push and prove nothing.
setup_fixture()
deploy_requests = {}
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
local before = #deploy_requests
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
eq(#deploy_requests, before + 2, "the resume asked only the failed node and the one after it")
eq(deploy_requests[#deploy_requests - 1].node, "nextcloud", "the resume starts at node 3")
eq(deploy_requests[#deploy_requests].node, "openclaw", "and finishes with openclaw")
local states = {}
for _, row in ipairs(second.deploy) do states[#states + 1] = row.node .. ":" .. row.state end
contains(table.concat(states, ","), "nextcloud:failed", "the failed attempt stays in the record")
contains(table.concat(states, ","), "nextcloud:installed", "and the settled one is recorded beside it")
advance_main(landed)

-- ---------------------------------------------------------------- case 7: the rollback, reverse order
deploy_requests = {}
fleet.failing_node = nil
local rolled = land.run({ run = "case7-rollback", rollback = true })
eq(rolled, 0, "the rollback walks the ring")
local rollback_order, rollback_modes = {}, {}
for _, row in ipairs(deploy_requests) do
  rollback_order[#rollback_order + 1] = row.node
  rollback_modes[#rollback_modes + 1] = tostring(row.mode)
end
eq(table.concat(rollback_order, ","), "openclaw,nextcloud,mail,work", "the rollback runs the ring in reverse")
eq(table.concat(rollback_modes, ","), "rollback,rollback,rollback,rollback", "every request asks for a rollback")

-- ---------------------------------------------------------------- case 8: the rollback script itself
local rollback_script = tree_root .. "/scripts/rollback-node.sh"
ok(read_file(rollback_script) ~= nil, "the rollback script this node ships is here: " .. rollback_script)
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

-- ---------------------------------------------------------------- case 9: the signature made on a NAMED node
-- The vault's admin listener is not on this machine, so the pipeline signs where it is and the signature
-- travels back. This is that path: the node `laptop` runs the command it is given (its own signer, its own
-- environment) and answers with the signature; the land machine verifies it before anything ships.
if not VAULT_AVAILABLE then
  print("SKIP test-land: no scratch vault, so the signer-node hand-back was not exercised")
else
  setup_fixture()
  land.candidates = function() return { "laptop" } end
  sign_calls = 0
  local node_code = land.run({ run = "case9", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
  eq(node_code, 0, "a release signed on the node that reaches the vault lands")
  local node_journal = journal_of("case9")
  eq(node_journal.artifacts.signer, "laptop", "the journal names the node that signed")
  eq(node_journal.artifacts.signed, true, "the signature that came back verified here")
  contains(node_journal.artifacts.key_id, "release-signing-", "and it names the key")
  ok(sign_calls >= 1, "the signer node actually ran the signing command")
  contains(must("git -C " .. repo .. " fetch -q oc-in refs/heads/" .. node_journal.artifacts.ref ..
    " && git -C " .. repo .. " ls-tree -r --name-only FETCH_HEAD"), "SHA256SUMS.sig",
    "the shipped release carries the signature made elsewhere")
  advance_main(node_journal.tree_commit)

  -- ------------------------------------------------------------- case 10: no signer at all
  setup_fixture()
  land.candidates = function() return {} end
  local unknown_code = land.run({ run = "case10", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
  eq(unknown_code, 1, "no reachable vault stops the landing")
  eq(step_of("case10", "sign").state, "failed", "the sign step is failed")
  eq(step_of("case10", "sign").error, "signer_unknown", "the refusal is named")
  contains(step_of("case10", "sign").next, "--signer", "the refusal names the way to fix it")
  local unsigned_journal = journal_of("case10")
  ok(unsigned_journal ~= nil, "the journal of an unsigned stop is written")
  local unsigned_tip = tostring((unsigned_journal or {}).tree_commit or "")
  ok(#unsigned_tip == 40, "the journal names the landed tip of the unsigned run")
  eq(must("git -C " .. repo .. " ls-remote oc-in refs/heads/artifacts/node-" .. unsigned_tip:sub(1, 12)), "",
    "nothing was shipped for an unsigned release")
  local unsigned_ship = step_of("case10", "ship")
  ok(unsigned_ship == nil or unsigned_ship.state == "pending", "the ship step never ran")
  local unsigned_publish = step_of("case10", "publish")
  ok(unsigned_publish == nil or unsigned_publish.state == "pending", "and nothing was published")

  -- ------------------------------------------------------------- case 11: a key this project does not trust
  setup_fixture()
  land.candidates = function() return {} end
  write_file(repo .. "/config/release-keys.txt", "wa-trusted-keys v1\n")
  must("git add -A && git commit -q -m 'trust nothing' && git push -q origin main && git push -q oc-in main",
    "commit an empty trusted-key list", repo)
  local untrusted_code = land.run({ run = "case11", ring = SOLO_RING, branches = { "change/one" },
    signer = "local", checks = standard_checks() })
  eq(untrusted_code, 1, "a signature by an untrusted key stops the landing")
  eq(step_of("case11", "sign").state, "failed", "the sign step is failed")
  eq(step_of("case11", "sign").error, "release_key_not_trusted", "the refusal is named")
  contains(step_of("case11", "sign").next, "config/release-keys.txt", "it names where the key has to be trusted")
  local untrusted_journal = journal_of("case11")
  ok(untrusted_journal ~= nil, "the journal of an untrusted-key stop is written")
  local untrusted_tip = tostring((untrusted_journal or {}).tree_commit or "")
  ok(#untrusted_tip == 40, "the journal names the landed tip of the untrusted run")
  eq(must("git -C " .. repo .. " ls-remote oc-in refs/heads/artifacts/node-" .. untrusted_tip:sub(1, 12)), "",
    "a release no node would verify is not shipped")
end

-- ---------------------------------------------------------------- case 12: publish without a credential
setup_fixture()
local saved_route = land.exec
land.exec = function(command, cwd, timeout)
  if command:match("^command %-v gh") then return { code = 0, stdout = "no\n", stderr = "" } end
  return saved_route(command, cwd, timeout)
end
local no_gh = land.run({ run = "case12", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(no_gh, 1, "a machine without gh stops at the publish")
local publish_step = step_of("case12", "publish")
eq(publish_step.error, "publish_needs_credentials", "the stop is named")
contains(publish_step.next, "PUBLISH.sh", "the stop names the exact command that publishes elsewhere")
eq(step_of("case12", "sign").state, VAULT_AVAILABLE and "done" or "failed", "the release was signed before it was published")
eq(step_of("case12", "ship").state, "done", "and shipped")
land.exec = saved_route

-- ---------------------------------------------------------------- case 13: the reviewer, never blocking
setup_fixture()
-- The reviewer is a channel that must already be ON MAIN: it reviews a branch BEFORE that branch is merged.
must("git checkout -q main", "back to main", repo)
write_file(repo .. "/scripts/review-branch.mjs", REVIEW_SCRIPT)
must("git add -A && git commit -q -m 'the reviewer arrives on main' && git push -q origin main && git push -q oc-in main",
  "publish the reviewer on main", repo)
local reviewed_code = land.run({ run = "case13", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(reviewed_code, 0, "a reviewer's findings do not block a landing")
local reviewed = journal_of("case13")
ok(reviewed.review and #reviewed.review == 1, "the reviewer ran once, on the branch")
eq(reviewed.review[1].exit_code, 1, "its non-zero exit is recorded as a fact")
contains(reviewed.review[1].findings, "fake reviewer", "its findings are recorded")
advance_main(reviewed.tree_commit)

-- ---------------------------------------------------------------- case 14: a shipped ref that names a file it does not carry
-- The 13/11 defect, on purpose: PUBLISH.sh names SHA256SUMS and the commit does not hold it.
behaviour.omit_sums = true
local broken_code = land.run({ run = "case14", signer = "local", ring = SOLO_RING, branches = { "change/artifacts" }, checks = standard_checks() })
behaviour.omit_sums = false
eq(broken_code, 1, "an incomplete artifacts reference stops the landing")
eq(step_of("case14", "ship").state, "failed", "the ship step failed")
eq(step_of("case14", "ship").error, "ship_incomplete", "the refusal is named")
contains(step_of("case14", "ship").observed, "SHA256SUMS", "the refusal names the file the reference does not carry")

-- ---------------------------------------------------------------- case 15: the ready box
-- A fresh repository: case 14 pushed main before it failed at the ship, so reusing that history would land the
-- same commit again and the ref for it (the incomplete one case 14 made) would be the one under test.
setup_fixture()
must("rm -f " .. land.ready_file(), "an empty ready box")
local tip_one = must("git -C " .. repo .. " rev-parse change/one")
eq(land.cli({ "land", "ready", "change/one", tip_one }), 0, "a READY line is recorded")
contains(read_file(land.ready_file()) or "", "READY change/one " .. tip_one, "the box holds the line")
local ready_code = land.run({ run = "case15", signer = "local", ring = SOLO_RING, ready = true, no_deploy = true, checks = standard_checks() })
eq(ready_code, 0, "the ready box is enough to land")
local ready_journal = journal_of("case15")
eq(#ready_journal.branches, 1, "one branch was collected from the box")
eq(ready_journal.branches[1].name, "change/one", "the branch named in the line")
eq(step_of("case15", "deploy").state, "skipped", "--no-deploy skips the deploy, by name")
contains(step_of("case15", "deploy").detail, "--no-deploy", "the skip says why")
advance_main(ready_journal.tree_commit)

-- A recorded sha that no longer matches the branch is a refusal, not a silent upgrade.
must("rm -f " .. land.ready_file(), "an empty ready box")
land.ready_mark("change/one", string.rep("0", 40))
local moved_code = land.run({ run = "case16", signer = "local", ring = SOLO_RING, ready = true, no_deploy = true, checks = standard_checks() })
eq(moved_code, 1, "a moved branch is refused")
eq(step_of("case16", "collect").error, "ready_sha_moved", "the refusal is named")
contains(step_of("case16", "collect").next, "moved", "the refusal says what to do")

-- ---------------------------------------------------------------- case 17: the CLI
eq(land.cli({ "chat" }), nil, "not a land request: the dispatcher keeps its own path")
eq(land.cli({ "land", "--help" }), 0, "the help is free")
eq(land.cli({ "land" }), 2, "no arguments is a usage answer")
eq(land.cli({ "land", "--branches" }), 2, "a flag without a value is refused")
eq(land.cli({ "land", "--signer" }), 2, "a signer without a value is refused")
-- The dry run changes nothing and names the signer it would use.
local function journal_count()
  local out = must("ls -1 " .. journal_root .. " 2>/dev/null | wc -l")
  return tonumber((out:gsub("%s+", ""))) or 0
end
local before_journals = journal_count()
local before_pushes = observed.pushes
eq(land.cli({ "land", "--branches", "change/one", "--signer", "laptop", "--dry-run" }), 0, "the dry run answers zero")
eq(observed.pushes, before_pushes, "the dry run pushed nothing")
eq(journal_count(), before_journals, "the dry run wrote no journal")

stop_vault()
print(string.format("land ok (%d checks)", checks))
