-- THE PROGRAM THE HEALTH STEP STARTS (`wa land`, FACTORY.md rule 10), judged ACROSS PROCESSES.
--
-- The landing's `health` step starts `wa land health-run` as a supervised operation, and the program it hands
-- the operation manager is `runtime_info().binary_path`, i.e. this process's own binary. An install REPLACES
-- that binary while the landing runs, so on Linux `current_exe()` answers `<path> (deleted)` - and the operation
-- manager refuses a program that is not a file (`program_not_found`,
-- rust/wa-capabilities/src/operations.rs). The ledger's row of 22/11T12:48:09Z is exactly
-- `land main-health red detail=program_not_found`, and every landing that installed stopped there.
--
-- WHY A ROW OF ITS OWN, AND WHY A CHILD PROCESS. The defect lives in the seam between this tree's Lua and the
-- host's operation manager, so a stub of either side would judge the stub: the child is a COPY of this tree's
-- own binary that renames a fresh file over its own path - the swap an install makes - and then asks the REAL
-- operation manager for a program, through the same `land.start_operation` the health step calls. Its scratch
-- HOME, database and binary are its own; the build tree is never touched.
--
-- TWO ANSWERS, and the second is the one that must not become a launch:
--   * a replaced binary still names a path that HOLDS the installed binary, so the operation is accepted;
--   * a path with nothing at it is refused BY NAME, never satisfied by whatever `wa` is on PATH (a health run
--     started from a binary nobody chose judges main with it).
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_FAST_BIN=<wa> WA_SCRIPT=scripts/test-land-health-program.lua wa --db <scratch>

local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-health-program.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAILED: " .. label); os.exit(1) end
end
local function eq(got, want, label)
  ok(tostring(got) == tostring(want), label .. " (got [" .. tostring(got) .. "], wanted [" .. tostring(want) .. "])")
end
local function has(text, needle, label)
  ok(tostring(text):find(needle, 1, true) ~= nil, label .. " (the answer was [" .. tostring(text) .. "])")
end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ONE SHELL CALL, answered as {code, stdout, stderr}: the host answers JSON, and a row that cannot read it
-- must not read that as success.
local function exec(command, cwd, timeout)
  local raw = host.exec(command, cwd or "", timeout or 120)
  local okjson, answer = pcall(json.decode, tostring(raw))
  if not okjson or type(answer) ~= "table" then
    return { code = 127, stdout = "", stderr = "unreadable host answer: " .. tostring(raw) }
  end
  return answer
end

local tree = host.getenv("WASM_AGENT_LUA_ROOT") or ""
local binary = host.getenv("WA_FAST_BIN") or ""
if tree == "" then
  print("SKIP test-land-health-program: no WASM_AGENT_LUA_ROOT, so a child cannot load this tree's Lua")
  os.exit(0)
