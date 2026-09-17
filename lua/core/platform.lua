-- What this agent is running on, from the host.
--
-- The `bash` tool is `sh -c` on Linux and `cmd /C` on Windows, so the model has
-- to be told which dialect it is in. Without this it guesses POSIX, runs `pwd`,
-- `ls` and `grep`, and spends its tool budget on "not recognized as an internal
-- or external command".
local M = {}

local cached = nil

function M.info()
  if cached then return cached end
  local ok, value = pcall(host.platform)
  if ok and type(value) == "table" then
    cached = value
    return cached
  end
  cached = { os = "unknown", arch = "unknown", shell = "sh -c", pathSeparator = "/", cwd = "." }
  return cached
end

function M.os() return M.info().os end
function M.shell() return M.info().shell end
function M.cwd() return M.info().cwd or "." end

-- One line for the system prompt, and a short form for tool descriptions.
function M.describe()
  local info = M.info()
  local hint = info.os == "windows"
    and "shell commands run through cmd /C, so use dir, type, findstr and copy rather than ls, cat, grep and cp"
    or "shell commands run through sh -c"
  return string.format("%s (%s); %s", info.os, info.arch, hint)
end

function M.shell_name()
  return M.info().shell
end

return M
