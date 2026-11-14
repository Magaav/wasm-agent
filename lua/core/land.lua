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
function M.exec(command, cwd, timeout)
  local ok, raw = pcall(host.exec, command, cwd or "", timeout)
  if not ok or type(raw) ~= "string" then
    return { code = 127, stdout = "", stderr = "host refused: " .. tostring(command):sub(1, 120) }
  end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if decoded_ok and type(decoded) == "table" then
    return { code = tonumber(decoded.code) or 1, stdout = tostring(decoded.stdout or ""),
             stderr = tostring(decoded.stderr or "") }
  end
  return { code = 1, stdout = "", stderr = "unreadable operation wrapper: " .. tostring(raw):sub(1, 200) }
end

-- How a landing waits between two polls of a node's own record. A field, not a sleep call inside the
-- logic, so a test drains it instantly while production waits a real five seconds.
function M.sleep(seconds) M.exec("sleep " .. tostring(seconds)) end

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
-- `artifacts/node-<sha12>`, publish it, deploy. `report` is last and runs even when the machine stopped,
-- because a stop without a report is the thing this file exists to end.
--
-- `artifacts`/`sign`/`ship` are the three halves of publishing and they are separate steps because the
-- hosts differ: the build needs a toolchain, the signature needs the vault's admin listener, and the ship
-- needs a git remote. Keeping them apart is what makes a rerun of one of them cheap - and a signature that
-- arrives after a stopped run is not thrown away with the build.
M.STEPS = { "collect", "plan", "review", "merge", "gate", "push", "main", "artifacts", "sign", "ship", "publish", "deploy", "report" }

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
    command = "cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities codemode",
    timeout = 1800, min_tests = 1, detail = "the code-mode Rust tests (wa-capabilities: the seam and quickjs)" },
  { name = "cargo-wa-whatsapp", command = "cargo test --lib --offline", cwd = "rust/components/wa-whatsapp",
    timeout = 1200, min_tests = 1, detail = "the wa-whatsapp component's own crate" },
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
  artifacts = 480, sign = 150, ship = 120, publish = 180, deploy = 960, report = 5,
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
M.GATE_ALWAYS = { "fast", "prompt-docs" }
-- Checks a plan may ADD when a path touches their subject, with the paths that trigger them. The Rust
-- crates are already narrowed by `scripts/fast.sh` itself (it tests the crates a change touches), so only
-- the checks that are NOT inside the fast path are listed here.
M.GATE_TRIGGERS = {
  ["codemode-component"] = { "^lua/core/codemode", "^rust/components/codemode", "^rust/wa%-capabilities/src/codemode", "^scripts/codemode", "^scripts/build%-codemode" },
  ["cargo-codemode"] = { "^lua/core/codemode", "^rust/components/codemode", "^rust/wa%-capabilities/src/codemode", "^scripts/codemode", "^wit/model/codemode" },
  ["cargo-wa-whatsapp"] = { "^rust/components/wa%-whatsapp", "^rust/wa%-whatsapp%-outbox", "^rust/wa%-whatsapp%-index", "^wit/whatsapp" },
}

-- The plan's own rows/checks, as pure functions so the decisions are testable without git or a build.

