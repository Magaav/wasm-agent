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
--     `gh`, a reviewer that is not on main) is recorded `blocked` or `skipped` with the exact command that
--     would finish it - never as done.
--
-- WHAT IT DOES NOT DO. It invents no review, no signature, no publish and no deployment. Where a channel
-- is not on main yet the step stands in the journal as a TODO naming the file it looks for and the test
-- that enables it.
--
--   wa land --ready                    land every branch with a `READY <branch> <sha>` line
--   wa land --branches a,b             land exactly these branches
--   wa land --dry-run                  print the plan and every command; change nothing
--   wa land --no-deploy                land and publish, deploy nothing
--   wa land --resume                   continue the newest unfinished run from its failed step
--   wa land --run <id> --resume        continue that run
--   wa land status [--run <id>]        the journal as text (read-only)
--   wa land ready <branch> <sha>       record a READY line for an agent's finished branch
--
-- The runner is one seam (`M.exec`) so a test can script git, the gate and the nodes without a network, a
-- compiler or a fleet; production uses the host's own `exec`.
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

-- ---------------------------------------------------------------- the steps, in order
--
-- Data, so a reader can check the order against the mission and a test can assert it: merge, gate, push
-- the landed tip, fast-forward main, build and verify the artifacts, publish, deploy. `report` is last and
-- runs even when the machine stopped, because a stop without a report is the thing this file exists to
-- end.
M.STEPS = { "collect", "review", "merge", "gate", "push", "main", "artifacts", "publish", "deploy", "report" }

