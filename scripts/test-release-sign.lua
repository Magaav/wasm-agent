-- Signed releases on the fast path: the vault signs, and every path that installs a release refuses
-- anything a trusted key did not sign.
--
-- WHY A ROW AND NOT JUST A SHELL SCRIPT. `scripts/test-release-signing.sh` and `scripts/test-vault-sign.py`
-- are the real suites (they start a scratch vault, stand up file:// releases and drive the deploy's own
-- code). The fast path runs Lua rows, so this row is the one that runs them - and it hands them the binary
-- this run is about (`WA_FAST_BIN`, set by scripts/fast.sh), so the node's own verifier is judged by the
-- same six cases as the shell one, not by a different test that could drift.
--
-- What it proves, in one line each, is in the header of scripts/test-release-signing.sh: good signature
-- verifies; flipped byte, unknown key and missing signature are refused; a rotation announced by a trusted
-- key is accepted; one announced by an unknown key is refused; nothing unsigned is published or installed.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_FAST_BIN=<wa binary> WA_SCRIPT=scripts/test-release-sign.lua wa --db <scratch>
local json = dofile("lua/vendor/json.lua")
local root = host.getenv("WASM_AGENT_LUA_ROOT") or "."
local binary = host.getenv("WA_FAST_BIN") or ""

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end

local function shell(command)
  local raw = host.exec(command, root)
  local decoded = nil
  local fine, value = pcall(json.decode, tostring(raw or ""))
  if fine and type(value) == "table" then decoded = value end
  local code = decoded and tonumber(decoded.code) or -1
  local output = decoded and ((decoded.stdout or "") .. (decoded.stderr or "")) or tostring(raw or "")
  return code, output
end

local function have(tool)
  local code = shell("command -v " .. tool .. " >/dev/null 2>&1")
  return code == 0
end

for _, tool in ipairs({ "python3", "sha256sum", "curl", "git", "bash" }) do
  if not have(tool) then
    print("SKIP test-release-sign: " .. tool .. " is not on this machine, so the release-signing suites "
      .. "cannot run here (the vault, the verifier and the publisher all need it)")
    return
  end
end

-- 1. the shell suite: the six fixture cases, the shell verifier, a scratch vault, the deploy's release
--    path, the binary-only updater's gate, and the publisher + transport shipping the signature.
local command = "WA_RELEASE_BIN=" .. (binary ~= "" and ("'" .. binary .. "'") or "''") ..
  " bash scripts/test-release-signing.sh 2>&1"
local code, output = shell(command)
ok(code == 0, "the release-signing suite passed (exit " .. tostring(code) .. ")")
if code ~= 0 then
  for line in tostring(output):gmatch("[^\r\n]+") do print(line) end
end
ok(tostring(output):find("release%-signing: ok %(") ~= nil, "the suite reported its own ok line")
if binary ~= "" then
  ok(tostring(output):find("agrees with the shell verifier", 1, true) ~= nil,
    "the binary under test agreed with the shell verifier on all six cases")
end

-- 2. the vault's own suite: the key signs releases and cannot be read back, and the proxy has no route for
--    any of it.
local vault_code, vault_output = shell("python3 scripts/test-vault-sign.py 2>&1")
ok(vault_code == 0, "the vault's release-signing suite passed (exit " .. tostring(vault_code) .. ")")
ok(tostring(vault_output):find("0 failed") ~= nil, "the vault suite answered %d checks")
if vault_code ~= 0 then
  for line in tostring(vault_output):gmatch("[^\r\n]+") do print(line) end
end

if failed > 0 then
  error(string.format("release signing: %d of %d checks failed", failed, checks))
end
print(string.format("release signing ok (%d checks; the vault signs, every install path verifies)", checks))