-- <paths> -> which of M.GATE_TRIGGERS fire (a pattern is matched against each changed path).
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
    steps.deploy = skip("docs-only: no node needs these bytes (a document is not loaded at runtime)")
  elseif category == "lua-scripts-only" then
    steps.artifacts = run("Lua tree record (manifest + SHA256SUMS over the shipped Lua tree): no cross-build, no node release")
    steps.artifacts.kind = "lua-tree"
    steps.sign = run("signs the Lua-tree record's SHA256SUMS (the vault's host, as always)")
    steps.ship = skip("a Lua-only round ships no node release: each node installs the tree with its own deploy, which keeps the installed binary")
    steps.publish = skip("a Lua-only round publishes no node release; the signed record is the round's evidence and the deploy is the transport")
    steps.deploy = run("the ring, in order: the nodes take the Lua tree and keep their binary (the deploy's Lua fast path)")
  elseif category == "components" then
    steps.artifacts = run("components bundle only (scripts/publish-components.sh): build, verify against components.lock, print the repin line")
    steps.artifacts.kind = "components"
    steps.sign = skip("the component bundle is not covered by the release-signing key: scripts/publish-components.sh prints its own gh line")
    steps.ship = skip("no node release to ship: the bundle is fetched by the tag components-<lock sha12>")
    steps.publish = skip("publishing the bundle needs a credential host: the exact gh line is in the artifacts evidence and the report")
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
-- bound is a log nothing reads. `read` before `write` because the host has no append primitive.
local function sink(run, name)
  local path = M.evidence_path(run.id, name)
  local buffer = read(path) or ""
  return function(text)
    buffer = buffer .. tostring(text or "")
    if #buffer > 200000 then buffer = "…\n" .. buffer:sub(-150000) end
    write(path, buffer)
  end
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
  local fetched = git(run, repo, "fetch --quiet --prune " .. quote(incoming) .. " " .. quote("+refs/heads/*:refs/remotes/" .. incoming .. "/*"))
  evidence(command_line("fetch", "git fetch --prune " .. incoming))
  evidence((fetched.stdout or "") .. (fetched.stderr or ""))
  -- The base is the FURTHEST MAIN both sides agree on. Two mains exist and they can lag each other: the
  -- incoming repository's (every node can read it) and the source of truth's (only a credentialed node can
  -- fast-forward it). A landing stops after main moved but before the release published, so the next one
  -- must start from whichever main already contains the other - and a pair that diverged is a REFUSAL,
  -- because picking either would silently drop one side's work.
  local incoming_main = rev(repo, "refs/remotes/" .. incoming .. "/main")
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
  if options.branches and #options.branches > 0 then
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
    for _, candidate in ipairs({ "refs/remotes/" .. incoming .. "/" .. want.name, "refs/heads/" .. want.name }) do
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
  run.journal.incoming = incoming
  run.journal.origin = M.origin()
  run.journal.branches = branches
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