-- The two channels the mission names as conditional. Both are looked up in the LANDED TREE, so "is it on
-- main" is answered by the tree being landed and not by this machine's opinion.
M.REVIEW_SCRIPT = "scripts/review-branch.mjs"
M.SIGN_SCRIPT = "scripts/publish-sign.sh"

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
    for line in text:gmatch("[^\r\n]+") do
      local branch, sha = line:match("^%s*READY%s+(%S+)%s+(%x+)")
      if branch then wanted[#wanted + 1] = { name = branch, sha = sha } end
    end
    if #wanted == 0 then
      return false, { error = "ready_empty", observed = "no `READY <branch> <sha>` line in " .. box,
        next = "record one: wa land ready change/<name> <sha>" }
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
    branches[#branches + 1] = { name = want.name, sha = tip, ref = ref }
    evidence(string.format("%s -> %s (%s)\n", want.name, tip, ref))
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

-- review: the reviewer runs on each branch BEFORE it is merged, and its findings are reported without ever
-- blocking. The channel is not on main yet (change/reviewer), so the step detects it in the landed tree
-- instead of assuming it: absent means `skipped` plus a TODO naming the file and the test that turns it on.
impl.review = function(run, options)
  local evidence = sink(run, "review")
  local tree = M.repo()
  local base = run.journal.base
  local present = git(run, tree, "cat-file -e " .. quote(base .. ":" .. M.REVIEW_SCRIPT)).code == 0
  if not present then
    run.journal.todos[#run.journal.todos + 1] = {
      item = "reviewer", state = "not_on_main", looks_for = M.REVIEW_SCRIPT,
      test = "scripts/test-land.lua's reviewer case stands a fixture " .. M.REVIEW_SCRIPT ..
             " in a tree and asserts the findings reach the journal and never stop a landing",
      enable = "land change/reviewer, then this step runs " .. M.REVIEW_SCRIPT .. " on every branch before the merge",
    }
    return true, { state = "skipped", detail = "reviewer not on main (" .. M.REVIEW_SCRIPT .. " absent at " .. base:sub(1, 12) .. ")" }
  end
  local findings = {}
  for _, branch in ipairs(run.journal.branches) do
    local command = "node " .. M.REVIEW_SCRIPT .. " --branch " .. quote(branch.sha) .. " --base " .. quote(base) .. " --json"
    evidence(command_line("review " .. branch.name, command))
    local result = M.exec(command, tree, 1800)
    evidence((result.stdout or "") .. (result.stderr or ""))
    findings[#findings + 1] = { branch = branch.name, exit_code = result.code,
      findings = trim(result.stdout):sub(1, 4000) }
  end
  run.journal.review = findings
  return true, { detail = string.format("%d branch(es) reviewed (findings are reported, never blocking)", #findings) }
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
  local checks = options.checks or M.DEFAULT_CHECKS
  local decorator = M.weight()
  run.journal.gate_weight = decorator ~= "" and decorator or "none (no weight could be applied)"
  local rows = {}
  for _, check in ipairs(checks) do
    local command = (decorator ~= "" and (decorator .. " " .. quote(check.command))) or check.command
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

-- artifacts: build and verify the release artifacts, ship them to the incoming repository as
-- `artifacts/node-<sha12>`, and then prove the ref carries every file the shipped PUBLISH.sh names. That
-- last check is the one that was missing: on 13/11 the ref held PUBLISH.sh naming SHA256SUMS and did not
-- carry it, which would have failed the publish a human was instructed to run.
impl.artifacts = function(run, options)
  local evidence = sink(run, "artifacts")
  local tree, sha = run.tree, run.journal.tree_commit
  local incoming = M.incoming()
  local command = "bash scripts/publish-artifacts-branch.sh --remote " .. quote(incoming) .. " --commit " .. quote(sha)
  evidence(command_line("artifacts", command))
  local result = M.exec(command, slashes(tree), 5400)
  evidence((result.stdout or "") .. (result.stderr or ""))
  if (result.code or 1) ~= 0 then
    return false, { error = "artifacts_failed", observed = first_line(result.stderr ~= "" and result.stderr or result.stdout),
      next = "the publisher's own words are in " .. M.evidence_path(run.id, "artifacts") }
  end
  -- `PUBLISHREADY <ref> <artifacts commit> source=<landed commit>`: the ref carries an orphan commit of its
  -- own, so the two are compared separately - the artifacts commit is what was pushed, the source commit is
  -- the landing it was built from, and a reference built from a different tree is not this landing's release.
  local ref, artifacts_commit, source = tostring(result.stdout or ""):match("PUBLISHREADY%s+(%S+)%s+(%x+)%s+source=(%x+)")
  if not ref then
    return false, { error = "artifacts_unreadable",
      observed = "the publisher printed no PUBLISHREADY line",
      next = "inspect " .. M.evidence_path(run.id, "artifacts") }
  end
  if source ~= sha then
    return false, { error = "artifacts_wrong_commit",
      observed = "the artifacts reference names source " .. source:sub(1, 12) .. ", the landed tip is " .. sha:sub(1, 12) }
  end
  -- Read the ref back out of the remote and hold it to the files PUBLISH.sh names.
  local fetched = git(run, tree, "fetch --quiet " .. quote(incoming) .. " " .. quote("refs/heads/" .. ref), 600)
  evidence(command_line("fetch artifacts", "git fetch " .. incoming .. " refs/heads/" .. ref))
  evidence((fetched.stdout or "") .. (fetched.stderr or ""))
  if (fetched.code or 1) ~= 0 then
    return false, { error = "artifacts_not_readback", observed = "cannot fetch " .. ref .. " from " .. incoming }
  end
  local script = M.exec("git -C " .. quote(slashes(tree)) .. " show " .. quote("FETCH_HEAD:PUBLISH.sh"), slashes(tree), 120)
  if (script.code or 1) ~= 0 then
    return false, { error = "artifacts_no_publish_script", observed = ref .. " carries no PUBLISH.sh" }
  end
  local line = tostring(script.stdout or ""):match("gh release create[^\r\n]*")
  if not line then
    return false, { error = "artifacts_no_publish_line", observed = "the shipped PUBLISH.sh names no `gh release create`" }
  end
  local missing, named = {}, {}
  for word in (line .. " "):gmatch("(%S+)%s") do
    local name = word:gsub("^%./", "")
    if name:match("^[%w%._%-]+$") and not name:match("^node%-%x+%.manifest$") and
       (name:match("^wa%-") or name:match("^SHA256SUMS$") or name:match("%.manifest$")) then
      named[name] = true
      local check = git(run, tree, "cat-file -e " .. quote("FETCH_HEAD:" .. name), 120)
      if (check.code or 1) ~= 0 then missing[#missing + 1] = name end
    end
  end
  if #missing > 0 then
    return false, { error = "artifacts_incomplete",
      observed = ref .. " does not carry " .. table.concat(missing, ", ") .. " though its PUBLISH.sh names them",
      next = "fix scripts/publish-artifacts-branch.sh (the SHA256SUMS omission measured 13/11) and re-run this step" }
  end
  local count = 0
  for _ in pairs(named) do count = count + 1 end
  run.journal.artifacts = { ref = ref, commit = source, artifacts_commit = artifacts_commit, files = count }
  return true, { detail = string.format("%s %s carries all %d file(s) its PUBLISH.sh names", ref,
                  tostring(artifacts_commit):sub(1, 12), count) }
end

-- publish: the release. Two channels decide this step, and neither is assumed:
--   * signing - `scripts/publish-sign.sh` in the landed tree. Absent (change/sign is not on main) means the
--     step records the TODO and does not claim the release is signed.
--   * the credential - `gh`, on a machine allowed to hold one. Absent means `blocked` with the exact command
--     that publishes from the machine that has it.
impl.publish = function(run, options)
  local evidence = sink(run, "publish")
  local tree, sha = run.tree, run.journal.tree_commit
  local artifacts = run.journal.artifacts
  if not artifacts then
    return false, { error = "publish_without_artifacts", observed = "the artifacts step has not run" }
  end
  local signing = git(run, tree, "cat-file -e " .. quote(sha .. ":" .. M.SIGN_SCRIPT)).code == 0
  if signing then
    evidence("signing channel present: " .. M.SIGN_SCRIPT .. "\n")
  else
    run.journal.todos[#run.journal.todos + 1] = {
      item = "sign", state = "not_on_main", looks_for = M.SIGN_SCRIPT,
      test = "scripts/test-land.lua's signing case stands a fixture " .. M.SIGN_SCRIPT ..
             " in a tree and asserts publish runs it and records its signature",
      enable = "land change/sign, then this step signs the artifacts before publishing and nodes verify on install",
    }
    evidence("no " .. M.SIGN_SCRIPT .. " at " .. sha:sub(1, 12) .. ": the release will not be signed (change/sign is not on main)\n")
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
  if signing then
    local signed = M.exec("bash " .. M.SIGN_SCRIPT .. " " .. quote(artifacts.artifacts_commit or artifacts.commit), slashes(tree), 900)
    evidence(command_line("sign", "bash " .. M.SIGN_SCRIPT .. " " .. tostring(artifacts.artifacts_commit or artifacts.commit)))
    evidence((signed.stdout or "") .. (signed.stderr or ""))
    if (signed.code or 1) ~= 0 then
      return false, { error = "signing_failed", observed = first_line(signed.stderr ~= "" and signed.stderr or signed.stdout) }
    end
  end
  -- The artifacts commit is fetched again here rather than trusted from an earlier step: on a resume the
  -- artifacts step is `done` and its FETCH_HEAD died with the process that made it.
  local refetch = git(run, tree, "fetch --quiet " .. quote(M.incoming()) .. " " .. quote("refs/heads/" .. artifacts.ref), 600)
  evidence(command_line("refetch artifacts", "git fetch " .. M.incoming() .. " refs/heads/" .. artifacts.ref))
  evidence((refetch.stdout or "") .. (refetch.stderr or ""))
  if (refetch.code or 1) ~= 0 then
    return false, { error = "publish_no_artifacts_ref",
      observed = "cannot fetch " .. tostring(artifacts.ref) .. " from " .. M.incoming(),
      next = "git fetch " .. M.incoming() .. " refs/heads/" .. tostring(artifacts.ref) }
  end
  local scratch = M.run_dir(run.id) .. "/publish"
  local extract = M.exec("mkdir -p " .. quote(scratch) .. " && git -C " .. quote(slashes(tree)) .. " archive FETCH_HEAD | tar -x -C " .. quote(scratch), "", 300)
  evidence(command_line("extract", "git archive " .. artifacts.ref .. " | tar -x -C " .. scratch))
  evidence((extract.stdout or "") .. (extract.stderr or ""))
  if (extract.code or 1) ~= 0 then
    return false, { error = "publish_extract_failed", observed = first_line(extract.stderr ~= "" and extract.stderr or extract.stdout) }
  end
  local existing = M.exec("gh release view " .. quote(tag) .. " >/dev/null 2>&1 && echo present || echo absent", "", 120)
  if trim(existing.stdout) == "present" then
    evidence("release " .. tag .. " already exists; not published again\n")
    run.journal.publish = { tag = tag, state = "already_present" }
    return true, { detail = "release " .. tag .. " already published (not repeated)" }
  end
  local published = M.exec("bash " .. quote(scratch .. "/PUBLISH.sh"), scratch, 1800)
  evidence(command_line("publish", "bash " .. scratch .. "/PUBLISH.sh"))
  evidence((published.stdout or "") .. (published.stderr or ""))
  if (published.code or 1) ~= 0 then
    return false, { error = "publish_failed", observed = first_line(published.stderr ~= "" and published.stderr or published.stdout),
      next = "the publisher's own words are in " .. M.evidence_path(run.id, "publish") }
  end
  run.journal.publish = { tag = tag, state = "published", signed = signing }
  return true, { detail = "release " .. tag .. (signing and " (signed)" or " (unsigned: change/sign is not on main)") }
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
  local order = {}
  if options.rollback then
    for index = #ring, 1, -1 do order[#order + 1] = ring[index] end
  else
    for index = 1, #ring do order[#order + 1] = ring[index] end
  end
  local sha = run.journal.main_sha or run.journal.tree_commit
  local deadline = tonumber(options.deploy_timeout or (host.getenv and host.getenv("WA_LAND_DEPLOY_TIMEOUT")) or 900) or 900
  local poll = tonumber(options.deploy_poll or 5) or 5
  -- One node: ask it to update itself, then read its own record until it settles or the deadline passes.
  -- "Queued" is not installed - the row carries the peer's state and the record id an operator (or
  -- `wa update <node> --status`) reads next, and the first node that is not installed stops the ring.
  local function deploy_one(run_, node, mode_, sha_, options_, log)
    local started = now()
    local request = { commit = (not options_.rollback) and sha_ or nil, mode = mode_,
                      reason = "wa land " .. run_.id .. (options_.rollback and " rollback" or ""),
                      session = options_.session }
    log(string.format("deploy %s (%s) -> %s\n", node, mode_, tostring(sha_)))
    local reply = remote_update.request(M.call(), node, request)
    local row = { node = node, mode = mode_, commit = sha_,
                  state = tostring(reply and (reply.state or reply.status or reply.error) or "no_answer"),
                  record = reply and tostring(reply.record or "") }
    if not reply or reply.error then
      row.state = "refused"
      row.detail = reply and (tostring(reply.error) .. (reply.observed and (": " .. tostring(reply.observed)) or "")) or "no answer from the node"
      row.seconds = now() - started
      log(json.encode(row) .. "\n")
      return row, { error = "deploy_refused", detail = "node " .. node .. " (" .. mode_ .. "): " .. tostring(row.detail),
        observed = row.record ~= "" and ("record " .. row.record) or "",
        next = "inspect it: wa update " .. node .. " --status" .. (row.record ~= "" and (" --id " .. row.record) or "") }
    end
    local settle_at = now() + deadline
    local status = nil
    while true do
      status = remote_update.status(M.call(), node, { id = row.record, session = options_.session })
      local state = tostring(status and status.state or "unknown")
      if state == "installed" or state == "failed" or state == "silent" then break end
      if now() >= settle_at then break end
      log(string.format("  %s: %s\n", node, state))
      M.sleep(poll)
    end
    row.state = tostring(status and status.state or "unknown")
    row.installed_commit = status and status.installed_commit or nil
    row.verified = (status and status.verified == true) or false
    row.detail = status and status.detail or nil
    row.seconds = now() - started
    log(json.encode(row) .. "\n")
    if row.state ~= "installed" then
      return row, { error = "deploy_failed",
        detail = string.format("node %s (%s) is %s after %ss: %s", node, mode_, row.state, tostring(row.seconds), tostring(row.detail or "")),
        observed = row.record ~= "" and ("record " .. row.record) or "",
        next = "read the node's own records (installed.txt, the sentinel's done/failed) and the evidence in " ..
          M.evidence_path(run_.id, "deploy") .. "; then `wa land --resume` continues at this step" }
    end
    return row, nil
  end
  run.journal.deploy = run.journal.deploy or {}
  -- What an earlier attempt of THIS run already installed at THIS commit is not installed again: a resume
  -- continues at the node that failed, which is the whole point of the journal.
  local settled_nodes = {}
  for _, row in ipairs(run.journal.deploy) do
    if row.state == "installed" and (row.commit == sha or row.installed_commit == sha) then settled_nodes[row.node] = true end
  end
  for _, entry in ipairs(order) do
    local mode = options.rollback and "rollback" or (entry.mode or "tree")
    if settled_nodes[entry.node] and not options.rollback then
      evidence("deploy " .. entry.node .. ": already installed at " .. tostring(sha) .. " in this run; not asked again\n")
      print("land: deploy: " .. entry.node .. " already installed in this run")
    else
      local row, failure = deploy_one(run, entry.node, mode, sha, options, evidence)
      run.journal.deploy[#run.journal.deploy + 1] = row
      save(run)
      if failure then return false, failure end
    end
  end
  return true, { detail = string.format("%d node(s) %s", #order, options.rollback and "rolled back" or "installed") }
end

-- report: one summary, written to a file and printed. It runs even when the machine stopped, because the
-- thing it is for is a human reading what happened.
impl.report = function(run, options)
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
    add("| artifacts | `" .. tostring(journal.artifacts.ref) .. "` `" .. tostring(journal.artifacts.commit or ""):sub(1, 12) .. "` |")
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
    add("| node | mode | state | seconds | detail |")
    add("| --- | --- | --- | --- | --- |")
    for _, row in ipairs(journal.deploy) do
      add(string.format("| %s | %s | %s | %s | %s |", tostring(row.node), tostring(row.mode), tostring(row.state),
        tostring(row.seconds or "-"), tostring(row.detail or ""):gsub("|", "/"):sub(1, 160)))
    end
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
      if name == "deploy" and options.no_deploy then
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
  for _, check in ipairs(options.checks or M.DEFAULT_CHECKS) do
    print(string.format("  gate %-22s %s", check.name, check.command))
  end
  local tree = run.tree or (M.run_dir(run.id) .. "/tree")
  print("  merge        git worktree add -b <land N>/final " .. tree .. " <base>; one --no-ff merge per branch")
  print("  push         git push " .. M.incoming() .. " HEAD:refs/heads/<land N>/final")
  print("  main         git push " .. M.origin() .. " <landed>:refs/heads/main")
  print("  artifacts    bash scripts/publish-artifacts-branch.sh --remote " .. M.incoming() .. " --commit <landed>")
  print("  publish      bash <artifacts ref>/PUBLISH.sh")
  for _, entry in ipairs(M.ring(options)) do
    print(string.format("  deploy       wa update %-12s (%s)", entry.node, entry.mode))
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

function M.ready_mark(branch, sha)
  if type(branch) ~= "string" or branch == "" or branch:find("%s") then
    return false, "branch_invalid"
  end
  if type(sha) ~= "string" or not sha:match("^%x+$") or #sha < 7 then
    return false, "sha_invalid"
  end
  local existing = read(M.ready_file()) or ""
  for line in existing:gmatch("[^\r\n]+") do
    local name = line:match("^%s*READY%s+(%S+)")
    if name == branch then return true, "already recorded" end
  end
  local wrote = write(M.ready_file(), existing .. (existing ~= "" and not existing:match("\n$") and "\n" or "") ..
    "READY " .. branch .. " " .. sha .. "\n")
  if not wrote then return false, "ready_box_unwritable: " .. M.ready_file() end
  return true, "recorded"
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
        print("wa land ready needs a branch and a sha: wa land ready change/<name> <sha>")
        return 2
      end
      local ok, answer = M.ready_mark(branch, sha)
      print("wa land ready: " .. tostring(answer) .. (ok and (" - " .. branch .. " " .. sha) or ""))
      return ok and 0 or 1
    elseif flag == "--branches" then
      local value = read_value(flag); if not value then return 2 end
      options.branches = split(value); index = index + 2
    elseif flag == "--ready" then options.ready = true; index = index + 1
    elseif flag == "--dry-run" then options.dry_run = true; index = index + 1
    elseif flag == "--no-deploy" then options.no_deploy = true; index = index + 1
    elseif flag == "--rollback" then options.rollback = true; index = index + 1
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
      print("wa land --ready | --branches a,b [--dry-run] [--no-deploy] [--resume] [--run <id>]")
      print("wa land --rollback                 put every node's kept pair back (reverse ring order)")
      print("wa land status [--run <id>]        the journal, read-only")
      print("wa land ready <branch> <sha>       record a READY line for a finished branch")
      print("  --repo <dir> --incoming <remote> --origin <remote> --ring node:mode,... --json")
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
