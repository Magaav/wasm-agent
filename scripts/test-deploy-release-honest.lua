-- A PAUSE WHOSE UPDATE DID NOT HAPPEN SAYS SO (r8c 1, Fable 24/11).
--
-- MEASURED (deploy-hold-never-fails-our-load/paused-evidence.log, 24/11): seven sessions sat 20-37 minutes after a
-- pause whose install never swapped anything - 16:48Z and 17:06Z were a TEST LEAK writing the node's real
-- deploy-pending.json, not an install - and their resume wakes (5ffa1bd2, d1cd45bc, 8117d28f) stayed pending even
-- through the real installs at 17:12-17:24.
--
-- What this row pins, on the real modules, the real marker file and the real tick:
--   * a marker PAST ITS BOUND releases the pause - one resume turn per session - because the installer that wrote
--     it is gone and a crashed (or leaked) marker must not hold a session for ever;
--   * the released turn CARRIES THE MACHINE'S OWN LINE, "[deploy] the update did not happen", so a model is not
--     left to invent what was installed;
--   * and a LIVE marker still holds: nothing is released and no turn is spent (the control, so a release that
--     happens always is not read as this fix).
-- The ledger, the marker file and the tick are the product's own; the scheduler is a counter, because a row must
-- never start a paid turn.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then
  error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")")
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
local pause = dofile("lua/core/deploy_pause.lua")
local data = dofile("lua/core/paths.lua").data()
local MARKER = data .. "/" .. pause.FILE

