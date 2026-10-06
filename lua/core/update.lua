-- `/update`: deploy this node's own tree through the gate.
--
-- The node cannot replace itself. The stop is the last command a run executes, and `deploy.sh` /
-- `upgrade.sh` refuse to run inside a run for exactly that reason. So nothing here updates
-- anything: it answers whether there is a runtime tree, whether the sentinel that could perform the
-- deploy is installed, and whether the tree is in a state the gate will accept - and, when the
-- answer is "deploy it", writes exactly one request into the sentinel's drop-box. The sentinel
-- performs it when the node is idle.
--
-- The request is a *deploy*, not an `upgrade --binary`, and that distinction is the whole of it: an
-- upgrade installs the node and the UI, while a deploy builds, runs the full test suite, and installs
-- the node, the UI, the sentinel, the scripts and the job templates, recording a commit it verified.
-- `/update` used to write the upgrade form, and that left a mixed install behind - measured: a new
-- binary with the scripts of an older install, one of them (`deploy.sh`) ten lines behind the tree,
-- and a record whose commit was only a hint (`source_provenance=unverified-binary`).
--
-- Which is why the answer says `queued` and never `updated`. A queued request that never appears
-- in the sentinel's `done/` did not happen, and a command that says "updated" before that is a
-- claim nobody can support. `next` always says where the record will land.
--
-- The decision is a pure function of the facts, so it is testable without a tree, a build or a
-- sentinel: `M.verdict(facts)` takes what was observed and returns what to say.
local M = {}

local json = dofile("lua/vendor/json.lua")
local platform = dofile("lua/core/platform.lua")
local paths = dofile("lua/core/paths.lua")

