-- Does this binary ship the credential module, and does the node's own loader reach it?
-- Run from a directory with no `lua/` and with WASM_AGENT_LUA_ROOT unset: this is the shape the
-- installed node runs. Nothing here reads the working tree except the byte-for-byte comparison.
local fails = 0
local function ok(cond, label, detail)
  if cond then print("PROBE ok " .. label)
  else fails = fails + 1; print("PROBE FAIL " .. label .. " [" .. tostring(detail) .. "]") end
end

local path = "lua/core/openai_sub_auth.lua"
local embedded = EMBEDDED[path]
ok(type(embedded) == "string" and #embedded > 1000, "the module is in the embedded registry",
  type(embedded) .. " bytes=" .. tostring(embedded and #embedded))

-- Negative control: an unregistered module must be refused by the same loader, so a pass above is
-- not "dofile always answers".
local raised = select(2, pcall(dofile, "lua/core/definitely-not-registered.lua"))
ok(tostring(raised):find("embedded module missing", 1, true) ~= nil,
  "an unregistered module is refused by name", tostring(raised))

-- The registry lookup `dofile` itself uses, with no root set.
local loaded = dofile(path)
ok(type(loaded) == "table" and type(loaded.token) == "function",
  "dofile serves the module with no lua root", type(loaded))
ok(LOADED_SOURCES[path] ~= nil, "the load was recorded with its sha256", tostring(LOADED_SOURCES[path]))

-- Byte-for-byte against the working tree copy (so the embedded copy is not stale).
local tree = host.getenv("VERIFY_TREE") or "."
local disk = host.read_file(tree .. "/" .. path)
ok(type(disk) == "string" and host.sha256(disk) == host.sha256(embedded),
  "the embedded copy is byte-identical to the working tree", tostring(disk and #disk))

-- And the embedded copy actually runs: ask it for a token with no store present.
local token, failure = loaded.token()
ok(token == nil and failure and failure.code == "subscription_credentials_absent",
  "the embedded module answers the taxonomy, not a crash", tostring(failure and failure.code))
print("PROBE verdict failures=" .. tostring(fails))
if fails > 0 then error("embedded probe failed") end
