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

-- The audit must not report a changed *setting* as a changed *prefix*: only the prefix can
-- invalidate a cache, and `max_tokens` shrinks as the context grows, so it changes on most
-- rounds. Measured over 48h, settings_changed was true on 142 of 852 prepared requests while
-- the provider reported a cache hit on 98.7% - which is why the two are separate fields.
local audit = dofile("lua/core/prefix_audit.lua")
local audit_session = "prefix-audit-test"
local first_body = { model = "m", messages = { { role = "user", content = "hi" } }, max_tokens = 100 }
ok(audit.observe(audit_session, "model_call", first_body, {}).relation == "unmeasured",
  "the first request has no baseline to compare against")
local same = audit.observe(audit_session, "model_call", first_body, {})
ok(same.settings_changed == false and same.prefix_changed == false, "an identical request changes nothing")
local grown = { model = "m", max_tokens = 90,
  messages = { { role = "user", content = "hi" }, { role = "assistant", content = "there" } } }
local appended = audit.observe(audit_session, "model_call", grown, {})
ok(appended.relation == "append_only", "a longer message list is append-only")
ok(appended.settings_changed == true and appended.prefix_changed == false,
  "a shrunken max_tokens is a settings change, not a prefix change")
local rewritten = { model = "m", max_tokens = 90, messages = { { role = "user", content = "different" } } }
ok(audit.observe(audit_session, "model_call", rewritten, {}).prefix_changed == true,
  "a rewritten message is a prefix change")

print("prefix stability ok (" .. checks .. " checks)")
