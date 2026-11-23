-- `wa land`: one command that takes READY branches to installed nodes, as a state machine with a journal.
--
-- WHAT IT REPLACES. Until 13/11 everything after an agent printed `READY <branch> <sha>` was run by hand,
-- from another machine, in a fixed order: collect the READY lines, merge them in a fresh worktree, build
-- with code-mode assets, run the gate, push the merged tip to the incoming bare repository, fast-forward
-- GitHub's main from the node that holds the credential, build and verify the release artifacts, publish
-- them, deploy node by node, and check each node afterwards. Every one of those steps already existed as a
-- script or a verb; none of them existed as a *sequence with a memory*. What went wrong was never one
-- step - it was a re-run that repeated a push, a deploy that stopped nowhere in particular, and a human
-- holding six facts in their head at 3 a.m.
--
-- So this module is a state machine and nothing else. Each step names its command, runs it under the
-- cpu/io weight a landing deserves, keeps the output as evidence, and writes what it did into a journal
-- before it moves on. Three properties follow, and they are the whole contract:
--
--   * resumable. `wa land --resume` starts at the first step that is not `done`. A push, a main
--     fast-forward and a publish recorded done are never repeated - and the remote is read back first, so
--     a crash between the push and the journal line is not a second push either.
--   * it stops at the first red step, by name, with the evidence path. `flaky under load: <check>` is a
--     STOP, not a green: a check that fails while agents load the machine and passes alone is a fact a
--     human decides on, never something this module silently ignores.
--   * it is honest about what it did not do. A step this node cannot perform (no GitHub credential, no
--     `gh`) is recorded `blocked` or `skipped` with the exact command that would finish it - never as done.
--
-- WHAT IT DOES NOT DO. It invents no signature, no publish and no deployment. Where a channel is not on main
-- yet the step stands in the journal as a TODO naming the file it looks for and the test that enables it.
-- The review is NOT such a channel any more: `wa land` runs the reviewer that landed (`wa eval reviewer`)
-- on every branch before the merge, through the reviewer's own door - see `impl.review`.
--
--   wa land --ready                    land every branch with a `READY <branch> <sha>` line
--   wa land --branches a,b             land exactly these branches
--   wa land --dry-run                  print the plan and every command; change nothing
--   wa land --no-deploy                land and publish, deploy nothing
--   wa land --signer <node>|local      where the release is signed (default: the node whose
--                                      WA_VAULT_ADMIN_URL is set - the vault's admin listener is loopback)
--   wa land --until <step>             stop cleanly AFTER that step (exit 0, result stopped_at_until):
--                                      --until gate is collect, plan, review, merge, gate, report and
--                                      no push, no main, no artifacts, no release, no node
--   wa land --resume                   continue the newest unfinished run from its failed step
--   wa land --run <id> --resume        continue that run
--   wa land status [--run <id>]        the journal as text (read-only)
--   wa land ready <branch> <sha> [--brief <file>]   record a READY line for an agent's finished branch
--
-- The runner is one seam (`M.exec`) so a test can script git, the gate and the nodes without a network, a
-- compiler or a fleet; production uses the host's own `exec`. The review's binary is a second, smaller seam
-- (`M.review_binary_path`) for the same reason: a test stands a fake reviewer where the binary would be.
local M = {}

local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function slashes(path) return (tostring(path or ""):gsub("\\", "/")) end
local function quote(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end
local function first_line(text) return (tostring(text or ""):match("^%s*([^\r\n]*)") or "") end
-- The line that carries the verdict. git writes progress first and the failure last ("Preparing worktree
-- (new branch ...)" then "fatal: already used by worktree at ..."), so first_line reports the progress and
-- loses the reason - measured by this suite's own case 12b, which is why the failure detail uses this.
local function last_line(text)
  local verdict = ""
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if line:match("%S") then verdict = line end
  end
  return trim(verdict)
end
local function now() return math.floor(host.now()) end

local function read(path)
  if not path then return nil end
  local ok, text = pcall(host.read_file, path)
  return (ok and text) or nil
end

local function write(path, text)
  local ok, wrote = pcall(host.write_file, path, text)
  return ok and wrote == true
end

-- Lines of a file's text, without `io.lines` (the host hands over the whole file).
local function vsplit(text, separator)
  local rows, from = {}, 1
  while true do
    local at = tostring(text):find(separator, from, true)
    if not at then
      rows[#rows + 1] = tostring(text):sub(from)
      break
    end
    rows[#rows + 1] = tostring(text):sub(from, at - 1)
    from = at + 1
  end
  return rows
end

local function json_file(path)
  local text = read(path)
  if not text then return nil end
  local ok, value = pcall(json.decode, text)
  return (ok and type(value) == "table") and value or nil
end

-- ---------------------------------------------------------------- the runner seam
--
-- One function runs every command and a test replaces it. `host.exec` answers with the operation wrapper
-- as JSON (`code`, `stdout`, `stderr`) and can refuse a command outright; both are normalised here, so no
-- step has to know about either. The third argument is the operation deadline: the gate runs a suite of
-- minutes, and the host's default 300 s would kill it into a false red.
-- <opts.tee = path>: run the command with its output APPENDED to that file by its own shell, and answer
-- the bytes this call wrote. The gate uses it to keep a long check legible while it runs (item 3 of the
-- harness-fixes-2 round). It is an ARGUMENT here, not a rewrite of `command` by the caller, so the command
-- a seam sees is the command the gate decided on - a stubbed runner still sees it unchanged.
function M.exec(command, cwd, timeout, opts)
  local tee = type(opts) == "table" and opts.tee or nil
  local launch, before = command, 0
  if type(tee) == "string" and tee ~= "" then
    before = #(read(tee) or "")
    -- The closing brace goes on its OWN line, never after a `;` (measured: it broke case5b of what is now
-- scripts/test-land-plan.lua). A
    -- check command may legally end in a shell comment (`bash x.sh # changed`), and `; }` on the same line
    -- belongs to that comment - the group never closes, the shell exits 2, and a green check reads red.
    launch = "{ " .. tostring(command) .. "\n} >> " .. quote(tee) .. " 2>&1"
  end
  local ok, raw = pcall(host.exec, launch, cwd or "", timeout)
  if not ok or type(raw) ~= "string" then
    return slice({ code = 127, stdout = "", stderr = "host refused: " .. tostring(command):sub(1, 120),
             raw = tostring(raw) })
  end
  -- With a tee, the answer is the part of the log THIS call wrote: the check's output is already on disk,
  -- written by the check itself as it printed, so nothing is lost if this call is killed.
  local function slice(result)
    if type(tee) ~= "string" or tee == "" then return result end
    local full = read(tee) or ""
    return { code = result.code, stdout = full:sub(before + 1), stderr = "", streamed = true }
  end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if decoded_ok and type(decoded) == "table" then
    -- The host answers {"error": ...} when it refused the launch (a disk cap, an unavailable shell) with
    -- no streams at all. Reading only stdout/stderr made that refusal an EMPTY failure: measured 19/11,
    -- `worktree_failed` came back four times with observed:"" while the same git command worked by
    -- hand, and nothing anywhere said why. The error is the message when there are no streams.
    local code = tonumber(decoded.code)
    local stdout = tostring(decoded.stdout or "")
    local stderr = tostring(decoded.stderr or "")
    if code == nil and decoded.error ~= nil then
      stderr = "host_error: " .. tostring(decoded.error)
      return slice({ code = 1, stdout = stdout, stderr = stderr, raw = raw })
    end
    return slice({ code = code or 1, stdout = stdout, stderr = stderr })
  end
  return { code = 1, stdout = "", stderr = "unreadable operation wrapper: " .. tostring(raw):sub(1, 200),
           raw = tostring(raw) }
end

-- How a landing waits between two polls of a node's own record. A field, not a sleep call inside the
-- logic, so a test drains it instantly while production waits a real five seconds.
function M.sleep(seconds) M.exec("sleep " .. tostring(seconds)) end

-- ---------------------------------------------------------------- the gate's LIVE output
--
-- A gate check used to be one plain run, and its output reached evidence/gate.log only when the call
-- RETURNED. A check the gate's timeout killed therefore left NO output - the one thing a reader needs to
-- see why it hung - and a failed row's own log died with fast.sh's scratch directory (item 3 of the
-- harness-fixes-2 round: a check that prints then hangs left an empty log).
--
-- So a check runs with its output APPENDED to the log by its OWN shell (M.exec, opts.tee), which the
-- kernel flushes as the lines appear: a check killed at the deadline has already written every line it
-- printed, and nothing is held in a buffer that dies with the caller. The command SEAM still sees the
-- command the gate decided on - the tee is added inside M.exec - so a stubbed runner and its
-- exact-command assertions are unaffected, and a run with no log to write is the plain runner.
--
-- <command> <cwd> <timeout_seconds> <live_path> -> {code, stdout, stderr}: stdout is the part of the log
-- THIS check wrote, measured from the byte offset the file had when it started.
function M.exec_streamed(command, cwd, timeout, live_path)
  if type(live_path) ~= "string" or live_path == "" then
    return M.exec(command, cwd, timeout)
  end
  return M.exec(command, cwd, timeout, { tee = live_path })
end

-- ---------------------------------------------------------------- where things live

-- The journal root: `<config>/land`. `root_dir` is the test seam; the module itself never sets it.
function M.root() return M.root_dir or (slashes(paths.config()) .. "/land") end
function M.ready_file() return M.root() .. "/ready.txt" end
function M.run_dir(id) return M.root() .. "/" .. tostring(id) end
function M.journal_path(id) return M.run_dir(id) .. "/journal.json" end
function M.evidence_path(id, step) return M.run_dir(id) .. "/evidence/" .. tostring(step) .. ".log" end
function M.report_path(id) return M.run_dir(id) .. "/report.md" end

-- The repository a landing works in. Production: the node's runtime worktree, the same answer
-- `lua/core/update.lua` gives, because that is the one checkout a node is guaranteed to have.
function M.repo()
  if M.repo_dir and M.repo_dir ~= "" then return slashes(M.repo_dir) end
  local explicit = trim(host.getenv and host.getenv("WA_LAND_REPO") or "")
  if explicit ~= "" then return slashes(explicit) end
  local ok, update = pcall(dofile, "lua/core/update.lua")
  if ok and type(update) == "table" and type(update.facts) == "function" then
    local facts = update.facts({})
    if facts and facts.tree and facts.tree ~= "" then return slashes(facts.tree) end
  end
  return nil
end

-- The two remotes. `oc-in` is the incoming bare repository every node can write (the drop box); `origin`
-- is the source of truth whose `main` only the node holding the credential can fast-forward.
function M.incoming()
  local explicit = M.incoming_remote or trim(host.getenv and host.getenv("WA_LAND_INCOMING") or "")
  return explicit ~= "" and explicit or "oc-in"
end

-- THE REFNAME A REMOTE'S TRACKING BRANCHES LIVE UNDER, computed once. "--incoming" is usually a remote NAME
-- ("oc-in"), and a name is a legal refname component. It can also be a LOCAL PATH - a bare repository on this
-- machine, which is how a landing is tested with no network and no other node - and a path is NOT: a fetch
-- with a path inside the refspec is refused by git, the fetch fails, and every branch then reads as "neither
-- on the incoming nor a local branch" (measured 21/11, the first preflight replay: the round could not
-- collect a branch that WAS in the drop box). A path therefore contributes its basename, and every named
-- remote reads exactly as it did.
local function tracking(incoming)
  local spec = tostring(incoming or "")
  -- A backslash is a path separator too (a Windows path), so both are tested literally.
  local sep = "\\"
  if spec:find("/", 1, true) or spec:find(sep, 1, true) then
    spec = spec:gsub("[/" .. sep .. "]+$", "")
    local leaf = spec:match("([^/" .. sep .. "]+)$") or spec
    spec = leaf:gsub("%.git$", "")
  end
  return (spec:gsub("[^%w%._%-]", "-"))
end
M.tracking = function(incoming) return tracking(incoming) end

function M.origin()
  local explicit = M.origin_remote or trim(host.getenv and host.getenv("WA_LAND_ORIGIN") or "")
  return explicit ~= "" and explicit or "origin"
end

-- The peer call a deploy uses (`nodes.remote_call` in production, a scripted function in a test).
function M.call()
  if M.remote_call then return M.remote_call end
  local ok, nodes = pcall(dofile, "lua/core/nodes.lua")
  if not ok or type(nodes) ~= "table" then
    error("lua/core/nodes.lua is unavailable, so no deploy can be asked for")
  end
  return nodes.remote_call
end

-- ---------------------------------------------------------------- who signs a release
--
-- The vault's ADMIN listener answers on the machine that runs the vault - measured 13/11: 127.0.0.1:8801 on
-- the operator's laptop, loopback only - so the signature is produced THERE and handed back here. The order
-- is deliberate: an explicit name wins, then the recorded choice, then the node that sets the vault's
-- operator URL (the default the mission names), then a refusal by name. Nothing guesses a signer and nothing
-- ever reads, prints or forwards the admin token.

function M.vault_var()
  for _, name in ipairs(M.SIGNER_VARS) do
    if trim(host.getenv and host.getenv(name) or "") ~= "" then return name end
  end
  return nil
end

-- The nodes worth asking: the fabric's peers, minus this node. `M.candidates` is the test seam (it takes the
-- options and answers names), and the module itself never sets it.
function M.signer_nodes(options)
  if type(M.candidates) == "function" then return M.candidates(options) end
  local ok, nodes = pcall(dofile, "lua/core/nodes.lua")
  if not ok or type(nodes) ~= "table" or type(nodes.list) ~= "function" then return {} end
  local names = {}
  for _, node in ipairs(nodes.list() or {}) do
    local name = tostring(node.name or "")
    if name ~= "" and node.local_node ~= true then names[#names + 1] = name end
  end
  return names
end

-- Can that node reach a vault? One signed call, one command, and only the two URL variables are asked for:
-- `printenv` prints the values of the names it was given and skips the ones that are unset, so the answer is
-- a URL or nothing, never a token.
function M.probes_vault(node)
  local ok, reply = pcall(M.call(), node, "bash",
    { command = "printenv WA_VAULT_ADMIN_URL WASM_AGENT_VAULT_OPERATOR_URL 2>/dev/null || true" })
  if not ok or type(reply) ~= "table" or reply.error then return false end
  if (tonumber(reply.code) or 1) ~= 0 then return false end
  return trim(reply.stdout) ~= ""
end

function M.signer(options)
  options = type(options) == "table" and options or {}
  local explicit = trim(options.signer)
  if explicit ~= "" then
    if explicit == "local" or explicit == "this" then return { kind = "local", why = "--signer local" } end
    return { kind = "node", node = explicit, why = "--signer " .. explicit }
  end
  local configured = json_file(M.root() .. "/signer.json")
  if configured then
    if configured["local"] == true then return { kind = "local", why = M.root() .. "/signer.json says local" } end
    local node = trim(configured.node)
    if node ~= "" then return { kind = "node", node = node, why = M.root() .. "/signer.json names " .. node } end
  end
  local variable = M.vault_var()
  if variable then return { kind = "local", why = "this node sets " .. variable } end
  local names = M.signer_nodes(options)
  for _, name in ipairs(names) do
    if M.probes_vault(name) then return { kind = "node", node = name, why = name .. " sets a vault operator URL" } end
  end
  return nil, { error = "signer_unknown",
    detail = "no host was found that can reach wa-vault's admin listener",
    observed = "this node sets neither " .. table.concat(M.SIGNER_VARS, " nor ") .. ";" ..
      (#names > 0 and (" it asked " .. table.concat(names, ", ") .. " and none named one")
        or " the fabric lists no other node to ask"),
    next = "name the host (`wa land --signer <node>`, or `--signer local` here), or set WA_VAULT_ADMIN_URL and "
      .. "WA_VAULT_ADMIN_TOKEN on the node that runs the vault" }
end

-- The signature, produced on `node` and handed back: the sums travel as base64, the signer's own
-- `scripts/sign-release.sh` runs there (found in its install, or wherever WA_LAND_SIGNER_SCRIPT names), and
-- the signature file comes back the same way. The token never leaves that node.
function M.sign_on_node(node, sums_path, sig_path, evidence)
  local encoded = M.exec("base64 < " .. quote(sums_path) .. " | tr -d '\\n'", "", 120)
  if (encoded.code or 1) ~= 0 or trim(encoded.stdout) == "" then
    return nil, { error = "sign_transfer_failed", observed = "cannot read " .. sums_path .. " to send it to " .. node }
  end
  local command = table.concat({
    'set -e',
    'd=$(mktemp -d)',
    'trap \'rm -rf "$d"\' EXIT',
    'printf %s ' .. quote(trim(encoded.stdout)) .. ' | base64 -d > "$d/SHA256SUMS"',
    's=""',
    'for c in "${WA_LAND_SIGNER_SCRIPT:-}" "${WA_INSTALL_DIR:-$HOME/.local/bin}/scripts/sign-release.sh" "$HOME/wasm-agent/scripts/sign-release.sh"; do',
    '  if [ -n "$c" ] && [ -f "$c" ]; then s="$c"; break; fi',
    'done',
    '[ -n "$s" ] || { echo "signer_script_missing: no scripts/sign-release.sh on this node (deploy this commit there, or set WA_LAND_SIGNER_SCRIPT)" >&2; exit 9; }',
    'bash "$s" "$d/SHA256SUMS" "$d/SHA256SUMS.sig" >/dev/null',
    'base64 < "$d/SHA256SUMS.sig" | tr -d \'\\n\'',
  }, '\n')
  if evidence then evidence(string.format("sign on %s: the sums travel as base64 and the signature comes back\n", node)) end
  local ok, reply = pcall(M.call(), node, "bash", { command = command })
  if not ok or type(reply) ~= "table" then
    return nil, { error = "signer_unreachable", observed = "the call to " .. node .. " produced no answer" }
  end
  if reply.error then
    return nil, { error = "signer_refused", detail = "node " .. node .. " refused the signing request",
      observed = tostring(reply.error) .. (reply.note and (" - " .. tostring(reply.note)) or "") }
  end
  if (tonumber(reply.code) or 1) ~= 0 then
    return nil, { error = "release_not_signed", detail = "node " .. node .. " could not sign",
      observed = first_line(tostring(reply.stderr or "") ~= "" and tostring(reply.stderr) or tostring(reply.stdout or "")) }
  end
  local signature = trim(reply.stdout)
  if signature == "" then
    return nil, { error = "signer_answered_nothing", observed = node .. " answered exit 0 with no signature" }
  end
  local decoded = M.exec("printf %s " .. quote(signature) .. " | base64 -d > " .. quote(sig_path), "", 120)
  if (decoded.code or 1) ~= 0 or not read(sig_path) then
    return nil, { error = "sign_transfer_failed", observed = "the signature " .. node .. " sent could not be written to " .. sig_path }
  end
  return { code = 0, stdout = "signed on " .. node, stderr = "" }
end

-- ---------------------------------------------------------------- the steps, in order
--
-- Data, so a reader can check the order against the mission and a test can assert it: merge, gate, push
-- the landed tip, fast-forward main, build and verify the release set, SIGN it, ship it as
-- `artifacts/node-<sha12>`, publish it, deploy the ring, then publish the PUBLIC LINUX CHANNEL for the same
-- commit (`linux`) - the order is a measurement, see `impl.linux`.
-- `report` is last and runs even when the machine stopped, because a stop without a report is the thing this
-- file exists to end.
--
-- `linux` is the one step that writes a commit of its own onto main: the channel a machine with no node
-- installs from is read from `main` (`releases/index-linux.json`), so an entry that only existed in this run's
-- worktree would change nothing. That commit carries exactly one path (an allow-list pathspec, checked again
-- before it is made), it is a fast-forward, and it is read back from the remote - `impl.linux` says why.
--
-- `artifacts`/`sign`/`ship` are the three halves of publishing and they are separate steps because the
-- hosts differ: the build needs a toolchain, the signature needs the vault's admin listener, and the ship
-- needs a git remote. Keeping them apart is what makes a rerun of one of them cheap - and a signature that
-- arrives after a stopped run is not thrown away with the build.
M.STEPS = { "collect", "plan", "review", "merge", "gate", "push", "main", "artifacts", "sign", "ship", "publish", "deploy", "linux", "report" }

-- ---------------------------------------------------------------- the LANDING (FACTORY.md rule 10)
--
-- A landing is not a release: merge onto main, regenerate the derived files, run the tests the branch ITSELF
-- added or changed, push, install THIS node and read the install record back, then measure main's health in
-- the background. No artifacts, no signature, no publish, no ring - `wa release cut` is that command and it is
-- where the whole gate runs.
--
-- WHAT IT REPLACES, one part to one script of the night of 21-22/11 (re-measured 22/11):
--   ~/Work/missions/land-quick.sh      -> `wa land change/x` (this order, one journal, one lock, and every
--                                         step is a row in the ledger)
--   ~/Work/missions/_quick/line.sh     -> `wa land change/a change/b` (one run per branch, each named)
--   ~/Work/missions/install-local.sh   -> the `install` step (the sentinel's deploy, the install record read
--                                         back, the installed Lua compared with main's)
--   scripts/main-health.sh             -> the `health` step (started as an operation; its verdict is the event
--                                         `land.main-health`, green or red)
--   two sessions messaging "it is green, land it" -> `wa events --follow --kind land`, and a session wakes on
--                                         `land.*` through the wake rows that already exist
M.LANDING_STEPS = { "collect", "plan", "merge", "tests", "push", "main", "install", "health", "report" }
-- `--gate` on a landing is the explicit request for the whole fast path on the merged tree (a human decided
-- this change deserves it). It is the fast path, not the release's gate: minutes, not the release's set.
M.LANDING_GATE_STEPS = { "collect", "plan", "merge", "gate", "tests", "push", "main", "install", "health", "report" }

function M.landing_steps(options)
  return (options and options.gate) and M.LANDING_GATE_STEPS or M.LANDING_STEPS
end

-- THE STEP ORDER A RUN FOLLOWS is the one it STARTED with: a resumed landing is the same landing, so its order
-- comes from its journal and not from the invocation that happened to continue it (the same rule the start
-- options follow, and the reason a resume cannot silently become a release).
function M.steps_for(journal, options)
  if options and options.release then return M.STEPS end
  local landing = (journal and journal.landing) or (options and options.landing)
  if not landing then return M.STEPS end
  if (journal and journal.gate_landing) or (options and options.gate) then return M.LANDING_GATE_STEPS end
  return M.LANDING_STEPS
end

-- The one command that signs a release's SHA256SUMS, run on whichever host can reach the vault
-- (`scripts/sign-release.sh` is a thin wrapper over `scripts/lib/release-signing.sh`).
M.SIGN_SCRIPT = "scripts/sign-release.sh"
M.SIGNER_VARS = { "WA_VAULT_ADMIN_URL", "WASM_AGENT_VAULT_OPERATOR_URL" }

-- ---------------------------------------------------------------- the gate's checks
--
-- The same checks the outside orchestrator ran by hand on 12/11-13/11, as data: a name a report can point
-- at, the command, where it runs, how long it may take, and - where a run could pass vacuously - the least
-- number of `test result: ok. N passed` tests it must have executed. `min_tests` is the anti-silence
-- guard: a `cargo test` whose filter matches nothing exits 0 and proves nothing, and that is exactly the
-- shape of a green landing nobody should trust.
--
-- `fast` is the day-to-day gate (AGENTS.md); the other four are the seams it deliberately leaves out - the
-- component parity run, the code-mode Rust tests (rust/wa-capabilities), the WhatsApp component's own
-- crate and the generated prompt documents.
M.DEFAULT_CHECKS = {
  { name = "fast", command = "bash scripts/fast.sh", timeout = 3600,
    detail = "the fast path (0 failed, 0 skipped)" },
  { name = "codemode-component", command = "bash scripts/test-codemode-component.sh", timeout = 1800,
    detail = "the code-mode seam: the same scripts through the native loop and through the component" },
  { name = "cargo-codemode",
    command = "bash scripts/gate-cargo-codemode.sh",
    timeout = 1800, min_tests = 1, detail = "the code-mode Rust tests (wa-capabilities: the seam and quickjs)" },
  { name = "cargo-wa-whatsapp", command = "cargo test --lib --offline", cwd = "rust/components/wa-whatsapp",
    timeout = 1200, min_tests = 1, detail = "the wa-whatsapp component's own crate" },
  -- Does each test this branch adds or changes actually fail on the code the branch had before its
  -- non-test changes? A test that still passes there would not have caught the bug it was written for,
  -- and it blocks the landing BY NAME (19-20/11: three of ten hidden tests did not discriminate, and
  -- every review of that round carried a test MUST). A branch declared refactor-only is exempt and must
  -- instead keep its tests green (scripts/test-discriminates.sh). A row this machine could not judge
  -- (unrevertable, timeout, skipped, environment) is named and does NOT block: exit 0 unless a row is a
  -- named blocker (1) or the script could not answer at all (76) - review r2 MUST 1.
  { name = "discrimination", command = "bash scripts/test-discriminates.sh origin/main", timeout = 900,
    per_test_seconds = 180,
    detail = "every test the branch adds or changes fails on the code before the change" },
  { name = "prompt-docs", command = "bash scripts/sync-prompt-docs.sh --check", timeout = 600,
    detail = "the generated prompt documents are in sync with the code" },
}

-- The deploy ring: every node, in the order it is deployed, with the mode each one needs. `openclaw` is
-- last on purpose - it holds the WhatsApp account and the relay, so every other node is already installed
-- and verified before the one that carries the fabric's own connections is touched. `nextcloud` is the
-- binary-only aarch64 node: `binary` means "install the published release; do not build here", which is
-- the procedure that used to be a hand-run sequence (WA_DEPLOY_PREBUILT_ONLY=1 through deploy.sh).
M.RING = {
  { node = "work", mode = "tree", why = "the working node: a tree install by its own Sentinel" },
  { node = "mail", mode = "tree", why = "the mail node: a tree install over its own session, no hand steps" },
  { node = "nextcloud", mode = "binary", why = "aarch64 with no toolchain: the published binary, never a build" },
  { node = "openclaw", mode = "tree", why = "last: it holds the WhatsApp account and the relay" },
}

-- ---------------------------------------------------------------- the plan: the cheapest safe path
--
-- WHY. A round cost ~40 minutes every time it ran (measured by hand, 13/11): merge, code-mode build, the
-- fast gate, a cross-build of BOTH Linux targets - even when no compiled input had changed - sign+publish,
-- and four deploys in series. Most of that day's branches were Lua-only, so most of every round was work the
-- round did not need. The plan is therefore made FIRST, from what actually changed, and it decides which
-- steps run: a docs-only round builds, releases and deploys nothing; a Lua-only round signs and ships a
-- RECORD of the tree it installed instead of cross-building a binary it would not use; a components round
-- rebuilds only the bundle and checks the pins; only a round that changed a compiled input pays for a build.
--
-- The classification is not spelled here either - `scripts/lib/land-classify.sh` is the one definition
-- (it calls `wa_compiled_input`, the same function the deploy's Lua fast path and the release digest use).
-- What lives here is the DECISION, as data a reader can check and a test can assert:
--
--   category            artifacts            sign  ship  publish  deploy
--   docs-only           skipped              skip  skip  skip     skip
--   lua-scripts-only    Lua-tree record      run   skip  skip     run (the tree, binary kept)
--   components          components bundle    skip  skip  skip     run
--   compiled            node release         run   run   run      run
--
-- A skipped step is recorded as `skipped` with its reason - never silently omitted, never reported done.
M.CATEGORIES = { "docs-only", "lua-scripts-only", "components", "compiled" }
M.CANARY_NODE = "work"
M.ACCOUNT_NODE = "openclaw"

-- What each step costs when the journal has no measurement yet. These are NOT guesses about this machine's
-- speed: they are the hand-run round of 13/11 (merge + code-mode build 3-5 min, gate 4-6, release 7-9,
-- sign+publish 2-5, four deploys in series 15-20), split per step and per path, so the first ever plan is
-- still comparable with what follows it. Every later plan uses the journal's own medians instead.
-- `review` is 5s because the step only STARTS the reviews now: they run beside the merge and the gate, and the
-- join is inside `report` (whose seconds carry whatever the landing waited for them at the end).
M.ESTIMATE_DEFAULTS = {
  collect = 40, review = 5, plan = 5, merge = 150, gate = 300, push = 30, main = 30,
  artifacts = 480, sign = 150, ship = 120, publish = 180, linux = 600, deploy = 960, report = 5,
}
-- Per path, the parts that differ: a Lua-only round signs a small record (seconds) and ships nothing; a
-- components round builds one wasm bundle and no binary; a full round pays the cross-build.
M.ESTIMATE_BY_CATEGORY = {
  ["docs-only"] = { artifacts = 0, sign = 0, ship = 0, publish = 0, deploy = 0 },
  ["lua-scripts-only"] = { artifacts = 30, sign = 60, ship = 0, publish = 0, deploy = 660 },
  ["components"] = { artifacts = 240, sign = 0, ship = 0, publish = 0, deploy = 660 },
  ["compiled"] = {},
}

-- The gate's always-on checks: a plan may never drop these, whatever the paths say, because they are what
-- makes a green run mean anything (the generated prompt documents, the landing queue's own evidence, the
-- binary the rows run, the machine-vs-code classifier, and the fast path's result file).
M.GATE_ALWAYS = { "fast", "prompt-docs", "discrimination" }
-- Checks a plan may ADD when a path touches their subject, with the paths that trigger them. The Rust
-- crates are already narrowed by `scripts/fast.sh` itself (it tests the crates a change touches), so only
-- the checks that are NOT inside the fast path are listed here.
M.GATE_TRIGGERS = {
  ["codemode-component"] = { "^lua/core/codemode", "^rust/components/codemode", "^rust/wa%-capabilities/src/codemode", "^scripts/codemode", "^scripts/build%-codemode" },
  ["cargo-codemode"] = { "^lua/core/codemode", "^scripts/gate%-cargo%-codemode", "^rust/components/codemode", "^rust/wa%-capabilities/src/codemode", "^scripts/codemode", "^wit/model/codemode" },
  ["cargo-wa-whatsapp"] = { "^rust/components/wa%-whatsapp", "^rust/wa%-whatsapp%-outbox", "^rust/wa%-whatsapp%-index", "^wit/whatsapp" },
}

-- The plan's own rows/checks, as pure functions so the decisions are testable without git or a build.

-- <paths> -> which of M.GATE_TRIGGERS fire (a pattern is matched against each changed path).
-- <step name> -> its position in M.STEPS, or nil. One reader, so `--until gate` and the gate step itself
-- cannot disagree about which side of the boundary they are on.
function M.step_index(name)
  for index, step in ipairs(M.STEPS) do
    if step == tostring(name) then return index end
  end
  return nil
end

-- <incoming> -> true when it is a remote NAME (oc-in) and not a path or a URL. A name is what the node
-- resolves through its own git config, so an unreachable name means a MACHINE is down (review r1, item 4);
-- a path or a URL is a fact about the repository the caller named.
function M.remote_is_named(incoming)
  local spec = tostring(incoming or "")
  return spec ~= "" and spec:find("/", 1, true) == nil and spec:find("\\", 1, true) == nil
end

-- <options> -> true when this round is told to stop at or before the gate, i.e. it is a PREFLIGHT: it
-- merges and gates and pushes nothing, so it must not need another node to be awake to answer.
function M.stops_by_gate(options)
  local boundary = options and options.until_step
  if not boundary then return false end
  local at, gate_at = M.step_index(boundary), M.step_index("gate")
  return at ~= nil and gate_at ~= nil and at <= gate_at
end

function M.gate_checks_for(paths)
  local wanted = {}
  for _, name in ipairs(M.GATE_ALWAYS) do wanted[name] = true end
  for name, patterns in pairs(M.GATE_TRIGGERS) do
    for _, path in ipairs(paths or {}) do
      local hit = false
      for _, pattern in ipairs(patterns) do
        if tostring(path):find(pattern) then hit = true break end
      end
      if hit then wanted[name] = true break end
    end
  end
  return wanted
end

-- <category> -> step name -> {action = "run"|"skip", why = <reason>, kind = <what the artifacts step writes>}.
-- Data, so a reader can check the table above against the code and the report can print the reason of every
-- skip.
function M.plan_steps(category)
  local function run(why) return { action = "run", why = why } end
  local function skip(why) return { action = "skip", why = why } end
  local steps = {}
  for _, name in ipairs(M.STEPS) do steps[name] = run("runs on every path") end
  if category == "docs-only" then
    steps.artifacts = skip("docs-only: nothing compiled, nothing a node loads, so there is nothing to build")
    steps.sign = skip("docs-only: no release to sign")
    steps.ship = skip("docs-only: no release to ship")
    steps.publish = skip("docs-only: no release to publish")
    steps.linux = skip("docs-only: nothing is compiled, so there is no bundle for the public channel either")
    steps.deploy = skip("docs-only: no node needs these bytes (a document is not loaded at runtime)")
  elseif category == "lua-scripts-only" then
    steps.artifacts = run("Lua tree record (manifest + SHA256SUMS over the shipped Lua tree): no cross-build, no node release")
    steps.artifacts.kind = "lua-tree"
    steps.sign = run("signs the Lua-tree record's SHA256SUMS (the vault's host, as always)")
    steps.ship = skip("a Lua-only round ships no node release: each node installs the tree with its own deploy, which keeps the installed binary")
    steps.publish = skip("a Lua-only round publishes no node release; the signed record is the round's evidence and the deploy is the transport")
    steps.linux = skip("a Lua-only round builds no bundle, and the public channel publishes prebuilt bundles: it moves with the next compiled release")
    steps.deploy = run("the ring, in order: the nodes take the Lua tree and keep their binary (the deploy's Lua fast path)")
  elseif category == "components" then
    steps.artifacts = run("components bundle only (scripts/publish-components.sh): build, verify against components.lock, print the repin line")
    steps.artifacts.kind = "components"

    steps.sign = skip("the component bundle is not covered by the release-signing key: scripts/publish-components.sh prints its own gh line")
    steps.ship = skip("no node release to ship: the bundle is fetched by the tag components-<lock sha12>")
    steps.publish = skip("publishing the bundle needs a credential host: the exact gh line is in the artifacts evidence and the report")
    steps.linux = skip("a components bundle is not a node bundle: the public Linux channel publishes wa/wa-sentinel with their runtime, not wasm components")
    steps.deploy = run("the ring installs the repinned components (and their binary, if the pins moved one)")
  end
  return steps
end

-- <ring> <options> -> the deploy's waves. The canary goes FIRST and alone (a broken commit must break one
-- node, not the fleet), then every other non-account node IN PARALLEL, then the account node last - it holds
-- the WhatsApp account and the relay, so it is the last thing touched and the first thing a stop protects.
function M.deploy_waves(ring, options)
  options = type(options) == "table" and options or {}
  local canary = tostring(options.canary or M.CANARY_NODE)
  local account = tostring(options.account or M.ACCOUNT_NODE)
  local by_name, order = {}, {}
  for _, entry in ipairs(ring or {}) do
    by_name[tostring(entry.node)] = entry
    order[#order + 1] = entry
  end
  local waves = { {}, {}, {} }
  local canary_entry = by_name[canary]
  if not canary_entry then
    -- A ring that does not name the canary still gets one: the first node that is not the account node, and
    -- the plan says it defaulted rather than pretending `work` was there.
    for _, entry in ipairs(order) do
      if tostring(entry.node) ~= account then canary_entry = entry break end
    end
  end
  local place = {}
  if canary_entry then
    waves[1][1] = canary_entry
    place[tostring(canary_entry.node)] = "canary"
  end
  for _, entry in ipairs(order) do
    local name = tostring(entry.node)
    if place[name] then
      -- already placed (the canary): a node appears in exactly one wave
      local _ = name
    elseif name == account then
      waves[3][1] = entry
      place[name] = "account"
    else
      waves[2][#waves[2] + 1] = entry
      place[name] = "parallel"
    end
  end
  local flat = {}
  for index = 1, 3 do for _, entry in ipairs(waves[index]) do flat[#flat + 1] = entry end end
  return { waves = waves, place = place, flat = flat, canary = canary_entry and tostring(canary_entry.node) or nil,
           account = by_name[account] and account or nil,
           canary_defaulted = (canary_entry ~= nil and tostring(canary_entry.node) ~= canary) or nil }
end

-- ---------------------------------------------------------------- the journal

local function blank_journal(id)
  return { schema = 1, run = tostring(id), created_at = now(), updated_at = now(), result = "in_progress",
           steps = {}, branches = {}, deploy = {}, todos = {} }
end

local function step_of(journal, name)
  journal.steps[name] = journal.steps[name] or { name = name, state = "pending" }
  return journal.steps[name]
end

local function save(run)
  run.journal.updated_at = now()
  if not write(M.journal_path(run.id), json.encode(run.journal)) then
    -- A journal nobody can write is a landing nobody can resume: say it once, here, instead of reporting a
    -- resumable state machine that is not one.
    print("land: warning: cannot write the journal " .. M.journal_path(run.id))
  end
end

-- Every step's evidence is one file, appended as the commands run, bounded: a log that grows without a
-- bound is a log nothing reads. `read` before `write` because the host has no append primitive - and
-- every call WRITES AND FLUSHES at once (item 3 of the harness-fixes-2 round): a caller that streams a
-- running check's output must be able to read it from another process WHILE the check runs, and a buffer
-- kept only in this one dies with the process that the timeout kills.
local function sink(run, name)
  local path = M.evidence_path(run.id, name)
  -- READ BEFORE EVERY WRITE, never once at the start (item 3 of the harness-fixes-2 round). The file is
  -- written by somebody else while this runs: a gate check appends its own live output to gate.log, so a
  -- buffer kept here would overwrite - silently delete - every line the CHECK wrote. What is on disk is the
  -- truth, and this appends to it.
  return function(text)
    local buffer = read(path) or ""
    buffer = buffer .. tostring(text or "")
    if #buffer > 200000 then buffer = "…\n" .. buffer:sub(-150000) end
    write(path, buffer)
  end
end

-- ---------------------------------------------------------------- the events a landing writes
--
-- ONE ROW PER STEP, written after the step settled, in the ledger's one schema
-- (lua/core/event_ledger.lua): mission, branch, sha, step, result, at. The steps are translated to the loop's
-- own vocabulary here (merge -> merged, install -> installed), so a subscriber asks for `land.merged` and not
-- for an internal name, and a step this run does not have writes nothing at all.
M.EVENT_STEP = { collect = "collected", plan = "planned", review = "reviewed", merge = "merged", gate = "gate",
  tests = "tests", push = "pushed", main = "main", install = "installed", health = "main-health",
  artifacts = "artifacts", sign = "signed", ship = "shipped", publish = "published", linux = "linux-channel",
  deploy = "deployed", report = "reported" }
-- A step whose fact has two halves: `installed` says the record named the landing, `install-verified` says the
-- node runs THIS landing's Lua. Two rows, in that order, written only when the step answered green (a failed
-- install writes `installed` red and `install-failed` from the step itself, never a verified row).
M.EVENT_FOLLOW = { install = "install-verified" }
M.EVENT_RESULT = { done = "green", skipped = "skipped", failed = "red", flaky = "red", blocked = "blocked" }

-- The mission's own name: the branches of the round without their `change/` prefix. One round, one name, and
-- a line of several branches names them all - a reader of the feed must be able to tell WHICH landing a row
-- belongs to without opening the journal.
function M.mission_name(run)
  local journal = (run and run.journal) or {}
  local names = {}
  for _, branch in ipairs(journal.branches or {}) do
    local name = tostring(branch.name or "")
    if name ~= "" then names[#names + 1] = (name:gsub("^change/", "")) end
  end
  if #names == 0 then
    -- BEFORE THE COLLECT STEP the round's branches are still the ones the invocation named, and the `started`
    -- row has to carry the same mission as every row after it - a feed a reader has to join by hand is not the
    -- point of this file.
    for _, name in ipairs((journal.start or {}).branches or {}) do
      local text = tostring(type(name) == "table" and (name.name or name.sha) or name or "")
      if text ~= "" then names[#names + 1] = (text:gsub("^change/", "")) end
    end
  end
  return table.concat(names, ",")
end

function M.branches_text(run)
  local journal = (run and run.journal) or {}
  local names = {}
  for _, branch in ipairs(journal.branches or {}) do
    local name = tostring(branch.name or branch.sha or "")
    if name ~= "" then names[#names + 1] = name end
  end
  if #names == 0 then
    -- See M.mission_name: before `collect` the round's own branch list is what the invocation named.
    for _, name in ipairs((journal.start or {}).branches or {}) do
      local text = tostring(type(name) == "table" and (name.name or name.sha) or name or "")
      if text ~= "" then names[#names + 1] = text end
    end
  end
  return table.concat(names, ",")
end

-- WHAT VICTOR TESTS (FACTORY.md rule 4). It comes from the ready line's own brief - the one file a branch's
-- intent travels on (`wa land ready <branch> <sha> --brief <file>`) - and from that file's `## How Victor tests
-- it` section, verbatim.
--
-- WHEN NO BRIEF WAS RECORDED THE MISSION'S OWN BRIEF IS READ: `wa land change/<name>` is launched from
-- ~/Work/missions/<name>/brief.md, which is where the operator already wrote the steps, so a branch landed
-- without `wa land ready --brief` still ends with what to do instead of "nothing describes the steps" (22/11,
-- the first real landing). A brief that is not there is the same fact as no brief at all, and a brief without
-- that section - or a branch name that cannot be a directory - invents nothing.
local function how_section(text)
  local section, inside = {}, false
  for line in tostring(text):gmatch("[^\r\n]+") do
    if line:match("^##%s*How Victor tests it") then inside = true
    elseif inside and line:match("^##%s") then inside = false
    elseif inside and trim(line) ~= "" then section[#section + 1] = trim(line) end
  end
  if #section == 0 then return nil end
  return table.concat(section, " | ")
end

-- The missions root, read the way `wa mission` reads it (MISSION_ROOT, then MISSIONS_DIR, then
-- ~/Work/missions): one place decides where a mission lives, so a fixture's scratch root is the one used here.
function M.missions_root()
  local ok, mission = pcall(dofile, "lua/core/mission.lua")
  if ok and type(mission) == "table" and type(mission.root) == "function" then
    local called, root = pcall(mission.root)
    if called and type(root) == "string" and trim(root) ~= "" then return slashes(trim(root)) end
  end
  local home = trim(host.getenv and host.getenv("HOME") or "")
  if home == "" then return nil end
  return slashes(home) .. "/Work/missions"
end

-- <journal> -> how, where: the `## How Victor tests it` text of the first branch's brief - the ready line's own
-- first, then the mission's own brief.md - and the file it was read from, so the report can cite it.
function M.how_to_test(journal)
  local branches = (journal and journal.branches) or {}
  for _, branch in ipairs(branches) do
    local brief = trim(branch.brief or "")
    if brief ~= "" then
      local how = how_section(read(brief) or "")
      if how then return how, brief end
    end
  end
  local root = M.missions_root()
  if not root then return nil, nil end
  for _, branch in ipairs(branches) do
    local name = tostring(branch.name or ""):gsub("^change/", "")
    -- ONE WORD, NO TRAVERSAL: a mission is a directory name (mission.check_name's rule), and a name that is not
    -- one would make this read a path nobody named.
    if name ~= "" and not name:find("[/\\]") and not name:find("..", 1, true) then
      local path = root .. "/" .. name .. "/brief.md"
      local how = how_section(read(path) or "")
      if how then return how, path end
    end
  end
  return nil, nil
end

-- THE LINE THE LANDING ENDS WITH. "Local is evolved to <sha>" is only true when the install record named this
-- landing; a landing whose install was skipped because nothing a node loads changed says exactly that instead
-- of claiming a deploy that did not happen.
function M.landed_line(journal, options)
  local sha = tostring((journal and (journal.main_sha or journal.tree_commit)) or ""):sub(1, 12)
  local who = M.mission_name({ journal = journal })
  if who == "" then who = "this change" end
  local install = ((journal or {}).steps or {}).install or {}
  local how = M.how_to_test(journal)
  local tail
  if tostring(install.state) == "skipped" then
    tail = "Local is evolved to " .. sha .. " (the checkout only: " .. tostring(install.detail or "no deploy was needed") .. ")"
  else
    tail = "Local is evolved to " .. sha
  end
  if how then return tail .. ". You can now test: " .. who .. " - " .. how end
  return tail .. ". You can now test: " .. who .. " (no brief was recorded for this branch, so nothing describes " ..
    "the steps: record one with `wa land ready <branch> <sha> --brief <file>`)"
end

-- WRITE ONE FACT. Never fatal: a ledger that cannot be written must not stop a landing (the journal is the
-- run's state machine, this is the record of what happened), and the failure is PRINTED so it is not silent -
-- an unrecorded step is not a green one.
function M.emit(run, step, result, detail, extra)
  local fields = {
    kind = "land", step = tostring(step), result = tostring(result),
    mission = M.mission_name(run), branch = M.branches_text(run),
    sha = tostring(run.journal.main_sha or run.journal.tree_commit or ""),
    detail = tostring(detail or ""), source = "wa land " .. tostring(run.id),
    session = tostring((run.journal.start or {}).session or ""),
  }
  for key, value in pairs(extra or {}) do fields[key] = value end
  local called, answer = pcall(function()
    return dofile("lua/core/event_ledger.lua").record(fields)
  end)
  if not called then
    print("land: the ledger row for " .. tostring(step) .. " could not be written: " .. tostring(answer))
    return nil
  end
  if type(answer) ~= "table" or answer.error then
    print("land: the ledger refused the row for " .. tostring(step) .. ": " ..
      tostring(type(answer) == "table" and answer.error or answer))
    return nil
  end
  return answer
end

local function command_line(label, command, decorator)
  local full = (decorator and decorator ~= "") and (decorator .. " " .. quote(command)) or command
  return string.format("$ [%s] %s\n", label, full)
end

-- The cpu/io weight a landing's gate runs under. Agents landing branches at the same time are what made
-- checks flaky (they spawn a shell each, and a fork that fails under load reads as a red check), so the
-- gate is run at the highest weight this machine will actually grant - and the decorator that was used is
-- recorded in the journal, because "weighted" that silently fell back to nothing is not a measurement.
--
-- The probe is the point: `nice -n -19` needs a privilege an ordinary user does not have and fails with
-- "Permission denied", so each candidate is RUN once (`true`) and the first that exits 0 wins.
-- `nice` and `ionice` WARN and then run anyway when they may not set a priority (exit 0 with "cannot set
-- niceness: Permission denied" on stderr), so their probes read the words and not only the exit code:
-- a measurement that believes it was weighted when it was not is exactly the flakiness this is here to
-- remove. Measured on wa-desktop 13/11: `systemd-run --user` works, `nice -n -19` and `ionice -c 1` do not.
M.WEIGHT_CANDIDATES = {
  { decorator = "systemd-run --user --scope --quiet -p CPUWeight=10000 -p IOWeight=10000 -- bash -lc",
    probe = "systemd-run --user --scope --quiet -p CPUWeight=10000 -p IOWeight=10000 -- true" },
  { decorator = "nice -n -19 ionice -c 1 -n 0 bash -lc",
    probe = "if nice -n -19 ionice -c 1 -n 0 true 2>&1 | grep -qiE 'permission denied|not permitted|failed'; then exit 1; fi; exit 0" },
  { decorator = "nice -n -19 bash -lc",
    probe = "if nice -n -19 true 2>&1 | grep -qiE 'permission denied|not permitted|failed'; then exit 1; fi; exit 0" },
  { decorator = "ionice -c 1 -n 0 bash -lc",
    probe = "if ionice -c 1 -n 0 true 2>&1 | grep -qiE 'permission denied|not permitted|failed'; then exit 1; fi; exit 0" },
  { decorator = "", probe = "true" },
}

function M.weight()
  if M.weight_decorator ~= nil then return M.weight_decorator end
  for _, candidate in ipairs(M.WEIGHT_CANDIDATES) do
    local probe = M.exec(candidate.probe, "", 30)
    if (probe.code or 1) == 0 then
      M.weight_decorator = candidate.decorator
      return M.weight_decorator
    end
  end
  M.weight_decorator = ""
  return M.weight_decorator
end

-- ---------------------------------------------------------------- small git helpers

local function git(run, tree, arguments, timeout)
  return M.exec("git -C " .. quote(slashes(tree)) .. " " .. arguments, tree, timeout or 300)
end

local function rev(tree, spec)
  local result = M.exec("git -C " .. quote(slashes(tree)) .. " rev-parse --verify --quiet " .. quote(spec) .. "^{commit}", tree, 120)
  if (result.code or 1) ~= 0 then return nil end
  local sha = trim(first_line(result.stdout))
  return sha:match("^%x+$") and sha or nil
end

-- <tree> -> the tree OBJECT of HEAD: the content, with no author, message or timestamp in it. rev() answers
-- a commit and appends ^{commit}, so the tree needs its own reader rather than a second spelling of rev.
local function tree_of(tree)
  local result = M.exec("git -C " .. quote(slashes(tree)) .. " rev-parse --verify --quiet " .. quote("HEAD^{tree}"), tree, 120)
  if (result.code or 1) ~= 0 then return nil end
  local sha = trim(first_line(result.stdout))
  return sha:match("^%x+$") and sha or nil
end

local function remote_tip(tree, remote, ref)
  local result = M.exec("git -C " .. quote(slashes(tree)) .. " ls-remote " .. quote(remote) .. " " .. quote(ref), tree, 300)
  if (result.code or 1) ~= 0 then return nil, trim(result.stderr) end
  local sha = trim(first_line(result.stdout)):match("^(%x+)")
  return sha
end

local function is_ancestor(tree, ancestor, descendant)
  local result = M.exec("git -C " .. quote(slashes(tree)) .. " merge-base --is-ancestor " .. quote(ancestor) .. " " .. quote(descendant), tree, 120)
  return (result.code or 1) == 0
end

-- ---------------------------------------------------------------- the steps

local impl = {}

-- ---------------------------------------------------------------- the release loop (`wa release cut`)
--
-- FACTORY.md rule 1: a landing ends at main; a RELEASE is cut from main's tip when the owner says. It is the
-- same state machine, the same journal and the same steps from the gate on - with nothing to land: collect
-- reads main, review/merge/push/main are settled as "nothing to land", the gate runs every check (kept when
-- the same tree object already passed the same command, M.gate_history), then artifacts, sign, ship,
-- publish, linux, deploy. It pushes no branch and lands nothing; the one commit it can write is the public
-- channel's index (`impl.linux`, one path, fast-forward, read back), so a failure in it leaves every landing -
-- and the node release that came before it - exactly as it was.

-- <run> <repo> <base> -> the run's tree: a DETACHED worktree of main's tip. The merge step makes the tree of
-- a landing; a release has no merge, so this is where artifacts/sign/ship find their checkout. Idempotent:
-- a resume whose worktree is gone gets it back at the same commit.
function M.release_tree(run, repo, base, evidence)
  local tree = run.tree_dir or (M.run_dir(run.id) .. "/tree")
  if rev(tree, "HEAD") ~= base then
    git(run, repo, "worktree prune")
    local added = git(run, repo, "worktree add --quiet --detach " .. quote(tree) .. " " .. quote(base), 600)
    if evidence then
      evidence(command_line("worktree", "git worktree add --detach " .. tree .. " " .. base))
      evidence((added.stdout or "") .. (added.stderr or ""))
    end
    if (added.code or 1) ~= 0 or rev(tree, "HEAD") ~= base then
      return false, { error = "release_tree_failed",
        observed = "git worktree add --detach " .. tree .. " " .. tostring(base):sub(1, 12) .. " exited " ..
          tostring(added.code) .. ": " .. last_line(tostring(added.stderr or "") .. "\n" .. tostring(added.stdout or "")),
        next = "git -C " .. tostring(repo) .. " worktree prune, then wa release cut --run " .. run.id .. " --resume" }
    end
  end
  run.tree = tree
  run.journal.tree = tree
  run.journal.tree_commit = base
  run.journal.tree_sha = tree_of(tree)
  run.journal.release = true
  return true
end

-- THE PRECONDITIONS, asked in the first second and before any build. 5 of 19 landings on 20-21/11 stopped at
-- sign or publish AFTER paying for the gate and the artifacts, for a reason that was true before the run
-- began (the signer could not reach the vault; gh could not read the desktop keyring). Each check answers
-- { ready = bool, why = <text>, next = <the one command that fixes it> } and is a field of this table so a
-- test (or an operator's wrapper) replaces it without a vault or GitHub.
M.release_checks = {}
M.RELEASE_CHECK_ORDER = { "version", "signing", "publishing", "channel", "ancestry" }
-- which step a check protects: a resume whose step is already settled does not ask again.
M.RELEASE_CHECK_STEP = { version = "linux", signing = "sign", publishing = "publish", channel = "linux", ancestry = "artifacts" }

function M.release_checks.signing(options)
  local signer, problem = M.signer(options)
  if not signer then
    return { ready = false, error = "release_signing_not_ready", why = tostring(problem.detail) .. " (" .. tostring(problem.observed) .. ")",
      next = "wa release cut --signer <the node that runs wa-vault>   (or --signer local on that node)" }
  end
  if signer.kind == "node" then
    if M.probes_vault(signer.node) then return { ready = true, why = "signer " .. signer.node .. " names a vault URL (" .. signer.why .. ")" } end
    return { ready = false, error = "release_signing_not_ready",
      why = "the signer " .. signer.node .. " (" .. signer.why .. ") did not answer with a vault URL",
      next = "wa nodes   (is " .. signer.node .. " reachable?), or name another: wa release cut --signer <node>" }
  end
  -- This node signs: the same URL and token rule scripts/lib/release-signing.sh applies, asked without
  -- printing either value.
  local probe = M.exec('url="${WA_VAULT_ADMIN_URL:-${WASM_AGENT_VAULT_OPERATOR_URL:-http://127.0.0.1:${WA_VAULT_ADMIN_PORT:-8801}}}"; ' ..
    'if [ -z "${WA_VAULT_ADMIN_TOKEN:-}" ] && ! { [ -n "${WA_VAULT_ADMIN_TOKEN_FILE:-}" ] && [ -r "${WA_VAULT_ADMIN_TOKEN_FILE}" ]; }; then echo no-token; ' ..
    'elif curl -s -o /dev/null --max-time 5 "$url"; then echo reachable; else echo unreachable; fi', "", 30) or {}
  local answer = trim(probe.stdout)
  if answer == "reachable" then return { ready = true, why = "this node reaches the vault's admin listener (" .. signer.why .. ")" } end
  if answer == "no-token" then
    return { ready = false, error = "release_signing_not_ready",
      why = "this node would sign (" .. signer.why .. ") and has no vault admin token: neither WA_VAULT_ADMIN_TOKEN nor a readable WA_VAULT_ADMIN_TOKEN_FILE",
      next = "export WA_VAULT_ADMIN_TOKEN_FILE=<the 0600 token file> in this shell, or sign where the vault runs: wa release cut --signer <node>" }
  end
  return { ready = false, error = "release_signing_not_ready",
    why = "this node would sign (" .. signer.why .. ") and the vault's admin listener does not answer",
    next = "start the vault (or set WA_VAULT_ADMIN_URL to its admin listener), or sign where it runs: wa release cut --signer <node>" }
end

function M.release_checks.publishing(options)
  local account = trim(options.account)
  local routed = account ~= "" and account ~= "local" and account ~= "this"
  local gh_command = "command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && echo yes || echo no"
  if routed then
    local reply, problem = M.node_bash(account, gh_command)
    if reply and trim(reply.stdout) == "yes" then return { ready = true, why = "gh on " .. account .. " is signed in" } end
    return { ready = false, error = "release_publishing_not_ready",
      why = reply and ("gh on " .. account .. " is missing or signed out")
        or (account .. " did not answer: " .. tostring(problem and (problem.observed or problem.detail) or "")),
      next = "gh auth login   (on " .. account .. "), or publish from here: wa release cut --account local" }
  end
  local here = M.exec(gh_command, "", 60) or {}
  if trim(here.stdout) == "yes" then return { ready = true, why = "gh here is signed in" } end
  return { ready = false, error = "release_publishing_not_ready",
    why = "gh here is missing or signed out (gh reads its token from the desktop keyring; a systemd unit or an ssh shell has no session bus to unlock it)",
    next = "gh auth login   (in a desktop terminal; or export GH_TOKEN there), then run wa release cut from that same shell" }
end

-- THE VERSION, asked in the FIRST SECOND (Fable, 23/11): the number on main is the release this tree WILL be cut
-- as, and one that already has a tag means the bump commit from the previous release never landed - a cut now
-- would publish bytes whose tag already exists, under a number nobody chose. That is a fact about the tree, so
-- it is a precondition and not a failure at the end of the channel step (which runs after the node release is
-- out). The same row holds an explicit bump to Victor's quoted instruction, because a minor is decided one
-- release AHEAD now: the bump this release writes is the next cut's number.
function M.release_checks.version(options, journal)
  local repo = M.repo()
  if not repo then return { ready = true, why = "no checkout to ask (collect refuses that by name)" } end
  local shown = M.exec("git -C " .. quote(slashes(repo)) .. " show " .. quote("origin/main:" .. M.VERSION_FILE), "", 120) or {}
  if (shown.code or 1) ~= 0 then
    return { ready = false, error = "release_version_not_ready",
      why = "cannot read " .. M.VERSION_FILE .. " on origin/main in " .. slashes(repo),
      next = "git -C " .. slashes(repo) .. " fetch " .. M.origin() .. " main   (then wa release cut)" }
  end
  local line = M.product_version_line(tostring(shown.stdout or ""))
  local current = line and M.parse_product_version(line)
  if not current then
    return { ready = false, error = "release_version_not_ready",
      why = M.VERSION_FILE .. " on origin/main has no usable M.PRODUCT_VERSION line (" .. tostring(line) .. ")",
      next = "set M.PRODUCT_VERSION in " .. M.VERSION_FILE .. " to the number this release will be cut as" }
  end
  local release = M.format_product_version(current)
  local tag = M.version_tag(release)
  -- A resume carries the commit it is releasing, so a tag that names THAT commit is this run's own work (the
  -- publisher created it before the index commit was pushed) and the cut goes on. A fresh run has no commit yet
  -- and any existing tag means the number is taken.
  local resuming = type(journal) == "table" and tostring(journal.tree_commit or "")
  local ours, why_tag = M.version_tag_owner(repo, tag, resuming ~= "" and resuming or nil)
  if not ours then
    return { ready = false, error = "version_already_released",
      why = "main's " .. M.VERSION_FILE .. " says " .. release .. " and " .. tostring(why_tag) ..
        ": the previous release's bump commit is missing, so this cut would ship bytes whose tag is taken",
      next = "publish the bump commit (a release writes the NEXT number into M.PRODUCT_VERSION), or set that line to the next number, then cut again" }
  end
  if options.major or options.minor then
    local kind = options.major and "major" or "minor"
    local bumped, _ = M.bump_version(current, options)
    local authorised, why_bump = M.bump_is_authorised(repo, kind, bumped)
    if not authorised then
      return { ready = false, error = "release_bump_not_authorised",
        why = tostring(why_bump),
        next = "quote Victor's instruction naming " .. M.version_tag(M.format_product_version(bumped)) .. " in " ..
          M.VERSION_NOTES .. " and commit it, then wa release cut" }
    end
    return { ready = true, why = "main's number is " .. release .. " (not yet released) and the " .. kind ..
      " bump to " .. M.format_product_version(bumped) .. " is quoted in " .. M.VERSION_NOTES }
  end
  return { ready = true, why = "main's number is " .. release .. " and " .. tag .. " does not exist yet" }
end

-- The public channel needs a toolchain the node release does not: two STATIC musl bundles, built by
-- `scripts/release-linux.sh --target` with cargo-zigbuild and the rust target's std. Asked in the first second,
-- for the same reason as signing and publishing: a cut that pays for the gate and the node build and then finds
-- no zig has spent an hour to learn a fact that was true before it started.
function M.release_checks.channel(options)
  local targets = {}
  for target in tostring(options.linux_targets or M.LINUX_TARGETS or "x86_64-unknown-linux-musl aarch64-unknown-linux-musl"):gmatch("%S+") do targets[#targets + 1] = target end
  local probe = M.exec("command -v cargo-zigbuild >/dev/null 2>&1 && echo yes || echo no", "", 60) or {}
  if trim(tostring(probe.stdout or "")) ~= "yes" then
    return { ready = false, error = "release_channel_not_ready",
      why = "cargo-zigbuild is not on PATH, and the channel's musl bundles are built with it (scripts/release-linux.sh --target)",
      next = "install the publish toolchain (scripts/provision-publish-toolchain.sh), or publish the channel on a node that has it" }
  end
  for _, target in ipairs(targets) do
    local have = M.exec("rustup target list --installed 2>/dev/null | grep -qx " .. quote(target) .. " && echo yes || echo no", "", 60) or {}
    if trim(tostring(have.stdout or "")) ~= "yes" then
      return { ready = false, error = "release_channel_not_ready",
        why = "the rust target " .. target .. " is not installed in this toolchain, so its bundle cannot be built here",
        next = "rustup target add " .. target .. "   (then wa release cut --run <id> --resume)" }
    end
  end
  return { ready = true, why = "cargo-zigbuild and the rust targets are here (" .. table.concat(targets, " ") .. ")" }
end

-- The ancestry rule (docs/missions/reports/release-ancestry.md): a node installs a release over its
-- predecessor only when the new binary can prove it contains the old commit. Two facts decide that before a
-- build: the checkout must not be shallow (publish-node-binaries.sh refuses ancestry_window_unknown after
-- the build otherwise), and main must contain the release this machine published last.
function M.release_checks.ancestry(options)
  local repo = M.repo()
  if not repo then return { ready = true, why = "no checkout to ask (collect refuses that by name)" } end
  local shallow = git(nil, repo, "rev-parse --is-shallow-repository", 60)
  if trim(shallow.stdout) == "true" then
    return { ready = false, error = "release_ancestry_not_ready",
      why = repo .. " is a shallow clone, so the release cannot prove which commits it contains (ancestry_window_unknown)",
      next = "git -C " .. repo .. " fetch --unshallow " .. M.origin() }
  end
  local main = rev(repo, "origin/main")
  for _, path in ipairs(M.published_journals and M.published_journals() or {}) do
    local journal = json_file(path)
    if journal and type(journal.publish) == "table" and journal.publish.tag and journal.tree_commit then
      local previous = tostring(journal.tree_commit)
      if main and rev(repo, previous) and not is_ancestor(repo, previous, main) then
        return { ready = false, error = "release_ancestry_not_ready",
          why = "origin/main (" .. main:sub(1, 12) .. ") does not contain the previous release " .. tostring(journal.publish.tag) ..
            " (run " .. tostring(journal.run) .. "): every node on it would refuse this one",
          next = "git -C " .. repo .. " log --oneline origin/main.." .. previous:sub(1, 12) .. "   (land those commits, then wa release cut)" }
      end
      return { ready = true, why = "main contains the previous release " .. tostring(journal.publish.tag) }
    end
  end
  return { ready = true, why = "full history; no earlier release recorded under " .. M.root() }
end

-- <options> [journal] -> rows { name, ready, why, next, error }, all_ready. Read-only.
function M.release_preflight(options, journal)
  local rows, all = {}, true
  for _, name in ipairs(M.RELEASE_CHECK_ORDER) do
    local step = journal and journal.steps and journal.steps[M.RELEASE_CHECK_STEP[name]]
    local row
    if step and (step.state == "done" or step.state == "skipped") then
      row = { ready = true, why = "step " .. M.RELEASE_CHECK_STEP[name] .. " is already " .. step.state .. " in this run" }
    else
      local called, answer = pcall(M.release_checks[name], options, journal)
      row = (called and type(answer) == "table") and answer
        or { ready = false, error = "release_" .. name .. "_not_ready", why = "the check itself failed: " .. tostring(answer),
             next = "wa release cut --dry-run" }
    end
    row.name = name
    if row.ready ~= true then all = false end
    rows[#rows + 1] = row
  end
  return rows, all
end

function M.release_preflight_lines(rows)
  local lines = {}
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format("release: %s: %s (%s)", row.name, row.ready == true and "ready" or "not ready", tostring(row.why))
    if row.ready ~= true then lines[#lines + 1] = "release:   fix: " .. tostring(row.next) end
  end
  return lines
end

-- collect: which branches, at which tips. `--ready` reads the ready box, which is the same line an agent
-- prints when it finishes (`READY <branch> <sha>`), so a coordinator or an agent records it with
-- `wa land ready <branch> <sha>` and this step reads it back. A recorded sha that no longer matches the
-- branch's tip is a REFUSAL, not a silent upgrade: the branch moved after somebody said it was ready, and
-- that is a human's decision.
impl.collect = function(run, options)
  local evidence = sink(run, "collect")
  local repo = M.repo()
  if not repo then
    return false, { error = "no_repository", observed = "this node has no runtime tree and WA_LAND_REPO is empty",
      next = "run `wa land` on a machine with a checkout, or set WA_LAND_REPO=<dir>" }
  end
  local incoming = M.incoming()
  local tracked = tracking(incoming)
  local fetched = git(run, repo, "fetch --quiet --prune " .. quote(incoming) .. " " .. quote("+refs/heads/*:refs/remotes/" .. tracked .. "/*"))
  evidence(command_line("fetch", "git fetch --prune " .. incoming))
  evidence((fetched.stdout or "") .. (fetched.stderr or ""))
  -- A FETCH THAT FAILED IS NOT AN EMPTY DROP BOX. It used to be ignored, so an unreachable incoming (or one
  -- whose refspec git refused) answered "the branch is neither on <incoming> nor a local branch" - a
  -- statement about the branch, when the truth was a statement about the fetch.
  if (fetched.code or 1) ~= 0 then
    -- AN UNREACHABLE NAMED REMOTE IS NOT A REFUSAL WHEN THE ROUND STOPS AT OR BEFORE THE GATE (review r1,
    -- item 4). A landing must read the drop box before it can merge anything, but a PREFLIGHT is the local
    -- loop (FACTORY.md rule 1: no network, no other node) and it must not depend on openclaw being awake: the
    -- refs this checkout already has are enough to ask the gate question. A refused refspec or a PATH is a
    -- different failure - it is a fact about the repository, not about a machine being down - and stays a
    -- refusal. The warning is in the evidence, so nothing is silent.
    if M.remote_is_named(incoming) and M.stops_by_gate(options) then
      evidence("fetch: WARN " .. incoming .. " could not be fetched (" ..
        first_line(tostring(fetched.stderr ~= "" and fetched.stderr or fetched.stdout)) ..
        "); this round stops at " .. tostring(options.until_step) .. " so it goes on with the refs this checkout has\n")
    else
    return false, { error = "fetch_failed",
      observed = "git fetch " .. incoming .. " exited " .. tostring(fetched.code) .. ": " ..
        first_line(tostring(fetched.stderr ~= "" and fetched.stderr or fetched.stdout)),
      next = "check that " .. incoming .. " is reachable and is a git repository, then wa land --resume" }
    end
  end
  -- The base is the FURTHEST MAIN both sides agree on. Two mains exist and they can lag each other: the
  -- incoming repository's (every node can read it) and the source of truth's (only a credentialed node can
  -- fast-forward it). A landing stops after main moved but before the release published, so the next one
  -- must start from whichever main already contains the other - and a pair that diverged is a REFUSAL,
  -- because picking either would silently drop one side's work.
  local incoming_main = rev(repo, "refs/remotes/" .. tracked .. "/main")
  local origin_main = rev(repo, "origin/main")
  local base, base_ref = nil, nil
  if incoming_main and origin_main then
    if incoming_main == origin_main then
      base, base_ref = incoming_main, incoming .. "/main == origin/main"
    elseif is_ancestor(repo, incoming_main, origin_main) then
      base, base_ref = origin_main, "origin/main (contains " .. incoming .. "/main)"
    elseif is_ancestor(repo, origin_main, incoming_main) then
      base, base_ref = incoming_main, incoming .. "/main (contains origin/main)"
    else
      return false, { error = "main_diverged",
        observed = string.format("%s/main is %s and origin/main is %s; neither contains the other",
          incoming, incoming_main:sub(1, 12), origin_main:sub(1, 12)),
        next = "reconcile the two mains (the incoming repository is a drop box; main is the source of truth) before landing" }
    end
  elseif incoming_main then
    base, base_ref = incoming_main, incoming .. "/main"
  elseif origin_main then
    base, base_ref = origin_main, "origin/main"
  else
    return false, { error = "no_main", observed = "neither " .. incoming .. "/main nor origin/main resolves in " .. repo,
      next = "fetch main first: git fetch " .. incoming .. " main" }
  end

  local wanted = {}
  if options.release then
    -- A RELEASE RUN LANDS NOTHING: its tree is main's tip, so there is no branch to resolve (see
    -- M.release_tree below, which gives the later steps the tree a merge would have given them).
  elseif options.branches and #options.branches > 0 then
    for _, name in ipairs(options.branches) do wanted[#wanted + 1] = { name = name } end
  elseif options.ready then
    local box = M.ready_file()
    local text = read(box) or ""
    -- `READY <branch> <sha>` and, when the box knows one, ` brief=<file>`: the brief is the operator's text for
    -- the branch and it is what the reviewer reads beside the diff. The LAST line for a branch wins, because the
    -- box is rewritten when a line is re-recorded.
    local order, wanted_of = {}, {}
    for line in text:gmatch("[^\r\n]+") do
      local branch, sha, rest = line:match("^%s*READY%s+(%S+)%s+(%x+)%s*(.*)$")
      if branch then
        local brief = tostring(rest or ""):match("brief=(%S+)")
        if not wanted_of[branch] then order[#order + 1] = branch end
        wanted_of[branch] = { name = branch, sha = sha, brief = brief }
      end
    end
    for _, branch in ipairs(order) do wanted[#wanted + 1] = wanted_of[branch] end
    if #wanted == 0 then
      return false, { error = "ready_empty", observed = "no `READY <branch> <sha>` line in " .. box,
        next = "record one: wa land ready change/<name> <sha> [--brief <file>]" }
    end
  else
    return false, { error = "no_branches", observed = "neither --branches nor --ready was given",
      next = "wa land --branches change/a,change/b   (or --ready to use the ready box)" }
  end

  local branches = {}
  for _, want in ipairs(wanted) do
    local ref = nil
    for _, candidate in ipairs({ "refs/remotes/" .. tracked .. "/" .. want.name, "refs/heads/" .. want.name }) do
      if rev(repo, candidate) then
        ref = candidate
        break
      end
    end
    if not ref then
      return false, { error = "branch_unknown", observed = want.name .. " is neither on " .. incoming .. " nor a local branch",
        next = "git push " .. incoming .. " " .. want.name .. ":refs/heads/" .. want.name .. " (the agent's drop box), then ask again" }
    end
    local tip = rev(repo, ref)
    if want.sha and want.sha ~= tip then
      return false, { error = "ready_sha_moved",
        observed = string.format("%s was recorded READY at %s and its tip is now %s", want.name, want.sha:sub(1, 12), tip:sub(1, 12)),
        next = "the branch moved after it was declared ready: land the new tip (wa land --branches " .. want.name ..
          ") or find out what pushed to it" }
    end
    branches[#branches + 1] = { name = want.name, sha = tip, ref = ref, brief = want.brief }
    evidence(string.format("%s -> %s (%s)%s\n", want.name, tip, ref,
      (want.brief and want.brief ~= "") and (" brief " .. want.brief) or ""))
  end
  run.journal.base = base
  run.journal.base_ref = base_ref
  run.journal.repo = repo
  if options.release then
    -- THE RELEASE IS OF origin's MAIN, and of nothing else. When the incoming main is ahead of it a landing
    -- pushed and did not fast-forward main yet: releasing that tip would publish a commit main does not have.
    if origin_main and base ~= origin_main then
      return false, { error = "release_main_not_on_origin",
        observed = string.format("%s/main is %s and origin/main is %s: a landing pushed and has not moved main",
          incoming, base:sub(1, 12), origin_main:sub(1, 12)),
        next = "finish that landing first (wa land --resume), then wa release cut" }
    end
    local made, problem = M.release_tree(run, repo, base, evidence)
    if not made then return false, problem end
    if origin_main then run.journal.main_sha = base end
  end
  run.journal.incoming = incoming
  run.journal.incoming_tracking = tracked
  run.journal.origin = M.origin()
  run.journal.branches = branches
  if options.release then
    return true, { detail = string.format("release of main's tip %s (%s): no branch to land", base:sub(1, 12), base_ref) }
  end
  return true, { detail = string.format("base %s, %d branch(es): %s", base:sub(1, 12), #branches,
                  table.concat((function()
                    local names = {}
                    for _, entry in ipairs(branches) do names[#names + 1] = entry.name end
                    return names
                  end)(), " ")) }
end

-- ---------------------------------------------------------------- plan
--
-- What the round changed, which of the four paths it takes, which steps that path skips, what the gate has to
-- run, and what the round should cost. Read-only: no fetch, no merge, no build. It runs after `collect`
-- because the tips are what make "what changed" answerable at all.

-- <journal> -> paths, notes: the round's changed paths (the FORK POINT of every collected branch, not main's
-- tip, to that branch's own tip), deduplicated, and a note naming every branch whose diff could NOT be read.
-- Renames are not followed (`--no-renames`): the planner asks which paths the merge introduces, and a rename is
-- two paths - the old one gone and the new one here - exactly as `git diff --name-status` reports it.
--
-- THE FORK POINT, NOT THE BASE. `git diff <main's tip> <branch>` answers "how do main and the branch differ",
-- which also reports every commit MAIN gained after the branch was cut. The first real `wa land`
-- (run land-20261122T113743Z-f3fedc13, branch change/seat-5-10-check - docs/, lua/core/, scripts/) was measured
-- as "the branch changes Rust (3 file(s))" because main had moved on Rust since its base e7bf6d56, and the
-- branch's own three test files were never run before its push. What a landing changes ABOUT MAIN is the
-- branch's own delta - a merge of main into the branch moves main by exactly merge-base(main, branch)..branch -
-- so that range is what every reader of "what this branch changes" gets: the plan's path, the tests it runs,
-- the deploy it asks for, whether main's health can have moved.
--
-- A git that fails is NOT a round that changed nothing. This list is what the plan narrows on and what the gate's
-- rows file is proved against, so a broken `git merge-base`/`git diff` must never come back as an empty answer: an
-- empty list is read as "nothing to land", and a missing path is a row the gate then never asks for. The failure
-- is therefore returned by name in `notes`, and every caller that would narrow work on this list runs the whole
-- suite instead.

-- <repo> <base> <tip> -> fork sha, nil: the commit the branch and main parted at. Histories that share nothing
-- have no fork point (git exits 1), and that is a note, never a guess at "no changes".
function M.fork_point(repo, base, tip)
  local answer = M.exec("git -C " .. quote(slashes(repo)) .. " merge-base " .. quote(base) .. " " .. quote(tip),
    repo, 120)
  if (answer.code or 1) ~= 0 then
    return nil, first_line(tostring(answer.stderr ~= "" and answer.stderr or answer.stdout))
  end
  local fork = trim(tostring(answer.stdout or ""))
  if fork == "" then return nil, "git merge-base printed no commit" end
  return fork
end

function M.changed_paths(run)
  local repo = run.journal.repo or M.repo()
  local base = run.journal.base
  local seen, paths, notes = {}, {}, {}
  for _, branch in ipairs(run.journal.branches or {}) do
    if base and branch.sha then
      local fork, fork_error = M.fork_point(repo, base, branch.sha)
      if not fork then
        notes[#notes + 1] = "the changed paths of " .. tostring(branch.name or branch.sha) ..
          " could not be read (git merge-base " .. tostring(base) .. " " .. tostring(branch.sha) .. ": " ..
          tostring(fork_error) .. "), so the paths this round changes are unknown"
      else
        local listing = M.exec("git -C " .. quote(slashes(repo)) .. " diff --name-only --no-renames " ..
          quote(fork) .. " " .. quote(branch.sha), repo, 120)
        if (listing.code or 1) ~= 0 then
          notes[#notes + 1] = "the changed paths of " .. tostring(branch.name or branch.sha) ..
            " could not be read (git diff " .. tostring(fork) .. " " .. tostring(branch.sha) .. ": " ..
            first_line(tostring(listing.stderr ~= "" and listing.stderr or listing.stdout)) ..
            "), so the paths this round changes are unknown"
        else
          for path in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
            path = trim(path)
            if path ~= "" and not seen[path] then seen[path] = true; paths[#paths + 1] = path end
          end
        end
      end
    end
  end
  table.sort(paths)
  return paths, notes
end

-- <run> <paths> -> {category, counts, classifier} from `scripts/lib/land-classify.sh` (the ONE classification:
-- it calls `wa_compiled_input`, the same function the deploy's Lua fast path and the release digest use).
-- A tree without the classifier takes the FULL path and says so: a plan that guessed would be a plan that
-- skips work nobody proved unnecessary.
function M.classify(run, paths)
  local repo = run.journal.repo or M.repo()
  local counts, class_of = {}, {}
  -- The paths travel as ARGUMENTS, not through a file: a `--dry-run` promises to change nothing, and a
  -- scratch list under the run directory is still a write. ARG_MAX is ~2 MB on this platform and a 2000-path
  -- round is ~120 KB, so the ceiling is not reachable by a landing.
  local command = "bash scripts/lib/land-classify.sh --repo " .. quote(slashes(repo))
  for _, path in ipairs(paths) do command = command .. " " .. quote(path) end
  local listing = M.exec(command, repo, 300)
  if (listing.code or 1) ~= 0 then
    return { category = "compiled", counts = {}, classifier = "missing",
      why = "scripts/lib/land-classify.sh could not classify this tree (" ..
        first_line(tostring(listing.stderr ~= "" and listing.stderr or listing.stdout)) .. "), so the full path runs" }
  end
  for line in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
    local class, path = line:match("^(%S+)%s+(.+)$")
    if class and path then
      counts[class] = (counts[class] or 0) + 1
      class_of[#class_of + 1] = { class = class, path = trim(path) }
    end
  end
  local category = M.exec(command .. " --category", repo, 120)
  local word = trim(first_line(tostring(category.stdout or "")))
  if word == "" then
    return { category = "compiled", counts = counts, classifier = "no_answer",
      why = "land-classify.sh named no category for these paths, so the full path runs" }
  end
  return { category = word, counts = counts, classifier = "land-classify.sh", files = class_of }
end

-- <repo> -> {list, known, skips, why}: the rows this tree's fast path WOULD run, read from the one inventory
-- that defines them - `wa_fast_row_candidates` / `wa_fast_row_skips` in scripts/lib/fast-rows.sh, the same
-- functions scripts/fast.sh builds its `lua.list` with. `skips` carries the reason each declared row is not
-- run, so a plan can report it by name; `why` is set when the inventory cannot be read at all, and then no row
-- is proved necessary and the round runs the whole suite (the answer a missing classifier already gets).
--
-- A planner with its own idea of "runnable" is what asked for `scripts/test-agent-benchmark-runtime-route.lua`
-- (the file exists, but the ledger declares it not run), got `fast_narrow:unknown_row` and failed a whole gate
-- with 0 tests run: measured twice on the same 90-path round, land-20261118T172243Z-666a59cf and
-- land-20261118T173351Z-2a481142.
function M.row_inventory(repo)
  local listing = M.exec("bash -c " .. quote(". ./scripts/lib/fast-rows.sh || exit 3; wa_fast_row_candidates"), repo, 120)
  if (listing.code or 1) ~= 0 then
    return { list = {}, known = {}, skips = {},
      why = "the row inventory (scripts/lib/fast-rows.sh) could not be read in this tree: " ..
        first_line(tostring(listing.stderr ~= "" and listing.stderr or listing.stdout)) }
  end
  local list, known = {}, {}
  for line in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
    local row = trim(line)
    if row ~= "" and not known[row] then known[row] = true; list[#list + 1] = row end
  end
  local skips = {}
  local declared = M.exec("bash -c " .. quote(". ./scripts/lib/fast-rows.sh 2>/dev/null || exit 0; wa_fast_row_skips"), repo, 120)
  for line in tostring(declared.stdout or ""):gmatch("[^\r\n]+") do
    local row, why = line:match("^(%S+)\t(.*)$")
    if row and not known[row] then
      why = trim(why or "")
      if why == "" then why = "declared not run in scripts/fast-path.exclude" end
      skips[row] = why
    end
  end
  return { list = list, known = known, skips = skips }
end

-- <run> <paths> -> rows, not_rows, why: the Lua rows a narrowed fast-path run should execute (`scripts/fast.sh`
-- adds its never-dropped core rows itself, so this list is a REQUEST). A row is affected when the round changed
-- it, when its own name names a changed module (`lua/core/agent.lua` -> `scripts/test-agent*.lua`), or when its
-- text mentions the changed path - a dependency proved by the file, not guessed from the name. Only a row the
-- runner would run may be requested: an affected row that is declared not run comes back in `not_rows` with its
-- reason, so the plan prints "not a gate row: <reason>" and asks for nothing the filter would refuse. No row and
-- a non-doc change means the suite runs whole, which the plan reports as `full`.
function M.gate_rows(run, paths)
  local repo = run.journal.repo or M.repo()
  local rows, not_rows, seen = {}, {}, {}
  local inventory = M.row_inventory(repo)
  local function add(path)
    path = trim(path)
    if path == "" or seen[path] then return end
    if not path:match("^scripts/test%-[%w%._%-]+%.lua$") then return end
    seen[path] = true
    if not (inventory.known or {})[path] then
      not_rows[#not_rows + 1] = { path = path,
        why = (inventory.skips or {})[path] or inventory.why or "not a row this fast path runs" }
      return
    end
    rows[#rows + 1] = path
  end
  local modules = {}
  for _, path in ipairs(paths) do
    if path:match("^scripts/test%-[%w%._%-]+%.lua$") then add(path) end
    if path:match("^lua/.+%.lua$") then modules[#modules + 1] = path end
  end
  if #modules > 0 then
    -- The naming scan reads every test file in the tree - the rows this fast path runs AND the ones it declares
    -- not run - so an affected row that is declared not run is REPORTED (the naming is how it was found) while
    -- only the runnable ones can be requested. add() is the one gate between the two lists.
    local named = {}
    for _, row in ipairs(inventory.list or {}) do named[#named + 1] = row end
    for row in pairs(inventory.skips or {}) do named[#named + 1] = row end
    table.sort(named)
    for _, module in ipairs(modules) do
      local base_name = module:match("([^/]+)%.lua$") or ""
      if base_name ~= "" then
        for _, candidate in ipairs(named) do
          local file_name = candidate:match("([^/]+)%.lua$") or ""
          if file_name:find("test-" .. base_name, 1, true) then add(candidate) end
        end
        local mentions = M.exec("grep -rlF -- " .. quote(module) .. " scripts/test-*.lua 2>/dev/null", repo, 120)
        for line in tostring(mentions.stdout or ""):gmatch("[^\r\n]+") do add(line) end
      end
    end
  end
  table.sort(rows)
  table.sort(not_rows, function(a, b) return a.path < b.path end)
  return rows, not_rows, inventory.why
end

-- <run> -> {list, why}: the gate's checks for this round. The always-on two (`fast`, `prompt-docs`) are never
-- dropped; the others are added when a changed path touches their subject (M.GATE_TRIGGERS). A round whose
-- plan is `full` runs every check.
function M.gate_checks(run, options)
  if options.checks then return options.checks, #options.checks .. " check(s), named with --checks" end
  -- `--full` is the whole suite and every check: a human's escape hatch cannot mean half of one.
  if options.full then return M.DEFAULT_CHECKS, "every check (--full)" end
  local plan = run.journal.plan
  if not plan or plan.full then return M.DEFAULT_CHECKS, "every check (no narrower set was proved)" end
  local wanted = {}
  -- The always-on set is a floor, not a suggestion: a plan written before a check existed (or by an
  -- older tree) must not run less than the gate promises. fast and prompt-docs were already here;
  -- discrimination joins them because a test that cannot fail on the old code is the failure this
  -- gate exists to catch, whatever paths the plan happens to name.
  for _, name in ipairs(M.GATE_ALWAYS) do wanted[name] = true end
  for _, name in ipairs(plan.checks or {}) do wanted[name] = true end
  local list = {}
  for _, check in ipairs(M.DEFAULT_CHECKS) do if wanted[check.name] then list[#list + 1] = check end end
  -- A name the plan asked for that this tree does not define is refused rather than dropped: a gate that
  -- silently runs less than it said is the failure the always-on set exists to prevent.
  for _, name in ipairs(plan.checks or {}) do
    local found = false
    for _, check in ipairs(list) do if check.name == name then found = true break end end
    if not found then
      return M.DEFAULT_CHECKS, "every check (the plan named " .. tostring(name) .. ", which this tree does not define)"
    end
  end
  return list, table.concat((function()
    local names = {}
    for _, check in ipairs(list) do names[#names + 1] = check.name end
    return names
  end)(), " ")
end

-- Every journal under the run root, NEWEST FIRST, as paths. `find` takes the directory QUOTED and matches the
-- name itself, which is the only form that works: `ls -1dt '<dir>'/*/journal.json` cannot expand a glob the
-- shell never sees, so the listing came back empty and every reader of it saw no run at all - the estimate
-- fell back to the default table and a bare `wa land --resume` answered "nothing to resume" with runs sitting
-- in the directory (measured 19/11; scripts/test-land-resume-19-11.lua case 24). One listing, so no two
-- readers disagree.
local function journals_by_newest(limit)
  local listing = M.exec("find " .. quote(M.root()) .. " -maxdepth 2 -name journal.json -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -" .. tostring(limit or 20), "", 60)
  local paths = {}
  for line in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
    local path = line:match("^%S+%s+(.+)$")
    if path then paths[#paths + 1] = trim(path) end
  end
  return paths
end

-- The finished runs in the journal: what an estimate is made from. Only a run whose result is `done` is used -
-- a stopped round's step times are the part that worked, not what a round costs.
-- The journals the ancestry precondition reads for the last published release (newest first).
function M.published_journals() return journals_by_newest(40) end

function M.land_runs(limit)
  local runs = {}
  for _, path in ipairs(journals_by_newest(limit)) do
    local journal = json_file(path)
    if journal and journal.run and journal.result == "done" then runs[#runs + 1] = journal end
  end
  return runs
end

local function median(values)
  local list = {}
  for _, value in ipairs(values) do list[#list + 1] = value end
  if #list == 0 then return nil end
  table.sort(list)
  local middle = math.floor((#list + 1) / 2)
  if #list % 2 == 1 then return list[middle] end
  return math.floor((list[middle] + list[middle + 1]) / 2)
end

function M.duration_text(seconds)
  local total = tonumber(seconds) or 0
  if total < 60 then return string.format("%ds", total) end
  return string.format("%dm%02ds", math.floor(total / 60), total % 60)
end

-- <category> [runs] -> {seconds, per_step, from, samples}. Each step's expected time is the MEDIAN of the
-- runs that actually ran it (a skipped step measured 0 and would drag the median to nothing), falling back
-- per step to the hand-run round of 13/11 - so the first plan is comparable with every later one.
function M.estimate(category, runs)
  runs = runs or M.land_runs()
  local per_step, from = {}, nil
  local same, any = {}, {}
  for _, journal in ipairs(runs) do
    any[#any + 1] = journal
    if journal.plan and journal.plan.category == category then same[#same + 1] = journal end
  end
  local basis = (#same >= 2) and same or any
  from = (#basis > 0) and ("median of " .. tostring(#basis) .. " finished run(s)" .. ((#same >= 2) and " on this path" or ""))
    or "the hand-run round of 13/11 (no finished run in the journal yet)"
  local total = 0
  for _, name in ipairs(M.STEPS) do
    local samples = {}
    for _, journal in ipairs(basis) do
      local step = (journal.steps or {})[name]
      if step and tonumber(step.seconds) and (step.state == "done" or step.state == "skipped" or step.state == "flaky") then
        samples[#samples + 1] = tonumber(step.seconds)
      end
    end
    local value = median(samples)
    if value == nil then
      value = (M.ESTIMATE_BY_CATEGORY[category] or {})[name]
    end
    if value == nil then value = M.ESTIMATE_DEFAULTS[name] or 0 end
    per_step[name] = value
    total = total + value
  end
  return { seconds = total, per_step = per_step, from = from, samples = #basis }
end

-- <runs> -> the average total of the finished runs, for the report's comparison. Nothing is invented when
-- there are none: it answers nil and the report says so.
function M.journal_average(runs)
  runs = runs or M.land_runs()
  local sum, count = 0, 0
  for _, journal in ipairs(runs) do
    local total = 0
    for _, name in ipairs(M.STEPS) do
      local step = (journal.steps or {})[name]
      if step and tonumber(step.seconds) then total = total + tonumber(step.seconds) end
    end
    if total > 0 then sum = sum + total; count = count + 1 end
  end
  if count == 0 then return nil end
  return { average = math.floor(sum / count), runs = count }
end

-- <run> <paths> [notes] -> the plan table (the shape `journal.plan` holds), built the same way for a real round
-- and for `--dry-run`: one implementation, so a printed plan and the plan a round obeys cannot differ.
--
-- A non-empty `notes` (M.changed_paths could not read a diff) proves no narrowing: the plan is the FULL path,
-- with every check and no rows file, and `unknown_paths` carries the failure so the printed plan says so instead
-- of claiming a file count it does not have.
-- The ring entry that can only take a NODE RELEASE (item 28 release mode), or nil when every node in the
-- ring installs a tree. A release-installed node has no checkout, so nothing a Lua-only round builds - a
-- Lua-tree record, and a deploy that keeps the installed binary - reaches it.
local function ring_release_node(ring)
  for _, entry in ipairs(ring or {}) do
    if type(entry) == "table" and tostring(entry.mode or "") == "release" then return tostring(entry.node or "?") end
  end
  return nil
end

function M.build_plan(run, paths, notes, ring)
  local unknown = (notes and #notes > 0) and notes or nil
  local classified = unknown and { category = "compiled", counts = {}, files = {}, classifier = "unreadable",
    why = table.concat(unknown, "; ") } or M.classify(run, paths)
  local rows, not_rows, rows_why = {}, {}, nil
  if unknown then
    rows_why = "the paths this round changes could not be read, so no row is proved sufficient"
  else
    rows, not_rows, rows_why = M.gate_rows(run, paths)
  end
  -- A round with no provable row - and a round whose row inventory could not be read at all - runs the whole
  -- suite. A docs-only change narrows nothing either way: its gate is the suite, without a rows file.
  local full = (classified.category ~= "docs-only") and (#rows == 0 or rows_why ~= nil)
  local checks = M.gate_checks_for(paths)
  local names = {}
  for _, check in ipairs(M.DEFAULT_CHECKS) do
    if checks[check.name] then names[#names + 1] = check.name end
  end
  if full then
    for _, check in ipairs(M.DEFAULT_CHECKS) do
      local known = false
      for _, name in ipairs(names) do if name == check.name then known = true break end end
      if not known then names[#names + 1] = check.name end
    end
  end
  table.sort(names)
  local estimate = M.estimate(classified.category)
  local steps = M.plan_steps(classified.category)
  -- THE BRANCH'S OWN TESTS, named by the plan: this is the row a reader checks BEFORE the push ("what of mine
  -- will run?"), and 22/11's first real landing answered it in the step and nowhere in the plan. Computed from
  -- the same path list the step uses - the branch's FORK POINT to its tip - so a printed plan and the round
  -- cannot disagree, and a Rust branch says why it is skipped instead of leaving the row unmentioned.
  local rust_paths, own_rows = 0, {}
  for _, path in ipairs(paths or {}) do
    local spec = tostring(path)
    if spec:find("^rust/") then rust_paths = rust_paths + 1
    elseif spec:match("^scripts/test%-.+%.lua$") then own_rows[#own_rows + 1] = spec end
  end
  if unknown then
    steps.tests = { action = "run", why = "the paths this round changes could not be read (above), so the " ..
      "merged tree decides which of the branch's own rows run" }
  elseif rust_paths > 0 then
    steps.tests = { action = "skip", why = string.format("the branch changes Rust (%d file(s)): its tests need the " ..
      "new binary, so main-health judges them after the install", rust_paths) }
  elseif #own_rows > 0 then
    steps.tests = { action = "run", why = string.format("the branch's own %d row(s), each alone with its own home " ..
      "and ledger: %s", #own_rows, table.concat(own_rows, ", ")) }
  else
    steps.tests = { action = "skip", why = "the branch added or changed no scripts/test-*.lua of its own: " ..
      "nothing of its own to run" }
  end
  -- A LUA-ONLY ROUND MUST STILL SHIP A NODE RELEASE WHEN A RING NODE INSTALLS FROM ONE (review r1 #61).
  -- The lua-tree path is right for every node that deploys a tree and wrong for the one that cannot: a
  -- release-installed node has no checkout to deploy, so a round that skipped artifacts/ship/publish left it
  -- on its old binary with nothing to install. The ring is asked here, not assumed, and the plan names the
  -- node that forced the release. A caller that names no ring gets the configured one - the same ring the
  -- deploy will walk - so the two cannot disagree.
  if classified.category == "lua-scripts-only" then
    local release_node = ring_release_node(ring or M.ring({}))
    if release_node then
      local function forced(why) return { action = "run", why = why } end
      steps.artifacts = forced("node release: the ring includes " .. release_node ..
        " in release mode, a node with no checkout, so this round builds the node release the tree travels in")
      steps.artifacts.kind = "node-release"
      steps.sign = forced("signs the node release SHA256SUMS (the vault host, as always)")
      steps.ship = forced("ships the node release the release-mode node installs")
      steps.publish = forced("publishes the node release " .. release_node .. " fetches")
      steps.linux = forced("publishes the same commit's bundles on the public channel (a machine with no node " ..
        "installs from releases/index-linux.json), so the fresh-install channel cannot lag the release")
      steps.deploy = forced("the ring, in order: tree nodes take the Lua tree, " .. release_node ..
        " takes the published release (" .. release_node .. ":release)")
    end
  end
  -- A COMPILED ROUND THAT ALSO MOVES components.lock BUILDS THE BUNDLE IN THE SAME STEP, BEFORE THE DEPLOY
  -- (item 28): a bundle built after the deploy describes a lock the fleet already reads, and the node that takes
  -- both would take the new lock with the old bundle. A flag rather than a step, because the step that must do
  -- it is `artifacts`, which is ordered before `deploy` already.
  for _, path in ipairs(paths) do
    if trim(path) == "components.lock" and classified.category == "compiled" then
      steps.artifacts.also_components = "this round changes components.lock, so the components bundle is built and verified here with the node release, before any node takes either"
    end
  end
  return { category = classified.category, files = #paths, counts = classified.counts or {},
    classifier = classified.classifier, why = classified.why, steps = steps,
    checks = names, rows = rows, not_rows = not_rows, rows_why = rows_why, full = full,
    unknown_paths = unknown and tostring(unknown[1]) or nil,
    expected_seconds = estimate.seconds,
    expected_from = estimate.from, per_step = estimate.per_step }
end

impl.plan = function(run, options)
  local evidence = sink(run, "plan")
  local repo = run.journal.repo or M.repo()
  local paths, path_notes = M.changed_paths(run)
  if run.journal.release then
    -- A RELEASE CHANGES NO PATH (its tree IS main) and still takes the full path: every check, the node
    -- release, every step after the gate. The plan is built the way an unreadable diff is - nothing is
    -- narrowed - and then says what it really is.
    local plan = M.build_plan(run, {}, { "release of main's tip" }, M.ring(options))
    plan.classifier, plan.unknown_paths, plan.rows_why = "release", nil, nil
    plan.why = "a release is cut from main's tip: the whole gate (kept where this tree already passed it), then the node release"
    for _, name in ipairs({ "review", "merge", "push", "main" }) do
      plan.steps[name] = { action = "skip", why = "nothing to land: a release is cut from main's tip" }
    end
    run.journal.plan = plan
    local text = M.plan_text(run.journal)
    print(text)
    evidence(text .. "\n")
    return true, { detail = string.format("release: every check (%d), expected %s (%s)", #plan.checks,
      M.duration_text(plan.expected_seconds), plan.expected_from) }
  end
  -- A broken diff is evidence, not an empty round: M.build_plan takes the notes, names every one of them in the
  -- plan's own `why` line (which is printed and kept in the evidence below), and plans the FULL path - so an
  -- unreadable git costs time, never coverage.
  if #paths == 0 and #path_notes == 0 then
    return false, { error = "plan_no_changes", observed = "the collected branches introduce no path this tree does not already have",
      next = "nothing to land: a branch has no change of its own (main already contains it, or the branch is main's tip) - " ..
        "check it with `git -C " .. tostring(repo) .. " log --oneline $(git merge-base main <branch>)..<branch>`" }
  end
  local plan = M.build_plan(run, paths, path_notes, M.ring(options))
  run.journal.plan = plan
  -- The plan, printed BEFORE any step that changes anything, and kept in the journal so a later reader (or
  -- the report) knows which path this round took and why.
  local text = M.plan_text(run.journal)
  print(text)
  evidence(text .. "\n")
  return true, { detail = string.format("%s: %d path(s), %d check(s)%s, expected %s (%s)",
    plan.category, plan.files, #plan.checks,
    (not plan.full and plan.category ~= "docs-only") and (" over " .. tostring(#plan.rows) .. " Lua row(s)") or "",
    M.duration_text(plan.expected_seconds), plan.expected_from) }
end

-- <options> [run] -> plan, notes: the plan a `--dry-run` prints, resolved from what THIS checkout already has.
-- A dry run fetches nothing (the header says so), so a branch that is not here yet is named in `notes` and
-- left out rather than fetched to make the plan look complete.
function M.plan_preview(options, run)
  local repo = M.repo()
  local incoming = M.incoming()
  local notes = {}
  local tracked = tracking(incoming)
  local base = rev(repo, "origin/main") or rev(repo, "refs/remotes/" .. tracked .. "/main")
    or rev(repo, incoming .. "/main")
  if not base then
    return nil, { "no main in " .. tostring(repo) .. ": the plan needs a base, and a dry run does not fetch (run without --dry-run)" }
  end
  local branches = {}
  for _, name in ipairs(options.branches or {}) do
    local tip = rev(repo, "refs/heads/" .. name) or rev(repo, "refs/remotes/" .. tracked .. "/" .. name)
    if tip then
      branches[#branches + 1] = { name = name, sha = tip }
    else
      notes[#notes + 1] = name .. " is not in this checkout yet (collect fetches it), so the plan leaves it out"
    end
  end
  if #branches == 0 then return nil, notes end
  local shell = { id = (run and run.id) or "dry-run", journal = { repo = repo, base = base, branches = branches } }
  local paths, path_notes = M.changed_paths(shell)
  for _, note in ipairs(path_notes) do notes[#notes + 1] = note end
  if #paths == 0 and #path_notes == 0 then
    return nil, { "the named branches introduce no path this tree does not already have" }
  end
  return M.build_plan(shell, paths, path_notes, M.ring(options)), notes
end

-- The plan as text: what changed, which path, which steps run or are skipped and why, and what it should cost.
function M.plan_text(journal)
  local plan = journal.plan or {}
  local lines = {}
  local function add(line) lines[#lines + 1] = line end
  local counts = plan.counts or {}
  -- A round whose diff could not be read has no file count to print, and printing 0 would be a false statement.
  add(string.format("land: plan: %s -> %s",
    (plan.unknown_paths and "the changed paths could not be read")
      or (tostring(tonumber(plan.files or 0)) .. " path(s) changed"),
    tostring(plan.category or "unknown")))
  add(string.format("land:   compiled %d, component %d, lua %d, docs %d (classified by %s)",
    tonumber(counts.compiled or 0), tonumber(counts.component or 0), tonumber(counts.lua or 0), tonumber(counts.docs or 0),
    tostring(plan.classifier or "?")))
  if plan.why then add("land:   " .. tostring(plan.why)) end
  local rows = plan.rows or {}
  if journal.landing then
    -- A LANDING RUNS NO GATE (FACTORY.md rule 10): printing the checks the plan narrowed would say it does.
    add(journal.gate_landing and "land:   gate: the whole fast path on the merged tree (--gate asked for it)"
      or "land:   gate: none - a landing runs no gate (the gate belongs to `wa release cut`; --gate asks anyway)")
  else
    add(string.format("land:   gate: %s%s", table.concat(plan.checks or {}, " "),
      plan.full and " (the whole suite)" or (" over " .. tostring(#rows) .. " Lua row(s) of the suite")))
  end
  -- The rows this plan considered and may NOT ask for, each with the reason: an affected row the fast path
  -- declares not run is reported here, never requested - requesting one is `fast_narrow:unknown_row` and a
  -- round gated on zero tests.
  for _, skipped in ipairs(plan.not_rows or {}) do
    add("land:   not a gate row: " .. tostring(skipped.path) .. " (" .. tostring(skipped.why) .. ")")
  end
  if plan.rows_why then add("land:   no row inventory: " .. tostring(plan.rows_why)) end
  for _, name in ipairs(M.steps_for(journal)) do
    local step = (plan.steps or {})[name]
    -- A step of a landing has no plan entry (the plan describes the pipeline's steps): it runs, and the plan
    -- says so with the reason it exists rather than leaving a hole in the table.
    if step then
      add(string.format("land:   %-9s %-4s %s", name, step.action == "skip" and "skip" or "run", tostring(step.why or "")))
    elseif journal.landing then
      local why = ({ tests = "the branch's own added or changed scripts/test-*.lua, alone (skipped for a Rust branch)",
        install = "this node: the sentinel's deploy, the install record read back, the installed Lua compared",
        health = "main's health after a landing that changed lua/ or rust/, as an operation (its verdict is an event)",
      })[name] or "runs on every landing"
      add(string.format("land:   %-9s %-4s %s", name, "run", why))
    end
  end
  add(string.format("land:   expected %s (%s)", M.duration_text(plan.expected_seconds or 0), tostring(plan.expected_from or "?")))
  return table.concat(lines, "\n")
end

-- review: the landing reviewer (lua/core/harness_evaluator_reviewer.lua), on every branch of the round and
-- BEFORE that branch is merged, through the ONE door an operator uses - `wa eval reviewer <branch>` (the
-- same module, the same opt-out switch, the same store). There is no second reviewer and no wrapper script.
--
-- Each review is a PROCESS OF ITS OWN, started here and joined at the `report` step, so it runs while the
-- merge, the gate and everything after them run: `host.exec` returns as soon as the shell exits, so a child
-- that redirects its own streams outlives that call (measured on this host, 14/11), and the landing does not
-- sit waiting for a model. Findings are evidence about the branch, never a verdict on it: nothing in this
-- step, and nothing in the join, can stop a landing.
--
-- What it replaces: the step used to look for `scripts/review-branch.mjs` in the landed tree and skip with
-- "reviewer not on main" - a file that never existed, so the review step would have skipped forever while the
-- reviewer that DID land (`wa eval reviewer`) ran only when an operator typed it.
M.REVIEW_WAIT = 900

-- The reviewer's module, loaded the way `wa eval reviewer` loads it: the same file, so the switch, the model
-- and the store are one implementation. `pcall` because a checkout without it is a sentence to report, not a
-- crash in the middle of a landing.
function M.review_engine()
  local ok, engine = pcall(dofile, "lua/core/harness_evaluator_reviewer.lua")
  if not ok or type(engine) ~= "table" or type(engine.switch) ~= "function" then
    return nil, "the reviewer module could not be loaded: " .. tostring(engine)
  end
  return engine
end

-- The binary a review runs with: the one this landing is running as, unless a test names another. A review
-- started from a door that resolves its own binary could otherwise be a different build from the tree being
-- landed.
function M.review_binary()
  if M.review_binary_path and M.review_binary_path ~= "" then return slashes(M.review_binary_path) end
  local ok, raw = pcall(host.runtime_info)
  local info = ok and (type(raw) == "string" and json.decode(raw) or raw) or nil
  local path = type(info) == "table" and info.binary_path or nil
  if type(path) == "string" and path ~= "" then return slashes(path) end
  return nil, "no binary to run the reviewer with (host.runtime_info() names no binary_path)"
end

-- One file stem per branch under the run's own directory: the reviewer's answer, its log and its exit code
-- are evidence beside the rest of the round's, not scratch in a temporary directory.
local function review_stem(run, branch)
  local slug = tostring(branch or "branch"):lower():gsub("[^a-z0-9._-]", "-"):gsub("%-+", "-")
  if slug == "" then slug = "branch" end
  return M.run_dir(run.id) .. "/review/" .. slug
end

-- Is the review's process still there? `kill -0` says whether the pid exists without touching it.
function M.review_alive(pid)
  local number = tonumber(pid)
  if not number then return false end
  local probe = M.exec("kill -0 " .. tostring(number) .. " 2>/dev/null && echo alive || echo gone", "", 60)
  return tostring(probe.stdout or ""):find("alive", 1, true) ~= nil
end

-- Start ONE review in the background and record what is needed to join it: its branch and tip, the base it
-- is diffed against, the brief it was given, its pid, its answer file, its log and its exit code.
--
-- The answer file is the reviewer's own `--json` (added to that door for exactly this caller): "the review ran,
-- here are its findings" and "the review could not run, here is why" arrive in the same place, so a landing
-- never has to read a sentence to learn which happened.
function M.review_start(run, branch, base, repo, bin)
  local stem = review_stem(run, branch.name)
  local job = { branch = branch.name, ref = branch.ref, sha = branch.sha, base = base,
    brief = branch.brief, json = stem .. ".json", log = stem .. ".log", code_path = stem .. ".code",
    started_at = now() }
  M.exec("mkdir -p " .. quote(M.run_dir(run.id) .. "/review"), "", 120)
  local parts = { quote(bin), "eval", "reviewer", quote(branch.name), "--repo", quote(repo),
    "--base", quote(base), "--bin", quote(bin), "--json", quote(job.json) }
  if job.brief and job.brief ~= "" then
    parts[#parts + 1] = "--brief"
    parts[#parts + 1] = quote(job.brief)
  end
  -- `{ ...; } & echo $!` starts the review, leaves its streams in files (so the shell that started it exits
  -- at once instead of holding a pipe open) and answers its pid; the trailing `echo $? >` is what tells the
  -- join that the review finished with which exit, even when it wrote no answer.
  local command = "{ " .. table.concat(parts, " ") .. " > " .. quote(job.log) .. " 2>&1; echo $? > "
    .. quote(job.code_path) .. "; } & echo $!"
  job.command = command
  local started = M.exec(command, repo, 120)
  job.pid = tonumber((trim(started.stdout):match("%d+") or ""))
  if (started.code or 1) ~= 0 or not job.pid then
    return nil, "the review could not be started: "
      .. first_line((started.stderr or "") ~= "" and started.stderr or started.stdout)
  end
  return job
end

impl.review = function(run, options)
  local evidence = sink(run, "review")
  local base = run.journal.base
  local repo = run.journal.repo or M.repo()
  local branches = run.journal.branches or {}
  if not base or #branches == 0 then
    return true, { state = "skipped", detail = "nothing to review: no branch was collected" }
  end
  local engine, engine_error = M.review_engine()
  if not engine then
    return true, { state = "skipped", detail = "review unavailable: " .. tostring(engine_error) }
  end
  -- The opt-out is the reviewer's OWN switch (`reviewer = off` in the node's config file, or WA_REVIEWER), read
  -- through the reviewer's own module: a landing must not be a second place where "reviewer = off" can mean
  -- something else.
  local switch = engine.switch()
  if not switch.on then
    evidence("the reviewer is off (" .. tostring(switch.source) .. " = " .. tostring(switch.value) .. ")\n")
    return true, { state = "skipped", detail = "reviewer off (" .. tostring(switch.source) .. " = "
      .. tostring(switch.value) .. "): nothing was reviewed" }
  end
  local bin, bin_error = M.review_binary()
  if not bin then
    return true, { state = "skipped", detail = "review unavailable: " .. tostring(bin_error) }
  end
  -- A resume must not review the same tip twice: a job already recorded for this branch and sha is kept, and
  -- a job that never got a pid is dropped (it never ran, so it is retried rather than remembered as a review
  -- that happened).
  local kept, known = {}, {}
  for _, job in ipairs(run.journal.review_jobs or {}) do
    if job.pid then
      kept[#kept + 1] = job
      known[job.branch .. "@" .. tostring(job.sha)] = job
    end
  end
  run.journal.review_jobs = kept
  local started, refused = 0, {}
  for _, branch in ipairs(branches) do
    local known_job = known[branch.name .. "@" .. tostring(branch.sha)]
    if known_job then
      evidence(string.format("%s is already being reviewed (started %s, pid %s): not started again\n",
        tostring(branch.name), tostring(known_job.started_at), tostring(known_job.pid)))
      started = started + 1
    else
      local job, problem = M.review_start(run, branch, base, repo, bin)
      evidence(command_line("review " .. tostring(branch.name), job and job.command or "(not started)"))
      if job then
        run.journal.review_jobs[#run.journal.review_jobs + 1] = job
        started = started + 1
        evidence(string.format("started pid %s: it answers in %s, its log is %s\n", tostring(job.pid),
          tostring(job.json), tostring(job.log)))
      else
        -- Recorded as a job so the report shows the branch by name with "review unavailable: <reason>" - the
        -- sentence this step must never replace with silence.
        run.journal.review_jobs[#run.journal.review_jobs + 1] = { branch = branch.name, sha = branch.sha,
          started_at = now(), start_failed = tostring(problem) }
        refused[#refused + 1] = tostring(problem)
        evidence("review unavailable: " .. tostring(problem) .. "\n")
      end
    end
  end
  local detail = string.format("%d review(s) started, joined at the report (findings are never blocking)", started)
  if #refused > 0 then
    detail = string.format("%d started, %d review unavailable: %s", started, #refused, refused[1])
  end
  return true, { state = started > 0 and "started" or "skipped", detail = detail }
end

-- Join the reviews the review step started: wait for each process (bounded by M.REVIEW_WAIT, because a review
-- is a model session of minutes and the landing it overlaps usually outlasts it), then write one row per
-- branch into the journal and into the review step. Called by `report` - the step that runs last and runs even
-- when the machine stopped - so the findings are in the journal and the report whatever happened.
--
-- A review that failed, answered about another commit, or has not finished is a ROW, never a stop and never a
-- silence: its own words travel as "review unavailable: <reason>".
function M.review_collect(run)
  local jobs = run.journal.review_jobs or {}
  if #jobs == 0 then return nil end
  local limit = tonumber(M.REVIEW_WAIT) or 900
  local deadline = now() + limit
  local function finished(job)
    if job.start_failed or job.finished then return true end
    local code = read(job.code_path)
    if code and trim(code) ~= "" then
      job.finished, job.exit_code = true, tonumber(trim(code))
      return true
    end
    if job.pid and not M.review_alive(job.pid) then
      -- Gone without leaving an exit code: the process was killed (or the host cleaned it up with the call
      -- that started it) and there is nothing to read. Said as such, not as "no findings".
      job.finished, job.lost = true, true
      return true
    end
    return false
  end
  local waiting = true
  while waiting and now() < deadline do
    waiting = false
    for _, job in ipairs(jobs) do
      if not finished(job) then waiting = true end
    end
    if waiting then M.sleep(1) end
  end
  -- One last look AFTER the bound, for two reasons: a review that finished while the report waited must not be
  -- reported as still running, and a process that is gone is known without waiting for anything at all (a
  -- bound of zero is a caller saying "say what you know now").
  for _, job in ipairs(jobs) do finished(job) end
  local rows = {}
  for _, job in ipairs(jobs) do
    local row = { branch = job.branch, sha = job.sha, base = job.base, log = job.log,
      seconds = job.started_at and (now() - job.started_at) or nil }
    local answer = job.json and json_file(job.json) or nil
    if job.start_failed then
      row.state = "unavailable"
      row.unavailable = "review unavailable: " .. tostring(job.start_failed)
    elseif answer then
      row.review_id = answer.review_id
      row.state = tostring(answer.state or "unknown")
      row.findings = tonumber(answer.findings)
      row.answer = tostring(answer.answer or ""):sub(1, 4000)
      local answered = tostring(answer.sha or "")
      if answer.ok ~= true or row.state ~= "reviewed" then
        row.unavailable = "review unavailable: "
          .. tostring(answer.error or ("the reviewer answered " .. tostring(row.state)))
      elseif answered ~= "" and answered ~= job.sha then
        -- The review is about a commit, and a tip that moved under it is not this branch's review.
        row.unavailable = "review unavailable: the reviewer answered about " .. answered:sub(1, 12)
          .. ", not " .. tostring(job.sha):sub(1, 12)
      end
    elseif job.lost then
      row.state = "unavailable"
      row.unavailable = "review unavailable: the review process is gone without an answer: "
        .. first_line(read(job.log) or "")
    elseif job.finished then
      row.state = "unavailable"
      local tail = tostring(read(job.log) or "")
      local last = trim(tail:sub(-400)):sub(-200)
      row.unavailable = "review unavailable: wa eval reviewer exited " .. tostring(job.exit_code or "?")
        .. (last ~= "" and (": " .. last) or "")
    else
      row.state = "running"
      row.unavailable = "review unavailable: still running after " .. tostring(limit)
        .. "s - its log is " .. tostring(job.log) .. " and its record arrives in `wa eval reviewer list`"
    end
    rows[#rows + 1] = row
  end
  run.journal.review = rows
  local step = step_of(run.journal, "review")
  local reviewed, findings, missing = 0, 0, {}
  for _, row in ipairs(rows) do
    if row.state == "reviewed" and not row.unavailable then
      reviewed = reviewed + 1
      findings = findings + (tonumber(row.findings) or 0)
    else
      missing[#missing + 1] = tostring(row.unavailable)
    end
  end
  -- The step's own `finished_at`/`seconds` are NOT touched: the plan learns a step's cost from them, and the
  -- time the report spent joining the reviews is the report's, not the step's.
  if reviewed > 0 then
    step.state = "done"
    step.detail = string.format("%d branch(es) reviewed, %d finding(s)", reviewed, findings)
  else
    -- Nothing was reviewed: the sentence IS the detail, so `wa land status` and the report cannot read this as
    -- a review that happened and found nothing.
    step.state = "done"
    step.detail = table.concat(missing, "; ")
  end
  if #missing > 0 and reviewed > 0 then
    step.detail = step.detail .. "; " .. table.concat(missing, "; ")
  end
  return rows
end

-- ---------------------------------------------------------------- derived files, regenerated on the merge
--
-- A file that is GENERATED and committed goes stale in the one place no worker can see: the merge. On 21/11
-- land243 added lua/core/agent_control.lua and its refusal codes, land244 was green (its narrowed gate never
-- ran scripts/test-refusal-contract.lua), and main was red from bfad4f8f for the next landings - every later
-- mission whose rows included that row paid for a fault nobody had made. Two branches that are each correct
-- alone are only wrong together, so the repair belongs here and not in the gate.
--
-- What this does, exactly, and nothing else:
--   * scripts/generators.txt is the registry: for each derived file, the paths it is written to and the one
--     command that writes them from the tree (scripts/generators.txt says what may and may not be listed).
--     A tree without a registry regenerates nothing, and the step says that instead of looking clean;
--   * scripts/regenerate.sh runs every generator with --write on the MERGED tree and prints the paths it
--     changed. A generator that fails is a STOP by name: a derived file we could not recompute is not a file
--     to land;
--   * whatever it changed is put in the MERGE COMMIT (staged, then the merge commit amended), so main's tip
--     is green on its own rows without a second commit nobody asked for;
--   * a merge that conflicts ONLY in the paths the registry declares as generated is resolved by taking our
--     side and regenerating: that conflict is in bytes no person wrote. A conflict anywhere else is a stop,
--     exactly as before - the allow-list is the registry, never a guess about a file name.

-- <tree> -> set of the paths this tree declares as generated, or nil and the reason it could not be told.
function M.regenerate_outputs(tree)
  if not read(tree .. "/scripts/regenerate.sh") then
    return nil, "this tree has no scripts/regenerate.sh, so it declares no generated file"
  end
  local listing = M.exec("bash scripts/regenerate.sh --outputs", tree, 120)
  if (listing.code or 1) ~= 0 then
    return nil, "scripts/regenerate.sh --outputs exited " .. tostring(listing.code) .. ": " ..
      first_line(tostring(listing.stderr ~= "" and listing.stderr or listing.stdout))
  end
  local set = {}
  for line in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
    local path = trim(line)
    if path ~= "" then set[path] = true end
  end
  return set
end

-- <run> <tree> <evidence-sink> -> ok, info: run every registered generator on the merged tree and put what
-- it wrote into the merge commit. `info.changed` is the list of paths this run wrote (empty when the tree was
-- already current, which is the normal case).
function M.regenerate(run, tree, evidence)
  local note = evidence or function() end
  if not read(tree .. "/scripts/regenerate.sh") then
    return true, { ran = false, changed = {},
      why = "no scripts/regenerate.sh in the merged tree: nothing declares a derived file" }
  end
  local result = M.exec("bash scripts/regenerate.sh", tree, 900)
  local out = tostring(result.stdout or "")
  note(command_line("regenerate", "bash scripts/regenerate.sh"))
  note(out .. tostring(result.stderr or ""))
  if (result.code or 1) ~= 0 then
    local failed = {}
    for line in out:gmatch("[^\r\n]+") do
      if line:find("regenerate: FAILED", 1, true) then failed[#failed + 1] = trim(line) end
    end
    return false, { error = "regenerate_failed",
      observed = (#failed > 0 and table.concat(failed, "; ")
        or ("scripts/regenerate.sh exited " .. tostring(result.code) .. ": " ..
            first_line(tostring(result.stderr ~= "" and result.stderr or result.stdout)))),
      next = "fix the generator in scripts/generators.txt, or the file it writes, and land again" }
  end
  local changed, count = {}, nil
  for line in out:gmatch("[^\r\n]+") do
    local path = line:match("^regenerate: changed (%S.*)$")
    if path then changed[#changed + 1] = trim(path) end
    local n = line:match("^regenerate: changed_count (%d+)$")
    if n then count = tonumber(n) end
  end
  -- A generator wrote files and the runner did not say which: the amendment below would stage a guess.
  if count == nil then
    return false, { error = "regenerate_unreadable",
      observed = "scripts/regenerate.sh exited 0 but printed no 'changed_count' line: " .. first_line(out),
      next = "scripts/regenerate.sh must print 'regenerate: changed_count <n>' (it is what tells the merge whether to amend)" }
  end
  if count == 0 or #changed == 0 then
    return true, { ran = true, changed = {} }
  end
  -- ONLY THE PATHS THE GENERATORS SAID THEY WROTE: `add -A` would also put any stray file a generator (or
  -- anything else in this tree) left behind into the merge commit that becomes main.
  local quoted = {}
  for _, path in ipairs(changed) do quoted[#quoted + 1] = quote(path) end
  local added = git(run, tree, "add -- " .. table.concat(quoted, " "), 300)
  if (added.code or 1) ~= 0 then
    return false, { error = "regenerate_unstaged",
      observed = first_line(tostring(added.stderr ~= "" and added.stderr or added.stdout)),
      next = "the generated files are on disk in " .. tree .. " but could not be staged" }
  end
  local head = git(run, tree, "log -1 --format=%B", 60)
  local lines = { trim(tostring(head.stdout or "")), "",
    string.format("regenerate: %d derived file(s) refreshed by scripts/regenerate.sh on the merged tree", #changed) }
  for _, path in ipairs(changed) do lines[#lines + 1] = "regenerate: " .. path end
  local amended = git(run, tree, "commit --amend --no-edit -m " .. quote(table.concat(lines, "\n")), 300)
  note(command_line("regenerate amend", "git commit --amend (" .. #changed .. " generated file(s))"))
  note((amended.stdout or "") .. (amended.stderr or ""))
  if (amended.code or 1) ~= 0 then
    return false, { error = "regenerate_uncommitted",
      observed = first_line(tostring(amended.stderr ~= "" and amended.stderr or amended.stdout)),
      next = "the regenerated files are staged in " .. tree .. " but the merge commit was not amended" }
  end
  return true, { ran = true, changed = changed, commit = rev(tree, "HEAD") }
end

-- <run> <tree> <branch> <evidence> <message> -> ok, why: the merge this landing may finish BY ITSELF.
-- It is allowed to finish only when EVERY unmerged path is a path the tree's registry declares as generated;
-- then our side is taken and staged, and M.regenerate writes the real content afterwards. Any other
-- unmerged path aborts the merge again and the landing stops, as it always did.
local function merge_generated_conflict(run, tree, branch, evidence, message)
  local declared, why = M.regenerate_outputs(tree)
  if not declared then return false, why end
  local merged = git(run, tree, "merge --no-ff --no-edit -m " .. quote(message) .. " " .. quote(branch.sha), 600)
  evidence(command_line("merge (conflicted) " .. branch.name, "git merge " .. branch.sha))
  evidence((merged.stdout or "") .. (merged.stderr or ""))
  local unmerged = {}
  local listing = git(run, tree, "diff --name-only --diff-filter=U", 120)
  for line in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
    local path = trim(line)
    if path ~= "" then unmerged[#unmerged + 1] = path end
  end
  if #unmerged == 0 then
    git(run, tree, "merge --abort", 120)
    return false, "the merge failed without naming an unmerged path: " ..
      first_line(tostring(merged.stderr ~= "" and merged.stderr or merged.stdout))
  end
  local foreign = {}
  for _, path in ipairs(unmerged) do
    if not declared[path] then foreign[#foreign + 1] = path end
  end
  if #foreign > 0 then
    git(run, tree, "merge --abort", 120)
    return false, "the conflict is not only in a generated file: " .. table.concat(foreign, ", ")
  end
  for _, path in ipairs(unmerged) do
    local ours = git(run, tree, "checkout --ours -- " .. quote(path), 120)
    if (ours.code or 1) ~= 0 then
      git(run, tree, "merge --abort", 120)
      return false, "cannot take our side of " .. path .. ": " ..
        first_line(tostring(ours.stderr ~= "" and ours.stderr or ours.stdout))
    end
    local staged = git(run, tree, "add -- " .. quote(path), 120)
    if (staged.code or 1) ~= 0 then
      git(run, tree, "merge --abort", 120)
      return false, "cannot stage the resolved " .. path
    end
  end
  evidence("resolved as generated (the merge regenerates them): " .. table.concat(unmerged, ", "))
  local committed = git(run, tree, "commit --no-edit", 300)
  if (committed.code or 1) ~= 0 then
    git(run, tree, "merge --abort", 120)
    return false, "the merge with the generated files resolved did not commit: " ..
      first_line(tostring(committed.stderr ~= "" and committed.stdout or committed.stdout))
  end
  return true, table.concat(unmerged, ", ")
end

-- merge: a fresh worktree cut from the base, then one merge per branch. Conflicts stop the landing and keep
-- the worktree: it is the evidence a human resolves against.
impl.merge = function(run, options)
  local evidence = sink(run, "merge")
  local repo = run.journal.repo or M.repo()
  local base = run.journal.base
  -- FACTORY.md rule 8, applied where the base is known and before anything is merged: a landing onto a RED main
  -- is refused by name, with the row that says so, unless this landing IS the fix (`--fix-main`).
  if options.landing and not options.fix_main then
    local red = M.main_red(base)
    if red then
      local observed = string.format("main-health measured %s red at %s: %s", tostring(red.sha):sub(1, 12),
        tostring(red.at), tostring(red.detail))
      M.emit(run, "refused", "red", "main is red: " .. observed, { sha = tostring(base) })
      return false, { error = "main_red", detail = "main is red, so this landing waits for the fix (FACTORY.md rule 8)",
        observed = observed,
        next = "land the fix on its own with `wa land <the fix branch> --fix-main`, or measure main again: " ..
          "bash scripts/main-health.sh --repo <checkout>" }
    end
  end
  local tree = run.tree
  if tree and not rev(tree, "HEAD") then
    -- A resume whose worktree is gone: the merges are redone from the base rather than reported as done.
    print("land: merge: the worktree " .. tostring(tree) .. " is gone; recreating it")
    tree = nil
  end
  if not tree then
    -- The format is QUOTED: an unquoted `%(refname:short)` is a shell syntax error, so the listing came
    -- back empty, every run believed it was `land1`, and the second landing of a session died on
    -- "'land1/final' is already used by worktree" (measured 13/11; the case is in
-- scripts/test-land-sign.lua now).
    local listing = git(run, repo, "for-each-ref " .. quote("--format=%(refname:short)") ..
      " " .. quote("refs/heads/land*/final"))
    local highest = 0
    local function claim(name)
      local number = trim(name):match("land(%d+)/final$")
      if number then highest = math.max(highest, tonumber(number)) end
    end
    for name in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do claim(name) end
    -- THE INCOMING REPOSITORY'S OWN LAND BRANCHES COUNT TOO. A previous landing, from another checkout or
    -- another node, leaves `land<N>/final` on the incoming remote; taking that number again would push the
    -- new round on top of a ref somebody else's landing already reads, and the push step reads a remote ref
    -- back expecting its own commit. So the free number is asked of the remote as well, and a remote that
    -- cannot answer is a refusal by name - a number nobody proved free is not a number to push onto.
    local remote = git(run, repo, "ls-remote --heads " .. quote(M.incoming()) .. " " .. quote("refs/heads/land*/final"), 300)
    if (remote.code or 1) ~= 0 then
      -- THE SAME RULE AS THE FETCH (review r1, item 4): a round that stops at or before the gate takes the
      -- free landing-branch number from the refs this checkout has and says so, instead of refusing because
      -- another node is asleep. A landing still refuses: it must know the remote number, because it pushes
      -- onto it.
      if M.remote_is_named(M.incoming()) and M.stops_by_gate(options) then
        evidence("ls-remote: WARN " .. M.incoming() .. " could not be listed (" ..
          first_line(tostring(remote.stderr ~= "" and remote.stderr or remote.stdout)) ..
          "); the landing-branch number comes from the refs this checkout has\n")
      else
      return false, { error = "land_branch_unknown",
        observed = "cannot list the landing branches of " .. M.incoming() .. ": " ..
          first_line(tostring(remote.stderr ~= "" and remote.stderr or remote.stdout)),
        next = "check the incoming remote (" .. M.incoming() .. ") is reachable, then `wa land --resume`" }
      end
    end
    for line in tostring(remote.stdout or ""):gmatch("[^\r\n]+") do claim(line) end
    local number = highest + 1
    tree = (run.tree_dir or (M.run_dir(run.id) .. "/tree"))
    local branch = "land" .. number .. "/final"
    local added = git(run, repo, "worktree add --quiet -b " .. quote(branch) .. " " .. quote(tree) .. " " .. quote(base), 600)
    evidence(command_line("worktree", "git worktree add -b " .. branch .. " " .. tree .. " " .. base))
    evidence((added.stdout or "") .. (added.stderr or ""))
    if (added.code or 1) ~= 0 and tostring(added.stderr or ""):find("already exists") then
      -- The branch survived an earlier attempt but its worktree did not: attach a worktree to it instead of
      -- inventing a second land<N> for the same work.
      added = git(run, repo, "worktree add --quiet " .. quote(tree) .. " " .. quote(branch), 600)
      evidence(command_line("worktree (existing branch)", "git worktree add " .. tree .. " " .. branch))
      evidence((added.stdout or "") .. (added.stderr or ""))
    end
    if (added.code or 1) ~= 0 then
      -- What git actually said, what it exited with, and the command that failed - one durable
      -- sentence. An EMPTY observed was the bug: the old line reported first_line(stderr or stdout), so a
      -- failure carrying neither stream reported nothing at all; measured 19/11, worktree_failed came back
      -- with observed:"" four times (21:45-22:23Z) while the same git command worked by hand. The step
      -- recorder keeps observed, error and next, so every fact a reader needs goes in observed.
      local detail = trim(tostring(added.stderr or ""))
      if detail == "" then detail = trim(tostring(added.stdout or "")) end
      local parts = { last_line(detail ~= "" and detail or "(git answered with no output)"),
        "exit " .. tostring(added.code),
        "command: git worktree add -b " .. branch .. " " .. tree .. " " .. base }
      if added.raw ~= nil then
        parts[#parts + 1] = "raw host answer: " .. tostring(added.raw):sub(1, 400)
      elseif trim(tostring(added.stdout or "")) ~= "" and detail ~= trim(tostring(added.stdout or "")) then
        parts[#parts + 1] = "stdout: " .. last_line(added.stdout)
      end
      return false, { error = "worktree_failed", observed = table.concat(parts, "; "),
        next = "check " .. tree .. " (an existing worktree there is reused only when the journal names it)" }
    end
    run.tree, run.land_branch = tree, branch
    run.journal.land_branch = branch
    run.journal.tree = tree
    save(run)
  end
  for _, branch in ipairs(run.journal.branches) do
    -- `merge-tree --write-tree` first: it answers "would this conflict" without touching the tree, so a
    -- conflict leaves HEAD exactly where the last good merge left it.
    local probe = git(run, tree, "merge-tree --write-tree HEAD " .. quote(branch.sha), 600)
    evidence(command_line("merge-tree " .. branch.name, "git merge-tree --write-tree HEAD " .. branch.sha))
    evidence((probe.stdout or "") .. (probe.stderr or ""))
    if (probe.code or 1) ~= 0 then
      -- A commit the worktree does not have is a different refusal from a conflict: say which.
      local known = git(run, tree, "rev-parse --verify --quiet " .. quote(branch.sha .. "^{commit}"))
      if (known.code or 1) ~= 0 then
        return false, { error = "commit_missing", observed = branch.name .. " is not in the worktree: " .. branch.sha }
      end
      -- A CONFLICT IN A GENERATED FILE IS NOT A CONFLICT OF WORK: two branches that each regenerated the
      -- same derived file disagree about bytes nobody wrote by hand, so the merge resolves it and the
      -- regeneration after the loop writes the real content. Anything else stops, as it always did.
      local message = "land " .. tostring(run.journal.land_branch) .. ": merge " .. branch.name
      local resolved, why = merge_generated_conflict(run, tree, branch, evidence, message)
      if not resolved then
        return false, { error = "merge_conflict",
          observed = branch.name .. " conflicts with " .. tostring(run.journal.land_branch) ..
            (why and (" - " .. tostring(why)) or ""),
          next = "resolve it in " .. tree .. " (the worktree is kept), or land a fixed branch" }
      end
      run.journal.regenerate_resolved = run.journal.regenerate_resolved or {}
      run.journal.regenerate_resolved[#run.journal.regenerate_resolved + 1] = { branch = branch.name, paths = why }
    end
    local command = "merge --no-ff --no-edit -m " .. quote("land " .. tostring(run.journal.land_branch) .. ": merge " .. branch.name) .. " " .. quote(branch.sha)
    local result = git(run, tree, command, 600)
    evidence(command_line("merge " .. branch.name, "git " .. command))
    evidence((result.stdout or "") .. (result.stderr or ""))
    if (result.code or 1) ~= 0 then
      return false, { error = "merge_failed", observed = first_line(result.stderr ~= "" and result.stderr or result.stdout) }
    end
    branch.merged = true
    save(run)
  end
  -- DERIVED FILES, after every branch is merged and BEFORE the tree commit is recorded: what this writes
  -- is part of the tree the gate judges and the commit main will get (scripts/generators.txt).
  local regenerated, regen = M.regenerate(run, tree, evidence)
  if not regenerated then
    return false, regen
  end
  run.journal.regenerate = { ran = regen.ran, changed = regen.changed, commit = regen.commit, why = regen.why }
  run.journal.tree_commit = rev(tree, "HEAD")
  -- THE BYTES, SEPARATE FROM THE COMMIT THAT CARRIES THEM. A merge commit has its own committer timestamp,
  -- so the SAME content merged twice is TWO commits (measured 21/11: a preflight and the landing that
  -- followed it produce different tree commits for an identical merge). The tree object is the content
  -- alone, so it is what a gate verdict is really about, and it is recorded here for the gate to keep a
  -- verdict across runs with (M.gate_history).
  run.journal.tree_sha = tree_of(tree)
  local detail = string.format("%d branch(es) merged into %s (%s)", #run.journal.branches,
    tostring(run.journal.land_branch), tostring(run.journal.tree_commit):sub(1, 12))
  if regen and regen.changed and #regen.changed > 0 then
    detail = detail .. "; regenerate wrote " .. table.concat(regen.changed, ", ")
  elseif regen and regen.ran == false then
    detail = detail .. "; no generator: " .. tostring(regen.why)
  end
  return true, { detail = detail }
end

-- gate: the checks, weighted, one run each - and a failing check is re-run ONCE ALONE. Passing alone after
-- failing under load is reported as `flaky under load: <name>` and STOPS the landing: a human decides,
-- nothing here turns it green.
local function passed_tests(text)
  local total = 0
  for count in tostring(text or ""):gmatch("test result: ok%. (%d+) passed") do total = total + (tonumber(count) or 0) end
  return total
end

-- <check> <rows_file> -> the command this round runs the check with. `fast` ALWAYS carries a WA_FAST_ROWS
-- assignment: the file when the round narrowed, and an EMPTY value when it did not. Empty is not the same as
-- absent - `scripts/fast.sh` narrows on `[ -n "${WA_FAST_ROWS:-}" ]` - so a WA_FAST_ROWS inherited from the
-- environment would narrow a round that wrote no file: a `--full` run would execute less than it said, obeying
-- somebody else's plan. Every other check runs untouched.
function M.gate_command(check, rows_file, run)
  if check.name == "fast" then
    -- THE FAILED ROWS' OWN LOGS STAY WITH THIS RUN (item 3 of the harness-fixes-2 round): fast.sh
    -- copies every failed row's log here before it deletes its scratch directory, so a red gate can
    -- still be read after the fact instead of only the one line gate.log already had.
    local keep = run and M.run_dir(run.id) .. "/evidence/fast-logs" or ""
    local keep_env = keep ~= "" and (" WA_FAST_KEEP_LOGS=" .. quote(keep)) or ""
    return "WA_FAST_ROWS=" .. (rows_file and quote(rows_file) or "") .. keep_env .. " " .. check.command
  end
  -- The discrimination check is the only one whose VERDICT depends on which round it is judging: a
  -- Refactor-only declaration must be refused in a round of several branches, and the base is whichever
  -- main this round merged into (incoming/main may contain origin/main). Without these the check judged
  -- the wrong base and never saw the round at all (review r2, MUST 2 and 3).
  if check.name == "discrimination" and run and run.journal then
    local names = {}
    for _, branch in ipairs(run.journal.branches or {}) do
      local name = tostring(branch.name or branch.sha or "")
      if name ~= "" then names[#names + 1] = name end
    end
    local command = check.command
    if #names > 0 then command = command .. " --branches " .. quote(table.concat(names, ",")) end
    local base = run.journal.base
    if base and tostring(base) ~= "" then command = command .. " " .. tostring(base) end
    return command
  end
  return check.command
end

-- <run> <options> -> path, failed, notes: the WA_FAST_ROWS file this round narrows `scripts/fast.sh` with, or
-- nil when nothing narrows it. `--full` means the WHOLE suite, so a full round writes no rows file at all;
-- neither does a plan that already runs everything (`plan.full`), a docs-only plan (no row maps to a document)
-- or a round whose checks were named by hand (`--checks`). The file is written next to the evidence, so the
-- command in the log is the command that ran. `notes` is what the gate logs: every row it did NOT ask for and
-- why, and the line that says the whole suite runs.
--
-- The list is proved against the MERGED TREE (`run.tree`), never against the planner's checkout. The plan is
-- made before anything is merged, from the operator's checkout (`journal.repo`), so the two trees can disagree
-- in both directions and each disagreement was a broken gate:
--
--   * a branch that ADDS `scripts/test-new.lua` is not a row the planner's checkout has, so the plan reports it
--     "not a gate row" and the branch's own new test never runs - a narrowed gate that silently drops the row
--     the change brought with it;
--   * a branch that ADDS an exclude line (or DELETES a row) leaves the planner requesting a row the merged
--     tree's runner refuses - `fast_narrow:unknown_row`, the whole round gated on zero tests.
--
-- So the candidates are read where `scripts/fast.sh` will run them, and only what that inventory proves is
-- requested: the plan's rows and every changed `scripts/test-*.lua` that exists there, minus whatever the
-- merged tree declares not run. Anything dropped is named in `notes` (evidence, by name - never a silence), and
-- a round with no row left in the merged tree runs the whole suite.
function M.gate_rows_file(run, options)
  local plan = run.journal and run.journal.plan
  if options.checks or options.full or not plan or plan.full then return nil end
  local tree = run.tree
  if not tree or tostring(tree) == "" then
    return nil, false, { "no merged tree is known, so no row can be proved runnable: the whole suite runs" }
  end
  local inventory = M.row_inventory(slashes(tree))
  local known = inventory.known or {}
  local rows, seen, dropped = {}, {}, {}
  local function keep(path, source)
    path = trim(path)
    if path == "" or seen[path] then return end
    if not path:match("^scripts/test%-[%w%._%-]+%.lua$") then return end
    seen[path] = true
    if not known[path] then
      dropped[#dropped + 1] = { path = path, source = source,
        why = (inventory.skips or {})[path] or inventory.why or "not a row this fast path runs in the merged tree" }
      return
    end
    rows[#rows + 1] = path
  end
  for _, row in ipairs(plan.rows or {}) do keep(row, "the plan asked for it") end
  -- A row the branch ADDS or DELETES is only visible here: the planner's checkout has the old list. A diff that
  -- cannot be read proves nothing about this tree's rows, and the file it would write is a request the merged
  -- tree REFUSES by name (fast_narrow:unknown_row, zero tests run) - so it runs the whole suite and says why.
  local changed, changed_notes = M.changed_paths(run)
  if #changed_notes > 0 then
    local why = {}
    for _, note in ipairs(changed_notes) do why[#why + 1] = note end
    why[#why + 1] = "so no row is proved runnable: the whole suite runs"
    return nil, false, why
  end
  for _, path in ipairs(changed) do keep(path, "this round changes it") end
  table.sort(rows)
  local notes = {}
  for _, entry in ipairs(dropped) do
    notes[#notes + 1] = "not asking for " .. entry.path .. " (" .. entry.source .. "): " .. entry.why
  end
  if #rows == 0 then
    notes[#notes + 1] = "no row the merged tree can run is left" ..
      (#dropped > 0 and (" (" .. #dropped .. " dropped)") or "") .. "; the whole suite runs"
    return nil, false, notes
  end
  local path = M.run_dir(run.id) .. "/gate-rows.txt"
  if not write(path, table.concat(rows, "\n") .. "\n") then
    notes[#notes + 1] = "the row list could not be written; every Lua row will run"
    return nil, true, notes
  end
  notes[#notes + 1] = string.format("%d row(s) of the merged tree: %s", #rows, table.concat(rows, " "))
  return path, false, notes
end

-- <check> <rows_text> <run> -> the IDENTITY of a check's verdict: everything that decides what "this check
-- passed" means, and nothing that changes from one run to the next.
--
-- It is built from the check's own data rather than from the composed shell line, because that line carries
-- two per-run paths - the WA_FAST_ROWS file and WA_FAST_KEEP_LOGS - and a verdict keyed on those could never
-- be recognised again, which is exactly the bug item 4 fixes. The row LIST is in it (its content, not its
-- path), so the same check asked for different rows is a different verdict, and so is a check whose command,
-- cwd, minimum or subject changed.
function M.gate_identity(check, rows_text, run)
  local parts = { tostring(check.name or ""), tostring(check.command or ""), tostring(check.cwd or ""),
                  tostring(check.min_tests or ""), tostring(rows_text or "") }
  if check.name == "discrimination" and run and type(run.journal) == "table" then
    -- The discrimination check is judged against a BASE and a set of branches (M.gate_command appends both),
    -- so two rounds with the same merged bytes but a different base are not the same verdict.
    local names = {}
    for _, branch in ipairs(run.journal.branches or {}) do
      local name = tostring(branch.name or branch.sha or "")
      if name ~= "" then names[#names + 1] = name end
    end
    parts[#parts + 1] = table.concat(names, ",")
    parts[#parts + 1] = tostring(run.journal.base or "")
  end
  return table.concat(parts, "\n")
end

-- <run> -> name -> {row, run}: the newest gate row that ANY other run passed on a KNOWN tree content, from
-- the journals under this root. The keep is proved by the caller (same identity, same tree_sha); this
-- function only finds candidates, newest run first, and takes the first per check name.
--
-- It reads the same 20 newest journals every other reader of this root reads (journals_by_newest), so a
-- preflight written a minute ago is in it and a flight of old runs cannot crowd it out of the window.
function M.gate_history(run, limit)
  local index = {}
  local current = tostring((run and run.id) or "")
  for _, path in ipairs(journals_by_newest(limit or 20)) do
    local journal = json_file(path)
    if journal and tostring(journal.run or "") ~= current and type(journal.gate) == "table" then
      for _, row in ipairs(journal.gate) do
        if type(row) == "table" and row.name and row.ok == true and row.retry == nil and not row.vacuous
            and tostring(row.key or "") ~= "" and tostring(row.tree_sha or "") ~= "" then
          -- KEYED BY THE CHECK **AND** THE TREE (review r1, item 2). Keyed by the name alone, the newest
          -- run won: two missions preflighted before one landed left history[fast] holding the OTHER
          -- mission tree, the caller tree comparison then failed, and the first mission gate ran in full
          -- again - the normal case, not the corner one. Newest-first scan, so `not index[slot]` keeps the
          -- newest row for exactly this check on exactly this content.
          local slot = row.name .. "\n" .. tostring(row.tree_sha)
          if not index[slot] then index[slot] = { row = row, run = tostring(journal.run or "") } end
        end
      end
    end
  end
  return index
end

-- <tree> -> failed, why: which ROWS the last fast-path run in that tree reported as failing, read from the
-- runner's own result file (scripts/fast.sh writes it into the worktree's git dir: name, section, status,
-- first_error) instead of guessed from its log. failed.lua is the list WA_FAST_ROWS takes; failed.failed
-- carries each row with its first line for the journal and for a preflight's report; failed.named is the
-- contract checks, which this runner runs by name and never narrows.
--
-- A tree with no readable result file is NOT an empty failure list: it is nil plus a reason, and the caller
-- then re-runs the whole check (unknown is not "nothing failed").
-- <tree> -> number, path: the mtime (epoch seconds) of the fast path result file THIS worktree would use,
-- and its path, or nil when there is no file yet. It is the marker an attempt is judged against: a file
-- whose timestamp did not move during the attempt is not that attempt\\u2019s answer (review r1, item 3).
function M.result_mtime(tree)
  if not tree or tostring(tree) == "" then return nil end
  local located = M.exec("git -C " .. quote(slashes(tree)) .. " rev-parse --git-path wa-fast-result.json", "", 60)
  local path = trim(tostring(located.stdout or ""))
  if (located.code or 1) ~= 0 or path == "" then return nil end
  if path:sub(1, 1) ~= "/" then path = slashes(tree) .. "/" .. path end
  local listed = M.exec("stat -c %Y " .. quote(path), "", 30)
  local written = tonumber(trim(tostring(listed.stdout or "")))
  if (listed.code or 1) ~= 0 or written == nil then return nil end
  return written
end

function M.failed_rows(tree, started)
  if not tree or tostring(tree) == "" then return nil, "no merged tree is known, so no result file can be read" end
  local located = M.exec("git -C " .. quote(slashes(tree)) .. " rev-parse --git-path wa-fast-result.json", "", 60)
  local path = trim(tostring(located.stdout or ""))
  if (located.code or 1) ~= 0 or path == "" then
    return nil, "the runner's result file cannot be located in this tree (" ..
      first_line(tostring(located.stderr or "")) .. ")"
  end
  if path:sub(1, 1) ~= "/" then path = slashes(tree) .. "/" .. path end
  local text = read(path)
  if not text then return nil, "the runner wrote no result file at " .. path end
  -- AND IT MUST BELONG TO THIS ATTEMPT (review r1, item 3). scripts/fast.sh writes the file at the END, so
  -- an attempt killed early (budget, signal, a crash) leaves the PREVIOUS attempt file in the same tree: a
  -- resumed run, a retry, a second check in the same round. Reading that one names rows that did not fail
  -- now; the narrowed retry runs them, they pass, and the verdict is reported as flaky under load - which
  -- stops a landing, but for the WRONG reason and with the wrong rows. The file therefore has to be newer
  -- than this attempt; one written before it began is treated exactly like a file that cannot be read.
  -- The comparison is BETWEEN TWO FILESYSTEM TIMESTAMPS, never between a file and the caller clock: this
  -- module has a monotonic `now()` and the file has a wall clock, and mixing them would silently never
  -- fire (measured once already). The marker is what the file looked like BEFORE the attempt ran.
  if type(started) == "number" then
    local listed = M.exec("stat -c %Y " .. quote(path), "", 30)
    local written = tonumber(trim(tostring(listed.stdout or "")))
    if (listed.code or 1) ~= 0 or written == nil then
      return nil, "the result file at " .. path .. " carries no readable timestamp"
    end
    if written <= started then
      return nil, "the result file at " .. path .. " is not newer than this attempt began: it describes " ..
        "an earlier run"
    end
  end
  local decoded_ok, decoded = pcall(json.decode, text)
  if not decoded_ok or type(decoded) ~= "table" then return nil, "the result file at " .. path .. " is not JSON" end
  local rows, failed, named = {}, {}, {}
  for _, entry in ipairs(type(decoded.checks) == "table" and decoded.checks or {}) do
    if type(entry) == "table" then
      local state, name = tostring(entry.status or ""), tostring(entry.name or "")
      if name ~= "" and state ~= "pass" and state ~= "skip" then
        local first = first_line(tostring(entry.first_error or ""))
        if tostring(entry.section or "") == "lua" then
          rows[#rows + 1] = name
          failed[#failed + 1] = { row = name, first = first }
        else
          named[#named + 1] = { row = name, first = first }
        end
      end
    end
  end
  return { lua = rows, failed = failed, named = named, path = path }
end

-- IS THIS ROW A MEASUREMENT OF MAIN, or a step that merely mentions it? `wa land health-run` writes
-- `data = { measured = "scripts/main-health.sh" }` beside its verdict; a landing's own health STEP writes a row
-- with the same step name and no such field, because it answers a different question (did the step start the
-- measurement), not what main is. A row without the marker is skipped in BOTH directions - it neither reds
-- main (the 22/11 false red) nor greens it (a step that started is not a green suite) - and the search goes on
-- to the older row about this main that IS a measurement.
local function measured_verdict(row)
  local raw = row and row.data
  if type(raw) ~= "string" or trim(raw) == "" then return false end
  local ok, fields = pcall(json.decode, raw)
  if not ok or type(fields) ~= "table" then return false end
  return trim(tostring(fields.measured or "")) ~= ""
end

-- THE RED MAIN RULE (FACTORY.md rule 8): main is always green, and a red main blocks the next landing unless
-- that landing IS the fix. The verdict is the ledger's own newest `land.main-health` row about THIS main: a red
-- about an older main is stale and blocks nothing (main-health writes what it measured, and only that), a green
-- about this main blocks nothing either, and a row that cannot be read is not a pass - it says what it could
-- not read.
function M.main_red(base)
  base = trim(base)
  if base == "" then return nil end
  local called, rows = pcall(function()
    return dofile("lua/core/event_ledger.lua").read({ kinds = { "land" }, step = "main-health", limit = 10 })
  end)
  if not called or type(rows) ~= "table" then return nil end
  for index = #rows, 1, -1 do
    local row = rows[index]
    local sha = tostring(row.sha or "")
    if sha ~= "" and (base:sub(1, #sha) == sha or sha:sub(1, #base) == base) and measured_verdict(row) then
      if tostring(row.result) == "red" then return row end
      return nil
    end
  end
  return nil
end

impl.gate = function(run, options)
  local evidence = sink(run, "gate")
  if options.landing then
    -- The whole fast path on the merged tree, asked for by name (`--gate`): the command is the runner this tree
    -- already has, its output is the step's evidence as it is written (the tee), and its exit code is the
    -- verdict. Minutes, not the release's set: `wa release cut` is the release's gate.
    local tree = run.tree
    local command = trim(options.gate_command or "") ~= "" and options.gate_command or "bash scripts/fast.sh"
    evidence(command_line("gate", command))
    local started = now()
    local result = M.exec_streamed(command, tree, tonumber(options.gate_timeout) or 3600, M.evidence_path(run.id, "gate"))
    local output = tostring(result.stdout or "") .. tostring(result.stderr or "")
    if (result.code or 1) ~= 0 then
      return false, { error = "gate_red", detail = "the fast path is red on the merged tree",
        observed = last_line(output), next = "fix the rows on the branch (wa mission preflight <name> asks the same), then land again" }
    end
    return true, { detail = string.format("the whole fast path is green on the merged tree (%ds)", now() - started) }
  end
  local tree = run.tree
  -- Which checks: the plan's set (M.gate_checks), which is never smaller than the always-on core, and - when
  -- the plan mapped rows and the round is not full - a WA_FAST_ROWS file for `scripts/fast.sh` so a Lua-only
  -- round runs the rows its changed modules touch instead of all ~200. `--full` means the whole suite, so it
  -- writes none (M.gate_rows_file). The file is written next to the evidence, so the command in the log is the
  -- command that ran.
  local checks, why = M.gate_checks(run, options)
  local rows_file, rows_file_failed, rows_notes = M.gate_rows_file(run, options)
  local notes = rows_notes or {}
  for _, note in ipairs(notes) do evidence("gate rows: " .. tostring(note) .. "\n") end
  if rows_file_failed and #notes == 0 then evidence("gate rows: the row list could not be written; every Lua row will run\n") end
  run.journal.gate_checks = why
  local decorator = M.weight()
  run.journal.gate_weight = decorator ~= "" and decorator or "none (no weight could be applied)"
  local rows = {}
  -- THE NODE BUILD RECORD, READ BY THIS GATE THE WAY EVERY OTHER ENTRY POINT READS IT (item 6 of the
  -- node-ops round). `wa land` runs `cargo test` and `bash scripts/fast.sh` here, so it has the same
  -- question about zig, the wasi-sdk and the target policy that deploy.sh and fast.sh ask - and before
  -- this it answered it from its own ambient environment, which is two answers to one question. One
  -- reader (scripts/lib/build-requirements.sh) is applied to every gate command in the same shell, and a
  -- record naming a directory that is not there refuses the GATE by name instead of failing a check.
  local record_prefix = ""
  do
    local reader = slashes(tree) .. "/scripts/lib/build-requirements.sh"
    local probe = M.exec("test -f " .. quote(reader) .. " && echo present || echo absent", "", 30)
    if tostring(probe.stdout or ""):find("present", 1, true) then
      local applied = M.exec("bash -c " .. quote(". " .. quote(reader) .. " || exit 3; wa_build_env_audit >/dev/null || exit 4; wa_build_env"), slashes(tree), 120)
      if (applied.code or 1) ~= 0 then
        return false, { error = "build_env_incomplete", detail = "the build record names a directory that is not there: "
          .. tostring(applied.stderr or applied.stdout or ""):gsub("%s+$", "") .. " (refused before a gate ran)" }
      end
      -- The prefix is applied INSIDE the shell that runs each check: the exported names and the appended
      -- PATH of the record, so a cargo or bash check sees exactly what deploy.sh/fast.sh see.
      -- THE AUDIT RUNS INSIDE EVERY GATE SHELL TOO (item 8 of the node-ops round). A key nothing reads
      -- must stop the gate by name, not be silently ignored while fast.sh and deploy.sh refuse the same
      -- record: one record, one answer. The audit is cheap (one file, one loop) and it reads the same
      -- allow-list, so no key can be known to one entry point and unknown to another.
      -- THE MESSAGES ARE QUOTED, AND THAT IS THE WHOLE POINT (measured 20/11 on the base). A bare
      -- `echo refused(build_env_key_unknown): ...` is not a message, it is a SHELL SYNTAX ERROR: the
      -- unquoted parenthesis after the word ends the command, bash answers `syntax error near unexpected
      -- token `(`` and the whole prefix dies with exit 2 - so EVERY gate check exited 2 without running,
      -- in any tree that has a build record script, and the verdict read as a red check. Quoted, the words
      -- are the words a reader sees and the check after the prefix actually runs.
      record_prefix = ". " .. quote(reader) .. " >/dev/null 2>&1; wa_build_env_audit >/dev/null 2>&1 || { wa_build_env_audit >&2; echo " .. quote("refused(build_env_key_unknown): the build record names a setting no build reads") .. " >&2; exit 2; }; "
        .. "wa_build_env >/dev/null 2>&1 || { echo " .. quote("refused(build_env_incomplete): the build record names a directory that is not there") .. " >&2; exit 2; }; "
    end
  end
  -- A resume keeps a check that already PASSED (first run, not a retry) on this exact tree with this exact
  -- command and row list: the same bytes judged by the same command answer the same thing, and re-running a
  -- green 15-minute check is the slowest part of a resume. Anything else runs again - a red or flaky check, a
  -- different tree_commit, a changed command (a check definition fixed between attempts) or a different
  -- WA_FAST_ROWS list. The reuse is written to the evidence and the row, by name, with the sha it passed on.
  local tree_commit = tostring(run.journal.tree_commit or "")
  local tree_sha = tostring(run.journal.tree_sha or "")
  local rows_text = rows_file and (read(rows_file) or "") or ""
  local earlier = {}
  for _, prior in ipairs(type(run.journal.gate) == "table" and run.journal.gate or {}) do
    if type(prior) == "table" and prior.name then earlier[prior.name] = prior end
  end
  -- A GREEN VERDICT BELONGS TO THE BYTES, NOT TO THE RUN THAT EARNED IT (item 4). The rule just above - a
  -- resume keeps a check that already passed on this tree_commit - stopped at the edge of the run, so a
  -- preflight's green gate (the whole point of asking the question before the landing) was thrown away and
  -- the landing paid for the same checks on the same bytes again. The identity a verdict can be kept by is
  -- therefore the check's own data (M.gate_identity) plus the TREE OBJECT - the content - and never the
  -- merge commit: that commit carries its timestamp, so an identical merge twice is two commits (measured;
  -- docs/missions/reports/factory-1.md).
  local history = M.gate_history(run)
  for _, check in ipairs(checks) do
    -- <rows file> -> the command this run composes for that row list: the record prefix inside the same
    -- shell, the weight decorator outside it. One function, so the retry below cannot compose a command
    -- that differs from the one that just ran in anything but the rows it asks for.
    local function compose(rowsf)
      local line = record_prefix .. M.gate_command(check, rowsf, run)
      return (decorator ~= "" and (decorator .. " " .. quote(line))) or line
    end
    -- The fast check ALWAYS gets the assignment (M.gate_command): the round's file, or an empty value so a
    -- WA_FAST_ROWS inherited from the environment cannot narrow a run that wrote none.
    local command = compose(rows_file)
    local cwd = check.cwd and (slashes(tree) .. "/" .. check.cwd) or slashes(tree)
    local key = M.gate_identity(check, rows_text, run)
    local prior = earlier[check.name]
    local older = nil
    if tree_sha ~= "" then
      local found = history[check.name .. "\n" .. tree_sha]
      if found and tostring(found.row.key) == key and tostring(found.row.tree_sha) == tree_sha then older = found end
    end
    if tree_commit ~= "" and prior and prior.ok == true and prior.retry == nil and not prior.vacuous
        and prior.tree_commit == tree_commit and prior.key == key then
      evidence(string.format("%s: kept - passed on %s with this command in an earlier attempt (%s test(s), %ss)\n",
        check.name, tree_commit:sub(1, 12), tostring(prior.tests or 0), tostring(prior.seconds or "?")))
      rows[#rows + 1] = { name = check.name, ok = true, code = prior.code, seconds = 0, tests = prior.tests,
                          detail = prior.detail, tree_commit = tree_commit, tree_sha = tree_sha, key = key,
                          kept = true, kept_from = prior.kept_from,
                          kept_seconds = prior.kept_seconds or prior.seconds }
      run.journal.gate = rows
      save(run)
    elseif older then
      -- THE SAME BYTES, JUDGED BY THE SAME COMMAND, IN ANOTHER RUN: a preflight, a landing that stopped
      -- after the gate, or an earlier round on an unmoved main. Kept, and the row names the run it was kept
      -- from, so a reader can go and read that verdict instead of trusting a claim about it.
      evidence(string.format("%s: kept - passed on tree %s with this command in run %s (%s test(s), %ss)\n",
        check.name, tree_sha:sub(1, 12), tostring(older.run), tostring(older.row.tests or 0),
        tostring(older.row.seconds or "?")))
      rows[#rows + 1] = { name = check.name, ok = true, code = older.row.code, seconds = 0,
                          tests = older.row.tests, detail = older.row.detail, tree_commit = tree_commit,
                          tree_sha = tree_sha, key = key, kept = true, kept_from = older.run,
                          kept_seconds = older.row.kept_seconds or older.row.seconds }
      run.journal.gate = rows
      save(run)
    else -- not kept: the check runs (this branch closes at the end of the loop body)
    evidence(command_line(check.name, command))
    local started = now()
    -- A serial per-test budget needs a total that grows with the tests it will run, or a round that
    -- touches twenty of them times out on the twenty-first and reads as a failure of the change. The
    -- count is the round's own changed test paths; anything else keeps the check's declared timeout.
    local budget = check.timeout or 1800
    if check.per_test_seconds and run.journal and run.journal.plan then
      local touched = 0
      -- plan.files is the COUNT of changed paths (M.plan returns files = #paths), not the list: iterating it
      -- crashed the gate with "attempt to index a number value" the first time a round reached the
      -- discrimination check (21/11, batch-4, after a green fast path). The list is asked for by name.
      local listed = run.journal.plan.files
      if type(listed) ~= "table" then listed = (M.changed_paths(run)) end
      for _, path in ipairs(type(listed) == "table" and listed or {}) do
        if tostring(path):match("^tests?/") or tostring(path):match("test%-") then touched = touched + 1 end
      end
      budget = math.max(budget, 300 + check.per_test_seconds * touched)
    end
    -- STREAMED, NOT COLLECTED (item 3): the check's own shell appends to gate.log as it prints, so a
    -- check the gate's deadline kills has already said why. `result.stdout` is the part of the log this
    -- check wrote, which is what the lines below count and report.
    -- WHAT THE RUNNER RESULT FILE LOOKED LIKE BEFORE THIS ATTEMPT RAN (review r1, item 3): the retry may
    -- only name rows a file written DURING this attempt reports.
    local result_marker = (check.name == "fast") and M.result_mtime(tree) or nil
    local result = M.exec_streamed(command, cwd, budget, M.evidence_path(run.id, "gate"))
    local seconds = now() - started
    local tests = passed_tests((result.stdout or "") .. (result.stderr or ""))
    local row = { name = check.name, ok = (result.code or 1) == 0, code = result.code, seconds = seconds,
                  tests = tests, detail = check.detail or check.command, tree_commit = tree_commit,
                  tree_sha = tree_sha, key = key }
    if row.ok and check.min_tests and tests < check.min_tests then
      row.ok = false
      row.vacuous = true
      row.detail = "exited 0 but proved nothing: " .. tests .. " test(s), at least " .. check.min_tests .. " required"
    end
    evidence(string.format("-> %s in %ss (%d test(s))\n", row.ok and "ok" or ("exit " .. tostring(result.code)), tostring(seconds), tests))
    if row.vacuous then
      -- A run that executed no test is not a flaky run: retrying it would prove the same nothing. This is a
      -- FAIL, by name, and it is the shape a green landing nobody should trust takes (a filter that matches
      -- nothing exits 0).
      rows[#rows + 1] = row
      run.journal.gate = rows
      save(run)
      return false, { error = "gate_vacuous", name = check.name,
        detail = check.name .. " " .. tostring(row.detail),
        observed = first_line((result.stdout or "") ~= "" and result.stdout or result.stderr),
        next = "a check that runs no test cannot pass: fix its command or its filter (" .. M.evidence_path(run.id, "gate") .. ")" }
    end
    if not row.ok then
      -- ONLY THE ROWS THAT FAILED RUN AGAIN ALONE (item 5, and the factory's Rule 6).
      --
      -- The retry answers one question - "did this fail because of the load, or because of the tree?" - and
      -- it used to answer it by running the WHOLE check a second time: 468 s of fast path re-run to classify
      -- 3 red rows, on a landing that had already spent 354 s finding them (land-20261121T102542Z and
      -- land-20261121T124854Z, measured in docs/missions/reports/factory-1.md). The runner already names the
      -- rows that failed in its own result file, and scripts/fast.sh takes a row list through WA_FAST_ROWS,
      -- so the retry asks for those rows and nothing else. The command, its prefix and its weight are
      -- composed by the SAME function that composed the first attempt (compose), so the only difference
      -- between the two runs is the row list.
      --
      -- A check that is not the fast path has nothing to narrow - its command IS its row - so it re-runs as
      -- it always did. When the failed-row list cannot be read the retry says so, by name, and runs the whole
      -- check: unknown is not "nothing failed", it is the slower, always-correct path.
      local failed, failed_why = nil, nil
      if check.name == "fast" then failed, failed_why = M.failed_rows(tree, result_marker) end
      if failed then
        row.failed = {}
        for _, entry in ipairs(failed.failed) do row.failed[#row.failed + 1] = entry end
        for _, entry in ipairs(failed.named) do row.failed[#row.failed + 1] = entry end
      end
      if not row.failed or #row.failed == 0 then
        row.failed = { { row = check.name,
          first = first_line((result.stdout or "") ~= "" and result.stdout or result.stderr) } }
      end
      local retry_file, retry_note = nil, nil
      if check.name == "fast" then
        if failed and #failed.lua > 0 then
          local candidate = M.run_dir(run.id) .. "/gate-retry-rows.txt"
          if write(candidate, table.concat(failed.lua, "\n") .. "\n") then
            retry_file = candidate
            retry_note = string.format("%d row(s) failed (%s); the retry asks for those and nothing else",
              #failed.lua, table.concat(failed.lua, " "))
          else
            retry_note = "the failed-row list could not be written to " .. candidate ..
              "; the retry is the whole check"
          end
        elseif failed then
          retry_note = "no Lua row failed (only contract checks did): the retry is the whole check, because " ..
            "this runner runs every contract check by name and none of them can be narrowed"
        else
          retry_note = "the failed rows could not be read (" .. tostring(failed_why) ..
            "): the retry is the whole check"
        end
      end
      local retry_command = compose(retry_file or rows_file)
      local retry_started = now()
      evidence(command_line(check.name .. " (alone, after a failure)", retry_command))
      if retry_note then evidence("retry rows: " .. retry_note .. "\n") end
      local retry = M.exec_streamed(retry_command, cwd, budget, M.evidence_path(run.id, "gate"))
      local retry_tests = passed_tests((retry.stdout or "") .. (retry.stderr or ""))
      row.retry = { ok = (retry.code or 1) == 0, code = retry.code, seconds = now() - retry_started,
                    tests = retry_tests, rows_file = retry_file, why = retry_note }
      rows[#rows + 1] = row
      run.journal.gate = rows
      save(run)
      if (retry.code or 1) == 0 then
        return false, { state = "flaky",
          error = "flaky_under_load",
          detail = "flaky under load: " .. check.name .. " failed beside the other checks (exit " .. tostring(result.code) ..
            ") and passed alone in " .. tostring(now() - retry_started) .. "s (" .. retry_tests .. " test(s)). " ..
            "The landing stops here and a human decides - it is not green.",
          observed = first_line((result.stdout or "") ~= "" and result.stdout or result.stderr),
          next = "re-run `wa land --resume` when the machine is quiet, or land with `--checks` naming only what changed" }
      end
      return false, { error = "gate_failed", name = check.name,
        detail = check.name .. " failed twice (exit " .. tostring(result.code) .. ", then " .. tostring(retry.code) ..
          " alone): " .. tostring(row.detail),
        observed = first_line((result.stdout or "") ~= "" and result.stdout or result.stderr),
        next = "the check's own words are in " .. M.evidence_path(run.id, "gate") }
    end
    rows[#rows + 1] = row
    run.journal.gate = rows
    save(run)
    end -- not kept
  end
  return true, { detail = string.format("%d check(s) passed, weighted (%s)", #rows,
                  decorator ~= "" and decorator or "no weight available") }
end

-- push: the landed tip into the incoming repository, read back. A push recorded done is never repeated, and
-- a remote that already has the sha is recorded done without pushing - that is the crash-between-push-and-
-- journal case, and it must not become a second push.
impl.push = function(run, options)
  local evidence = sink(run, "push")
  local tree, sha = run.tree, run.journal.tree_commit
  local incoming, branch = M.incoming(), run.journal.land_branch
  local existing = remote_tip(tree, incoming, "refs/heads/" .. branch)
  if existing == sha then
    run.journal.pushed_sha = sha
    evidence("already on " .. incoming .. " at " .. sha .. "; not pushed again\n")
    return true, { detail = incoming .. " " .. branch .. " already at " .. sha:sub(1, 12) }
  end
  local result = git(run, tree, "push " .. quote(incoming) .. " " .. quote("HEAD:refs/heads/" .. branch), 1800)
  evidence(command_line("push", "git push " .. incoming .. " HEAD:refs/heads/" .. branch))
  evidence((result.stdout or "") .. (result.stderr or ""))
  if (result.code or 1) ~= 0 then
    return false, { error = "push_failed", observed = first_line(result.stderr ~= "" and result.stderr or result.stdout),
      next = "git push " .. incoming .. " " .. branch .. " (from " .. tree .. ")" }
  end
  local readback = remote_tip(tree, incoming, "refs/heads/" .. branch)
  if readback ~= sha then
    return false, { error = "push_not_readback",
      observed = incoming .. " refs/heads/" .. branch .. " is " .. tostring(readback or "absent") .. ", pushed " .. sha,
      next = "do not retry blindly: inspect " .. incoming .. " first" }
  end
  run.journal.pushed_sha = sha
  return true, { detail = incoming .. " " .. branch .. " = " .. sha:sub(1, 12) .. " (read back)" }
end

-- main: fast-forward the source of truth. Only the node holding the GitHub credential can do this, and the
-- refusal says so with the exact command instead of pretending the landing is done.
-- Run one shell command ON a named node and answer its exit and streams: the fabric's own remote call,
-- capability `bash`, which is the door `wa update <node>` uses too. A node that answers nothing is a
-- refusal by name, never a pass.
function M.node_bash(node, command)
  local ok, reply = pcall(M.call(), tostring(node), "bash", { command = command })
  if not ok or type(reply) ~= "table" then
    return nil, { error = "node_unreachable", detail = "no answer from " .. tostring(node),
      observed = tostring(reply or "the call produced nothing") }
  end
  if reply.error then
    return nil, { error = "node_refused", detail = "node " .. tostring(node) .. " refused the command",
      observed = tostring(reply.error) .. ((reply.note and (" - " .. tostring(reply.note))) or "") }
  end
  return reply
end

-- The URL a remote name stands for, resolved in the landed tree: a node that is asked to fetch or push
-- needs an address it can resolve itself, and `origin` is a name only this checkout knows.
local function remote_url(run, tree, remote)
  local result = git(run, tree, "remote get-url " .. quote(remote), 120)
  if (result.code or 1) == 0 then
    local url = trim(result.stdout)
    if url ~= "" then return url end
  end
  return nil
end

impl.main = function(run, options)
  local evidence = sink(run, "main")
  local tree, sha = run.tree, run.journal.tree_commit
  local origin = M.origin()
  -- The comparison below is about the remote's current main, so fetch it: a land worktree cut from the base
  -- may not have the commit main moved to while the gate ran.
  local fetched = git(run, tree, "fetch --quiet " .. quote(origin) .. " main", 600)
  evidence(command_line("fetch main", "git fetch " .. origin .. " main"))
  evidence((fetched.stdout or "") .. (fetched.stderr or ""))
  local current = remote_tip(tree, origin, "refs/heads/main")
  if current == sha then
    run.journal.main_sha = sha
    evidence(origin .. "/main is already " .. sha .. "; nothing to fast-forward\n")
    return true, { detail = origin .. " main already at " .. sha:sub(1, 12) }
  end
  if current and not is_ancestor(tree, current, sha) then
    return false, { error = "main_not_fast_forward",
      observed = origin .. "/main is " .. current:sub(1, 12) .. " and the landed tip " .. sha:sub(1, 12) .. " does not contain it",
      next = "rebase onto " .. origin .. "/main and land again; this never force-pushes" }
  end
  -- WHO FAST-FORWARDS MAIN. Only the node holding the GitHub credential can, and this machine must not be
  -- given one - so `--account <node>` does the push THERE, from a throwaway clone of the incoming repository
  -- the landed tip was already pushed to: the node needs no checkout of the landing, only the address it
  -- already has. Without --account the push is tried here, exactly as before.
  local account = trim(options.account)
  local routed = account ~= "" and account ~= "local" and account ~= "this"
  local result, readback
  if routed then
    local incoming_url = remote_url(run, tree, M.incoming()) or M.incoming()
    local origin_url = remote_url(run, tree, origin) or origin
    local script = table.concat({
      'set -e',
      'd=$(mktemp -d)',
      "trap 'rm -rf \"$d\"' EXIT",
      'git -C "$d" init -q .',
      'git -C "$d" fetch -q ' .. quote(incoming_url) .. ' ' .. quote(sha),
      'git -C "$d" push ' .. quote(origin_url) .. ' ' .. quote(sha .. ":refs/heads/main"),
      'git -C "$d" ls-remote ' .. quote(origin_url) .. ' ' .. quote("refs/heads/main"),
    }, '\n')
    evidence(command_line("main on " .. account, script))
    local reply, problem = M.node_bash(account, script)
    if not reply then
      return false, { error = problem.error, detail = problem.detail,
        observed = problem.observed,
        next = "check the node is reachable (wa nodes), or land with the credential on this machine" }
    end
    evidence((reply.stdout or "") .. (reply.stderr or ""))
    result = { code = reply.code, stdout = reply.stdout, stderr = reply.stderr }
    -- The read-back that matters is the ACCOUNT's own answer, not this machine's memory of the remote:
    -- a push that left this machine and a main that moved somewhere else would otherwise look the same.
    for line in tostring(reply.stdout or ""):gmatch("[^\r\n]+") do
      local tip = line:match("^(%x+)%s+refs/heads/main$")
      if tip then readback = tip end
    end
    run.journal.main_account = account
  else
    result = git(run, tree, "push " .. quote(origin) .. " " .. quote(sha .. ":refs/heads/main"), 1800)
    evidence(command_line("main", "git push " .. origin .. " " .. sha .. ":refs/heads/main"))
    evidence((result.stdout or "") .. (result.stderr or ""))
  end
  if (result.code or 1) ~= 0 then
    local text = tostring(result.stderr or "") .. tostring(result.stdout or "")
    local credential = text:lower():find("permission") or text:lower():find("denied")
      or text:lower():find("authentication") or text:lower():find("could not read username")
    return false, { error = credential and "main_push_needs_credentials" or "main_push_failed",
      detail = "the landed tip could not be fast-forwarded onto " .. origin .. "/main",
      observed = first_line(text ~= "" and text or "git push answered nothing"),
      next = "name the node that holds the Magaav credential: wa land --account <node> --resume   " ..
        "(this node has no GitHub credential and must not be given one)" }
  end
  readback = readback or remote_tip(tree, origin, "refs/heads/main")
  if readback ~= sha then
    return false, { error = "main_not_readback",
      observed = origin .. "/main is " .. tostring(readback or "absent") .. ", pushed " .. sha }
  end
  run.journal.main_sha = sha
  return true, { detail = origin .. " main = " .. sha:sub(1, 12) .. " (read back)" }
end

-- ---------------------------------------------------------------- the release, in three steps
--
-- BUILD, SIGN, SHIP are separate steps because they need different hosts. The build needs a toolchain, the
-- signature needs wa-vault's ADMIN listener (which answers on the machine that runs the vault and nowhere
-- else - measured 13/11: 127.0.0.1:8801 on the operator's laptop), and the ship needs a git remote. Keeping
-- them apart also means a signature that arrives after a stopped run is not thrown away with the build.
--
-- What never changes, whichever host does which: a release is signed by a key this project trusts, and an
-- unsigned one is not shipped and not published (`scripts/lib/release-signing.sh`, `docs/INSTALL.md`
-- "Signed releases"). `--dry-run` is the only mode that ends without a signature, and it ends without a
-- release either.

-- artifacts: build the release set for the landed commit and verify it HERE - payloads, manifest and
-- SHA256SUMS - with the signature DEFERRED (`WA_RELEASE_SIGN_DEFER=1`: the publisher is told that the signer
-- is another host, and it will neither sign nor publish an unsigned set).
impl.artifacts = function(run, options)
  local evidence = sink(run, "artifacts")
  local tree, sha = run.tree, run.journal.tree_commit
  local dir = run.journal.release_dir or (M.run_dir(run.id) .. "/release")
  run.journal.release_dir = dir
  -- WHICH BUILD THIS ROUND NEEDS is the plan's answer, not a constant: `lua-tree` writes the signed record of
  -- the tree the nodes will load, `components` rebuilds only the wasm bundle, and anything else is the node
  -- release this step always built. The release DIRECTORY is shared (`<run>/release`) so the sign step signs
  -- whichever sums the round produced, with one code path.
  local kind = (run.journal.plan and run.journal.plan.steps and run.journal.plan.steps.artifacts
    and run.journal.plan.steps.artifacts.kind) or "node-release"
  if kind == "lua-tree" then return impl.artifacts_lua_tree(run, options, evidence, tree, sha, dir) end
  if kind == "components" then return impl.artifacts_components(run, options, evidence, tree, sha, dir) end
  -- A COMPILED ROUND THAT ALSO MOVES components.lock BUILDS THE BUNDLE HERE, with the node release and before
  -- any node takes either (item 28): the same publisher the components path uses, verified against the lock the
  -- fleet will read, so there is one build path and the deploy cannot see a new lock with an old bundle.
  local also = run.journal.plan and run.journal.plan.steps and run.journal.plan.steps.artifacts
    and run.journal.plan.steps.artifacts.also_components
  if also then
    local bundle_ok, bundle = impl.artifacts_components(run, options, evidence, tree, sha, dir .. "/components")
    if not bundle_ok then return false, bundle end
    run.journal.artifacts.components = { dir = dir .. "/components", detail = tostring(bundle and bundle.detail or "") }
  end
  local command = "WA_RELEASE_SIGN_DEFER=1 bash scripts/publish-node-binaries.sh --commit " .. quote(sha) ..
    " --out " .. quote(dir)
  evidence(command_line("build release", command))
  local result = M.exec(command, slashes(tree), 7200)
  evidence((result.stdout or "") .. (result.stderr or ""))
  if (result.code or 1) ~= 0 then
    return false, { error = "artifacts_failed", observed = first_line(result.stderr ~= "" and result.stderr or result.stdout),
      next = "the publisher's own words are in " .. M.evidence_path(run.id, "artifacts") }
  end
  local short = sha:sub(1, 12)
  local manifest = dir .. "/node-" .. short .. ".manifest"
  local text = read(manifest)
  if not text then
    return false, { error = "artifacts_manifest_missing", observed = manifest .. " was not written by the publisher",
      next = "inspect " .. M.evidence_path(run.id, "artifacts") }
  end
  local source = tostring(text):match("source_commit=(%x+)")
  if source ~= sha then
    return false, { error = "artifacts_wrong_commit",
      observed = "the manifest names source_commit " .. tostring(source) .. ", the landed tip is " .. sha }
  end
  -- A target row is `<triple> <sha> <bytes> <sha> <bytes>`; everything else in the manifest is `key=value` or a
  -- comment. The triple itself is not parsed by shape (a target triple is not a version number):
  -- `aarch64-unknown-linux-gnu` has no dot at all.
  local triples = {}
  for line in tostring(text):gmatch("[^\r\n]+") do
    local triple = line:match("^(%S+)%s+%x+%s+%d+")
    if triple and not triple:match("^#") and not triple:match("=") then triples[#triples + 1] = triple end
  end
  if #triples == 0 then
    return false, { error = "artifacts_manifest_empty", observed = manifest .. " names no target row" }
  end
  -- The publisher says it verified its own bytes; this asks the same question again from the manifest's own
  -- pins - sha256 and size of each payload for each target - so a truncated, stale or tampered directory
  -- cannot reach the signer. Spelled here rather than through `scripts/lib/node-binaries.sh` because this is
  -- the one check that has to work in a tree that cannot run that library.
  for _, line in ipairs(vsplit(tostring(text), "\n")) do
    local triple, want_sha, want_bytes, want_ssha, want_sbytes = line:match("^(%S+)%s+(%x+)%s+(%d+)%s+(%x+)%s+(%d+)")
    if triple then
      local measured = M.exec(
        'for n in ' .. quote("wa-" .. triple .. "-" .. short) .. ' ' .. quote("wa-sentinel-" .. triple .. "-" .. short) ..
        '; do printf "%s %s\n" "$(sha256sum < ' .. quote(dir) .. '/$n 2>/dev/null | cut -d" " -f1)" ' ..
        '"$(wc -c < ' .. quote(dir) .. '/$n 2>/dev/null | tr -d " ")"; done', "", 300)
      evidence(string.format("$ verify %s against the manifest pins\n%s%s\n", triple, tostring(measured.stdout), tostring(measured.stderr)))
      local got = {}
      for line2 in tostring(measured.stdout or ""):gmatch("[^\r\n]+") do got[#got + 1] = line2 end
      local pairs_ = { { got[1], want_sha, want_bytes, "wa" }, { got[2], want_ssha, want_sbytes, "wa-sentinel" } }
      for _, pair in ipairs(pairs_) do
        local got_sha, got_bytes = tostring(pair[1] or ""):match("^(%x+)%s+(%d+)")
        if got_sha ~= pair[2] or got_bytes ~= pair[3] then
          return false, { error = "artifacts_not_pinned",
            observed = string.format("%s for %s is %s/%s bytes, the manifest pins %s/%s", pair[4], triple,
              tostring(got_sha or "missing"), tostring(got_bytes or "0"), pair[2], pair[3]),
            next = "the built bytes do not match the manifest the publisher wrote for this commit; nothing is signed and nothing ships" }
        end
      end
    end
  end
  run.journal.artifacts = { dir = dir, manifest = manifest, commit = sha, triples = triples }
  return true, { detail = string.format("%s holds %s for %s (%s); unsigned so far, by design",
    dir, short, sha:sub(1, 12), table.concat(triples, " ")) }
end

-- A LUA-ONLY round's artifacts: the signed record of the tree the nodes will load, and nothing compiled.
--
-- `scripts/publish-lua-tree.sh` writes `<release>/node-lua-tree.manifest` + `SHA256SUMS` over the same file set
-- `scripts/deploy.sh` stages (`scripts/lib/lua-tree.sh` is that one definition), stamped once so a resume
-- cannot rewrite what the signing host signed. The signature is the SAME sign step every other path uses -
-- `scripts/sign-release.sh <dir>/SHA256SUMS` - because what gets signed is "the bytes that name the payloads",
-- and for this path the payload is a tree.
impl.artifacts_lua_tree = function(run, options, evidence, tree, sha, dir)
  local command = "bash scripts/publish-lua-tree.sh --commit " .. quote(sha) .. " --out " .. quote(dir)
  evidence(command_line("lua-tree record", command))
  local result = M.exec(command, slashes(tree), 900)
  evidence((result.stdout or "") .. (result.stderr or ""))
  if (result.code or 1) ~= 0 then
    return false, { error = "artifacts_failed", observed = first_line(result.stderr ~= "" and result.stderr or result.stdout),
      next = "the record script's own words are in " .. M.evidence_path(run.id, "artifacts") }
  end
  local manifest = dir .. "/node-lua-tree.manifest"
  local text = read(manifest)
  if not text then
    return false, { error = "artifacts_manifest_missing", observed = manifest .. " was not written",
      next = "inspect " .. M.evidence_path(run.id, "artifacts") }
  end
  local source = tostring(text):match("source_commit=(%x+)")
  if source ~= sha then
    return false, { error = "artifacts_wrong_commit",
      observed = "the record names source_commit " .. tostring(source) .. ", the landed tip is " .. sha }
  end
  local inputs = tostring(text):match("lua_inputs=(%x+)")
  if not inputs then
    return false, { error = "artifacts_record_unreadable", observed = manifest .. " names no lua_inputs digest" }
  end
  local files = 0
  for _ in tostring(text):gmatch("\n%x+  ") do files = files + 1 end
  run.journal.artifacts = { kind = "lua-tree", dir = dir, manifest = manifest, commit = sha,
    lua_inputs = inputs, files = files }
  return true, { detail = string.format("Lua tree record: %d file(s) at %s, lua_inputs %s (no cross-build, no node release)",
    files, sha:sub(1, 12), tostring(inputs):sub(1, 12)) }
end

-- A COMPONENTS round's artifacts: rebuild and verify only the wasm bundle, and make the repin decision
-- visible. `scripts/publish-components.sh` verifies every artifact against `components.lock` and refuses
-- (exit 5) with the line that WOULD pin it - which is exactly the repin check: a bundle whose bytes are not
-- the pins cannot be deployed by a node, and the round stops here rather than on four nodes.
--
-- The bundle is not signed by the release-signing key and is published by the gh line the script prints (the
-- tag is `components-<first 12 hex of sha256(components.lock)>`), so this step keeps that line in the journal
-- and the report, where an operator with a credential can run it. Nothing here pretends it was published.
impl.artifacts_components = function(run, options, evidence, tree, sha, dir)
  local command = "bash scripts/publish-components.sh --out " .. quote(dir)
  evidence(command_line("components bundle", command))
  local result = M.exec(command, slashes(tree), 3600)
  evidence((result.stdout or "") .. (result.stderr or ""))
  if (result.code or 1) ~= 0 then
    return false, { error = "artifacts_failed", observed = first_line(result.stderr ~= "" and result.stderr or result.stdout),
      detail = "the component bundle is not the pins components.lock names, so no node could install it",
      next = "the builder's own words (and the line that would pin each artifact) are in " .. M.evidence_path(run.id, "artifacts") }
  end
  local publish_line, tag
  for line in tostring(result.stdout or ""):gmatch("[^\r\n]+") do
    if not publish_line and line:match("^gh release create") then publish_line = line end
    if not tag then tag = line:match("release tag: (%S+)") end
  end
  run.journal.artifacts = { kind = "components", dir = dir, commit = sha, tag = tag, publish_line = publish_line }
  return true, { detail = string.format("components bundle %s verified against components.lock%s%s",
    tostring(tag or "(no tag)"), publish_line and "; publish with the printed gh line" or "",
    publish_line and (" in " .. M.evidence_path(run.id, "artifacts")) or "") }
end

-- sign: the SHA256SUMS of the release set, signed by wa-vault's `release-signing` key ON THE HOST THAT CAN
-- REACH THE VAULT, and the signature handed back here, where it is verified against the trusted keys of the
-- landed tree. This is the step that used to be a TODO while `change/sign` was not on main.
impl.sign = function(run, options)
  local evidence = sink(run, "sign")
  local tree, sha = run.tree, run.journal.tree_commit
  local artifacts = run.journal.artifacts
  if not artifacts or not artifacts.dir then
    return false, { error = "sign_without_artifacts", observed = "the artifacts step has not built a release set" }
  end
  local sums = artifacts.dir .. "/SHA256SUMS"
  local sig = sums .. ".sig"
  if not read(sums) then
    return false, { error = "sign_without_sums", observed = sums .. " does not exist, so there is nothing to sign" }
  end
  local signer, problem = M.signer(options)
  if not signer then return false, problem end
  evidence(string.format("signer: %s (%s)\n", signer.kind == "local" and "this node" or tostring(signer.node), tostring(signer.why)))
  local result
  if signer.kind == "local" then
    local command = "bash scripts/sign-release.sh " .. quote(sums) .. " " .. quote(sig)
    evidence(command_line("sign", command))
    result = M.exec(command, slashes(tree), 900)
    evidence((result.stdout or "") .. (result.stderr or ""))
  else
    result, problem = M.sign_on_node(signer.node, sums, sig, evidence)
    if not result then return false, problem end
  end
  if (result.code or 1) ~= 0 then
    local text = tostring(result.stderr or "") .. tostring(result.stdout or "")
    return false, { error = "release_not_signed",
      detail = "the release for " .. sha:sub(1, 12) .. " was not signed, so nothing is shipped and nothing is published",
      observed = first_line(text ~= "" and text or "the signer answered nothing"),
      next = "the vault's admin listener answers only where the vault runs: set WA_VAULT_ADMIN_URL and "
        .. "WA_VAULT_ADMIN_TOKEN on that node (or name it: `wa land --signer <node>`), create the "
        .. "release-signing key on its admin page, then `wa land --resume`" }
  end
  -- Verified HERE, against the keys the landed tree trusts. A signature this project does not trust is not a
  -- release, and the answer says which key arrived and where its public half has to go.
  local verify = M.exec(". scripts/lib/release-signing.sh && wa_release_verify_sums " .. quote(artifacts.dir),
    slashes(tree), 300)
  evidence(command_line("verify signature", ". scripts/lib/release-signing.sh; wa_release_verify_sums " .. artifacts.dir))
  evidence((verify.stdout or "") .. (verify.stderr or ""))
  if (verify.code or 1) ~= 0 then
    return false, { error = "release_key_not_trusted",
      detail = "the vault signed " .. sha:sub(1, 12) .. " with a key this tree does not trust, so nothing is shipped",
      observed = first_line(verify.stderr ~= "" and verify.stderr or verify.stdout),
      next = "add the key's public half to config/release-keys.txt (the key id is in " .. sig ..
        "; GET <vault>/api/release-signing returns it) and land that: a release no node can verify is not a release" }
  end
  local key_id = tostring(read(sig) or ""):match("key%s+(%S+)")
  artifacts.signed = true
  artifacts.signer = signer.kind == "local" and "local" or tostring(signer.node)
  artifacts.key_id = key_id
  return true, { detail = string.format("signed on %s (key %s)",
    signer.kind == "local" and "this node" or tostring(signer.node), tostring(key_id)) }
end

-- ship: the release set becomes the orphan commit `artifacts/node-<sha12>` on the incoming repository - and a
-- ref that already carries this source commit is recorded and reused rather than pushed twice. Then the ref
-- is read back and held to every file its own PUBLISH.sh names: the check that was missing on 13/11, when a
-- ref named SHA256SUMS it did not carry.
impl.ship = function(run, options)
  local evidence = sink(run, "ship")
  local tree, sha = run.tree, run.journal.tree_commit
  local artifacts = run.journal.artifacts
  if not artifacts or not artifacts.dir then
    return false, { error = "ship_without_artifacts", observed = "the artifacts step has not built a release set" }
  end
  if not read(artifacts.dir .. "/SHA256SUMS.sig") then
    return false, { error = "ship_unsigned", observed = "the release set has no SHA256SUMS.sig, so the sign step has not run",
      next = "run the sign step: `wa land --resume` (it signs where the vault is and brings the signature back)" }
  end
  local incoming = M.incoming()
  local ref = "artifacts/node-" .. sha:sub(1, 12)
  local tip = remote_tip(tree, incoming, "refs/heads/" .. ref)
  local reused = false
  if tip then
    local fetched = git(run, tree, "fetch --quiet " .. quote(incoming) .. " " .. quote("refs/heads/" .. ref), 600)
    local probe = M.exec("git -C " .. quote(slashes(tree)) .. " show " ..
      quote("FETCH_HEAD:node-" .. sha:sub(1, 12) .. ".manifest"), slashes(tree), 120)
    if (fetched.code or 1) == 0 and tostring(probe.stdout or ""):match("source_commit=" .. sha) then
      reused = true
      evidence("the ref " .. ref .. " already carries this source commit (" .. tip .. "); not shipped again\n")
    end
  end
  local artifacts_commit = tip
  if not reused then
    local command = "WA_RELEASE_SIGN_DEFER=1 bash scripts/publish-artifacts-branch.sh --remote " .. quote(incoming) ..
      " --commit " .. quote(sha) .. " --from " .. quote(artifacts.dir) .. " --out " .. quote(artifacts.dir)
    evidence(command_line("ship", command))
    local result = M.exec(command, slashes(tree), 3600)
    evidence((result.stdout or "") .. (result.stderr or ""))
    if (result.code or 1) ~= 0 then
      return false, { error = "ship_failed", observed = first_line(result.stderr ~= "" and result.stderr or result.stdout),
        next = "the shipper's own words are in " .. M.evidence_path(run.id, "ship") }
    end
    -- `PUBLISHREADY <ref> <artifacts commit> source=<landed commit>`: the ref carries an orphan commit of its
    -- own, so the two are compared separately - a reference built from another tree is not this release.
    local shipped_ref, shipped_commit, source = tostring(result.stdout or ""):match(
      "PUBLISHREADY%s+(%S+)%s+(%x+)%s+source=(%x+)")
    if not shipped_ref then
      return false, { error = "ship_unreadable", observed = "the shipper printed no PUBLISHREADY line",
        next = "inspect " .. M.evidence_path(run.id, "ship") }
    end
    if source ~= sha or shipped_ref ~= ref then
      return false, { error = "ship_wrong_commit",
        observed = "the ref " .. shipped_ref .. " names source " .. tostring(source):sub(1, 12) ..
          ", the landed tip is " .. sha:sub(1, 12) }
    end
    artifacts_commit = shipped_commit
  end
  -- Read the ref back out of the remote and hold it to the files PUBLISH.sh names, and to its own signature.
  local fetched = git(run, tree, "fetch --quiet " .. quote(incoming) .. " " .. quote("refs/heads/" .. ref), 600)
  evidence(command_line("fetch ship", "git fetch " .. incoming .. " refs/heads/" .. ref))
  evidence((fetched.stdout or "") .. (fetched.stderr or ""))
  if (fetched.code or 1) ~= 0 then
    return false, { error = "ship_not_readback", observed = "cannot fetch " .. ref .. " from " .. incoming }
  end
  local script = M.exec("git -C " .. quote(slashes(tree)) .. " show " .. quote("FETCH_HEAD:PUBLISH.sh"), slashes(tree), 120)
  if (script.code or 1) ~= 0 then
    return false, { error = "ship_no_publish_script", observed = ref .. " carries no PUBLISH.sh" }
  end
  local line = tostring(script.stdout or ""):match("gh release create[^\r\n]*")
  if not line then
    return false, { error = "ship_no_publish_line", observed = "the shipped PUBLISH.sh names no `gh release create`" }
  end
  local missing, named = {}, {}
  for word in (line .. " "):gmatch("(%S+)%s") do
    local name = word:gsub("^%./", "")
    if name:match("^[%w%._%-]+$") and not name:match("^node%-%x+%.manifest$") and
       (name:match("^wa%-") or name:match("^SHA256SUMS") or name:match("%.manifest$")) then
      named[name] = true
      local check = git(run, tree, "cat-file -e " .. quote("FETCH_HEAD:" .. name), 120)
      if (check.code or 1) ~= 0 then missing[#missing + 1] = name end
    end
  end
  if #missing > 0 then
    return false, { error = "ship_incomplete",
      observed = ref .. " does not carry " .. table.concat(missing, ", ") .. " though its PUBLISH.sh names them" ..
        (reused and " (the ref was already there for this commit: it was shipped incomplete)" or ""),
      next = "fix the shipper and publish a complete ref for this commit (an existing artifacts/ ref is reused, "
        .. "never overwritten, so a broken one has to be replaced deliberately)" }
  end
  if not named["SHA256SUMS.sig"] then
    return false, { error = "ship_unsigned",
      observed = ref .. "'s PUBLISH.sh names no SHA256SUMS.sig, so this release would be published unsigned",
      next = "the signed sums ship with the payloads (`scripts/lib/release-signing.sh`); fix the publisher" }
  end
  local count = 0
  for _ in pairs(named) do count = count + 1 end
  artifacts.ref = ref
  artifacts.artifacts_commit = artifacts_commit
  artifacts.files = count
  return true, { detail = string.format("%s %s carries all %d file(s) its PUBLISH.sh names%s", ref,
    tostring(artifacts_commit):sub(1, 12), count, reused and " (already there, not pushed again)" or "") }
end

-- publish: the release itself. The credential is the only thing this step can be missing: the signature is
-- already made and verified (the `sign` step) and the ref already exists (the `ship` step).
-- publish: the release itself. The credential is the only thing this step can be missing: the signature is
-- already made and verified (`sign`) and the ref already exists (`ship`).
--
-- Two things this step learned (19/11, items 26 and 27):
--   * A BINARY IS NOT A CREDENTIAL. `command -v gh` says a program exists; a signed-out gh fails afterwards,
--     and the journal has already said done. So the check is `gh auth status` - where the publish runs.
--   * `--account <node>` CREATES THE RELEASE THERE, as that node's own account: the ref is fetched from the
--     incoming repository the node can already reach, and PUBLISH.sh runs from that extract with its assets
--     beside it. No token and no checkout of the landing is needed on this machine.
impl.publish = function(run, options)
  local evidence = sink(run, "publish")
  local tree, sha = run.tree, run.journal.tree_commit
  local artifacts = run.journal.artifacts
  if not artifacts or not artifacts.ref then
    return false, { error = "publish_without_artifacts", observed = "the ship step has not run",
      next = "the release ref is what PUBLISH.sh lives in; run `wa land --resume`" }
  end
  if artifacts.signed ~= true then
    return false, { error = "publish_unsigned",
      observed = "the journal records no verified signature for this release",
      next = "the sign step runs before this one and refuses to continue unsigned; nothing is published here" }
  end
  local tag = "node-" .. sha:sub(1, 12)
  local start = run.journal.start or {}
  local account = trim(options.account or start.account)
  local routed = account ~= "" and account ~= "local" and account ~= "this"
  -- WHETHER THE RELEASE EXISTS IS A FACT, AND IT IS ASKED FIRST (21/11, hand fix 5). This used to run AFTER
  -- the credentials gate, so `wa land --resume` on a round whose release HAD been published stopped at
  -- publish_needs_credentials for ever; a systemd user unit met the same gate first, because gh auth lives in
  -- the desktop keyring a unit cannot reach. A release that exists needs no token to be RECORDED as published,
  -- so the question is asked before any credential is demanded - and it is answered from the public API too,
  -- because a release on a public repository is a fact anyone can read (gh may be unable to run here at all).
  local function release_state()
    local probe = "gh release view " .. quote(tag) .. " >/dev/null 2>&1 && echo present || echo absent"
    if routed then
      local reply = M.node_bash(account, probe)
      if trim(tostring((reply or {}).stdout or "")) == "present" then return "present" end
    elseif trim(tostring((M.exec(probe, "", 120) or {}).stdout or "")) == "present" then
      return "present"
    end
    -- The public API. An answer that cannot be read is unknown, never absent: a check that guessed would
    -- report a published release as missing and publish it twice.
    local ok, banner = pcall(dofile, "lua/core/update_banner.lua")
    local repo = ok and type(banner) == "table" and banner.repo and banner.repo(tree) or ""
    if repo == "" then return "unknown" end
    local url = "https://api.github.com/repos/" .. repo .. "/releases/tags/" .. tag
    local body = M.exec("curl -fsSL --max-time 20 " .. quote(url) .. " 2>/dev/null", "", 40) or {}
    if (body.code or 1) ~= 0 then return "unknown" end
    local text = tostring(body.stdout or "")
    if not text:find(tag, 1, true) then return "unknown" end
    local assets = 0
    for _ in text:gmatch('"name"%s*:') do assets = assets + 1 end
    if assets == 0 then return "present_no_assets" end
    return "present"
  end
  local state_of_release = release_state()
  if state_of_release == "present" then
    evidence("release " .. tag .. " already exists; not published again\n")
    run.journal.publish = { tag = tag, state = "already_present", signed = true, key_id = artifacts.key_id }
    return true, { detail = "release " .. tag .. " already published (not repeated)" }
  end
  if state_of_release == "present_no_assets" then
    return false, { error = "publish_release_incomplete",
      observed = "release " .. tag .. " exists on GitHub with no assets, so it is not the release a node installs",
      next = "delete it and publish again (gh release delete " .. tag .. " --yes, then wa land --resume), or publish by hand from the shipped ref" }
  end
  -- THE CHECK IS `gh auth status`, NOT `command -v gh`: the question is whether a token works HERE, and a
  -- binary that is installed and signed out answers it the same way a missing one does. Where the publish is
  -- routed, the question is asked ON THE ACCOUNT NODE, because that is whose token creates the release.
  local gh_command = "command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && echo yes || echo no"
  local gh_answer
  if routed then
    local reply, problem = M.node_bash(account, gh_command)
    if not reply then
      return false, { error = "publish_needs_credentials", detail = "the release " .. tag .. " was not published",
        observed = problem.detail .. ": " .. problem.observed,
        next = "check that node is reachable and signed in (`wa nodes`, then `gh auth status` there), then `wa land --resume`" }
    end
    gh_answer = tostring(reply.stdout or "")
    evidence("gh auth status on " .. account .. ": " .. trim(gh_answer) .. "\n")
  else
    local here = M.exec(gh_command, "", 60) or {}
    gh_answer = tostring(here.stdout or "")
  end
  if trim(gh_answer) ~= "yes" then
    return false, { error = "publish_needs_credentials", detail = "the release " .. tag .. " was not published",
      observed = routed and ("`gh` on " .. account .. " is missing or not signed in")
        or ("no `gh` here, or a `gh` this machine is not signed in to, so the release cannot be created here"),
      next = routed and ("sign in on " .. account .. " (`gh auth login` there), then `wa land --resume`")
        or ("this is the keyring cause: gh auth status reads a token from the desktop keyring, and a systemd user unit has no session bus to unlock it - so gh is installed and signed out HERE. Publish as an operator: git fetch " ..
          M.incoming() .. " refs/heads/" .. artifacts.ref .. ":refs/heads/" .. artifacts.ref ..
          " && git worktree add /tmp/" .. tag .. " " .. artifacts.ref .. " && bash /tmp/" .. tag .. "/PUBLISH.sh" ..
          " - or give the unit a token it can read (GH_TOKEN in its environment), then wa land --resume") }
  end
  -- The artifacts commit is fetched again here rather than trusted from the ship step: on a resume that step
  -- is `done` and its FETCH_HEAD died with the process that made it.
  local refetch = git(run, tree, "fetch --quiet " .. quote(M.incoming()) .. " " .. quote("refs/heads/" .. artifacts.ref), 600)
  evidence(command_line("refetch artifacts", "git fetch " .. M.incoming() .. " refs/heads/" .. artifacts.ref))
  evidence((refetch.stdout or "") .. (refetch.stderr or ""))
  if (refetch.code or 1) ~= 0 then
    return false, { error = "publish_no_artifacts_ref",
      observed = "cannot fetch " .. tostring(artifacts.ref) .. " from " .. M.incoming(),
      next = "git fetch " .. M.incoming() .. " refs/heads/" .. tostring(artifacts.ref) }
  end
  local scratch = M.run_dir(run.id) .. "/publish"
  local extract = M.exec("mkdir -p " .. quote(scratch) .. " && git -C " .. quote(slashes(tree)) ..
    " archive FETCH_HEAD | tar -x -C " .. quote(scratch), "", 300)
  evidence(command_line("extract", "git archive " .. artifacts.ref .. " | tar -x -C " .. scratch))
  evidence((extract.stdout or "") .. (extract.stderr or ""))
  if (extract.code or 1) ~= 0 then
    return false, { error = "publish_extract_failed", observed = first_line(extract.stderr ~= "" and extract.stderr or extract.stdout) }
  end
  local published
  if routed then
    -- The files travel as content (base64, one file per command): PUBLISH.sh runs the release script THIS
    -- round shipped, with the assets beside it, under the account node's own token.
    local script_text = read(scratch .. "/PUBLISH.sh")
    if not script_text then
      return false, { error = "publish_no_script", observed = "the extract carries no PUBLISH.sh" }
    end
    local names, seen = { "PUBLISH.sh" }, { ["PUBLISH.sh"] = true }
    for word in tostring(script_text):gmatch("%S+") do
      local bare = tostring(word):gsub("^%./", "")
      if not seen[bare] and (bare:match("^wa%-") or bare:match("^SHA256SUMS") or bare:match("%.manifest$")) then
        seen[bare] = true
        names[#names + 1] = bare
      end
    end
    local script = { "set -e", "d=$(mktemp -d)", [[trap 'rm -rf "$d"' EXIT]], [[cd "$d"]] }
    for _, name in ipairs(names) do
      if not read(scratch .. "/" .. name) then
        return false, { error = "publish_asset_missing",
          observed = scratch .. "/" .. name .. " is named by PUBLISH.sh but is not in the extract",
          next = "the shipped ref is incomplete: inspect " .. M.incoming() .. " refs/heads/" .. artifacts.ref }
      end
      local b64 = M.exec("base64 -w 0 < " .. quote(scratch .. "/" .. name), "", 120) or {}
      if (b64.code or 1) ~= 0 then
        return false, { error = "publish_asset_unreadable", observed = "cannot read " .. scratch .. "/" .. name }
      end
      script[#script + 1] = "printf %s " .. quote(trim(tostring(b64.stdout or ""))) .. " | base64 -d > " .. quote(name)
    end
    script[#script + 1] = "bash ./PUBLISH.sh"
    evidence(command_line("publish on " .. account, "bash PUBLISH.sh (" .. tostring(#names) .. " file(s) sent)"))
    local reply, problem = M.node_bash(account, table.concat(script, "\n"))
    if not reply then
      return false, { error = "publish_failed", observed = problem.detail .. ": " .. problem.observed,
        next = "check that node is reachable and signed in, then `wa land --resume`" }
    end
    evidence((reply.stdout or "") .. (reply.stderr or ""))
    published = { code = reply.code, stdout = reply.stdout, stderr = reply.stderr }
  else
    published = M.exec("bash " .. quote(scratch .. "/PUBLISH.sh"), scratch, 1800)
    evidence(command_line("publish", "bash " .. scratch .. "/PUBLISH.sh"))
    evidence((published.stdout or "") .. (published.stderr or ""))
  end
  if (published.code or 1) ~= 0 then
    local text = tostring(published.stderr ~= "" and published.stderr or published.stdout)
    return false, { error = "publish_failed",
      observed = first_line(text ~= "" and text or "the publisher answered nothing"),
      next = "the publisher's own words are in " .. M.evidence_path(run.id, "publish") }
  end
  run.journal.publish = { tag = tag, state = "published", signed = true, key_id = artifacts.key_id,
    account = routed and account or nil }
  return true, { detail = "release " .. tag .. " published (signed, key " .. tostring(artifacts.key_id) .. ")" ..
    (routed and (", on " .. account) or "") }
end

-- ---------------------------------------------------------------- the public channel (`linux`)
--
-- THE SECOND CHANNEL (Fable, 22/11). `node-<sha12>` is what an EXISTING node updates from. A machine with no
-- node at all installs from `releases/index-linux.json` (`scripts/install.sh` -> `scripts/linux/bootstrap.sh`),
-- and nothing in this machine had ever written to it: measured 22/11, six node releases were cut in one day
-- while the channel's newest x86_64 entry was 23 days old (`v0.1.0-alpha.13` at `d80d86bd`, 30/10). The
-- fresh-install proof died on `core_lib_unreachable` - a 404 on a file that entry fetches - and an install from
-- a stale entry works until the day a path it names moves, which is what made the lag silent.
--
-- WHERE IT SITS: after `deploy` (Fable, 23/11, measured). It was written between `publish` and `deploy`, and that
-- was wrong: this step moves `main` by one commit (the bump below), and a node only deploys a commit while
-- `HEAD == origin/main == that commit` (`scripts/deploy-rendezvous.sh:10,13`; `scripts/deploy.sh` builds nothing
-- but a canonical tree that is exactly origin/main). Publishing the channel first therefore turned every tree
-- deploy of the shocked release into `source is not origin/main`, and a cut whose deploy is refused is a cut
-- that shipped to nobody. Now the ring takes the released commit first, and `main` moves afterwards - the bump
-- is a one-line Lua change (`wa_compiled_input` says so), so the sentinel's next redeploy is cheap. A failure
-- here is a failure of THIS step, named, with every earlier fact true: the release exists, it is signed, it is
-- published, and the fleet has it.
--
-- THE INDEX IS A COMMIT, and this is the one place a release writes one. The channel is read from `main`
-- (`raw.githubusercontent.com/<repo>/main/releases/index-linux.json`), so an entry that only existed in this
-- run's worktree would change nothing at all. So the entry is committed HERE, in a worktree of `origin/main`
-- (never the run's own tree: a resume re-creates that tree from `tree_commit`, and a moved HEAD there would
-- break the resume), with an ALLOW-LIST pathspec - `git commit -- releases/index-linux.json`, so nothing else
-- can enter the commit - fast-forwarded onto `main` (never a force push) and read back from the remote.
--
-- WHAT IT REFUSES, by name: a signer that is not this node (the publisher signs the channel's own SHA256SUMS
-- where it builds, and build/sum/upload split across three hosts is a different piece of work); a run whose
-- node release is not signed (no channel entry may name a commit whose release this machine would not ship);
-- and, after the push, a live channel that does not name this commit for every target or that is still older
-- than the newest node release - the two facts that make the channel an answer instead of a file.

M.LINUX_TARGETS = "x86_64-unknown-linux-musl aarch64-unknown-linux-musl"
M.LINUX_INDEX = "releases/index-linux.json"

-- ---------------------------------------------------------------- the product version (`VERSION`)
--
-- ONE OWNER (Victor, 22/11): the `VERSION` file at the tree root. The binary embeds it at build time
-- (`rust/wa-host/build.rs`, `rust/wa-capabilities/src/host.rs`), the welcome line and `wa --version` print it,
-- and the RELEASE is the only thing that writes it. A release takes the next number: `v0.1.0` first, then
-- 0.1.1, 0.1.2 ... - the patch moves by one per release, and minor/major move ONLY when the operator says so
-- with `--minor`/`--major` AND Victor's own quoted instruction in `docs/release/RELEASE_NOTES.md` (he decides
-- when a 1.0.0 is due: "[a 1.0.0] needs major changes so i need to say so").
M.VERSION_FILE = "lua/core/build_identity.lua"
M.VERSION_NOTES = "docs/release/RELEASE_NOTES.md"

-- <text> -> {major, minor, patch} or nil. `0.1.0` and nothing else: a version this does not understand must not
-- be bumped by accident.
function M.parse_product_version(text)
  local major, minor, patch = tostring(text or ""):match("^(%d+)%.(%d+)%.(%d+)$")
  if not major then return nil end
  return { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch) }
end

function M.format_product_version(version)
  return string.format("%d.%d.%d", tonumber(version.major) or 0, tonumber(version.minor) or 0, tonumber(version.patch) or 0)
end

-- <version-or-text> -> the release tag the public channel publishes under (`v0.1.0`).
function M.version_tag(version)
  local text = tostring(version or "")
  if text:sub(1, 1) == "v" then return text end
  return "v" .. text
end

-- <text> -> the number `M.PRODUCT_VERSION` names in lua/core/build_identity.lua, or nil.
function M.product_version_line(text)
  local value = tostring(text or ""):match([[M%.PRODUCT_VERSION%s*=%s*"([^"]*)"]] )
  if not value then return nil end
  return trim(value)
end

-- <tree> -> the version this tree carries, or nil + why. Read from the checkout, so a resume reads the same
-- number the release was started from - and from the ONE owner (`M.PRODUCT_VERSION`), never a second file.
function M.tree_version(tree)
  local text = read(slashes(tree) .. "/" .. M.VERSION_FILE)
  if not text then return nil, "version_source_missing: " .. M.VERSION_FILE .. " is not in this tree" end
  local line = M.product_version_line(text)
  if not line then
    return nil, "version_invalid: " .. M.VERSION_FILE .. " has no M.PRODUCT_VERSION line (this release bumps only d.d.d)"
  end
  local parsed = M.parse_product_version(line)
  if not parsed then
    return nil, "version_invalid: M.PRODUCT_VERSION is '" .. line .. "' and this release bumps only d.d.d"
  end
  return parsed, nil
end

-- <current> <options> -> the number the NEXT cut takes, and how it was decided. This is the BUMP the release
-- writes, not the release it publishes: Fable, 23/11 - "the constant on main always names the release this tree
-- WILL be cut as", so the cut ships `current` and leaves `next` behind for the cut after it.
function M.bump_version(current, options)
  options = options or {}
  if options.major then
    return { major = current.major + 1, minor = 0, patch = 0 }, "explicit major bump"
  end
  if options.minor then
    return { major = current.major, minor = current.minor + 1, patch = 0 }, "explicit minor bump"
  end
  return { major = current.major, minor = current.minor, patch = current.patch + 1 }, "one patch past the release it follows"
end

-- <tree> <tag> <commit> -> true when the tag is absent or names THIS commit, false + why when it names ANOTHER one.
--
-- The distinction is the difference between a resume and a collision (Fable, round 3): `scripts/publish-linux-channel.sh`
-- creates the release tag with `gh release create`, and the index commit is pushed LATER - so between those two a
-- tag exists that this very run made, and refusing it would make `--resume` impossible for ever. A tag that names
-- another commit is a release somebody else published under this number, and that is refused.
function M.version_tag_owner(tree, tag, commit)
  local local_commit = rev(tree, tag)
  local remote_commit = remote_tip(tree, M.origin(), "refs/tags/" .. tag)
  local holder = local_commit or remote_commit
  if not holder then return true, nil end
  local mine = tostring(commit or "")
  if mine ~= "" and (local_commit == mine or remote_commit == mine) then return true, nil end
  local where = (local_commit == holder) and "in this clone" or ("on " .. M.origin())
  return false, tag .. " already exists " .. where .. " and names " .. tostring(holder):sub(1, 12) .. ", not " ..
    (mine ~= "" and mine:sub(1, 12) or "this commit")
end

-- <tree> <kind> <version> -> true, or false + why. A minor or major bump is Victor's decision, and the ONLY
-- evidence this accepts is his instruction QUOTED in the release notes file, naming the bump and the version it
-- produces. A flag alone is never enough.
function M.bump_is_authorised(tree, kind, version)
  local text = read(slashes(tree) .. "/" .. M.VERSION_NOTES)
  if not text then
    return false, "notes_missing: " .. M.VERSION_NOTES .. " is not in this tree, so no " .. kind .. " bump can be authorised"
  end
  local text_version = M.format_product_version(version)
  local want = M.version_tag(text_version)
  for line in text:gmatch("[^\r\n]+") do
    if line:find("Victor", 1, true) then
      for quote in line:gmatch('"(.-)"') do
        local lowered = quote:lower()
        local names = quote:find(want, 1, true) or quote:find(text_version, 1, true)
        if lowered:find(kind, 1, true) and names then return true, line end
      end
    end
  end
  return false, "bump_not_authorised: a " .. kind .. " bump needs Victor's quoted instruction naming " .. want ..
    " in " .. M.VERSION_NOTES .. " - a flag alone never moves the minor or the major"
end

-- <options> -> the triples to publish, as a list. An unknown one is refused by the publisher too; here it is
-- refused before the build (the allow-list is the channel's, and the channel publishes static musl only).
local function linux_targets(options)
  local list = {}
  for target in tostring((type(options) == "table" and options.linux_targets) or M.LINUX_TARGETS):gmatch("%S+") do
    list[#list + 1] = target
  end
  return list
end

-- <tree> -> the index `origin/main` carries, or nil + why. The fetch is what makes the answer the one a fresh
-- machine would read; a fetch that fails is "could not tell", never "not published".
local function origin_main_index(tree)
  local fetched = M.exec("git -C " .. quote(slashes(tree)) .. " fetch --quiet " .. quote(M.origin()) .. " main", tree, 600)
  if (fetched.code or 1) ~= 0 then
    return nil, "cannot fetch " .. M.origin() .. " main: " .. first_line(tostring(fetched.stderr or "") .. tostring(fetched.stdout or ""))
  end
  local shown = M.exec("git -C " .. quote(slashes(tree)) .. " show " .. quote("origin/main:" .. M.LINUX_INDEX), tree, 120)
  if (shown.code or 1) ~= 0 then return nil, "origin/main carries no " .. M.LINUX_INDEX end
  local decoded, doc = pcall(json.decode, tostring(shown.stdout or ""))
  if not decoded or type(doc) ~= "table" then return nil, "origin/main:" .. M.LINUX_INDEX .. " is not JSON" end
  return doc
end

-- <doc> <sha> <targets> -> the entries this commit has, and the targets it does not.
local function index_covers(doc, sha, targets)
  local found, missing = {}, {}
  for _, row in ipairs((type(doc) == "table" and doc.releases) or {}) do
    if type(row) == "table" and row.commit == sha and row.target then found[tostring(row.target)] = row end
  end
  for _, target in ipairs(targets) do if not found[target] then missing[#missing + 1] = target end end
  return found, missing
end

-- <text> -> the publisher's own refusal name and the line it came on (build_failed, index_stale, ...). A
-- publisher that failed without naming anything is still a refusal, and says so as `failed`.
local function channel_refusal(text)
  for line in tostring(text):gmatch("[^\r\n]+") do
    local name = line:match("linux%-channel: ([%a][%w_]*):")
    if name then return name, line end
  end
  return nil, first_line(text)
end

impl.linux = function(run, options)
  local evidence = sink(run, "linux")
  local tree, sha = run.tree, run.journal.tree_commit
  if not tree or rev(tree, "HEAD") == nil then
    return false, { error = "linux_without_tree", observed = "this run has no checkout to build the bundle from",
      next = "wa release cut --run " .. tostring(run.id) .. " --resume" }
  end
  if not sha or #tostring(sha) < 12 then
    return false, { error = "linux_without_commit", observed = "the run records no landed commit (tree_commit)",
      next = "wa release cut --run " .. tostring(run.id) .. " --resume" }
  end
  local short = tostring(sha):sub(1, 12)
  -- THE VERSION IS THE TREE'S OWN NUMBER (`M.tree_version`): main's constant always names the release this tree
  -- will be cut as, so the bytes built here print the number they are released as. A minor or major bump is
  -- refused unless Victor's quoted instruction is in the notes file, and it changes the BUMP, not this release.
  local current, why_version = M.tree_version(tree)
  if not current then
    return false, { error = "linux_version_unreadable",
      detail = "the channel was not published for " .. short .. " because this release has no version",
      observed = tostring(why_version),
      next = "set M.PRODUCT_VERSION in " .. M.VERSION_FILE .. " (the current release number, e.g. 0.1.0) and cut again" }
  end
  -- THE RELEASE IS THE TREE'S NUMBER (Fable, 23/11): the bundles are built from THIS commit, and the binary
  -- `build.rs` embeds the constant of the tree it builds - so shipping `current` is what makes the installed
  -- bytes say the same number as the tag and the index. The BUMP (`next`) is written behind it, for the cut
  -- after this one.
  local version_text = M.format_product_version(current)
  local tag = M.version_tag(version_text)
  -- THE SAME TWO FACTS AS THE PREFLIGHT (`M.release_checks.version`), checked AGAIN here: the preflight is the
  -- first second and this is the last, and a version that is already released or an unquoted minor bump must be
  -- refused at BOTH ends - a caller that reaches this step without the preflight gets the same answer.
  -- A TAG THAT POINTS AT THIS RELEASE IS OURS (Fable, round 3). The publisher creates it (`gh release create`), and
  -- the index commit is pushed afterwards: a failure in between would otherwise answer `version_already_released`
  -- for ever, for a tag this very run made. So only a tag pointing at ANOTHER commit refuses - the publisher
  -- re-uploads with `--clobber` into a release of ours, which is what makes a resume idempotent.
  local ours_tag, why_ours = M.version_tag_owner(tree, tag, sha)
  if not ours_tag then
    return false, { error = "version_already_released",
      detail = "the public channel for " .. short .. " was not published: its version is released elsewhere",
      observed = tostring(why_ours),
      next = "main's M.PRODUCT_VERSION must name the NEXT release: publish the bump commit (a release writes it), then cut again" }
  end
  if options.major or options.minor then
    local kind = options.major and "major" or "minor"
    local bumped, _ = M.bump_version(current, options)
    local authorised, why_bump = M.bump_is_authorised(tree, kind, bumped)
    if not authorised then
      return false, { error = "linux_bump_not_authorised",
        detail = "the " .. kind .. " bump was refused, so nothing was published",
        observed = tostring(why_bump),
        next = "quote Victor's instruction naming " .. M.version_tag(M.format_product_version(bumped)) .. " in " .. M.VERSION_NOTES ..
          ", commit it, then wa release cut --run " .. tostring(run.id) .. " --resume" }
    end
  end
  local next_version, version_why = M.bump_version(current, options)
  local next_text = M.format_product_version(next_version)
  -- AN ALLOW-LIST, before anything is built or published: this channel publishes the two STATIC musl triples,
  -- because a bundle that is not static needs a libc floor on the machine that installs it (the 30/10 defect
  -- that made the first published bundle refuse on an older Ubuntu). A caller cannot widen it by naming a
  -- triple the channel does not publish.
  local targets = linux_targets(options)
  local allowed = {}
  for target in tostring(M.LINUX_TARGETS):gmatch("%S+") do allowed[target] = true end
  for _, target in ipairs(targets) do
    if not allowed[target] then
      return false, { error = "linux_target_unknown",
        detail = "the public channel was not published for " .. short,
        observed = "the channel is asked for " .. tostring(target) .. ", and it publishes " .. tostring(M.LINUX_TARGETS),
        next = 'name only the triples the channel publishes (--linux-targets "' .. tostring(M.LINUX_TARGETS) .. '"), or publish that one by hand with scripts/publish-linux-channel.sh' }
    end
  end
  local artifacts = run.journal.artifacts or {}
  if artifacts.signed ~= true then
    return false, { error = "linux_unsigned_release",
      detail = "the public channel was not published for " .. short,
      observed = "the node release for this commit is not signed (the sign step is before this one)",
      next = "wa release cut --run " .. tostring(run.id) .. " --resume   (sign, ship, publish, then the channel)" }
  end
  -- THE SIGNER, and the same two hosts the `sign` step already has: the bundle is built where the toolchain is
  -- (here) and the sums are signed where the vault answers (here, or the node this run named). The publisher
  -- has the two half-modes for exactly that (`--build-only`, `--upload-only`), so a routed signature is the same
  -- chain, split either side of one signature.
  local signer, problem = M.signer(options)
  if not signer then return false, problem end
  local dir = (run.journal.release_dir or (M.run_dir(run.id) .. "/release")) .. "/linux-channel"
  M.exec("mkdir -p " .. quote(dir), "", 60)

  -- THE LIVE CHANNEL, asked first: a resume (or a cut whose channel step already ran) finds the entries on
  -- origin/main and does not publish the same commit twice.
  local live, why = origin_main_index(tree)
  local already = nil
  if live then
    local _, missing = index_covers(live, sha, targets)
    if #missing == 0 then already = true end
  else
    evidence("origin/main's channel index could not be read first (" .. tostring(why) .. "); publishing without the reuse check\n")
  end

  local live_copy = dir .. "/index-linux.origin-main.json"
  -- <none> -> verify what a FRESH MACHINE reads: the copy origin/main carries, naming this commit for every
  -- target, and no older than the newest node release. Two facts, both read from the remote.
  local function verify_live()
    local doc, why_not = origin_main_index(tree)
    if not doc then
      return false, { error = "linux_index_unreadable", detail = "the channel could not be read back",
        observed = tostring(why_not), next = "git -C " .. slashes(tree) .. " fetch " .. M.origin() .. " main, then wa release cut --run " .. tostring(run.id) .. " --resume" }
    end
    local found, missing = index_covers(doc, sha, targets)
    local names_count = 0
    for _ in pairs(found) do names_count = names_count + 1 end
    if #missing > 0 then
      return false, { error = "linux_index_incomplete",
        detail = "origin/main's channel index does not name " .. short .. " for every target this step published",
        observed = "missing " .. table.concat(missing, ", ") .. " (the live index names " .. tostring(names_count) .. " target(s) for this commit)",
        next = "the live channel is read with: git -C " .. slashes(tree) .. " show origin/main:" .. M.LINUX_INDEX .. "; nothing was removed" }
    end
    local shown = M.exec("git -C " .. quote(slashes(tree)) .. " show " .. quote("origin/main:" .. M.LINUX_INDEX), tree, 120)
    if (shown.code or 1) ~= 0 or not write(live_copy, tostring(shown.stdout or "")) then
      return false, { error = "linux_index_unreadable", observed = "cannot write the live copy to " .. live_copy }
    end
    local fresh = M.exec("bash scripts/check-linux-channel-fresh.sh --index " .. quote(live_copy) .. " --repo " .. quote(slashes(tree)), slashes(tree), 300)
    evidence(command_line("channel freshness", "scripts/check-linux-channel-fresh.sh --index <live copy> --repo " .. slashes(tree)))
    evidence((fresh.stdout or "") .. (fresh.stderr or ""))
    local verdict = first_line(tostring(fresh.stdout or ""))
    if (fresh.code or 1) == 1 then
      return false, { error = "linux_index_stale", detail = "the published channel is older than the newest node release, so a fresh machine would install an older commit",
        observed = verdict, next = "the channel index on main names an entry older than the newest node release: re-run the step after the release it is missing (wa release cut --run " .. tostring(run.id) .. " --resume), or publish that release's channel entry" }
    end
    if (fresh.code or 1) ~= 0 then
      return false, { error = "linux_index_freshness_unknown", detail = "the channel could not be judged",
        observed = verdict ~= "" and verdict or "check-linux-channel-fresh.sh answered exit " .. tostring(fresh.code or 1),
        next = "the check's own words are in " .. M.evidence_path(run.id, "linux") }
    end
    return true, verdict
  end

  if already then
    local passed, verdict = verify_live()
    if not passed then return false, verdict end
    run.journal.linux = { tag = tag, version = version_text, next_version = next_text, targets = targets,
      state = "already_present", live = verdict }
    return true, { detail = "the channel already names " .. short .. " (v" .. version_text .. ") for " .. #targets ..
      " target(s) on " .. M.origin() .. "/main (not published again; " .. tostring(verdict) .. ")" }
  end

  -- A WORKTREE OF origin/main for the commit: the run's own tree is the release's commit and stays where it is.
  local index_tree = dir .. "/index-tree"
  local base = rev(tree, "origin/main")
  if not base then
    return false, { error = "linux_without_main", observed = "origin/main does not resolve in " .. slashes(tree) .. " after the fetch",
      next = "git -C " .. slashes(tree) .. " fetch " .. M.origin() .. " main, then wa release cut --run " .. tostring(run.id) .. " --resume" }
  end
  if rev(index_tree, "HEAD") ~= base then
    git(run, tree, "worktree prune", 120)
    if rev(index_tree, "HEAD") ~= nil then git(run, tree, "worktree remove --force " .. quote(index_tree), 300) end
    local added = git(run, tree, "worktree add --quiet --detach " .. quote(index_tree) .. " " .. quote(base), 600)
    evidence(command_line("index worktree", "git worktree add --detach " .. index_tree .. " " .. base))
    evidence((added.stdout or "") .. (added.stderr or ""))
    if (added.code or 1) ~= 0 or rev(index_tree, "HEAD") ~= base then
      return false, { error = "linux_index_worktree_failed",
        observed = "git worktree add --detach " .. index_tree .. " " .. base:sub(1, 12) .. " exited " .. tostring(added.code) .. ": " .. last_line(tostring(added.stderr or "") .. tostring(added.stdout or "")),
        next = "git -C " .. slashes(tree) .. " worktree prune, then wa release cut --run " .. tostring(run.id) .. " --resume" }
    end
  end
  local index = slashes(index_tree) .. "/" .. M.LINUX_INDEX
  -- THE BUMP IS WRITTEN IN THE SAME COMMIT as the entry it follows: one commit, one release, so the number a
  -- person reads and the bytes a machine installs never disagree. It writes `next` (the following release), never
  -- the number this release is published as.
  local version_path = slashes(index_tree) .. "/" .. M.VERSION_FILE
  local version_source = read(version_path)
  if not version_source then
    return false, { error = "linux_version_write_failed", observed = "cannot read " .. version_path }
  end
  -- ONE LINE, rewritten in place: every other byte of the module stays as the release found it.
  local rewritten = version_source:gsub([[M%.PRODUCT_VERSION%s*=%s*"[^"]*"]], "M.PRODUCT_VERSION = \"" .. next_text .. "\"", 1)
  if rewritten == version_source and version_source:find("M.PRODUCT_VERSION", 1, true) == nil then
    return false, { error = "linux_version_write_failed", observed = version_path .. " has no M.PRODUCT_VERSION line to write" }
  end
  if not write(version_path, rewritten) then
    return false, { error = "linux_version_write_failed", observed = "cannot write " .. version_path }
  end

  -- THE PUBLISH: build, sign, verify, upload, write the entry. One command, so the standalone operator path and
  -- the release path are the same code (scripts/publish-linux-channel.sh).
  local command = "bash scripts/publish-linux-channel.sh --tree " .. quote(slashes(tree)) .. " --commit " .. quote(sha) ..
    " --tag " .. quote(tag) .. " --targets " .. quote(table.concat(targets, " ")) .. " --out " .. quote(dir .. "/out") ..
    " --index " .. quote(index) .. " --reason " .. quote("wa release cut " .. tostring(run.id))
  local published
  if signer.kind == "local" then
    evidence(command_line("publish the channel", command))
    published = M.exec(command, slashes(tree), 7200)
    evidence((published.stdout or "") .. (published.stderr or ""))
  else
    evidence(command_line("build the channel", command .. " --build-only"))
    published = M.exec(command .. " --build-only", slashes(tree), 7200)
    evidence((published.stdout or "") .. (published.stderr or ""))
    if (published.code or 1) == 0 then
      -- THE SUMS TRAVEL TO THE SIGNER AND THE SIGNATURE COMES BACK: the one helper the `sign` step uses, so a
      -- signature made on another node is made by the same code, verified here against the same keys.
      local sums = dir .. "/out/SHA256SUMS"
      local signed, sign_problem = M.sign_on_node(signer.node, sums, sums .. ".sig", evidence)
      if not signed then
        return false, { error = "linux_channel_not_signed",
          detail = "the public channel for " .. short .. " was not published: its sums are not signed",
          observed = tostring((sign_problem or {}).error or "signer_unavailable") .. ": " .. tostring((sign_problem or {}).observed or ""),
          next = "the signer is the node the sign step used: check it is reachable (wa nodes), then wa release cut --run " .. tostring(run.id) .. " --resume" }
      end
      evidence("signed the channel's sums on " .. tostring(signer.node) .. "\n")
      evidence(command_line("upload the channel", command .. " --upload-only"))
      published = M.exec(command .. " --upload-only", slashes(tree), 7200)
      evidence((published.stdout or "") .. (published.stderr or ""))
    end
  end
  if (published.code or 1) ~= 0 then
    local name, line = channel_refusal(tostring(published.stderr or "") .. "\n" .. tostring(published.stdout or ""))
    return false, { error = "linux_channel_" .. tostring(name or "failed"),
      detail = "the public channel for " .. short .. " was not published; the node release for it is published and unaffected",
      observed = tostring(line or "the publisher answered nothing"),
      next = "the publisher's own words are in " .. M.evidence_path(run.id, "linux") .. "; fix what it names, then wa release cut --run " .. tostring(run.id) .. " --resume" }
  end

  -- THE ENTRY IS CHECKED BEFORE IT IS COMMITTED: the publisher says it published, and this reads the file it
  -- wrote. A file a fresh machine could not install from is never put on main - the push is a promise to every
  -- machine that has no node yet.
  local wrote = read(index)
  if not wrote then
    return false, { error = "linux_index_missing", observed = "the publisher answered done and " .. index .. " does not exist" }
  end
  local decoded, doc = pcall(json.decode, wrote)
  if not decoded or type(doc) ~= "table" then
    return false, { error = "linux_index_invalid", observed = index .. " is not JSON after the publisher wrote it" }
  end
  local written_found, written_missing = index_covers(doc, sha, targets)
  if #written_missing > 0 then
    return false, { error = "linux_index_incomplete",
      observed = "the index the publisher wrote names no " .. table.concat(written_missing, ", ") .. " entry for " .. short,
      next = "nothing was committed and main is untouched; the publisher's own words are in " .. M.evidence_path(run.id, "linux") }
  end
  -- THE COMMIT: exactly one path, staged and committed by name, so nothing else can travel with it.
  local added = git(run, index_tree, "add -- " .. quote(M.VERSION_FILE) .. " " .. quote(M.LINUX_INDEX), 300)
  evidence(command_line("stage the index", "git add -- " .. M.LINUX_INDEX .. " (in " .. index_tree .. ")"))
  evidence((added.stdout or "") .. (added.stderr or ""))
  if (added.code or 1) ~= 0 then
    return false, { error = "linux_index_stage_failed", observed = first_line(tostring(added.stderr or "") .. tostring(added.stdout or "")) }
  end
  local staged = git(run, index_tree, "diff --cached --name-only", 120)
  local staged_names = {}
  for line in tostring(staged.stdout or ""):gmatch("[^\r\n]+") do staged_names[#staged_names + 1] = trim(line) end
  local may_move = { [M.LINUX_INDEX] = true, [M.VERSION_FILE] = true }
  for _, name in ipairs(staged_names) do
    if not may_move[name] then
      return false, { error = "linux_index_path_not_allowed",
        observed = "the index commit would carry " .. name .. " as well as " .. M.LINUX_INDEX,
        next = "only the channel index may move in this commit; reset " .. index_tree .. " and resume" }
    end
  end
  local index_commit = rev(index_tree, "HEAD")
  if #staged_names > 0 then
    local message = "releases: " .. tag .. ", the public Linux channel for " .. short .. " (main's next cut is v" .. next_text .. ")"
    local committed = git(run, index_tree, "commit -q -m " .. quote(message) .. " -- " .. quote(M.VERSION_FILE) .. " " .. quote(M.LINUX_INDEX), 600)
    evidence(command_line("commit the index", "git commit -m 'releases: the public Linux channel " .. tag .. " for " .. short .. "' -- " .. M.LINUX_INDEX))
    evidence((committed.stdout or "") .. (committed.stderr or ""))
    if (committed.code or 1) ~= 0 then
      return false, { error = "linux_index_commit_failed", observed = first_line(tostring(committed.stderr or "") .. tostring(committed.stdout or "")) }
    end
    index_commit = rev(index_tree, "HEAD")
  end
  if index_commit == base then
    return false, { error = "linux_index_unchanged",
      observed = "the entry was published but origin/main's " .. M.LINUX_INDEX .. " is unchanged, so the channel would stay where it was" }
  end

  -- THE PUSH: fast-forward onto main, read back from the remote. Never a force push: main may have moved while
  -- this cut ran, and that is the operator's decision, not this step's.
  local origin = M.origin()
  local current = remote_tip(index_tree, origin, "refs/heads/main")
  if current and not is_ancestor(index_tree, current, index_commit) then
    return false, { error = "linux_index_not_fast_forward",
      observed = origin .. "/main is " .. current:sub(1, 12) .. " and the index commit " .. index_commit:sub(1, 12) .. " does not contain it",
      next = "main moved while this cut ran: git -C " .. slashes(tree) .. " fetch " .. origin .. " main, then wa release cut --run " .. tostring(run.id) .. " --resume (this step never force-pushes)" }
  end
  local pushed = git(run, index_tree, "push " .. quote(origin) .. " " .. quote(index_commit .. ":refs/heads/main"), 900)
  evidence(command_line("push the index", "git push " .. origin .. " " .. index_commit .. ":refs/heads/main"))
  evidence((pushed.stdout or "") .. (pushed.stderr or ""))
  if (pushed.code or 1) ~= 0 then
    local text = tostring(pushed.stderr or "") .. tostring(pushed.stdout or "")
    local credential = text:lower():find("permission") or text:lower():find("denied")
      or text:lower():find("authentication") or text:lower():find("could not read username")
    return false, { error = credential and "linux_index_push_needs_credentials" or "linux_index_push_failed",
      detail = "the channel entry exists in no remote, so a fresh machine still reads the old channel",
      observed = first_line(text ~= "" and text or "git push answered nothing"),
      next = "the channel index is a commit on main and needs the credential that pushes main: run this step where that credential is (a desktop shell with gh signed in on this node)" }
  end
  local readback = remote_tip(index_tree, origin, "refs/heads/main")
  if readback ~= index_commit then
    return false, { error = "linux_index_not_readback",
      observed = origin .. "/main is " .. tostring(readback or "absent") .. ", pushed " .. index_commit,
      next = "do not retry blindly: inspect " .. origin .. " first" }
  end

  local passed, verdict = verify_live()
  if not passed then return false, verdict end
  if rev(index_tree, "HEAD") == index_commit then
    git(run, tree, "worktree remove --force " .. quote(index_tree), 300)
  end
  run.journal.linux = { tag = tag, version = version_text, next_version = next_text, version_why = version_why,
    targets = targets, state = "published", index_commit = index_commit, index_base = base, entries = #targets,
    live = verdict }
  return true, { detail = string.format("published %s (%d target(s)) and %s on %s/main = %s: the released bytes say v%s, and main's next cut is v%s (%s); read back, %s",
    tag, #targets, M.LINUX_INDEX, origin, tostring(index_commit):sub(1, 12), version_text, next_text, tostring(version_why), tostring(verdict)) }
end

-- the ring, as configured: `--ring name:mode,...`, else `<config>/land/ring.json`, else M.RING.
function M.ring(options)
  if options.ring and #options.ring > 0 then return options.ring end
  local configured = json_file(M.root() .. "/ring.json")
  if configured and configured.nodes and #configured.nodes > 0 then
    local rows = {}
    for _, entry in ipairs(configured.nodes) do
      if type(entry) == "table" and entry.node then rows[#rows + 1] = { node = tostring(entry.node), mode = tostring(entry.mode or "tree") } end
    end
    if #rows > 0 then return rows end
  end
  return M.RING
end

-- deploy: every node, in order, stopping at the first one that is not installed. Each node is asked to
-- update ITSELF (`lua/core/remote_update.lua`): this machine only asks and reads back, and "queued" is
-- never reported as installed. `--rollback` runs the same ring in reverse and puts each node's kept pair
-- back (`scripts/rollback-node.sh` through that node's own Sentinel).
impl.deploy = function(run, options)
  local evidence = sink(run, "deploy")
  local ok, remote_update = pcall(dofile, "lua/core/remote_update.lua")
  if not ok or type(remote_update) ~= "table" then
    return false, { error = "remote_update_unavailable", observed = "lua/core/remote_update.lua could not be loaded" }
  end
  local ring = M.ring(options)
  -- AN UNKNOWN RING MODE IS REFUSED HERE, BY NAME, BEFORE ANY NODE IS ASKED (review r1 must 3, and the
  -- allow-list rule): a typo would otherwise reach the node, and a node that answers the default deploy to
  -- "relase" would move a release-installed machine as a tree. The four modes are the ones the node's own
  -- admit() accepts, plus rollback, which this ring never asks for - so a ring can never name a mode this
  -- coordinator and that node disagree about.
  local RING_MODES = { tree = true, binary = true, release = true }
  for _, entry in ipairs(ring or {}) do
    local mode_ = tostring((type(entry) == "table" and entry.mode) or "tree")
    if not RING_MODES[mode_] then
      local allowed = {}
      for name in pairs(RING_MODES) do allowed[#allowed + 1] = name end
      table.sort(allowed)
      return false, { error = "mode_unknown",
        observed = "the ring names node " .. tostring(entry.node or "?") .. " with mode " .. mode_ .. ", and this coordinator sends only " .. table.concat(allowed, ", "),
        detail = "node " .. tostring(entry.node or "?") .. ": mode_unknown (the ring names an install mode this landing does not send)",
        next = "fix the ring: --ring name:tree,name:binary,name:release" }
    end
  end
  local sha = run.journal.main_sha or run.journal.tree_commit
  local deadline = tonumber(options.deploy_timeout or (host.getenv and host.getenv("WA_LAND_DEPLOY_TIMEOUT")) or 900) or 900
  local poll = tonumber(options.deploy_poll or 5) or 5
  local function request_for(node, mode_, why)
    return { commit = (not options.rollback) and sha or nil, mode = mode_,
             reason = "wa land " .. run.id .. (why and (" " .. why) or ""), session = options.session }
  end
  -- One node: ask it to update itself, then read its own record until it settles or the deadline passes.
  -- "Queued" is not installed - the row carries the peer's state and the record id an operator (or
  -- `wa update <node> --status`) reads next.
  -- A NODE WITH AN OPERATOR PIN IS NEVER MOVED BY A RING SILENTLY. The node's own gate refuses it anyway
  -- (lua/core/remote_update.lua, lua/core/update.lua), but the coordinator knowing FIRST is what turns a
  -- half-deployed wave into one named refusal with the way out on it - and it is what keeps `--account`/ring
  -- order from being the only thing that decided. Unknown is not free: a pin store this module cannot read
  -- refuses the deploy by name instead of assuming the node is unpinned.
  local function pin_refusal(node)
    local loaded, pins = pcall(dofile, "lua/core/pins.lua")
    if not loaded or type(pins) ~= "table" or type(pins.active) ~= "function" then
      return { error = "pin_state_unknown",
        detail = "node " .. node .. " was not deployed: the pin store (lua/core/pins.lua) could not be read, so whether an operator pinned it is unknown",
        next = "check the tree this landing runs from; nothing was asked of " .. node }
    end
    local node_id = ""
    local ok_find, found = pcall(function() return dofile("lua/core/nodes.lua").find(node) end)
    if ok_find and type(found) == "table" then node_id = tostring(found.node_id or "") end
    local pinned = pins.active(node, node_id)
    if not pinned then return nil end
    local summary = ""
    if type(pins.summary_line) == "function" then summary = tostring(pins.summary_line(pinned) or "") end
    local hatch = ""
    if type(pins.escape_hatch) == "function" then hatch = tostring(pins.escape_hatch(node, pinned) or "") end
    return { error = "node_pinned",
      detail = "node " .. node .. " carries an active operator pin, so this ring did not deploy it" ..
        (summary ~= "" and (": " .. summary) or ""),
      observed = "pin " .. tostring(pinned.id or "?") .. (pinned.reason and (" - " .. tostring(pinned.reason)) or ""),
      next = hatch ~= "" and hatch or ("release the pin deliberately (`wa update " .. node .. " --unpin --reason <text>`), then `wa land --resume`") }
  end
  local function ask(node, mode_, why)
    local row = { node = node, mode = mode_, commit = sha, started_at = now() }
    evidence(string.format("deploy %s (%s) -> %s\n", node, mode_, tostring(sha)))
    if not options.rollback then
      local pinned = pin_refusal(node)
      if pinned then
        row.state, row.detail, row.seconds = "refused", pinned.detail, 0
        evidence(json.encode(row) .. "\n")
        row.failure = { error = pinned.error, detail = pinned.detail, observed = pinned.observed, next = pinned.next }
        return row
      end
    end
    local reply = remote_update.request(M.call(), node, request_for(node, mode_, why))
    row.state = tostring(reply and (reply.state or reply.status or reply.error) or "no_answer")
    row.record = reply and tostring(reply.record or "") or ""
    if not reply or reply.error then
      row.state = "refused"
      row.detail = reply and (tostring(reply.error) .. (reply.observed and (": " .. tostring(reply.observed)) or "")) or "no answer from the node"
      row.seconds = now() - row.started_at
      evidence(json.encode(row) .. "\n")
      row.failure = { error = "deploy_refused", detail = "node " .. node .. " (" .. mode_ .. "): " .. tostring(row.detail),
        observed = row.record ~= "" and ("record " .. row.record) or "",
        next = "inspect it: wa update " .. node .. " --status" .. (row.record ~= "" and (" --id " .. row.record) or "") }
      return row
    end
    return row
  end
  -- Read one node's record ONCE. Called from the wave loop below, so the nodes of a wave are read
  -- interleaved rather than one after the other - that is what makes the middle wave parallel: every request
  -- is issued first, and the settling is one loop over all of them.
  local function settle_once(row)
    local status = remote_update.status(M.call(), row.node, { id = row.record, session = options.session })
    local state = tostring(status and status.state or "unknown")
    row.state = state
    row.installed_commit = status and status.installed_commit or row.installed_commit
    row.verified = (status and status.verified == true) or false
    row.detail = status and status.detail or row.detail
    row.seconds = now() - (row.started_at or now())
    return state == "installed" or state == "failed" or state == "silent" or state == "unknown"
  end
  local function failure_for(row)
    if row.state == "installed" then return nil end
    return { error = "deploy_failed",
      detail = string.format("node %s (%s) is %s after %ss: %s", row.node, row.mode, row.state, tostring(row.seconds or "?"), tostring(row.detail or "")),
      observed = row.record ~= "" and ("record " .. row.record) or "",
      next = "read the node's own records (installed.txt, the sentinel's done/failed) and the evidence in " ..
        M.evidence_path(run.id, "deploy") .. "; then `wa land --resume` continues at this step" }
  end
  run.journal.deploy = run.journal.deploy or {}
  local function record(row)
    run.journal.deploy[#run.journal.deploy + 1] = row
    evidence(json.encode(row) .. "\n")
    save(run)
  end

  -- A rollback is one action per node in the REVERSE ring, serially: it puts back the pair the last install
  -- replaced, and there is nothing to gain from overlapping it with a second node's rollback.
  if options.rollback then
    for index = #ring, 1, -1 do
      local entry = ring[index]
      local row = ask(entry.node, "rollback", "rollback")
      local settle_at = now() + deadline
      while row.state ~= "refused" and not settle_once(row) and now() < settle_at do
        evidence(string.format("  %s: %s\n", entry.node, tostring(row.state)))
        M.sleep(poll)
      end
      record(row)
      if row.failure then return false, row.failure end
      if row.state ~= "installed" then return false, failure_for(row) end
    end
    return true, { detail = string.format("%d node(s) rolled back", #ring) }
  end

  -- What an earlier attempt of THIS run already installed at THIS commit is not installed again: a resume
  -- continues at the node that failed, which is the whole point of the journal.
  local settled_nodes = {}
  for _, row in ipairs(run.journal.deploy) do
    if row.state == "installed" and (row.commit == sha or row.installed_commit == sha) then settled_nodes[row.node] = true end
  end
  -- THE ORDER IS THE PLAN's: the canary alone, then the rest of the non-account nodes together, then the
  -- account node. Measured 13/11: four deploys in series cost 15-20 minutes of a ~40 minute round, and three
  -- of those four nodes have nothing to do with the account - so they wait on each other for nothing. The
  -- canary still goes first and alone (a broken commit breaks one node, not the fleet), and the account node
  -- is still last (it holds the WhatsApp account and the relay).
  local plan = M.deploy_waves(ring, options)
  run.journal.deploy_plan = { canary = plan.canary, account = plan.account, canary_defaulted = plan.canary_defaulted,
    waves = (function()
      local rows = {}
      for index, wave in ipairs(plan.waves) do
        local names = {}
        for _, entry in ipairs(wave) do names[#names + 1] = tostring(entry.node) end
        rows[index] = names
      end
      return rows
    end)() }
  local stopped = nil
  local deployed = 0
  for index, wave in ipairs(plan.waves) do
    if #wave == 0 then
      local _ = index
    elseif stopped then
      for _, entry in ipairs(wave) do
        record({ node = entry.node, mode = entry.mode or "tree", commit = sha, state = "not_attempted", seconds = 0,
          detail = "not deployed: the round stopped at " .. tostring(stopped.detail or "an earlier node") })
      end
    else
      local asked = {}
      for _, entry in ipairs(wave) do
        local name = tostring(entry.node)
        if settled_nodes[name] then
          evidence("deploy " .. name .. ": already installed at " .. tostring(sha) .. " in this run; not asked again\n")
          print("land: deploy: " .. name .. " already installed in this run")
          record({ node = name, mode = entry.mode or "tree", commit = sha, state = "installed", seconds = 0,
            detail = "already installed at this commit in this run" })
        elseif stopped then
          record({ node = name, mode = entry.mode or "tree", commit = sha, state = "not_attempted", seconds = 0,
            detail = "not deployed: the round stopped at " .. tostring(stopped.detail or "an earlier node") })
        else
          local row = ask(name, entry.mode or "tree", nil)
          row.wave = index
          asked[#asked + 1] = row
          if row.failure then stopped = row.failure end
        end
      end
      -- Settle what was asked, all of it in one loop: a wave with three nodes costs the slowest one, not the
      -- sum of three. A node whose request was refused does not enter this loop (it already has a failure).
      local pending = {}
      for _, row in ipairs(asked) do if not row.failure then pending[#pending + 1] = row end end
      local settle_at = now() + deadline
      while #pending > 0 and now() < settle_at do
        local still = {}
        for _, row in ipairs(pending) do
          if not settle_once(row) then still[#still + 1] = row end
        end
        pending = still
        if #pending > 0 then
          for _, row in ipairs(pending) do evidence(string.format("  %s: %s\n", row.node, tostring(row.state))) end
          M.sleep(poll)
        end
      end
      for _, row in ipairs(pending) do
        -- The deadline passed with the node still working: say `unknown`, never `installed`. Its own records
        -- are the truth and `wa update <node> --status` reads them.
        row.state = "unknown"
        row.detail = "not settled within " .. tostring(deadline) .. "s; read it with: wa update " .. row.node .. " --status"
        row.seconds = now() - (row.started_at or now())
      end
      for _, row in ipairs(asked) do
        record(row)
        deployed = deployed + 1
        if not stopped then stopped = row.failure or failure_for(row) end
      end
    end
  end
  if stopped then return false, stopped end
  return true, { detail = string.format("%d node(s) installed in %d wave(s) (canary %s first, account %s last)",
    deployed, #plan.waves, tostring(plan.canary or "-"), tostring(plan.account or "-")) }
end
-- report: one summary, written to a file and printed. It runs even when the machine stopped, because the
-- thing it is for is a human reading what happened.
-- ---------------------------------------------------------------- the landing's own steps
--
-- tests: THE BRANCH'S OWN TESTS, and nothing else (land-quick.sh's rule, which is what made a landing minutes
-- instead of a gate). Every `scripts/test-*.lua` the branch added or changed, each one ALONE with its own
-- scratch home and ledger, on the merged tree. A branch that changes Rust is SKIPPED BY NAME: a Lua row cannot
-- judge a new binary, and main-health judges that after the install - the skip is a recorded fact with its
-- reason, never a silent pass.
impl.tests = function(run, options)
  local evidence = sink(run, "tests")
  local tree = run.tree
  if not tree or trim(tree) == "" then
    return false, { error = "tests_without_tree", observed = "this run has no merged worktree to test" }
  end
  local paths, notes = M.changed_paths(run)
  for _, note in ipairs(notes) do evidence("WARN " .. note .. "\n") end
  if #notes > 0 then
    -- UNKNOWN IS NOT "NOTHING TO RUN". The paths this branch changes could not be read, so this step cannot say
    -- which of its tests to run: it names that in its own row instead of passing on an empty list.
    local detail = table.concat(notes, "; ") .. " - so the branch's own tests were NOT run here"
    evidence(detail .. "\n")
    return true, { state = "skipped", detail = detail }
  end
  local rust, rows, excluded = 0, {}, {}
  for _, path in ipairs(paths) do
    local spec = tostring(path)
    if spec:find("^rust/") then rust = rust + 1
    elseif spec:match("^scripts/test%-.+%.lua$") then rows[#rows + 1] = spec end
  end
  -- THE EXCLUSION IS READ FROM THE MERGED TREE, where the runner reads it: a row the fast path declares not run
  -- is not a row this step invents a verdict for.
  local excluded_text = read(slashes(tree) .. "/scripts/fast-path.exclude") or ""
  local keep = {}
  for _, row in ipairs(rows) do
    local listed = false
    for line in excluded_text:gmatch("[^\r\n]+") do
      local text = trim(line)
      if text ~= "" and text:sub(1, 1) ~= "#" and text == row then listed = true break end
    end
    if listed then excluded[#excluded + 1] = row else keep[#keep + 1] = row end
  end
  evidence(string.format("changed paths: %d (rust %d, scripts/test-*.lua %d, excluded %d)\n",
    #paths, rust, #keep, #excluded))
  if rust > 0 then
    local detail = string.format("the branch changes Rust (%d file(s)): its tests need the new binary, so they are " ..
      "judged by main-health after the install, not here", rust)
    evidence(detail .. "\n")
    return true, { state = "skipped", detail = detail }
  end
  if #keep == 0 then
    local detail = "the branch changed no scripts/test-*.lua of its own: nothing of its own to run"
    if #excluded > 0 then detail = detail .. " (" .. table.concat(excluded, ", ") .. " is not a fast-path row)" end
    evidence(detail .. "\n")
    return true, { state = "skipped", detail = detail }
  end
  -- How a row is run: the way the fast path runs one - its own HOME and ledger, the merged tree's Lua, the
  -- binary this node runs. `WA_LAND_TEST_BINARY` names another binary (a row can only judge THIS node).
  local binary = trim(options.test_binary or (host.getenv and host.getenv("WA_LAND_TEST_BINARY") or "")) 
  if binary == "" then binary = "wa" end
  local timeout = tonumber(options.test_timeout) or 300
  local green, red = 0, {}
  for _, row in ipairs(keep) do
    local scratch = M.run_dir(run.id) .. "/tests/" .. (row:gsub("[^%w]", "-"))
    M.exec("rm -rf " .. quote(scratch) .. " && mkdir -p " .. quote(scratch .. "/h/wahome"), tree, 60)
    local command = table.concat({
      "WASM_AGENT_LUA_ROOT=" .. quote(slashes(tree)),
      "WA_SCRIPT=" .. quote(row),
      "HOME=" .. quote(scratch .. "/h"),
      "WASM_AGENT_HOME=" .. quote(scratch .. "/h/wahome"),
      "TMPDIR=" .. quote(scratch),
      "timeout " .. tostring(math.floor(timeout)),
      quote(binary), "--db", quote(scratch .. "/t.db"),
    }, " ")
    evidence(command .. "\n")
    local result = M.exec(command, tree, timeout + 60)
    local output = tostring(result.stdout or "") .. tostring(result.stderr or "")
    evidence(output .. "\n")
    if (result.code or 1) == 0 then
      green = green + 1
    else
      red[#red + 1] = row .. " (" .. tostring(result.code) .. ": " .. last_line(output) .. ")"
    end
  end
  local detail = string.format("the branch's own tests: %d green", green)
  if #excluded > 0 then detail = detail .. ", " .. #excluded .. " not a fast-path row" end
  if #red > 0 then
    return false, { error = "own_tests_red", detail = "the branch's own tests are red:",
      observed = table.concat(red, "; "), next = "fix them on the branch (or record the row as not a fast-path row for a real reason), then land again" }
  end
  return true, { detail = detail }
end

-- WHERE THE INSTALL RECORD IS. `installed.txt` is what a deploy writes and what `wa update --check` reads, and
-- FACTORY.md rule 4 says exactly why the version string will not do: `wa --version` names the binary, never the
-- tree the node was last installed from.
function M.install_dir()
  if M.install_dir_override and M.install_dir_override ~= "" then return slashes(M.install_dir_override) end
  local ok, update = pcall(dofile, "lua/core/update.lua")
  if ok and type(update) == "table" and type(update.install_dir) == "function" then
    return slashes(update.install_dir())
  end
  return nil
end

function M.install_record()
  local dir = M.install_dir()
  if not dir then return nil, "this node cannot name its install directory" end
  local text = read(dir .. "/installed.txt")
  if not text then return nil, "no installed.txt in " .. dir end
  local record = {}
  for line in tostring(text):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then record[trim(key)] = trim(value) end
  end
  return record
end

-- Does this landing change what a node RUNS? The rule is land-quick.sh's, and it is a list of the paths a node
-- loads: a scripts/docs-only branch deploys nothing, because a deploy pauses every worker for bytes no node
-- reads.
function M.landing_runs(paths)
  local runs = {}
  for _, path in ipairs(paths or {}) do
    local spec = tostring(path)
    if spec:find("^lua/") or spec:find("^rust/") or spec:find("^ui/") or spec:find("^web/") or spec:find("^assets/") then
      runs[#runs + 1] = spec
    end
  end
  return runs
end

-- install: THE LANDING'S SECOND HALF, and the reason a landing is complete only when the record says so.
--   1. the checkout is fast-forwarded to the landed tip (the deploy builds what the runtime worktree holds);
--   2. the deploy is REQUESTED through this node's sentinel (the supported door, never a hand-run script);
--   3. `installed.txt` is READ BACK until it names the landed commit - the record, not a version string;
--   4. the Lua the node runs is compared with the landed tree's, when this install carries a lua-core tree.
-- A step that cannot prove (3) is not installed: it stops by name, with what the record does say.
impl.install = function(run, options)
  local evidence = sink(run, "install")
  local repo = M.repo()
  local sha = tostring(run.journal.main_sha or run.journal.tree_commit or "")
  if not repo or trim(repo) == "" then
    return false, { error = "install_no_repository", observed = "this node has no runtime tree",
      next = "run the landing on a machine with a checkout, or set WA_LAND_REPO=<dir>" }
  end
  if sha == "" then
    return false, { error = "install_without_tip", observed = "the run has no landed tip in its journal",
      next = "nothing was installed: `wa land --resume` lands the tip first" }
  end
  -- (1) the checkout. `merge --ff-only` only: a checkout that cannot take the tip is a refusal, never a reset.
  local command = "git -C " .. quote(slashes(repo)) .. " fetch --quiet origin main && git -C " .. quote(slashes(repo)) ..
    " merge --ff-only " .. quote(sha)
  evidence(command_line("checkout", command))
  local ff = M.exec(command, slashes(repo), 600)
  evidence((ff.stdout or "") .. (ff.stderr or ""))
  if (ff.code or 1) ~= 0 then
    return false, { error = "checkout_not_fast_forwarded",
      observed = first_line(tostring(ff.stderr or "") ~= "" and ff.stderr or ff.stdout),
      next = "make " .. slashes(repo) .. " clean and on main, then `wa land --resume` (the checkout is never reset by a landing)" }
  end
  local paths = M.changed_paths(run)
  local runs = M.landing_runs(paths)
  if #runs == 0 then
    local detail = "scripts/docs only (no lua/, rust/, ui/, web/ or assets/ path): the checkout is at " ..
      sha:sub(1, 12) .. " and no deploy was asked for"
    evidence(detail .. "\n")
    return true, { state = "skipped", detail = detail }
  end
  -- (2) the deploy request: the sentinel performs it, and its own queue is what it answers about.
  local reason = "wa land " .. tostring(run.id) .. ": install " .. sha:sub(1, 12)
  local request_command = "wa-sentinel request deploy --reason " .. quote(reason)
  evidence(command_line("deploy request", request_command))
  local request = M.exec(request_command, slashes(repo), 300)
  evidence((request.stdout or "") .. (request.stderr or ""))
  if (request.code or 1) ~= 0 then
    return false, { error = "deploy_not_requested",
      observed = first_line(tostring(request.stderr or "") ~= "" and request.stderr or request.stdout),
      next = "check the sentinel is running (wa-sentinel status) on this node, then `wa land --resume`" }
  end
  -- (3) the wait, on the RECORD.
  local deadline = tonumber(options.install_timeout) or
    tonumber(host.getenv and host.getenv("WA_LAND_INSTALL_TIMEOUT") or "") or 2400
  local started = now()
  local record, verdict = nil, nil
  while true do
    record, verdict = M.install_record()
    if record then
      local installed = tostring(record.commit or "")
      -- `installed.txt` records the SHORT form on a build and the full id on a prebuilt install (remote_update
      -- reads both), so the comparison is by prefix, in whichever direction the record was written.
      if installed ~= "" and (sha:sub(1, #installed) == installed or installed:sub(1, #sha) == sha) then break end
    end
    record = nil
    if (now() - started) >= deadline then break end
    M.sleep(math.min(10, math.max(1, deadline - (now() - started))))
  end
  if not record then
    local said, where = M.install_record()
    local detail = "the install record does not name " .. sha:sub(1, 12) .. " after " .. tostring(now() - started) .. "s"
    local observed = where or (said and ("installed.txt says commit=" .. tostring(said.commit)) or "no record")
    M.emit(run, "install-failed", "red", detail .. " (" .. tostring(observed) .. ")")
    return false, { error = "install_not_recorded", detail = detail, observed = tostring(observed),
      next = "read the sentinel's own queue and records (wa-sentinel status), then `wa land --resume`: the install " ..
        "step is the only one that proves the node runs the landing" }
  end
  local detail = string.format("installed.txt names %s, %ds after the request", tostring(record.commit),
    math.floor(now() - started))
  evidence(detail .. "\n")
  -- (4) the Lua this node runs is main's. A tree-only install writes `lua-core`; a release install keeps its own
  -- tree, and then there is nothing to compare - which is SAID, never counted as a pass.
  local installed_lua = M.install_dir() .. "/lua-core/lua/core"
  local probe = M.exec("test -d " .. quote(installed_lua) .. " && echo yes || echo no", slashes(repo), 60)
  if trim(tostring(probe.stdout or "")) == "yes" then
    local diff = M.exec("diff -rq " .. quote(installed_lua) .. " " .. quote(slashes(repo) .. "/lua/core"), slashes(repo), 300)
    evidence((diff.stdout or "") .. (diff.stderr or ""))
    if (diff.code or 1) ~= 0 then
      local observed = "the installed lua/core differs from main's: " ..
        first_line(tostring(diff.stdout or "") ~= "" and diff.stdout or diff.stderr)
      M.emit(run, "install-failed", "red", observed)
      return false, { error = "install_lua_mismatch", detail = "the node was installed but not with this landing's Lua",
        observed = observed, next = "inspect " .. installed_lua .. " and the deploy's own log, then `wa land --resume`" }
    end
    detail = detail .. "; the installed lua/core equals main's"
  else
    detail = detail .. "; this install carries no lua-core tree (a release install keeps its own), so the Lua comparison was not made"
  end
  return true, { detail = detail }
end

-- THE PROGRAM AN OPERATION RUNS: this process's own binary, at a path that EXISTS NOW.
--
-- `runtime_info().binary_path` is the host's `current_exe()`, and on Linux a binary that an install replaced
-- answers `<path> (deleted)`: the path, plus a marker saying that the file this process runs is no longer the
-- file at that path (measured 23/11 with a copy of this binary - rename a new file over it, and
-- `current_exe()` answers `/tmp/.../wa (deleted)`). The operation manager refuses a program that is not a file
-- (rust/wa-capabilities/src/operations.rs, `program_not_found`), so EVERY landing that installed stopped at
-- `health`: the ledger's row of 22/11T12:48:09Z is `land main-health red detail=program_not_found`.
--
-- The install writes the landed binary AT this path, so the path without the marker is the binary to run -
-- the one the landing just installed, which is the binary main must be judged with. The path is checked with
-- the same rule the operation manager applies (a regular file), so a refusal can say what to do; a path with
-- nothing at it is refused BY NAME, never satisfied by whatever `wa` is found on PATH, because a health run
-- started from a binary nobody chose judges main with it.
local function running_program()
  local provided, raw = pcall(host.runtime_info)
  local runtime = {}
  if provided and type(raw) == "string" then pcall(function() runtime = json.decode(raw) or {} end) end
  local path = trim(tostring(runtime.binary_path or ""))
  local replaced = " (deleted)"
  local was_replaced = path:sub(-#replaced) == replaced
  if was_replaced then path = path:sub(1, #path - #replaced) end
  if path == "" then return nil, "this node cannot name its own binary (runtime_info)" end
  local probe = M.exec("test -f " .. quote(path) .. " && echo yes || echo no", "/", 60)
  if trim(tostring(probe and probe.stdout or "")) ~= "yes" then
    return nil, "the binary this process runs is not a file at " .. path ..
      (was_replaced and " (this process's binary was replaced, and nothing is installed at that path)" or "")
  end
  return path
end

-- START ONE SUPERVISED OPERATION. The seam is this function, so a test runs a health step without a node; the
-- default is the node's own operation manager, which is the only supported way to start long work.
function M.start_operation(spec)
  if type(host.operation) ~= "function" then return nil, "this node has no operation manager" end
  local program, program_problem = running_program()
  if not program then return nil, program_problem end
  local argv = {}
  local db = trim(host.getenv and host.getenv("WASM_AGENT_DB") or "")
  if db ~= "" then argv = { "--db", db } end
  for _, word in ipairs(spec.args or {}) do argv[#argv + 1] = tostring(word) end
  local launched, receipt = pcall(host.operation, "start", json.encode({ program = program, args = argv,
    timeout_seconds = tonumber(spec.timeout_seconds) or 3600, kind = "command",
    owner = tostring(spec.owner or "land-health"), background = true }))
  if not launched then return nil, "the operation manager refused: " .. tostring(receipt) end
  local answer = type(receipt) == "string" and json.decode(receipt) or receipt
  if type(answer) ~= "table" or not answer.operation_id then
    return nil, tostring(type(answer) == "table" and (answer.error or "no operation id") or receipt)
  end
  return tostring(answer.operation_id)
end

-- health: main's health, measured ONCE after a landing that can have moved it - lua/ or rust/ - and recorded
-- as an event. It runs as a SUPERVISED OPERATION and not inside this step: `scripts/main-health.sh` runs the
-- whole fast path (~10 minutes, holding the suite lock), and land-quick.sh's own comment says why the landing
-- must not wait for it. The operation's command is `wa land health-run`, which writes the verdict itself.
impl.health = function(run, options)
  local evidence = sink(run, "health")
  local paths = M.changed_paths(run)
  local touches = 0
  for _, path in ipairs(paths) do
    local spec = tostring(path)
    if spec:find("^lua/") or spec:find("^rust/") then touches = touches + 1 end
  end
  if touches == 0 then
    return true, { state = "skipped", detail = "the landing changed no lua/ or rust/ file, so main's health cannot have moved" }
  end
  if options.no_health then
    return true, { state = "skipped", detail = "skipped: --no-health (main is NOT measured for this landing)" }
  end
  local repo = M.repo()
  local sha = tostring(run.journal.main_sha or run.journal.tree_commit or "")
  if not repo or trim(repo) == "" or sha == "" then
    return false, { error = "health_without_target", observed = "no runtime tree or no landed tip to measure" }
  end
  local args = { "land", "health-run", "--repo", slashes(repo), "--sha", sha,
    "--mission", M.mission_name(run), "--branch", M.branches_text(run), "--source", "wa land " .. tostring(run.id) }
  local id, why_not = M.start_operation({ owner = "land-health", args = args, timeout_seconds = 5400 })
  evidence("health-run args: " .. table.concat(args, " ") .. "\n")
  if not id then
    local observed = tostring(why_not)
    return false, { error = "main_health_not_started",
      detail = "main's health was NOT measured: the health run was not started (" .. observed .. ")",
      observed = observed,
      next = "measure it by hand: bash " .. slashes(repo) .. "/scripts/main-health.sh --repo " .. slashes(repo) ..
        " (its verdict is a `wa land health-run` away), or run `wa land health-run --repo " .. slashes(repo) .. "`" }
  end
  local detail = "started as operation " .. id .. ": the whole fast path on main's tip at nice 19 under the " ..
    "suite lock; its verdict arrives as the event land.main-health"
  evidence(detail .. "\n")
  return true, { detail = detail }
end

-- `wa land health-run`: measure main's health ONCE here and write the verdict as an event. This is the command
-- the health step starts as its own operation, and it is also what a person runs by hand; both write the same
-- row, so the ledger says the same thing whoever measured it.
function M.health_run(options)
  options = type(options) == "table" and options or {}
  local repo = trim(options.repo) ~= "" and slashes(options.repo) or M.repo()
  if not repo or repo == "" then
    return 2, { error = "no_repository", observed = "no runtime tree and no --repo" }
  end
  local script = repo .. "/scripts/main-health.sh"
  if not read(script) then
    return 2, { error = "main_health_missing", observed = script .. " does not exist in this tree" }
  end
  local command = "bash " .. quote(script) .. " --repo " .. quote(repo)
  local result = M.exec(command, repo, tonumber(options.timeout) or 5400)
  local code = tonumber(result.code) or 1
  -- 0 green, 1 red, anything else is a run that could not judge - and an unknown verdict is never written green.
  local verdict = code == 0 and "green" or (code == 1 and "red" or "refused")
  local said = last_line(tostring(result.stdout or "") .. "\n" .. tostring(result.stderr or ""))
  local detail = verdict == "green" and "the whole fast path is green on main's tip"
    or (verdict == "red" and ("main is red: " .. said) or ("main-health refused to judge: " .. said))
  -- `data.measured` IS WHAT MAKES THIS ROW A VERDICT about main: a landing's health STEP writes a row with the
  -- same step name and its own outcome (started, or not started), which is a fact about the step and not about
  -- main. M.main_red reads only rows carrying this marker, so a health step that never started can no longer
  -- red a green main (22/11: `program_not_found` refused the next landing at merge).
  local fields = { kind = "land", step = "main-health", result = verdict, sha = tostring(options.sha or ""),
    mission = tostring(options.mission or ""), branch = tostring(options.branch or ""), detail = detail,
    data = { measured = "scripts/main-health.sh" },
    source = tostring(options.source or "wa land health-run") }
  local called, row = pcall(function() return dofile("lua/core/event_ledger.lua").record(fields) end)
  if not called or type(row) ~= "table" or row.error then
    print("land: health-run: the verdict could not be recorded: " ..
      tostring(type(row) == "table" and row.error or row))
    -- REFUSED, not red and not green: the measurement happened and the record did not, so nothing here says
    -- what main is (an unrecorded verdict is exactly the silent red FACTORY.md rule 8 is about).
    return 2, { verdict = verdict, error = "verdict_not_recorded" }
  end
  print(string.format("land: health-run: main is %s (event %s)", verdict, tostring(row.id)))
  return code, { verdict = verdict, row = row }
end

impl.report = function(run, options)
  -- The reviews were started by the `review` step and joined here: this is the one step that runs after every
  -- other and also after a stop, so it is where findings become evidence. It cannot fail the landing (`pcall`),
  -- and a join that throws is written down rather than swallowed.
  local joined, problem = pcall(M.review_collect, run)
  if not joined then
    run.journal.review_error = tostring(problem)
    print("land: report: the reviews could not be joined: " .. tostring(problem))
  end
  local text = M.report_text(run.journal)
  write(M.report_path(run.id), text)
  print("")
  print(text)
  return true, { detail = M.report_path(run.id) }
end

M.impl = impl

-- ---------------------------------------------------------------- the journal, as a report

function M.report_text(journal)
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  local result = tostring(journal.result or "in_progress")
  add("# wa land " .. tostring(journal.run))
  add("")
  add(string.format("result: **%s**%s", result, journal.stopped_at and (" at `" .. journal.stopped_at .. "`") or ""))
  if journal.stop_detail then add("") add("why: " .. journal.stop_detail) end
  add("")
  add("| field | value |")
  add("| --- | --- |")
  if journal.base then add("| base | `" .. journal.base:sub(1, 12) .. "` (" .. tostring(journal.base_ref) .. ") |") end
  if journal.land_branch then add("| land branch | `" .. journal.land_branch .. "` |") end
  if journal.tree_commit then add("| landed tip | `" .. journal.tree_commit .. "` |") end
  if journal.pushed_sha then add("| pushed | `" .. journal.pushed_sha:sub(1, 12) .. "` to " .. tostring(journal.incoming) .. " |") end
  if journal.main_sha then add("| main | `" .. journal.main_sha:sub(1, 12) .. "` on " .. tostring(journal.origin) .. " |") end
  if journal.artifacts then
    add("| release tag | `node-" .. tostring(journal.artifacts.commit or ""):sub(1, 12) .. "` |")
    if journal.artifacts.dir then
      add("| release set | `" .. tostring(journal.artifacts.dir) .. "` (" .. #(journal.artifacts.triples or {}) .. " target(s)) |")
    end
    if journal.artifacts.signed then
      add("| signature | key `" .. tostring(journal.artifacts.key_id) .. "`, signed on " ..
        tostring(journal.artifacts.signer) .. " |")
    end
    if journal.artifacts.ref then
      add("| artifacts | `" .. tostring(journal.artifacts.ref) .. "` `" ..
        tostring(journal.artifacts.artifacts_commit or ""):sub(1, 12) .. "` (" ..
        tostring(journal.artifacts.files or 0) .. " file(s)) |")
    end
  end
  if journal.publish then add("| publish | " .. tostring(journal.publish.state) .. " (`" .. tostring(journal.publish.tag) .. "`" ..
    (journal.publish.signed and ", signed" or ", unsigned") .. ") |") end
  if journal.linux then
    add("| linux channel | " .. tostring(journal.linux.state) .. " (`" .. tostring(journal.linux.tag) .. "`, " ..
      tostring(#(journal.linux.targets or {})) .. " target(s)) |")
    if journal.linux.index_commit then
      add("| channel index | `" .. M.LINUX_INDEX .. "` `" .. tostring(journal.linux.index_commit):sub(1, 12) .. "` on main |")
    end
  end
  if journal.gate_weight then add("| gate weight | `" .. tostring(journal.gate_weight) .. "` |") end
  add("")
  add("## branches")
  add("")
  if #(journal.branches or {}) == 0 then add("(none collected)") else
    add("| branch | tip |")
    add("| --- | --- |")
    for _, branch in ipairs(journal.branches) do
      add(string.format("| `%s` | `%s` |", tostring(branch.name), tostring(branch.sha):sub(1, 12)))
    end
  end
  add("")
  add("## steps")
  add("")
  add("| step | state | seconds | detail |")
  add("| --- | --- | --- | --- |")
  for _, name in ipairs(M.steps_for(journal)) do
    local step = (journal.steps or {})[name] or { state = "pending" }
    local seconds = step.started_at and step.finished_at and (step.finished_at - step.started_at) or nil
    add(string.format("| %s | %s | %s | %s |", name, tostring(step.state), seconds and tostring(seconds) or "-",
      tostring(step.detail or ""):gsub("|", "/")))
  end
  if #(journal.deploy or {}) > 0 then
    add("")
    add("## nodes")
    add("")
    if journal.deploy_plan then
      local waves = journal.deploy_plan.waves or {}
      local parts = {}
      for index, names in ipairs(waves) do
        parts[#parts + 1] = (index == 1 and "canary " or (index == #waves and "account " or "parallel ")) .. table.concat(names, "+")
      end
      add("deploy order: " .. table.concat(parts, " -> ") .. (journal.deploy_plan.canary_defaulted and " (the canary defaulted: the ring names no " .. tostring(journal.deploy_plan.canary) .. ")" or ""))
      add("")
    end
    add("| node | mode | wave | state | seconds | detail |")
    add("| --- | --- | --- | --- | --- | --- |")
    for _, row in ipairs(journal.deploy) do
      add(string.format("| %s | %s | %s | %s | %s | %s |", tostring(row.node), tostring(row.mode), tostring(row.wave or "-"),
        tostring(row.state), tostring(row.seconds or "-"), tostring(row.detail or ""):gsub("|", "/"):sub(1, 160)))
    end
  end
  -- WHAT THE ROUND COST, and what a round of this shape has cost before. A number nobody compares is a number
  -- nobody can improve - the point of the plan (and of this table) is that "~40 minutes every round" became a
  -- measurement per round, per path, against the journal's own history.
  local total = 0
  for _, name in ipairs(M.steps_for(journal)) do
    local step = (journal.steps or {})[name]
    if step and tonumber(step.seconds) then total = total + tonumber(step.seconds) end
  end
  add("")
  add("## cost")
  add("")
  add("| what | value |")
  add("| --- | --- |")
  add("| path | `" .. tostring((journal.plan or {}).category or "not planned") .. "` |")
  add("| total | " .. M.duration_text(total) .. " (" .. tostring(total) .. "s) |")
  if journal.plan and tonumber(journal.plan.expected_seconds) then
    local expected = tonumber(journal.plan.expected_seconds)
    add(string.format("| expected | %s (%s), actual %s |", M.duration_text(expected),
      tostring(journal.plan.expected_from or "?"), M.duration_text(total - expected) .. " off"))
  end
  local average = M.journal_average()
  if average then
    add(string.format("| journal average | %s over %d finished run(s) |", M.duration_text(average.average), average.runs))
    if total > 0 then
      local delta = total - average.average
      add(string.format("| this round | %s the average |", (delta >= 0 and "+" or "-") .. M.duration_text(math.abs(delta))))
    end
  else
    add("| journal average | no finished run in the journal yet |")
  end
  if #(journal.gate or {}) > 0 then
    add("")
    add("## gate")
    add("")
    add("| check | result | seconds | tests |")
    add("| --- | --- | --- | --- |")
    for _, row in ipairs(journal.gate) do
      local state = row.ok and "ok" or (row.retry and row.retry.ok and "FLAKY UNDER LOAD" or "failed")
      add(string.format("| %s | %s | %s | %s |", tostring(row.name), state, tostring(row.seconds or "-"), tostring(row.tests or "-")))
    end
  end
  -- The reviewer's findings, as evidence about the branch: each row names the review it came from, so the
  -- operator can mark it (`wa eval reviewer mark <id>#<n>`) and the store keeps the history. A review that could
  -- not run says so in its own column - never an empty one that reads as "nothing found".
  if #(journal.review or {}) > 0 then
    add("")
    add("## review (findings are reported, never blocking)")
    add("")
    add("| branch | review | findings | state |")
    add("| --- | --- | --- | --- |")
    for _, row in ipairs(journal.review) do
      add(string.format("| `%s` | %s | %s | %s |", tostring(row.branch), tostring(row.review_id or "-"),
        tostring(row.findings or "-"), tostring(row.unavailable or row.state or "-"):gsub("|", "/")))
    end
    for _, row in ipairs(journal.review) do
      if row.answer and row.answer ~= "" then
        add("")
        add(string.format("### %s - %s finding(s) (%s)", tostring(row.branch), tostring(row.findings or 0),
          tostring(row.review_id or "review")))
        add("")
        add((tostring(row.answer):gsub("\r", "")))
      end
    end
  end
  if journal.review_error then
    add("")
    add("the reviews could not be joined: " .. tostring(journal.review_error))
  end
  if #(journal.todos or {}) > 0 then
    add("")
    add("## TODO (recorded, never silently green)")
    add("")
    for _, todo in ipairs(journal.todos) do
      add(string.format("- **%s**: %s (looks for `%s`)", tostring(todo.item), tostring(todo.state), tostring(todo.looks_for)))
      add("  - enable: " .. tostring(todo.enable))
      add("  - test: " .. tostring(todo.test))
    end
  end
  add("")
  add("journal: `" .. M.journal_path(journal.run) .. "`")
  return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------- running the machine

local function open_run(options)
  local id = options.run
  if not id then
    id = tostring(options.run_prefix or "land") .. "-" .. os.date("!%Y%m%dT%H%M%SZ", now()) .. "-" .. tostring(host.uuid()):sub(1, 8)
  end
  local journal = json_file(M.journal_path(id))
  local fresh = journal == nil
  if fresh then journal = blank_journal(id) end
  return { id = tostring(id), journal = journal, fresh = fresh,
           tree = journal.tree, land_branch = journal.land_branch }
end

-- The newest run that is not finished: what `--resume` continues. A stopped run is a run to continue, and so
-- is one that never got as far as a result.
local function newest_unfinished(release)
  for _, path in ipairs(journals_by_newest(20)) do
    local journal = json_file(path)
    -- TWO LOOPS, TWO QUEUES: a bare `wa land --resume` never continues a release run and a bare
    -- `wa release cut --resume` never continues a landing. Either is resumable by name (--run <id>).
    local is_release = journal and (journal.release == true or (type(journal.start) == "table" and journal.start.release == true))
    if journal and (is_release and true or false) ~= (release and true or false) then journal = nil end
    -- A PREFLIGHT IS NOT AN UNFINISHED LANDING. A run that stopped after --until <step> answered the
    -- question it was asked and then stopped ON PURPOSE, and --until is deliberately not inherited by a
    -- resume - so continuing it would push, fast-forward main, build a release, publish it and deploy, for
    -- a branch nobody decided to land (review r1, BLOCKER 1). It stays resumable BY NAME: --run <id>
    -- --resume is refused by M.run unless the invocation names its own boundary again.
    if journal and journal.run and journal.result ~= "done" and journal.result ~= "stopped_at_until" then
      return tostring(journal.run)
    end
  end
  return nil
end

local function finish_step(run, name, ok, result)
  local step = step_of(run.journal, name)
  step.finished_at = now()
  step.seconds = (step.started_at and (step.finished_at - step.started_at)) or nil
  if ok then
    step.state = result and result.state or "done"
    step.detail = result and result.detail or nil
    return true, nil
  end
  step.state = (result and result.state) or "failed"
  step.error = result and result.error or "failed"
  step.detail = result and (result.detail or result.observed) or nil
  step.observed = result and result.observed or nil
  step.next = result and result.next or nil
  step.evidence = M.evidence_path(run.id, name)
  return false, (result and (result.state == "flaky" and result.detail or nil)) or nil
end

function M.run_step(run, name, options)
  local step = step_of(run.journal, name)
  step.state = "running"
  step.started_at = now()
  step.finished_at = nil
  step.error = nil
  save(run)
  print("land: " .. name .. " ...")
  local called, outcome, payload = pcall(M.impl[name], run, options)
  if not called then
    outcome, payload = false, { error = "step_crashed", observed = tostring(outcome) }
  end
  local ok, result = outcome, payload
  local passed, _ = finish_step(run, name, ok, result)
  save(run)
  -- THE FACT OF THE STEP, written after it settled and before it is printed: the journal says what still has to
  -- happen, this row says what happened, and a subscriber reads the same sentence the terminal does.
  if run.journal.landing then
    M.emit(run, M.EVENT_STEP[name] or name, M.EVENT_RESULT[step.state] or (passed and "green" or "red"),
      tostring(step.detail or step.error or ""))
    if passed and M.EVENT_FOLLOW[name] then
      M.emit(run, M.EVENT_FOLLOW[name], "green", tostring(step.detail or ""))
    end
  end
  if passed then
    print("land: " .. name .. ": " .. tostring(step.state) .. (step.detail and (" - " .. tostring(step.detail):gsub("\n", " ")) or ""))
  else
    print("land: " .. name .. ": STOPPED (" .. tostring(step.state) .. "): " .. tostring(step.detail or step.error or ""))
    if step.evidence then print("land: evidence: " .. step.evidence) end
    if step.next then print("land: next: " .. step.next) end
  end
  return passed
end

-- THE START OPTIONS ARE PART OF THE RUN, not of the invocation that happened to begin it. A resume is the
-- same round continued (often on another day, by another operator, after a stop), so a ring, `--full`,
-- `--no-deploy`, `--account` or `--signer` given at the start has to still hold at the resume - measured
-- 18/11: a resumed round silently took the DEFAULT ring and deployed a node the operator had excluded, and
-- a `--full` start came back narrowed because the flag was not in the journal at all.
--
-- A flag given ON the resume wins: it is the more recent instruction. Everything not given falls back to the
-- journal. `ring` is stored RESOLVED (node and mode), because the answer to `--ring` is what the round uses.
-- `landing`, `gate`, `fix_main` and `no_health` travel with the round for the same reason the ring does: a
-- resumed landing is the SAME landing (FACTORY.md rule 10), and a resume must not quietly become the full
-- pipeline, or lose the `--fix-main` that made it legal.
local START_KEYS = { "full", "no_deploy", "account", "signer", "canary", "session", "release",
  "landing", "gate", "fix_main", "no_health" }

local function remember_start(run, options)
  local start = run.journal.start or {}
  for _, key in ipairs(START_KEYS) do
    local value = options[key]
    if value ~= nil and value ~= "" then start[key] = value end
  end
  if options.ring and #options.ring > 0 then
    local rows = {}
    for _, entry in ipairs(options.ring) do rows[#rows + 1] = { node = tostring(entry.node), mode = tostring(entry.mode or "tree") } end
    start.ring = rows
  end
  if options.branches and #options.branches > 0 then start.branches = options.branches end
  run.journal.start = start
  save(run)
  return start
end

local function apply_start(run, options)
  local start = run.journal.start
  if type(start) ~= "table" then return options end
  for _, key in ipairs(START_KEYS) do
    if options[key] == nil and start[key] ~= nil then options[key] = start[key] end
  end
  if (not options.ring or #options.ring == 0) and type(start.ring) == "table" and #start.ring > 0 then
    local rows = {}
    for _, entry in ipairs(start.ring) do
      if type(entry) == "table" and entry.node then rows[#rows + 1] = { node = tostring(entry.node), mode = tostring(entry.mode or "tree") } end
    end
    if #rows > 0 then options.ring = rows end
  end
  if (not options.branches or #options.branches == 0) and type(start.branches) == "table" and #start.branches > 0 then
    options.branches = start.branches
  end
  return options
end

function M.run(options)
  options = type(options) == "table" and options or {}
  if options.release and not options.run then options.run_prefix = options.run_prefix or "release" end
  if options.resume and not options.run then
    options.run = newest_unfinished(options.release)
    if not options.run then
      print((options.release and "release" or "land") .. ": nothing to resume: no unfinished " ..
        (options.release and "release " or "") .. "run under " .. M.root())
      return 1
    end
  end
  local run = open_run(options)
  if run.fresh and not options.run then
    run.journal.branches = {}
  else
    -- A resume continues the SAME round: the options it started with come back unless this invocation names
    -- its own (see remember_start/apply_start).
    options = apply_start(run, options)
  end
  -- WHAT KIND OF ROUND THIS IS, recorded before anything reads the journal (the dry run's plan, the step order,
  -- the skip a resumed run keeps): a landing is one from its first line, so nothing downstream has to guess
  -- from the flags of whichever invocation is running.
  if options.landing and not options.release then
    run.journal.landing = true
    run.journal.gate_landing = options.gate and true or nil
  end
  -- A DRY RUN WRITES NOTHING, so the start options are recorded only after this return: a plan that wrote a
  -- journal entry would change the thing it says it does not touch.
  if options.release and (options.branches or options.ready or options.rollback) then
    print("release: refused(release_takes_no_branch): a release is cut from main's tip and lands nothing")
    print("release: next: wa land --branches <branch> --until main   (land it), then wa release cut")
    return 2
  end
  if not run.fresh and options.release and type(run.journal.start) == "table" and run.journal.start.release ~= true
     and run.journal.release ~= true then
    print("release: refused(release_resume_of_landing): run " .. run.id .. " is a landing, not a release")
    print("release: next: wa land --run " .. run.id .. " --resume   (or a fresh release: wa release cut)")
    return 2
  end
  if options.dry_run and options.release then return M.release_dry_run(run, options) end
  if options.dry_run then return M.dry_run(run, options) end
  if options.release then
    -- BEFORE THE JOURNAL, THE FETCH AND THE BUILD: a precondition that fails refuses here, by name, with
    -- the command that fixes it, and nothing was written.
    local rows, all_ready = M.release_preflight(options, run.journal)
    for _, line in ipairs(M.release_preflight_lines(rows)) do print(line) end
    if not all_ready then
      for _, row in ipairs(rows) do
        if row.ready ~= true then
          print("release: refused(" .. tostring(row.error) .. "): " .. tostring(row.why))
          print("release: next: " .. tostring(row.next))
        end
      end
      print("release: nothing was fetched, built, signed or published")
      return 1
    end
    -- A resume whose worktree is gone gets it back before a settled collect is skipped over.
    if not run.fresh and run.journal.tree_commit and run.journal.repo then
      local made, problem = M.release_tree(run, run.journal.repo, run.journal.tree_commit, nil)
      if not made then
        print("release: refused(" .. tostring(problem.error) .. "): " .. tostring(problem.observed))
        print("release: next: " .. tostring(problem.next))
        return 1
      end
    end
  end
  -- A RUN THAT STOPPED AFTER --until IS RESUMED ONLY BY AN INVOCATION THAT SAYS WHERE TO STOP AGAIN. The
  -- boundary was the whole point of that run (a preflight asks the gate and nothing else), and a resume
  -- that silently dropped it would turn the answer into a landing and a release (review r1, BLOCKER 1).
  -- The branches are printed so the deliberate command is in front of the operator.
  if not run.fresh and tostring(run.journal.result or "") == "stopped_at_until" and options.until_step == nil then
    local names = {}
    for _, branch in ipairs(run.journal.branches or {}) do
      names[#names + 1] = tostring(branch.name or branch.sha or "")
    end
    print("land: refused(resume_of_stopped_at_until): run " .. run.id .. " stopped after " ..
      tostring(run.journal.stopped_at or "a step") .. " (--until) and landed nothing")
    print("land: next: wa land --run " .. run.id .. " --resume --until " ..
      tostring(run.journal.stopped_at or "gate") .. "   (name the boundary again), or land the branch " ..
      "on purpose: wa land --branches " .. (#names > 0 and table.concat(names, ",") or "<branch>"))
    return 1
  end
  remember_start(run, options)
  if options.run and not run.fresh then
    print("land: resuming run " .. run.id .. " (journal " .. M.journal_path(run.id) .. ")")
  end
  if options.landing and run.fresh then
    run.journal.landing = true
    run.journal.gate_landing = options.gate and true or nil
  end
  if options.landing and not (run.journal.landing) then run.journal.landing = true end
  run.journal.result = "in_progress"
  save(run)
  local order = M.steps_for(run.journal, options)
  if run.journal.landing then
    M.emit(run, "started", "started", string.format("landing started: %s (no gate unless --gate)",
      #(run.journal.branches or {}) > 0 and table.concat((function()
        local names = {}
        for _, branch in ipairs(run.journal.branches or {}) do names[#names + 1] = tostring(branch.name or branch.sha or "") end
        return names end)(), " ") or "no branch named"))
  end
  local stopped = nil
  local reached_until = nil
  for _, name in ipairs(order) do
    local step = step_of(run.journal, name)
    local settled = step.state == "done" or step.state == "skipped"
    if options.rollback and name ~= "deploy" and name ~= "report" then
      -- A rollback is one action on the fleet, not a landing: nothing is collected, merged, gated, pushed
      -- or published, and the journal says so rather than leaving those steps looking pending.
      if not settled then
        step.state, step.detail = "skipped", "skipped: rollback run"
        save(run)
      end
      print("land: " .. name .. ": skipped (rollback run)")
    elseif options.release and (name == "review" or name == "merge" or name == "push" or name == "main") then
      -- Settled BY NAME: a release has no branch to review or merge, pushes no landing branch and moves no main.
      if not settled then
        step.state, step.detail = "skipped", "skipped: nothing to land (a release is cut from main's tip)"
        save(run)
      end
      print("land: " .. name .. ": skipped (nothing to land: a release is cut from main's tip)")
    elseif settled and name ~= "report" then
      print("land: " .. name .. ": " .. step.state .. " already" .. (step.detail and (" (" .. tostring(step.detail) .. ")") or ""))
    else
      -- The plan's skip, applied here and nowhere else: a step the round does not need is recorded `skipped`
      -- with its reason (never omitted, never reported done), and `--full` is the explicit escape hatch for a
      -- human who wants every step anyway.
      local planned = run.journal.plan and run.journal.plan.steps and run.journal.plan.steps[name]
      if planned and planned.action == "skip" and name ~= "plan" and not options.full then
        step.state, step.detail = "skipped", "skipped by the plan: " .. tostring(planned.why)
        save(run)
        print("land: " .. name .. ": skipped by the plan (" .. tostring(planned.why) .. ")")
        if run.journal.landing then
          M.emit(run, M.EVENT_STEP[name] or name, "skipped", tostring(step.detail))
        end
      elseif name == "deploy" and options.no_deploy then
        step.state, step.detail = "skipped", "skipped: --no-deploy"
        save(run)
        print("land: deploy: skipped (--no-deploy)")
        if run.journal.landing then
          M.emit(run, M.EVENT_STEP[name] or name, "skipped", "skipped: --no-deploy")
        end
      else
        local ok = M.run_step(run, name, options)
        if not ok then stopped = name break end
      end
    end
    -- `--until <step>`: the round STOPS CLEANLY after the named step, and this is the one place that
    -- boundary is applied. It exists so a check can be asked BY A CALLER that does not want the rest:
    -- a preflight asks "what would the gate say about this branch on the current main?", pays for
    -- collect/plan/review/merge/gate and nothing after it, and gets exit 0 - not a red run of a
    -- landing it never intended to make. The step is a BOUNDARY, not an acknowledgement: whether it
    -- ran, was skipped by the plan or was already settled, nothing after it runs.
    if name == options.until_step then reached_until = name break end
  end
  if reached_until then
    local remaining, after = {}, false
    for _, name in ipairs(order) do
      if name == reached_until then after = true
      -- report is the exception, and it is in the message below rather than in this list: the report ALWAYS
      -- renders (a stop without a summary is the thing this file exists to end), so a list that named it
      -- would contradict the line printed right after it.
      elseif after and name ~= "report" then remaining[#remaining + 1] = name end
    end
    run.journal.result = "stopped_at_until"
    run.journal.stopped_at = reached_until
    run.journal.stop_detail = string.format("stopped after %s (--until): %s did not run",
      reached_until, #remaining > 0 and table.concat(remaining, " ") or "(nothing)")
    save(run)
    -- The report still runs: an until-stop is a result a human reads, and the gate's rows are in it.
    if reached_until ~= "report" then M.run_step(run, "report", options) end
    write(M.report_path(run.id), M.report_text(run.journal))
    save(run)
    print("")
    print(string.format("land: stopped after %s (--until): nothing after it ran%s", reached_until,
      #remaining > 0 and (" (" .. table.concat(remaining, " ") .. ")") or ""))
    if reached_until == "main" and run.journal.main_sha then
      -- THE LOCAL LOOP'S RESULT (FACTORY.md rule 1): main moved and that is the whole landing. No release
      -- was made and none is owed by this run; `wa release cut` starts its own run from main's tip.
      print(string.format("land: landed %s on main - the landing is complete (local loop: no release, no node). A release is its own command: wa release cut",
        tostring(run.journal.main_sha):sub(1, 12)))
    end
    print("land: evidence: " .. tostring((step_of(run.journal, "gate") or {}).evidence or "-"))
    print("land: journal: " .. M.journal_path(run.id))
    print("land: report: " .. M.report_path(run.id))
    return 0
  end
  if stopped then
    local step = step_of(run.journal, stopped)
    run.journal.result = step.state == "flaky" and "stopped" or "stopped"
    run.journal.stopped_at = stopped
    run.journal.stop_detail = tostring(step.detail or step.error or "")
    save(run)
    if run.journal.landing then
      -- One row for the STOP itself: the step's own row is above (red), and this one says the round ended here
      -- so a follower is not left waiting for a landing that stopped.
      M.emit(run, "stopped", "red", string.format("stopped at %s: %s", tostring(stopped),
        tostring(step.detail or step.error or "")))
    end
    -- The report still runs: a stop without a summary is what this file exists to end.
    if stopped ~= "report" then M.run_step(run, "report", options) end
    print("")
    print(string.format("land: STOPPED at %s: %s", stopped, tostring(step.detail or step.error or "")))
    print("land: evidence: " .. tostring(step.evidence or "-"))
    print("land: report: " .. M.report_path(run.id))
    print(options.release and ("land: continue with: wa release cut --run " .. run.id .. " --resume   (main and every landing are untouched)")
      or "land: continue with: wa land --resume")
    return 1
  end
  run.journal.result = "done"
  run.journal.stopped_at = nil
  save(run)
  if run.journal.landing then
    M.emit(run, "done", "green", M.landed_line(run.journal, options))
  end
  -- THE SUMMARY IS REWRITTEN WITH THE FINAL RESULT. report is the last step, so it rendered the journal one
  -- line before result became done: the file a human opens said in_progress while the journal beside it
  -- said done (measured, case29 of this round). The report is the journal as a document, and it must agree
  -- with the journal it documents.
  write(M.report_path(run.id), M.report_text(run.journal))
  print(string.format(options.release and "release: done (run %s, released main %s)" or "land: done (run %s, landed %s)",
    run.id, tostring(run.journal.tree_commit or ""):sub(1, 12)))
  if run.journal.landing then print(M.landed_line(run.journal, options)) end
  return 0
end

-- `--dry-run`: the plan and every command, and nothing else. No journal, no fetch, no worktree, no push.
function M.dry_run(run, options)
  local repo = M.repo()
  print("land: dry run - nothing is fetched, built, pushed, published or deployed")
  print("land: journal would be " .. M.journal_path(run.id))
  print("land: repository " .. tostring(repo))
  print("land: incoming   " .. M.incoming() .. "   origin " .. M.origin())
  if options.branches then print("land: branches   " .. table.concat(options.branches, ", ")) end
  if options.ready then
    local text = read(M.ready_file()) or ""
    print("land: --ready reads " .. M.ready_file() .. ":")
    for line in text:gmatch("[^\r\n]+") do print("        " .. line) end
  end
  local decorator = M.weight()
  print("land: gate weight " .. (decorator ~= "" and decorator or "none (no weight could be applied)"))
  -- THE PLAN, before the command list, because it is what decides which of those commands run at all. Built
  -- from this checkout's own refs (a dry run fetches nothing), by the same code the round itself uses.
  local plan, notes = M.plan_preview(options, run)
  if plan then
    -- The plan names the round's OWN steps: a landing prints the landing's table, never the pipeline's.
    print(M.plan_text({ plan = plan, landing = run.journal.landing, gate_landing = run.journal.gate_landing }))
    for _, note in ipairs(notes or {}) do print("land:   note: " .. note) end
  else
    print("land: plan: cannot be made without a fetch - " .. table.concat(notes or { "no base" }, "; "))
  end

  if run.journal.landing then
    local tree = run.tree or (M.run_dir(run.id) .. "/tree")
    -- THE LANDING'S OWN COMMANDS, and none of the release's: this is the list land-quick.sh printed by doing it.
    print("  merge        git worktree add -b <land N>/final " .. tree .. " <base>; one --no-ff merge per branch;")
    print("               regenerate the declared generated files into the merge commit")
    print("  tests        each scripts/test-*.lua the branch added or changed, alone, with its own home and ledger")
    print("               (skipped, by name, when the branch changes Rust: main-health judges that after the install)")
    if run.journal.gate_landing then print("  gate         bash scripts/fast.sh   (--gate: the whole fast path on the merged tree)") end
    print("  push         git push " .. M.incoming() .. " HEAD:refs/heads/<land N>/final")
    print("  main         git push " .. M.origin() .. " <landed>:refs/heads/main")
    print("  install      git -C " .. tostring(M.repo()) .. " merge --ff-only <landed>")
    print("               wa-sentinel request deploy --reason 'wa land <run>: install <landed>'")
    print("               then installed.txt is read back until it names <landed>, and the installed lua/core is compared")
    print("  health       wa land health-run --repo " .. tostring(M.repo()) .. " --sha <landed>   (an operation; its verdict is an event)")
    print("  report       the run's report, then: Local is evolved to <sha>. You can now test: ...")
    return 0
  end

  -- The checks the plan will actually run, not every check the machine knows: the list has to match the plan
  -- line above it, or the dry run reads as "everything" while the round would run a subset.
  for _, check in ipairs(options.checks or M.DEFAULT_CHECKS) do
    if options.checks then
      print(string.format("  gate %-22s %s", check.name, check.command))
    elseif not plan then
      print(string.format("  gate %-22s %s", check.name, check.command))
    else
      for _, name in ipairs(plan.checks or {}) do
        if name == check.name then print(string.format("  gate %-22s %s", check.name, check.command)) end
      end
    end
  end
  local tree = run.tree or (M.run_dir(run.id) .. "/tree")
  print("  merge        git worktree add -b <land N>/final " .. tree .. " <base>; one --no-ff merge per branch")
  print("  push         git push " .. M.incoming() .. " HEAD:refs/heads/<land N>/final")
  print("  main         git push " .. M.origin() .. " <landed>:refs/heads/main")
  local signer = M.signer(options)
  -- Each command carries the plan's action for its step, so the dry run reads as "this is what would run" and
  -- not as a list of everything the pipeline can do. A step the plan skips still prints its command, prefixed
  -- `skip`, because "what would this have done" is a question an operator asks before trusting a plan.
  local function action_of(name)
    local steps = plan and plan.steps or nil
    if steps and steps[name] and steps[name].action == "skip" then return "skip" end
    return "run "
  end
  local kind = plan and plan.steps and plan.steps.artifacts and plan.steps.artifacts.kind or "node-release"
  local artifacts_command = kind == "lua-tree" and
    ("bash scripts/publish-lua-tree.sh --commit <landed> --out <run>/release")
    or (kind == "components" and ("bash scripts/publish-components.sh --out <run>/release")
    or ("WA_RELEASE_SIGN_DEFER=1 bash scripts/publish-node-binaries.sh --commit <landed> --out <run>/release"))
  -- The review runs BESIDE the merge and the gate (one process per branch, joined by the report), so its line
  -- says that and not "before the merge": a dry run that read as a serialised step would misreport the cost.
  print("  " .. action_of("review") .. "      review       " .. (select(1, M.review_binary()) or "wa")
    .. " eval reviewer <branch> --repo <repo> --base <base> [--brief <file>]; one process per branch,"
    .. " in the background, joined by the report")
  print("  " .. action_of("artifacts") .. "      artifacts    " .. artifacts_command)
  -- `..` binds tighter than `or`, so the whole signer expression is parenthesised before it is concatenated:
  -- without those brackets a node with no signer concatenated nil (measured: `attempt to concatenate a nil
  -- value` on the dry run of a node that has no vault admin URL).
  local sign_command = "REFUSED: no signer found (--signer <node>|local, or WA_VAULT_ADMIN_URL on the vault's node)"
  if signer then
    sign_command = signer.kind == "local" and
      ("bash scripts/sign-release.sh <run>/release/SHA256SUMS (this node: " .. tostring(signer.why) .. ")")
      or ("bash scripts/sign-release.sh on " .. tostring(signer.node) .. " (" .. tostring(signer.why) ..
        "); the signature travels back and is verified here")
  end
  print("  " .. action_of("sign") .. "      sign         " .. sign_command)
  print("  " .. action_of("ship") .. "      ship         WA_RELEASE_SIGN_DEFER=1 bash scripts/publish-artifacts-branch.sh --remote " ..
    M.incoming() .. " --commit <landed> --from <run>/release --out <run>/release")
  print("  " .. action_of("publish") .. "      publish      bash <artifacts ref>/PUBLISH.sh")
  -- The ring in its WAVES: the canary alone, the middle nodes together, the account node last.
  local waves = M.deploy_waves(M.ring(options), options)
  for index, wave in ipairs(waves.waves) do
    for _, entry in ipairs(wave) do
      print(string.format("  %s      deploy       wa update %-12s (%s)%s", action_of("deploy"), entry.node, entry.mode,
        #wave > 1 and " [wave " .. tostring(index) .. ", together with: " ..
          (function()
            local names = {}
            for _, other in ipairs(wave) do if other.node ~= entry.node then names[#names + 1] = other.node end end
            return table.concat(names, "+")
          end)() .. "]" or (index == 1 and " [canary]" or " [account, last]")))
    end
  end
  return 0
end

-- `wa release cut --dry-run`: the plan, and whether signing and publishing are ready. Nothing is fetched,
-- written, built or asked of GitHub beyond `gh auth status`.
function M.release_dry_run(run, options)
  local repo = M.repo()
  print("release: dry run - nothing is fetched, built, signed, pushed, published or deployed")
  print("release: journal would be " .. M.journal_path(run.id))
  local tip = repo and rev(repo, "origin/main") or nil
  print("release: from origin/main " .. (tip and tip:sub(1, 12) or "(unknown here)") .. " as this checkout has it (the run fetches first)  repository " .. tostring(repo))
  print("release: steps: collect (main's tip) - plan - review/merge/push/main skipped (nothing to land) - gate (every check; kept where this tree already passed) - artifacts - sign - ship - publish - " ..
    (options.no_deploy and "deploy skipped (--no-deploy)" or "deploy") .. " - report")
  if not options.no_deploy then
    local waves = M.deploy_waves(M.ring(options), options)
    for index, wave in ipairs(waves.waves) do
      for _, entry in ipairs(wave) do
        print(string.format("release:   deploy wave %d: wa update %s (%s)", index, entry.node, entry.mode))
      end
    end
  end
  local rows = M.release_preflight(options, run.journal)
  for _, line in ipairs(M.release_preflight_lines(rows)) do print(line) end
  return 0
end

-- `wa release cut ...`: the release loop's door (lua/core/init.lua hands `release cut` here; every other
-- `wa release` verb belongs to the binary and lua/core/release_trust.lua). The flags are `wa land`'s own.
function M.release_cli(argv)
  argv = type(argv) == "table" and argv or {}
  if argv[1] ~= "release" or argv[2] ~= "cut" then return nil end
  local forwarded = { "land", "--release" }
  for index = 3, #argv do forwarded[#forwarded + 1] = argv[index] end
  return M.cli(forwarded)
end

-- ---------------------------------------------------------------- `wa land status` / `ready`

function M.status_text(journal)
  local lines = { string.format("run %s: %s%s", tostring(journal.run), tostring(journal.result),
    journal.stopped_at and (" at " .. tostring(journal.stopped_at)) or "") }
  for _, name in ipairs(M.steps_for(journal)) do
    local step = (journal.steps or {})[name] or { state = "pending" }
    lines[#lines + 1] = string.format("  %-10s %-8s %s", name, tostring(step.state), tostring(step.detail or ""))
  end
  return table.concat(lines, "\n")
end

function M.ready_mark(branch, sha, brief)
  if type(branch) ~= "string" or branch == "" or branch:find("%s") then
    return false, "branch_invalid"
  end
  if type(sha) ~= "string" or not sha:match("^%x+$") or #sha < 7 then
    return false, "sha_invalid"
  end
  -- The brief is the file the reviewer reads beside the diff, and it travels ON the ready line because that
  -- line is the one place this machine keeps a branch's intent: `READY <branch> <sha> brief=<path>`. It cannot
  -- hold whitespace (the line is space-separated), and saying so is better than writing a line nothing parses.
  if brief ~= nil and brief ~= "" then
    if type(brief) ~= "string" or brief:find("%s") then return false, "brief_invalid: " .. tostring(brief) end
  else
    brief = nil
  end
  local line = "READY " .. branch .. " " .. sha .. (brief and (" brief=" .. brief) or "")
  local existing = read(M.ready_file()) or ""
  local rows, replaced = {}, false
  for _, row in ipairs(vsplit(existing, "\n")) do
    local name, recorded = row:match("^%s*READY%s+(%S+)%s+(%x+)")
    if trim(row) == "" then
      -- an empty line is not a record: it is dropped rather than carried into the rewrite
    elseif name == branch then
      if recorded ~= sha then
        return false, "ready_box_conflict: " .. branch .. " is recorded at " .. tostring(recorded)
      end
      rows[#rows + 1] = line
      replaced = true
    else
      rows[#rows + 1] = trim(row)
    end
  end
  if not replaced then rows[#rows + 1] = line end
  local wrote = write(M.ready_file(), table.concat(rows, "\n") .. "\n")
  if not wrote then return false, "ready_box_unwritable: " .. M.ready_file() end
  -- A FINISHED WORKER IS AN EVENT (a `mission` row): the ready line is the worker saying it is done, and until
  -- now the only reader of that fact was whoever opened the file. Best effort - the line is written above.
  pcall(function()
    dofile("lua/core/event_ledger.lua").record({ kind = "mission", step = "finished", result = "ready",
      mission = tostring(branch):gsub("^change/", ""), branch = tostring(branch), sha = tostring(sha),
      detail = "READY " .. tostring(branch) .. " " .. tostring(sha) .. (brief and (" brief=" .. tostring(brief)) or ""),
      source = "wa land ready" })
  end)
  return true, replaced and "recorded (replaced the line)" or "recorded"
end

-- ---------------------------------------------------------------- marking a step done out of band
--
-- Some steps are done by a hand that is not this machine: the vault host signs while the operator watches, a
-- release is created from a laptop that holds the token. The journal is the run's state, so that work has to
-- reach it - and NOT by editing journal.json, which turns a record of what happened into a claim about it.
-- `wa land mark <step> --evidence <file>` reads the evidence, RE-VERIFIES the effect with the same checks the
-- step itself would pass, and only then records the step as done, with `marked` and the evidence path on it.
-- A verification that cannot tell is a refusal by name: unknown is not yes.
M.MARKABLE = { "push", "main", "sign", "ship", "publish" }

local function mark_verdict(run, step, options)
  local id = run.id
  local sha = tostring(run.journal.tree_commit or "")
  local tree = run.tree or run.journal.tree
  if sha == "" then
    return false, { error = "mark_without_commit", detail = "run " .. id .. " has no landed tip in its journal",
      next = "a step can only be marked after the merge wrote the tip: run `wa land --resume` first" }
  end
  if step == "push" then
    local tip = tree and remote_tip(tree, M.incoming(), "refs/heads/" .. tostring(run.journal.land_branch or "")) or nil
    if tip ~= sha then
      return false, { error = "mark_not_verified",
        detail = "the incoming repository does not carry this run's tip on its landing branch",
        observed = M.incoming() .. " " .. tostring(run.journal.land_branch or "?") .. " is " .. tostring(tip or "absent") .. ", the landed tip is " .. sha,
        next = "nothing was marked: a push is verified against the remote, never against a file" }
    end
    return true, { detail = M.incoming() .. " " .. tostring(run.journal.land_branch) .. " = " .. sha:sub(1, 12) .. " (verified)" }
  end
  if step == "main" then
    local tip = tree and remote_tip(tree, M.origin(), "refs/heads/main") or nil
    if tip ~= sha then
      return false, { error = "mark_not_verified",
        detail = "the source of truth is not at this run's tip",
        observed = M.origin() .. "/main is " .. tostring(tip or "absent") .. ", the landed tip is " .. sha,
        next = "nothing was marked: main is read back from the remote" }
    end
    return true, { detail = M.origin() .. " main = " .. sha:sub(1, 12) .. " (verified)" }
  end
  local artifacts = run.journal.artifacts or {}
  if step == "sign" then
    local dir = tostring(artifacts.dir or run.journal.release_dir or "")
    if dir == "" or not read(dir .. "/SHA256SUMS") then
      return false, { error = "mark_not_verified", detail = "there is no release set with SHA256SUMS to verify a signature against",
        observed = "looked for " .. (dir ~= "" and (dir .. "/SHA256SUMS") or "a release directory") .. " in the journal",
        next = "the signature is verified against the release set the artifacts step built; run the sign step" }
    end
    if not read(dir .. "/SHA256SUMS.sig") then
      return false, { error = "mark_not_verified", detail = "the release set carries no signature",
        observed = dir .. "/SHA256SUMS.sig does not exist",
        next = "sign it where the vault is, put SHA256SUMS.sig beside the sums, then mark again" }
    end
    local verify = M.exec(". scripts/lib/release-signing.sh && wa_release_verify_sums " .. quote(dir), slashes(tree or "."), 300)
    if (verify.code or 1) ~= 0 then
      return false, { error = "release_key_not_trusted",
        detail = "the signature beside the sums does not verify against the keys this tree trusts",
        observed = first_line(tostring(verify.stderr ~= "" and verify.stderr or verify.stdout)),
        next = "nothing was marked: a signature no node can verify is not a release" }
    end
    artifacts.dir = dir
    artifacts.signed = true
    artifacts.signer = trim(options.signer) ~= "" and trim(options.signer) or "out_of_band"
    artifacts.key_id = tostring(read(dir .. "/SHA256SUMS.sig") or ""):match("key%s+(%S+)")
    run.journal.artifacts = artifacts
    return true, { detail = "signed out of band (key " .. tostring(artifacts.key_id) .. "), verified here" }
  end
  if step == "ship" or step == "publish" then
    local short = sha:sub(1, 12)
    if step == "ship" then
      local ref = tostring(artifacts.ref or ("artifacts/node-" .. short))
      local tip = tree and remote_tip(tree, M.incoming(), "refs/heads/" .. ref) or nil
      if not tip then
        return false, { error = "mark_not_verified", detail = "the incoming repository carries no " .. ref,
          observed = "git ls-remote " .. M.incoming() .. " refs/heads/" .. ref .. " answered nothing",
          next = "ship the set first (scripts/publish-artifacts-branch.sh), then mark" }
      end
      local fetched = git(run, tree, "fetch --quiet " .. quote(M.incoming()) .. " " .. quote("refs/heads/" .. ref), 600)
      local sig = M.exec("git -C " .. quote(slashes(tree)) .. " cat-file -e " .. quote("FETCH_HEAD:SHA256SUMS.sig") .. " && echo yes || echo no", slashes(tree), 120)
      if (fetched.code or 1) ~= 0 or trim(tostring(sig.stdout or "")) ~= "yes" then
        return false, { error = "mark_not_verified", detail = ref .. " does not carry a signature",
          observed = "fetched " .. ref .. ": " .. trim(tostring(sig.stdout or "")) .. " for SHA256SUMS.sig",
          next = "a shipped ref without SHA256SUMS.sig is not this round's release" }
      end
      artifacts.ref = ref
      artifacts.artifacts_commit = tip
      run.journal.artifacts = artifacts
      return true, { detail = ref .. " " .. tostring(tip):sub(1, 12) .. " carries the signed sums (verified)" }
    end
    local tag = "node-" .. short
    local account = trim(options.account or (run.journal.start or {}).account)
    local routed = account ~= "" and account ~= "local" and account ~= "this"
    local command = "gh release view " .. quote(tag) .. " >/dev/null 2>&1 && echo present || echo absent"
    local answer
    if routed then
      local reply, problem = M.node_bash(account, command)
      if not reply then
        return false, { error = "mark_not_verified", detail = "cannot read the releases of " .. account,
          observed = problem.detail .. ": " .. problem.observed, next = "check the node is reachable, then mark again" }
      end
      answer = tostring(reply.stdout or "")
    else
      answer = tostring((M.exec(command, "", 120) or {}).stdout or "")
    end
    if trim(answer) ~= "present" then
      return false, { error = "mark_not_verified", detail = "the release " .. tag .. " is not there",
        observed = (routed and ("asked " .. account)) or "asked this machine" .. ": " .. trim(answer),
        next = "publish it first (bash PUBLISH.sh from the shipped ref), then mark" }
    end
    artifacts.signed = artifacts.signed or true
    run.journal.artifacts = artifacts
    run.journal.publish = { tag = tag, state = "published", signed = true, key_id = artifacts.key_id,
      account = routed and account or nil }
    return true, { detail = "release " .. tag .. " is published" .. (routed and (" (on " .. account .. ")") or "") .. " (verified)" }
  end
  return false, { error = "mark_unsupported", detail = step .. " cannot be marked: this verb only records an effect it can verify",
    observed = "markable steps: " .. table.concat(M.MARKABLE, ", "),
    next = "run the step instead: wa land --resume" }
end

-- <run id> <step> <evidence file> <options>: verify, then record. The evidence file must exist and be
-- readable - a mark with no evidence is the hand-edited journal this verb replaces - and the journal is
-- written only after the verification answered yes.
function M.mark(id, step, evidence_path, options)
  options = type(options) == "table" and options or {}
  step = trim(step)
  local journal = json_file(M.journal_path(id))
  if not journal then
    return false, { error = "mark_no_run", detail = "no journal for run " .. tostring(id),
      observed = M.journal_path(id) .. " does not exist", next = "`wa land status` lists the runs" }
  end
  local markable = false
  for _, name in ipairs(M.MARKABLE) do if name == step then markable = true break end end
  if not markable then
    return false, { error = "mark_unsupported", detail = tostring(step) .. " cannot be marked",
      observed = "markable steps: " .. table.concat(M.MARKABLE, ", "),
      next = "run the step instead: wa land --resume" }
  end
  if evidence_path == nil or trim(evidence_path) == "" then
    return false, { error = "mark_evidence_required", detail = "a mark without evidence is a claim, not a record",
      next = "name the output of the command that did it: wa land mark " .. step .. " --evidence <file>" }
  end
  if not read(evidence_path) then
    return false, { error = "mark_evidence_missing", detail = "the evidence file cannot be read",
      observed = tostring(evidence_path), next = "write what the command printed to a file and name it" }
  end
  local step_row = (journal.steps or {})[step]
  if step_row and (step_row.state == "done" or step_row.state == "skipped") then
    return false, { error = "mark_already_settled", detail = "run " .. id .. "'s " .. step .. " is already " .. tostring(step_row.state),
      next = "nothing to mark: `wa land status --run " .. id .. "` shows the run" }
  end
  local start = journal.start or {}
  local merged = {}
  for key, value in pairs(start) do merged[key] = value end
  for key, value in pairs(options) do merged[key] = value end
  local run = { id = tostring(id), journal = journal, tree = journal.tree, land_branch = journal.land_branch }
  local ok, result = mark_verdict(run, step, merged)
  if not ok then return false, result end
  journal.steps = journal.steps or {}
  local row = journal.steps[step] or { name = step }
  row.state = "done"
  row.detail = tostring((result and result.detail) or "marked")
  row.marked = true
  row.mark_evidence = tostring(evidence_path)
  row.marked_at = now()
  journal.steps[step] = row
  journal.updated_at = now()
  if step == "push" then journal.pushed_sha = journal.tree_commit end
  if step == "main" then journal.main_sha = journal.tree_commit end
  if not write(M.journal_path(id), json.encode(journal)) then
    return false, { error = "mark_unwritable", detail = "the journal could not be written", observed = M.journal_path(id) }
  end
  local note = M.run_dir(id) .. "/evidence/" .. step .. ".log"
  local previous = read(note) or ""
  write(note, previous .. "\n$ [marked out of band] evidence " .. tostring(evidence_path) .. "\n" .. tostring(result.detail) .. "\n")
  return true, { detail = tostring(result.detail), journal = M.journal_path(id) }
end

-- ---------------------------------------------------------------- the CLI

local function split(value)
  local rows = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    local name = trim(item)
    if name ~= "" then rows[#rows + 1] = name end
  end
  return rows
end

-- Returns nil when the arguments are not a `land` request (so the caller keeps its own dispatch), and an
-- exit code otherwise. 0 done, 1 stopped or refused, 2 usage.
function M.cli(argv)
  argv = type(argv) == "table" and argv or {}
  if argv[1] ~= "land" then return nil end
  local options = {}
  local index = 2
  local read_value = function(flag)
    local value = argv[index + 1]
    if type(value) ~= "string" or value == "" or value:sub(1, 2) == "--" then
      print("wa land: " .. flag .. " needs a value")
      return nil
    end
    return value
  end
  while argv[index] do
    local flag = tostring(argv[index])
    if flag == "status" then options.status = true; index = index + 1
    elseif flag == "ready" then
      local branch, sha = argv[index + 1], argv[index + 2]
      if type(branch) ~= "string" or type(sha) ~= "string" then
        print("wa land ready needs a branch and a sha: wa land ready change/<name> <sha> [--brief <file>]")
        return 2
      end
      -- The brief is the operator's text for the branch, and the ready line is where this machine keeps it: the
      -- reviewer reads it beside the diff, so a branch declared ready WITH its brief is reviewed against what it
      -- was for and not only against its diff.
      local brief = nil
      for scan = index + 3, #argv do
        if argv[scan] == "--brief" then brief = argv[scan + 1] end
      end
      local ok, answer = M.ready_mark(branch, sha, brief)
      print("wa land ready: " .. tostring(answer) .. (ok and (" - " .. branch .. " " .. sha) or ""))
      return ok and 0 or 1
    elseif flag == "health-run" then
      -- `wa land health-run --repo <checkout> [--sha <sha>]`: measure main's health once, here, and write the
      -- verdict as an event. It is what the `health` step starts as its own operation, and it is the command a
      -- person runs by hand: both write the same row.
      local health = {}
      for scan = index + 1, #argv do
        local word = tostring(argv[scan])
        if word == "--repo" then health.repo = argv[scan + 1]
        elseif word == "--sha" then health.sha = argv[scan + 1]
        elseif word == "--mission" then health.mission = argv[scan + 1]
        elseif word == "--branch" then health.branch = argv[scan + 1]
        elseif word == "--source" then health.source = argv[scan + 1]
        elseif word == "--timeout" then health.timeout = tonumber(argv[scan + 1])
        end
      end
      local code, answer = M.health_run(health)
      if answer.error then
        print("land: health-run: refused(" .. tostring(answer.error) .. "): " ..
          tostring(answer.observed or answer.verdict or ""))
      end
      return code
    elseif flag == "mark" then
      -- `wa land mark <step> --evidence <file> [--run <id>] [--account <node>]`: the verb that records an
      -- effect done out of band, AFTER re-verifying it. It is the only supported way to move a step to done
      -- outside the step itself; a hand-edited journal is exactly what it replaces.
      local step = argv[index + 1]
      if type(step) ~= "string" or step == "" or step:sub(1, 2) == "--" then
        print("wa land mark needs a step: wa land mark <" .. table.concat(M.MARKABLE, "|") .. "> --evidence <file> [--run <id>]")
        return 2
      end
      local mark_options = {}
      for scan = index + 2, #argv do
        local word = tostring(argv[scan])
        if word == "--evidence" then mark_options.evidence = argv[scan + 1]
        elseif word == "--run" then mark_options.run = argv[scan + 1]
        elseif word == "--account" then mark_options.account = argv[scan + 1]
        elseif word == "--signer" then mark_options.signer = argv[scan + 1]
        end
      end
      local id = mark_options.run
      if id == nil or id == "" then id = newest_unfinished() end
      if id == nil then
        print("wa land mark: no run to mark: name one with --run <id>, or `wa land status`")
        return 1
      end
      local marked, answer = M.mark(id, step, mark_options.evidence, mark_options)
      if marked then
        print("wa land mark: " .. tostring(answer.detail) .. " (run " .. tostring(id) .. ", step " .. tostring(step) .. ")")
        return 0
      end
      print("wa land mark: refused (" .. tostring(answer.error) .. "): " .. tostring(answer.detail or ""))
      if answer.observed then print("wa land mark: observed: " .. tostring(answer.observed)) end
      if answer.next then print("wa land mark: next: " .. tostring(answer.next)) end
      return 1
    elseif flag == "--branches" then
      local value = read_value(flag); if not value then return 2 end
      options.branches = split(value); index = index + 2
    elseif flag == "--ready" then options.ready = true; index = index + 1
    elseif flag == "--release" then options.release = true; index = index + 1
    elseif flag == "--dry-run" then options.dry_run = true; index = index + 1
    elseif flag == "--full" then options.full = true; index = index + 1
    elseif flag == "--gate" then
      -- THE GATE ON A LANDING, asked for by name (FACTORY.md rule 10: a landing runs no gate; the gate belongs
      -- to the release, and this is the one way to ask for it anyway).
      options.gate = true; options.landing = true; index = index + 1
    elseif flag == "--fix-main" then
      -- This landing IS the fix for a red main (FACTORY.md rule 8): it is allowed onto a red main, and nothing
      -- else is.
      options.fix_main = true; options.landing = true; index = index + 1
    elseif flag == "--no-health" then
      options.no_health = true; options.landing = true; index = index + 1
    elseif flag == "--install-timeout" then
      local given = value(flag); if not given then return 2 end
      if not tonumber(given) then print("wa land: --install-timeout takes seconds"); return 2 end
      options.install_timeout = tonumber(given); index = index + 2
    elseif flag == "--canary" then
      local value = read_value(flag); if not value then return 2 end
      options.canary = value; index = index + 2
    elseif flag == "--account" then
      local value = read_value(flag); if not value then return 2 end
      options.account = value; index = index + 2
    elseif flag == "--no-deploy" then options.no_deploy = true; index = index + 1
    elseif flag == "--rollback" then options.rollback = true; index = index + 1
    elseif flag == "--signer" then
      local value = read_value(flag); if not value then return 2 end
      options.signer = value; index = index + 2
    elseif flag == "--until" then
      local value = read_value(flag); if not value then return 2 end
      -- A STEP BY NAME, checked here: an `--until gat` that silently honoured nothing would run the
      -- whole landing (push, main, artifacts, the fleet) for a caller who asked for the gate only.
      local known = false
      for _, step in ipairs(M.STEPS) do if step == value then known = true break end end
      for _, step in ipairs(M.LANDING_STEPS) do if step == value then known = true break end end
      if not known then
        print("wa land: --until " .. value .. " is not a step of this file; the steps are " ..
          table.concat(M.STEPS, " "))
        return 2
      end
      options.until_step = value; index = index + 2
    elseif flag == "--resume" then options.resume = true; index = index + 1
    elseif flag == "--run" then
      local value = read_value(flag); if not value then return 2 end
      options.run = value; index = index + 2
    elseif flag == "--repo" then
      local value = read_value(flag); if not value then return 2 end
      M.repo_dir = value; index = index + 2
    elseif flag == "--incoming" then
      local value = read_value(flag); if not value then return 2 end
      M.incoming_remote = value; index = index + 2
    elseif flag == "--origin" then
      local value = read_value(flag); if not value then return 2 end
      M.origin_remote = value; index = index + 2
    elseif flag == "--ring" then
      local value = read_value(flag); if not value then return 2 end
      local rows = {}
      for _, item in ipairs(split(value)) do
        local node, mode = item:match("^([^:]+):?([^:]*)")
        if node then rows[#rows + 1] = { node = node, mode = (mode ~= "" and mode or "tree") } end
      end
      options.ring = rows; index = index + 2
    elseif flag == "--json" then options.json = true; index = index + 1
    elseif flag == "--help" or flag == "-h" then
      print("wa land <branch>...                THE LANDING: merge onto main, regenerate, the branch's own tests,")
      print("                                   push, install this node (verified), then main's health. No gate.")
      print("  --gate                     run the whole fast path on the merged tree anyway (minutes, not the release)")
      print("  --fix-main                 this landing IS the fix for a red main (FACTORY.md rule 8)")
      print("  --no-health                do not measure main's health after this landing")
      print("  --install-timeout <s>      how long the install record has to name the landing (default 2400)")
      print("wa land health-run --repo <checkout> [--sha <sha>]   measure main's health once; the verdict is an event")
      print("wa land --ready | --branches a,b [--dry-run] [--no-deploy] [--full] [--resume] [--run <id>]")
      print("wa land --rollback                 put every node's kept pair back (reverse ring order)")
      print("wa land mark <step> --evidence <file> [--run <id>]   record a step done out of band, after re-verifying it")
      print("wa land status [--run <id>]        the journal, read-only")
      print("wa release cut [--dry-run] [--no-deploy] [--signer <node|local>] [--account <node>] [--run <id>] [--resume]")
      print("                                   a signed release FROM MAIN'S TIP, rolled to the fleet; lands nothing")
      print("wa land ready <branch> <sha> [--brief <file>]   record a READY line for a finished branch")
      print("  --repo <dir> --incoming <remote> --origin <remote> --ring node:mode,... --json")
      print("  --canary <node> --account <node>  which node goes first (default work) and last (default openclaw)")
      print("  --until <step>         stop cleanly after that step: exit 0, result stopped_at_until")
      print("  --full                 ignore the plan: run every step and the whole suite (no narrowed rows)")
      print("  --signer <node|local>   where the release is signed (default: the node whose WA_VAULT_ADMIN_URL is set)")
      return 0
    elseif flag:sub(1, 2) ~= "--" then
      -- `wa land change/x [change/y ...]`: THE LANDING (FACTORY.md rule 10). Positional branches are what the
      -- operator types; no gate runs unless --gate names it, and the round takes the landing's own step order.
      options.branches = options.branches or {}
      options.branches[#options.branches + 1] = flag
      options.landing = true
      index = index + 1
    else
      print("wa land: unknown option " .. flag .. "; nothing was done")
      return 2
    end
  end
  if options.status then
    local id = options.run
    if not id then id = newest_unfinished(options.release) end
    if not id then
      print("wa land: no run under " .. M.root())
      return 1
    end
    local journal = json_file(M.journal_path(id))
    if not journal then
      print("wa land: no journal for run " .. tostring(id) .. " (" .. M.journal_path(id) .. ")")
      return 1
    end
    print(M.status_text(journal))
    print("report: " .. M.report_path(id))
    return journal.result == "done" and 0 or 1
  end
  if not options.branches and not options.ready and not options.resume and not options.run and not options.rollback
     and not options.release then
    print("wa land: nothing named. Use `wa land <branch>...` (a landing: merge, the branch's own tests, push, " ..
      "install this node, then main's health), or --ready (the ready box), --branches a,b, --resume, or --rollback.")
    print("wa land --help")
    return 2
  end
  return M.run(options)
end

return M
