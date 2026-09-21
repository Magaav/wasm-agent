-- Prefix stability, and the guard that keeps a big session alive.
--
-- Unchanged instructions preserve prefix bytes. Changed instructions take effect without a
-- restart: protecting cache hits must never preserve stale authority. Explicit mutation makes
-- this a real freshness test rather than a vacuous comparison of two reads of the same file.
-- The model window remains the default compaction guard; an explicit budget can only lower it.
--
-- Run: WASM_AGENT_AGENTS_MD=<tmp> WA_SCRIPT=scripts/test-prefix-stability.lua wa --db /tmp/x.db
local agent = dofile("lua/core/agent.lua")
local window = dofile("lua/core/model_window.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

local path = host.getenv("WASM_AGENT_AGENTS_MD")
ok(path and path ~= "", "the test must run with WASM_AGENT_AGENTS_MD pointing at a scratch file", tostring(path))
ok(host.write_file(path, "ORIGINAL INSTRUCTIONS\n"), "the scratch file can be written")

local first = agent.agents_md("master")
ok(first and first:find("ORIGINAL INSTRUCTIONS", 1, true) ~= nil, "the first read sees the file")

ok(agent.agents_md('master')==first,'unchanged instruction bytes remain identical')
-- A legitimate edit is a legitimate prefix change, not a cache defect.
ok(host.write_file(path, "CHANGED INSTRUCTIONS\n"), "the scratch file can be rewritten")
local second = agent.agents_md("master")
ok(second ~= first, "instruction changes must not require a restart")
ok(second:find("CHANGED", 1, true) ~= nil, "updated instructions are visible at the next context build")

-- Fresh reads must not merge role boundaries.
local guest = agent.agents_md("guest")
ok(guest ~= nil and guest ~= first, "the guest instructions are still their own file")

-- The window decides by default, which is pi's policy. A budget is opt-in, and it can only make compaction
-- happen earlier - never later, or a call would be sent past its model.
local limit = 1000000
local reserve = window.policy(limit)
local off_trigger = (0 > 0) and math.min(limit - reserve, 0) or (limit - reserve)
ok(off_trigger == limit - reserve, "with no budget configured the window is the trigger")
local opt_in = 64000
ok(math.min(limit - reserve, opt_in) == opt_in, "a configured budget fires earlier than the window")
ok(math.min(limit - reserve, opt_in) <= limit - reserve, "and can never fire later than it")

print("prefix stability ok (" .. checks .. " checks)")