end
if binary == "" then
  -- ITS OWN BINARY, which is exactly the one the health step hands the operation manager: a copy is made
  -- below and only THAT copy is swapped, so neither the build tree nor this process's own file is touched.
  -- (WA_FAST_BIN is what the fast path exports; a row run by hand, or by scripts/test-discriminates.sh, has
  -- no such variable and must not skip on a fact it can read itself - a skip there is a half that was never
  -- judged.)
  local provided, raw = pcall(host.runtime_info)
  local info = {}
  if provided and type(raw) == "string" then pcall(function() info = json.decode(raw) or {} end) end
  binary = trim(tostring(info.binary_path or ""))
  local replaced = " (deleted)"
  if binary:sub(-#replaced) == replaced then binary = binary:sub(1, #binary - #replaced) end
end
if binary == "" then
  print("SKIP test-land-health-program: this process cannot name its own binary (runtime_info) and there is "
    .. "no WA_FAST_BIN, so there is nothing to copy (that half is UNPROVEN, not passed)")
  os.exit(0)
end

local made = exec("mktemp -d 2>/dev/null || mktemp -d -t wa-land-health-program", "/", 60)
local work = trim(made.stdout)
if work == "" then
  print("SKIP test-land-health-program: mktemp failed, so this row has no scratch directory")
  os.exit(0)
end
local function cleanup() exec("rm -rf " .. work, "/", 120) end

-- THE CHILD'S OWN SWAP AND ITS TWO QUESTIONS. It prints `key=value` lines and nothing else, so the parent
-- reads facts instead of prose.
local probe = [===[
local json = dofile("lua/vendor/json.lua")
local land = dofile("lua/core/land.lua")
local function say(key, value) print(key .. "=" .. tostring(value)) end
local function own_path()
  local provided, raw = pcall(host.runtime_info)
  local info = {}
  if provided and type(raw) == "string" then pcall(function() info = json.decode(raw) or {} end) end
  return tostring(info.binary_path or "")
end
local path = own_path()
say("path_before", path)
local suffix = " (deleted)"
local clean = path
if path:sub(-#suffix) == suffix then clean = path:sub(1, #path - #suffix) end
-- THE SWAP AN INSTALL MAKES: a new file renamed over this process's own path.
local swapped = os.execute("cp '" .. clean .. "' '" .. clean .. ".new' && chmod 755 '" .. clean
  .. ".new' && mv -f '" .. clean .. ".new' '" .. clean .. "'")
say("swap", swapped and "ok" or "failed")
say("path_after_swap", own_path())
local id, why = land.start_operation({ owner = "probe-health", args = { "--version" }, timeout_seconds = 120 })
say("after_swap_id", id or "")
say("after_swap_why", why or "")
-- AND THE OTHER DIRECTION: nothing at that path is a refusal by name.
local removed = os.execute("rm -f '" .. clean .. "'")
say("removed", removed and "ok" or "failed")
local id2, why2 = land.start_operation({ owner = "probe-health", args = { "--version" }, timeout_seconds = 120 })
say("gone_id", id2 or "")
say("gone_why", why2 or "")
]===]

local wrote = select(1, host.write_file(work .. "/probe.lua", probe))
if not wrote then cleanup(); print("FAILED: the probe script could not be written into " .. work); os.exit(1) end

local staged = exec("cp " .. binary .. " " .. work .. "/wa && chmod 755 " .. work .. "/wa", "/", 120)
if (staged.code or 1) ~= 0 then
  cleanup()
  print("FAILED: this tree's binary could not be copied to " .. work .. "/wa: " .. trim(staged.stderr))
  os.exit(1)
end

-- THE CHILD: its own HOME, node home, database and Lua root. WA_SCRIPT is unset on the way in, since the
-- variable names the script THIS process runs and a nested row must not inherit it.
local command = "env -u WA_SCRIPT -u WA_FAST_ROW_ENV -u WA_FAST_CLEARED"
  .. " HOME=" .. work .. "/user WASM_AGENT_HOME=" .. work .. "/node WASM_AGENT_DB=" .. work .. "/t.db"
  .. " WASM_AGENT_LUA_ROOT=" .. tree .. " WA_SCRIPT=" .. work .. "/probe.lua"
  .. " TMPDIR=" .. work .. " " .. work .. "/wa --db " .. work .. "/t.db"
local child = exec("mkdir -p " .. work .. "/user " .. work .. "/node && " .. command, work, 300)
local output = tostring(child.stdout or "") .. tostring(child.stderr or "")
local said = {}
for line in output:gmatch("[^\r\n]+") do
  local key, value = line:match("^(%a[%w_]*)=(.*)$")
  if key then said[key] = trim(value) end
end

if said.path_before == nil then
  cleanup()
  print("FAILED: the child printed no facts (exit " .. tostring(child.code) .. "): " .. output)
  os.exit(1)
end

-- THE PREMISE, measured here rather than assumed: an install's swap makes `current_exe()` answer a path
-- that is NOT a file any more. If a kernel ever stops saying so, this row says the premise moved.
local suffix = " (deleted)"
ok(said.path_after_swap:sub(-#suffix) == suffix,
  "a binary replaced under a running process reports `<path> (deleted)` (got [" .. said.path_after_swap .. "])")
eq(said.swap, "ok", "the swap itself succeeded (a new file renamed over this process's own path)")

-- ANSWER 1: the health step can still start the measurement, because the path holds the installed binary.
has(said.after_swap_id, "op-", "after the swap the operation was ACCEPTED (not program_not_found)")
eq(said.after_swap_why, "", "and nothing was refused")

-- ANSWER 2: nothing at the path is refused by name, with what to do about it.
eq(said.gone_id, "", "with nothing at the path no operation is started")
has(said.gone_why, "is not a file at ", "and the refusal names the rule that failed")
has(said.gone_why, "replaced", "and says the running binary was replaced")
has(said.gone_why, work .. "/wa", "and names the path, so an operator can look at it")

cleanup()
print(string.format("land-health-program ok (%d checks)", checks))

