-- start-instant: a turn's first model call must not wait for another process's ledger write.
--
-- The complaint (Victor 21/11 and 22/11): "wasm-agent takes long time to reply to me when i start him
-- ... it should start instantaneously". change/chat-stall proved the mechanism: a second process
-- holding the ledger's WRITE lock moves the turn's first model call by exactly the hold, because the
-- first write a turn makes after run/start is its user message. This test is the guard against it, and
-- it crosses processes on purpose - the bug and its fix both live between two OS processes, so an
-- in-process test could see neither.
--
-- What it asserts:
--   1. quiet ledger: the fixture's model call starts in under 1 s (the shape, and a floor for 2);
--   2. a second process holds the write lock for 10 s: the model call STILL starts in under 1 s;
--   3. the turn survives the hold: it does not die with database_busy at the retry ceiling;
--   4. the reader is told: a status line names the ledger while it is held;
--   5. the transcript is whole and in order once the ledger is free - the deferred row lands.
--
-- THE LOCK IS VERIFIED, NOT ASSUMED (rule 1). Before the turn is released into the held window, this
-- process tries to take the write lock itself with a 50 ms patience: if it GETS it, the fixture failed
-- to hold the ledger and the two measurements below would be meaningless, so the test refuses with
-- that reason instead of reporting a green row it cannot stand behind.
--
-- Every process gets its own scratch home (rule 2) and this one refuses to run against the operator's
-- own store. No fleet node, no provider, no network.
local json = dofile("lua/vendor/json.lua")

local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label) else print("FAIL " .. label); failures = failures + 1 end
end

local home = host.getenv("WASM_AGENT_HOME") or ""
do
  local operator = (host.getenv("HOME") or "") .. "/.wasm-agent"
  local norm = function(value) return (tostring(value or ""):gsub("\\", "/"):gsub("/+$", "")):lower() end
  if home == "" then
    print("SKIP start-instant: no WASM_AGENT_HOME (a scratch home is required)")
    os.exit(0)
  end
  if norm(home) == norm(operator) then
    print("FAIL start-instant: refusing to run against the node's own home (" .. home .. ")")
    os.exit(1)
  end
end

local function sh(command, cwd)
  local called, raw = pcall(host.exec, command, cwd or "", 300)
  if not called then return { code = 127, stdout = "", stderr = tostring(raw) } end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return { code = 127, stdout = tostring(raw), stderr = "" } end
  return decoded
end
local function first_line(text) return tostring(text or ""):match("([^\r\n]+)") or "" end

-- A TIMING ROW THAT FAILS ON A BUSY MACHINE MEASURES THE MACHINE (change/speed-board, 22/11). This row
-- stopped a fast path once under load (whatsapp-finds-owner, 22/11: one run red, two green alone) on a
-- single sample with an absolute bound. The bound is the promise and it does not move; what changes is
-- that the number is now the MEDIAN OF THREE turns, and that no number is measured at all while the
-- machine is above its ceiling (one load unit per core): the row then refuses by name, which is what a
-- reader can act on, instead of failing for a reason nobody can fix.
-- The machine's own load, from the kernel (Linux) and from uptime (the rest). nil when neither answers, and
-- nil is never "quiet": an unknown load is not a measured one (rule 1).
local function load_average()
  local one = sh('cut -d" " -f1 /proc/loadavg')
  local value = tonumber(first_line(tostring(one.stdout or '')))
  if value then return value end
  local uptime = sh("uptime")
  local text = first_line(tostring(uptime.stdout or ''))
  local after = text:match('load averages?:%s*([%d%.]+)')
  return after and tonumber(after) or nil
end

local function core_count()
  local out = sh('nproc')
  local count = tonumber(first_line(tostring(out.stdout or '')))
  if count and count >= 1 then return count end
  return nil
end

-- Wait (bounded) for the load to come under the ceiling. Returns true, or false and the reason, which the
-- caller turns into a refusal - never into a pass.
local function wait_for_quiet(budget_s)
  local ceiling = core_count()
  local load = load_average()
  if not ceiling or not load then return false, 'the machine did not say its load or its cores' end
  local deadline = os.time() + (budget_s or 60)
  while os.time() < deadline do
    load = load_average()
    if load and load <= ceiling then return true end
    host.sleep('500')
  end
  return false, string.format('the machine stayed at load %s on %d cores (ceiling %d): a timing row cannot tell code from load',
    tostring(load and string.format('%.2f', load) or 'unknown'), ceiling, ceiling)
