-- THE WATCHER IS ON `wa status`, AND ITS ABSENCE NAMES THE FIX (Fable 26/11, work).
--
-- MEASURED on work (a Docker container with no systemd), twice on 26/11: `wa-sentinel start` failed, the reason went to
-- the container's stdout, and `wa status` - the page a person reads - did not mention the watcher at all, running or not.
-- The only surface that refused was `wa update`, whose sentence began by sending the reader somewhere else. A page that
-- says nothing about the watcher is how two failed starts went unseen.
--
-- This row holds the line's four answers on the module's own seam (`read_file`, `alive`, `sentinel`, `config`), and then
-- the REAL path: a scratch home with no pid file, `status.lines()` must carry the not-running line with an absolute
-- command, exactly once.
--
--   WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-status-watcher-line.lua wa --db <that home>/t.db
-- The scratch ledger must exist before status.lines() asks it for the session line: a row that reads a store opens
-- it the way the node does (memory.setup()), never by creating a table by hand.
dofile("lua/core/memory.lua").setup()
local status = dofile("lua/core/status.lua")

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
local function says(text, needle, label)
  checks = checks + 1
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    error(label .. ": expected " .. needle .. " in " .. tostring(text), 2)
  end
end

local CONFIG = "/fixture/config"

-- 1. NO PID FILE: not running, and the ONE command that starts it, at an absolute path.
local none = status.watcher_line({ config = CONFIG, sentinel = "/fixture/install/wa-sentinel", read_file = function() return nil end })
eq(none, "watcher   not running - start it: /fixture/install/wa-sentinel start",
  "with no pid file the line is the command that fixes it")

-- 2. A PID FILE AND A LIVE PROCESS: running, with the pid a reader can check.
local live = status.watcher_line({ config = CONFIG, sentinel = "/fixture/install/wa-sentinel",
  read_file = function() return "4242\n" end, alive = function(pid) return pid == 4242 end })
eq(live, "watcher   running (pid 4242)", "a live pid is reported as running with its number")

-- 3. A STALE PID (the process is gone): not running, and the command again - a stale file must not read as a watcher.
local stale = status.watcher_line({ config = CONFIG, sentinel = "/fixture/install/wa-sentinel",
  read_file = function() return "4242\n" end, alive = function() return false end })
says(stale, "not running - start it: /fixture/install/wa-sentinel start", "a pid that is gone is not a running watcher")

-- 4. A PID FILE THAT NAMES NOTHING: the same answer, never a crash and never a silent blank.
local junk = status.watcher_line({ config = CONFIG, sentinel = "/fixture/install/wa-sentinel",
  read_file = function() return "not a pid\n" end, alive = function() return true end })
says(junk, "not running - start it:", "a pid file without a number is not a running watcher")

-- 5. THE REAL PATH, on this run's own home: no pid file there, so `status.lines()` carries the not-running line, once,
-- and it names an absolute command (never a bare `wa-sentinel`, which a reader in another directory would not find).
local lines = status.lines()
local found, count = nil, 0
for _, line in ipairs(lines or {}) do
  if tostring(line):find("^watcher%s") then count = count + 1; found = line end
end
eq(count, 1, "`wa status` carries exactly one watcher line")
says(found, "not running - start it: ", "and with no watcher on this scratch node it says so")
says(found, "/.local/bin/wa-sentinel start", "naming the installed sentinel's absolute path and its start verb")

print("status watcher line ok (" .. checks .. " checks): `wa status` always says whether the watcher runs, and its absence names the one command that starts it")
