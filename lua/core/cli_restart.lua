-- The CLI restarting itself into the same session.
--
-- A node is replaced by its sentinel (`/update` queues a deploy; lua/core/update.lua), but the
-- interactive `wa` in a terminal is nobody's child: when a deploy installs a new binary, the open
-- chat keeps running the old one until the reader quits and types `wa --resume <id>`. This does that
-- for them. Between runs - never during one, and never over a draft, a panel, a queued line or a
-- mouse selection (`host.input_idle`) - the REPL asks whether there is a reason to restart:
--   * the binary this process was started from was replaced on disk (`host.binary_changed`);
--   * someone asked: `/restart`, or a request file at `M.request_path()` (the agent can `touch` it,
--     with a reason as its content).
-- It then gives the terminal back and execs the binary at its own path as `wa chat --resume <id>`;
-- the new process draws the transcript again (chat.lua's replay) and says why it restarted.
--
-- A loop must stop: each restart carries `WA_CLI_RESTARTS=<count>:<first epoch>` to the next process,
-- and more than `M.MAX` restarts inside `M.WINDOW` seconds are refused with that said, so a request
-- that cannot be cleared or a build that looks new forever cannot exec the CLI forever.
local paths = dofile("lua/core/paths.lua")
local json = dofile("lua/vendor/json.lua")

local M = {}

M.MAX, M.WINDOW = 3, 300
-- How often, while idle at the prompt, the REPL looks (two stats, no process).
M.CHECK_SECONDS = 2

function M.request_path()
  return paths.home() .. "/.wasm-agent/cli-restart.request"
end

-- The loop guard, pure: `raw` is `WA_CLI_RESTARTS` as inherited. Returns ok, the value to pass on,
-- and a refusal sentence when not ok.
function M.budget(raw, now)
  local count, first = tostring(raw or ""):match("^(%d+):(%d+)$")
  count, first = tonumber(count) or 0, tonumber(first) or now
  if now - first > M.WINDOW then count, first = 0, now end
  if count >= M.MAX then
    return false, nil, string.format("not restarting: %d restarts in the last %ds (WA_CLI_RESTARTS) - "
      .. "something keeps asking; restart by hand with wa --resume", count, M.WINDOW)
  end
  return true, string.format("%d:%d", count + 1, math.floor(first)), nil
end

-- Why the CLI should restart now, or nil. Reads the request file's text as the reason.
function M.reason()
  local ok, raw = pcall(host.binary_changed)
  if ok and type(raw) == "string" then
    local decoded, value = pcall(json.decode, raw)
    if decoded and type(value) == "table" and value.changed then
      return "a new wa build is installed (" .. tostring(value.reason or "binary changed") .. ")"
    end
  end
  local request = host.read_file(M.request_path())
  if type(request) == "string" then
    local text = request:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return "restart requested" .. (text ~= "" and (": " .. text:sub(1, 200)) or "")
  end
  return nil
end

-- Nothing the reader is doing would be lost by restarting now.
function M.idle()
  if not host.input_idle then return true end
  local ok, raw = pcall(host.input_idle)
  if not ok or type(raw) ~= "string" then return true end
  local decoded, value = pcall(json.decode, raw)
  return not decoded or type(value) ~= "table" or value.idle ~= false
end

-- Restart into `session_id`. `before()` gives the screen back (the view's own teardown); the host
-- restores the console itself. Only returns on refusal or failure: the sentence to print, and whether
-- the screen was already given back (an exec that failed after it: the REPL cannot continue).
function M.restart(session_id, reason, before)
  local ok, carried, refusal = M.budget(host.getenv("WA_CLI_RESTARTS"), host.now())
  if not ok then return refusal end
  local request = M.request_path()
  if type(host.read_file(request)) == "string" then
    host.exec("rm -f '" .. request:gsub("'", "'\\''") .. "'", "")
    if type(host.read_file(request)) == "string" then return "not restarting: could not remove " .. request end
  end
  if not host.cli_reexec then return "not restarting: this wa binary cannot re-exec itself" end
  if before then pcall(before) end
  local raw = host.cli_reexec(json.encode({ "chat", "--resume", session_id }),
    json.encode({ WA_CLI_RESTARTS = carried, WA_CLI_RESTARTED = reason or "restart" }))
  local decoded, value = pcall(json.decode, raw or "")
  local problem = tostring(decoded and type(value) == "table" and value.error or raw)
  return "restart failed: " .. problem, true
end

return M