end

local function median(values)
  local sorted = {}
  for _, value in ipairs(values or {}) do if tonumber(value) then sorted[#sorted + 1] = tonumber(value) end end
  if #sorted == 0 then return nil end
  table.sort(sorted)
  local middle = math.floor(#sorted / 2)
  if #sorted % 2 == 1 then return sorted[middle + 1] end
  return math.floor((sorted[middle] + sorted[middle + 1]) / 2 + 0.5)
end

local function executable(path)
  if not path or path == "" then return nil end
  if sh('test -x "' .. path .. '"').code ~= 0 then return nil end
  return path
end
local function find_binary()
  -- WA_FAST_BIN is what the fast path hands a row that must run the TREE binary
  -- (scripts/lib/fast-row-exec.sh); without it this row could quietly test the installed one.
  for _, name in ipairs({ "WA_BIN", "WA_TEST_BIN", "FAST_BIN", "WA_FAST_BIN" }) do
    local found = executable(host.getenv(name))
    if found then return found end
  end
  local which = sh("command -v wa")
  if which.code == 0 then
    local found = executable(first_line(which.stdout))
    if found then return found end
  end
  local h = host.getenv("HOME") or ""
  for _, candidate in ipairs({ h .. "/.local/bin/wa", h .. "/.local/bin/wa.exe" }) do
    local found = executable(candidate)
    if found then return found end
  end
  return nil
end

local bin = find_binary()
if not bin then
  print("SKIP start-instant: no wa binary (WA_BIN/WA_TEST_BIN/FAST_BIN, PATH, ~/.local/bin)")
  os.exit(0)
end
local root = host.getenv("WASM_AGENT_LUA_ROOT") or "."
local db = host.getenv("WASM_AGENT_DB") or (home .. "/t.db")
local scratch = home .. "/start-instant"
sh('rm -rf "' .. scratch .. '" && mkdir -p "' .. scratch .. '"')

local function env_prefix(extra)
  return string.format('env WASM_AGENT_HOME="%s" WASM_AGENT_LUA_ROOT="%s" %s', home, root, extra or "")
end

-- The fixture prints \`turn: <key>=<value> <key>=<value> ...\`, and three lines whose tail is a whole
-- sentence (status, transcript, preflight). The first word there is \`ok=true\`, NOT a kind followed by a
-- space, so a pattern that expects "kind rest" skips the one line the test is about (measured: fields.ok
-- came back nil while the transcript parsed, and the row failed for the wrong reason).
local function parse(text)
  local answer = { text = text, fields = {}, statuses = {} }
  for line in tostring(text):gmatch("[^\r\n]+") do
    local rest = line:match("^turn: (.*)$")
    if rest then
      if rest:sub(1, 7) == "status " then answer.statuses[#answer.statuses + 1] = rest:sub(8)
      elseif rest:sub(1, 11) == "transcript " then answer.fields.transcript = rest:sub(12)
      elseif rest:sub(1, 10) == "preflight " then answer.fields.preflight = rest:sub(11)
      elseif rest:sub(1, 6) == "error " then answer.fields.refusal = rest:sub(7)
      else
        for key, value in rest:gmatch("(%a[%w_]*)=" .. "([^ ]*)") do answer.fields[key] = value end
      end
    end
  end
  answer.gap_ms = answer.fields.gap_ms and tonumber(answer.fields.gap_ms) or nil
  return answer
end

local function turn_log(tag) return scratch .. "/turn-" .. tag .. ".log" end

-- One turn in its own process, against the same ledger, with no lock in the way.
local function run_turn(tag)
  local log = turn_log(tag)
  sh(string.format('%s WA_SCRIPT=scripts/fixtures/start-instant-turn.lua "%s" --db "%s" >"%s" 2>&1',
    env_prefix(), bin, db, log), root)
  return parse(tostring(sh('cat "' .. log .. '"').stdout or ""))
end

local function start_turn_waiting(tag)
  local log = turn_log(tag)
  sh('rm -f "' .. log .. '"')
  local started = sh(string.format(
    '%s WA_GO_FILE="%s" WA_GO_WAIT_S=120 WA_SCRIPT=scripts/fixtures/start-instant-turn.lua "%s" --db "%s" >"%s" 2>&1 & echo $!',
    env_prefix(), scratch .. "/go-" .. tag, bin, db, log), root)
  local pid = tonumber(first_line(started.stdout))
  local deadline = os.time() + 60
  while os.time() < deadline do
    if tostring(sh('cat "' .. log .. '" 2>/dev/null').stdout or ""):find("turn: ready", 1, true) then return pid, log end
    host.sleep("50")
  end
  return pid, log
end

local function start_holder(hold_ms)
  local log = scratch .. "/holder.log"
  local started = sh(string.format(
    '%s WA_HOLD_MS=%d WA_SCRIPT=scripts/fixtures/sqlite-busy-holder.lua "%s" --db "%s" >"%s" 2>&1 & echo $!',
    env_prefix(), hold_ms, bin, db, log), root)
  local pid = tonumber(first_line(started.stdout))
  local deadline = os.time() + 60
  while os.time() < deadline do
    local text = tostring(sh('cat "' .. log .. '" 2>/dev/null').stdout or "")
    if text:find("holder: locked", 1, true) then return pid end
    if text:find("holder: failed", 1, true) then return nil end
    host.sleep("50")
  end
  return nil
end

-- Is the write lock really held by somebody else right now? A BEGIN IMMEDIATE with 50 ms of patience
-- against the same database: refused means held. Returns true, "held" / false, "free:<why>" / nil.
local function lock_held()
  local real = host.sql_exec
  local ok = pcall(function()
    host.sql_exec("PRAGMA busy_timeout = 50", "{}")
  end)
  if not ok then return nil, "no_pragma" end
  local taken, refused = pcall(function()
    local answer = json.decode(host.sql_exec("BEGIN IMMEDIATE", "{}"))
    if type(answer) == "table" and answer.error then error(answer.error, 0) end
    return answer
  end)
  pcall(function() host.sql_exec("PRAGMA busy_timeout = 5000", "{}") end)
  if not taken then
    local text = tostring(refused)
    if text:lower():find("lock", 1, true) or text:lower():find("busy", 1, true) then return true, "held" end
    return nil, "probe_failed:" .. text:sub(1, 80)
  end
  -- It was free: give it straight back, so the probe cannot itself be the holder.
  pcall(function() host.sql_exec("ROLLBACK", "{}") end)
  _ = real
  return false, "free"
end

local memory = dofile("lua/core/memory.lua")
memory.setup()

-- ---- 0. a machine busy enough to explain any number is not measurable ---------------------------
-- The row's promise (under 1 s, with a lock held) is only meaningful about the code, so this is measured
-- on a machine that can tell them apart. A machine that stays above its ceiling for the whole budget
-- refuses by name (SKIP, and the reason says what it was doing), exactly like a row with no binary.
local quiet_enough, busy_why = wait_for_quiet(60)
if not quiet_enough then
  print("SKIP start-instant: " .. tostring(busy_why))
  os.exit(0)
end

-- ---- 1. the quiet shape, as the MEDIAN OF THREE TURNS -------------------------------------------
-- One sample is what flaked: two of three quiet runs are green and the third pays for whatever else the
-- machine was doing. The median of three is the number that describes the code, and the assertion below
-- is unchanged - under 1 s, on the median, with every sample printed so a reader can see the spread.
local quiet_gaps = {}
local quiet_ok = true
for index = 1, 3 do
  local quiet = run_turn("quiet" .. index)
  if quiet.fields.ok ~= "true" then quiet_ok = false end
  if quiet.fields.error then
    print("     quiet turn " .. index .. ": " .. tostring(quiet.fields.error))
  end
  if quiet.gap_ms then quiet_gaps[#quiet_gaps + 1] = quiet.gap_ms end
end
local quiet_median = median(quiet_gaps)
check(quiet_ok, "a turn completes on a quiet ledger (" .. #quiet_gaps .. " of 3 turns produced a gap)")
check(quiet_median ~= nil and quiet_median < 1000,
  "quiet ledger: the model call starts in under 1 s (median " .. tostring(quiet_median) .. " ms of "
    .. table.concat(quiet_gaps, ", ") .. ")")

-- ---- 2. a second process holds the write lock for 10 s, the turn must not pay for it -------------
local turn_pid, log = start_turn_waiting("held")
local holder_pid = start_holder(10000)
check(holder_pid ~= nil, "the second process took the ledger write lock")
local held, why = lock_held()
if holder_pid and held == nil then
  print("FAIL start-instant: the lock probe could not answer (" .. tostring(why) .. ") - refusing to score")
  failures = failures + 1
elseif holder_pid and held == false then
  print("FAIL start-instant: the holder did not hold the ledger write lock - the measurement would be a guess")
  failures = failures + 1
elseif holder_pid and held then
  print("ok   the held window is real: a BEGIN IMMEDIATE from this process was refused (load "
    .. tostring(load_average()) .. ")")
  host.sleep("100")
  local go = scratch .. "/go-held"
  sh('printf go > "' .. go .. '"')
  if turn_pid then
    local deadline = os.time() + 120
    while os.time() < deadline do
      local alive = sh('kill -0 ' .. tostring(turn_pid) .. ' 2>/dev/null')
      if alive.code ~= 0 then break end
      host.sleep("200")
    end
    sh('kill ' .. tostring(turn_pid) .. ' 2>/dev/null')
  end
  local held_turn = parse(tostring(sh('cat "' .. log .. '"').stdout or ""))
  print("     held turn: " .. first_line(held_turn.text))
  check(held_turn.gap_ms ~= nil and held_turn.gap_ms < 1000,
    "write lock held 10 s: the model call still starts in under 1 s (" .. tostring(held_turn.fields.gap_ms) .. ")")
  check(held_turn.fields.ok == "true", "the turn survives the hold instead of dying of it (" .. tostring(held_turn.fields.error) .. ")")
  local named = false
  for _, line in ipairs(held_turn.statuses) do
    if line:lower():find("ledger", 1, true) then named = true end
  end
  check(named, "the reader is told what it waits for: a status line names the ledger")
  check(held_turn.fields.transcript ~= nil and tostring(held_turn.fields.transcript):find("user=hi", 1, true) ~= nil,
    "the turn's own transcript is whole (" .. tostring(held_turn.fields.transcript) .. ")")
end
if holder_pid then
  local deadline = os.time() + 60
  while os.time() < deadline do
    if sh('kill -0 ' .. tostring(holder_pid) .. ' 2>/dev/null').code ~= 0 then break end
    host.sleep("200")
  end
  pcall(function() sh('kill ' .. tostring(holder_pid) .. ' 2>/dev/null') end)
end

-- ---- 5. once the ledger is free, a later turn runs and every transcript is in order --------------
local settled = run_turn("settle")
check(settled.fields.ok == "true", "a later turn on the same ledger still runs (" .. tostring(settled.fields.error) .. ")")
local decoded = json.decode(host.sql_query([[SELECT session_id, role FROM messages ORDER BY session_id, seq]], "{}"))
check(type(decoded) == "table" and not decoded.error, "the transcript is readable after the hold")
if type(decoded) == "table" and not decoded.error then
  local sessions, ordered = {}, 0
  for _, row in ipairs(decoded) do
    sessions[row.session_id] = sessions[row.session_id] or {}
    table.insert(sessions[row.session_id], row.role)
  end
  local count = 0
  for _, roles in pairs(sessions) do
    if #roles > 0 then
      count = count + 1
      if roles[1] == "user" then ordered = ordered + 1 end
      for index = 2, #roles do
        if roles[index - 1] == "assistant" and roles[index] == "user" then ordered = ordered + 1 end
      end
    end
  end
  check(count >= 3, "every turn of this fixture left a transcript (" .. count .. " sessions)")
  check(ordered >= count, "every transcript starts with the user's message, in order (" .. ordered .. "/" .. count .. ")")
end

if failures > 0 then
  print(string.format("start-instant: %d FAIL", failures))
  os.exit(1)
end
print("start-instant ok")
