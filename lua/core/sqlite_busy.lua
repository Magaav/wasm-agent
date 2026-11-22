-- Bounded retry for the one SQLite error that is not a failure: someone else is writing.
--
-- Measured 2026-11-12, on `work`: an interactive run ended at 18:14:58 on
-- `lua/core/memory.lua:1056: database is locked` while `wa serve` handled relayed calls, and a relay
-- proof against `wasm_the_first` failed 2 of 10 parallel `status` calls while one long call ran (0 of
-- 10 with no long call). Since the relay fix, up to three admitted calls run at once, each in its own
-- interpreter with its own connection to the one WAL database, so a lock is ordinary weather - and a
-- run that died of weather is the defect.
--
-- The rules this module exists to make true:
--
--   * **Only `SQLITE_BUSY`/`SQLITE_LOCKED` is retried.** Any other error is re-raised exactly as it
--     arrived, on the first attempt. A missing table, a constraint, a bug - never retried.
--   * **The caller owns the choice to re-run.** `M.retry` runs its function again only when the
--     caller passed a unit that is safe to repeat. A statement or a `BEGIN IMMEDIATE` is (a refused
--     statement applied nothing; a refused BEGIN took no lock). A closure that already committed is
--     not, which is why `memory.in_transaction` retries its BEGIN and its COMMIT and never its body.
--   * **Patience is bounded and shared with the host.** The Rust side (`rust/wa-sqlite`) retries the
--     statement inside one call; this layer is what makes the *transaction* survive on a host that
--     does not, and it stops at the same deadline (`WASM_AGENT_SQLITE_RETRY_MS`). A retry nested in
--     another retry inherits the outer deadline instead of starting a fresh budget, so the two cannot
--     multiply into a minute of waiting.
--   * **A lock that cannot be had ends with a name.** `database_busy: ... (retryable)`: a string a
--     caller can match and a human can act on, instead of `database is locked` several frames down
--     from the thing that actually failed.
local M = {}

M.BUSY_NAME = "database_busy"
-- Forward declaration (change/start-instant): the retry loop below reports a refusal to the start
-- window defined at the bottom of this file, so the name has to exist before that body is compiled.
local notify
local PAUSE_START_MS, PAUSE_MAX_MS = 20, 400

local function number_env(name, default, low, high)
  local value = tonumber(host.getenv and host.getenv(name) or nil)
  if not value then return default end
  return math.max(low, math.min(high, value))
end

local function attempts_max()
  return math.floor(number_env("WASM_AGENT_SQLITE_RETRY_ATTEMPTS", 5, 1, 50))
end

local function retry_budget_ms()
  return number_env("WASM_AGENT_SQLITE_RETRY_MS", 20000, 0, 600000)
end

-- Monotonic where the host can offer it: a wall clock that steps during NTP correction would make a
-- budget either expire early or never.
function M.clock()
  if host.monotonic_ms then return host.monotonic_ms() end
  return host.now() * 1000
end

-- The text a retry decision is made on. Both spellings are matched because the same condition
-- arrives as SQLite's own sentence (from a host that does not name it) and as ours (from one that
-- does, `rust/wa-sqlite`), and a caller must not care which binary it is running on.
function M.is_busy(reason)
  local text = tostring(reason or ""):lower()
  return text:find("database is locked", 1, true) ~= nil
    or text:find("database table is locked", 1, true) ~= nil
    or text:find("sqlite_busy", 1, true) ~= nil
    or text:find("sqlite_locked", 1, true) ~= nil
    or text:find("database_busy", 1, true) ~= nil
end

-- The one name and shape for "I could not get the lock in time", so a log line, a CLI exit and a
-- test can all match it. A refusal that is already named (a host error this layer wrapped, or a retry
-- inside a retry) keeps its detail but loses its own marker: one `(retryable)` at the end of a line is
-- the contract, and `(retryable)) (retryable)` is not.
function M.failure(action, last, attempts, spent_ms)
  local detail = tostring(last):gsub("%s*%(retryable%)%s*$", "")
  return string.format(
    "%s: %s could not get the lock within %dms (%d attempt(s), last: %s) (retryable)",
    M.BUSY_NAME, tostring(action), math.floor(spent_ms or 0), attempts or 0, detail)