-- <journal> -> the round's changed paths (base..tip of every collected branch), deduplicated.
-- Renames are not followed (`--no-renames`): the planner asks which paths the merge introduces, and a rename
-- is two paths - the old one gone and the new one here - exactly as `git diff --name-status` reports it.
function M.changed_paths(run)
  local repo = run.journal.repo or M.repo()
  local base = run.journal.base
  local seen, paths = {}, {}
  for _, branch in ipairs(run.journal.branches or {}) do
    if base and branch.sha then
      local listing = M.exec("git -C " .. quote(slashes(repo)) .. " diff --name-only --no-renames " ..
        quote(base) .. " " .. quote(branch.sha), repo, 120)
      for path in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
        path = trim(path)
        if path ~= "" and not seen[path] then seen[path] = true; paths[#paths + 1] = path end
      end
    end
  end
  table.sort(paths)
  return paths
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

-- <run> <paths> -> the Lua rows a narrowed fast-path run should execute (`scripts/fast.sh` adds its
-- never-dropped core rows itself, so this list is a REQUEST). A row is affected when the round changed it,
-- when its own name names a changed module (`lua/core/agent.lua` -> `scripts/test-agent*.lua`), or when its
-- text mentions the changed path - a dependency proved by the file, not guessed from the name. No row and a
-- non-doc change means the suite runs whole, which the plan reports as `full`.
function M.gate_rows(run, paths)
  local repo = run.journal.repo or M.repo()
  local rows, seen = {}, {}
  local function add(path)
    path = trim(path)
    if path == "" or seen[path] then return end
    if not path:match("^scripts/test%-[%w%._%-]+%.lua$") then return end
    seen[path] = true; rows[#rows + 1] = path
  end
  local modules = {}
  for _, path in ipairs(paths) do
    if path:match("^scripts/test%-[%w%._%-]+%.lua$") then add(path) end
    if path:match("^lua/.+%.lua$") then modules[#modules + 1] = path end
  end
  if #modules > 0 then
    local listing = M.exec("ls -1 scripts/test-*.lua 2>/dev/null", repo, 60)
    local named = {}
    for line in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
      local candidate = trim(line)
      if (candidate:gsub("^scripts/", "")):match("^test%-") then named[#named + 1] = candidate end
    end
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
  return rows
end

-- <run> -> {list, why}: the gate's checks for this round. The always-on two (`fast`, `prompt-docs`) are never
-- dropped; the others are added when a changed path touches their subject (M.GATE_TRIGGERS). A round whose
-- plan is `full` runs every check.
function M.gate_checks(run, options)
  if options.checks then return options.checks, #options.checks .. " check(s), named with --checks" end
  local plan = run.journal.plan
  if not plan or plan.full then return M.DEFAULT_CHECKS, "every check (no narrower set was proved)" end
  local wanted = {}
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

-- The finished runs in the journal: what an estimate is made from. Only a run whose result is `done` is used -
-- a stopped round's step times are the part that worked, not what a round costs.
function M.land_runs(limit)
  local runs = {}
  -- `find`, not `ls <dir>/*/journal.json`: the glob has to be expanded by the shell, and quoting a path that
  -- contains a wildcard (the right thing to do with a path a user named) stops `ls` from doing it - measured
  -- here, the estimate silently fell back to the default table because the listing was empty. `find` takes
  -- the directory quoted and matches the name itself.
  local listing = M.exec("find " .. quote(M.root()) .. " -maxdepth 2 -name journal.json -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -" .. tostring(limit or 20), "", 60)
  for line in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
    local path = line:match("^%S+%s+(.+)$")
    if path then
      local journal = json_file(trim(path))
      if journal and journal.run and journal.result == "done" then runs[#runs + 1] = journal end
    end
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

-- <run> <paths> -> the plan table (the shape `journal.plan` holds), built the same way for a real round and
-- for `--dry-run`: one implementation, so a printed plan and the plan a round obeys cannot differ.
function M.build_plan(run, paths)
  local classified = M.classify(run, paths)
  local rows = M.gate_rows(run, paths)
  local full = (#rows == 0 and classified.category ~= "docs-only")
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
  return { category = classified.category, files = #paths, counts = classified.counts or {},
    classifier = classified.classifier, why = classified.why, steps = M.plan_steps(classified.category),
    checks = names, rows = rows, full = full, expected_seconds = estimate.seconds,
    expected_from = estimate.from, per_step = estimate.per_step }
end

impl.plan = function(run, options)
  local evidence = sink(run, "plan")
  local repo = run.journal.repo or M.repo()
  local paths = M.changed_paths(run)
  if #paths == 0 then
    return false, { error = "plan_no_changes", observed = "the collected branches introduce no path this tree does not already have",
      next = "nothing to land: check the branches with `git -C " .. tostring(repo) .. " log --oneline <base>..<tip>`" }
  end
  local plan = M.build_plan(run, paths)
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
  local base = rev(repo, "origin/main") or rev(repo, "refs/remotes/" .. incoming .. "/main")
    or rev(repo, incoming .. "/main")
  if not base then
    return nil, { "no main in " .. tostring(repo) .. ": the plan needs a base, and a dry run does not fetch (run without --dry-run)" }
  end
  local branches = {}
  for _, name in ipairs(options.branches or {}) do
    local tip = rev(repo, "refs/heads/" .. name) or rev(repo, "refs/remotes/" .. incoming .. "/" .. name)
    if tip then
      branches[#branches + 1] = { name = name, sha = tip }
    else
      notes[#notes + 1] = name .. " is not in this checkout yet (collect fetches it), so the plan leaves it out"
    end
  end
  if #branches == 0 then return nil, notes end
  local shell = { id = (run and run.id) or "dry-run", journal = { repo = repo, base = base, branches = branches } }
  local paths = M.changed_paths(shell)
  if #paths == 0 then return nil, { "the named branches introduce no path this tree does not already have" } end
  return M.build_plan(shell, paths), notes
end

-- The plan as text: what changed, which path, which steps run or are skipped and why, and what it should cost.
function M.plan_text(journal)
  local plan = journal.plan or {}
  local lines = {}
  local function add(line) lines[#lines + 1] = line end
  local counts = plan.counts or {}
  add(string.format("land: plan: %d path(s) changed -> %s", tonumber(plan.files or 0), tostring(plan.category or "unknown")))
  add(string.format("land:   compiled %d, component %d, lua %d, docs %d (classified by %s)",
    tonumber(counts.compiled or 0), tonumber(counts.component or 0), tonumber(counts.lua or 0), tonumber(counts.docs or 0),
    tostring(plan.classifier or "?")))
  if plan.why then add("land:   " .. tostring(plan.why)) end
  local rows = plan.rows or {}
  add(string.format("land:   gate: %s%s", table.concat(plan.checks or {}, " "),
    plan.full and "" or (" over " .. tostring(#rows) .. " Lua row(s) of the suite")))
  for _, name in ipairs(M.STEPS) do
    local step = (plan.steps or {})[name]
    if step then
      add(string.format("land:   %-9s %-4s %s", name, step.action == "skip" and "skip" or "run", tostring(step.why or "")))
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

-- merge: a fresh worktree cut from the base, then one merge per branch. Conflicts stop the landing and keep
-- the worktree: it is the evidence a human resolves against.
impl.merge = function(run, options)
  local evidence = sink(run, "merge")
  local repo = run.journal.repo or M.repo()
  local base = run.journal.base
  local tree = run.tree
  if tree and not rev(tree, "HEAD") then
    -- A resume whose worktree is gone: the merges are redone from the base rather than reported as done.
    print("land: merge: the worktree " .. tostring(tree) .. " is gone; recreating it")
    tree = nil
  end
  if not tree then
    -- The format is QUOTED: an unquoted `%(refname:short)` is a shell syntax error, so the listing came
    -- back empty, every run believed it was `land1`, and the second landing of a session died on
    -- "'land1/final' is already used by worktree" (measured by scripts/test-land.lua, 13/11).
    local listing = git(run, repo, "for-each-ref " .. quote("--format=%(refname:short)") ..
      " " .. quote("refs/heads/land*/final"))
    local highest = 0
    for name in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
      local number = trim(name):match("^land(%d+)/final$")
      if number then highest = math.max(highest, tonumber(number)) end
    end
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
      return false, { error = "worktree_failed", observed = first_line(added.stderr ~= "" and added.stderr or added.stdout),
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
      return false, { error = "merge_conflict", observed = branch.name .. " conflicts with " .. tostring(run.journal.land_branch),
        next = "resolve it in " .. tree .. " (the worktree is kept), or land a fixed branch" }
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
  run.journal.tree_commit = rev(tree, "HEAD")
  return true, { detail = string.format("%d branch(es) merged into %s (%s)", #run.journal.branches,
                  tostring(run.journal.land_branch), tostring(run.journal.tree_commit):sub(1, 12)) }
end

-- gate: the checks, weighted, one run each - and a failing check is re-run ONCE ALONE. Passing alone after
-- failing under load is reported as `flaky under load: <name>` and STOPS the landing: a human decides,
-- nothing here turns it green.
local function passed_tests(text)
  local total = 0
  for count in tostring(text or ""):gmatch("test result: ok%. (%d+) passed") do total = total + (tonumber(count) or 0) end
  return total
end

impl.gate = function(run, options)
  local evidence = sink(run, "gate")
  local tree = run.tree
  -- Which checks: the plan's set (M.gate_checks), which is never smaller than the always-on core, and - when
  -- the plan mapped rows - a WA_FAST_ROWS file for `scripts/fast.sh` so a Lua-only round runs the rows its
  -- changed modules touch instead of all ~140. The rows file is written here, next to the evidence, so the
  -- command in the log is the command that ran.
  local checks, why = M.gate_checks(run, options)
  local rows_file = nil
  if not options.checks and run.journal.plan and run.journal.plan.rows and #run.journal.plan.rows > 0
     and not run.journal.plan.full then
    rows_file = M.run_dir(run.id) .. "/gate-rows.txt"
    if not write(rows_file, table.concat(run.journal.plan.rows, "\n") .. "\n") then
      rows_file = nil
      evidence("the row list could not be written; every Lua row will run\n")
    end
  end
  run.journal.gate_checks = why
  local decorator = M.weight()
  run.journal.gate_weight = decorator ~= "" and decorator or "none (no weight could be applied)"
  local rows = {}
  for _, check in ipairs(checks) do
    local command = check.command
    if rows_file and check.name == "fast" then
      command = "WA_FAST_ROWS=" .. quote(rows_file) .. " " .. command
    end
    command = (decorator ~= "" and (decorator .. " " .. quote(command))) or command
    local cwd = check.cwd and (slashes(tree) .. "/" .. check.cwd) or slashes(tree)
    evidence(command_line(check.name, check.command, decorator))
    local started = now()
    local result = M.exec(command, cwd, check.timeout or 1800)
    local seconds = now() - started
    evidence((result.stdout or "") .. (result.stderr or ""))
    local tests = passed_tests((result.stdout or "") .. (result.stderr or ""))
    local row = { name = check.name, ok = (result.code or 1) == 0, code = result.code, seconds = seconds,
                  tests = tests, detail = check.detail or check.command }
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
      -- Alone, once. No other check runs beside it, so "it passes alone" is a statement about load.
      local retry_started = now()
      evidence(command_line(check.name .. " (alone, after a failure)", check.command, decorator))
      local retry = M.exec(command, cwd, check.timeout or 1800)
      local retry_tests = passed_tests((retry.stdout or "") .. (retry.stderr or ""))
      evidence((retry.stdout or "") .. (retry.stderr or ""))
      row.retry = { ok = (retry.code or 1) == 0, code = retry.code, seconds = now() - retry_started, tests = retry_tests }
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
  local result = git(run, tree, "push " .. quote(origin) .. " " .. quote(sha .. ":refs/heads/main"), 1800)
  evidence(command_line("main", "git push " .. origin .. " " .. sha .. ":refs/heads/main"))
  evidence((result.stdout or "") .. (result.stderr or ""))
  if (result.code or 1) ~= 0 then
    local text = tostring(result.stderr or "") .. tostring(result.stdout or "")
    local credential = text:lower():find("permission") or text:lower():find("denied")
      or text:lower():find("authentication") or text:lower():find("could not read username")
    return false, { error = credential and "main_push_needs_credentials" or "main_push_failed",
      detail = "the landed tip could not be fast-forwarded onto " .. origin .. "/main",
      observed = first_line(text ~= "" and text or "git push answered nothing"),
      next = "run on the node that holds the Magaav credential: git -C <its checkout> push " .. origin .. " " ..
        sha .. ":refs/heads/main   (this node has no GitHub credential and must not be given one)" }
  end
  local readback = remote_tip(tree, origin, "refs/heads/main")
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
  local gh = M.exec("command -v gh >/dev/null 2>&1 && echo yes || echo no", "", 60)
  local tag = "node-" .. sha:sub(1, 12)
  if trim(gh.stdout) ~= "yes" then
    return false, { error = "publish_needs_credentials", detail = "the release `" .. tag .. "` was not published",
      observed = "no `gh` on this machine, so the release cannot be created here",
      next = "publish from the machine that holds the token: git fetch " .. M.incoming() .. " refs/heads/" ..
        artifacts.ref .. ":refs/heads/" .. artifacts.ref .. " && git worktree add /tmp/" .. tag .. " " ..
        artifacts.ref .. " && bash /tmp/" .. tag .. "/PUBLISH.sh" }
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
  local existing = M.exec("gh release view " .. quote(tag) .. " >/dev/null 2>&1 && echo present || echo absent", "", 120)
  if trim(existing.stdout) == "present" then
    evidence("release " .. tag .. " already exists; not published again\n")
    run.journal.publish = { tag = tag, state = "already_present", signed = true, key_id = artifacts.key_id }
    return true, { detail = "release " .. tag .. " already published (not repeated)" }
  end
  local published = M.exec("bash " .. quote(scratch .. "/PUBLISH.sh"), scratch, 1800)
  evidence(command_line("publish", "bash " .. scratch .. "/PUBLISH.sh"))
  evidence((published.stdout or "") .. (published.stderr or ""))
  if (published.code or 1) ~= 0 then
    return false, { error = "publish_failed", observed = first_line(published.stderr ~= "" and published.stderr or published.stdout),
      next = "the publisher's own words are in " .. M.evidence_path(run.id, "publish") }
  end
  run.journal.publish = { tag = tag, state = "published", signed = true, key_id = artifacts.key_id }
  return true, { detail = "release " .. tag .. " published (signed, key " .. tostring(artifacts.key_id) .. ")" }
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
  local function ask(node, mode_, why)
    local row = { node = node, mode = mode_, commit = sha, started_at = now() }
    evidence(string.format("deploy %s (%s) -> %s\n", node, mode_, tostring(sha)))
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
  for _, name in ipairs(M.STEPS) do
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
  for _, name in ipairs(M.STEPS) do
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

-- The newest run that is not finished: what `--resume` continues.
local function newest_unfinished()
  local listing = M.exec("ls -1dt " .. quote(M.root() .. "/*/journal.json") .. " 2>/dev/null | head -20", "", 60)
  for path in tostring(listing.stdout or ""):gmatch("[^\r\n]+") do
    local journal = json_file(trim(path))
    if journal and journal.run and journal.result ~= "done" and journal.result ~= "stopped" then
      return tostring(journal.run)
    end
    if journal and journal.run and journal.result == "stopped" then return tostring(journal.run) end
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
  if passed then
    print("land: " .. name .. ": " .. tostring(step.state) .. (step.detail and (" - " .. tostring(step.detail):gsub("\n", " ")) or ""))
  else
    print("land: " .. name .. ": STOPPED (" .. tostring(step.state) .. "): " .. tostring(step.detail or step.error or ""))
    if step.evidence then print("land: evidence: " .. step.evidence) end
    if step.next then print("land: next: " .. step.next) end
  end
  return passed
end

function M.run(options)
  options = type(options) == "table" and options or {}
  if options.resume and not options.run then
    options.run = newest_unfinished()
    if not options.run then
      print("land: nothing to resume: no unfinished run under " .. M.root())
      return 1
    end
  end
  local run = open_run(options)
  if run.fresh and not options.run then
    run.journal.branches = {}
  end
  if options.run and not run.fresh then
    print("land: resuming run " .. run.id .. " (journal " .. M.journal_path(run.id) .. ")")
  end
  if options.dry_run then return M.dry_run(run, options) end
  run.journal.result = "in_progress"
  save(run)
  local stopped = nil
  for _, name in ipairs(M.STEPS) do
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
      elseif name == "deploy" and options.no_deploy then
        step.state, step.detail = "skipped", "skipped: --no-deploy"
        save(run)
        print("land: deploy: skipped (--no-deploy)")
      else
        local ok = M.run_step(run, name, options)
        if not ok then stopped = name break end
      end
    end
  end
  if stopped then
    local step = step_of(run.journal, stopped)
    run.journal.result = step.state == "flaky" and "stopped" or "stopped"
    run.journal.stopped_at = stopped
    run.journal.stop_detail = tostring(step.detail or step.error or "")
    save(run)
    -- The report still runs: a stop without a summary is what this file exists to end.
    if stopped ~= "report" then M.run_step(run, "report", options) end
    print("")
    print(string.format("land: STOPPED at %s: %s", stopped, tostring(step.detail or step.error or "")))
    print("land: evidence: " .. tostring(step.evidence or "-"))
    print("land: report: " .. M.report_path(run.id))
    print("land: continue with: wa land --resume")
    return 1
  end
  run.journal.result = "done"
  run.journal.stopped_at = nil
  save(run)
  print(string.format("land: done (run %s, landed %s)", run.id, tostring(run.journal.tree_commit or ""):sub(1, 12)))
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
    print(M.plan_text({ plan = plan }))
    for _, note in ipairs(notes or {}) do print("land:   note: " .. note) end
  else
    print("land: plan: cannot be made without a fetch - " .. table.concat(notes or { "no base" }, "; "))
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

-- ---------------------------------------------------------------- `wa land status` / `ready`

function M.status_text(journal)
  local lines = { string.format("run %s: %s%s", tostring(journal.run), tostring(journal.result),
    journal.stopped_at and (" at " .. tostring(journal.stopped_at)) or "") }
  for _, name in ipairs(M.STEPS) do
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
  return true, replaced and "recorded (replaced the line)" or "recorded"
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
    elseif flag == "--branches" then
      local value = read_value(flag); if not value then return 2 end
      options.branches = split(value); index = index + 2
    elseif flag == "--ready" then options.ready = true; index = index + 1
    elseif flag == "--dry-run" then options.dry_run = true; index = index + 1
    elseif flag == "--full" then options.full = true; index = index + 1
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
      print("wa land --ready | --branches a,b [--dry-run] [--no-deploy] [--full] [--resume] [--run <id>]")
      print("wa land --rollback                 put every node's kept pair back (reverse ring order)")
      print("wa land status [--run <id>]        the journal, read-only")
      print("wa land ready <branch> <sha> [--brief <file>]   record a READY line for a finished branch")
      print("  --repo <dir> --incoming <remote> --origin <remote> --ring node:mode,... --json")
      print("  --canary <node> --account <node>  which node goes first (default work) and last (default openclaw)")
      print("  --full                 ignore the plan: run every step, even the ones this round does not need")
      print("  --signer <node|local>   where the release is signed (default: the node whose WA_VAULT_ADMIN_URL is set)")
      return 0
    else
      print("wa land: unknown option " .. flag .. "; nothing was done")
      return 2
    end
  end
  if options.status then
    local id = options.run
    if not id then id = newest_unfinished() end
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
  if not options.branches and not options.ready and not options.resume and not options.run and not options.rollback then
    print("wa land: nothing named. Use --ready (the ready box), --branches a,b, --resume, or --rollback.")
    print("wa land --help")
    return 2
  end
  return M.run(options)
end

return M
