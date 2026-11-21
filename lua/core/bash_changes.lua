-- The files a shell command changed while it ran (Victor 20/11: files that changed while this
-- command ran), and nothing else.
--
-- The honest question a snapshot can answer is: which files were CLEAN before this command and are
-- not clean after it. For those the text the command started from is the indexed one (git show
-- :path, taken at the repository root), so a diff against the file on disk now is a true account of
-- what the command did. A file that was already modified before the command cannot be answered that
-- way - its starting text is not in the index - so it is REPORTED by path and its diff is refused by
-- name: a guessed before side would take a reader's earlier work and blame the command for it.
--
-- Paths are resolved against the repository ROOT and never against the command's own directory:
-- git's porcelain output is root-relative even when git runs in a subdirectory (measured 20/11 on
-- rust/ inside this repo), so a path joined to the command's cwd reads the wrong file or none.
--
-- It uses git's own porcelain because that is a rule every reader already trusts, and it is bounded:
-- only a command that runs in a git work tree, only a command the caller says can change a file, a
-- short timeout, and a cap on how many files are read. When git is absent, the directory is not a
-- work tree, or the command could not be observed, nothing is claimed at all - unknown is not
-- nothing changed.
local json = dofile("lua/vendor/json.lua")

local M = {}

M.MAX_FILES = 20
M.TIMEOUT = 10

local function exec(command, cwd)
  if type(host.exec) ~= "function" then return nil end
  local ok, raw = pcall(host.exec, command, cwd or "", M.TIMEOUT, json.encode({ tool = "bash" }))
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil end
  if decoded.code ~= 0 then return nil end
  return tostring(decoded.stdout or "")
end

-- The repository root a command's directory belongs to, or nil when it is not in a work tree.
function M.root(cwd)
  local out = exec("git rev-parse --show-toplevel", cwd)
  if out == nil then return nil end
  local root = out:match("^%s*(.-)%s*$")
  if root == nil or root == "" then return nil end
  return root
end

-- path -> the two-letter porcelain status, for the whole work tree. nil when git is not there or the
-- directory is not a work tree: a snapshot nobody can take is not a clean tree.
function M.snapshot(root)
  local out = exec("git status --porcelain=v1 -uno", root)
  if out == nil then return nil end
  local map = {}
  for line in out:gmatch("[^\r\n]+") do
    local status, path = line:match("^(..)%s+(.+)$")
    if status and path then map[path] = status end
  end
  return map
end

-- The snapshot a call is about to change, or nothing when there is nothing to compare against.
--
-- The read-only verdict is the CALLER's, passed in: the rule for what a command may read is one
-- function the caller already applies to decide whether the call is an effect, and asking it a
-- second time here would be two definitions of one rule. An unknown verdict (nil) takes the snapshot:
-- the cost of a needless one is two cheap git calls, the cost of a missing one is a file that changed
-- unseen.
function M.before(cwd, read_only)
  if read_only == true then return nil end
  local root = M.root(cwd)
  if root == nil then return nil end
  local status = M.snapshot(root)
  if status == nil then return nil end
  return { root = root, status = status }
end

-- The files that went from clean to changed, with the two texts a diff needs. Returns a list of
-- {path, before_text, after_text} plus a list of files whose diff cannot honestly be drawn.
function M.changed(before)
  if type(before) ~= "table" or type(before.root) ~= "string" or type(before.status) ~= "table" then
    return {}, {}
  end
  local after = M.snapshot(before.root)
  if after == nil then return {}, {} end
  local out, refused, count = {}, {}, 0
  local paths = {}
  for path in pairs(after) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local status = after[path]
    local was = before.status[path]
    if count < M.MAX_FILES and (was == nil or was ~= status) then
      count = count + 1
      local now = host.read_file and host.read_file(before.root .. "/" .. path) or nil
      if status:sub(1, 2) == "??" then
        -- A new file: there was no text before it, which is a fact, not a guess.
        out[#out + 1] = { path = path, before_text = "", after_text = now or "" }
      elseif was == nil then
        -- Was clean: the index holds exactly the text the command started from, at the root.
        local started = exec("git show :" .. path, before.root)
        if started ~= nil and now ~= nil then
          out[#out + 1] = { path = path, before_text = started, after_text = now }
        else
          refused[#refused + 1] = { path = path, why = "index_text_unavailable" }
        end
      else
        refused[#refused + 1] = { path = path, why = "already_modified" }
      end
    end
  end
  return out, refused
end

return M