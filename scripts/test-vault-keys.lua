-- `/vault <name> <value>`: a key stored as `<name>.key` that the agent uses by name and never sees.
--
-- The promises checked here are the ones a leak would break: the value is written owner-only, it is
-- listed by name and never by value, the CLI echo and the queued row show the name only, and any tool
-- output that carries the value - however it got there - has it replaced before it is stored or sent.
--
-- Run from the repo root:
--   WASM_AGENT_KEYS_DIR=/tmp/k WA_SCRIPT=scripts/test-vault-keys.lua wa --db /tmp/x.db
local keys = dofile("lua/core/keys.lua")
local redact = dofile("lua/core/redact.lua")
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

ok((host.getenv("WASM_AGENT_KEYS_DIR") or "") ~= "", "the test runs against its own store (WASM_AGENT_KEYS_DIR), never the node's")

-- 1. Parsing and the masked echo.
local name, value = keys.parse("/vault github ghp_abcdefghijklmnopqrstuvwxyz0123")
ok(name == "github" and value == "ghp_abcdefghijklmnopqrstuvwxyz0123", "name and value split", tostring(name))
ok(keys.parse("/vault github") == "github", "a name alone parses")
ok(not keys.masked("/vault github s3cr3t-value"):find("s3cr3t", 1, true), "the echo never carries the value")
ok(keys.masked("/vault github s3cr3t-value"):find("github", 1, true), "the echo names the key")

-- 2. Names are file- and shell-safe.
ok(keys.set("../etc/passwd", "x").error == "invalid_key_name", "a path is not a name")
ok(keys.set("a b", "x").error == "invalid_key_name", "a space is not a name")
ok(keys.set("ok_name", "").error == "key_value_required", "an empty value is refused")
ok(keys.set("ok_name", "a\nb").error == "key_value_multiline", "a key is one line")

-- 3. Stored owner-only, listed by name, replaced in place.
local secret = "plain-looking-value-7f3a9c2e"
local stored = keys.set("service_x", secret)
ok(stored.ok and not stored.replaced, "stored", json.encode(stored))
ok(not json.encode(stored):find(secret, 1, true), "the answer never carries the value")
ok(host.read_file(keys.path("service_x")) == secret, "the file holds exactly the value")
local mode = json.decode(host.exec("stat -c %a '" .. keys.path("service_x") .. "'", ""))
ok(mode and tostring(mode.stdout or ""):match("^600"), "written 0600", mode and mode.stdout)
ok(keys.set("service_x", secret).replaced == true, "a second /vault replaces")
local listed = keys.names()
ok(table.concat(listed, ","):find("service_x", 1, true) ~= nil, "listed by name", table.concat(listed, ","))

-- 4. The value is an exact-value secret: a tool result that carries it is redacted, whatever its
-- shape (this one has no `sk-` prefix and no secret-looking name around it).
local result = redact.value({ stdout = "token is " .. secret .. " ok" }, { tool = "bash", args = { command = "env" } })
ok(not json.encode(result):find(secret, 1, true), "a tool result never carries a stored value", json.encode(result))
ok(not redact.text(redact.secrets("x " .. secret)):find(secret, 1, true), "the CLI redactor removes it too")

-- 5. The prompt line lists names and the path, never a value.
local line = keys.prompt_line()
ok(line and line:find("service_x", 1, true) and not line:find(secret, 1, true), "the prompt names the key only", line)

host.exec("rm -f '" .. keys.path("service_x") .. "'", "")
print("vault keys ok (" .. checks .. " checks)")
