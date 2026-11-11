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

return M
