-- The files a shell command changed while it ran (Victor 20/11: files that changed while this
-- command ran), and nothing else.
--
-- The honest question a snapshot can answer is: which files were CLEAN before this command and are
-- not clean after it. For those the text the command started from is the indexed one (git show
-- :path), so a diff against the file on disk now is a true account of what the command did. A file
-- that was already modified before the command cannot be answered that way - its starting text is
-- not in the index - so it is REPORTED by path and its diff is refused by name: a guessed before
-- side would take a reader's earlier work and blame the command for it.
--
-- It uses git's own porcelain because that is a rule every reader already trusts, and it is bounded:
-- only a command that runs in a git work tree, only a non-read-only command, a short timeout, and a
-- cap on how many files are read. When git is absent, the directory is not a work tree, or the
-- command could not be observed, nothing is claimed at all - unknown is not nothing changed.
local json = dofile("lua/vendor/json.lua")

local M = {}

M.MAX_FILES = 20
M.STATUS_TIMEOUT = 10

local function exec(command, cwd)
  if type(host.exec) ~= "function" then return nil end
  local ok, raw = pcall(host.exec, command, cwd or "", M.STATUS_TIMEOUT, json.encode({ tool = "bash" }))
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil end
  if decoded.code ~= 0 then return nil end
  return tostring(decoded.stdout or "")
end

-- path -> the two-letter porcelain status, for the whole work tree the command ran in. nil when git is
-- not there or the directory is not a work tree: a snapshot nobody can take is not a clean tree.
function M.snapshot(cwd)
  local out = exec("git status --porcelain=v1 -uno", cwd)
  if out == nil then return nil end
  local map = {}
  for line in out:gmatch("[^\r\n]+") do
    local status, path = line:match("^(..)%s+(.+)$")
    if status and path then map[path] = status end
  end
  return map
end

local function read_at(cwd, path)
  if not (host.read_file and cwd and cwd ~= "") then return nil end
  return host.read_file(cwd .. "/" .. path)
end

-- The files that went from clean to changed, with the two texts a diff needs. Returns a list of
-- {path, before_text, after_text} plus a list of files whose diff cannot honestly be drawn.
function M.changed(cwd, before)
  if type(before) ~= "table" then return {}, {} end
  local after = M.snapshot(cwd)
  if after == nil then return {}, {} end
  local out, refused, count = {}, {}, 0
  for path, status in pairs(after) do
    local was = before[path]
    if count < M.MAX_FILES and (was == nil or was ~= status) then
      count = count + 1
      if status:sub(1, 2) == "??" then
        -- A new file: there was no text before it, which is a fact, not a guess.
        out[#out + 1] = { path = path, before_text = "", after_text = read_at(cwd, path) or "" }
      elseif was == nil then
        -- Was clean: the index holds exactly the text the command started from.
        local indexed = exec("git show :" .. path, cwd)
        local text = read_at(cwd, path)
        if indexed ~= nil and text ~= nil then
          out[#out + 1] = { path = path, before_text = indexed, after_text = text }
        else
          refused[#refused + 1] = { path = path, why = "index_text_unavailable" }
        end
      else
        refused[#refused + 1] = { path = path, why = "already_modified_before_command" }
      end
    end
  end
  return out, refused
end

-- The snapshot a call is about to change, or nothing when the call cannot change a file.
--
-- The read-only verdict is the CALLER's, passed in: the rule for what a command may read is
-- orchestration_mode.read_only_command, which the caller already applies to decide whether the call
-- is an effect (agent.lua command_effect). Loading it here to ask a second time would be two
-- definitions of one rule, and this module is about a snapshot, not about policy. An unknown verdict
-- (nil) takes the snapshot: the cost of a needless one is a pair of git status calls, the cost of a
-- missing one is a file that changed unseen.
function M.before(cwd, command, read_only)
  if read_only == true then return nil end
  return M.snapshot(cwd)
end

return M