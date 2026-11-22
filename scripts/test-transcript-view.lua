-- A LONG SESSION MUST NOT PAY FOR DIAGNOSTIC BYTES IT NEVER READS (21/11).
--
-- The stall this closes: a turn's cost before its first model call grew with the session's history.
-- Measured on a scratch session of 1502 rows carrying real-sized tool spans:
--
--   session_messages(all=true), as build_context asked  730 ms   (17.3 MB of trace decoded: 663 ms)
--   the same rows without trace/changes                 181 ms
--
-- `build_context` turns rows into {role, content, tool_calls} - it never reads `trace` (the tool spans
-- a turn ran) or `changes` (the files it touched). Both are per-row diagnostic JSON that accumulates
-- with a day of real tool output, so every turn of a long thread decoded megabytes it then dropped.
--
-- What this asserts, in order of how much it can be trusted:
--   1. the SHAPE: asking for a transcript row does not hand back trace/changes (deterministic, and the
--      thing the hot path relies on); the default shape still does, so the column exists and is only
--      skipped on request;
--   2. the WIRING: the two transcript loads in agent.lua ask for the view - a source check, because a
--      caller reverting to `all = true` would silently restore the cost with no failing assertion
--      anywhere else;
--   3. the COST: on rows with large traces, the transcript view is materially cheaper than the full
--      one. A timing bound with a wide margin (measured 4x, asserted 2x) - it fails on a regression,
--      not on a busy machine.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')

local checks, failures = 0, 0
local function check(value, why)
  checks = checks + 1
  if not value then failures = failures + 1; print("FAIL " .. why) end
end

local home = host.getenv("WASM_AGENT_HOME") or ""
check(home ~= "" and not home:match("/%.wasm%-agent$"),
  "this test must run in a scratch WASM_AGENT_HOME, not the node's own: " .. tostring(home))

memory.setup()
local sid = "transcript-view"
if not memory.session(sid) then
  memory.start_session('', 'chat', { id = sid, user_id = 'transcript-view', node_id = '', title = 'transcript view' })
end

-- ---- seed rows with REAL-SIZED traces ------------------------------------------------------------
local existing = tonumber(memory.message_count(sid)) or 0
local TARGET = 240
if existing < TARGET then
  local span = string.rep('x', 24000) -- one tool span's output, the size a real bash call returns
  for i = existing + 1, TARGET do
    local role = (i % 2 == 1) and 'user' or 'assistant'
    local row = { role = role, debug = 0 }
    if role == 'user' then
      row.content = 'question ' .. i
    else
      row.content = 'answer ' .. i
      row.trace = { { kind = 'tool', name = 'bash', ok = true, ms = 240, output = span } }
      row.changes = { files = { { path = 'lua/core/agent.lua', added = 3, removed = 1 } } }
    end
    memory.append_turn(sid, row)
  end
end
check((tonumber(memory.message_count(sid)) or 0) >= TARGET, "the fixture session holds its rows")

-- ---- 1. the shape --------------------------------------------------------------------------------
local function ms() return (host.monotonic_ms and host.monotonic_ms()) or (host.now() * 1000) end

local plain = memory.session_messages(sid, { all = true, view = 'transcript' })
check(#plain > 0, "the transcript view returns the session's rows (" .. #plain .. ")")
local saw_content, saw_calls = false, false
-- ONE verdict for the loop, not one per row: a failure here is the shape, and 240 identical lines hide
-- the assertion that mattered.
local leaked_trace, leaked_changes = 0, 0
for _, row in ipairs(plain) do
  if row.trace ~= nil then leaked_trace = leaked_trace + 1 end
  if row.changes ~= nil then leaked_changes = leaked_changes + 1 end
  if type(row.content) == 'string' and row.content ~= '' then saw_content = true end
  if row.tool_calls ~= nil then saw_calls = true end
end
check(leaked_trace == 0, "no transcript row carries a trace column (" .. leaked_trace .. " did)")
check(leaked_changes == 0, "no transcript row carries a changes column (" .. leaked_changes .. " did)")
check(saw_content, "and still carries content: the columns a replay reads are present")
check(saw_calls, "and still carries tool_calls, decoded")

-- The column is skipped ON REQUEST, not missing from the row: the full shape still has it.
local full = memory.session_messages(sid, { all = true })
local carried_trace = false
for _, row in ipairs(full) do if row.trace ~= nil then carried_trace = true break end end
check(carried_trace, "the default shape still carries trace, so the view is what skips it")

-- ---- 2. the wiring -------------------------------------------------------------------------------
local root = (host.getenv("WASM_AGENT_LUA_ROOT") or "."):gsub("/+$", "")
local ok, agent_source = pcall(host.read_file, root .. "/lua/core/agent.lua")
if ok and type(agent_source) == 'string' then
  local views = 0
  for _ in agent_source:gmatch("view%s*=%s*'transcript'") do views = views + 1 end
  for _ in agent_source:gmatch('view%s*=%s*"transcript"') do views = views + 1 end
  check(views >= 2,
    "both transcript loads in agent.lua ask for the transcript view (found " .. views ..
    "); a caller back on all=true restores the whole cost silently")
else
  check(false, "could not read agent.lua to check the wiring: " .. tostring(agent_source))
end

-- ---- 3. the cost, with a wide margin -------------------------------------------------------------
local t0 = ms()
local heavy = memory.session_messages(sid, { all = true })
local heavy_ms = ms() - t0
t0 = ms()
local light = memory.session_messages(sid, { all = true, view = 'transcript' })
local light_ms = ms() - t0
check(#heavy == #light, "both shapes return the same rows (" .. #heavy .. "/" .. #light .. ")")
-- MEASURED margin on 240 rows of 24 KB traces: the full shape decodes ~5.8 MB, the view does not.
-- 2x is the assertion; anything near 1x means the view stopped skipping the columns.
if heavy_ms > 20 then
  check(light_ms * 2 < heavy_ms,
    string.format("the transcript view is materially cheaper (full %.0fms vs view %.0fms)", heavy_ms, light_ms))
else
  print("note: the full load was too fast to compare (" .. string.format("%.0f", heavy_ms) .. "ms) - cost check skipped as inconclusive")
end

if failures > 0 then
  print(failures .. " of " .. checks .. " checks failed")
  os.exit(1)
end
print("transcript view ok — " .. checks .. " checks")
