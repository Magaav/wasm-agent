-- THE QUICK ROW'S HARNESS: what `wa land <branch>` - the landing every round ends with - is proved by,
-- in PARTS BY SUBJECT.
--
-- SPLIT, 23/11 (mission land-quick-row-not-hung). As one row it was 178 checks and ~3,200 `host.exec` calls
-- (every landing is real git), and its cost is what the per-row watchdog measures:
--
--   * ~35 s alone on a quiet machine, and 112 s alone at load 12.8 - still under the 120 s deadline, and it
--     passed;
--   * 145 s each when EIGHT copies of it run at once (measured, two rounds of eight), which is the shape of a
--     fast-path run: scripts/fast.sh runs eight rows at a time and reports "no verdict within 120s ... killed
--     the group" - a row that had NOT deadlocked and would have finished;
--   * and it is not the tree: the four main-health runs that reported this row HUNG are four different
--     commits (22808bc81598, 899fdd47caee, 70205155fe34, da912828082d - the last two before and the first two
--     well before the remote-undo-works landing), and main-health's own log for e9a42d20 does not contain
--     this row at all (its reds there were test-graph-crash-recovery, undo-pty and undo-remote-pty).
--
-- So this is the same remedy the land row itself got on 22/11 (`scripts/lib/land-row.lua`, "SPLIT, 22/11"):
-- the cases were already independent fixtures, so the row is five rows by subject now, each cheap enough to
-- stay far inside the watchdog under load. NO CHECK WAS DROPPED AND NO WATCHDOG WAS RAISED: every part prints
-- its own count, and the five counts add up to the one row's 178.
--
--   scripts/test-land-quick.lua             the landing itself, and the line Victor reads (+ the brief)
--   scripts/test-land-quick-tests.lua       the branch's own tests decide (+ a docs-only branch)
--   scripts/test-land-quick-components.lua  the components a row names
--   scripts/test-land-quick-main.lua        a red main, and a health row is not a verdict
--   scripts/test-land-quick-install.lua     the install record, --gate, another process, the resume
--
-- The harness (the fixture repository and its two remotes, the scripted network, the scratch-home guard) is
-- scripts/lib/land-row.lua; what is scripted HERE is only what cannot be real in a test: this node's sentinel
-- (the route writes the record the way a deploy does), the health run's own process, and the fast path.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_FAST_BIN=<wa binary> WA_SCRIPT=scripts/test-land-quick.lua wa --db <scratch>
--
-- Each part calls `arm()` once, before its first case: it is the scratch-home refusal (item 3 of the
-- node-ops round) and the ledger's schema in one place, in that order - a row that writes a ledger must be
-- provably not the operator's node BEFORE it writes anything.
local R = dofile("scripts/lib/land-row.lua")
local land, repo, must, write_file, read_file = R.land, R.repo, R.must, R.write_file, R.read_file
local setup_fixture, journal_of, step_of, marker, json, state = R.setup_fixture, R.journal_of, R.step_of,
  R.marker, R.json, R.state
local ledger = dofile("lua/core/event_ledger.lua")

local Q = {}
Q.R = R
Q.land, Q.repo, Q.ok, Q.eq, Q.contains = land, repo, R.ok, R.eq, R.contains
Q.must, Q.write_file, Q.read_file = must, write_file, read_file
Q.setup_fixture, Q.journal_of, Q.step_of, Q.marker = setup_fixture, journal_of, step_of, marker
Q.json, Q.state, Q.ledger = json, state, ledger

-- ---------------------------------------------------------------- what is scripted, and only that
local install_dir = R.fixture .. "/node-install"
Q.install_dir = install_dir
land.install_dir_override = install_dir
land.start_operation = function(spec)
  state.health_operation = spec
  return "op-health-1"
end

local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
Q.trim = trim
-- ONE table each, exported as the same table: a case that sets `behaviour.main_health_code = 1` is setting
-- the field the route below reads, because it is the same record and not a copy of it.
local behaviour = { install_commit = nil, sentinel_fails = false, lua_core = true, lua_differs = false,
  main_health_code = 0, gate_code = 0 }
local observed = { deploy_requests = 0, health_runs = 0, gate_runs = 0 }
Q.behaviour, Q.observed = behaviour, observed

