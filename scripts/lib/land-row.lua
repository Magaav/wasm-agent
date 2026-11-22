-- THE LAND ROW'S HARNESS: the fixtures, the fakes and the helpers that prove `wa land` (lua/core/land.lua).
--
-- SPLIT, 22/11 (mission main-green-2, item 2). Until today this was the front of ONE row,
-- `scripts/test-land.lua`: 655 checks, 55 s alone. That row is the landing machine's own and the fast path
-- may never drop it (scripts/lib/fast-rows.sh, wa_fast_core_rows), so every narrowed run paid it - and on a
-- busy machine it grew past the 120 s per-row watchdog and reported "no verdict within 120s" (measured in
-- land261 and in main-health, 8 rows in parallel beside running workers). The cases were already independent
-- fixtures - each one starts with `setup_fixture()` - so they are ten rows by subject now, each under 11 s
-- alone, and this file is what the ten share:
--
--   scripts/test-land-plan.lua          the weight probe, the happy path, the regenerate, the gate
--   scripts/test-land-resume.lua        a resume after the deploy failed, the rollback, the pins
--   scripts/test-land-sign.lua          the release signature, here and on a named node
--   scripts/test-land-review.lua        the reviewer channel and its join
--   scripts/test-land-rows.lua          the ready box, the classifier, the gate rows, waves, cost, report
--   scripts/test-land-resume-19-11.lua  the 19/11 bare --resume, land numbering, --account
--   scripts/test-land-marks.lua         publish marks, the ring a resume keeps, an operator pin
--   scripts/test-land-release.lua       the row inventory, the plans, release modes, the end-to-end round
--   scripts/test-land-gate-rows.lua     the gate's WA_FAST_ROWS file and the discrimination check
--   scripts/test-land-until.lua         --until, and the release loop (main, then a release cut from it)
--
-- No check was dropped and no watchdog was raised: the ten parts carry the same checks the one row carried.
-- The CASE text stayed in the parts, because a case belongs next to the comment that records what was
-- measured; what is here is only what all ten need.
--
-- WHAT IS REAL HERE, and stays real in every part: git (a fixture repository with two remotes - the incoming
-- bare repository every node can write, and the source of truth), the merged worktree, the pushes and their
-- readback, the release set the fixture publisher writes, the ed25519 signature made by a SCRATCH wa-vault
-- through the admin API (`scripts/lib/test-release-vault.sh`, its own data directory and ports, never the
-- operator's vault), its verification against the trusted keys of the tree, the artifacts reference, the
-- rollback script, the journal and the report on disk.
--
-- What is SCRIPTED, and only because it cannot be real in a test: the gate's checks (their commands point at
-- marker scripts, so one run can be green, red, or red-then-green-under-load), the release BUILD (`cargo`
-- and `zig` for two triples is not a test's business: the fixture publisher writes a fake payload set with
-- the real manifest/checksum shape), `gh` (a route in the runner: this machine has no token and no test may
-- publish), the nodes (a scripted peer call that answers `queued`/`installed`/`failed`, and - for the
-- signing hand-back - runs the command it was given, which is exactly what a signer node does), and the
-- weight probe (exercised once, then turned off so the rows run at a sane speed).
--
--   WA_SCRIPT=scripts/test-land-plan.lua wa --db /tmp/wa-land.db
--
-- Each part prints `land ok (<n> checks)`; a failed check raises, so the gate reads a verdict and not a
-- summary.
local json = dofile("lua/vendor/json.lua")
local land = dofile("lua/core/land.lua")
local real_host = host

