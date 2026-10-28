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
local command_output = dofile("lua/core/command_output.lua")

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
  local state = memory.session_state(id)
  if not state then return id end
  return string.format("%s  %s", id, state.detail)
end

-- An unfinished thread is the one fact `wa status` is uniquely placed to report:
-- it is what `--continue` would resume, and the transcript itself cannot say it -
-- a question with no answer looks the same whether the process is still thinking
-- or dead. The line is emitted only when there is something to recover, so
-- silence here means the thread is settled, and `wa resume` is the next step.
function M.unfinished()
  local id = M.session_id()
  if not id then return nil end
  local state = memory.session_state(id)
  if not state or state.state ~= "unfinished" then return nil end
  return string.format("unfinished at seq %d  %s  ->  wa resume", state.seq, state.detail)
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
    -- The elision marker is a host note, not a changed path, and must not be counted.
    if not command_output.is_elision(line) and line:match("%S") then changed = changed + 1 end
  end
  -- A clipped view is a lower bound, not a count: say so instead of printing a number that looks
  -- measured. (An emptiness answer is unaffected: a clipped stream is never empty.)
  if command_output.truncated(result) then return string.format("at least %d changed", changed) end
  if changed == 0 then return "clean" end
  return string.format("%d changed", changed)
end

function M.config_path() return paths.config() end

local function result_has(list, value)
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

-- Do the toolchains this node's tools need actually resolve? A systemd service
-- does not inherit a login shell's PATH, so `cargo` can be installed and still be
-- unreachable - which is what stopped a remote build with "sh: 1: cargo: not
-- found" after two attempted calls. Nothing else reported it, because nothing
-- else had tried to use it.
-- Do the toolchains this node's tools need actually resolve, and can it build itself?
--
-- The knowledge of *what* a node wants and *how* to get it lives in `toolchain.lua`, because this
-- line is one of several places that need it (a build script, the installer, an engine view). A
-- systemd service does not inherit a login shell's PATH, so `cargo` can be installed and still
-- unreachable - which is what stopped a remote build with "sh: 1: cargo: not found" after two
-- attempted calls. Nothing else reported it, because nothing else had tried to use it.
function M.tools()
  return dofile("lua/core/toolchain.lua").line()
end

