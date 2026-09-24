-- What this agent is running on, from the host.
--
-- The `bash` tool is `sh -c` on Linux and `cmd /C` on Windows, so the model has
-- to be told which dialect it is in. Without this it guesses POSIX, runs `pwd`,
-- `ls` and `grep`, and spends its tool budget on "not recognized as an internal
-- or external command".
local json = dofile("lua/vendor/json.lua")

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

-- The terminal's width in columns: the console's own answer, then `$COLUMNS`, then 80.
--
-- The order is the point. `COLUMNS` is a *shell* variable on most machines and is not exported to
-- children, so it is absent in exactly the place the CLI runs - measured: a 120-column terminal with
-- `COLUMNS` empty - and when it is present it can be stale after a resize. The console knows; the
-- environment is the fallback for a caller that has one and no console.
--
-- `host.terminal_size` may be missing (an older binary), and it returns nil when it cannot ask, so
-- both absences fall through to the same answer rather than to a width of zero.
--
-- `environment` and `probe` are injectable: the rule is worth a test, and a test has no terminal.
function M.columns(environment, probe)
  probe = probe or function()
    local ok, raw = pcall(host.terminal_size)
    if not ok or type(raw) ~= "string" then return nil end
    local decoded
    local read = pcall(function() decoded = json.decode(raw) end)
    if not read or type(decoded) ~= "table" then return nil end
    return decoded
  end
  local size = probe() or {}
  local columns = tonumber(size.columns) or tonumber(environment) or 0
  if columns <= 0 then return 80 end
  return math.floor(columns)
end

-- One line for the system prompt, and a short form for tool descriptions.
function M.describe()
  local info = M.info()
  -- Say which shell, and only warn about the dialect when it actually is cmd:
  -- with Git Bash present the POSIX habits the model already has are correct,
  -- and a hint to use dir/type/findstr would push it the wrong way.
  local shell = tostring(info.shell or "")
  local hint
  if shell:find("cmd", 1, true) then
    hint = "shell commands run through cmd /C, so use dir, type, findstr and copy rather than ls, cat, grep and cp"
  elseif shell:find("bash", 1, true) then
    hint = "shell commands run through bash -c"
  else
    hint = "shell commands run through " .. shell
  end
  return string.format("%s (%s); %s", info.os, info.arch, hint)
end

function M.shell_name()
  return M.info().shell
end

return M
