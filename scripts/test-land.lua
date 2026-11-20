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
  -- `setsid -w`, not `setsid`: host.exec runs a command as the leader of its own process group, and a
  -- group leader is exactly the case where util-linux `setsid` FORKS and its parent returns at once. The
  -- host then waits only its 1 s cleanup budget for start.sh (which still holds the output pipe, in the
  -- new session) and answers `code -1, cleanup_incomplete` - so whenever start.sh needed more than a
  -- second (a loaded machine: the vault start, a curl, three python3 runs) this row printed "SKIP ...
  -- the scratch wa-vault did not start" with an empty reason and the happy path then failed at `sign`
  -- (measured 15/11 on wa-desktop, two fast runs in parallel; a probe with a 2 s script: plain `setsid`
  -- -> code -1 and no stdout, `setsid -w` -> code 0 and the script's output, the detached child alive
  -- in both). `-w` waits for start.sh and returns its exit status; the vault is still in the new
  -- session, so the process-group cleanup after this command cannot reach it.
  local code, out, err = shell("setsid -w bash " .. vault .. "/start.sh")
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

-- A stand-in for the reviewer's DOOR, not for a reviewer of its own: `wa land` runs `wa eval reviewer <branch>
-- ... --json <file>`, and this script speaks exactly that contract - it writes the answer where the real verb
-- writes it, exits with what the real verb exits with, and records the arguments it was given so the test can
-- hold the landing to "branch, base and the brief". Its modes are the four outcomes a landing has to survive:
--
--   findings      two findings, after the GATE has run (mode `gate` makes it wait for the gate's marker, which
--                 is how the test proves the review overlaps the gate instead of being serialised before it)
--   fail          a reviewer that cannot run: exit 3, one line on stderr, no answer file
--   other_commit  an answer about a commit that is not the branch's tip
--   slow          a review still running when the report has to say what it knows
local FAKE_REVIEWER_SCRIPT = [==[#!/usr/bin/env bash
# A fake reviewer at the reviewer's own door (`wa eval reviewer`). Generated by scripts/test-land.lua.
set -uo pipefail
JSON=""; BRIEF=""; BASE=""; BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON="$2"; shift 2 ;;
    --brief) BRIEF="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --repo|--bin|--timeout) shift 2 ;;
    eval|reviewer) shift ;;
    *) BRANCH="$1"; shift ;;
  esac
done
printf 'branch=%s base=%s brief=%s\n' "$BRANCH" "$BASE" "$BRIEF" >> @@ARGS@@
MODE="$(cat @@MODE@@ 2>/dev/null || echo findings)"
case "$MODE" in
  findings|gate)
    if [ "$MODE" = gate ]; then
      for _ in $(seq 1 400); do [ -f @@MARKER@@ ] && break; sleep 0.05; done
    fi
    printf '%s\n' '{"schema":"harness-evaluator/review/answer/1","ok":true,"state":"reviewed","review_id":"fake-001","findings":2,"answer":"fake reviewer: the opt-out switch is read in one place, and the report names the brief"}' > "$JSON"
    printf 'REVIEW %s %s findings=2\n' "$BRANCH" "$BASE"
    exit 0 ;;
  fail)
    echo "fake reviewer: the model route is missing" >&2
    exit 3 ;;
  other_commit)
    printf '%s\n' '{"schema":"harness-evaluator/review/answer/1","ok":true,"state":"reviewed","review_id":"fake-002","findings":1,"sha":"0000000000000000000000000000000000000000","answer":"fake reviewer: about a commit that is not this branch"}' > "$JSON"
    exit 0 ;;
  slow)
    sleep 3
    exit 0 ;;
  *) echo "fake reviewer: unknown mode $MODE" >&2; exit 9 ;;
esac
]==]

local review_home = host.paths().home .. "/land-review"
local FAKE_REVIEWER = review_home .. "/fake-reviewer"
local REVIEW_MODE = review_home .. "/mode"
local REVIEW_ARGS = review_home .. "/args"
local REVIEW_MARKER = review_home .. "/gate-ran"
local REVIEW_SHA_FILE = review_home .. "/tip"

local function fill(template, values)
  return (template:gsub("@@([A-Z_]+)@@", function(name) return values[name] or "" end))
end

local function install_fake_reviewer()
  must("mkdir -p " .. review_home, "create the fake reviewer's directory")
  write_file(FAKE_REVIEWER, fill(FAKE_REVIEWER_SCRIPT, { ARGS = REVIEW_ARGS, MODE = REVIEW_MODE, MARKER = REVIEW_MARKER }))
  must("chmod +x " .. FAKE_REVIEWER, "make the fake reviewer executable")
end

local function review_start(mode)
  write_file(REVIEW_MODE, tostring(mode or "findings") .. "\n")
end

local function review_forget()
  must("rm -f " .. REVIEW_ARGS .. " " .. REVIEW_MARKER .. " " .. REVIEW_SHA_FILE, "clear the fake reviewer's records")
end

local function review_arguments() return read_file(REVIEW_ARGS) or "" end

local function review_started()
  local count = 0
  for _ in (review_arguments()):gmatch("[^\r\n]+") do count = count + 1 end
  return count
end

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
local behaviour = { publish_fails = false, release_present = false, omit_sums = false,
  gh_authed = true, gh_present = true }

local function with_vault(command)
  if vault_env == "" then return command end
  return vault_env .. command
end

land.exec = function(command, cwd, timeout)
  -- `gh auth status` is part of the check (item 26): a gh that exists and is not signed in is not a
  -- credential, so the route answers for both halves of the question.
  if command:match("^command %-v gh") then
    local binary = behaviour.gh_present ~= false
    local authed = behaviour.gh_authed ~= false
    local yes = binary and authed
    return { code = yes and 0 or 1, stdout = yes and "yes\n" or "no\n", stderr = "" }
  end
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

local routed_calls = {}
local function remote_call(selector, capability, args)
  args = type(args) == "table" and args or {}
  if capability == "bash" then
    local command = tostring(args.command or "")
    -- THE ROUTED WORK (item 26): main and the release are done ON a named node, by that node's own
    -- account. Recorded here so a case can prove WHERE the work ran, and answered the way that node
    -- would answer it.
    local kind = nil
    if command:find("gh auth status", 1, true) then kind = "gh auth"
    elseif command:find("refs/heads/main", 1, true) and command:find("push ", 1, true) then kind = "main"
    elseif command:find("PUBLISH.sh", 1, true) then kind = "publish"
    elseif command:find("gh release view", 1, true) then kind = "release view" end
    if kind then routed_calls[#routed_calls + 1] = { node = selector, kind = kind, command = command } end
    if kind == "gh auth" then
      local yes = behaviour.gh_present ~= false and behaviour.gh_authed ~= false
      return { code = yes and 0 or 1, stdout = yes and "yes\n" or "no\n", stderr = "" }
    end
    if kind == "release view" then
      return { code = 0, stdout = (behaviour.release_present and "present\n" or "absent\n"), stderr = "" }
    end
    if kind == "publish" then
      if behaviour.publish_fails then
        return { code = 1, stdout = "", stderr = "publish_failed: fake gh refused (no token)\n" }
      end
      return { code = 0, stdout = "fake gh: release created\n", stderr = "" }
    end
    if kind == "main" then
      local code, out, err = shell(command, repo)
      return { code = code, stdout = out, stderr = err }
    end
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
land.SIGNER_VARS = {}        -- see above: the ambient vault is not this row's
land.remote_call = remote_call
land.weight_decorator = ""          -- exercised in its own check below; the rows run unweighted and fast
-- NO AMBIENT VAULT. The signer question is asked of the process environment first, and a NODE that runs this
-- row exports WASM_AGENT_VAULT_OPERATOR_URL for its own vault: the row then signed "locally" against a vault
-- it does not own, and every case that names a signer node failed on that machine and nowhere else
-- (measured 19/11 on avell). The row's own vault is the scratch one above, so the ambient names are cleared
-- HERE - the module reads this table (M.SIGNER_VARS) and nothing else decides who signs.
land.sleep = function() end         -- the deploy poll must not cost the suite five seconds a lap
-- The reviewer's binary: the landing starts `wa eval reviewer` as a process of its own, so the seam is WHERE that
-- process comes from, and everything else about the review (the door, `--json`, the join) stays real code.
install_fake_reviewer()
land.review_binary_path = FAKE_REVIEWER
review_start("findings")

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
local expected_state = { review = "done" }   -- the reviewer really runs: its findings are joined at the report
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
eq(table.concat(todo_items, ","), "", "no channel is a TODO any more (the reviewer that landed is the one that runs)")
eq(#(journal.review or {}), 2, "both branches of the round were reviewed")
for _, row in ipairs(journal.review or {}) do
  eq(row.state, "reviewed", "the review of " .. tostring(row.branch) .. " happened")
  eq(row.findings, 2, "its findings are a number in the journal: " .. tostring(row.branch))
end
local report = read_file(land.report_path("case2")) or ""
contains(report, "# wa land case2", "the report is written to a file")
contains(report, "signature", "the report carries the signature row")
contains(report, "nextcloud", "the report carries the per-node results")
contains(report, "## review", "the report carries the review section")
contains(report, "fake reviewer", "and the reviewer's own findings")
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

-- ---------------------------------------------------------------- case 13: the reviewer really runs
-- `wa land` runs the reviewer that LANDED (`wa eval reviewer`) on every branch of the round and BEFORE the
-- merge, through that door and no other. The fake sits where that process sits (`M.review_binary_path`) and
-- speaks that door's contract (`--json`), so the step, the spawn, the join, the journal and the report are all
-- the shipped code. What this case proves: findings reach the journal and the report, the review really runs
-- BESIDE the gate (the fake only answers after the gate's own row has run), and the reviewer is given the
-- branch, the base and the brief the ready box knew.
setup_fixture()
review_start("gate")
review_forget()
-- The gate's row touches the marker the fake waits for: a landing that serialised the review before the merge
-- and the gate could never touch it, and the findings would never arrive.
local overlap_gate = host.paths().home .. "/land-gate/gate-overlap.sh"
write_file(overlap_gate, fill([==[#!/usr/bin/env bash
# A gate row that leaves a trace the review can see: if the review ran AFTER the gate, this file is written
# after the fake looked for it, and the fake answers nothing.
touch @@MARKER@@
echo "fast: 12 rows ok"
]==], { MARKER = REVIEW_MARKER }))
local brief_path = review_home .. "/brief-one.md"
write_file(brief_path, "The brief for change/one: one file, one behavior, one string.\n")
must("rm -f " .. land.ready_file(), "an empty ready box")
local tip_one = must("git -C " .. repo .. " rev-parse change/one")
eq(land.cli({ "land", "ready", "change/one", tip_one, "--brief", brief_path }), 0,
  "a READY line with a brief is recorded")
contains(read_file(land.ready_file()) or "", "brief=" .. brief_path, "the brief travels on the ready line")
local reviewed_code = land.run({ run = "case13", signer = "local", ring = SOLO_RING, ready = true, no_deploy = true,
  checks = standard_checks(overlap_gate) })
eq(reviewed_code, 0, "a reviewer's findings never block a landing")
ok(read_file(REVIEW_MARKER) ~= nil, "the gate ran while the review was still going: the review is not serialised before it")
local reviewed = journal_of("case13")
eq(#(reviewed.review or {}), 1, "one review row per branch of the round")
local review_row = reviewed.review[1]
eq(review_row.branch, "change/one", "the row names the branch")
eq(review_row.state, "reviewed", "the review happened")
eq(review_row.findings, 2, "its findings are a number in the journal, not a sentence")
eq(review_row.review_id, "fake-001", "the row names the review, so a finding can be marked afterwards")
contains(review_row.answer, "fake reviewer", "the reviewer's own answer is in the journal")
eq(review_row.unavailable, nil, "and the field is absent, not empty")
eq(step_of("case13", "review").state, "done", "the review step is done once the reviews are joined")
contains(step_of("case13", "review").detail, "2 finding(s)", "the step counts the findings it reported")
local got_arguments = review_arguments()
contains(got_arguments, "branch=change/one", "the reviewer was given the branch")
contains(got_arguments, "base=" .. tostring(reviewed.base), "and the base the round is landing on")
contains(got_arguments, "brief=" .. brief_path, "and the brief the ready box knew")
eq(review_started(), 1, "exactly one review was started for one branch")
local review_report = read_file(land.report_path("case13")) or ""
contains(review_report, "## review", "the report has a review section")
contains(review_report, "fake reviewer", "the report carries the findings")
contains(review_report, "fake-001", "the report names the review")
advance_main(reviewed.tree_commit)

-- 13b. The reviewer's own opt-out switch: `reviewer = off` reaches the landing through the reviewer's own
-- module, so nothing is started and the step says which switch stopped it. A landing is not a second place
-- where "off" can mean something else. Proved on the step itself - the switch is read before anything else can
-- happen, so a landing around it would prove nothing more and cost a release build.
review_start("findings")
review_forget()
local real_engine = land.review_engine
land.review_engine = function()
  return { switch = function() return { on = false, source = "config <home>/.wasm-agent/env", value = "off" } end }
end
local off_run = { id = "case13b", journal = { run = "case13b", base = tostring(journal_of("case13").base),
  repo = repo, branches = { { name = "change/two", sha = must("git -C " .. repo .. " rev-parse change/two") } },
  steps = {}, review_jobs = {}, deploy = {}, todos = {} } }
local off_ok, off_result = land.impl.review(off_run, {})
land.review_engine = real_engine
eq(off_ok, true, "the review step never stops a landing")
eq(off_result.state, "skipped", "the review step is skipped, never silently done")
contains(off_result.detail, "reviewer off", "the skip names the switch")
contains(off_result.detail, "off", "and the value it read")
eq(review_started(), 0, "no review was started while the switch says off")
eq(#(off_run.journal.review_jobs or {}), 0, "and no job is recorded")

-- 13c. A reviewer that cannot run: "review unavailable: <reason>", never a silent skip and never a stop. The
-- landing is a real one on the repository case 13 left (change/two is still unmerged), because "never blocking"
-- is a statement about a landing and not about a step.
review_start("fail")
review_forget()
local failed_code = land.run({ run = "case13c", signer = "local", ring = SOLO_RING, branches = { "change/two" },
  no_deploy = true, checks = standard_checks() })
eq(failed_code, 0, "a reviewer failure does not stop the landing")
local failed = journal_of("case13c")
eq(#(failed.review or {}), 1, "the branch still has a row: a failure is evidence, not a silence")
contains(failed.review[1].unavailable, "review unavailable:", "the failure is named as unavailable")
contains(failed.review[1].unavailable, "exited 3", "with the exit the reviewer failed with")
contains(failed.review[1].unavailable, "the model route is missing", "and the reviewer's own words")
contains(step_of("case13c", "review").detail, "review unavailable:", "the step says the same thing")
eq(step_of("case13c", "review").state, "done", "recorded as a step that ran, not as a silent skip")
eq(failed.result, "done", "and the landing is done")
contains(read_file(land.report_path("case13c")) or "", "review unavailable:", "the report carries it")
advance_main(failed.tree_commit)

-- 13d. The join itself, without a landing: an answer about another commit is not this branch's review, and a
-- review nobody waited for is reported by name. Both are rows; neither is a stop.
-- A pid that is certainly alive: this row's own process, which is what a review still running looks like.
local process_id = (function()
  local decoded_ok, value = pcall(json.decode, host.runtime_info())
  if decoded_ok and type(value) == "table" then return value.process_id end
  return nil
end)()
local function collect_case(name, answer, exit_code, live)
  local stem = review_home .. "/collect-" .. name
  if answer then write_file(stem .. ".json", json.encode(answer) .. "\n")
  else must("rm -f " .. stem .. ".json", "clear a collected answer") end
  if exit_code then write_file(stem .. ".code", tostring(exit_code) .. "\n") end
  local journal_row = { run = "collect-" .. name, result = "done", deploy = {}, todos = {}, branches = {},
    steps = { review = { name = "review", state = "started", started_at = math.floor(host.now()) } },
    review_jobs = { { branch = "change/x", sha = string.rep("a", 40), base = "base", json = stem .. ".json",
      code_path = stem .. ".code", log = stem .. ".log", started_at = math.floor(host.now()),
      pid = live and process_id or 999999 } } }
  local saved = land.REVIEW_WAIT
  land.REVIEW_WAIT = 0
  land.review_collect({ id = "collect-" .. name, journal = journal_row })
  land.REVIEW_WAIT = saved
  return journal_row.review[1]
end
local other = collect_case("other", { schema = "harness-evaluator/review/answer/1", ok = true, state = "reviewed",
  review_id = "fake-003", findings = 1, sha = string.rep("b", 40), answer = "about another commit" })
eq(other.state, "reviewed", "the answer was a review")
contains(other.unavailable, "review unavailable:", "but it is not this branch's review")
contains(other.unavailable, "answered about bbbbbbbbbbbb", "and it says which commit it answered about")
local running = collect_case("running", nil, nil, true)
eq(running.state, "running", "a review nobody waited for is recorded as running")
contains(running.unavailable, "still running after 0s", "by its own words, not as \"no findings\"")
contains(running.unavailable, "wa eval reviewer list", "and it says where its record will arrive")
local gone = collect_case("gone", nil, nil, false)
eq(gone.state, "unavailable", "a review process that is gone without an answer is unavailable")
contains(gone.unavailable, "gone without an answer", "and says exactly that")

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

-- ---------------------------------------------------------------- case 18: the fastlane plan
--
-- The mission's rule: the round takes the CHEAPEST safe path, decided from what changed before anything runs.
-- These cases stand the REAL classifier and the REAL record script in a fixture and assert the decisions - the
-- categories, the steps each one skips, the gate's narrowing with its never-dropped core, the deploy's waves
-- (canary first, the middle together, the account node last, stop at the first failure) and the cost report
-- against the journal's own history.

-- The classifier is the tree's own (`scripts/lib/land-classify.sh` + `scripts/lib/node-binaries.sh`): a fork
-- of the rule would be a plan that disagrees with the deploy about the same file.
for _, relative in ipairs({ "scripts/lib/land-classify.sh", "scripts/lib/node-binaries.sh", "scripts/publish-lua-tree.sh", "scripts/lib/lua-tree.sh" }) do
  must("mkdir -p " .. repo .. "/" .. (relative:match("^(.*)/[^/]+$") or "."), "mkdir for " .. relative)
  must("cp -f " .. tree_root .. "/" .. relative .. " " .. repo .. "/" .. relative, "copy " .. relative)
end
must("git add -A && git commit -q -m fastlane-fixtures", "commit the fastlane fixtures", repo)

local function classify(paths)
  local command = "bash scripts/lib/land-classify.sh --repo " .. repo
  for _, path in ipairs(paths) do command = command .. " " .. path end
  return must(command, "classify", repo)
end
local function category_of(paths)
  local command = "bash scripts/lib/land-classify.sh --category --repo " .. repo
  for _, path in ipairs(paths) do command = command .. " " .. path end
  return (must(command, "category", repo):gsub("%s+$", ""))
end

-- 18a. The four classes, on paths whose answer is not a guess.
eq(category_of({ "docs/LAND.md", "skills/x/SKILL.md" }), "docs-only", "markdown is the docs path")
eq(category_of({ "lua/core/agent.lua", "ui/app.js", "scripts/fast.sh" }), "lua-scripts-only",
  "the Lua tree, the UI and the scripts are the lua path")
eq(category_of({ "rust/components/wa-whatsapp/src/lib.rs", "components.lock" }), "components",
  "a component's own crate and its pins are the components path")
eq(category_of({ "lua/core/agent.lua", "rust/wa-host/src/main.rs" }), "compiled", "the strongest class wins")
eq(category_of({ "rust/components/graph/src/lib.rs", "rust/wa-whatsapp-outbox/src/lib.rs" }), "compiled",
  "a crate the NODE also compiles is compiled even though a component uses it")
contains(classify({ "rust/components/graph/src/lib.rs" }), "component\trust/components/graph/src/lib.rs",
  "one line per path, class then path")
-- The classification IS `wa_compiled_input`, not a second opinion about it: the same function the deploy's Lua
-- fast path and the release digest use decides here.
contains(classify({ "rust/wa-host/src/main.rs" }), "compiled\trust/wa-host/src/main.rs", "rust/ is compiled")
contains(classify({ "docs/LAND.md" }), "docs\tdocs/LAND.md", "a document is not compiled")

-- 18b. The steps each path skips, and the artifact each one builds.
local function steps_of(category) return land.plan_steps(category) end
eq(steps_of("docs-only").artifacts.action, "skip", "docs-only builds nothing")
eq(steps_of("docs-only").deploy.action, "skip", "docs-only deploys nothing")
eq(steps_of("docs-only").sign.action, "skip", "docs-only signs nothing")
contains(steps_of("docs-only").deploy.why, "docs-only", "the skip says why")
eq(steps_of("lua-scripts-only").artifacts.kind, "lua-tree", "the lua path writes a tree record")
eq(steps_of("lua-scripts-only").ship.action, "skip", "the lua path ships no node release")
eq(steps_of("lua-scripts-only").deploy.action, "run", "the lua path deploys the tree to every node")
eq(steps_of("components").artifacts.kind, "components", "the components path rebuilds the bundle")
eq(steps_of("components").deploy.action, "run", "and deploys the repinned components")
for _, name in ipairs({ "artifacts", "sign", "ship", "publish", "deploy" }) do
  eq(steps_of("compiled")[name].action, "run", "the compiled path runs " .. name)
end

-- 18c. The gate: the always-on checks are never dropped, a path adds only what it touches, and a changed Lua
-- module maps to the rows that mention it (proved by grep on the fixture, not by a naming convention alone).
local function gate_for(paths)
  local wanted = land.gate_checks_for(paths)
  local names = {}
  for _, name in ipairs({ "fast", "prompt-docs", "codemode-component", "cargo-codemode", "cargo-wa-whatsapp" }) do
    if wanted[name] then names[#names + 1] = name end
  end
  return table.concat(names, ",")
end
eq(gate_for({ "docs/LAND.md" }), "fast,prompt-docs", "a document runs the fast path and the prompt-docs check only")
eq(gate_for({ "rust/components/wa-whatsapp/src/lib.rs" }), "fast,prompt-docs,cargo-wa-whatsapp",
  "the WhatsApp component's crate brings its own check")
eq(gate_for({ "lua/core/codemode.lua" }), "fast,prompt-docs,codemode-component,cargo-codemode",
  "a code-mode path brings its two checks")

-- A changed module maps to rows: the fixture carries one row that names `lua/core/agent.lua` and one that does
-- not, and only the first may be planned.
-- The fixture carries the REAL row inventory (scripts/lib/fast-rows.sh): the planner reads the rows a round may
-- request from it (the function scripts/fast.sh builds its lua.list with), so a fixture without it can prove
-- nothing about narrowing.
must("mkdir -p scripts/lib", "fixture lib dir", repo)
write_file(repo .. "/scripts/lib/fast-rows.sh", read_file(tree_root .. "/scripts/lib/fast-rows.sh") or "")
must("mkdir -p scripts lua/core", "fixture dirs", repo)
write_file(repo .. "/lua/core/agent.lua", "return {}\n")
write_file(repo .. "/scripts/test-agent-thing.lua", "-- mentions lua/core/agent.lua\n")
write_file(repo .. "/scripts/test-unrelated-thing.lua", "-- mentions nothing\n")
write_file(repo .. "/scripts/test-fast-row-environment.lua", "-- the core row\n")
must("git add -A && git commit -q -m rows", "commit the rows", repo)
local row_run = { id = "rows", journal = { repo = repo, base = "HEAD~1", branches = { { name = "x", sha = "HEAD" } } } }
local rows = land.gate_rows(row_run, { "lua/core/agent.lua" })
eq(#rows, 1, "one row mentions the changed module")
eq(rows[1], "scripts/test-agent-thing.lua", "and it is the one the grep found")
eq(#land.gate_rows(row_run, { "lua/core/agent.lua", "scripts/test-unrelated-thing.lua" }), 2,
  "a changed row is planned too")
eq(#land.gate_rows(row_run, { "docs/LAND.md" }), 0, "no row maps to a document, which makes the run whole")
-- 18c-2. ONE row inventory. The planner requests only rows this fast path would run, and a row the ledger
-- declares not run is REPORTED with its reason, never requested - requesting it is `fast_narrow:unknown_row`
-- and a round gated on zero tests (measured twice: land-20261118T172243Z-666a59cf, land-20261118T173351Z-2a481142).
write_file(repo .. "/scripts/fast-path.exclude",
  "scripts/test-agent-thing.lua  # needs a ledger the fast path has not got\n" ..
  "scripts/test-agent-unrunnable.lua  # needs a real raw terminal\n")
write_file(repo .. "/scripts/test-agent-live.lua", "-- mentions lua/core/agent.lua\n")
write_file(repo .. "/scripts/test-agent-unrunnable.lua", "-- mentions lua/core/agent.lua\n")
must("git add -A && git commit -q -m inventory", "commit the inventory", repo)
local planned, not_planned = land.gate_rows(row_run, { "lua/core/agent.lua" })
eq(#planned, 1, "only a row this fast path would run is requested")
eq(planned[1], "scripts/test-agent-live.lua", "and it is the live one")
eq(#not_planned, 2, "the declared rows are reported as not a gate row")
local why_of = {}
for _, entry in ipairs(not_planned) do why_of[entry.path] = entry.why end
contains(why_of["scripts/test-agent-thing.lua"] or "", "needs a ledger", "the report carries the ledger's reason")
contains(why_of["scripts/test-agent-unrunnable.lua"] or "", "raw terminal", "and the reason of a row found by name")
-- A changed path that IS a test the ledger declares not run: not requested, reported with the reason.
local only_declared, declared_report = land.gate_rows(row_run, { "scripts/test-agent-thing.lua" })
eq(#only_declared, 0, "a changed test the ledger declares not run is never requested")
eq(#declared_report, 1, "it is reported instead")
contains(declared_report[1] and declared_report[1].why or "", "needs a ledger", "with the ledger's reason")
local narrowed_text = land.plan_text({ plan = { files = 1, category = "lua-scripts-only", counts = {},
  classifier = "land-classify.sh", checks = { "fast" }, rows = planned, not_rows = not_planned, full = false } })
contains(narrowed_text, "not a gate row: scripts/test-agent-thing.lua (needs a ledger", "the plan reports it by name")
contains(narrowed_text, "over 1 Lua row(s)", "and asks for exactly one row")
-- The list the plan produces is a request `scripts/fast.sh` ACCEPTS: the real filter, the real candidate list,
-- over the rows this plan chose.
write_file(fixture .. "/rows.txt", table.concat(planned, "\n") .. "\n")
must("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_candidates' > " .. fixture .. "/candidates.txt",
  "candidate list", repo)
local accepted, accepted_out, accepted_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates.txt " .. fixture .. "/rows.txt'", repo)
eq(accepted, 0, "the planned rows are a request fast.sh accepts (" .. tostring(accepted_err) .. ")")
contains(accepted_out, "scripts/test-agent-live.lua", "the run would execute the planned row")
contains(accepted_out, "scripts/test-fast-row-environment.lua", "with the always-on core rows the runner adds")
-- The request the planner used to make - a declared row in it - is the refusal those two landings met, so the
-- two lists differ by a verdict and not by taste.
write_file(fixture .. "/rows-declared.txt", "scripts/test-agent-thing.lua\n")
local refused, _, refused_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates.txt " .. fixture .. "/rows-declared.txt'", repo)
eq(refused, 2, "a request naming the declared row is refused, so nothing runs")
contains(refused_err, "fast_narrow:unknown_row", "by the name the two measured landings hit")

-- 18c-3. `--full` means the whole suite: no WA_FAST_ROWS file, and every check. The rows file itself is
-- proved against the MERGED TREE (18c-4 below), so these cases carry a real one.
must("mkdir -p " .. land.run_dir("rows-full") .. " " .. land.run_dir("rows-plan-full"), "rows dirs")
local narrowed_plan = { plan = { rows = { "scripts/test-agent-live.lua" }, full = false } }
eq(land.gate_rows_file({ id = "rows-full", tree = repo, journal = narrowed_plan }, { full = true }), nil,
  "--full writes no rows file")
eq(read_file(land.run_dir("rows-full") .. "/gate-rows.txt"), nil, "and none exists on disk for that round")
eq(land.gate_rows_file({ id = "rows-plan-full", tree = repo, journal = { plan = { rows = {}, full = true } } }, {}), nil,
  "a plan that already runs the whole suite writes none either")
local full_checks, full_why = land.gate_checks({ journal = { plan = { checks = { "fast" } } } }, { full = true })
eq(#full_checks, #land.DEFAULT_CHECKS, "--full runs every gate check, not the narrowed set")
contains(full_why, "--full", "and the gate says so")
-- 18c-4. The rows file is proved against the MERGED TREE, never the planner's checkout.
--
-- WHY. The plan is made before anything is merged, from the operator's checkout (journal.repo);
-- scripts/fast.sh runs in the merged worktree (run.tree). The two lists disagree in both directions and each
-- disagreement was a broken gate:
--
--   * a branch that ADDS scripts/test-new.lua is not a row the planner's checkout has, so the plan said "not a
--     gate row" and the branch's own new test never ran - a narrowed gate that silently dropped the row the
--     change brought with it;
--   * a branch that ADDS an exclude line (or DELETES a row) left the plan requesting a row the merged tree's
--     runner refuses: fast_narrow:unknown_row, and the whole round gated on zero tests.
--
-- The merged tree is built the way impl.merge builds one: a worktree of the base with the branch merged in.
local rows_ref = must("git -C " .. repo .. " rev-parse --abbrev-ref HEAD")
local rows_base = must("git -C " .. repo .. " rev-parse HEAD")
local function merged_row_tree(name, edit)
  local branch = "change/" .. name
  must("git -C " .. repo .. " checkout -q -B " .. branch .. " " .. rows_base, "branch " .. branch)
  edit()
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m " .. name, "commit " .. name)
  local sha = must("git -C " .. repo .. " rev-parse HEAD")
  local tree = fixture .. "/merged-" .. name
  must("git -C " .. repo .. " worktree add --quiet -b land-" .. name .. " " .. tree .. " " .. rows_base,
    "worktree for " .. name)
  must("git -C " .. tree .. " merge --no-ff --no-edit -m " .. name .. " " .. sha, "merge " .. name)
  -- The planner's checkout keeps the base: it must NOT hold what only the branch has.
  must("git -C " .. repo .. " checkout -q --detach " .. rows_base, "leave the base checked out")
  return sha, tree
end
local function rows_run(id, tree, sha, rows)
  must("mkdir -p " .. land.run_dir(id), "run dir " .. id)
  return { id = id, tree = tree, journal = { repo = repo, base = rows_base,
    branches = { { name = "change/x", sha = sha } }, plan = { rows = rows, checks = { "fast" }, full = false } } }
end

-- The branch ADDS a test row. The planner's checkout cannot see it...
local added_sha, added_tree = merged_row_tree("newrow", function()
  write_file(repo .. "/scripts/test-new-agent-row.lua", "-- mentions lua/core/agent.lua\n")
end)
local planner_run = { id = "rows-planner", journal = { repo = repo, base = rows_base,
  branches = { { name = "change/newrow", sha = added_sha } } } }
local planner_rows, planner_not = land.gate_rows(planner_run, { "lua/core/agent.lua", "scripts/test-new-agent-row.lua" })
eq(table.concat(planner_rows, " "), "scripts/test-agent-live.lua",
  "the planner's checkout maps the changed module to the one runnable row it has")
local planner_why = {}
for _, entry in ipairs(planner_not) do planner_why[entry.path] = entry.why end
contains(planner_why["scripts/test-new-agent-row.lua"] or "", "not a row this fast path runs",
  "and reports the branch's own new row as not a gate row, by name")
-- ...and the gate asks for it anyway, because the merged tree HAS it as a row.
local added_run = rows_run("rows-added", added_tree, added_sha, { "scripts/test-agent-live.lua" })
local added_file, added_failed, added_notes = land.gate_rows_file(added_run, {})
ok(added_file ~= nil and not added_failed, "a narrowed round gets a WA_FAST_ROWS file")
local added_text = read_file(added_file) or ""
contains(added_text, "scripts/test-agent-live.lua", "holding the rows the plan chose")
contains(added_text, "scripts/test-new-agent-row.lua", "AND the row the branch added, which the planner's checkout cannot see")
contains(table.concat(added_notes, " | "), "scripts/test-new-agent-row.lua", "and the evidence names what it asks for")
must("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_candidates' > " .. fixture .. "/candidates-added.txt",
  "the merged tree's candidate list", added_tree)
local added_code, added_out, added_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates-added.txt " .. added_file .. "'", added_tree)
eq(added_code, 0, "the merged tree's own filter accepts the request (" .. tostring(added_err) .. ")")
contains(added_out, "scripts/test-new-agent-row.lua", "so the branch's own new row really runs")

-- The branch ADDS an exclude line: a row the plan asked for is no longer a row the merged tree can run.
local excluded_sha, excluded_tree = merged_row_tree("excluder", function()
  write_file(repo .. "/scripts/fast-path.exclude",
    "scripts/test-agent-thing.lua  # needs a ledger the fast path has not got\n" ..
    "scripts/test-agent-unrunnable.lua  # needs a real raw terminal\n" ..
    "scripts/test-agent-live.lua  # this round excludes it\n")
end)
-- One runnable row left: it is requested, the excluded one is dropped BY NAME.
local two_run = rows_run("rows-two", excluded_tree, excluded_sha,
  { "scripts/test-agent-live.lua", "scripts/test-fast-row-environment.lua" })
local two_file, two_failed, two_notes = land.gate_rows_file(two_run, {})
ok(two_file ~= nil and not two_failed, "a round with one runnable row left is still narrowed")
local two_text = read_file(two_file) or ""
contains(two_text, "scripts/test-fast-row-environment.lua", "the runnable row is requested")
ok(two_text:find("scripts/test-agent-live.lua", 1, true) == nil,
  "the row the merged tree excludes is NOT requested (got " .. two_text .. ")")
local two_why = table.concat(two_notes, " | ")
contains(two_why, "scripts/test-agent-live.lua", "the dropped row is named in the evidence")
contains(two_why, "this round excludes it", "with the ledger's own reason")
-- Nothing left: no rows file at all, so the whole suite runs.
local none_run = rows_run("rows-none", excluded_tree, excluded_sha, { "scripts/test-agent-live.lua" })
local none_file, _, none_notes = land.gate_rows_file(none_run, {})
eq(none_file, nil, "a round whose only row the merged tree excludes writes no rows file")
eq(read_file(land.run_dir("rows-none") .. "/gate-rows.txt"), nil, "and none exists on disk")
local none_why = table.concat(none_notes, " | ")
contains(none_why, "the whole suite runs", "the gate says the whole suite runs")
contains(none_why, "scripts/test-agent-live.lua", "and names the row it dropped")
-- The stale list the plan would have written is exactly what the merged tree refuses: this is the failure.
write_file(fixture .. "/rows-stale.txt", "scripts/test-agent-live.lua\n")
must("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_candidates' > " .. fixture .. "/candidates-excluded.txt",
  "the excluded tree's candidate list", excluded_tree)
local stale_code, _, stale_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates-excluded.txt " .. fixture .. "/rows-stale.txt'", excluded_tree)
eq(stale_code, 2, "the pre-merge request really is refused, so nothing would run")
contains(stale_err, "fast_narrow:unknown_row", "by the name this case prevents")
-- And no merged tree at all is no proof of anything: the whole suite runs.
local no_tree, _, no_tree_notes = land.gate_rows_file({ id = "rows-notree", journal = narrowed_plan }, {})
eq(no_tree, nil, "without a merged tree no row is proved runnable")
contains(table.concat(no_tree_notes or {}, " | "), "the whole suite runs", "and the gate says so")
must("git -C " .. repo .. " checkout -q " .. rows_ref, "restore the fixture checkout")

-- 18c-5. The fast check ALWAYS carries WA_FAST_ROWS, empty when the round narrowed nothing: scripts/fast.sh
-- narrows only on a NON-EMPTY WA_FAST_ROWS ([ -n "$WA_FAST_ROWS" ]), so one inherited from the environment
-- would narrow a --full run that wrote no rows file - a run executing less than it said, obeying somebody
-- else's plan.
eq(land.gate_command({ name = "fast", command = "bash scripts/fast.sh" }, nil),
  "WA_FAST_ROWS= bash scripts/fast.sh", "no rows file means an EMPTY WA_FAST_ROWS, not an absent one")
eq(land.gate_command({ name = "fast", command = "bash scripts/fast.sh" }, "/tmp/rows.txt"),
  "WA_FAST_ROWS='/tmp/rows.txt' bash scripts/fast.sh", "a narrowed round names its file")
eq(land.gate_command({ name = "cargo-codemode", command = "cargo test" }, nil), "cargo test",
  "and no other check is touched")
local env_probe = fixture .. "/rows-env.sh"
write_file(env_probe, "#!/usr/bin/env bash\nprintf '%s\n' \"$WA_FAST_ROWS\"\n")
eq(must("env WA_FAST_ROWS=" .. fixture .. "/inherited.txt bash " .. env_probe), fixture .. "/inherited.txt",
  "an inherited WA_FAST_ROWS really does reach a check that does not set it")
eq(must("env WA_FAST_ROWS=" .. fixture .. "/inherited.txt " ..
  land.gate_command({ name = "fast", command = "bash " .. env_probe }, nil)), "",
  "and the empty assignment the gate always makes removes it")
-- At the gate: the command it actually runs, on both paths.
local saved_gate_exec = land.exec
local gate_commands = {}
-- Only the gate's own checks are answered here (they are held to their command); everything else - the row
-- inventory the rows file is proved with, the git calls - still runs for real.
local function is_gate_check(command)
  for _, marker in ipairs({ "scripts/fast.sh", "scripts/test-codemode-component.sh", "scripts/gate-cargo-codemode.sh", "cargo test", "sync-prompt-docs" }) do
    if command:find(marker, 1, true) then return true end
  end
  return false
end
land.exec = function(command, cwd, timeout)
  if not is_gate_check(command) then return saved_gate_exec(command, cwd, timeout) end
  gate_commands[#gate_commands + 1] = command
  return { code = 0, stdout = "test result: ok. 3 passed\n", stderr = "" }
end
local saved_weight = land.weight_decorator
land.weight_decorator = ""
eq(land.impl.gate(added_run, {}), true, "a narrowed gate runs")
eq(gate_commands[1], "WA_FAST_ROWS='" .. land.run_dir("rows-added") .. "/gate-rows.txt' bash scripts/fast.sh",
  "the narrowed gate runs the fast check with the round's rows file (got " .. tostring(gate_commands[1]) .. ")")
gate_commands = {}
eq(land.impl.gate(added_run, { full = true }), true, "a --full gate runs")
eq(gate_commands[1], "WA_FAST_ROWS= bash scripts/fast.sh",
  "--full runs the fast check with WA_FAST_ROWS EMPTY (got " .. tostring(gate_commands[1]) .. ")")
contains(read_file(land.evidence_path("rows-added", "gate")) or "", "WA_FAST_ROWS=",
  "and the evidence logs the command that ran, not one it might have run")
land.exec = saved_gate_exec
land.weight_decorator = saved_weight

do
  -- 18c-6. A `git diff` that FAILS is not a round that changed nothing. M.changed_paths answered an empty list
  -- for a broken diff, which the plan read as "nothing to land" and the rows file as "no row to add" - so an
  -- unreadable git could refuse a landing, or narrow a gate, with no line anywhere saying so. The list now carries
  -- a named note, and every caller that would narrow on it runs the whole suite instead.
  local broken_sha = "0000000000000000000000000000000000000000"
  local function broken_journal()
    return { repo = repo, base = broken_sha, branches = { { name = "change/unreadable", sha = rows_base } } }
  end
  local broken_paths, broken_notes = land.changed_paths({ journal = broken_journal() })
  eq(#broken_paths, 0, "a diff that cannot be read yields no path")
  eq(#broken_notes, 1, "and one note instead of a silence")
  contains(broken_notes[1] or "", "change/unreadable", "the note names the branch whose diff failed")
  contains(broken_notes[1] or "", "could not be read", "and says what happened to it")
  -- The gate: the rows file it would have written is a request the merged tree refuses (18c-4), so the whole
  -- suite runs and the evidence names the failure.
  must("mkdir -p " .. land.run_dir("rows-unreadable") .. " " .. land.run_dir("plan-unreadable"), "unreadable run dirs")
  local unreadable_run = { id = "rows-unreadable", tree = repo, journal = broken_journal() }
  unreadable_run.journal.plan = { rows = { "scripts/test-agent-live.lua" }, checks = { "fast" }, full = false }
  local unreadable_file, _, unreadable_why = land.gate_rows_file(unreadable_run, {})
  eq(unreadable_file, nil, "an unreadable diff writes no rows file")
  eq(read_file(land.run_dir("rows-unreadable") .. "/gate-rows.txt"), nil, "and none exists on disk")
  local unreadable_text = table.concat(unreadable_why or {}, " | ")
  contains(unreadable_text, "could not be read", "the gate names the failure in its evidence")
  contains(unreadable_text, "the whole suite runs", "and says the whole suite runs")
  -- The plan: not the "nothing to land" refusal a broken git used to produce, and not a narrowed plan either.
  local broken_plan = land.build_plan({ journal = broken_journal() }, {}, broken_notes)
  eq(broken_plan.full, true, "a plan built on an unreadable diff runs the whole suite")
  eq(#broken_plan.checks, #land.DEFAULT_CHECKS, "with every gate check")
  eq(#broken_plan.rows, 0, "and no row it cannot prove")
  contains(tostring(broken_plan.unknown_paths or ""), "could not be read", "the plan records why")
  local broken_text = land.plan_text({ plan = broken_plan })
  contains(broken_text, "the changed paths could not be read", "the printed plan says the count is unknown")
  ok(broken_text:find("0 path(s) changed", 1, true) == nil, "and prints no file count it does not have")
  -- The door the operator uses: impl.plan answers a plan (and an evidence line), never "no changes".
  local plan_run = { id = "plan-unreadable", journal = broken_journal() }
  eq(land.impl.plan(plan_run, {}), true, "a round whose diff cannot be read still plans")
  eq(plan_run.journal.plan and plan_run.journal.plan.full, true, "onto the full path")
  contains(read_file(land.evidence_path("plan-unreadable", "plan")) or "", "could not be read",
    "and the failure is in the plan's own evidence")
  -- A diff that CAN be read is untouched: no note, and no path invented.
  local readable_paths, readable_notes = land.changed_paths({ journal = { repo = repo, base = rows_base,
    branches = { { name = "change/readable", sha = rows_base } } } })
  eq(#readable_paths, 0, "the base against itself changes no path")
  eq(#readable_notes, 0, "and a diff that worked has nothing to report")
end

-- 18d. The deploy's waves: canary alone, the middle together, the account node last.
local function wave_names(plan)
  local parts = {}
  for index, wave in ipairs(plan.waves) do
    local names = {}
    for _, entry in ipairs(wave) do names[#names + 1] = tostring(entry.node) end
    parts[index] = table.concat(names, "+")
  end
  return table.concat(parts, " | ")
end
local route = land.deploy_waves(land.RING, {})
eq(wave_names(route), "work | mail+nextcloud | openclaw",
  "the canary goes first alone, the middle goes together, the account node goes last")
eq(route.canary, "work", "the default canary is work")
eq(route.account, "openclaw", "the default account node is openclaw")
eq(route.canary_defaulted, nil, "a ring that names the canary does not default it")
local named = land.deploy_waves(land.RING, { canary = "nextcloud", account = "mail" })
eq(wave_names(named), "nextcloud | work+openclaw | mail", "the canary and the account node are knobs, not constants")
local ringless = land.deploy_waves({ { node = "a", mode = "tree" }, { node = "openclaw", mode = "tree" } }, {})
eq(wave_names(ringless), "a |  | openclaw", "a ring without `work` still gets a canary (the first non-account node)")
eq(ringless.canary_defaulted, true, "and the plan says the canary defaulted")
eq(#land.deploy_waves(land.RING, { canary = "work", account = "work" }).waves[3], 0,
  "a canary that IS the account node is not deployed twice")

-- 18e. A cost estimate and a report that compares: written once, read back from the journal.
local estimate = land.estimate("docs-only", {})
ok(estimate.seconds > 0, "the estimate is a number even with no history")
eq(estimate.per_step.deploy, 0, "the docs path expects no deploy at all")
eq(estimate.per_step.artifacts, 0, "and no build")
ok(estimate.per_step.gate > 0, "the gate is never free")
contains(estimate.from, "13/11", "with no finished run the estimate says where its numbers come from")
-- A journal with two finished runs is what the next plan measures against.
for index, seconds in ipairs({ 100, 300 }) do
  local id = "history" .. index
  write_file(land.journal_path(id), json.encode({ run = id, result = "done", created_at = 1, updated_at = 1,
    steps = { gate = { name = "gate", state = "done", seconds = seconds } },
    plan = { category = "lua-scripts-only" } }))
end
local measured = land.estimate("lua-scripts-only", land.land_runs())
eq(measured.per_step.gate, 200, "the gate's median comes from the journal, not from the fallback table")
contains(measured.from, "median", "and the plan says it was measured")
local average = land.journal_average(land.land_runs())
ok(average ~= nil and average.average > 0, "the report's comparison has a number to compare with")
ok(average.runs >= 2, "over the finished runs only (earlier cases in this row are finished runs too)")

-- 18f. The report names the path, the per-step time, the total and the journal's average.
local report_text = land.report_text({ run = "report-check", result = "done", plan = { category = "lua-scripts-only",
  expected_seconds = 600, expected_from = "median of 2 finished run(s)" },
  steps = { gate = { state = "done", seconds = 120 }, artifacts = { state = "done", seconds = 30 } },
  deploy_plan = { canary = "work", account = "openclaw", waves = { { "work" }, { "mail", "nextcloud" }, { "openclaw" } } },
  deploy = { { node = "work", mode = "tree", wave = 1, state = "installed", seconds = 12 } } })
contains(report_text, "## cost", "the report has a cost table")
contains(report_text, "`lua-scripts-only`", "it names the path the round took")
contains(report_text, "total | 2m30s", "it states the total in the same units as the plan")
contains(report_text, "journal average", "and the journal's average to compare with")
contains(report_text, "deploy order: canary work -> parallel mail+nextcloud -> account openclaw",
  "the report names the deploy's waves")

local function cases_19_11()
  -- THE 19/11 CASES LIVE IN THEIR OWN FUNCTION. Lua allows 200 locals per function and this row was
  -- already at the limit; the cases share the outer fixtures as upvalues and add no register to the
  -- function that runs the whole row.
-- ---------------------------------------------------------------- case 24: a bare --resume finds the run
-- `wa land --resume` with no run named continues the newest unfinished run. It did not: the listing was
-- `ls -1dt '<root>'/*/journal.json`, and a glob inside quotes is never expanded, so the answer was always
-- "nothing to resume" with a stopped run sitting in the directory (item 24).
setup_fixture()
land.candidates = function() return {} end
write_file(fixture .. "/land-gate/gate-red.sh", "#!/usr/bin/env bash\nexit 1\n")
must("chmod +x " .. fixture .. "/land-gate/gate-red.sh", "the red gate runs")
local red_checks = function()
  return { { name = "fast", command = "bash " .. fixture .. "/land-gate/gate-red.sh", timeout = 60 } }
end
local stopped_code = land.run({ run = "case24", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = red_checks() })
eq(stopped_code, 1, "the red gate stops the round")
eq(journal_of("case24").result, "stopped", "and the run is recorded stopped")
local resumed_code = land.run({ resume = true, checks = standard_checks() })
eq(resumed_code, 0, "a bare --resume continues the stopped run and finishes it")
eq(journal_of("case24").result, "done", "the run it continued is the one on disk")
contains(step_of("case24", "gate").detail or "", "passed", "the gate of the continued run is the green one")

-- ---------------------------------------------------------------- case 25: the landing branch is free
-- A landing leaves `land<N>/final` on the incoming repository. A second landing that picks the same N pushes
-- on top of another round's ref, and the push step reads that ref back expecting its own commit (item 25).
setup_fixture()
must("git -C " .. repo .. " push -q oc-in main:refs/heads/land7/final", "another round already used land7")
local number_code = land.run({ run = "case25", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(number_code, 0, "a round lands while land7/final is on the incoming remote")
eq(journal_of("case25").land_branch, "land8/final", "the number is taken from the remote too, never reused")

-- ---------------------------------------------------------------- case 26: main and publish on a named node
-- The GitHub credential is on ONE node; --account names it, and the push and the release are done there
-- (`gh auth status` is what proves the credential, not `command -v gh`).
setup_fixture()
land.candidates = function() return {} end
routed_calls = {}
behaviour.gh_authed = true
behaviour.gh_present = true
local account_code = land.run({ run = "case26", signer = "local", ring = SOLO_RING, account = "laptop", branches = { "change/one" }, checks = standard_checks() })
eq(account_code, 0, "a round with --account lands")
local account_journal = journal_of("case26")
eq(account_journal.main_account, "laptop", "main was fast-forwarded on the named node")
eq(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), account_journal.tree_commit .. "\trefs/heads/main",
  "and the source of truth is at the landed tip")
local main_on_node, publish_on_node = false, false
for _, call in ipairs(routed_calls) do
  if call.node == "laptop" and call.kind == "main" then main_on_node = true end
  if call.node == "laptop" and call.kind == "publish" then publish_on_node = true end
end
ok(main_on_node, "the main push ran on laptop, not here")
ok(publish_on_node, "the release was created on laptop")
eq(account_journal.publish.account, "laptop", "the journal names the account that published")
-- A `gh` that exists but is not signed in is not a credential.
setup_fixture()
routed_calls = {}
behaviour.gh_authed = false
local noauth_code = land.run({ run = "case26b", signer = "local", ring = SOLO_RING, account = "laptop", branches = { "change/one" }, checks = standard_checks() })
eq(noauth_code, 1, "a signed-out gh stops the publish")
eq(step_of("case26b", "publish").error, "publish_needs_credentials", "the refusal is named")
contains(step_of("case26b", "publish").observed or "", "laptop", "and it names the node whose gh is not signed in")
local published_anyway = false
for _, call in ipairs(routed_calls) do if call.kind == "publish" then published_anyway = true end end
ok(not published_anyway, "nothing was published by a node that is not signed in")
behaviour.gh_authed = true

-- ---------------------------------------------------------------- case 27: mark a step done out of band
-- A release created by hand must reach the journal by a VERB that re-verifies it, not by editing
-- journal.json. `wa land mark <step> --evidence <file>`: no evidence, no mark; a claim the world does not
-- support, no mark; a verified claim, a mark with `marked` and the evidence path on the step (item 27).
setup_fixture()
behaviour.release_present = true
local quiet_exec = land.exec
land.exec = function(command, cwd, timeout)
  if command:match("^command %-v gh") then return { code = 0, stdout = "no\n", stderr = "" } end
  return quiet_exec(command, cwd, timeout)
end
local blocked_code = land.run({ run = "case27", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(blocked_code, 1, "the round stops where gh is missing")
eq(step_of("case27", "publish").state, "failed", "at the publish step")
local evidence_path = fixture .. "/publish-evidence.txt"
write_file(evidence_path, "release node-... created by hand on the account node\n")
local no_evidence_ok, no_evidence = land.mark("case27", "publish", nil, {})
eq(no_evidence_ok, false, "a mark with no evidence is refused")
eq(no_evidence.error, "mark_evidence_required", "by name")
local missing_ok, missing_answer = land.mark("case27", "publish", fixture .. "/absent.txt", {})
eq(missing_ok, false, "a mark naming a file that does not exist is refused")
eq(missing_answer.error, "mark_evidence_missing", "by name")
-- The world does not support the claim yet: the release is not there.
behaviour.release_present = false
local false_ok, false_answer = land.mark("case27", "publish", evidence_path, {})
eq(false_ok, false, "a mark the world contradicts is refused")
eq(false_answer.error, "mark_not_verified", "and the refusal says the claim could not be verified")
eq(step_of("case27", "publish").state, "failed", "the step is untouched by a refused mark")
-- Now it is there, and the mark records it - with the evidence path and the flag.
behaviour.release_present = true
local mark_ok, mark_answer = land.mark("case27", "publish", evidence_path, {})
ok(mark_ok, "a verified mark is recorded: " .. tostring(mark_answer and (mark_answer.error or mark_answer.detail) or ""))
local marked_step = step_of("case27", "publish")
eq(marked_step.state, "done", "the step is done in the journal")
eq(marked_step.marked, true, "and it says it was marked")
eq(marked_step.mark_evidence, evidence_path, "naming the file that proves it")
local marked_journal = journal_of("case27")
eq(marked_journal.publish and marked_journal.publish.tag, "node-" .. tostring(marked_journal.tree_commit):sub(1, 12),
  "the publish record the step would have written is written")
local again_ok, again = land.mark("case27", "publish", evidence_path, {})
eq(again_ok, false, "marking a finished step again is refused")
eq(again.error, "mark_already_settled", "by name")
land.exec = quiet_exec

-- ---------------------------------------------------------------- case 28: the start options are the run's
-- A resume is the same round continued, so the ring and --no-deploy it started with still hold: measured
-- 18/11, a resumed round took the DEFAULT ring and deployed a node the operator had left out (item 28).
setup_fixture()
deploy_requests = {}
write_file(fixture .. "/land-gate/gate-red.sh", "#!/usr/bin/env bash\nexit 1\n")
must("chmod +x " .. fixture .. "/land-gate/gate-red.sh", "the red gate runs")
local one_node_ring = { { node = "work", mode = "tree" } }
eq(land.run({ run = "case28", signer = "local", ring = one_node_ring, no_deploy = false, full = true,
  branches = { "change/one" }, checks = red_checks() }), 1, "the round stops at the red gate")
local started = journal_of("case28").start
ok(type(started) == "table", "the journal stores the start options")
eq(started.full, true, "--full is one of them")
eq(started.ring and started.ring[1] and started.ring[1].node, "work", "and the ring, resolved")
deploy_requests = {}
eq(land.run({ resume = true, checks = standard_checks() }), 0, "the resume finishes the round")
local rang = {}
for _, request in ipairs(deploy_requests) do rang[request.node] = true end
ok(rang["work"], "the resumed round deployed the canary")
ok(not rang["openclaw"] and not rang["mail"] and not rang["nextcloud"],
  "and only the ring it started with - not the default ring of four nodes")
-- A node an operator pinned is never moved by a ring silently.
setup_fixture()
deploy_requests = {}
local pins = dofile("lua/core/pins.lua")
pins.set({ node = "work", kind = "operator", state = "active", reason = "operator test pin" })
local pinned_code = land.run({ run = "case28b", signer = "local", ring = one_node_ring, branches = { "change/one" }, checks = standard_checks() })
eq(pinned_code, 1, "a ring that would move a pinned node stops")
eq(step_of("case28b", "deploy").error, "node_pinned", "the refusal is the pin, by name")
contains(step_of("case28b", "deploy").detail or "", "active operator pin", "and it says the node is pinned")
local asked_pinned = false
for _, request in ipairs(deploy_requests) do if request.node == "work" then asked_pinned = true end end
ok(not asked_pinned, "nothing was asked of the pinned node")
pins.clear("work", { kind = "released", reason = "test done" })

-- ---------------------------------------------------------------- case 18: one row inventory
-- The planner and scripts/fast.sh ask the SAME function for the rows a narrowed run may execute; a planner
-- with its own idea of runnable asks for a row the runner refuses, which is a round gated on zero tests.
local inventory = land.row_inventory(tree_root)
local fast_rows = must("bash -c '. ./scripts/lib/fast-rows.sh && wa_fast_row_candidates'", "the runner's rows", tree_root)
local fast_set, planner_set = {}, {}
for row in tostring(fast_rows):gmatch("[^\r\n]+") do fast_set[row] = true end
for _, row in ipairs(inventory.list or {}) do planner_set[row] = true end
local only_planner, only_fast = 0, 0
for row in pairs(planner_set) do if not fast_set[row] then only_planner = only_planner + 1 end end
for row in pairs(fast_set) do if not planner_set[row] then only_fast = only_fast + 1 end end
eq(only_planner, 0, "every row the planner would request is a row the runner executes")
eq(only_fast, 0, "and every row the runner executes is one the planner knows")
-- ---------------------------------------------------------------- case 30: the pins move in a compiled round
-- A compiled round that ALSO moves components.lock builds the components bundle inside the `artifacts` step,
-- before any node takes the lock (item 28): building it afterwards describes a lock the fleet already reads,
-- and a node that takes both would take the new pins with the old bundle. On the base commit
-- `also_components` does not exist at all, so nothing marks such a round. The classifier and the row
-- inventory are the REAL ones - this asks the tree the row runs from, not a fixture.
local pinned_plan = land.build_plan({ id = "case30", journal = { repo = tree_root } },
  { "components.lock", "rust/Cargo.toml" })
eq(pinned_plan.category, "compiled", "a compiled change that also moves the pins is a compiled round")
contains(tostring(pinned_plan.steps.artifacts.also_components or ""), "components.lock",
  "and its artifacts step says the components bundle is built with the node release")
local plain_plan = land.build_plan({ id = "case30b", journal = { repo = tree_root } }, { "rust/Cargo.toml" })
eq(plain_plan.category, "compiled", "a compiled change that moves no pin is still compiled")
eq(plain_plan.steps.artifacts.also_components, nil, "and it builds no components bundle")
-- ------------------------------------------------ case 31: a Lua-only round still ships a release for a
-- release-installed node (review r1 #61). A node installed FROM a release has no checkout, so a round that
-- skipped artifacts/ship/publish left it on its old binary with nothing to install - while the plan said
-- "done". The plan reads the RING, not a constant: the same paths plan differently when a node in the ring
-- installs a tree instead.
local lua_paths = { "lua/core/land.lua" }
local release_ring = { { node = "nextcloud", mode = "release" } }
local release_plan = land.build_plan({ id = "case31", journal = { repo = tree_root } }, lua_paths, nil, release_ring)
eq(release_plan.category, "lua-scripts-only", "a Lua-only change is still a Lua-only round")
eq(release_plan.steps.artifacts.kind, "node-release",
  "and its artifacts step builds a NODE RELEASE: the ring has a node that cannot deploy a tree")
eq(release_plan.steps.artifacts.action, "run", "the artifacts step runs")
eq(release_plan.steps.ship.action, "run", "the release is shipped")
eq(release_plan.steps.publish.action, "run", "and published")
contains(tostring(release_plan.steps.artifacts.why or ""), "nextcloud",
  "the plan names the node that forced it")
contains(tostring(release_plan.steps.deploy.why or ""), "nextcloud:release",
  "and the deploy says which node takes the release")
local tree_ring = { { node = "work", mode = "tree" } }
local tree_plan = land.build_plan({ id = "case31b", journal = { repo = tree_root } }, lua_paths, nil, tree_ring)
eq(tree_plan.steps.artifacts.kind, "lua-tree", "a ring of tree nodes keeps the Lua-tree record")
eq(tree_plan.steps.ship.action, "skip", "and ships no node release")
eq(tree_plan.steps.publish.action, "skip", "and publishes none")
eq(land.build_plan({ id = "case31c", journal = { repo = tree_root } }, lua_paths, nil, nil).steps.artifacts.kind and
  land.build_plan({ id = "case31c", journal = { repo = tree_root } }, lua_paths, nil, nil).steps.ship.action,
  "skip", "no ring named: the configured ring decides, and it is all tree nodes")
-- ------------------------------------------- case 32: a release-mode ring node, signed through a coordinator
-- (review r1 must 3). The e2e above uses SOLO_RING and signer=local, so no case had ever driven a ring
-- entry whose mode is release - the one mode that exists for a node with no checkout - nor a signer that
-- is a NAMED NODE rather than this machine. Both are asserted from the journal and from what the stub node
-- was actually asked: a plan that claims the mode and a deploy that sends tree would read the same in the
-- journal otherwise.
setup_fixture()
land.candidates = function() return {} end
behaviour.gh_authed, behaviour.gh_present, behaviour.release_present = true, true, false
routed_calls, deploy_requests = {}, {}
local mixed_ring = { { node = "work", mode = "tree" }, { node = "nextcloud", mode = "release" } }
local release_code = land.run({ run = "case32", signer = "laptop", account = "laptop", ring = mixed_ring,
  branches = { "change/one" }, checks = standard_checks() })
eq(release_code, 0, "a round with a release-mode ring node and a node signer lands")
local release_journal = journal_of("case32")
eq(release_journal.result, "done", "the journal says done")
-- The deploy asked the release node for release, not for the default mode: the mode travels to the node.
local asked_modes = {}
-- Read from the JOURNAL's own deploy rows: what the round recorded it asked of each node. The stub's
-- call list is not used, because a later setup_fixture in this file clears it.
for _, row in ipairs(release_journal.deploy or {}) do asked_modes[tostring(row.node)] = tostring(row.mode) end
eq(asked_modes["nextcloud"], "release", "the release-mode node was asked for a release install")
eq(asked_modes["work"], "tree", "and the tree node was asked for a tree deploy")
ok(sign_calls > 0, "the sign step ran on the coordinator node, where the vault is", tostring(sign_calls))
local main_there = false
for _, call in ipairs(routed_calls) do
  if call.node == "laptop" and call.kind == "main" then main_there = true end
end
ok(main_there, "and main was fast-forwarded there too")
contains(tostring(((release_journal.steps or {}).sign or {}).detail or ""), "signed on laptop",
  "the journal says the release was signed on the coordinator node")
ok(release_journal.artifacts and release_journal.artifacts.key_id ~= nil,
  "and the release carries the key it was signed with", tostring(release_journal.artifacts and release_journal.artifacts.key_id))
-- A release-mode node is NEVER silently deployed as a tree: an unknown mode is refused by name.
setup_fixture()
deploy_requests = {}
local bad_ring = { { node = "nextcloud", mode = "relase" } }
local bad_code = land.run({ run = "case32b", signer = "local", ring = bad_ring, branches = { "change/one" },
  checks = standard_checks() })
eq(bad_code, 1, "a ring naming an unknown mode stops the round")
eq(step_of("case32b", "deploy").state, "failed", "at the deploy")
contains(tostring(step_of("case32b", "deploy").detail or ""), "mode_unknown",
  "and the node refuses it by name rather than deploying the default")
-- ---------------------------------------------------------------- case 29 (end to end): one command, no hand
-- steps. A fixture land - scratch incoming repository, fake gh, scratch vault - runs from collect to report
-- with nothing done by hand: every effect is either done by the machine or skipped WITH A REASON, no step
-- carries `marked` (nothing needed an out-of-band verb), and the report it wrote says done (the mission's
-- done-when).
setup_fixture()
land.candidates = function() return {} end
behaviour.gh_authed, behaviour.gh_present, behaviour.release_present = true, true, false
routed_calls = {}
local e2e_code = land.run({ run = "case29", signer = "local", account = "laptop", ring = SOLO_RING,
  branches = { "change/one", "change/two" }, checks = standard_checks() })
eq(e2e_code, 0, "a fixture land runs collect -> report and answers zero")
local e2e = journal_of("case29")
eq(e2e.result, "done", "the journal says done")
for _, name in ipairs(land.STEPS) do
  local state = (e2e.steps or {})[name] and e2e.steps[name].state or "pending"
  ok(state == "done" or state == "skipped",
    "step " .. name .. " is done or skipped with a reason (it is " .. tostring(state) .. ")")
  if state == "skipped" then
    contains(tostring(e2e.steps[name].detail or ""), "skipped", "the skip of " .. name .. " says why")
  end
  ok(not (e2e.steps or {})[name] or e2e.steps[name].marked ~= true,
    "no step of an unattended round was marked out of band (" .. name .. ")")
end
local e2e_report = read_file(land.report_path("case29")) or ""
contains(e2e_report, "result: **done**", "the report says the round is done")
contains(e2e_report, "## steps", "and carries the step table")
ok(e2e.main_account == "laptop", "main was fast-forwarded by the account node, not by hand")
eq(e2e.publish and e2e.publish.account, "laptop", "and the release was created by that node")
end

cases_19_11()

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
