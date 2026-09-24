-- A tool result must not carry the node's own secret into the transcript.
--
-- Measured on the live ledger: a `bash` call dumped the config file, and the API key in its
-- output was stored in `messages` (and the sync journal) and sent to the provider. The
-- redactor existed and its comment said tool results should pass through it, but no code
-- did, and the shape patterns would miss this value anyway (no `sk-` prefix). Exact-value
-- replacement is what closes it, and it must not mangle ordinary text.
local json = dofile("lua/vendor/json.lua")
local redact = dofile("lua/core/redact.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

local SECRET = "sk-live-SECRETVALUE-0123456789abcdef"
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return SECRET end
  return real_getenv(key)
end

-- The exact shape of the leak: a config-file dump inside a bash result.
local dumped = { code = 0, stdout = "=== env file ===\nWASM_AGENT_LLM_API_KEY=" .. SECRET ..
  "\nWASM_AGENT_LLM_MODEL=deepseek-v4.1-flash\n", stderr = "" }
local redacted = redact.value(dumped)
ok(not json.encode(redacted):find(SECRET, 1, true), "the secret must not survive in the result")
ok(redacted.stdout:find("<redacted>", 1, true) ~= nil, "the value is replaced with a marker")
ok(redacted.stdout:find("WASM_AGENT_LLM_MODEL=deepseek", 1, true) ~= nil, "the rest is kept")
ok(redacted.code == 0, "non-string fields are untouched")

-- The caller's table is not mutated.
ok(dumped.stdout:find(SECRET, 1, true) ~= nil, "the original table must be left alone")

-- Nested tables (a read result, a bash receipt) are walked.
local nested = { full_result = { path = "x", preview = "key=" .. SECRET } }
ok(not json.encode(redact.value(nested)):find(SECRET, 1, true), "nested strings are redacted")

-- Ordinary text is not mangled: the shape patterns would mask `task-runner`, exact values do not.
ok(redact.value({ stdout = "task-runner risk-assessment docs/task-queue.md" }).stdout ==
  "task-runner risk-assessment docs/task-queue.md", "ordinary text must be untouched")

-- A different secret that is not configured is out of scope for the exact pass; this pins
-- that boundary so the behaviour is explicit rather than assumed.
ok(redact.value({ stdout = "OTHER_KEY=whatever" }).stdout == "OTHER_KEY=whatever",
  "only the node's own configured secrets are replaced by the exact pass")

host.getenv = real_getenv
print("redact secrets ok (" .. checks .. " checks)")