-- Ordered: identity first, then what would break a turn, then the paths.
function M.lines()
  local lines = {
    "node      " .. M.node_id(),
    "model     " .. M.model(),
    "session   " .. M.session(),
  }
  local unfinished = M.unfinished()
  if unfinished then lines[#lines + 1] = "unfinished " .. unfinished end
  lines[#lines + 1] = "tools     " .. M.tools()
  lines[#lines + 1] = "tree      " .. M.working_tree()
  lines[#lines + 1] = "config    " .. M.config_path()
  return lines
end

-- `/status` in the chat: this session's id, the model, and every provider's usage - the same numbers
-- the window's status balloon shows (`wa_model` in server.lua): the provider's own rolling limits
-- (5h / 7d / 30d) and this session's measured tokens and cost from the harness ledger. One network
-- call per configured provider, cached 30 s by `provider.limits`; a provider that does not answer
-- says so on its own line instead of failing the command.
local function tokens(n)
  n = tonumber(n)
  if not n then return "unknown" end
  if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

-- Epoch seconds of an ISO-8601 UTC stamp (`2026-11-02T00:00:00.000Z`), the shape providers send.
local function iso_seconds(text)
  local y, mo, d, h, mi, se = tostring(text or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  y, mo = tonumber(y), tonumber(mo)
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + tonumber(d) - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
end

local function resets(value)
  local at = tonumber(value) or iso_seconds(value)
  if not at then return value and (" resets " .. tostring(value)) or "" end
  if at > 1e12 then at = at / 1000 end
  local left = at - host.now()
  if left <= 0 then return " resets now" end
  if left < 3600 then return string.format(" resets in %dm", math.ceil(left / 60)) end
  if left < 172800 then return string.format(" resets in %.1fh", left / 3600) end
  return string.format(" resets in %.1fd", left / 86400)
end

-- A bar of `width` cells for `percent` (0-100), eighths for the partial cell. Coloured by how close
-- the window is to its limit when `color` is set (the CLI's panel); plain text otherwise.
local PARTS = { "", "\226\150\143", "\226\150\142", "\226\150\141", "\226\150\140",
  "\226\150\139", "\226\150\138", "\226\150\137" }
local FULL, EMPTY = "\226\150\136", "\226\150\145"
function M.bar(percent, width, color)
  percent = math.max(0, math.min(100, tonumber(percent) or 0))
  width = width or 24
  local eighths = math.floor(percent / 100 * width * 8 + 0.5)
  local full, part = math.floor(eighths / 8), eighths % 8
  local filled = string.rep(FULL, full) .. PARTS[part + 1]
  local cells = full + (part > 0 and 1 or 0)
  local rest = string.rep(EMPTY, width - cells)
  if not color then return filled .. rest end
  local tone = percent >= 80 and "\27[38;2;240;113;120m" or percent >= 50 and "\27[38;2;229;192;123m"
    or "\27[38;2;152;195;121m"
  return tone .. filled .. "\27[38;2;68;68;68m" .. rest .. "\27[0m"
end

-- The providers `/status` reports: the configured ones (an unconfigured provider has nothing to say),
-- the active one first.
local function reported_providers(active)
  local list = {}
  for _, item in ipairs(provider.providers()) do
    local configured = item.id == active or (type(item.api_key) == "string" and item.api_key ~= "")
    if configured then list[#list + 1] = item end
  end
  table.sort(list, function(a, b)
    if (a.id == active) ~= (b.id == active) then return a.id == active end
    return a.id < b.id
  end)
  return list
end

-- The limits last read per provider, so a `/status` built during a run (`opts.cached`) never waits on
-- the network: the run is what the reader is waiting on.
M._limits = {}
local function limits_of(id, opts)
  local seen = M._limits[id]
  local now = host.now()
  if seen and (opts.cached or now - seen.at < (opts.max_age or 30)) then return seen.limits, seen.problem end
  if opts.cached then return nil, "read on the next /status between runs" end
  local limits, problem = provider.limits(id)
  M._limits[id] = { at = now, limits = limits, problem = problem }
  return limits, problem
end

-- `/status`: rows for the CLI's panel (or printed where there is none). `opts.color` paints the bars;
-- `opts.cached` uses the limits already read instead of asking the provider; `opts.max_age` (seconds,
-- default 30) is how old a reading may be before it is asked for again.
function M.session_lines(session_id, opts)
  opts = opts or {}
  local dim = function(text) return opts.color and ("\27[38;2;119;119;119m" .. text .. "\27[0m") or text end
  local bold = function(text) return opts.color and ("\27[1m" .. text .. "\27[0m") or text end
  local settings = provider.settings()
  local lines = {
    dim("Session  ") .. tostring(session_id or "none"),
    dim("Resume   ") .. "wa --resume " .. tostring(session_id or "<id>"),
    dim("Model    ") .. tostring(settings.model) .. dim("  \194\183  " .. tostring(settings.provider)),
  }
  local ok_snapshot, observed = pcall(function() return dofile("lua/core/telemetry.lua").snapshot(session_id) end)
  local total = ok_snapshot and type(observed) == "table" and observed.available and observed.total
  if total then
    local parts = { "in " .. tokens(total.prompt), "out " .. tokens(total.output) }
    if total.cache_known and tonumber(total.prompt) and total.prompt > 0 then
      parts[#parts + 1] = string.format("cache %.0f%%", 100 * (total.cacheRead or 0) / total.prompt)
    end
    parts[#parts + 1] = total.cost_known and string.format("$%.4f", tonumber(total.cost) or 0) or "cost unknown"
    lines[#lines + 1] = dim("Usage    ") .. table.concat(parts, dim("  \194\183  "))
  else
    lines[#lines + 1] = dim("Usage    ") .. "not yet observed in this session"
  end
  for _, item in ipairs(reported_providers(settings.provider)) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = bold(item.id) .. (item.id == settings.provider and dim("  (in use)") or "")
    local limits, problem = limits_of(item.id, opts)
    local shown = 0
    for _, window in ipairs({ { "5h", "rolling" }, { "7d", "weekly" }, { "30d", "monthly" } }) do
      local entry = type(limits) == "table" and limits[window[2]]
      if type(entry) == "table" then
        local percent = tonumber(entry.percent) or 0
        lines[#lines + 1] = string.format("  %-4s %s %4s%%  %s", window[1], M.bar(percent, 24, opts.color),
          string.format("%.0f", percent), dim((resets(entry.resetsAt):gsub("^ ", ""))))
        shown = shown + 1
      end
    end
    if shown == 0 then lines[#lines + 1] = dim("  limits unavailable" .. (problem and (": " .. problem) or "")) end
  end
  return lines
end

function M.session_report(session_id, opts)
  return table.concat(M.session_lines(session_id, opts), "\n")
end

function M.report()
  local lines = M.lines()
  for _, text in ipairs(lines) do print(text) end
  return lines
end

return M