local harness_exec = land.exec
land.exec = function(command, cwd, timeout, opts)
  if command:find("wa%-sentinel request deploy", 1) then
    observed.deploy_requests = observed.deploy_requests + 1
    if behaviour.sentinel_fails then
      return { code = 1, stdout = "", stderr = "wa-sentinel: the request box is unwritable" }
    end
    -- WHAT THE SENTINEL DOES, and the only thing this route owns: it installs the checkout's tip and writes the
    -- install record. Everything the step then proves (the record names the tip, the Lua matches) is read back
    -- by the code under test.
    local head = must("git -C " .. repo .. " rev-parse HEAD")
    local commit = behaviour.install_commit or head
    must("mkdir -p " .. install_dir, "create the install directory")
    write_file(install_dir .. "/installed.txt", "commit=" .. commit .. "\nvia=tree\n")
    must("rm -rf " .. install_dir .. "/lua-core", "clear the installed lua tree")
    local has_lua = harness_exec("test -d " .. repo .. "/lua/core", repo, 60)
    if behaviour.lua_core and (has_lua.code or 1) == 0 then
      must("mkdir -p " .. install_dir .. "/lua-core/lua", "create the installed lua tree")
      must("cp -a " .. repo .. "/lua/core " .. install_dir .. "/lua-core/lua/core", "copy the landed lua core")
      if behaviour.lua_differs then write_file(install_dir .. "/lua-core/lua/core/stray.lua", "-- not this landing") end
    end
    return { code = 0, stdout = "queued\n", stderr = "" }
  end
  if command:find("scripts/main%-health%.sh", 1) then
    observed.health_runs = observed.health_runs + 1
    return { code = behaviour.main_health_code, stdout = "main-health: measuring ...\n",
      stderr = behaviour.main_health_code == 0 and "" or "main-health: FAIL test-land-plan.lua\n" }
  end
  if trim(command) == "bash scripts/fast.sh" then
    observed.gate_runs = observed.gate_runs + 1
    return { code = behaviour.gate_code, stdout = behaviour.gate_code == 0 and "fast: 12 rows ok\n" or "FAIL fast: fake red\n",
      stderr = "" }
  end
  return harness_exec(command, cwd, timeout, opts)
end

-- A branch of the fixture that changes the paths the rules look at.
local function branch_with(name, files)
  must("git -C " .. repo .. " checkout -q -B " .. name .. " main", "branch " .. name)
  for path, text in pairs(files) do write_file(repo .. "/" .. path, text) end
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m '" .. name .. "'", "commit " .. name)
  must("git -C " .. repo .. " push -q oc-in " .. name .. ":refs/heads/" .. name, "push " .. name)
  must("git -C " .. repo .. " checkout -q main", "back to main")
end
Q.branch_with = branch_with

-- A row's first line, for an assertion message (the log itself is too long to print whole).
local function first_line_ish(text) return (tostring(text):match("[^\n]*") or "") end
Q.first_line_ish = first_line_ish

-- MAIN GROWS AFTER a branch was cut: a commit on main, pushed to both remotes, so the round's base is newer
-- than the branch's fork point - the shape the first real landing measured (22/11).
local function main_grows(files)
  must("git -C " .. repo .. " checkout -q main", "back to main")
  for path, text in pairs(files) do write_file(repo .. "/" .. path, text) end
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m 'main moves on'", "commit on main")
  must("git -C " .. repo .. " push -q origin main && git -C " .. repo .. " push -q oc-in main", "publish main")
end
Q.main_grows = main_grows

-- The fixture's own main-health: the REAL script (the step and `wa land health-run` both look for it in the
-- tree), committed to main so every branch carries it. Its command is routed above, so it never runs here.
local function fixture(name, extra)
  setup_fixture()
  must("cp -f " .. R.tree_root .. "/scripts/main-health.sh " .. repo .. "/scripts/main-health.sh", "copy main-health")
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m 'main-health'", "commit main-health")
  must("git -C " .. repo .. " push -q origin main && git -C " .. repo .. " push -q oc-in main", "publish main-health to main")
  branch_with("change/lua", { ["lua/core/greeting.lua"] = "return { hello = 'landing' }\n" })
  branch_with("change/tests", { ["scripts/test-own.lua"] = "print('own ok')\n" })
  branch_with("change/tests-red", { ["scripts/test-own-red.lua"] = "print('own red')\nos.exit(1)\n" })
  branch_with("change/rust", { ["rust/thing.rs"] = "// a change that needs a binary\n",
    ["scripts/test-own-rust.lua"] = "print('never runs here')\n" })
  branch_with("change/docs", { ["docs/notes.txt"] = "a document\n" })
  observed.deploy_requests, observed.health_runs, observed.gate_runs = 0, 0, 0
  behaviour.install_commit, behaviour.sentinel_fails = nil, false
  behaviour.lua_core, behaviour.lua_differs = true, false
  behaviour.main_health_code, behaviour.gate_code = 0, 0
  state.health_operation = nil
  if extra then extra() end
end
Q.fixture = fixture

-- The prints of a run, captured so the LAST LINE (the one Victor reads) can be asserted.
local captured = {}
local real_print = print
function Q.running(fn)
  captured = {}
  print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
    captured[#captured + 1] = table.concat(parts, " ")
  end
  local called, answer = pcall(fn)
  print = real_print
  if not called then error(answer, 0) end
  return answer
end
function Q.said(needle)
  for _, line in ipairs(captured) do
    if line:find(needle, 1, true) ~= nil then return true, line end
  end
  return false, nil
end
function Q.captured_lines() return captured end

function Q.rows_of(mission)
  local rows = ledger.read({ kinds = { "land" }, limit = 500 })
  local mine = {}
  for _, row in ipairs(rows) do
    if tostring(row.mission) == mission then mine[#mine + 1] = row end
  end
  return mine
end

-- ARM A PART: the scratch-home refusal first (a row must never act on the operator's node), then the ledger's
-- schema. Every part calls this once before its first case.
function Q.arm(label)
  local why_home = dofile("scripts/lib/scratch-home.lua").guard(tostring(label or "test-land-quick.lua"))
  if why_home then print("REFUSED " .. why_home); os.exit(2) end
  ledger.setup()
  return Q
end

return Q
