-- A DEPLOY REQUEST THAT IS STILL WAITING IS ALREADY A REASON TO STOP STARTING TURNS.
--
-- Measured twice on this laptop (22/11 09:43Z and 10:01Z, ~/.wasm-agent/sentinel/sentinel.log): a deploy
-- request sat in the sentinel's box for 34 and 30 minutes with "held: node busy" while three workers ran,
-- and it ran only after the operator parked four sessions by hand and stopped one `wa chat --once`. The
-- pause signal that exists (lua/core/deploy_pause.lua) is the INSTALLER's marker, and the installer writes
-- it only after the request has been performed - so it covers the swap and never the wait, which is the
-- part that starves: while a request is merely held there is no marker, a running turn is never asked to
-- pause, every resume wake is released at once ("the marker is gone"), and each new `wa chat --once`, wake
-- or child keeps the node busy for another turn.
--
-- So the node reads the request itself. The sentinel's box is a directory of durable JSON files
-- (`<data>/sentinel/requests/*.json`), written before anything is performed and renamed out of the box when
-- the request is claimed or withdrawn; a request waiting there is a fact no process has to be told about,
-- it survives the writer (the sentinel may be a unit of its own), and it names the commit that is coming.
-- lua/core/cli_view.lua already reads the same directory to draw "restarting" on the status row, so this is
-- one more reader of a file shape that exists, not a new channel.
--
-- WHAT THIS IS NOT. It does not decide whether the deploy is *possible* - the sentinel owns that, from
-- state this module cannot see (protocol readiness, request capacity, the node's own health). It answers one
-- question - "is a build waiting to be installed, or being installed" - and a caller that gets an answer
-- refuses to start a turn, which is the whole of its job. It is bounded, so a request that can never run
-- cannot freeze the node: past its bound the wait is ignored, exactly as an expired installer marker is.
local json = dofile("lua/vendor/json.lua")

local M = {}

-- The box, inside the node's data directory. The path is the sentinel's own (rust/wa-sentinel/src/main.rs,
-- `sentinel_dir`): `<home>/.wasm-agent/sentinel`, and `M.LANES` are its two lanes. `M.dir()` is that directory
-- and NOT one lane: a lane is appended per read, so the two cannot drift apart (measured by
-- scripts/test-deploy-wait.sh's first run: `M.dir()` returned `<data>/sentinel/requests` and the read appended
-- `requests` again - every process then agreed the box was empty while the request sat in it).
M.SUBDIR = "sentinel"
-- The box has two lanes a deploy lives in: it waits in `requests/`, and the moment the sentinel claims it the
-- file is renamed into `claimed/` (rust/wa-sentinel/src/main.rs: the rename IS the claim) before the installer
-- is started. Reading only the first lane would leave a gap - request gone, installer's marker not written
-- yet, because `scripts/deploy.sh` verifies the tree and builds before `scripts/upgrade.sh` writes it - and in
-- that gap a new turn would start, keep the node busy, and delay the install it is racing. So both lanes count,
-- and `source` says which one answered.
M.LANES = { "requests", "claimed" }
-- How long a waiting request keeps the node's new turns stopped. A deploy's own install bound is 900 s
-- (lua/core/deploy_pause.lua's DEFAULT_BOUND, written by the installer); this is the same number for the
-- wait BEFORE it, and it is deliberately generous: the sentinel bounds the wait itself (3 minutes, then it
-- proceeds when the only holders are paused sessions), so this only has to outlive a legitimate wait.
M.DEFAULT_BOUND = 900
-- The one sentence every caller says, so a reader meets the same words in a chat refusal, a wake's deferred
-- row and a session's status line.
M.REASON = "waiting for the install of"
-- Verbs that REPLACE this node's bytes, and therefore need the node idle: `deploy` only. `upgrade` is
-- retired and held by name by the sentinel (it never runs), so honouring it would stop the node for a
-- request that cannot happen; `restart`, `stop`, `recover`, `spell`, `run` and `wake` do not install a new
-- build, so no "waiting for the install of <sha>" is true of them. An allow-list, not a list of the ones to
-- ignore: a verb added to the sentinel must be named here before it can pause the node.
M.INSTALLING = { deploy = true }

-- Where a paused session says so: `<data>/deploy-paused/<session>.json`, one file per session so two
-- sessions pausing at once never write the same file (lua/core/deploy_pause.lua writes it, and
-- `wa-sentinel status` reads it to tell a paused holder from a working one).
M.PAUSE_SUBDIR = "deploy-paused"
M.PAUSE_FRESH = 1800

function M.dir(data_dir)
  local root = data_dir
  if type(root) ~= "string" or root == "" then
    local ok, data = pcall(function() return dofile("lua/core/paths.lua").data() end)
    if not ok or type(data) ~= "string" or data == "" then return nil end
    root = data
  end
  return root .. "/" .. M.SUBDIR
end

-- One lane by name: `requests` (waiting) or `claimed` (being installed).
function M.lane_dir(lane, data_dir)
  local dir = M.dir(data_dir)
  if not dir then return nil end
  return dir .. "/" .. tostring(lane)
end

-- The queue time of a request whose file does not carry `queued_at`: the file is named
-- `<epoch-nanos>-<pid>-<sequence>.json`, so the name is when the writer asked. The first ten digits, as
-- text: 1.8e18 nanoseconds does not survive a float64, and a wait measured from a rounded time would be a
-- wait of the wrong length.
function M.stamp_seconds(name)
  local digits = tostring(name or ""):match("^(%d+)")
  if not digits or #digits < 10 then return nil end
  local seconds = tonumber(digits:sub(1, 10))
  if not seconds or seconds <= 0 then return nil end
  return seconds
end

-- The first positive number among the arguments. `select('#', ...)` and not `ipairs({ ... })`: a table built
-- from a list whose FIRST element is nil is EMPTY, so `positive(nil, 900)` answered nil and every request
-- without its own bound was refused as `no_bound` (measured by scripts/test-deploy-wait.lua, first run).
local function positive(...)
  local count = select("#", ...)
  for index = 1, count do
    local number = tonumber((select(index, ...)))
    if number and number > 0 then return number end
  end
  return nil
end

-- Decode and judge one request file. Pure: `now` and the bound are arguments, so a test needs no clock and
-- no filesystem. Returns nil and the reason when this file is not a deploy waiting for the node, or the
-- wait in the shape the pause and the refusal both read (`to`, `since`, `bound_seconds`, `id`).
function M.decode(text, name, now, bound_default)
  if type(text) ~= "string" or text == "" then return nil, "absent" end
  local ok, request = pcall(json.decode, text)
  if not ok or type(request) ~= "table" then return nil, "unreadable" end
  local verb = tostring(request.verb or "")
  if not M.INSTALLING[verb] then return nil, "not_an_install" end
  local since = positive(request.queued_at) or M.stamp_seconds(name)
  if not since then return nil, "no_since" end
  -- An explicit bound is obeyed as given, INCLUDING a zero: `bound_seconds = 0` means "no bound", and a
  -- reader that turned that into the harness default would pause the node for ever on a request whose writer
  -- meant it to never hold anything. The same rule as the installer's marker (deploy_pause.decode).
  local bound = tonumber(bound_default)
  if bound == nil then bound = M.DEFAULT_BOUND end
  if not bound or bound <= 0 then return nil, "no_bound" end
  if (tonumber(now) or 0) > since + bound then return nil, "expired" end
  return {
    source = "request",
    verb = verb,
    id = tostring(name or ""):gsub("%.json$", ""),
    to = request.expected_sha or request.target_commit,
    since = since,
    bound_seconds = bound,
    session = request.session,
    owner = request.owner,
    by = "the sentinel's request box",
  }
end

-- The oldest installing request waiting in the box, or nil and why there is none. Nothing here is cached:
-- the box is a handful of small files and a step boundary is where a stale answer would cost a turn.
-- `opts` (`dir`, `list`, `read`, `bound`) exists for the test; a real caller passes nothing and gets the
-- host's own list and read of the node's data directory.
function M.read(now, opts)
  opts = opts or {}
  now = tonumber(now) or os.time()
  local dir = opts.dir or M.dir()
  if not dir then return nil, "no_path" end
  local list = opts.list
  if type(list) ~= "function" then
    if type(host) ~= "table" or type(host.list_dir) ~= "function" then return nil, "no_list_dir" end
    list = function(path) return host.list_dir(path) end
  end
  local reader = opts.read
  if type(reader) ~= "function" then
    reader = (type(host) == "table" and type(host.read_file) == "function") and host.read_file or nil
  end
  local lanes = opts.lanes or M.LANES
  local candidates = {}
  local why = "no_box"
  local any_names = false
  for _, lane in ipairs(lanes) do
    local listed, raw = pcall(list, dir .. "/" .. lane)
    if listed and type(raw) == "string" then
      local decoded, listing = pcall(json.decode, raw)
      if decoded and type(listing) == "table" and type(listing.entries) == "table" then
        why = "empty"
        for _, entry in ipairs(listing.entries) do
          local name = tostring(type(entry) == "table" and entry.name or "")
          if name:sub(-5) == ".json" and (type(entry) ~= "table" or entry.kind == "file") then
            any_names = true
            candidates[#candidates + 1] = { lane = lane, name = name }
          end
        end
      end
    end
  end
  if not any_names and why == "empty" then why = "empty" end
  -- Oldest first: the queue runs in the order it was written, and so does this reader.
  table.sort(candidates, function(left, right)
    if left.name == right.name then return left.lane < right.lane end
    return left.name < right.name
  end)
  for _, candidate in ipairs(candidates) do
    local text
    if reader then
      local read_ok, body = pcall(reader, dir .. "/" .. candidate.lane .. "/" .. candidate.name)
      if read_ok and type(body) == "string" then text = body end
    end
    local wait, reason = M.decode(text, candidate.name, now, opts.bound)
    if wait then
      wait.source = (candidate.lane == "claimed") and "claimed" or "request"
      wait.lane = candidate.lane
      return wait
    end
    if reason then why = reason end
  end
  return nil, why
end

-- "2m ago" / "14s ago": the operator reads how long the install has been wanted.
local function ago(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds < 60 then return string.format("%ds ago", seconds) end
  if seconds < 3600 then return string.format("%dm ago", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%dh ago", math.floor(seconds / 3600)) end
  return string.format("%dd ago", math.floor(seconds / 86400))
end

-- The one sentence a reader meets: which commit is coming, which request asked for it, and how long it has
-- waited. Always starts with M.REASON, so it can be found in a log or matched by a caller.
function M.say(wait, now)
  wait = wait or {}
  local sha = tostring(wait.to or "")
  local target = sha ~= "" and sha:sub(1, 12) or "an unnamed commit"
  local since = tonumber(wait.since) or 0
  local waited = since > 0 and ago((tonumber(now) or os.time()) - since) or "for an unrecorded time"
  return string.format("%s %s (deploy request %s, asked %s)",
    M.REASON, target, tostring(wait.id or "unnamed"), waited)
end

-- What a turn that did NOT start says: the wait, and that nothing was lost. The first word is a name the
-- log, the tests and `wa session status` can match on (`deploy_waiting`), like `no_dispatchable_tools`.
function M.refusal(wait, now)
  return "deploy_waiting: " .. M.say(wait, now) .. ". This node starts no new turn while a build is "
    .. "waiting for it or being installed - a turn in flight is exactly what keeps the node from going "
    .. "idle - and this turn did not start. Nothing was lost: this is a wait, not a failure, and the work "
    .. "starts again once the swap is done. A running turn pauses after its current step instead "
    .. "(lua/core/deploy_pause.lua). To stop waiting, withdraw the request: "
    .. "wa-sentinel request withdraw " .. tostring(wait and wait.id or "<id>")
end

return M
