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
  local less = provider.model_less()
  return string.format("%s  provider=%s  configured=%s%s", settings.model,
    settings.provider, provider.configured() and "yes" or "no",
    less and "  model-less=yes (no turn can run here)" or "")
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

-- THE WATCHER IS ONE LINE, AND ITS ABSENCE NAMES THE FIX (Fable 26/11, work).
--
-- MEASURED on work (a Docker container with no systemd), twice on 26/11: `wa-sentinel start` failed, its reason went to
-- the container's stdout, and `wa status` - the page a person reads - said nothing about the watcher at all, running or
-- not. The only surface that refused was `wa update`, and its sentence began by sending the reader somewhere else. So the
-- fact gets a line here, ALWAYS: running with its pid, or not running with the one command that starts it.
--
-- `opts` is a test's seam (read_file, alive, sentinel, config): production calls it with nothing.
function M.watcher_line(opts)
  opts = opts or {}
  local reader = opts.read_file or (type(host) == "table" and host.read_file or nil)
  local config = opts.config or M.config_path()
  local sentinel = opts.sentinel
  if sentinel == nil then
    local ok, update = pcall(dofile, "lua/core/update.lua")
    if ok and type(update) == "table" and type(update.install_dir) == "function" then
      local named_ok, dir = pcall(update.install_dir)
      if named_ok and type(dir) == "string" and dir ~= "" then sentinel = dir .. "/wa-sentinel" end
    end
    sentinel = sentinel or "wa-sentinel"
  end
  local not_running = "watcher   not running - start it: " .. sentinel .. " start"

  -- ASK THE OWNER (law 17, 28/11). MEASURED on the live laptop: `wa status` said "watcher not running" while
  -- `wa-sentinel status` said "sentinel: up watching (pid 2121399)" and the unit was active - two answers to one
  -- question. The cause was not a stale pid file: this function probed with `host.exec("kill -0 N")`, and host.exec
  -- returns a JSON STRING, so `answer.code` was never read and the probe could only ever answer "not running".
  -- The sentinel is the owner of that fact (it also knows about the systemd supervisor), so in production the line
  -- comes from its own answer. The test seams below are kept and take precedence: a row must not need a real sentinel.
  if type(opts.alive) ~= "function" and opts.read_file == nil then
    local ok, raw = pcall(host.exec, sentinel .. " status", "", 30)
    local text = ""
    if ok and type(raw) == "string" then
      local decoded_ok, decoded = pcall(function() return json.decode(raw) end)
      if decoded_ok and type(decoded) == "table" then text = tostring(decoded.stdout or "") .. tostring(decoded.stderr or "")
      else text = raw end
    end
    local up_pid = text:match("sentinel:%s+up[^\n]-%(pid%s+(%d+)%)")
    if up_pid then return "watcher   running (pid " .. up_pid .. ")" end
    if text:match("sentinel:%s+down") then return not_running end
    -- The owner could not be asked (no binary, no answer): fall through to the pid file, and say nothing it cannot know.
  end

  local raw = ""
  if type(reader) == "function" then raw = tostring(reader(config .. "/sentinel/sentinel.pid") or "") end
  local pid = raw:match("^%s*(%d+)")
  local alive = false
  if pid then
    if type(opts.alive) == "function" then alive = opts.alive(tonumber(pid)) == true
    else
      -- `kill -0` reads without signalling, and host.exec answers a JSON string: decode it before reading `code`.
      local ok, answer = pcall(host.exec, "kill -0 " .. pid, "", 20)
      local code = nil
      if ok and type(answer) == "string" then
        local decoded_ok, decoded = pcall(function() return json.decode(answer) end)
        if decoded_ok and type(decoded) == "table" then code = tonumber(decoded.code) end
      elseif ok and type(answer) == "table" then code = tonumber(answer.code) end
      alive = code == 0
    end
  end
  if alive then return "watcher   running (pid " .. pid .. ")" end
  return not_running
end

