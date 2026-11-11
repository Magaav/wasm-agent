-- Contention, for real: several OS processes on one ledger, and a lock held past the deadline.
--
-- Measured 2026-11-12. On `work`, an interactive run ended at 18:14:58 on
-- `lua/core/memory.lua:1056: database is locked` while `wa serve` handled relayed calls; a relay proof
-- against `wasm_the_first` failed 2 of 10 parallel `status` calls while one long call ran (0 of 10 with
-- no long call), and serve.log carried `[placement] lua/core/completions.lua:28: database is locked`.
-- Since the relay fix, up to three admitted calls run at once, each in its own interpreter with its own
-- connection to the one WAL database, so contention is the ordinary case and no call may fail of it.
--
-- What this proves, in order:
--
--   1. the policy itself, with no processes: only a lock is retried, the budget is bounded, a lock that
--      never clears ends as `database_busy: ... (retryable)`, and a nested retry inherits the outer
--      deadline instead of multiplying it;
--   2. an append LANDS while another process holds the write lock (`test-sqlite-busy-holder.lua`);
--   3. a lock held past the deadline ends the call with that name - not with SQLite's own sentence and
--      not with a dead process (`test-sqlite-busy-subject.lua`);
--   4. writers and readers in five other processes - one `serve` lane, three relay lanes and two CLI
--      readers - all finish with zero `database is locked` failures, and every row is in the ledger.
--
-- Runs against a binary plus this tree's `lua/` (`WASM_AGENT_LUA_ROOT`), which is how the fast path
-- runs everything: the fixture is honest about the host it is given, and it reports the part it could
-- not run as SKIPPED rather than as a pass.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local sqlite_busy = dofile("lua/core/sqlite_busy.lua")

local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label) else print("FAIL " .. label); failures = failures + 1 end
end

local function sh(command, cwd)
  local called, raw = pcall(host.exec, command, cwd or "", 180)
  if not called then return { code = 127, stdout = "", stderr = tostring(raw) } end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return { code = 127, stdout = tostring(raw), stderr = "" } end
  return decoded
end

local function first_line(text)
  return tostring(text or ""):match("([^\r\n]+)") or ""
end

