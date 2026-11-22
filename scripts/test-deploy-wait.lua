-- A deploy request that is still WAITING is a reason not to start a turn (lua/core/deploy_wait.lua).
--
-- MEASURED twice on this laptop (22/11, ~/.wasm-agent/sentinel/sentinel.log): a deploy request sat in the
-- sentinel's box 34 and 30 minutes with "held: node busy" while workers ran. The pause signal that existed
-- was the INSTALLER's marker, written only after the request had been performed - so the wait, which is the
-- part that starves, was covered by nothing: no running turn was asked to pause, every resume wake was
-- released at once ("the marker is gone"), and every new `wa chat --once`, wake or child kept the node busy
-- for another turn. This row holds the reader that closes it: the sentinel's own request box, read by the
-- node, bounded, and turned into the one sentence a caller refuses a turn with.
--
-- Run from the repo root, in a scratch home (this row writes a box, a marker and pause records):
--   WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-deploy-wait.lua wa --db <that home>/t.db
local json = dofile("lua/vendor/json.lua")
local function refuse(why) print("REFUSED test-deploy-wait: " .. why); os.exit(2) end
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-deploy-wait")
if why_home then refuse(why_home) end

local wait = dofile("lua/core/deploy_wait.lua")
local pause = dofile("lua/core/deploy_pause.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end
-- An allow-list of what a refusal may say, checked by `find` rather than by pattern quoting.
local function says(text, needle, label)
  checks = checks + 1
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    error(label .. ": expected " .. needle .. " in: " .. tostring(text), 2)
  end
end

local NOW = 1800000000
local SHA = "8082b42e11112222333344445555666677778888"

-- 1. What a request file means, and what it does not: purely, with the clock as an argument.
local function request(overrides)
  local value = { verb = "deploy", expected_sha = SHA, queued_at = NOW - 120, reason = "land the fix" }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return json.encode(value)
end
local absent, why_absent = wait.decode(nil, "1700000000000000000-1-0.json", NOW)
ok(absent == nil and why_absent == "absent", "no file is not a wait")
local broken, why_broken = wait.decode("{not json", "x.json", NOW)
ok(broken == nil and why_broken == "unreadable", "a corrupt request is not obeyed")
-- An ALLOW-LIST of verbs: only one that installs a build stops the node. `upgrade` is retired and held for
-- ever by name, so honouring it would freeze a node for a request that can never run; the rest install
-- nothing and no "waiting for the install of <sha>" would be true of them.
for _, verb in ipairs({ "restart", "stop", "recover", "spell", "run", "wake", "upgrade", "" }) do
  local other, why = wait.decode(request({ verb = verb }), "1700000000000000000-1-0.json", NOW)
  ok(other == nil and why == "not_an_install", "only a deploy installs: " .. verb)
end
local live = wait.decode(request(), "1700000000000000000-1-0.json", NOW)
eq(live.verb, "deploy", "a deploy is a wait")
eq(live.to, SHA, "the wait names the commit that is coming")
eq(live.since, NOW - 120, "and when it was asked for")
eq(live.source, "request", "a file in the box is a request")
eq(live.bound_seconds, wait.DEFAULT_BOUND, "with the harness bound when none is given")
-- The file is named `<epoch-nanos>-<pid>-<sequence>.json`, so a request written before `queued_at` existed
-- still has a time: read from the name, in seconds, from the first ten digits (1.8e18 ns is not a float64).
eq(wait.stamp_seconds("1700000000123456789-4242-0.json"), 1700000000, "the queue time is in the name")
eq(wait.stamp_seconds("not-a-stamp.json"), nil, "a name that is not a stamp has no time")
local undated = wait.decode(json.encode({ verb = "deploy", expected_sha = SHA }),
  NOW .. "123456789-4242-0.json", NOW)
ok(undated ~= nil and undated.since == NOW, "a request with no queued_at takes its time from its name")
local dated = wait.decode(json.encode({ verb = "deploy", expected_sha = SHA }), "n.json", NOW)
ok(dated == nil, "a request with no time at all cannot be bounded, so it is ignored")
-- Bounded: a request that can never run (a held protocol, an operator who walked away) must not freeze the
-- node for ever. Past its bound the wait is ignored, exactly as an expired installer marker is.
local expired, why_expired = wait.decode(request({ queued_at = NOW - wait.DEFAULT_BOUND - 1 }),
  "1700000000000000000-1-0.json", NOW)
ok(expired == nil and why_expired == "expired", "an expired request stops pausing the node")
local bounded = wait.decode(request(), "1700000000000000000-1-0.json", NOW, 300)
eq(bounded.bound_seconds, 300, "the bound is an argument, so a test needs no clock")
local unbound, why_unbound = wait.decode(request(), "1700000000000000000-1-0.json", NOW, 0)
ok(unbound == nil and why_unbound == "no_bound", "a bound of zero is not a bound")

-- 2. The box: two lanes, oldest first, and one unreadable file does not hide a good request behind it.
local scratch = host.getenv("WASM_AGENT_HOME") .. "/.wasm-agent/sentinel"
local function box(files)
  for lane, entries in pairs(files) do
    host.exec("mkdir -p '" .. scratch .. "/" .. lane .. "'", "", 30)
    for name, text in pairs(entries) do
      ok(host.write_file(scratch .. "/" .. lane .. "/" .. name, text), "write " .. lane .. "/" .. name)
    end
  end
end
local function listing(lanes)
  return function(path)
    local lane = path:match("/([^/]+)$")
    if not lanes[lane] then return json.encode({ path = path, error = "no_such_directory" }) end
    return json.encode({ path = path, entries = lanes[lane] })
  end
end
local function reader(texts)
  return function(path)
    local name = path:match("([^/]+)$")
    for key, text in pairs(texts) do
      if path:find(key, 1, true) then return text end
    end
    return texts[name]
  end
end
local empty, why_empty = wait.read(NOW, { dir = "/box", list = listing({ requests = {}, claimed = {} }) })
ok(empty == nil and why_empty == "empty", "an empty box is not a wait")
local missing, why_missing = wait.read(NOW, { dir = "/box", list = listing({}) })
ok(missing == nil and why_missing == "no_box", "a box that does not exist is not a wait")
local found = wait.read(NOW, { dir = "/box",
  list = listing({ requests = { { name = "1700000000100000000-1-0.json", kind = "file" } },
                   claimed = {} }),
  read = reader({ ["1700000000100000000-1-0.json"] = request({ queued_at = NOW - 10 }) }) })
ok(found ~= nil and found.since == NOW - 10, "a request in the box is a wait")
eq(found.lane, "requests", "and it says which lane answered")
-- THE CLAIM IS STILL A DEPLOY. The file is renamed into `claimed/` before the installer starts, and
-- scripts/deploy.sh verifies and builds before scripts/upgrade.sh writes its own marker: reading only the
-- first lane would leave that gap uncovered, and a turn started in it keeps the node busy during the
-- install it is racing.
local claimed = wait.read(NOW, { dir = "/box",
  list = listing({ requests = {}, claimed = { { name = "1700000000200000000-2-0.json", kind = "file" } } }),
  read = reader({ ["1700000000200000000-2-0.json"] = request({ queued_at = NOW - 20 }) }) })
ok(claimed ~= nil and claimed.source == "claimed", "a claimed request is a deploy in flight")
-- Oldest first across both lanes, and a file that cannot be read does not hide the next one.
local oldest = wait.read(NOW, { dir = "/box",
  list = listing({ requests = { { name = "1700000000300000000-3-0.json", kind = "file" } },
                   claimed = { { name = "1700000000100000000-9-0.json", kind = "file" } } }),
  read = reader({ ["1700000000300000000-3-0.json"] = request({ expected_sha = "b", queued_at = NOW - 30 }),
                  ["1700000000100000000-9-0.json"] = request({ expected_sha = "a", queued_at = NOW - 10 }) }) })
eq(oldest.to, "a", "the oldest request in the box is the one answered")
local skipped = wait.read(NOW, { dir = "/box",
  list = listing({ requests = { { name = "1700000000100000000-1-0.json", kind = "file" },
                                { name = "1700000000200000000-2-0.json", kind = "file" } },
                   claimed = {} }),
  read = reader({ ["1700000000100000000-1-0.json"] = "{not json",
                  ["1700000000200000000-2-0.json"] = request({ queued_at = NOW - 10 }) }) })
ok(skipped ~= nil and skipped.id:find("1700000000200000000", 1, true) ~= nil,
  "an unreadable request is skipped, not in the way")

-- 3. The sentence. Every caller says the same words, and they name the commit, the request and the verb that
-- stops the wait - an operator reads one line and can act on it.
local sentence = wait.say(live, NOW)
says(sentence, wait.REASON .. " 8082b42e1111", "the sentence names the commit that is coming")
says(sentence, "1700000000000000000-1-0", "and the request that asked for it")
says(sentence, "2m ago", "and how long it has waited")
local refusal = wait.refusal(live, NOW)
says(refusal, "deploy_waiting:", "a refusal starts with the name a log and a test can match")
says(refusal, "wa-sentinel request withdraw 1700000000000000000-1-0", "and names the way out")
says(refusal, "Nothing was lost", "and says a wait is not a failure")
local unnamed = wait.refusal({ id = "x", since = NOW - 5 }, NOW)
says(unnamed, "an unnamed commit", "a request that recorded no commit says so")

-- 4. One predicate for both halves of the signal: the installer's marker still wins (its sentence is the one
-- an operator and the deploy tests already read), and with no marker the request answers instead.
local marker_wait = pause.waiting(NOW, { read = function() return nil end,
  read_request = function() return wait.decode(request(), "1700000000000000000-1-0.json", NOW) end })
