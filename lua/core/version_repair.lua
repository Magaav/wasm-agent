-- A node that starts after a cut finishes the migration itself (slice (b), requirement 5).
--
-- WHY. The shell half (scripts/lib/versions.sh) moves the pointer with ONE rename, and puts each legacy path in
-- place with two: the real file or directory is renamed ASIDE first (one rename, atomic), then a link through
-- `current` is renamed ONTO it (one rename, atomic). A cut between those two leaves the path ABSENT on purpose -
-- that is the order that keeps a node working, because the binary falls back to its compiled-in Lua and says so
-- once. What must not happen is the path STAYING absent, and the repair cannot be a shell script: the script may
-- be the thing missing. So every start of `wa` asks this module, before it needs the tree, to put back any link
-- the pointer names that is missing or dangling.
--
-- WHAT IT REFUSES TO DO. It never replaces a real file or directory: a real directory at a legacy path is today's
-- layout (no pointer at all), or evidence of a migration that has not started. It never touches a healthy link.
-- Nothing at all happens on a node with no `current` - which is every node before this slice installs.
--
-- NOT WINDOWS. There the in-place install stays (requirement 9) and `mv -T` does not exist; the guard is Lua's
-- own path separator, so this module is inert there without pulling in a platform module.

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function norm(p)
  p = tostring(p or ""):gsub("\\", "/")
  while #p > 1 and p:sub(-1) == "/" do p = p:sub(1, -2) end
  return p
end

local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

function M.share_root()
  if IS_WINDOWS then return nil end
  local env = host.getenv("WA_SHARE_ROOT")
  if env and env ~= "" then return norm(env) end
  local data = host.getenv("XDG_DATA_HOME")
  if not data or data == "" then data = norm(host.getenv("HOME")) .. "/.local/share" end
  return norm(data) .. "/wasm-agent"
end

-- A path is healthy when it RESOLVES to something that exists: a dangling link is not healthy, and neither is a
-- missing path. MEASURED on this host: host.path_kind answers "missing" for both of those and "file"/"dir" for a
-- path that resolves (host.file_exists does not exist in this host's surface - the first run of the row said so).
local function healthy(p)
  local ok, kind = pcall(host.path_kind, p)
  return ok and kind ~= "missing"
end

function M.members(install, share)
  return {
    { path = install .. "/wa",          target = share .. "/current/wa" },
    { path = install .. "/wa-sentinel", target = share .. "/current/wa-sentinel" },
    { path = install .. "/lua-core",    target = share .. "/current/lua-core" },
    { path = install .. "/scripts",     target = share .. "/current/scripts" },
    { path = share .. "/ui",            target = "current/ui" },
  }
end

-- <opts: {share, install, quiet}> -> {repaired=n, skipped=n, reason=...}
function M.repair(opts)
  opts = opts or {}
  if IS_WINDOWS then return { repaired = 0, skipped = 0, reason = "windows_in_place" } end
  local share = opts.share or M.share_root()
  if not share then return { repaired = 0, skipped = 0, reason = "no_share_root" } end
  local current = share .. "/current"
  -- The pointer's own record is what says a version is current; a bare symlink is not enough.
  if not healthy(current .. "/version.txt") then return { repaired = 0, skipped = 0, reason = "no_current" } end
  local install = opts.install
  if not install then
    local ok, update = pcall(dofile, "lua/core/update.lua")
    if not (ok and type(update) == "table" and type(update.install_dir) == "function") then
      return { repaired = 0, skipped = 0, reason = "no_install_dir" }
    end
    install = norm(update.install_dir())
  end
  local repaired, skipped, failed = 0, 0, 0
  for _, m in ipairs(M.members(install, share)) do
    if healthy(m.path) then
      skipped = skipped + 1
    elseif healthy(m.target) or healthy(share .. "/" .. m.target) then
      local tmp = m.path .. ".repair"
      local command = "ln -sfn " .. quote(m.target) .. " " .. quote(tmp) ..
        " && mv -T " .. quote(tmp) .. " " .. quote(m.path)
      local ok = pcall(host.exec, command, "", 30)
      if ok and healthy(m.path) then
        repaired = repaired + 1
        if not opts.quiet then print("wa: put back " .. m.path .. " -> " .. m.target) end
      else
        failed = failed + 1
        if not opts.quiet then print("wa: could not put back " .. m.path .. " (the node keeps running)") end
      end
    end
    -- Neither the path nor the pointer's member exists: nothing to repair, and nothing to say.
  end
  return { repaired = repaired, skipped = skipped, failed = failed }
end

return M