-- ---- 1. the policy, with no clock and no processes ------------------------------------------------
do
  local real_getenv, real_sleep, real_clock = host.getenv, host.sleep, host.monotonic_ms
  local clock = 0
  host.monotonic_ms = function() return clock end
  host.sleep = function(ms) clock = clock + (tonumber(ms) or 0) end
  host.getenv = function(name)
    if name == "WASM_AGENT_SQLITE_RETRY_ATTEMPTS" then return "3" end
    if name == "WASM_AGENT_SQLITE_RETRY_MS" then return "1000" end
    return nil
  end

  local attempts = 0
  local ok, problem = pcall(sqlite_busy.retry, "BEGIN IMMEDIATE", function()
    attempts = attempts + 1
    error("database is locked", 0)
  end)
  check(not ok, "a lock that never clears fails instead of looping")
  check(attempts == 3, "it made exactly the configured attempts (" .. attempts .. ")")
  check(tostring(problem):sub(1, #"database_busy:") == "database_busy:",
    "the failure is named: " .. tostring(problem))
  check(tostring(problem):find("(retryable)", 1, true) ~= nil, "and says it is retryable")
  check(tostring(problem):find("database is locked", 1, true) ~= nil, "and keeps the last refusal as detail")

  local once = 0
  local raised, message = pcall(sqlite_busy.retry, "INSERT", function()
    once = once + 1
    error("no such table: nope", 0)
  end)
  check(not raised and once == 1, "an ordinary error is raised once and never retried")
  check(tostring(message):find("no such table", 1, true) ~= nil, "keeping its own message")

  local rides = 0
  local value, extra = sqlite_busy.retry("INSERT", function()
    rides = rides + 1
    if rides < 3 then error("database is locked", 0) end
    return 42, "second"
  end)
  check(value == 42 and rides == 3, "a lock that clears inside the budget returns the value")
  check(extra == "second", "with every return value")

  check(sqlite_busy.is_busy("lua/core/memory.lua:1056: database is locked"), "the old sentence is recognised")
  check(sqlite_busy.is_busy("database_busy: BEGIN IMMEDIATE ..."), "and so is the new name")
  check(not sqlite_busy.is_busy("no such table"), "an ordinary error is not a lock")

  local nested_before = clock
  local nested_ok = pcall(sqlite_busy.retry, "outer", function()
    sqlite_busy.retry("inner", function() error("database is locked", 0) end)
  end)
  check(not nested_ok, "a nested lock fails the whole unit")
  check(clock - nested_before < 5000,
    "the nested budgets did not multiply into minutes (" .. (clock - nested_before) .. "ms)")

  host.getenv, host.sleep, host.monotonic_ms = real_getenv, real_sleep, real_clock
end

-- ---- the processes this fixture needs -------------------------------------------------------------
local function executable(path)
  if not path or path == "" then return nil end
  if sh('test -x "' .. path .. '"').code ~= 0 then return nil end
  return path
end

local function find_binary()
  local explicit = host.getenv("WA_BIN") or host.getenv("WA_TEST_BIN") or host.getenv("FAST_BIN")
  local found = executable(explicit)
  if found then return found end
  local which = sh("command -v wa")
  if which.code == 0 then
    found = executable(first_line(which.stdout))
    if found then return found end
  end
  local home = host.getenv("HOME") or ""
  for _, candidate in ipairs({ home .. "/.local/bin/wa.exe", home .. "/.local/bin/wa" }) do
    found = executable(candidate)
    if found then return found end
  end
  local root = host.getenv("WASM_AGENT_LUA_ROOT") or ""
  for _, name in ipairs({ "wa.exe", "wa" }) do
    found = executable(root .. "/rust/target/release/" .. name)
    if found then return found end
  end
  return nil
end

local bin = find_binary()
if not bin then
  print("SKIP sqlite-busy contention: no wa binary (WA_BIN/WA_TEST_BIN/FAST_BIN, PATH, ~/.local/bin, rust/target/release)")
  if failures > 0 then os.exit(1) end
  print("sqlite busy: policy ok, contention SKIPPED")
  os.exit(0)
end
print("ok   binary: " .. bin)

local home = host.getenv("WASM_AGENT_HOME") or ""
local root = host.getenv("WASM_AGENT_LUA_ROOT") or "."
local db = host.getenv("WASM_AGENT_DB") or ""
if db == "" then db = home .. "/t.db" end
local scratch = (home ~= "" and home or "/tmp") .. "/sqlite-busy-fixture"
sh('rm -rf "' .. scratch .. '" && mkdir -p "' .. scratch .. '"')
print("ok   database: " .. db)

memory.setup()
-- The session the writers append to, created once so a reader's `memory.session` is a real read of a
-- real row while the writers commit, not an accidental nil.
pcall(memory.start_session, '', 'chat', {
  id = 'sqlite-busy', user_id = 'sqlite-busy-fixture', node_id = '', title = 'sqlite busy fixture',
})

local function env_prefix(extra)
  return string.format(
    'env WASM_AGENT_HOME="%s" WASM_AGENT_LUA_ROOT="%s" %s',
    home, root, extra or "")
end

local function start_holder(name, hold_ms)
  local log = scratch .. "/" .. name .. ".holder.log"
  local started = sh(string.format(
    '%s WA_HOLD_MS=%d WA_SCRIPT=scripts/fixtures/sqlite-busy-holder.lua "%s" --db "%s" >"%s" 2>&1 & echo $!',
    env_prefix(), hold_ms, bin, db, log), root)
  local pid = tonumber(first_line(started.stdout))
  -- Wait for a real row inside a real transaction, not for a moment in time. A holder that failed says
  -- so in its own log, and the wait stops there instead of burning the budget: a fixture that waits out
  -- a dead helper reports a lock that was never held.
  local deadline = os.time() + 30
  while os.time() < deadline do
    local seen = sh('cat "' .. log .. '" 2>/dev/null')
    local text = tostring(seen.stdout or "")
    if text:find("holder: locked", 1, true) then return pid, log end
    if text:find("holder: failed", 1, true) then return nil, log end
    host.sleep("50")
  end
  return nil, log
end

local function wait_line(log, pattern, seconds)
  local deadline = os.time() + (seconds or 120)
  while os.time() < deadline do
    local seen = sh('grep -c "' .. pattern .. '" "' .. log .. '" 2>/dev/null')
    local count = tonumber(first_line(seen.stdout)) or 0
    if count > 0 then return true end
    host.sleep("100")
  end
  return false
end

local function log_text(log)
  local result = sh('cat "' .. log .. '" 2>/dev/null')
  return tostring(result.stdout or "")
end

-- ---- 2. an append lands while another process holds the lock ---------------------------------------
do
  local pid, log = start_holder("short", 1200)
  check(pid ~= nil and wait_line(log, "holder: locked", 30), "the holder took the write lock")
  local started = sqlite_busy.clock()
  local ok, problem = pcall(memory.append_turn, "sqlite-busy-hold", {
    role = "user", content = "landed-through-a-held-lock",
  })
  local waited = sqlite_busy.clock() - started
  check(ok, "an append lands while another process holds the write lock: " .. tostring(problem))
  check(waited >= 400, "it waited for the lock rather than racing it (" .. math.floor(waited) .. "ms)")
  wait_line(log, "holder: released", 30)
end

-- ---- 3. a lock held past the deadline ends the call with the name ----------------------------------
do
  local pid, log = start_holder("long", 8000)
  check(pid ~= nil and wait_line(log, "holder: locked", 30), "the holder took the lock for the deadline case")
  local subject = scratch .. "/subject.log"
  sh(string.format(
    '%s WASM_AGENT_SQLITE_BUSY_MS=200 WASM_AGENT_SQLITE_RETRY_MS=1500 WASM_AGENT_SQLITE_RETRY_ATTEMPTS=2 ' ..
    'WA_SCRIPT=scripts/fixtures/sqlite-busy-subject.lua "%s" --db "%s" >"%s" 2>&1',
    env_prefix(), bin, db, subject), root)
  local output = log_text(subject)
  local named = output:find("database_busy", 1, true) ~= nil
  local retryable = output:find("(retryable)", 1, true) ~= nil
  local reported = output:find("subject: error", 1, true) ~= nil
  check(named, "the subject ends with the named error, not with SQLite's sentence")
  check(retryable, "it is marked retryable")
  check(reported, "and the subject reported it instead of dying")
  -- The subject's line is printed only when it is the evidence: its attempt counts are a fact about
  -- this machine's load, and the gate's native/component parity compares outputs byte for byte.
  if not (named and retryable and reported) then
    print("--- subject, write lock held 8000ms, retry budget 1500ms ---")
    print(output)
  end
  wait_line(log, "holder: released", 60)
end

-- ---- 4. five processes at once: serve, three lanes, two CLI readers --------------------------------
do
  local writers = {
    { tag = "serve", n = 8 },
    { tag = "lane1", n = 8 },
    { tag = "lane2", n = 8 },
    { tag = "lane3", n = 8 },
  }
  local readers = { { tag = "cli1", n = 12 }, { tag = "cli2", n = 12 } }
  local running = {}
  local function start(kind, spec)
    local log = scratch .. "/" .. kind .. "-" .. spec.tag .. ".log"
    local started = sh(string.format(
      '%s BUSY_KIND=%s BUSY_TAG=%s BUSY_N=%d WA_SCRIPT=scripts/fixtures/sqlite-busy-worker.lua "%s" --db "%s" >"%s" 2>&1 & echo $!',
      env_prefix(), kind, spec.tag, spec.n, bin, db, log), root)
    running[#running + 1] = { kind = kind, tag = spec.tag, log = log, pid = tonumber(first_line(started.stdout)) }
  end
  for _, spec in ipairs(writers) do start("writer", spec) end
  for _, spec in ipairs(readers) do start("reader", spec) end
  check(#running == 6, "six processes started (one serve, three lanes, two CLI readers)")

  local expected = 0
  for _, spec in ipairs(writers) do expected = expected + spec.n * 2 end

  for _, process in ipairs(running) do
    wait_line(process.log, "worker: ", 120)
    local text = log_text(process.log)
    local finished = text:find("worker: ok ", 1, true) ~= nil
    check(finished, process.kind .. " " .. process.tag .. " finished ok")
    check(text:find("database is locked", 1, true) == nil,
      process.kind .. " " .. process.tag .. " never saw `database is locked`")
    if not finished then print(text) end
  end

  local rows = json.decode(host.sql_query(
    "SELECT COUNT(*) AS n FROM messages WHERE session_id='sqlite-busy'", "[]"))
  check(rows and rows[1] and tonumber(rows[1].n) == expected,
    "every writer's rows are in the ledger (" .. tostring(rows and rows[1] and rows[1].n) .. "/" .. expected .. ")")
  local seqs = json.decode(host.sql_query(
    "SELECT COUNT(DISTINCT seq) AS n FROM messages WHERE session_id='sqlite-busy'", "[]"))
  check(seqs and seqs[1] and tonumber(seqs[1].n) == expected, "and no two rows share a seq")
end

sh('rm -rf "' .. scratch .. '"')
if failures > 0 then
  print(failures .. " check(s) failed")
  os.exit(1)
end
print("sqlite busy ok")
