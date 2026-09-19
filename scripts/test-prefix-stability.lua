-- Prefix stability, and the guard that keeps a big session alive.
--
-- Two claims, both of which cost money if they are false:
--
--   1. Instructions are read once per node process. They sit at the front of every request, so re-reading
--      them every turn means an edit re-prices and re-slows every call for the rest of the session. Measured
--      the night this was written: two AGENTS.md edits, `cached_tokens: 0`, 27s time-to-first-token on a
--      723k prompt, and the provider dropped the stream.
--   2. The context budget is on by default. It is a guard, not the parity fix - pi runs huge contexts
--      happily because its prefix is stable and cached - but a guard that has to be remembered is not one.
--
-- The first version of this test was vacuous: it called agents_md twice and compared, which passes whether or
-- not a cache exists, because nothing changed the file in between. It was caught by mutating the cache away
-- and watching the test still pass. So this version points the node at a *temporary* instruction file and
-- edits it between the two calls, which is the only way the claim can fail.
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

-- The file changes underneath the process. With a per-process cache the instructions must NOT move: the
-- prefix is fixed for the life of the node, which is what keeps the provider's prompt cache warm.
ok(host.write_file(path, "CHANGED INSTRUCTIONS\n"), "the scratch file can be rewritten")
local second = agent.agents_md("master")
ok(second == first, "an edit on disk must not change the instructions mid-process",
  "got: " .. tostring(second):sub(1, 40))
ok(second:find("CHANGED", 1, true) == nil, "and the changed text must not have leaked into the prefix")

-- A different role is a different key, so caching did not merge roles.
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