ok(marker_wait ~= nil and marker_wait.source == "request", "a waiting request is a deploy pause")
eq(pause.say_wait(marker_wait, NOW):sub(1, 14), "deploy waiting", "and a paused turn says it is waiting")
says(pause.say_wait(marker_wait, NOW), "waiting for the install of 8082b42e1111",
  "with the words the operator has to be told")
local marker_beats_request = pause.waiting(NOW, {
  read = function() return { since = NOW - 5, bound_seconds = 600, to = SHA, by = "upgrade.sh" } end,
  read_request = function() return wait.decode(request(), "1700000000000000000-1-0.json", NOW) end })
ok(marker_beats_request ~= nil and marker_beats_request.source == nil,
  "the installer's own marker is answered first: the swap is under way")
says(pause.say_wait(marker_beats_request, NOW), "deploy pending",
  "and it keeps the sentence an installing node always said")

-- 5. The turn's own ending: one pause per run, ONE wake, a short arm (the node looks again in a minute) and a
-- checkpoint - plus the record that tells the sentinel this session is paused rather than working.
local noted = 0
local scheduled = {}
local self = { session_id = "deploy-wait-session", user = "master" }
local boundary = pause.at_boundary(self, "carry on with the fix", {
  now = NOW,
  read = function() return nil end,
  read_request = function() return wait.decode(request(), "1700000000000000000-1-0.json", NOW) end,
  notes = function() noted = noted + 1 end,
  schedule = function(args) scheduled[#scheduled + 1] = args; return { wake = { id = "w-1" } } end,
})
ok(boundary ~= nil, "a running turn pauses for a waiting request")
eq(#scheduled, 1, "exactly one resume wake")
eq(scheduled[1].in_seconds, pause.WAIT_RESUME_SECONDS, "armed for the short wait, not the installer's bound")
eq(scheduled[1].reason, pause.RESUME_REASON, "with the reason the release matches on")
eq(noted, 1, "and a checkpoint before the turn ends")
says(boundary.text, "waiting for the install of 8082b42e1111", "the turn's ending says what it waits for")
local record_path = pause.paused_dir() .. "/deploy-wait-session.json"
local recorded = host.read_file(record_path)
ok(type(recorded) == "string" and #recorded > 0, "the pause is recorded where the sentinel reads it: " .. record_path)
local record = json.decode(recorded)
eq(record.session, "deploy-wait-session", "the record names the session")
eq(record.since, NOW, "and when it paused")
eq(record.request, "1700000000000000000-1-0", "and which request it paused for")
eq(record.to, SHA, "and which commit is coming")

-- 6. Nothing is released while a deploy is merely WAITING: a resumed turn now is the turn that keeps the node
-- busy, which is the half hour this exists to remove.
local rows = {}
local released = pause.release_due(NOW, {
  read = function() return nil end,
  read_request = function() return wait.decode(request(), "1700000000000000000-1-0.json", NOW) end,
  query = function() return rows end,
  exec = function() rows.changed = (rows.changed or 0) + 1; return { changes = 1 } end })
eq(released, 0, "a waiting request releases no resume")
eq(rows.changed, nil, "and the ledger was not touched")

-- 7. The gate itself is an allow-list of one thing: `operator_present`. A turn with a person in front of it
-- is not refused (that is lua/core/agent.lua's rule, and this is the same predicate it reads).
local operator = pause.waiting(NOW, { read = function() return nil end,
  read_request = function() return wait.decode(request(), "1700000000000000000-1-0.json", NOW) end })
ok(operator ~= nil, "the predicate a refused turn and a paused turn share")

-- 7b. AN OPERATOR'S TURN IS PAUSED ONLY FOR THE REAL SWAP (review MUST 2). A request that is only waiting
-- needs the node to stop STARTING turns, not to cut the turn a person is in the middle of: their multi-step
-- work would be ended after every step for as long as the wait lasts. The installer's marker is the launch
-- sequence itself and pauses everybody, as it always did.
local operator = { session_id = "operator-session", user = "master", operator_present = true }
local operator_runs = 0
local operator_paused = pause.at_boundary(operator, "carry on", {
  now = NOW,
  read = function() return nil end,
  read_request = function() return wait.decode(request(), "1700000000000000000-1-0.json", NOW) end,
  notes = function() operator_runs = operator_runs + 1 end,
  schedule = function() error("an operator's turn must not schedule a resume for a waiting request") end })
ok(operator_paused == nil and operator_runs == 0, "a waiting request does not end the operator's turn")
local operator_marker = pause.at_boundary({ session_id = "operator-session-2", user = "master", operator_present = true },
  "carry on", {
    now = NOW,
    read = function() return { since = NOW - 5, bound_seconds = 600, to = SHA, by = "upgrade.sh" } end,
    notes = function() end,
    schedule = function(args) return { wake = { id = "w-op" } } end })
ok(operator_marker ~= nil and operator_marker.wake and operator_marker.wake.id == "w-op",
  "the real swap still pauses an operator's turn")
says(operator_marker.text, "deploy pending", "with the sentence an installing node always said")
-- ...and an AUTOMATIC turn still pauses for the waiting request: the exemption is the person, not the path.
local automatic = pause.at_boundary({ session_id = "automatic-session", user = "master" }, "carry on", {
  now = NOW,
  read = function() return nil end,
  read_request = function() return wait.decode(request(), "1700000000000000000-1-0.json", NOW) end,
  notes = function() end,
  schedule = function() return { wake = { id = "w-auto" } } end })
ok(automatic ~= nil, "a turn without a person in front of it pauses for the same request")

print("deploy wait ok (" .. checks .. " checks)")