-- The sentinel owns the other side of replacement, so it is also the only actor that can prove the
-- new node came back before resuming the conversation. Keep this server-owned: a browser may choose
-- which of its threads to continue, but it may not inject a different post-deploy instruction.
M.CONTINUATION_PROMPT = "The update request settled; report its result, verify the node if it changed, and continue this session."

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function slashes(path)
  -- A recorded Windows path (`C:\a\b`) is unusable by the POSIX shell this node runs commands in,
  -- and `\` inside a single-quoted word is a literal backslash that bash then hands to a native
  -- git as an escape. Forward slashes are read by both.
  return (tostring(path or ""):gsub("\\", "/"))
end

local function quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function first_line(text)
  return (tostring(text or ""):match("^%s*([^\r\n]*)") or "")
end

local function read(path)
  if not path then return nil end
  local ok, text = pcall(host.read_file, path)
  return (ok and text) or nil
end

local function exists(path)
  if not path or path == "" then return false end
  -- Answered WITHOUT reading the file. `read` goes through `host.read_file`, which is
  -- `std::fs::read_to_string`: it decodes UTF-8, so reading a compiled binary always fails and returns
  -- nil. This module asked "is anything built?" and "is the sentinel installed?" by reading exactly those
  -- binaries, so it reported `nothing_built` while its own build sat in the tree, and no /update could
  -- install anything on any machine. A shell test asks the same question and never looks at the bytes.
  -- `host.exec` returns the operation wrapper as JSON, whose `code` says whether the command succeeded.
  if not host.exec then return read(path) ~= nil end
  local ok, raw = pcall(host.exec, "test -s \"" .. tostring(path) .. "\"", "")
  if not ok or type(raw) ~= "string" then return read(path) ~= nil end
  return raw:find('"code":0', 1, true) ~= nil
end

local function shell(command)
  local ok, raw = pcall(host.exec, command, "")
  if not ok then return nil end
  local ok2, decoded = pcall(json.decode, raw)
  return (ok2 and type(decoded) == "table") and decoded or nil
end

local function lines(text)
  local count = 0
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if trim(line) ~= "" then count = count + 1 end
  end
  return count
end

-- ---- who can perform a request ---------------------------------------------

-- `wa-sentinel request` writes a file and returns. The *watcher* is what performs it, so a request
-- written while no watcher is running is a claim with no actor - and that is the shape this file used
-- to report as `queued`. Measured on this machine: a deploy request sat in the box for over an hour
-- while the install stayed on the old commit, and the command that wrote it had already said the
-- sentinel would deploy the tree.
--
-- The sentinel proves its own OS-held lifetime lock without asking this node's
-- health route. Unknown/legacy identity is a refusal, never a recycled-PID claim.
local function watcher_probe(binary)
  local result = shell(quote(binary) .. " preflight")
  if not result or result.code ~= 0 then return nil, result and trim(result.stderr or result.stdout) or "preflight unavailable" end
  local ok, probe = pcall(json.decode, result.stdout or "")
  if not ok or type(probe) ~= "table" or probe.schema ~= 1 or probe.ownership ~= "watcher_lifetime_lock" or
     not probe.capabilities or not probe.capabilities.health_free or not probe.capabilities.atomic_deploy_dedupe then
    return nil, "sentinel lacks verified health-free preflight and atomic deploy admission"
  end
  return probe
end

-- ---- where things are ------------------------------------------------------

-- The install directory, by the same rule the sentinel uses to find the node it restarts. The two
-- disagreeing about which binary is "the node" is the kind of bug that reads as a working update.
function M.install_dir()
  local explicit = host.getenv and host.getenv("WA_INSTALL_DIR")
  if explicit and explicit ~= "" then return slashes(explicit) end
  if platform.os() == "windows" then
    local base = host.getenv and host.getenv("LOCALAPPDATA")
    if base and base ~= "" then return slashes(base) .. "/wasm-agent" end
  end
  return slashes(paths.home()) .. "/.local/bin"
end

function M.binary_name() return platform.os() == "windows" and "wa.exe" or "wa" end

function M.sentinel_name() return platform.os() == "windows" and "wa-sentinel.exe" or "wa-sentinel" end

-- The tree this node is running from. `runtime-worktree.txt` is written at install time and is the
-- authority; a node started straight out of a checkout (dev mode) has no such record, and there the
-- working directory is the only evidence there is. It says which one it used rather than implying
-- the first.
function M.runtime_tree(install)
  local recorded = trim(first_line(read(install .. "/runtime-worktree.txt")))
  if recorded ~= "" then return slashes(recorded), "runtime-worktree.txt" end
  local cwd = slashes(platform.cwd())
  if cwd ~= "" and exists(cwd .. "/rust/Cargo.toml") then return cwd, "working-directory" end
  return nil, nil
end

local function git(tree, arguments)
  local result = shell("git -C " .. quote(tree) .. " " .. arguments .. " 2>/dev/null")
  if not result or result.code ~= 0 then return nil end
  return tostring(result.stdout or "")
end

local function installed_record(install)
  local record = {}
  for line in tostring(read(install .. "/installed.txt") or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then record[trim(key)] = trim(value) end
  end
  return record
end

-- ---- what was observed ------------------------------------------------------

-- Everything the verdict needs, gathered once. IO lives here and nowhere else, so `verdict` stays
-- a function a test can call with a table. `options.install` names the install directory explicitly,
-- which is what `WA_INSTALL_DIR` does for a node and what lets a test point the whole path - facts,
-- verdict and the request it writes - at a fixture instead of at the machine's real node.
function M.facts(options)
  local install = (options and options.install) or M.install_dir()
  -- The sentinel's own state directory: `<config>/sentinel` by the rule the sentinel uses to find its
  -- request box. `options.sentinel_dir` names it explicitly, the way `options.install` names the
  -- install, so a test can point the whole path at a fixture instead of at this machine's real state.
  local sentinel_dir = (options and options.sentinel_dir) or (slashes(paths.config()) .. "/sentinel")
  local facts = {
    install = install,
    binary = install .. "/" .. M.binary_name(),
    sentinel = install .. "/" .. M.sentinel_name(),
    sentinel_dir = sentinel_dir,
  }
  facts.tree, facts.tree_source = M.runtime_tree(install)
  if facts.tree then
    facts.candidate = facts.tree .. "/rust/target/release/" .. M.binary_name()
    facts.candidate_bytes = exists(facts.candidate) and 1 or nil
    local head = git(facts.tree, "rev-parse --short HEAD")
    facts.tree_commit = head and trim(head) or nil
    facts.dirty = lines(git(facts.tree, "status --porcelain")) or 0
  end
  local record = installed_record(install)
  facts.installed_commit = record.source_commit_hint or record.commit
  facts.installed_sha256 = record.sha256
  facts.installed_at = record.at
  facts.sentinel_present = exists(facts.sentinel)
  facts.stop_file = sentinel_dir .. "/stop"
  facts.pid_file = sentinel_dir .. "/sentinel.pid"
  facts.sentinel_stopped = exists(facts.stop_file)
  local probe, probe_error = watcher_probe(facts.sentinel)
  facts.sentinel_probe_error = probe_error
  facts.sentinel_pid = probe and probe.watcher_pid or nil
  facts.sentinel_running = probe and probe.watcher == "running" or false
  facts.sentinel_stopped = facts.sentinel_stopped or (probe and probe.stop_file) or false
  facts.pending_deploys = probe and probe.pending_deploys or {}
  facts.inventory_verified = probe and probe.inventory_verified == true or false
  facts.inventory_error = probe and probe.inventory_error or probe_error
  return facts
end

-- Bring the node-owned worktree to the source the deploy gate will build. `/update` used to queue
-- a deploy from whichever branch happened to be checked out; the gate then refused it after the
-- user had already been told it was queued. Only an explicit `/update` runs this, and only on a
-- clean tree. Switch to the worktree's own lane, fetch, and fast-forward when that is provably safe.
-- A diverged lane is reported for integration; it is never reset or force-moved.
function M.sync_source(tree, expected_branch)
  tree = slashes(tree)
  local branch = trim(git(tree, "branch --show-current") or "")
  if branch == "" then return { ok=false, error="detached_runtime_tree", observed="the runtime worktree has no checked-out branch" } end
  if expected_branch and branch ~= expected_branch then
    local switched = shell("git -C " .. quote(tree) .. " switch --quiet " .. quote(expected_branch) .. " 2>&1")
    if not switched or switched.code ~= 0 then
      return { ok=false, error="runtime_branch_mismatch", observed="expected branch " .. expected_branch .. "; current branch " .. branch ..
        (switched and trim(switched.stdout .. " " .. switched.stderr) or "") }
    end
    branch = expected_branch
  end

  local fetched = shell("git -C " .. quote(tree) .. " fetch --quiet origin 2>&1")
  if not fetched or fetched.code ~= 0 then
    return { ok=false, error="source_fetch_failed", observed=trim(fetched and (fetched.stderr ~= "" and fetched.stderr or fetched.stdout) or "git fetch returned no result") }
  end
  local counts = git(tree, "rev-list --left-right --count HEAD...origin/main")
  local ahead, behind = tostring(counts or ""):match("^(%d+)%s+(%d+)")
  ahead, behind = tonumber(ahead), tonumber(behind)
  if not ahead or not behind then
    return { ok=false, error="origin_main_unavailable", observed="origin/main is not available after fetching origin" }
  end
  if ahead > 0 then
    return { ok=false, error="runtime_branch_not_integrated", observed=branch .. " is " .. ahead .. " commit(s) ahead and " .. behind ..
      " commit(s) behind origin/main; the deploy gate requires the source commit to be integrated" }
  end
  if behind > 0 then
    -- What the node builds and then runs - as whatever user it runs as - is whatever origin/main says.
    -- With WASM_AGENT_UPDATE_REQUIRE_SIGNED=1 the commit must carry a signature git trusts
    -- (gpg.ssh.allowedSignersFile or the gpg keyring), so a push by someone who took over the account
    -- or the remote is not deployed to every node. Off by default: the history is not signed today.
    if tostring(host.getenv("WASM_AGENT_UPDATE_REQUIRE_SIGNED") or "") == "1" then
      local verified = shell("git -C " .. quote(tree) .. " verify-commit origin/main 2>&1")
      if not verified or verified.code ~= 0 then
        return { ok=false, error="unsigned_source", observed="origin/main does not carry a trusted signature: " ..
          trim(verified and (verified.stderr ~= "" and verified.stderr or verified.stdout) or "git verify-commit returned no result") }
      end
    end
    local merged = shell("git -C " .. quote(tree) .. " merge --ff-only --quiet origin/main 2>&1")
    if not merged or merged.code ~= 0 then
      return { ok=false, error="runtime_fast_forward_failed", observed=trim(merged and (merged.stderr ~= "" and merged.stderr or merged.stdout) or "git merge returned no result") }
    end
  end
  return { ok=true, branch=branch, behind=behind, synchronized=behind > 0 }
end

-- ---- the decision -----------------------------------------------------------

-- The check that was missing before a request is written: is there a watcher that can perform it?
-- `verdict` calls this immediately before it says "queued", and `run` calls it before it synchronizes
-- anything, so a request nothing can perform is refused *before* it is written and before the tree is
-- moved for it. Pure: every fact it reads is in the table.
--
-- Three refusals, each with the same shape as the rest of this module's answers, and each naming the
-- one command that changes it. Nothing here starts a watcher: an intentional stop must stay stopped,
-- and a second watcher must not be started beside a running one.
function M.preconditions(facts)
  if facts.sentinel_stopped then
    return {
      ok = false, status = "sentinel_stopped", error = "sentinel_stopped", tree = facts.tree,
      message = "the sentinel was stopped on purpose - its stop file is present - so a request nothing " ..
                "would perform was not queued.",
      observed = "stop file at " .. tostring(facts.stop_file),
      next = "start it when you want this deploy, then ask again: " .. M.start_command(facts) ..
             ". /update does not clear a stop you made.",
    }
  end
  if not facts.sentinel_running then
    return {
      ok = false, status = "no_watcher", error = "no_watcher", tree = facts.tree,
      message = "no sentinel watcher ownership was verified, so nothing can safely accept this deploy: the request " ..
                "was not queued.",
      observed = "no verified watcher ownership for " .. tostring(facts.pid_file) .. (facts.sentinel_probe_error and ("; " .. facts.sentinel_probe_error) or "") ..
                 ((facts.pending_deploys and #facts.pending_deploys > 0)
                   and ("; a deploy is already waiting there: " .. table.concat(facts.pending_deploys, ", "))
                   or ""),
      next = "inspect the watcher/service outside this node if identity or preflight is unverified; install the current sentinel through the deployment gate if needed, then start it and ask again: " .. M.start_command(facts),
    }
  end
  if facts.inventory_verified == false then
    return {ok=false,status="unknown_inventory",error="unknown_inventory",tree=facts.tree,
      message="pending sentinel intent could not be verified, so this update wrote nothing.",
      observed=tostring(facts.inventory_error or "inventory proof unavailable"),
      next="inspect and reconcile the named queued/claimed evidence outside this run; preserve uncertain effects before retrying"}
  end
  if facts.pending_deploys and #facts.pending_deploys > 0 then
    return {
      ok = false, status = "already_pending", error = "already_pending", tree = facts.tree,
      pending = facts.pending_deploys[1],
      message = "a deploy request is already waiting in the sentinel's box (" .. facts.pending_deploys[1] ..
                "), so this /update wrote nothing.",
      observed = #facts.pending_deploys .. " deploy request(s) waiting in " .. tostring(facts.sentinel_dir) .. "/requests",
      next = "let it run: the record lands in " .. tostring(facts.sentinel_dir) .. "/done/ or failed/, " ..
             "and " .. tostring(facts.sentinel_dir) .. "/sentinel.log says what happened to it",
    }
  end
  return nil
end

-- How to start a watcher that is not running, spelled out for the machine this is. The Windows task
-- is the one `scripts/install-sentinel-task.ps1` registers, and it is what starts the supervisor again
-- after a logon; the binary beside the node is what a human at a shell would run now.
function M.start_command(facts)
  local command = tostring(facts.sentinel) .. " start"
  if platform.os() == "windows" then
    command = command .. " (or the registered logon task: schtasks /Run /TN wasm-agent-sentinel)"
  end
  return command
end

-- Three answers and no others. Each carries `message` (one sentence for a human), `observed` (what
-- was seen) and - where there is somewhere to go - `next`.
--
-- There is no `nothing_built` answer any more, and no `already_current` one. Both belonged to the
-- older shape, where this module installed a build that already existed in the tree:
--
--   * a deploy *builds*, so "the tree has nothing built in it" is no longer a reason to refuse;
--   * and "the tree is at the installed commit" is no longer a reason to do nothing, because the
--     commit does not describe the install. Measured on this machine: `installed.txt` read
--     `commit=unknown` while the shipped `scripts/deploy.sh` was ten lines behind the tree, so a
--     short-circuit on the commit answered "nothing to do" about a node whose scripts were stale.
--     A deploy of the same commit is idempotent, and it is how the install is made to match the tree.
--
-- A dirty tree is refused here rather than queued: the gate refuses one, so a request would be
-- written only to fail. That is the one precondition this module checks, because it is the one it
-- already knows; the rest belong to `deploy.sh`, and two implementations of the same precondition
-- are two things to keep in step.
function M.verdict(facts)
  if not facts.tree then
    return {
      ok = false, status = "no_runtime_tree", error = "no_runtime_tree",
      message = "there is no tree to update from: this node has no runtime-worktree.txt and its working directory is not a checkout.",
      observed = "looked for " .. (facts.install or "?") .. "/runtime-worktree.txt and for rust/Cargo.toml in the working directory",
      next = "install this node with scripts/deploy.sh, or start it from its checkout (WASM_AGENT_LUA_ROOT / scripts/dev-agent.cmd)",
    }
  end
  if not facts.sentinel_present then
    return {
      ok = false, status = "no_sentinel", error = "no_sentinel", tree = facts.tree,
      message = "the sentinel is not installed beside this node, and it is the only process that can replace it.",
      observed = "no binary at " .. tostring(facts.sentinel),
      next = "a fresh install needs wa-sentinel beside wa (see skills/self-update); until then, run scripts/deploy.sh from outside the node",
    }
  end
  if (facts.dirty or 0) > 0 then
    return {
      ok = false, status = "tree_dirty", error = "tree_dirty", tree = facts.tree, dirty = facts.dirty,
      message = "this tree has " .. facts.dirty .. " uncommitted change(s) and the gate refuses a dirty tree, " ..
                "so a deploy would fail instead of installing.",
      observed = "git status --porcelain reported " .. facts.dirty .. " path(s) in " .. tostring(facts.tree),
      next = "commit or stash them, then ask again: a deploy installs a commit, not a working copy",
    }
  end
  -- The last question before the answer that costs something: a request nothing can perform must not
  -- be written, and an answer of "queued" must not be given for one.
  local blocked = M.preconditions(facts)
  if blocked then return blocked end
  return {
    ok = true, queued = true, status = "queue", tree = facts.tree,
    commit = facts.tree_commit or facts.installed_commit,
    dirty = 0,
    message = "queued: the sentinel will deploy this tree through the gate once the node is idle - " ..
              "build, the full test suite, then the node, UI, sentinel and scripts. This is not done yet.",
    observed = "the tree is at " .. tostring(facts.tree_commit) .. " with nothing uncommitted; " ..
               "the install records " .. tostring(facts.installed_commit) .. "; " ..
               (facts.sentinel_pid
                 and ("a watcher is running (pid " .. tostring(facts.sentinel_pid) .. ")")
                 or "a watcher answered as running"),
  }
end

-- ---- the only thing that acts -----------------------------------------------

local function reason_for(facts)
  local where = facts.tree or "an unknown tree"
  return trim("/update: deploy " .. where .. " through the gate")
end

-- The exact command line handed to the shell for a queued install. Pure, so a test can read it:
-- every path and the reason are single-quoted (this node runs commands through `bash -c`), and a
-- quote inside a reason must not be able to end the quoting early.
function M.request_command(facts, reason, continuation)
  -- A deploy, not an `upgrade --binary`: the gate builds the tree itself, so there is no candidate
  -- to name, and it is the only path that installs the sentinel, the scripts and the job templates
  -- and records a commit it verified.
  local command = {
    quote(facts.sentinel), "request", "deploy", "--if-no-pending",
    "--reason", quote(reason),
  }
  local session_id = trim(continuation and continuation.session_id)
  if session_id ~= "" then
    command[#command + 1] = "--session"
    command[#command + 1] = quote(session_id)
    command[#command + 1] = "--prompt"
    command[#command + 1] = quote(trim(continuation.prompt) ~= "" and continuation.prompt or M.CONTINUATION_PROMPT)
  end
  return table.concat(command, " ")
end

-- Gather, decide, and - only in the queueing case - write one request for the sentinel.
local function decorate(verdict, facts)
  verdict.tree = verdict.tree or facts.tree
  verdict.installed_commit = verdict.installed_commit or facts.installed_commit
  verdict.candidate = facts.candidate
  verdict.installed_sha256 = facts.installed_sha256
  verdict.installed_at = facts.installed_at
  return verdict
end

function M.run(options)
  options = options or {}
  local facts = M.facts(options)
  -- Asked before the tree is synchronized: a request no watcher can perform is refused without moving
  -- the runtime worktree for it, and without writing anything.
  local blocked = M.preconditions(facts)
  if blocked then return decorate(blocked, facts) end
  if facts.tree and (facts.dirty or 0) == 0 and not options.skip_source_sync then
    local name = facts.tree:match("([^/]+)$") or ""
    local expected = name == "wasm-agent" and "main" or name
    local synced = M.sync_source(facts.tree, expected)
    if not synced.ok then
      local reason = synced.error == "runtime_branch_not_integrated"
        and "integrate this worktree's commits into main, then ask again"
        or "repair the runtime worktree or its origin/main connection, then ask again"
      return {
        ok=false, status="source_sync_failed", error=synced.error,
        tree=facts.tree, observed=synced.observed,
        message="the runtime source could not be synchronized safely, so no deploy was queued.",
        next=reason, installed_commit=facts.installed_commit, candidate=facts.candidate,
        installed_sha256=facts.installed_sha256, installed_at=facts.installed_at,
      }
    end
    facts = M.facts(options)
  end
  local verdict = decorate(M.verdict(facts), facts)
  if verdict.status ~= "queue" then
    return verdict
  end

  -- The new binary migrates the schema when it starts, and an older one refuses a migrated database:
  -- take a checked snapshot of every store first, or do not deploy. (MEMORY.md used to ask the
  -- operator to remember this.)
  if not options.skip_backup then
    local backed, snapshot = pcall(function() return dofile("lua/core/backup.lua").run("pre-update") end)
    if not backed then
      verdict.ok, verdict.queued, verdict.status = false, nil, "backup_failed"
      verdict.error = "backup_failed"
      verdict.observed = tostring(snapshot)
      verdict.next = "free disk space or repair the store named above, then ask again; nothing was deployed"
      return verdict
    end
    verdict.backup = snapshot.dir
  end

  local reason = trim(options.reason or "")
  if reason == "" then
    reason = reason_for(facts)
  else
    reason = "/update: " .. reason
  end
  local session_id = trim(options.session_id)
  local command = M.request_command(facts, reason, {
    session_id = session_id,
    prompt = M.CONTINUATION_PROMPT,
  })
  local result = shell(command)
  if not result then
    verdict.ok, verdict.queued, verdict.status = false, nil, "sentinel_unreachable"
    verdict.error = "sentinel_unreachable"
    verdict.observed = "calling " .. facts.sentinel .. " produced no answer"
    verdict.next = "run it by hand outside the node: " .. command
    return verdict
  end
  if (result.code or 0) ~= 0 then
    local detail = trim(result.stderr or "") ~= "" and trim(result.stderr) or trim(result.stdout or "")
    verdict.ok, verdict.queued, verdict.status = false, nil, "sentinel_refused"
    verdict.error = "sentinel_refused"
    verdict.observed = "the sentinel exited " .. tostring(result.code) .. ": " .. detail
    verdict.next = "read its log (" .. (facts.sentinel_dir or (slashes(paths.config()) .. "/sentinel")) ..
                   "/sentinel.log); a refusal is logged there with its reason"
    return verdict
  end
  local output = tostring(result.stdout or "")
  local existing = output:match("existing deploy request:%s*([^\r\n]+)")
  if existing then
    verdict.ok, verdict.queued, verdict.status, verdict.error = false, nil, "already_pending", "already_pending"
    verdict.pending = existing
    verdict.message = "a deploy was admitted concurrently, so this /update wrote nothing."
    verdict.observed = existing
    return verdict
  end
  verdict.request = output:match("requested[^:]*:%s*([^\r\n]+)")
  if not verdict.request then
    verdict.ok, verdict.queued, verdict.status, verdict.error = false, nil, "sentinel_unverifiable", "sentinel_unverifiable"
    verdict.observed = "sentinel exited successfully without naming a durable request"
    verdict.next = "inspect the sentinel request box and log before retrying"
    return verdict
  end
  verdict.sentinel = trim(first_line(output))
  -- The stop file was checked before the request was written, so this is the race it cannot close: a
  -- stop that appeared in between. The request is on disk and will be performed by whoever starts the
  -- watcher next - say so rather than let it look like a deploy in flight.
  if facts.sentinel_stopped then
    verdict.warning = "the sentinel's stop file exists, so nothing will happen until it is started again (wa-sentinel start)"
  end
  local sentinel_dir = facts.sentinel_dir or (slashes(paths.config()) .. "/sentinel")
  verdict.next = "the sentinel performs it when this node is idle. The record lands in " ..
                 sentinel_dir .. "/done/ or failed/, and installed.txt records the commit it installed."
  verdict.reason = reason
  if session_id ~= "" then verdict.continuation_session = session_id end
  verdict.message = "queued: the sentinel will deploy " .. tostring(verdict.commit or "this tree") ..
                    " through the gate once this node is idle. This is not done yet."
  if session_id ~= "" then
    verdict.next = verdict.next .. " After it settles, the sentinel will wake this session to report the result and continue."
  end
  return verdict
end

return M
