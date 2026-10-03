-- `wa status`: one compact health line per fact.
--
-- Facts only, and none of them costs a network round trip: a health probe that
-- calls the provider hangs exactly when the provider is the thing that is
-- broken. Identity, provider config, the current thread, the working tree and
-- the config path are all readable locally.
--
-- Each fact is its own function returning a string, so a caller (the CLI, the
-- smoke test) can assert a fact without parsing the rendered lines.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local paths = dofile("lua/core/paths.lua")
local nodes = dofile("lua/core/nodes.lua")

local M = {}

-- The CLI runs as one user on one node, so "this thread" is the newest session
-- for that pair - the same one `wa chat --continue` resumes. These are the same
-- constants chat.lua uses; if they ever drift, status reports a thread nobody
-- can continue.
local USER, NODE = "master", ""

function M.node_id()
  local identity = nodes.identity() or {}
  return identity.node_id or "unknown"
end

-- Model name and whether it can actually be reached: an unconfigured provider
-- is the difference between "the model is quiet" and "nothing works".
function M.model()
  local settings = provider.settings()
  return string.format("%s  provider=%s  configured=%s", settings.model,
    settings.provider, provider.configured() and "yes" or "no")
end

function M.session_id()
  local session = memory.latest_session(USER, NODE)
  return session and session.id or nil
end

function M.session()
  local id = M.session_id()
  if not id then return "none yet  (nothing for --continue to resume)" end
  local state = memory.session_state(id)
  if not state then return id end
  return string.format("%s  %s", id, state.detail)
end

-- An unfinished thread is the one fact `wa status` is uniquely placed to report:
-- it is what `--continue` would resume, and the transcript itself cannot say it -
-- a question with no answer looks the same whether the process is still thinking
-- or dead. The line is emitted only when there is something to recover, so
-- silence here means the thread is settled, and `wa resume` is the next step.
function M.unfinished()
  local id = M.session_id()
  if not id then return nil end
  local state = memory.session_state(id)
  if not state or state.state ~= "unfinished" then return nil end
  return string.format("unfinished at seq %d  %s  ->  wa resume", state.seq, state.detail)
end

-- host.exec hands its result back as a JSON string, not a table: reading `.code`
-- off that string yields nil, which would make every tree look unreachable.
local function exec(command)
  local ok, result = pcall(host.exec, command, "")
  if not ok then return nil end
  if type(result) == "string" then
    local decoded_ok, decoded = pcall(json.decode, result)
    if decoded_ok and type(decoded) == "table" then return decoded end
    return nil
  end
  return result
end

-- Uncommitted changes in the working tree we are actually sitting in. Untracked
-- files count: an uncommitted new file is as invisible to the next pull as an
-- edit. A git failure is reported, not smoothed into "clean" - a health line
-- that lies is worse than no line.
function M.working_tree()
  local result = exec("git status --porcelain")
  if type(result) ~= "table" or result.code == nil then
    return "unavailable (no git?)"
  end
  if result.code ~= 0 then
    local detail = tostring(result.stderr or ""):gsub("%s+", " "):gsub("^%s+", "")
    if detail == "" then detail = "git exit " .. tostring(result.code) end
    return "unavailable (" .. detail:sub(1, 90) .. ")"
  end
  local changed = 0
  for line in tostring(result.stdout or ""):gmatch("[^\r\n]+") do
    if line:match("%S") then changed = changed + 1 end
  end
  if changed == 0 then return "clean" end
  return string.format("%d changed", changed)
end

function M.config_path() return paths.config() end

local function result_has(list, value)
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

-- Do the toolchains this node's tools need actually resolve? A systemd service
-- does not inherit a login shell's PATH, so `cargo` can be installed and still be
-- unreachable - which is what stopped a remote build with "sh: 1: cargo: not
-- found" after two attempted calls. Nothing else reported it, because nothing
-- else had tried to use it.
-- Do the toolchains this node's tools need actually resolve, and can it build itself?
--
-- The knowledge of *what* a node wants and *how* to get it lives in `toolchain.lua`, because this
-- line is one of several places that need it (a build script, the installer, an engine view). A
-- systemd service does not inherit a login shell's PATH, so `cargo` can be installed and still
-- unreachable - which is what stopped a remote build with "sh: 1: cargo: not found" after two
-- attempted calls. Nothing else reported it, because nothing else had tried to use it.
function M.tools()
  return dofile("lua/core/toolchain.lua").line()
end

-- Ordered: identity first, then what would break a turn, then the paths.
function M.lines()
  local lines = {
    "node      " .. M.node_id(),
    "model     " .. M.model(),
    "session   " .. M.session(),
  }
  local unfinished = M.unfinished()
  if unfinished then lines[#lines + 1] = "unfinished " .. unfinished end
  lines[#lines + 1] = "tools     " .. M.tools()
  lines[#lines + 1] = "tree      " .. M.working_tree()
  lines[#lines + 1] = "config    " .. M.config_path()
  return lines
end

function M.report()
  local lines = M.lines()
  for _, text in ipairs(lines) do print(text) end
  return lines
end

return M
