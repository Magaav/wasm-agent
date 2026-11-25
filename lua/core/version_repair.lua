-- A node that starts after a cut finishes the migration itself (slice (b), requirement 5).
--
-- WHY. The shell half (scripts/lib/versions.sh) moves the pointer with ONE rename and puts each legacy path in
-- place; a cut between two of those steps leaves a path ABSENT on purpose (the binary falls back to its
-- compiled-in Lua and says so once). What must not happen is the path STAYING absent, and the repair cannot be a
-- shell script: the script may be the thing missing. So every start of `wa` asks this module, before the tree is
-- needed, to put back any link the pointer names that is missing or dangling.
--
-- WHOSE INSTALL (Fable 25/11, fix 1). The first version of this module took the install dir from
-- `update.install_dir()` and the share root from the operator's HOME, which is wrong in a specific, dangerous way:
-- a `wa` built in a worktree, or a scratch binary started with the real HOME, would find the live pointer and plant
-- links to the LIVE version inside its own directory - and then run the installed Lua instead of its own. So:
--   - the version's own record names the install dir it belongs to (version.txt's install_dir=, written at
--     assemble time), and
--   - the repair acts ONLY when the running program is that install's program: its real path is inside the
--     version the pointer names, or its directory IS the install dir the record names.
-- `wa --version` in a worktree therefore plants nothing.
--
-- COST (fix 3). With no pointer the module does exactly one path_kind and returns: no fork, no update.lua, no
-- read. With a pointer it reads version.txt and asks the kernel for the running program's real path (one fork of
-- `readlink -f /proc/<node>/exe`), which is the price of knowing WHOSE install this is; the report measures it.
-- It never loads lua/core/update.lua: the install dir comes from the record.
--
-- WHAT IT REFUSES TO DO. It never replaces a real file or directory (today's layout, and evidence of a migration
-- that has not started), never touches a healthy link, and says nothing on stdout (fix 2): its messages go to
-- stderr, so `wa --version`'s stdout is byte-identical whether a repair happened or not.
--
-- NOT WINDOWS. There the in-place install stays (requirement 9); the guard is Lua's own path separator.

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function say(message) io.stderr:write("wa: " .. message .. "\n") end

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
-- missing path. Measured on this host: path_kind answers "missing" for both (host.file_exists does not exist).
local function healthy(p)
  local ok, kind = pcall(host.path_kind, p)
  return ok and kind ~= "missing"
end

local function record(path, field)
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= "string" then return nil end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key == field then return value end
  end
  return nil
end

-- The running program's real path, or nil. host.exec answers a JSON envelope (measured), so the path is taken out
-- of its stdout field; a host that cannot answer leaves nil and the caller refuses rather than guesses.
local function running_exe()
  local ok, out = pcall(host.exec, "readlink -f /proc/$PPID/exe 2>/dev/null", "", 10)
  if not ok or type(out) ~= "string" then return nil end
  local path = out:match('"stdout"%s*:%s*"([^"]*)"')
  if not path then return nil end
  path = path:gsub("\\n", ""):gsub("\\/", "/")
  if path == "" then return nil end
  return norm(path)
end

local function dirname(p)
  p = norm(p)
  return p:match("^(.*)/[^/]*$") or ""
end

-- Is this repair OURS? The running program must be the install's program (fix 1).
function M.ours(install, version_dir, exe)
  install = norm(install)
  if not exe or exe == "" then
    -- No /proc answer: only an explicit WA_INSTALL_DIR that IS this install is enough to act.
    return norm(host.getenv("WA_INSTALL_DIR")) == install and install ~= ""
  end
  if dirname(exe) == install then return true end
  version_dir = norm(version_dir)
  if #exe > #version_dir and exe:sub(1, #version_dir + 1) == version_dir .. "/" then return true end
  return false
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

-- <opts: {share, install, exe, quiet}> -> {repaired=n, skipped=n, failed=n, reason=...}
function M.repair(opts)
  opts = opts or {}
  if IS_WINDOWS then return { repaired = 0, skipped = 0, reason = "windows_in_place" } end
  local share = opts.share or M.share_root()
  if not share then return { repaired = 0, skipped = 0, reason = "no_share_root" } end
  local current = share .. "/current"
  -- The cheap gate, and the ONLY work when there is no pointer (fix 3): one path_kind.
  if not healthy(current .. "/version.txt") then return { repaired = 0, skipped = 0, reason = "no_current" } end
  local install = opts.install or record(current .. "/version.txt", "install_dir")
  if not install or install == "" then return { repaired = 0, skipped = 0, reason = "no_install_dir_recorded" } end
  -- The version's id comes from its own record, so no link is followed and no update.lua is loaded (fix 3).
  local version_dir = share .. "/versions/" .. tostring(record(current .. "/version.txt", "id") or "")
  local exe = opts.exe
  if exe == nil then exe = running_exe() end
  if not M.ours(install, version_dir, exe) then
    return { repaired = 0, skipped = 0, reason = "not_this_install", install = install, exe = exe }
  end
  local repaired, skipped, failed = 0, 0, 0
  for _, m in ipairs(M.members(install, share)) do
    -- The ui member's target is RELATIVE (current/ui) so the share root stays movable: it is resolved against the
    -- share root here, which is what the shell half writes too.
    local target_ok = healthy(m.target)
    if not target_ok and m.target:sub(1, 1) ~= "/" then target_ok = healthy(share .. "/" .. m.target) end
    if healthy(m.path) then
      skipped = skipped + 1
    elseif target_ok then
      local tmp = m.path .. ".repair"
      local command = "ln -sfn " .. quote(m.target) .. " " .. quote(tmp) ..
        " && mv -T " .. quote(tmp) .. " " .. quote(m.path)
      local ok = pcall(host.exec, command, "", 30)
      if ok and healthy(m.path) then
        repaired = repaired + 1
        if not opts.quiet then say("put back " .. m.path .. " -> " .. m.target) end
      else
        failed = failed + 1
        if not opts.quiet then say("could not put back " .. m.path .. " (the node keeps running)") end
      end
    end
  end
  return { repaired = repaired, skipped = skipped, failed = failed }
end

return M