-- Ordered: identity first, then what would break a turn, then the paths.
function M.lines()
  local lines = {
    "node      " .. M.node_id(),
    "model     " .. M.model(),
    "session   " .. M.session(),
    -- The watcher's fact, always: a page that says nothing about it is how two failed starts went unseen on work.
    M.watcher_line(),
  }
  local unfinished = M.unfinished()
  if unfinished then lines[#lines + 1] = "unfinished " .. unfinished end
  -- AN ABANDONED RESUME IS A DEBT NOBODY SEES (r7-add): the session stopped and only the record knows. The count
  -- and the oldest age, counted from the records themselves (`deploy_pause.abandoned_count`), never a model call.
  local ok_pause, pause = pcall(dofile, "lua/core/deploy_pause.lua")
  if ok_pause and type(pause) == "table" and type(pause.abandoned_count) == "function" then
    local counted = pause.abandoned_count()
    if counted and (tonumber(counted.count) or 0) > 0 then
      lines[#lines + 1] = "abandoned resumes " .. tostring(counted.count)
        .. (counted.oldest_age_seconds and (" (oldest " .. M.age_text(counted.oldest_age_seconds) .. ")") or "")
    end
  end
  lines[#lines + 1] = "tools     " .. M.tools()
  lines[#lines + 1] = "tree      " .. M.working_tree()
  -- The node's one root: how big it is, how full its filesystem is against the cap, and when the last
  -- clean ran (docs/ONEROOT.md, rule 4). One line, read from the host's own measurement.
  local ok_clean, clean_line = pcall(function() return dofile("lua/core/clean.lua").status_line() end)
  lines[#lines + 1] = "root      " .. (ok_clean and clean_line or ("unavailable - " .. tostring(clean_line)))
  lines[#lines + 1] = "config    " .. M.config_path()
  -- WHICH FEATURES STILL WORK (lua/core/feature_health.lua): one line, because this page is the operator's
  -- short read - the full table is `wa features`, and the first stopped feature is named here so a reader
  -- who does not run that command still sees that something has stopped.
  local ok_features, feature_lines = pcall(function() return dofile("lua/core/feature_health.lua").lines() end)
  if ok_features and type(feature_lines) == "table" and type(feature_lines[1]) == "string" then
    local first_red
    for _, line in ipairs(feature_lines) do
      if line:find("failing") or line:find("stale") then first_red = first_red or line; break end
    end
    lines[#lines + 1] = "features  " .. tostring(feature_lines[1]):gsub("^features: ", "")
      .. (first_red and ("  <- " .. tostring(first_red):gsub("^%s+", "")) or "")
  else
    lines[#lines + 1] = "features  unavailable - " .. tostring(feature_lines)
  end
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

-- The limits last read per provider, with WHEN they were read, so a `/status` built during a run
-- (`opts.cached`) never waits on the network - the run is what the reader is waiting on - and can
-- still say how old the numbers it draws are (Victor 23/11: mid-run `/status` answered "limits
-- unavailable: read on the next /status between runs" while the panel had a reading it could have
-- shown with its age). A read this constructor has not made yet is still refused by name: an age is
-- a fact about a number that exists, and "unknown" is not "4 minutes ago".
M._limits = {}

-- How old a reading is, in the words the reader repeats it in. Rounded to the unit it is read in: a
-- bar that was true 4 minutes ago is not "256 s ago".
function M.age_text(seconds)
  local s = tonumber(seconds) or 0
  if s < 45 then return "just now" end
  if s < 5400 then return string.format("as of %d min ago", math.floor((s + 30) / 60)) end
  if s < 129600 then return string.format("as of %d h ago", math.floor(s / 3600 + 0.5)) end
  return string.format("as of %d d ago", math.floor(s / 86400 + 0.5))
end

-- The rows one provider's limits draw, as strings: `  5h  <bar>   4%  resets in 3.0h`. The ONE builder - the
-- `/status` page, the mid-run snapshot and its row all come through here (rust/wa-capabilities/src/limits.rs
-- row_texts is the console's port of it, and its test pins the two against each other).
function M.limit_rows(limits, opts)
  opts = opts or {}
  local rows = {}
  for _, window in ipairs({ { "5h", "rolling" }, { "7d", "weekly" }, { "30d", "monthly" } }) do
    local entry = type(limits) == "table" and limits[window[2]]
    if type(entry) == "table" then
      local percent = tonumber(entry.percent) or 0
      local reset = resets(entry.resetsAt):gsub("^ ", "")
      rows[#rows + 1] = (string.format("  %-3s %s %3.0f%%  %s", window[1], M.bar(percent, 16, opts.color), percent, reset)
        :gsub("%s+$", ""))
    end
  end
  return rows
end

-- Answers the limits, a named problem, how old the reading is, and the door's state.
--
-- The read is the HOST's now (provider.limits asks `host.limits_start`/`limits_poll`), so this never
-- waits - mid-run or between runs. The snapshot memory below is kept only so a caller that must not
-- talk to anything at all (`opts.cached`) still has the last numbers; it is never the reason a
-- reading is missing.
local function limits_of(id, opts)
  local seen = M._limits[id]
  local limits, problem, age, state = provider.limits(id)
  if type(limits) == "table" and next(limits) ~= nil then
    M._limits[id] = { at = host.now() - (tonumber(age) or 0), limits = limits, problem = problem }
    return limits, problem, tonumber(age) or 0, state or "ready"
  end
  if seen and type(seen.limits) == "table" and next(seen.limits) ~= nil then
    return seen.limits, seen.problem, host.now() - seen.at, "ready"
  end
  return limits, problem, tonumber(age), state or "none"
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
    lines[#lines + 1] = dim("Usage    ") .. table.concat(parts, dim("  \194\183  "))
    -- THE COST, ON ITS OWN ROW AND NAMED FOR WHOSE NUMBER IT IS (Victor 23/11). It used to be the last
    -- segment of the Usage row, which measured 55 cells on his screen and - measured in a pty at 100
    -- columns on 23/11 - is CUT by the panel: the row the reader got ended at `out 100`, so a cost that
    -- was there read as a cost that was missing. Short enough to survive any panel width.
    -- `cost` is priced from this node's rate snapshot (unknown for a provider that publishes none);
    -- `list_cost` is the provider's OWN price for each call, summed - opencode-go answers
    -- `opencode.list_cost` on every usage block (0.00102713 on a real call), so "cost unknown" was a
    -- refusal to read a number the provider had already sent.
    if total.cost_known then
      lines[#lines + 1] = dim("Cost     ") .. string.format("$%.4f", tonumber(total.cost) or 0)
        .. dim("  \194\183  rated")
    elseif total.list_cost_known then
      lines[#lines + 1] = dim("Cost     ") .. string.format("list $%.4f", tonumber(total.list_cost) or 0)
        .. dim("  \194\183  the provider's own list price, summed over " .. tostring(total.calls)
          .. (total.calls == 1 and " call" or " calls"))
    else
      lines[#lines + 1] = dim("Cost     ") .. "unknown"
    end
  else
    lines[#lines + 1] = dim("Usage    ") .. "not yet observed in this session"
  end
  for _, item in ipairs(reported_providers(settings.provider)) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = bold(item.id) .. (item.id == settings.provider and dim("  (in use)") or "")
    -- A snapshot the CONSOLE draws mid-run names the rows it must fill itself: the interpreter is
    -- inside the turn then, so nothing here can repaint when the read lands. The marker is one line;
    -- the console expands it from the door on every draw (rust/wa-capabilities/src/limits.rs).
    if opts and opts.limits_marker then
      lines[#lines + 1] = string.char(1) .. "limits:" .. tostring(item.id)
      goto continue_provider
    end
    local limits, problem, age, state = limits_of(item.id, opts)
    -- ONE NAMED BUILDER FOR A LIMITS ROW (27/11, Victor's `/status` regression). It was built inline here, so no row
    -- could measure what the panel actually draws without running a whole session. Two things this fixes at once:
    --   1. the row is now measurable (scripts/test-status-resets.lua calls exactly this);
    --   2. it FITS THE PANEL. The reset time is the LAST thing on the line and the console cuts a row to its box
    --      (clip_cells(text, width - BOX_CHROME)); at 24 cells of bar the row measured 53 and the reset fell off a
    --      narrow panel - the exact shape this repo already recorded for the cost segment (55 cells, cut at 100
    --      columns, 23/11). A 16-cell bar costs nothing a reader used and keeps the reset inside 44 cells.
    local rows = M.limit_rows(limits, opts)
    local shown = #rows
    for _, row in ipairs(rows) do lines[#lines + 1] = row end
    if shown == 0 then
      -- Nothing to draw yet: say WHAT is happening, never "come back between runs" - the read is
      -- already on its way, on the host's own thread (Victor 25/11).
      if state == "loading" then
        lines[#lines + 1] = dim("  loading limits\226\128\166")
      elseif state == "failed" and problem then
        lines[#lines + 1] = dim("  limits: " .. problem)
      else
        lines[#lines + 1] = dim("  limits: asking the provider\226\128\166")
      end
    elseif tonumber(age) then
      -- The rows above are a reading, not a measurement taken now: say how old it is, so a bar on the
      -- screen mid-run cannot be read as this second's allowance.
      lines[#lines + 1] = dim("  " .. M.age_text(age))
    end
    ::continue_provider::
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


-- ---------------------------------------------------------------- one status on every tool answer
-- 17/11: these two functions were added on 14/11 (fe5157a9) by REPLACING this whole file, which removed
-- `/status`'s own page (session_lines, lines, report, node_id ...): `/status` between runs raised, the
-- mid-run snapshot failed silently (so the host queued `/status` instead of showing it) and `wa status`
-- broke. One module, both surfaces, so no caller had to change.
-- One status on every tool answer (operator 14/11: "return 200 for success", made engineering law):
-- the dispatcher stamps it, so no tool can drift and the model reads one signal everywhere.
--   200 it worked  ·  202 accepted, still running or queued  ·  400 the call was wrong (fix the call)
--   403 not allowed  ·  404 no such tool/target  ·  500 the call was right and the world failed it
-- A tool that already says its own `status` keeps it (the WhatsApp send answers 200/202/500 itself).
local NOT_FOUND = { 'unknown_tool', 'unknown_node', 'unknown_capability', 'unknown_id', '_not_found', 'file_missing', 'not_found' }
local FORBIDDEN = { 'forbidden', 'not_in_profile', 'denied', 'not_granted', 'requires_approval', 'hook_denied' }
-- JSON-RPC protocol rejections (parse error, invalid request, unknown method, invalid params) are the call to fix.
local BAD_CALL = { 'schema_', 'bad_', '_required', 'invalid', 'exclusive', 'retired', 'codemode_only', ':-32700', ':-32600', ':-32601', ':-32602' }

local function has(text, list)
  for _, part in ipairs(list) do if text:find(part, 1, true) then return true end end
  return false
end

function M.of(result)
  if type(result) ~= 'table' then return 200 end
  if type(result.status) == 'number' then return result.status end
  local state = type(result.state) == 'string' and result.state or ''
  if state == 'pending' or state == 'queued' or state == 'running' then return 202 end
  local failed = result.ok == false or result.error ~= nil
  if not failed then return 200 end
  local code = tostring(result.code or result.error or ''):lower()
  if has(code, FORBIDDEN) then return 403 end
  if has(code, NOT_FOUND) then return 404 end
  if has(code, BAD_CALL) then return 400 end
  -- a script that did not run as written (SyntaxError, ReferenceError, TypeError ...) is the call to fix
  if code:find('^%a*error') then return 400 end
  return 500
end

function M.stamp(result)
  -- An array answer (a list) stays a list: a key on it would make it an object nothing can encode.
  if type(result) == 'table' and result.status == nil and result[1] == nil and next(result) ~= nil then result.status = M.of(result) end
  return result
end

return M
