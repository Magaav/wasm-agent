-- The window's `/efficiency_report` route: the node must return the same deterministic report
-- the CLI prints, for one session.
--
-- The UI test stubs this route, so without a node-side test the command could be listed in the
-- window and render a fixture while the real route answered nothing. server.lua defines its
-- routes as globals (that is how the host calls them), so it is sourced and the global called.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local telemetry = dofile("lua/core/telemetry.lua")
dofile("lua/core/server.lua")
assert(type(wa_efficiency) == "function", "server.lua must define wa_efficiency")
memory.setup()
telemetry.setup()

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

-- One measured call, so the report is not the empty-session case.
local sid = memory.start_session("", "efficiency route", {
  user_id = "master", node_id = "", title = "efficiency route",
})
local shape = {
  system_bytes = 1000, user_bytes = 100, assistant_bytes = 2000, tool_result_bytes = 0,
  other_bytes = 0, schema_bytes = 500, reasoning_source_bytes = 0,
  tool_arguments_source_bytes = 0, messages = 3, tool_results = 0, tool_calls = 0,
  images = 0, total_message_bytes = 3100,
}
local span = telemetry.start({ session_id = sid, run_id = "r" }, "model_call", {
  model = "fixture", prompt_shape = shape,
  prefix_audit = { schema_version = 1, relation = "append_only", messages = 3, shared_messages = 1 },
})
telemetry.finish(span, {
  ok = true,
  usage = { prompt_tokens = 1000, completion_tokens = 10 },
  normalized = telemetry.normalize({ prompt_tokens = 1000, completion_tokens = 10 }),
})

local body = json.decode(wa_efficiency(sid, ""))
ok(type(body.text) == "string" and #body.text > 0, "the route must return report text")
ok(body.session_id == sid, "the route must name the session it read")
ok(body.text:find("efficiency report", 1, true) ~= nil, "the text must be the report")
ok(body.text:find("where the request bytes go", 1, true) ~= nil, "the report must carry its tables")
ok(body.text:find("last call", 1, true) ~= nil, "and the per-call section")

-- An unknown session is refused, not answered with an empty report.
ok(json.decode(wa_efficiency("does-not-exist", "")).error == "unknown_session",
  "an unknown session must be refused")

print("efficiency route ok (" .. checks .. " checks)")
