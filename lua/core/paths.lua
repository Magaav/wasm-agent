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

-- The one file the host reads for configuration: `<config>/env`, KEY=VALUE per
-- line, loaded at startup without overriding the real environment
-- (`load_env_file` in rust/wa-host/src/main.rs). The name lives here *and* there,
-- which is a drift risk - but this function is what `wa paths` prints, so if the
-- two ever disagree the disagreement is visible instead of silently sending the
-- user to edit a file the agent will never read.
local CONFIG_FILE = "env"

function M.config_file() return M.config() .. "/" .. CONFIG_FILE end

-- Is that file there? `host.read_file` is the only capability we have, so a file
-- that exists but cannot be read also reports as missing - which is honest about
-- what the agent gets: nothing. An empty file counts as present, because the host
-- does open and read it; it just contributes no keys. Returns false rather than
-- nil so callers can use it in a condition without a `~= nil` dance.
function M.config_file_present()
  if not (host and host.read_file) then return false end
  return host.read_file(M.config_file()) ~= nil
end

return M