end

-- Spread the retries of callers that started in the same millisecond: without this, ten lanes that
-- collided once wake together and collide again, which is the shape that turned one slow commit into
-- ten failures.
local function pause_ms(pause, attempt)
  local spread = math.max(1, math.floor(pause / 2))
  local jitter = math.floor((M.clock() + attempt * 7) % spread)
  return pause + jitter
end

-- Run `fn` until it stops meeting a lock, within `attempts` attempts and `budget_ms` together.
--
-- Everything `fn` returns is returned; a raised error is re-raised unchanged unless it is a busy
-- error, in which case the wait is retried and the final answer is `M.failure(...)`.
--
-- `opts.attempts` / `opts.budget_ms` override the environment for one call (a caller that already has
-- a deadline of its own, or a test that must fail fast).
function M.retry(action, fn, opts)
  opts = opts or {}
  local limit = math.floor(tonumber(opts.attempts) or attempts_max())
  local budget = tonumber(opts.budget_ms) or retry_budget_ms()
  local started, attempts, pause = M.clock(), 0, PAUSE_START_MS
  -- A retry inside a retry (`append_turn` waits; `in_transaction` inside it waits too) must not get a
  -- fresh budget: that is how a bounded deadline becomes unbounded patience. The inner decision uses
  -- the earliest deadline already in force.
  local deadline = started + budget
  local enclosing = rawget(_G, "__wa_busy_deadline")
  if enclosing and enclosing < deadline then deadline = enclosing end
  local function attempt()
    while true do
      attempts = attempts + 1
      local results = table.pack(pcall(fn))
      if results[1] then return table.unpack(results, 2, results.n) end
      local last = results[2]
      if not M.is_busy(last) then error(last, 0) end
      -- The reader is told from here, not from a caller that guesses: this is the one place where "I am
      -- waiting for another process" is a fact (item 3 of change/start-instant).
      notify(action, last)
      if attempts >= limit or M.clock() >= deadline then
        error(M.failure(action, last, attempts, M.clock() - started), 0)
      end
      if host.sleep then pcall(host.sleep, tostring(pause_ms(pause, attempts))) end
      pause = math.min(PAUSE_MAX_MS, pause * 2)
    end
  end
  rawset(_G, "__wa_busy_deadline", deadline)
  local results = table.pack(pcall(attempt))
  rawset(_G, "__wa_busy_deadline", enclosing)
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end


-- ---------------------------------------------------------------- the start window (22/11)
-- A TURN'S FIRST WRITE MUST NOT WAIT FOR ANOTHER PROCESS (Victor 22/11: "it should start
-- instantaneously"; measured on this node: a land or a serve restart moves a turn's first model call by
-- 6-21 s, and the wait is the turn's own retry patience, not the holder's work).
--
-- Every write in a run's preamble - the session claim, the steering row, the user message, the telemetry
-- event - is bookkeeping the model does not need: the model is about to answer the text this node
-- already holds in memory. So for the preamble only, this module bounds the patience of ANY write to a
-- few hundred milliseconds: the connection's own busy_timeout is shortened (that is what one refused
-- statement would otherwise spend - 5 s a quantum, measured) and the retry deadline is moved to
-- now+patience, which a nested retry inherits instead of starting its own. A write refused inside the
-- window fails at once with the named, retryable answer callers already understand, and a caller that
-- can do its work later does (lua/core/ledger_defer.lua).
--
-- What it is NOT: a shorter patience for the whole process. The window is opened for a preamble and
-- closed at the first model call (or when the run ends), and the previous busy_timeout is put back.
-- THE WINDOW LIVES ON _G, NOT IN THIS FILE'S CHUNK. dofile() re-runs a module, so the table a module
-- builds at load time is a DIFFERENT table for every caller: telemetry.lua and memory.lua each hold their
-- own copy of this file, and a window opened by the agent was invisible to both (measured 22/11: the
-- telemetry write never learned the window was open and spent its own 828 ms twice). One shared table, the
-- same mechanism memory.lua already uses for its transaction depth (__wa_tx_depth).
local function window_state()
  local state = rawget(_G, "__wa_start_window")
  if type(state) ~= "table" then
    state = { open = false, restore = nil, deadline = nil, enclosing = nil, notifier = nil, noticed = false,
      busy = false, patience = nil }
    rawset(_G, "__wa_start_window", state)
  end
  return state