local checks = 0
local function check(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function decode(raw) if type(raw) == "string" then return json.decode(raw) end return raw end
local function rows(sql, params) return decode(host.sql_query(sql, json.encode(params or {}))) end

local T0 = 1700000000
selfloop.set_test_clock(function() return T0 end)

local sent = { count = 0, ids = {} }
local function counted(row)
  sent.count = sent.count + 1
  sent.ids[#sent.ids + 1] = tostring(row.id)
  return { accepted = true, run_id = sent.count }
end
local function marker(since, bound)
  local ok = pcall(host.write_file, MARKER, json.encode({ to = "deadbeefcafe", state = "deploy_pending",
    since = since, bound_seconds = bound, by = "scripts/test-deploy-release-honest.lua" }))
  check(ok, "the installer's marker is written at " .. MARKER)
end
local function unpause(session, extra)
  local opts = { now = T0, no_record = true, notes = function() end,
    schedule = function(args) return selfloop.schedule(args, { session_id = session, user_id = "master" }) end }
  for key, value in pairs(extra or {}) do opts[key] = value end
  local answer = pause.at_boundary({ session_id = session, user_id = "master" }, "finish the request", opts)
  check(type(answer) == "table" and type(answer.wake) == "table", "the turn paused and armed one resume: " .. json.encode(answer))
  return answer.wake.id
end

-- ---- 1. a LIVE marker holds: no release, no turn -------------------------------------------------
local live_session = memory.start_session("local", "chat", { id = "r8c-live", user_id = "master", title = "live" })
marker(T0 - 60, 900)
local live_wake = unpause(live_session)
local before = rows("SELECT * FROM self_wakes WHERE id=?", { live_wake })[1]
sent = { count = 0, ids = {} }
local held = selfloop.tick({ now = T0 + 5, dispatch = counted })
eq(held.deploy_waiting, 1, "a live marker holds the tick (the gate)")
eq(sent.count, 0, "and spends no turn")
eq(tonumber(rows("SELECT due_at FROM self_wakes WHERE id=?", { live_wake })[1].due_at), tonumber(before.due_at),
  "the armed resume keeps its own time while the install is live")

-- ---- 2. the installer is gone (past its bound): ONE resume turn - and it says only what it CAN say ------
-- This pause was taken with NO pause record at all (the turn paused without one), and at this moment in the row the
-- node has no install record either. So the release knows NEITHER side: it must not claim the update did not happen
-- (Fable 24/11), it says what it can see - that the pause ended, on an install whose record could not be read.
marker(T0 - 3600, 900)   -- since + bound is an hour in the past: an installer that never came back
sent = { count = 0, ids = {} }
local released = selfloop.tick({ now = T0 + 5, dispatch = counted })
eq(sent.count, 1, "exactly ONE resume turn is spent for the paused session")
eq(sent.ids[1], live_wake, "and it is the resume this pause armed, not another row")
eq(released.released, 1, "the tick reports the release (one row)")
local row = rows("SELECT * FROM self_wakes WHERE id=?", { live_wake })[1]
check(type(pause.UNKNOWN) == "string" and pause.UNKNOWN ~= "",
  "the module names the line a release carries when it cannot tell (got " .. tostring(pause.UNKNOWN) .. ")")
check((row.prompt or ""):find(pause.UNKNOWN, 1, true) ~= nil,
  "an unknown pause says the pause ended (" .. pause.UNKNOWN .. "): " .. tostring(row.prompt):sub(1, 200))
check((row.prompt or ""):find(pause.NOT_HAPPENED, 1, true) == nil,
  "and it does NOT claim the update did not happen - nothing recorded what this node ran before")
check((row.prompt or ""):find("an install whose record could not be read", 1, true) ~= nil,
  "naming the side it could not read: " .. tostring(row.prompt):sub(1, 200))
check((row.prompt or ""):find("what was installed", 1, true) ~= nil,
  "and still telling the model to verify the machine before claiming anything")
check((row.prompt or ""):find("finish the request", 1, true) ~= nil,
  "and the request the turn was continuing stays in it, below the line")
eq(row.status, "dispatching", "the row is claimed by the release and handed over once")


-- ---- 3. THE LINE IS DECIDED BY THE INSTALLED RECORD, NOT BY THE BINARY'S COMMIT -------------------
-- Fable's blocker: release_due is also the normal path after a REAL install, and `host.build_identity` is the
-- BINARY's commit, which a scripts-only install does not move (measured 24/11: 9a0c589a before and after ffb5153e;
-- fe108a8c and 42507780 today). Comparing it before and after told every resumed worker "nothing was installed"
-- after most real installs. The fact that DOES move is the installed record - `installed.txt`'s `lua_tree=` and
-- `commit=`, the pair change/version-names-the-tree prints - so the pause records it and the release compares it.
-- Both are read from the node's OWN install directory (`update.install_dir()`: WA_INSTALL_DIR or <home>/.local/bin)
-- and written in the shape scripts/deploy.sh writes. A row cannot run a whole install; the shell row
-- (scripts/test-deploy-release-node.sh) runs the same fact on a real scratch node, end to end.
local record_dir = pause.paused_dir()
local install_dir = dofile("lua/core/update.lua").install_dir()
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
check(scratch_root ~= "" and install_dir:sub(1, #scratch_root) == scratch_root,
  "the install record under test lives in this row's scratch home (" .. tostring(install_dir) .. "), never the machine's")
local function install_record(commit, tree)
  local ok = host.write_file(install_dir .. "/installed.txt",
    "commit=" .. commit .. "\n" .. (tree and ("lua_tree=" .. tree .. "\n") or "") .. "at=2026-11-24T16:00:00Z\n")
  check(ok == true, "the installed record is written at " .. install_dir .. "/installed.txt")
end

-- 3a. THE PAUSE RECORDS THE INSTALLED RECORD - written by the product, not typed by this row. The shape below is a
-- PREBUILT deploy's: `commit=` is the bytes, `lua_tree=` the tree installed beside them, and the two move separately.
install_record("cccc3333dddd4444", "aaaa1111bbbb2222")
local swap_session = memory.start_session("local", "chat", { id = "r8c-swap", user_id = "master", title = "swap" })
marker(T0 - 60, 900)
local swap_wake = unpause(swap_session, { no_record = false })
local recorded = json.decode(host.read_file(record_dir .. "/" .. swap_session .. ".json") or "{}")
eq(tostring(recorded.installed_tree), "aaaa1111bbbb2222", "the pause record names the tree this node runs")
eq(tostring(recorded.installed_commit), "cccc3333dddd4444", "and the bytes separately (a deploy can move only one of them)")

-- 3b. A SCRIPTS-ONLY INSTALL MOVES THE TREE AND NOT THE BYTES: the release says "installed", naming the new tree.
install_record("cccc3333dddd4444", "bbbb5555eeee6666")
marker(T0 - 3600, 900)
sent = { count = 0, ids = {} }
selfloop.tick({ now = T0 + 6, dispatch = counted })
local swap_row = rows("SELECT * FROM self_wakes WHERE id=?", { swap_wake })[1]
check((swap_row.prompt or ""):find(pause.INSTALLED, 1, true) ~= nil,
  "a scripts-only install makes the release say the build is installed: " .. tostring(swap_row.prompt):sub(1, 160))
check((swap_row.prompt or ""):find(pause.NOT_HAPPENED, 1, true) == nil,
  "and it does NOT tell the worker that nothing was installed")
check((swap_row.prompt or ""):find("bbbb5555eeee", 1, true) ~= nil, "naming the tree the install put there")
check((swap_row.prompt or ""):find("aaaa1111bbbb", 1, true) ~= nil, "and the tree the pause was taken on")

-- 3c. THE OTHER ROW FABLE ASKED FOR: a marker REMOVED with no install (the record does not move) says "did not happen".
local gone_session = memory.start_session("local", "chat", { id = "r8c-gone", user_id = "master", title = "gone" })
marker(T0 - 30, 900)
local gone_wake = unpause(gone_session, { no_record = false })
marker(T0 - 3600, 900)   -- the installer is gone and installed.txt still names bbbb5555eeee6666
sent = { count = 0, ids = {} }
selfloop.tick({ now = T0 + 7, dispatch = counted })
local gone_row = rows("SELECT * FROM self_wakes WHERE id=?", { gone_wake })[1]
check((gone_row.prompt or ""):find(pause.NOT_HAPPENED, 1, true) ~= nil,
  "a marker that goes with nothing installed says the update did not happen: " .. tostring(gone_row.prompt):sub(1, 160))
check((gone_row.prompt or ""):find(pause.INSTALLED, 1, true) == nil, "and does not claim an install")
check((gone_row.prompt or ""):find("deadbeefcafe", 1, true) ~= nil,
  "naming the target the marker carried - read from the marker as the installer wrote it, expiry aside")

-- 3d. UNKNOWN IS NOT YES: with no record on one side the rule cannot say "installed", and it does not.
eq(pause.install_moved(nil, { tree = "bbbb5555eeee6666", commit = "" }), nil,
  "no record at the pause is 'cannot tell', not installed")
eq(pause.install_moved({ tree = "aaaa", commit = "" }, { tree = "aaaa", commit = "" }), false,
  "the same record twice is not an install")
eq(pause.install_moved({ tree = "aaaa", commit = "1111" }, { tree = "aaaa", commit = "2222" }), true,
  "a deploy that moves only the bytes is still an install")


-- 3e. A PAUSE RECORD WITHOUT THE INSTALLED FIELDS IS "UNKNOWN", NEVER "did not happen" (Fable 24/11). That is the
-- shape of every record written by the code running before this change - so every session paused by THIS install
-- would be told "nothing was installed" right after it installed, which is the same lie in the other direction.
pcall(host.remove_file, install_dir .. "/installed.txt")   -- the record cannot be read when this pause is taken
local unknown_session = memory.start_session("local", "chat", { id = "r8c-unknown", user_id = "master", title = "unknown" })
marker(T0 - 60, 900)
local unknown_wake = unpause(unknown_session, { no_record = false })
local bare = json.decode(host.read_file(record_dir .. "/" .. unknown_session .. ".json") or "{}")
eq(bare.installed_tree, nil, "this pause record names no installed tree (the shape the code before this change wrote)")
eq(bare.installed_commit, nil, "and no bytes")
install_record("cccc3333dddd4444", "bbbb5555eeee6666")     -- ... and by the release the install's record IS readable
marker(T0 - 3600, 900)
sent = { count = 0, ids = {} }
selfloop.tick({ now = T0 + 8, dispatch = counted })
local unknown_row = rows("SELECT * FROM self_wakes WHERE id=?", { unknown_wake })[1]
check((unknown_row.prompt or ""):find(pause.UNKNOWN, 1, true) ~= nil,
  "a record with no installed fields gives the unknown line: " .. tostring(unknown_row.prompt):sub(1, 200))
check((unknown_row.prompt or ""):find("bbbb5555eeee", 1, true) ~= nil,
  "naming the tree this node runs, twelve characters")
check((unknown_row.prompt or ""):find(pause.NOT_HAPPENED, 1, true) == nil,
  "and it never says the update did not happen")
check((unknown_row.prompt or ""):find(pause.INSTALLED, 1, true) == nil,
  "and never claims it did")

-- 3f. THE OTHER SIDE UNREADABLE BY THE RELEASE: the pause recorded the record and, by the release, there is none.
local lost_session = memory.start_session("local", "chat", { id = "r8c-lost-record", user_id = "master", title = "lost" })
marker(T0 - 60, 900)
local lost_wake = unpause(lost_session, { no_record = false })
local known = json.decode(host.read_file(record_dir .. "/" .. lost_session .. ".json") or "{}")
eq(tostring(known.installed_tree), "bbbb5555eeee6666", "this pause record names the tree the node ran")
pcall(host.remove_file, install_dir .. "/installed.txt")   -- the record cannot be read at the release
marker(T0 - 3600, 900)
sent = { count = 0, ids = {} }
selfloop.tick({ now = T0 + 9, dispatch = counted })
local lost_row = rows("SELECT * FROM self_wakes WHERE id=?", { lost_wake })[1]
check((lost_row.prompt or ""):find(pause.UNKNOWN, 1, true) ~= nil,
  "an unreadable install record gives the unknown line: " .. tostring(lost_row.prompt):sub(1, 200))
check((lost_row.prompt or ""):find("an install whose record could not be read", 1, true) ~= nil,
  "naming that it could not be read rather than naming a tree")
check((lost_row.prompt or ""):find(pause.NOT_HAPPENED, 1, true) == nil, "and it does not say the update did not happen")
install_record("cccc3333dddd4444", "bbbb5555eeee6666")


-- ---- 4. ONE RESUME ROW PER SESSION - AND A HELD SESSION IS NOT TOUCHED -------------------------
-- Fable 24/11, the blocker: the first version of that supersede kept the earliest pending resume in the WHOLE TABLE,
-- so with eight paused sessions seven lost their only resume at the first release - the rows of PARKED sessions
-- included - and it did it inside a pcall, silently. The shape here is the brief's row: THREE paused sessions, each
-- carrying the two-to-four resume rows back-to-back releases left behind, plus ONE parked session that is not
-- waiting for this install at all (and whose rows are already overdue, the 24/11 shape: 13 overdue held rows).
local paused = {}
for i = 1, 3 do
  local session = memory.start_session("local", "chat", { id = "r8c-paused-" .. i, user_id = "master", title = "paused " .. i })
  paused[i] = session
  for j = 1, i + 1 do
    host.sql_exec([[INSERT INTO self_wakes (id, owner, session_id, status, reason, prompt, due_at, created_at, updated_at)
      VALUES (?, 'master', ?, 'pending', ?, ?, ?, ?, ?)]],
      json.encode({ "r8c-p" .. i .. "-" .. j, session, pause.RESUME_REASON, "resume " .. i .. "." .. j,
        T0 + 300 + j, T0 + j, T0 + j }))
  end
end
local parked = memory.start_session("local", "chat", { id = "r8c-parked", user_id = "master", title = "parked" })
local park = selfloop.park(parked, "master", "a stop recipe parked this session", { now = T0 })
check(type(park) == "table" and park.parked == true, "the parked session is held the product's own way: " .. json.encode(park))
for j = 1, 2 do
  host.sql_exec([[INSERT INTO self_wakes (id, owner, session_id, status, reason, prompt, due_at, created_at, updated_at)
    VALUES (?, 'master', ?, 'pending', ?, ?, ?, ?, ?)]],
    json.encode({ "r8c-parked-" .. j, parked, pause.RESUME_REASON, "parked resume " .. j, T0 - 10 + j, T0 + j, T0 + j }))
end
local function live_rows(session)
  return rows([[SELECT id, status, due_at, prompt FROM self_wakes WHERE session_id=? AND reason=?
    AND status IN ('pending','dispatching') ORDER BY id]], { session, pause.RESUME_REASON })
end
for i = 1, 3 do eq(#live_rows(paused[i]), i + 1, "session " .. i .. " starts with its whole queue of pending resumes") end
local parked_before = rows("SELECT id, status, due_at, prompt FROM self_wakes WHERE session_id=? ORDER BY id", { parked })
eq(#parked_before, 2, "the parked session has two pending resumes this install never asked for")

sent = { count = 0, ids = {} }
marker(T0 - 3600, 900)
selfloop.tick({ now = T0 + 8, dispatch = counted })
eq(sent.count, 3, "ONE resume turn per paused session: three paused sessions, three turns, and none for the parked one")
local seen = {}
for _, id in ipairs(sent.ids) do
  local row = rows("SELECT session_id FROM self_wakes WHERE id=?", { id })[1]
  check(row ~= nil, "the dispatched row is in the ledger: " .. tostring(id))
  local session = tostring(row.session_id)
  check(not seen[session], "each turn belongs to a different session (this one is " .. session .. ")")
  seen[session] = true
end
for i = 1, 3 do
  eq(#live_rows(paused[i]), 1, "session " .. i .. " is left with exactly ONE pending-or-dispatching resume row")
  check(seen[paused[i]] == true, "and that row is the one turn session " .. i .. " got")
end
local parked_after = rows("SELECT id, status, due_at, prompt FROM self_wakes WHERE session_id=? ORDER BY id", { parked })
eq(#parked_after, #parked_before, "the parked session keeps every row it had")
for k = 1, #parked_before do
  eq(tostring(parked_after[k].status), tostring(parked_before[k].status), "parked row " .. k .. " keeps its status")
  eq(tostring(parked_after[k].due_at), tostring(parked_before[k].due_at), "parked row " .. k .. " keeps its own time (a held session is not released)")
  eq(tostring(parked_after[k].prompt), tostring(parked_before[k].prompt), "parked row " .. k .. " keeps its prompt (no release line was stamped on it)")
end

-- ---- 5. THE INSTALLED LINE NAMES THE PROGRAM AND THE TREE, VERBATIM (factory-small-items item 1, 25/11) ------
-- MEASURED on this node: `wa --version` answers `wasm-agent v0.1.2 - va1857d15 - tree 70eb209d` - a PROGRAM and a
-- TREE - and the release line named only the tree. A Lua-only install therefore said "this node now runs <tree>"
-- while the program was unchanged, and a compile install said the same while the program had moved too.
--
-- This drives the real tick twice and asserts the EXACT first line of what the resumed worker reads: once for a
-- Lua-only install (the tree moves, the bytes do not) and once for a compile install (program and tree both move).
-- The third case is the replay the brief names: a pause taken while scripts/upgrade.sh's INTERIM record is the last
-- word records the INCOMING commit as if the node ran it, so the finished record looks unchanged and the release
-- says "the update did not happen" after a real install. An interim record is not an identity; that release says
-- what it can see instead.
local function full_record(fields)
  local order = { "commit", "lua_tree", "lua_fast_path", "binary_commit", "binary_release", "sha256",
    "record_role", "via" }
  local body = {}
  for _, key in ipairs(order) do
    if fields[key] ~= nil then body[#body + 1] = key .. "=" .. fields[key] end
  end
  local wrote = host.write_file(install_dir .. "/installed.txt", table.concat(body, "\n") .. "\n")
  check(wrote == true, "the install record is written at " .. install_dir .. "/installed.txt")
end
local function first_line(text)
  return (tostring(text or ""):match("^[^\n]*") or "")
end
local function release_notice(session, at)
  marker(T0 - 60, 900)
  local wake = unpause(session, { no_record = false })
  return wake, function()
    marker(T0 - 3600, 900)
    sent = { count = 0, ids = {} }
    selfloop.tick({ now = at, dispatch = counted })
    return rows("SELECT * FROM self_wakes WHERE id=?", { wake })[1]
  end
end

-- 5a. A LUA-ONLY INSTALL: the tree moves, the bytes (and so the program) do not.
full_record({ commit = "aaaa1111bbbb2222", lua_tree = "aaaa1111bbbb2222", lua_fast_path = "1",
  binary_commit = "cccc3333dddd4444", sha256 = "1111111111111111" })
local lua_session = memory.start_session("local", "chat", { id = "fsi-lua-only", user_id = "master", title = "lua" })
local _, finish_lua = release_notice(lua_session, T0 + 10)
full_record({ commit = "bbbb5555eeee6666", lua_tree = "bbbb5555eeee6666", lua_fast_path = "1",
  binary_commit = "cccc3333dddd4444", sha256 = "1111111111111111" })
local lua_row = finish_lua()
eq(first_line(lua_row.prompt),
  "[deploy] installed: this node now runs program vcccc3333dddd, tree bbbb5555eeee "
    .. "(was program vcccc3333dddd, tree aaaa1111bbbb).",
  "a Lua-only install says the program it kept and the tree it moved")

-- 5b. A COMPILE INSTALL: program and tree are the commit that was built, and both moved.
full_record({ commit = "dddd4444eeee5555", lua_tree = "dddd4444eeee5555", lua_fast_path = "0",
  sha256 = "2222222222222222" })
local compile_session = memory.start_session("local", "chat", { id = "fsi-compile", user_id = "master", title = "compile" })
local _, finish_compile = release_notice(compile_session, T0 + 11)
full_record({ commit = "ffff6666aaaa7777", lua_tree = "ffff6666aaaa7777", lua_fast_path = "0",
  sha256 = "3333333333333333" })
local compile_row = finish_compile()
eq(first_line(compile_row.prompt),
  "[deploy] installed: this node now runs program vffff6666aaaa, tree ffff6666aaaa "
    .. "(was program vdddd4444eeee, tree dddd4444eeee).",
  "a compile install names the program and the tree it installed, and the pair it replaced")

-- 5c. THE REPLAY: a pause taken inside the swap, with scripts/upgrade.sh's interim record as the last word.
full_record({ commit = "ffff6666aaaa7777", record_role = "interim", via = "deploy.sh" })
local interim_session = memory.start_session("local", "chat", { id = "fsi-interim", user_id = "master", title = "interim" })
local interim_wake, finish_interim = release_notice(interim_session, T0 + 12)
local interim_record_file = json.decode(host.read_file(record_dir .. "/" .. interim_session .. ".json") or "{}")
eq(interim_record_file.installed_tree, nil, "a pause taken on an interim record names no tree: the swap is not done")
eq(interim_record_file.installed_commit, nil, "and no commit")
full_record({ commit = "ffff6666aaaa7777", lua_tree = "ffff6666aaaa7777", lua_fast_path = "0",
  sha256 = "3333333333333333" })
local interim_row = finish_interim()
check((interim_row.prompt or ""):find(pause.UNKNOWN, 1, true) ~= nil,
  "the release after an install it could not measure says the pause ended: " .. tostring(interim_row.prompt):sub(1, 200))
check((interim_row.prompt or ""):find(pause.NOT_HAPPENED, 1, true) == nil,
  "and it never says the update did not happen after an install that happened")
check((interim_row.prompt or ""):find("ffff6666aaaa", 1, true) ~= nil,
  "naming the tree this node runs now")

-- 5d. THE FACTS THAT COUNT AS A MOVE, as functions: a rebuild of the same commit (same ids, new bytes) is an
-- install; so is a prebuilt install whose program moved; and two identical records are still not one.
eq(pause.install_moved({ tree = "t", commit = "c", program = "p", sha256 = "old" },
  { tree = "t", commit = "c", program = "p", sha256 = "new" }), true,
  "a rebuild of the same commit moves the bytes, so the release says installed")
eq(pause.install_moved({ tree = "t", commit = "c", program = "p1", sha256 = "s" },
  { tree = "t", commit = "c", program = "p2", sha256 = "s" }), true, "a program that moved is an install")
eq(pause.install_moved({ tree = "t", commit = "c", program = "p", sha256 = "s" },
  { tree = "t", commit = "c", program = "p", sha256 = "s" }), false, "the same four facts twice is not an install")

pcall(host.remove_file, record_dir .. "/" .. swap_session .. ".json")
pcall(host.remove_file, MARKER)
print("deploy release ok (" .. checks .. " checks): a leaked or crashed marker releases ONE resume turn per paused session, that says what happened, and leaves a held session alone")

