-- `wa update` FOLLOWS THE INSTALL IT ASKED FOR - from the first second, by itself (Fable/Victor, 24/11).
--
-- WHY THIS EXISTS. Measured on `work`, 24/11 15:32Z: the person typed `wa update`, the deploy was at 48
-- of 456 crates after three and a half minutes, and the terminal printed NOTHING - not the phase, not
-- how long it had been going, not what it was waiting for. The progress existed on disk the whole time
-- (`<data>/build-status.json`, `sentinel/queue/<id>.json`, `sentinel/deploy.out`); no command read it.
-- A second measurement, 15:34:55Z: a build FAILED after 361 s and the person was told nothing at all.
--
-- So this module is the reader. It makes no request of its own, changes no protocol and writes nothing:
-- it watches the files a deploy already writes and says, once per change,
--
--   * what the install is doing (the phase, and n/m while it compiles);
--   * how long it has been doing it;
--   * what it is waiting for, when it is waiting;
--   * the final line - the commit installed, or the failure with its reason and the next step.
--
-- `--detach` returns at once; Ctrl-C stops FOLLOWING and not the install, because the installer is
-- another process (the sentinel spawns it detached) and nothing here signals it.
--
-- Sources, in the order this module trusts them (each is a file a live node already has):
--   1. <install>/deploy-result.json              the installer's own verdict, matched by request id;
--   2. <data>/build-status.json                  state/phase/done/total/crate/at, written while it builds;
--   3. <config>/sentinel/failed|done/<id>.json   the sentinel's verdict on the REQUEST itself;
--   4. <install>/deploy-state.json               upgrade.sh's own phase (waiting_for_idle, upgrading, ...);
--   5. <config>/sentinel/queue/<id>.json         what the sentinel observed: queued, held, running;
--   6. <config>/sentinel/requests|claimed/<id>.json  the request is still in this node's box;
--   7. <data>/deploy-pending.json                the install waits for the node to be idle, and its bound.
--
-- Nothing here invents a phase. A file that cannot be read is skipped and the follower says what it DOES
-- know (`waiting for the installer to report its first phase`), because a wrong phase is worse than none.

local M = {}

local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function slashes(path)
  return (tostring(path or ""):gsub("\\", "/"))
end

local function read(path)
  if not path or path == "" then return nil end
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= "string" then return nil end
  return text
end

local function decode(path)
  local text = read(path)
  if not text then return nil end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function exists(path)
  if not path or path == "" then return false end
  local ok, present = pcall(host.file_exists, path)
  return ok and present == true
end

local function clock_default()
  return tonumber(host.now and host.now() or os.time()) or os.time()
end

-- Epoch seconds as the installer writes them (`date -u +%Y-%m-%dT%H:%M:%SZ`). Comparing these as
-- strings is exact (fixed width, zero-padded, always UTC), and it is the comparison `deploy.sh` and
-- `upgrade.sh` records invite: their `at` is an ISO stamp, never an epoch.
local function iso(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(tonumber(epoch) or 0))
end

-- `45s`, `2m05s`, `1h02m`: the same shapes `lua/core/update_banner.lua` and `build_status.rs` draw.
local function elapsed(seconds)
  local s = math.max(0, math.floor(tonumber(seconds) or 0))
  if s >= 3600 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor(s / 60) % 60) end
  if s >= 60 then return string.format("%dm%02ds", math.floor(s / 60), s % 60) end
  return s .. "s"
end
M.elapsed = elapsed

