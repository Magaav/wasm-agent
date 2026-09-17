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
  return id
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

-- Ordered: identity first, then what would break a turn, then the paths.
function M.lines()
  return {
    "node      " .. M.node_id(),
    "model     " .. M.model(),
    "session   " .. M.session(),
    "tree      " .. M.working_tree(),
    "config    " .. M.config_path(),
  }
end

function M.report()
  local lines = M.lines()
  for _, text in ipairs(lines) do print(text) end
  return lines
end

return M
