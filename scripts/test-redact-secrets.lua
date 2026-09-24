-- A tool result must not carry the node's own secret into the transcript, and the node must
-- say when it saw one.
--
-- Measured on the live ledger: a `bash` call dumped the config file, and the provider's API
-- key in its output was stored in `messages` and the sync journal and sent to the provider.
-- The redactor existed and its comment said tool results should pass through it, but no code
-- did, and the shape patterns would miss this value anyway (no `sk-` prefix). Exact-value
-- replacement closes it; `scan`/`hits` are the detection half, so an operator is told even
-- though the value is gone.
local json = dofile("lua/vendor/json.lua")
local redact = dofile("lua/core/redact.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

local SECRET = "sk-live-SECRETVALUE-0123456789abcdef"
local SECOND = "opencode-SECONDVALUE-4d5e6f7890abcdef"
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return SECRET end
  if key == "OPENCODE_GO_API_KEY" then return SECOND end
  return real_getenv(key)
end

-- The exact shape of the leak: a config-file dump inside a bash result.
local dumped = { code = 0, stdout = "=== env file ===\nWASM_AGENT_LLM_API_KEY=" .. SECRET ..
  "\nOPENCODE_GO_API_KEY=" .. SECOND .. "\nWASM_AGENT_LLM_MODEL=deepseek-v4.1-flash\n", stderr = "" }
local redacted, hits = redact.value(dumped)
ok(not json.encode(redacted):find(SECRET, 1, true), "the secret must not survive in the result")
ok(not json.encode(redacted):find(SECOND, 1, true), "every configured secret is removed")
ok(hits.WASM_AGENT_LLM_API_KEY == 1 and hits.OPENCODE_GO_API_KEY == 1,
  "the hit names what was found, so the operator can be told")
ok(redacted.stdout:find("<redacted>", 1, true) ~= nil, "the value is replaced with a marker")
ok(redacted.stdout:find("WASM_AGENT_LLM_MODEL=deepseek", 1, true) ~= nil, "the rest is kept")
ok(redacted.code == 0, "non-string fields are untouched")

-- Detection without modification: `scan` never returns the value.
local found = redact.scan("line\nkey=" .. SECRET .. " and again " .. SECRET)
ok(found.WASM_AGENT_LLM_API_KEY == 2, "scan counts the occurrences")
ok(json.encode(found):find(SECRET, 1, true) == nil, "scan must not carry the value")
ok(next(redact.scan("nothing secret here")) == nil, "a clean string scans empty")

-- The caller's table is not mutated.
ok(dumped.stdout:find(SECRET, 1, true) ~= nil, "the original table must be left alone")

-- Nested tables (a read result, a bash receipt) are walked.
local nested = { full_result = { path = "x", preview = "key=" .. SECRET } }
local nested_hits = select(2, redact.value(nested))
ok(not json.encode(redact.value(nested)):find(SECRET, 1, true), "nested strings are redacted")
ok(nested_hits.WASM_AGENT_LLM_API_KEY == 1, "nested hits are counted")

-- A single string, for callers that only have text.
local text, string_hits = redact.secrets("WASM_AGENT_LLM_API_KEY=" .. SECRET)
ok(not text:find(SECRET, 1, true) and string_hits.WASM_AGENT_LLM_API_KEY == 1,
  "the string form redacts and reports")

-- Ordinary text is not mangled: the shape patterns would mask `task-runner`, exact values do not.
ok(redact.value({ stdout = "task-runner risk-assessment docs/task-queue.md" }).stdout ==
  "task-runner risk-assessment docs/task-queue.md", "ordinary text must be untouched")

-- Only the node's own configured secrets are replaced by the exact pass; this pins the
-- boundary so the behaviour is explicit rather than assumed.
ok(redact.value({ stdout = "OTHER_KEY=whatever" }).stdout == "OTHER_KEY=whatever",
  "only the node's own configured secrets are replaced")

-- End to end: a bash result carrying the key must be stored without it, and the node must
-- record that it saw one. This is the whole property - prevention and detection - through
-- the real agent loop, so a refactor that drops either half fails here.
local agentlib = dofile("lua/core/agent.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local telemetry = dofile("lua/core/telemetry.lua")
telemetry.setup()
local real_exec = host.exec
host.exec = function()
  return json.encode({ code = 0, stdout = "=== env ===\nWASM_AGENT_LLM_API_KEY=" .. SECRET, stderr = "" })
end
local step = 0
local real_stream = host.http_stream
host.http_stream = function()
  step = step + 1
  if step == 1 then
    return json.encode({ status = 200, content = "", finish_reason = "tool_calls",
      tool_calls = { { id = "c1", type = "function",
        ["function"] = { name = "bash", arguments = '{"command":"env"}' } } } })
  end
  return json.encode({ status = 200, content = "done", finish_reason = "stop", tool_calls = {} })
end
local sid = memory.ensure_session("redact-e2e", "local", "redact")
local agent = agentlib.new(sid, function() end, "master", "redact-e2e", "local")
agent.stream = true
local ran = pcall(agent.run, agent, "run env")
host.exec = real_exec
host.http_stream = real_stream
ok(ran, "the end-to-end turn must run")
local leaked = false
for _, row in ipairs(memory.session_messages(sid, { all = true })) do
  if tostring(row.content or ""):find(SECRET, 1, true) then leaked = true end
end
ok(not leaked, "the stored transcript must not contain the secret")
local saw = false
for _, event in ipairs(telemetry.events(sid, 0, 200).events) do
  if event.kind == "secret_redacted" then saw = true end
end
ok(saw, "the node must record that it saw a secret, not redact it silently")

host.getenv = real_getenv
print("redact secrets ok (" .. checks .. " checks)")
