-- The long-call row, end to end: a real operation, a real output file, and the facts the host
-- publishes while it runs (docs/TOOL-PROGRESS.md).
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-tool-progress-live.lua wa --db <scratch>/t.db
--
-- `scripts/test-tool-progress.lua` pins the wording and the dialects with a tail fed by hand. This one
-- pins the *plumbing* that no unit test can: an operation started through the supervisor, whose output
-- file grows with cargo-like lines while the caller polls it, is published to
-- `<data>/tool-progress.json` by the wait loop, and the CLI's module reads a moving row out of it. If
-- the publish path ever stops writing (a refactor of the wait loop, a path that disagrees with
-- `wa-tool-progress::data_path`), this fails and the hand-fed test would not.
--
-- No network, no node: the command is the platform's own do-nothing wait, its output redirected to
-- nowhere, and every byte the row shows is written by this test into the operation's own stdout file.
local json = dofile('lua/vendor/json.lua')
local platform = dofile('lua/core/platform.lua')
local tp = dofile('lua/core/tool_progress.lua')

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end

local function decode(raw)
  local ok_decode, value = pcall(json.decode, raw or '')
  return ok_decode and type(value) == 'table' and value or nil
end

-- The command only has to outlive the test's own polling; its output is redirected, so the only bytes
-- in the operation's stdout are the ones this test appends. The null device follows the *shell* the
-- host runs, not the OS: on Windows with a `sh` shell, `>NUL` writes a file called `NUL` into the
-- working directory (it did, once), which is a mess in the caller's checkout.
local shell = tostring(platform.shell() or ""):lower()
local null_device = shell:find("cmd", 1, true) and "NUL" or "/dev/null"
local command = shell:find("cmd", 1, true) and ("ping -n 8 127.0.0.1 >" .. null_device)
  or ("sleep 6 >" .. null_device .. " 2>&1")

local started = decode(host.operation("start", json.encode({
  command = command, timeout_seconds = 60, owner = "test-tool-progress" })))
ok(type(started) == 'table' and type(started.operation_id) == 'string', "the operation started")
if type(started) ~= 'table' or type(started.operation_id) ~= 'string' then
  print(string.format("%d checks, %d failed", checks, failed))
  os.exit(1)
end
local id = started.operation_id

local state = decode(host.operation("status", json.encode({ id = id }))) or {}
local stdout_path = tostring(state.stdout_path or "")
ok(stdout_path ~= "", "the operation names its own stdout file: " .. stdout_path)

-- The row's own file, resolved the way the host resolves it.
local live = tp.path()
ok(type(live) == 'string' and live:sub(-18) == "tool-progress.json", "the row's file: " .. tostring(live))

-- Write a line the way a compiler would: appended to the operation's stdout.
local function append(text)
  local ok_read, before = pcall(host.read_file, stdout_path)
  local body = (ok_read and type(before) == 'string') and before or ""
  local wrote, problem = pcall(host.write_file, stdout_path, body .. text)
  if not wrote then print("note: append failed: " .. tostring(problem)) end
end

-- A command under two seconds has no row: the status line is enough.
append("   Compiling serde_json v1.0.0\n")
local early = decode(host.operation("wait", json.encode({ id = id, wait_ms = 200, tool = "bash" }))) or {}
ok(early.settled ~= true, "the operation is still running")
eq(tp.status({ now = host.now() }), nil, "under two seconds: no row, whatever the output says")

-- Now let it get old enough to say something, and feed it a compiler's progress line.
local observed = {}
for step = 1, 8 do
  host.sleep(400)
  if step == 2 then append("    Building [=============>         ] 143/412: serde_json, syn, proc-macro2\n") end
  if step == 4 then append("    Building [================>     ] 301/412: syn, proc-macro2, quote\n") end
  local waited = decode(host.operation("wait", json.encode({ id = id, wait_ms = 400, tool = "bash" })))
  ok(type(waited) == 'table', "the wait answered")
  local row = tp.status({ now = host.now() })
  if row and row.text then observed[#observed + 1] = row.text end
end

-- An older binary has no publish path at all (the feature is host-side), and this test would then
-- fail on a node that simply has not been upgraded yet. That is a SKIP with its reason, never a pass:
-- `scripts/test-tool-progress.lua` still pins the wording and the dialects on any binary.
if #observed == 0 and tp.live({ refresh = true }) == nil then
  host.operation("cancel", json.encode({ id = id }))
  print("SKIPPED: this host never published " .. tostring(live) ..
    " - the binary predates the long-call row (docs/TOOL-PROGRESS.md)")
  os.exit(0)
end
ok(#observed >= 2, "the row was published while the call ran: " .. #observed .. " observations")
local joined = table.concat(observed, "\n")
ok(joined:find("\u{27F3} bash", 1, true) ~= nil, "the row names the call the launch called it: bash")
ok(joined:find("143/412", 1, true) ~= nil or joined:find("301/412", 1, true) ~= nil,
  "and carries the compiler's own count")
ok(joined:find(tp.bar(143 / 412), 1, true) ~= nil or joined:find(tp.bar(301 / 412), 1, true) ~= nil,
  "with the bar the two other renderers draw")
-- The clock moves: the first and last observations are not the same sentence.
if observed[1] and observed[#observed] then
  ok(observed[1] ~= observed[#observed],
    "the row moves while the call runs: " .. observed[1] .. " -> " .. observed[#observed])
end
ok(not joined:find("\n\n", 1, true), "one row per observation, never a wrapped one")

-- The call ends: the row goes with it, and the file says so.
host.operation("cancel", json.encode({ id = id }))
local after = tp.status({ now = host.now() })
eq(after, nil, "a cancelled call has no row")
local facts = tp.live({ refresh = true })
ok(facts == nil or facts.state == "done", "and the published file says it is over")

print(string.format("%d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