-- WHAT A CASE MAY REBIND, not just read: these four are written by the cases themselves (a reset of the
-- recorded peer calls, a sign counter, the vault's availability) and read back by this file's helpers, so
-- they live in a table the parts hold: an alias would go stale the moment a case reset one.
local state = {}

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

state.vault_available = true
local vault_env = ""

local function start_vault()
  local probe = "command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && echo yes || echo no"
  local _, out = shell(probe)
  if (out or ""):gsub("%s", "") ~= "yes" then state.vault_available = false end
  if not state.vault_available then return false end
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
    state.vault_available = false
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
  if state.vault_available then
    -- The trust anchor: the tree trusts the key this run's vault made, which is what `config/release-keys.txt`
    -- is for. A release signed by a key that is not in it is refused (case 11).
    local trusted = read_file(vault .. "/trusted-keys.txt") or "wa-trusted-keys v1\n"
    write_file(repo .. "/config/release-keys.txt", trusted)
  else
    write_file(repo .. "/config/release-keys.txt", "wa-trusted-keys v1\n")
  end
  -- A DERIVED FILE, the way this tree has one (scripts/generators.txt + scripts/regenerate.sh): the base
  -- commit carries a STALE generated/files.txt (it lists only a.txt), so every merge below is the 21/11
  -- situation - two branches that are each correct alone make a file that is wrong together - and the
  -- landing's merge step is what fixes it (land.M.regenerate).
  must("cp -f " .. tree_root .. "/scripts/regenerate.sh " .. repo .. "/scripts/regenerate.sh", "copy the regeneration runner")
  write_file(repo .. "/scripts/generators.txt", "generated/files.txt = bash scripts/regen-fixture.sh\n")
  write_file(repo .. "/scripts/regen-fixture.sh",
    "#!/usr/bin/env bash\nset -u\nmkdir -p generated\nls *.txt | sort > generated/files.txt\n")
  must("mkdir -p " .. repo .. "/generated", "create the generated directory")
  write_file(repo .. "/generated/files.txt", "a.txt\n")
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
state.deploy_requests = {}
local fleet = { failing_node = nil, recovered = false, sign_node = "laptop", sign_null = false }
state.sign_calls = 0

state.routed_calls = {}
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
    if kind then state.routed_calls[#state.routed_calls + 1] = { node = selector, kind = kind, command = command } end
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
    state.sign_calls = state.sign_calls + 1
    local code, out, err = shell(with_vault(command))
    return { code = code, stdout = out, stderr = err }
  end
  if args.action == "request" then
    local id = "rec-" .. tostring(#state.deploy_requests + 1)
    state.deploy_requests[#state.deploy_requests + 1] = { node = selector, id = id, mode = args.mode, commit = args.commit,
      rollback = args.rollback, reason = args.reason }
    return { ok = true, status = "queued", record = id, commit = args.commit,
             kind = args.rollback and "rollback" or (args.mode or "node"),
             target_node = { name = selector, node_id = "id-" .. selector } }
  end
  if args.action == "status" then
    local row = nil
    for _, candidate in ipairs(state.deploy_requests) do if candidate.id == args.id then row = candidate end end
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

-- WHAT A PART GETS. Every name is this file's own; `state` is the writable half (above) and `count` is the
-- verdict line's number, read AFTER the cases have run - which is why it is a function and not a value.
return {
  json = json,
  land = land,
  real_host = real_host,
  tree_root = tree_root,
  fixture = fixture,
  repo = repo,
  incoming = incoming,
  origin = origin,
  journal_root = journal_root,
  vault = vault,
  ok = ok,
  flatten = flatten,
  eq = eq,
  contains = contains,
  shell = shell,
  must = must,
  write_file = write_file,
  read_file = read_file,
  start_vault = start_vault,
  stop_vault = stop_vault,
  PUBLISHER_SCRIPT = PUBLISHER_SCRIPT,
  SHIPPER_SCRIPT = SHIPPER_SCRIPT,
  FAKE_REVIEWER_SCRIPT = FAKE_REVIEWER_SCRIPT,
  review_home = review_home,
  FAKE_REVIEWER = FAKE_REVIEWER,
  REVIEW_MODE = REVIEW_MODE,
  REVIEW_ARGS = REVIEW_ARGS,
  REVIEW_MARKER = REVIEW_MARKER,
  REVIEW_SHA_FILE = REVIEW_SHA_FILE,
  fill = fill,
  install_fake_reviewer = install_fake_reviewer,
  review_start = review_start,
  review_forget = review_forget,
  review_arguments = review_arguments,
  review_started = review_started,
  setup_fixture = setup_fixture,
  marker = marker,
  advance_main = advance_main,
  real_exec = real_exec,
  observed = observed,
  behaviour = behaviour,
  with_vault = with_vault,
  fleet = fleet,
  remote_call = remote_call,
  journal_of = journal_of,
  step_of = step_of,
  gate_script = gate_script,
  set_gate = set_gate,
  SOLO_RING = SOLO_RING,
  standard_checks = standard_checks,
  state = state,
  count = function() return checks end,
}