M.POLL = 1        -- seconds between reads; the deploy writes build-status.json many times a second
M.HEARTBEAT = 30
-- A full compile of this tree on a node like work, said out loud while it runs (Victor, 27/11: "we need
-- instantaneous" - so at least the wait must be named, in seconds of reading, not discovered after 32 minutes).
BUILD_MINUTES = 30  -- seconds: an unchanged phase says so again at this interval, and only then
-- HOW LONG A FOLLOW WAITS FOR A REQUEST THE SENTINEL HAS NOT STARTED. A queued deploy can be held by
-- design (the node is busy, a turn is finishing), so the bound is the installer's OWN idle bound -
-- `WA_DEPLOY_IDLE_BOUND`, 1800 s, the number `scripts/upgrade.sh` writes into deploy-pending.json - and
-- not a number invented here. Past it `wa update` stops following, says the request is still queued, and
-- names the command that picks it up; nothing is cancelled and the request stays where it is.
-- `WA_UPDATE_FOLLOW_BOUND` overrides it; 0 waits forever (the pre-24/11 behaviour).
M.UNPERFORMED_BOUND = 1800
-- The one sentence about what Ctrl-C does, printed once when the follow starts.
M.HINT = "following: Ctrl-C stops following; the install continues (wa update --follow re-attaches)"
M.DETACHED = "detached: the install continues without this terminal; wa update --follow re-attaches"

local function shell(command)
  if not host.exec then return nil end
  local ok, raw = pcall(host.exec, command, "")
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil end
  return decoded
end

-- ---- where the facts are -----------------------------------------------------

-- Every path this module reads, named once. `options` may point any of them at a fixture (a test, an
-- operator diagnosing a copy), and the default is the rule the deploy writes by - not a second guess.
function M.paths(options)
  local o = options or {}
  local config = slashes(o.config or paths.config())
  local data = slashes(o.data or paths.data())
  local install = slashes(o.install or (function()
    local ok, module = pcall(dofile, "lua/core/update.lua")
    if ok and type(module) == "table" then return module.install_dir() end
    return slashes(paths.home()) .. "/.local/bin"
  end)())
  local sentinel = slashes(o.sentinel_dir or (config .. "/sentinel"))
  return {
    install = install,
    data = data,
    config = config,
    sentinel = sentinel,
    -- `scripts/lib/build-status.sh` writes `$WASM_AGENT_DATA/build-status.json`, else `$WASM_AGENT_HOME`.
    -- `lua/core/update_banner.lua` reads the same file for the window's row and honours WA_BUILD_STATUS,
    -- so a node that moved the file is followed here too.
    build = slashes(o.build_status or (function()
      local banner_ok, banner = pcall(dofile, "lua/core/update_banner.lua")
      if banner_ok and type(banner) == "table" and type(banner.build_path) == "function" then return banner.build_path(o) end
      return data .. "/build-status.json"
    end)()),
    queue = sentinel .. "/queue",
    requests = sentinel .. "/requests",
    claimed = sentinel .. "/claimed",
    done = sentinel .. "/done",
    failed = sentinel .. "/failed",
    deploy_out = sentinel .. "/deploy.out",
    deploy_state = install .. "/deploy-state.json",
    deploy_result = install .. "/deploy-result.json",
    installed = install .. "/installed.txt",
    pending = data .. "/deploy-pending.json",
  }
end

-- The commit this install says it runs: the installer's own record, never a guess.
function M.installed_commit(options)
  local p = (options and options.paths) or M.paths(options)
  local text = read(p.installed) or ""
  local commit = trim(text:match("\n?commit=([^\r\n]+)") or "")
  if commit == "" then commit = trim(text:match("\n?source_commit_hint=([^\r\n]+)") or "") end
  return commit
end

-- ---- is this record about the request this command wrote? ---------------------

-- Two requests can be minutes apart and the installer's record is one file, rewritten in place: the
-- previous deploy's verdict is otherwise read as this one's (deploy.sh itself names that trap). The
-- request id is the exact answer; the timestamp is the fallback for an installer too old to write one,
-- and a record that matches NEITHER is never claimed.
local function agent_record_mine(record, id, since_iso)
  local recorded = trim(record.request_id)
  if recorded ~= "" and trim(id) ~= "" then return recorded == trim(id) end
  local at = trim(record.at)
  if at ~= "" and since_iso and #at >= 19 then return at >= since_iso end
  return false
end

local function fresh_epoch(at, since)
  local value = tonumber(at)
  if not value then return false end
  if not since then return true end
  -- A second of slack: the request is written before the installer reads the clock.
  return value >= (tonumber(since) - 1)
end

local function fresh_iso(at, since_iso)
  local value = trim(at)
  if value == "" then return false end
  if not since_iso then return true end
  return value >= since_iso
end

-- Two short commits, either a prefix of the other. Anything shorter than seven hex is no evidence.
local function same_commit(left, right)
  local a, b = trim(left):lower(), trim(right):lower()
  if #a < 7 or #b < 7 then return true end  -- one side unknown: the caller decides, never a mismatch
  return a:sub(1, #b) == b or b:sub(1, #a) == a
end

local function duration(build)
  local done, total = tonumber(build.done), tonumber(build.total)
  if not total or total <= 0 then return "" end
  if done and done > total then done = total end
  return tostring(done or 0) .. "/" .. tostring(total) .. " "
end

-- ---- one snapshot of what is happening ---------------------------------------
--
-- Returns `{ key, body, terminal, ok, clock_from, detail, sources }`. `body` is the sentence without the
-- clock (`building 48/456 compiling wa-host`); `text` adds the elapsed time, so a caller can print on a
-- change of body and still show a clock that moves.
function M.state(options)
  local o = options or {}
  local p = o.paths or M.paths(o)
  local now = tonumber(o.now) or (o.clock and o.clock()) or clock_default()
  local id = trim(o.id)
  if id == "" and o.request then id = tostring(o.request):match("([^/\\]+)%.json$") or "" end
  local started = tonumber(o.started_at)
  local since_iso = started and iso(started) or nil
  -- WHEN THE INSTALL BEGAN, for the clock on every line: the sentinel's own record of when the request
  -- was queued, else the moment this command wrote it. A follower that started late (wa update --follow)
  -- still shows how long the install has really taken, not how long it has been watched.
  local queued = id ~= "" and decode(p.queue .. "/" .. id .. ".json") or nil
  local origin = tonumber(type(queued) == "table" and queued.queued_at) or started
  -- WHICH PATH THE INSTALLER TOOK, from its own words. Read once per snapshot: it decides whether a phase
  -- has an n/total to show at all (there is no build when it installs a published binary) and whether the
  -- word "build" may be printed (Fable 24/11, A and B).
  local declared = M.declared(o, p)

  local function snap(fields)
    fields.at = now
    fields.id = id
    fields.started_at = started
    fields.clock_from = fields.clock_from or origin
    fields.declared = fields.declared or declared
    fields.sources = fields.sources or {}
    return fields
  end

  -- 1. THE INSTALLER'S OWN VERDICT for this exact request. `deploy.sh` writes it on both sides of the
  --    swap (`write_result`), so it is the first word that means installed or failed.
  local result = decode(p.deploy_result)
  if type(result) == "table" and agent_record_mine(result, id, since_iso) then
    local detail = trim(result.detail)
    local commit = trim(result.commit)
    -- INSTALLED, AND THE DEPLOY DID NOT FINISH (25/11, Fable's B). ok=false is what "failed" looks like, and after
    -- the swap nothing failed: the node serves the new build and a problem is recorded for the operator. The verdict
    -- field is the one that says which of the three happened; a result written by an older deploy has none.
    if tostring(result.verdict or "") == "installed_with_problems" then
      local problems = tonumber(result.problems or 0) or 0
      return snap({ key = "installed_with_problems", terminal = true, ok = false, clock_from = origin,
        body = "installed " .. (commit ~= "" and commit:sub(1, 12) or "(the installer named no commit)")
          .. ", with " .. tostring(problems) .. " problem(s): " .. (detail ~= "" and detail or "(no detail recorded)"),
        detail = detail, commit = commit, problems = problems, sources = { p.deploy_result } })
    end
    if result.ok == true then
      return snap({ key = "installed", terminal = true, ok = true, clock_from = origin,
        body = "installed " .. (commit ~= "" and commit:sub(1, 12) or "(the installer named no commit)"),
        detail = detail, commit = commit, sources = { p.deploy_result } })
    end
    -- The deploy's own refused(...) sentence rides along when the record's detail does not already carry it: the
    -- operator reads one line, and that line has to be the installer's reason rather than a summary of it.
    local refused = M.refused_line(o, p)
    local why = detail
    if why == "" then why = refused end
    if why == "" then why = "the installer exited without a reason" end
    if refused ~= "" and not why:find(refused, 1, true) then why = why .. " - " .. refused end
    return snap({ key = "failed", terminal = true, ok = false, clock_from = origin,
      body = "failed: " .. why,
      detail = why, refused = refused, commit = commit, sources = { p.deploy_result } })
  end

  -- 2. THE BUILD'S OWN RECORD. A build that ended writes state=installed|failed with its phase as the
  --    reason (`wa_status failed "compiling: ..."`), and that is the measurement this slice exists for:
  --    24/11 15:34:55Z, a build died after 361 s and the person was told nothing.
  local build = decode(p.build)
  if type(build) == "table" and fresh_epoch(build.at, started and (started - 1)) then
    local state = trim(build.state)
    local phase = trim(build.phase)
    if state == "failed" then
      return snap({ key = "failed", terminal = true, ok = false,
        clock_from = tonumber(build.started_at) or origin,
        body = "failed: " .. (phase ~= "" and phase or "the build ended without a reason")
          .. M.refused_join(o, p, phase),
        detail = phase, commit = trim(build.commit), sources = { p.build } })
    end
    if state == "installed" and same_commit(build.commit, o.target) then
      return snap({ key = "installed", terminal = true, ok = true, clock_from = tonumber(build.started_at) or origin,
        body = "installed " .. (trim(build.commit) ~= "" and trim(build.commit):sub(1, 12) or "(the build named no commit)"),
        detail = "the build finished and installed", commit = trim(build.commit), sources = { p.build } })
    end
  end

  -- 3. THE SENTINEL'S VERDICT ON THE REQUEST: a refusal is final and names its reason. A `done` record
  --    for a deploy says the installer was SPAWNED (phase=spawned) - it is not an install, and reading
  --    it as one is how "done" came to mean "nothing happened yet".
  if id ~= "" then
    local failed = decode(p.failed .. "/" .. id .. ".json")
    if type(failed) == "table" then
      local detail = trim(failed.detail)
      return snap({ key = "failed", terminal = true, ok = false,
        clock_from = origin,
        body = "failed: " .. (detail ~= "" and detail or trim(failed.phase) ~= "" and trim(failed.phase) or "the sentinel refused the request"),
        detail = detail, sources = { p.failed .. "/" .. id .. ".json" } })
    end
  end

  -- 4. THE INSTALLER'S OWN PHASE (scripts/upgrade.sh). `waiting_for_idle` is a state, not silence, and
  --    `upgrading` means the node is being stopped and its binaries switched.
  local dstate = decode(p.deploy_state)
  if type(dstate) == "table" and fresh_iso(dstate.at, since_iso) then
    local state = trim(dstate.state)
    local phase = trim(dstate.phase)
    if state == "failed" then
      return snap({ key = "failed", terminal = true, ok = false, clock_from = origin,
        body = "failed: upgrade.sh stopped in " .. (phase ~= "" and phase or "an unnamed step"),
        detail = phase, sources = { p.deploy_state } })
    end
    if state == "done" and fresh_iso(dstate.at, since_iso) then
      -- deploy-result.json is the authority on success; a `done` here without one names what installed.
      local commit = M.installed_commit(o)
      return snap({ key = "installed", terminal = true, ok = true, clock_from = origin,
        body = "installed " .. (commit ~= "" and commit:sub(1, 12) or "(installed.txt names no commit)"),
        detail = "upgrade.sh finished", commit = commit, sources = { p.deploy_state } })
    end
    if state == "upgrading" then
      return snap({ key = "installing", clock_from = started,
        body = "installing: stopping the node and switching binaries" .. (phase ~= "" and (" (" .. phase .. ")") or ""),
        sources = { p.deploy_state } })
    end
    if state == "waiting_for_idle" then
      return snap({ key = "waiting", clock_from = started,
        body = "waiting: for this node to be idle" .. (phase ~= "" and (" (" .. phase .. ")") or "") .. M.hold_text(o, p),
        sources = { p.deploy_state } })
    end
  end

  -- 5. THE INSTALLER SAID IT IS INSTALLING A PUBLISHED BINARY: there is no n/total to show, because there
  --    is no build. "building 456/456 proving (published binary, no build)" contradicted itself (Fable
  --    24/11, B): the published path says what it is doing and drops the bar.
  -- THE LIVE BUILD OUTRANKS THE DECLARATION (Victor's update on work, 27/11: the screen said "installing the
  -- published binary (no build)" for 32 minutes while deploy.sh compiled for 1961 s, and the deploy then failed).
  -- `declared` is what the installer SAID it would do, read from its log; a fresh building record is what it IS
  -- doing, read from its own status file. When the two disagree the status file is right, so the published
  -- label is only reached when nothing is building now - and then step 6 shows the real phase and n/m.
  -- What contradicts the declaration is COMPILING, not merely a status file: a real published install writes
  -- `building installing` too (its own row, scripts/test-update-follow.sh case 3). So the test is the phase and
  -- the count, which only a source build produces.
  local compiling_now = false
  if type(build) == "table" and trim(build.state) == "building"
    and fresh_epoch(build.at, started and (started - 1)) then
    local bphase, bdone = trim(build.phase), tonumber(build.done) or 0
    compiling_now = bphase:match("^compil") ~= nil or bdone > 0
  end
  if declared == "published" and not compiling_now then
    return snap({ key = "downloading", body = "installing the published binary (no build)", sources = { p.deploy_out } })
  end

  -- 6. THE BUILD'S PROGRESS. The n/total form belongs to a real build only, and says so when the installer
  --    declared one ("from source, on this machine"); before it has spoken, the bar says nothing about the
  --    path rather than guessing one.
  if type(build) == "table" and trim(build.state) == "building" and fresh_epoch(build.at, started and (started - 1)) then
    local phase = trim(build.phase)
    local crate = trim(build.crate)
    local body = "building " .. duration(build) .. (phase ~= "" and phase or "working")
    if crate ~= "" and phase == "compiling" then body = body .. " " .. crate end
    -- WHY IT IS BUILDING, not only that it is (Victor on work, 27/11: 32 minutes of cargo behind a line that never
    -- said why a published binary was not used, and the answer - "no published binary for this commit" - was in
    -- the installer's own log the whole time). The reason comes from that log; the estimate is the honest one for
    -- a full compile on a machine like this, and it says "~" because it is an estimate.
    if declared == "build" then
      local why = M.build_reason(o, p)
      body = body .. " (from source, on this machine: "
        .. (why ~= "" and why or "no published binary for this commit")
        .. ", ~" .. BUILD_MINUTES .. " min)"
    end
    return snap({ key = "building", clock_from = tonumber(build.started_at) or started, body = body,
      done = tonumber(build.done), total = tonumber(build.total), sources = { p.build } })
  end

  -- 6. WHAT THE SENTINEL OBSERVED of this request: queued, held (and by what), or running.
  local queue = id ~= "" and decode(p.queue .. "/" .. id .. ".json") or nil
  if type(queue) == "table" then
    local state = trim(queue.state)
    local detail = trim(queue.detail)
    if state == "failed" then
      return snap({ key = "failed", terminal = true, ok = false,
        body = "failed: " .. (detail ~= "" and detail or "the sentinel reported the request failed"),
        detail = detail, sources = { p.queue .. "/" .. id .. ".json" } })
    end
    if state == "waiting" then
      return snap({ key = "waiting", clock_from = tonumber(queue.queued_at) or started,
        body = "waiting: " .. (detail ~= "" and detail or "the sentinel is holding this request") .. M.hold_text(o, p),
        sources = { p.queue .. "/" .. id .. ".json" } })
    end
    if state == "running" or (state == "done" and trim(queue.phase) == "spawned") then
      return snap({ key = "installer", clock_from = tonumber(queue.queued_at) or started,
        body = "installer started: " .. (detail ~= "" and detail or "the sentinel spawned the installer"),
        sources = { p.queue .. "/" .. id .. ".json" } })
    end
  end

  -- 7. STILL IN THE BOX: accepted, not yet performed.
  if id ~= "" and (exists(p.requests .. "/" .. id .. ".json") or exists(p.claimed .. "/" .. id .. ".json")) then
    return snap({ key = "queued", clock_from = started, body = "queued: the sentinel has not performed it yet" })
  end

  -- 8. Nothing readable names this request yet. Say so with the clock, never a made-up phase: the
  --    request may have been accepted a millisecond ago, or the sentinel may be between its lanes.
  return snap({ key = "unknown", clock_from = started,
    body = "no phase reported yet: waiting for the sentinel to observe this request" })
end

-- What holds an install that is waiting, from the deploy-pending marker the installer wrote (it carries
-- its own bound, `scripts/lib/deploy-signal.sh`). Empty when there is nothing to say.
function M.hold_text(options, paths_in)
  local p = paths_in or M.paths(options)
  local pending = decode(p.pending)
  if type(pending) ~= "table" then return "" end
  local bound = tonumber(pending.bound_seconds)
  local since = tonumber(pending.since)
  if not bound or not since then return "" end
  local left = math.max(0, math.floor(bound - ((tonumber(options and options.now) or clock_default()) - since)))
  local who = trim(pending.by)
  return " (" .. (who ~= "" and (who .. ": ") or "") .. "paused turns, bound " .. tostring(math.floor(bound)) .. "s, " .. tostring(left) .. "s left)"
end

-- The installer's own answer to download-or-build, read from its output (`deploy: installing the published
-- binary` / `deploy: no published binary for this commit; building this tree`). `nil` until it says - and
-- nil is NOT "build": the plan line says the installer looks for a covered release first, and the word
-- "build" is printed only when the installer itself says so (Fable 24/11, A).
-- The installer's own reason for building instead of installing, read from the same deploy output `declared()`
-- reads. Empty when the log does not say - the caller then states the fact without inventing a cause.
function M.build_reason(options, paths_in)
  local p = paths_in or M.paths(options)
  local text = read(p.deploy_out)
  if not text then return "" end
  local last = text:match("%-%-%- deploy [^\r\n]*%-%-%-(.*)$") or text
  local line = last:match("deploy: no published binary for this commit[^\r\n]*")
  if not line then return "" end
  return trim(line:gsub("^deploy: ", ""):gsub("%s*%b()%s*$", ""))
end

-- THE INSTALLER LAST VERDICT, from its own log (work retry #3, 27/11: the status line said "no installer block ...
-- names 82f57859" while deploy.out held `refused(canonical runtime binding ...)` - the reason existed and the surface
-- did not carry it). Empty when the log holds none, so a caller never shows a sentence the deploy did not say.
function M.refused_line(options, paths_in)
  local p = paths_in or M.paths(options)
  local text = read(p.deploy_out)
  if not text then return "" end
  local last = text:match("%-%-%- deploy [^\r\n]*%-%-%-(.*)$") or text
  local found = nil
  for line in last:gmatch("[^\r\n]+") do
    local s = trim(line)
    local hit = s:match("refused%([^%)]*%)[^\r\n]*")
    if hit then found = hit end
  end
  return found and trim(found) or ""
end

-- The deploy own refused(...) sentence, or "" - joined onto a failure line that came from another record (the build
-- status, the queue) so the one line a person reads still carries the installer reason (work retry #3, 27/11).
function M.refused_join(options, paths_in, existing)
  local refused = M.refused_line(options, paths_in)
  if refused == "" then return "" end
  if existing and existing:find(refused, 1, true) then return "" end
  return " - " .. refused
end

function M.declared(options, paths_in)
  local p = paths_in or M.paths(options)
  local text = read(p.deploy_out)
  if not text then return nil end
  -- Only the LAST deploy's words: each deploy appends a header (`--- deploy ... ---`) before its output.
  local last = text:match("%-%-%- deploy [^\r\n]*%-%-%-(.*)$") or text
  if last:match("deploy: installing the published binary") then return "published" end
  if last:match("deploy: no published binary for this commit") then return "build" end
  return nil
end

-- The installer's own last lines for this request, at most eight non-empty ones. Printed above the `next:`
-- line of a failure: the reason is usually the last thing it said, and nobody should need a file path to
-- read it (Victor, 24/11). Empty when it said nothing - never filled with words of this module's own.
function M.evidence_lines(options, limit)
  local p = (options and options.paths) or M.paths(options)
  local text = read(p.deploy_out)
  if not text then return {} end
  local section = text:match("%-%-%- deploy [^\r\n]*%-%-%-(.*)$") or text
  local lines = {}
  for line in tostring(section):gmatch("[^\r\n]+") do
    local value = trim(line)
    -- The `--- deploy ... ---` header is this module's separator, not the installer's word, and an empty
    -- line carries nothing a reader can act on.
    if value ~= "" and value:sub(1, 10) ~= "--- deploy" then lines[#lines + 1] = value end
  end
  local keep = math.max(0, math.floor(tonumber(limit) or 8))
  local first = math.max(1, #lines - keep + 1)
  local kept = {}
  for index = first, #lines do kept[#kept + 1] = lines[index] end
  return kept
end

-- `--verbose`: the installer's own words, STREAMED as they arrive (mission update-is-one-line, item 4).
-- Everything else goes to the deploy's log and is named in the last line; this is for the person who ASKED
-- for the detail. It reads only what the deploy already wrote, from where the last read stopped: no second
-- reader, no protocol, and nothing changes when nobody asks.
function M.tail(options, p, from, sink)
  local o = options or {}
  local text = read((p or M.paths(o)).deploy_out)
  if not text then return from or 0 end
  local at = tonumber(from) or 0
  if #text <= at then return #text end
  local fresh = text:sub(at + 1)
  for line in tostring(fresh):gmatch("[^\r\n]*[\r\n]+") do
    at = at + #line
    local value = trim(line)
    -- the `--- deploy ... ---` header is the deploy's separator, not the installer's word
    if value ~= "" and value:sub(1, 10) ~= "--- deploy" and type(sink) == "function" then sink(value) end
  end
  return at
end

-- The sentence with its clock. `now` defaults to the snapshot's own time, so a caller that already has
-- a snapshot adds no second read of the clock.
function M.text(snapshot, now)
  if type(snapshot) ~= "table" then return nil end
  local body = trim(snapshot.body)
  if body == "" then return nil end
  local from = tonumber(snapshot.clock_from) or tonumber(snapshot.started_at)
  if not from then return body end
  return body .. " \194\183 " .. elapsed((tonumber(now) or tonumber(snapshot.at) or from) - from)
end

-- ---- the wait between snapshots is an EVENT, not a poll (brief item 9) -------------------------
--
-- MEASURED before this: the follower slept one second between reads (`M.POLL`), so a phase the deploy had
-- already written could be up to a second late on the screen, and a command that finished in 200 ms still
-- paid a 1 s sleep before saying so. A deploy only ever CHANGES FILES, so the wait is on a file change:
-- `inotifywait` on the directories a deploy writes to, bounded by `M.HEARTBEAT` so an install that goes
-- quiet still gets its clock redrawn and never looks dead.
--
-- The tool is not assumed: `inotify-tools` is present on this machine (4.26.270) and absent on a minimal
-- host, and where it is absent the loop falls back to the 1 s poll - and SAYS SO, because a fixed poll on
-- the path is exactly what this item forbids and a silent fallback would hide it.
M.WAIT_TOOL = "inotifywait"
local wait_tool_answer = nil
function M.wait_tool(options)
  local o = options or {}
  if o.tool ~= nil then return o.tool == true end
  if wait_tool_answer ~= nil then return wait_tool_answer end
  local found = shell("command -v " .. M.WAIT_TOOL .. " >/dev/null 2>&1")
  wait_tool_answer = found ~= nil and (found.code or 1) == 0
  return wait_tool_answer
end

-- The directories a deploy writes into, in one list. Each is watched NON-recursively: the request lanes, the
-- data directory (build-status.json, deploy-pending.json), the sentinel directory (deploy.out) and the
-- install directory (installed.txt, deploy-result.json, deploy-state.json). A path that does not exist yet
-- is skipped by the command's own error (2>/dev/null) and the others still fire: a deploy that has not made a
-- lane yet is not a deploy nothing can be learned from.
function M.watch_paths(options)
  local p = (options and options.paths) or M.paths(options)
  local list = { p.data, p.sentinel, p.queue, p.requests, p.claimed, p.done, p.failed, p.install }
  local seen, out = {}, {}
  for _, dir in ipairs(list) do
    local value = trim(dir)
    if value ~= "" and not seen[value] then seen[value] = true; out[#out + 1] = value end
  end
  return out
end

-- One wait: returns `{ event = bool, tool = bool, seconds = n }`. `o.run` is the seam a test drives (the
-- command string is handed to it); `o.seconds` is the bound. Never blocks longer than the bound.
function M.wait(options)
  local o = options or {}
  local bound = math.max(1, math.floor(tonumber(o.seconds) or M.HEARTBEAT))
  if not M.wait_tool(o) then return { event = false, tool = false, seconds = bound } end
  local paths = o.paths and M.watch_paths({ paths = o.paths }) or M.watch_paths(o)
  if #paths == 0 then return { event = false, tool = true, seconds = bound } end
  local quoted = {}
  for _, dir in ipairs(paths) do quoted[#quoted + 1] = "'" .. dir .. "'" end
  -- No -m: ONE event ends the wait (the loop takes a snapshot and waits again). The bound is `timeout`, so a
  -- deploy that writes nothing for a while still returns and the heartbeat can speak.
  local command = "timeout " .. bound .. " " .. M.WAIT_TOOL ..
    " -q -e modify,close_write,create,moved_to,delete,attrib --format %w%f " .. table.concat(quoted, " ") .. " 2>/dev/null"
  local run = o.run or shell
  local ok, result = pcall(run, command)
  if not ok or type(result) ~= "table" then return { event = false, tool = true, seconds = bound } end
  local fired = trim(result.stdout or "") ~= ""
  return { event = fired, tool = true, seconds = bound, exit = tonumber(result.code) }
end

-- The line after a failure: what this node still runs, and where the deploy's own output is. Empty when
-- there is nothing true to say.
function M.next_line(options, snapshot)
  local p = (options and options.paths) or M.paths(options)
  local commit = M.installed_commit(options)
  local parts = {}
  if commit ~= "" then parts[#parts + 1] = "this node still runs " .. commit:sub(1, 12) end
  if type(snapshot) == "table" and trim(snapshot.detail) ~= "" then
    parts[#parts + 1] = "the installer's own output is " .. p.deploy_out
  else
    parts[#parts + 1] = "the deploy's own output is " .. p.deploy_out
  end
  return "next: " .. table.concat(parts, "; ")
end

-- ONE LOG FILE PER UPDATE (mission update-is-one-line, item 4). A deploy appends every install to one
-- `deploy.out`, so "the log of the update I just ran" is a section of it. This writes THIS request's own
-- section - the last `--- deploy ... ---` block - to its own file and returns its path, which is what the
-- last line names. It never invents a log: no request id, no file, or a section with nothing in it answers
-- nil and the caller names the deploy's own log instead.
function M.request_log(options)
  local o = options or {}
  local request = trim(o.request)
  local id = request:match("([^/\\]+)%.json$") or ""
  if id == "" then return nil end
  local p = o.paths or M.paths(o)
  local text = read(p.deploy_out)
  if not text then return nil end
  -- THE LAST deploy's block: every deploy appends its own `--- deploy ... ---` header before it writes a
  -- word, so the block that starts at the LAST header is this request's (the request wrote the newest one).
  local at = nil
  for start in text:gmatch("()%-%-%- deploy ") do at = start end
  if not at then return nil end
  local section = text:sub(at)
  if trim(section) == "" then return nil end
  local dir = slashes(p.config) .. "/update-log"
  local path = dir .. "/" .. id .. ".log"
  local made = shell("mkdir -p " .. "'" .. dir .. "' 2>/dev/null")
  if not made or (made.code or 1) ~= 0 then return nil end
  local ok = pcall(host.write_file, path, section)
  if not ok then return nil end
  return path
end

-- ---- the loop ----------------------------------------------------------------
--
-- Prints one line per change of body (and a heartbeat every M.HEARTBEAT seconds while nothing changes),
-- and returns when the install is over. `out`, `sleep`, `clock`, `poll`, `polls` and `seconds` are seams:
-- a test drives the whole loop without wall clock, and a terminal gets a line the moment a phase changes.
function M.follow(options)
  local o = options or {}
  local out = o.out or function(line) print(line) end
  -- THE ONE MOVING LINE (mission update-is-one-line, 25/11): when a screen is handed in, it owns what the
  -- person sees and this loop prints no line of its own - it hands over a BODY (no clock: the screen draws
  -- one clock for the whole command) and, at the end, nothing: the caller prints the last line.
  local screen = o.screen
  local verbose = o.verbose == true
  local clock = o.clock or clock_default
  local pause = o.sleep or function(seconds)
    if host.sleep then host.sleep(math.max(1, math.floor(seconds * 1000))) end
  end
  -- THE WAIT IS AN EVENT WHEN THE HOST CAN WATCH FILES (see M.wait). `o.sleep` is the seam the deterministic
  -- tests drive: a caller that hands one gets it, unchanged. `o.wait` is the same seam one level down.
  local function settle()
    if o.sleep then return pause(poll) end
    local waited = o.wait and o.wait({ seconds = M.HEARTBEAT, next = false }) or M.wait({ paths = o.paths, seconds = M.HEARTBEAT })
    if waited and waited.tool == false then return pause(poll) end
    return waited
  end
  local poll = tonumber(o.poll) or M.POLL
  local bound = tonumber(o.bound)
  if bound == nil then
    bound = tonumber(trim(host.getenv and host.getenv("WA_UPDATE_FOLLOW_BOUND") or "")) or M.UNPERFORMED_BOUND
  end
  local started = clock()
  -- WHERE THE VERBOSE TAIL STARTS: at the end of the log as it is when this caller attaches, so --follow
  -- does not replay a log that already exists.
  local tail_at = verbose and #(read(M.paths(o).deploy_out) or "") or 0
  local rounds, printed = 0, 0
  local last_body, last_at = nil, nil
  local declared_printed = false
  while true do
    local now = clock()
    local snapshot = M.state({ paths = o.paths, id = o.id, request = o.request,
      started_at = o.started_at, target = o.target, now = now })
    local body = trim(snapshot.body)
    -- THE INSTALLER SAID IT IS BUILDING: only now may the word "build" be printed (Fable 24/11, A). Once.
    -- WITH A SCREEN this is the phase body's own suffix ("(from source, on this machine)"): a second line
    -- would be a second line on a screen that has one.
    if not screen and not declared_printed and snapshot.declared == "build" then
      out(M.build_declared_line(o))
      printed = printed + 1
      declared_printed = true
      last_body, last_at = body, now
    end
    if screen then
      -- the phase, not the clock: a body that did not change is not a change on a pipe, and on a terminal
      -- it is the same line rewritten (the screen decides both). A TERMINAL snapshot draws nothing: the
      -- last line says what happened (`update_screen.updated` / `not_updated`), and a phase that said
      -- "installed" first would be the same fact twice.
      if not snapshot.terminal then screen:phase(body, snapshot.clock_from) end
      if verbose then
        tail_at = M.tail(o, M.paths(o), tail_at, function(line) screen:line(line) end)
      end
      last_body, last_at = body, now
    elseif body ~= last_body or not last_at or (now - last_at) >= M.HEARTBEAT then
      out(M.text(snapshot, now))
      printed = printed + 1
      last_body, last_at = body, now
    end
    if snapshot.terminal then
      if snapshot.ok ~= true and not screen then
        -- THE INSTALLER'S OWN LAST LINES, above the advice: nobody should need a file path to read why.
        -- With a screen they are NOT printed: the last line carries one reason and the log is named.
        for _, line in ipairs(M.evidence_lines(o, 8)) do
          out("  " .. line)
          printed = printed + 1
        end
        local advice = M.next_line(o, snapshot)
        if advice then out(advice); printed = printed + 1 end
      end
      return { ok = snapshot.ok == true, state = snapshot.key, body = body, detail = snapshot.detail,
        problems = tonumber(snapshot.problems) or (snapshot.key == "installed_with_problems" and 1 or 0),
        commit = snapshot.commit, seconds = now - started, rounds = rounds, printed = printed }
    end
    rounds = rounds + 1
    -- A REQUEST THE SENTINEL HAS NOT STARTED does not hold a terminal forever: past the installer's own
    -- idle bound, stop following and say so, with the one command that picks it up again.
    local idle = snapshot.key == "queued" or snapshot.key == "waiting" or snapshot.key == "unknown"
    if idle and bound > 0 and (now - (tonumber(o.started_at) or started)) >= bound then
      if not screen then
        out("stopped following after " .. elapsed(now - (tonumber(o.started_at) or started)) ..
          ": the sentinel has not started this request (" .. body .. "); wa update --follow picks it up again")
        printed = printed + 1
      end
      return { ok = false, state = snapshot.key, body = body, unknown = true, unperformed = true,
        seconds = now - started, rounds = rounds, printed = printed }
    end
    if (o.polls and rounds >= o.polls) or (o.seconds and (now - started) >= o.seconds) then
      return { ok = false, state = snapshot.key, body = body, unknown = true, timed_out = true,
        seconds = now - started, rounds = rounds, printed = printed }
    end
    settle()
  end
end

-- The line printed the moment the installer says it is building (text #2 of the approved list): until then
-- `wa update` may only say the installer LOOKS for a covered release, because that is what it does.
function M.build_declared_line(options)
  local o = options or {}
  local sha = trim(o.target):sub(1, 12)
  if sha == "" then sha = "this commit" end
  local triple = trim(o.triple)
  if triple == "" then triple = "this machine" end
  return "no published binary for " .. sha .. " on " .. triple .. ": building from source, minutes"
end

-- ---- the first line: download or build ---------------------------------------
--
-- The person must know, before the minutes are spent, whether this install downloads or compiles. That
-- answer already has an owner (`lua/core/update_banner.lua`'s release list, read from this node's own
-- cache - no request here), and this turns it into the one line `wa update` prints first.
function M.plan(options)
  local o = options or {}
  local target = trim(o.target)
  local sha = target:sub(1, 12)
  local answer = nil
  local ok, banner = pcall(dofile, "lua/core/update_banner.lua")
  if ok and type(banner) == "table" and type(banner.published) == "function" and #target >= 7 then
    local called, reply = pcall(banner.published, target,
      { tree = o.tree, target = o.triple, cache_path = o.cache_path, order = o.order, now = o.now })
    if called and type(reply) == "table" then answer = reply end
  end
  local triple = (answer and trim(answer.target) ~= "") and answer.target
    or (ok and type(banner) == "table" and type(banner.target) == "function" and banner.target({}) or nil)
    or "this machine"
  local lines = {}
  local state = answer and trim(answer.state) or "unknown"
  -- TWO LINES AND NO THIRD (Fable 24/11, A). "No published binary ... building from source" is a claim this
  -- command cannot make: `scripts/deploy.sh` then SEARCHES for a release built from the same compiled inputs
  -- (`wa_node_release_digest_search`), and that finds a covering release for every scripts/Lua-only landing -
  -- which is most of them. So: a binary for this exact commit, named, when the release list names one; and
  -- otherwise ONE line that says what the installer actually does. The word "building" is printed only when
  -- the installer says it is building (`M.build_declared_line`, once its own output says so).
  if sha == "" then
    lines[#lines + 1] = "no published binary is named for this commit here: the installer looks for one built from " ..
      "the same inputs, and builds from source only if there is none (minutes)"
  elseif state == "published" then
    lines[#lines + 1] = "install: published binary for " .. sha .. " on " .. triple .. " \226\128\148 download, no build"
  else
    lines[#lines + 1] = "no published binary is named for " .. sha .. " here: the installer looks for one built from " ..
      "the same inputs, and builds from source only if there is none (minutes)"
  end
  return { lines = lines, published = answer, target = sha, triple = triple }
end

-- ---- what to follow when nothing was just asked --------------------------------
--
-- `wa update --follow` with no fresh request: the newest deploy this node still has in flight. The result
-- is the request file (its name is the request id) or nil and a reason - never a guess.
function M.latest(options)
  local p = (options and options.paths) or M.paths(options)
  local function newest_in(lane)
    local listed = shell("ls -1t " .. "'" .. lane .. "' 2>/dev/null | head -20")
    local first = trim(listed and listed.stdout or ""):match("^[^\r\n]+")
    return first
  end
  for _, lane in ipairs({ p.claimed, p.requests }) do
    local name = newest_in(lane)
    if name and name:match("%.json$") then return lane .. "/" .. name, lane end
  end
  -- No live request: the newest queue record that is not settled names a deploy still being performed.
  local name = newest_in(p.queue)
  if name and name:match("%.json$") then
    local record = decode(p.queue .. "/" .. name)
    local state = trim(record and record.state)
    if state == "queued" or state == "waiting" or state == "running" then
      return p.queue .. "/" .. name, p.queue
    end
    return nil, "the newest request on this node is " .. (state ~= "" and state or "unknown") .. " (" .. name .. ")"
  end
  return nil, "no deploy request is in this node's box"
end

return M
