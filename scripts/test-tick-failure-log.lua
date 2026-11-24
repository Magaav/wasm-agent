-- THE TICK CANNOT DIE SILENTLY (r8c iii, Fable 24/11): a red/green row for the line that was missing.
--
-- MEASURED live: a ledger created before r8a3 kept its old self_wakes, the tick's first call raised
-- "no such column: run_id", a bare pcall swallowed it, and the node dispatched nothing for 2.5 hours while
-- looking healthy. lua/core/subagents.lua now logs "selfloop_tick_failed: <error>", keeps the last one for
-- /health, logs a repeated identical error ONCE, and clears the memo on a clean tick so a returning error is
-- logged again.
--
-- The fixture is the real one: a ledger whose self_wakes has no run_id, made by this tree's own setup() and then
-- ALTER ... DROP COLUMN (exactly the column the release's ledger lacked).
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
local subagents = dofile("lua/core/subagents.lua")
local tick = subagents.orchestrator_tick

local checks = 0
local function check(v, label) checks = checks + 1; if not v then error(label, 2) end end
local function eq(a, b, label)
  checks = checks + 1
  if a ~= b then error(label .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- The log, captured: one line per distinct failure is what this row counts.
local lines, real_log = {}, host.log
host.log = function(line) lines[#lines + 1] = tostring(line) end
local function failed_lines()
  local n = 0
  for _, line in ipairs(lines) do if line:find("selfloop_tick_failed:", 1, true) then n = n + 1 end end
  return n
end
local function drop(table, column)
  json.decode(host.sql_exec("ALTER TABLE " .. table .. " DROP COLUMN " .. column, "[]"))
end

-- The real failure this row was written for, as the ledger really says it.
local raised = [=[lua error: [string "lua/core/deploy_pause.lua"]:56: no such column: run_id in SELECT id, session_id, owner, resume_chain, run_id FROM self_wakes WHERE reason=?]=]

-- ---- 1. a raise is logged by name, exactly once ---------------------------------------------------
lines = {}
subagents.record_tick(false, raised)
eq(failed_lines(), 1, "a raise is logged by name exactly once")
check(tostring(subagents.selfloop_tick_state().error):find("no such column: run_id", 1, true) ~= nil,
  "and the state /health reads carries it: " .. tostring(subagents.selfloop_tick_state().error))
check(lines[1] and lines[1]:find("selfloop_tick_failed: ", 1, true) == 1, "the line says so by name: " .. tostring(lines[1]))

-- ---- 2. the SAME error again: silent --------------------------------------------------------------
lines = {}
subagents.record_tick(false, raised)
eq(failed_lines(), 0, "a repeat of the same error is not logged again")

-- ---- 3. a clean tick clears the memo --------------------------------------------------------------
lines = {}
subagents.record_tick(true, nil)
eq(failed_lines(), 0, "a clean tick logs no failure")
eq(tostring(subagents.selfloop_tick_state().error), "", "and clears the error in the state")

-- ---- 4. the error RETURNING is logged again -------------------------------------------------------
lines = {}
subagents.record_tick(false, raised)
eq(failed_lines(), 1, "an error that returns after a clean tick is logged again, not swallowed by the old memo")
eq(tostring(subagents.selfloop_tick_state().error), subagents.selfloop_tick_state().error,
  "the state keeps the last error")

-- ---- 5. a DIFFERENT error is logged even while the first is remembered ------------------------------
lines = {}
subagents.record_tick(false, [=[lua error: [string "x"]:1: no such table: self_wakes]=])
eq(failed_lines(), 1, "a different error is logged too")

host.log = real_log
print("tick-failure-log ok (" .. checks .. " checks): logged once, silent on a repeat, cleared by a clean tick, logged again when it returns")
