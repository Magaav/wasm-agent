-- `/update`: install the newest build of this node's own tree.
--
-- The node cannot replace itself. The stop is the last command a run executes, and `deploy.sh` /
-- `upgrade.sh` refuse to run inside a run for exactly that reason. So nothing here updates
-- anything: it answers three questions - is there a runtime tree, is anything *built* in it, is
-- that build newer than what is installed - and, when the answer is "install it", writes exactly
-- one request into the sentinel's drop-box. The sentinel performs it when the node is idle.
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
  return read(path) ~= nil
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
    facts.candidate_bytes = read(facts.candidate) and #read(facts.candidate) or nil
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

-- Four answers and no others. Each carries `message` (one sentence for a human), `observed` (what
-- was seen) and - where there is somewhere to go - `next`.
function M.verdict(facts)
  if not facts.tree then
    return {
      ok = false, status = "no_runtime_tree", error = "no_runtime_tree",
      message = "there is no tree to update from: this node has no runtime-worktree.txt and its working directory is not a checkout.",
      observed = "looked for " .. (facts.install or "?") .. "/runtime-worktree.txt and for rust/Cargo.toml in the working directory",
      next = "install this node with scripts/deploy.sh, or start it from its checkout (WASM_AGENT_LUA_ROOT / scripts/dev-agent.cmd)",
    }
  end
  if facts.candidate_bytes == nil then
    return {
      ok = false, status = "nothing_built", error = "nothing_built", tree = facts.tree,
      message = "the tree has nothing built in it, so there is nothing to install: " .. facts.tree .. ".",
      observed = "no binary at " .. tostring(facts.candidate),
      next = "build it first: cd " .. facts.tree .. "/rust && cargo build --release --offline",
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
  if facts.tree_commit and facts.installed_commit
     and facts.tree_commit == facts.installed_commit and (facts.dirty or 0) == 0 then
    return {
      ok = true, changed = false, status = "already_current", tree = facts.tree,
      commit = facts.tree_commit,
      message = "nothing to do: this node already runs commit " .. facts.tree_commit ..
                ", which is what its tree is at (and the tree is clean).",
      observed = "installed records " .. tostring(facts.installed_commit) ..
                 "; the tree is at " .. tostring(facts.tree_commit) .. " with nothing uncommitted",
      next = "nothing. Edit the tree (or pull main) and ask again.",
    }
  end
  return {
    ok = true, queued = true, status = "queue", tree = facts.tree,
    commit = facts.tree_commit or facts.installed_commit,
    dirty = facts.dirty or 0,
    message = "queued: the sentinel will install the build in this tree once the node is idle. " ..
              "This is not done yet - its record is what settles it.",
    -- A dirty tree is installable (that is what the sentinel records a hash for) but it is not
    -- shippable by the gate, and saying so here is the difference between a reader knowing that and
    -- finding out later from a binary that does not match any commit.
    warning = ((facts.dirty or 0) > 0) and
      ("the tree has " .. facts.dirty .. " uncommitted file(s): scripts/deploy.sh would refuse it, " ..
       "and the hash the sentinel installs - not the commit - is what describes the binary") or nil,
  }
end

-- ---- the only thing that acts -----------------------------------------------

local function reason_for(facts)
  local where = facts.tree or "an unknown tree"
  local suffix = ""
  if (facts.dirty or 0) > 0 then
    suffix = " (the tree has " .. facts.dirty .. " uncommitted file(s), so the binary is the truth, not the commit)"
  end
  return trim("/update: install the build in " .. where .. suffix)
end

-- The exact command line handed to the shell for a queued install. Pure, so a test can read it:
-- every path and the reason are single-quoted (this node runs commands through `bash -c`), and a
-- quote inside a reason must not be able to end the quoting early.
function M.request_command(facts, reason)
  return table.concat({
    quote(facts.sentinel), "request", "upgrade",
    "--binary", quote(facts.candidate),
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
                 slashes(paths.config()) .. "/sentinel/done/ or failed/, and installed.txt records the hash it installed."
  verdict.reason = reason
  verdict.message = "queued: the sentinel will install " .. tostring(verdict.commit or "the built binary") ..
                    " once this node is idle. This is not done yet."
  return verdict
end

return M