end
local window = window_state()

-- The one callback a run registers so the READER is told what it waits for (item 3 of change/start-instant):
-- a silent screen for 20 s is the second half of the complaint.
function M.on_wait(fn)
  window.notifier = fn
  window.noticed = false
end

function M.noticed() return window.noticed end

local function pragma(statement)
  if type(host.sql_exec) ~= "function" then return nil end
  local ok, raw = pcall(host.sql_exec, statement, "{}")
  if not ok then return nil end
  local decoded
  local okd, value = pcall(dofile("lua/vendor/json.lua").decode, raw)
  if okd then decoded = value end
  return decoded or {}
end

function notify(action, reason)
  -- The ledger refused a write inside the window: from here on, a later writer in the same preamble does
  -- not have to spend the same patience to learn the same thing (see M.busy_now).
  if window.open and not window.busy then
    window.busy = true
    -- AND THE CONNECTION STOPS WAITING ALTOGETHER. A preamble has a dozen small writers (the steering
    -- row, the session claim, the envelope cache, the prompt cache, the transcript): each one that has
    -- to learn "still locked" for itself pays the window again, and ten times 400 ms is the 4.8 s turn
    -- this was measured as. Zero here means the rest of the preamble finds out at once, which is all
    -- any of them needs; end_window() puts the connection patience back.
    pragma("PRAGMA busy_timeout = 0")
  end
  if window.noticed or type(window.notifier) ~= "function" then return end
  window.noticed = true
  pcall(window.notifier, action, tostring(reason))
end

-- A caller that talks to the host's SQL boundary directly (telemetry, the envelope cache) reports the
-- refusal here, so the window learns it once and the reader is told once - whether or not the statement
-- came through M.retry.
function M.observe(reason)
  if not M.is_busy(reason) then return false end
  notify("sql", reason)
  return true
end

-- True while this run's preamble has already been refused the write lock. Callers that can do their
-- work later (telemetry, the transcript, the steering row) ask this instead of paying for the answer
-- again: a preamble is not a queue of identical 2 s waits (measured: three of them made a 9.2 s turn).
function M.busy_now() return window.open and window.busy end


-- patience_ms is the budget for the whole window, not per statement.
function M.begin_window(patience_ms)
  if window.open then return true end
  local patience = math.max(1, math.floor(tonumber(patience_ms) or 400))
  local current = pragma("PRAGMA busy_timeout")
  local previous = tonumber(type(current) == "table" and (current[1] and (current[1].timeout or current[1].busy_timeout) or nil)) or nil
  -- TWO NUMBERS, ONE WAIT. A newer host takes the window itself (`host.sql_patience`, one attempt) and
  -- the statement may then wait up to `patience`; an older host has no such knob and retries every
  -- statement five times of its own accord, so there the connection must not wait at all or the window is
  -- multiplied by five (measured 22/11: 400 ms became 2.2 s per refused write). A Lua-only deploy
  -- therefore still bounds the preamble - it just bounds it a little less tightly.
  local bounded_host = type(host.sql_patience) == "function"
  if not pragma("PRAGMA busy_timeout = " .. (bounded_host and patience or 0)) then return false end
  if bounded_host then pcall(host.sql_patience, tostring(patience)) end
  window.open = true
  window.busy = false
  window.patience = patience
  window.restore = previous
  window.enclosing = rawget(_G, "__wa_busy_deadline")
  window.deadline = M.clock() + patience
  local enclosing = window.enclosing
  if not enclosing or enclosing > window.deadline then rawset(_G, "__wa_busy_deadline", window.deadline) end
  return true
end

function M.end_window()
  if not window.open then return end
  window.open = false
  window.busy = false
  if type(host.sql_patience) == "function" then pcall(host.sql_patience, "0") end
  rawset(_G, "__wa_busy_deadline", window.enclosing)
  window.enclosing, window.deadline = nil, nil
  local restore = window.restore or 5000
  window.restore = nil
  pragma("PRAGMA busy_timeout = " .. restore)
end

function M.in_window() return window.open end

return M
