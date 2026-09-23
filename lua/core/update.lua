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
  local facts = {
    install = install,
    binary = install .. "/" .. M.binary_name(),
    sentinel = install .. "/" .. M.sentinel_name(),
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
  facts.sentinel_stopped = exists(slashes(paths.config()) .. "/sentinel/stop")
  return facts
end

-- ---- the decision -----------------------------------------------------------

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
  return {
    ok = true, queued = true, status = "queue", tree = facts.tree,
    commit = facts.tree_commit or facts.installed_commit,
    dirty = 0,
    message = "queued: the sentinel will deploy this tree through the gate once the node is idle - " ..
              "build, the full test suite, then the node, UI, sentinel and scripts. This is not done yet.",
    observed = "the tree is at " .. tostring(facts.tree_commit) .. " with nothing uncommitted; " ..
               "the install records " .. tostring(facts.installed_commit),
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
function M.request_command(facts, reason)
  -- A deploy, not an `upgrade --binary`: the gate builds the tree itself, so there is no candidate
  -- to name, and it is the only path that installs the sentinel, the scripts and the job templates
  -- and records a commit it verified.
  return table.concat({
    quote(facts.sentinel), "request", "deploy",
    "--reason", quote(reason),
  }, " ")
end

-- Gather, decide, and - only in the queueing case - write one request for the sentinel.
function M.run(options)
  options = options or {}
  local facts = M.facts(options)
  local verdict = M.verdict(facts)
  verdict.tree = verdict.tree or facts.tree
  verdict.installed_commit = verdict.installed_commit or facts.installed_commit
  verdict.candidate = facts.candidate
  verdict.installed_sha256 = facts.installed_sha256
  verdict.installed_at = facts.installed_at
  if verdict.status ~= "queue" then
    return verdict
  end

  local reason = trim(options.reason or "")
  if reason == "" then
    reason = reason_for(facts)
  else
    reason = "/update: " .. reason
  end
  local command = M.request_command(facts, reason)
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
    verdict.next = "read its log (" .. slashes(paths.config()) .. "/sentinel/sentinel.log); a refusal is logged there with its reason"
    return verdict
  end
  local output = tostring(result.stdout or "")
  verdict.request = output:match("requested[^:]*:%s*([^\r\n]+)")
  verdict.sentinel = trim(first_line(output))
  if facts.sentinel_stopped then
    verdict.warning = "the sentinel's stop file exists, so nothing will happen until it is started again (wa-sentinel start)"
  end
  verdict.next = "the sentinel performs it when this node is idle. The record lands in " ..
                 slashes(paths.config()) .. "/sentinel/done/ or failed/, and installed.txt records the commit it installed."
  verdict.reason = reason
  verdict.message = "queued: the sentinel will deploy " .. tostring(verdict.commit or "this tree") ..
                    " through the gate once this node is idle. This is not done yet."
  return verdict
end

return M
