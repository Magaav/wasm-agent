-- Platform-neutral directories, from the host.
--
-- Nothing in the Lua core should build a path from $HOME or assume a POSIX
-- layout: Windows does not set HOME at all, Git Bash sets it to a /c/... path
-- that a native binary cannot open, and WASI will hand these over directly.
-- Keeping the assumption in one place is what makes the rest portable.
local M = {}

local cached = nil

function M.all()
  if cached then return cached end
  local ok, value = pcall(host.paths)
  if ok and type(value) == "table" then
    cached = value
    return cached
  end
  -- Older hosts (or a WASI shim that has not been wired up yet): degrade to the
  -- environment rather than failing, so a missing capability is not fatal.
  local home = host.getenv("HOME") or "."
  cached = { home = home, config = home .. "/.wasm-agent", data = home .. "/.wasm-agent",
             cache = home .. "/.wasm-agent/cache", temp = host.getenv("TMPDIR") or "/tmp" }
  return cached
end

function M.config() return M.all().config end
function M.data() return M.all().data end
function M.cache() return M.all().cache end
function M.temp() return M.all().temp end
function M.home() return M.all().home end

return M
