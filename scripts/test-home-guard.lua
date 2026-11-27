-- THE ONE RULE A LEDGER-WRITING ROW MUST PASS, AND THE ROOT A RUNNER GIVES IT (factory-small-items, 25/11).
--
-- MEASURED in the orchestrator's row runner (row 20261125T223107Z-6213): scripts/test-deploy-release-honest.lua
-- refused to run there - "this test writes a ledger: it refuses to run (the test home <root>/home is not under the
-- scratch root <root>/tmp)" - because scripts/lib/test-home-guard.lua knew only GATE_ROOT and TMPDIR as scratch
-- roots, while the row contract gives HOME=<root>/home and TMPDIR=<root>/tmp. Nothing was wrong with the home; the
-- guard could not recognise it, so a whole row could not run in the runner that runs every row.
--
-- The rule stays an ALLOW-LIST and this row holds both halves of it:
--   * a home under the caller's scratch root, under the row contract's root (WA_ROW_SCRATCH_ROOT), or both: allowed;
--   * a home under NEITHER (a real home, a sibling path): refused, and the reason names every root it tried;
--   * a home that carries the live node's own markers: refused, wherever it sits.
-- It is a pure function of the strings it is handed (the probes are injected), so nothing here touches a ledger.
--
--   WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-home-guard.lua wa --db <that home>/t.db
local guard = dofile("scripts/lib/test-home-guard.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end
local function says(reason, needle, label)
  checks = checks + 1
  if type(reason) ~= "string" or not reason:find(needle, 1, true) then
    error(label .. ": expected " .. needle .. " in " .. tostring(reason), 2)
  end
end
local none = function() return false end

-- 1. THE SUITE'S OWN ROOT (GATE_ROOT, else TMPDIR) still admits its home.
ok(guard.reason({ home = "/w/gate/home", scratch = "/w/gate", exists = none, root = false }) == nil,
  "a home under the suite's scratch root is allowed")

-- 2. THE ROW CONTRACT'S ROOT (WA_ROW_SCRATCH_ROOT) admits a SIBLING home, which is the runner's shape.
ok(guard.reason({ home = "/w/row/home", scratch = "/w/row/tmp", root = "/w/row", exists = none }) == nil,
  "a home under the row contract's root is allowed even when the scratch root handed in is its tmp/ sibling")

-- 3. NEITHER ROOT: refused, and the reason names both it tried.
local refused = guard.reason({ home = "/home/victor", scratch = "/w/row/tmp", root = "/w/row", exists = none })
says(refused, "is not under the scratch root /w/row/tmp or /w/row", "a real home is refused, naming both roots")

-- 4. NO ROOT AT ALL: refused by name, never waved through.
local blind = guard.reason({ home = "/w/row/home", scratch = "", root = false, exists = none })
says(blind, "no scratch root", "a guard with no root at all refuses")

-- 5. THE LIVE NODE'S MARKERS refuse a home that sits INSIDE an allowed root - the allow-list alone would pass it.
-- The marker names come from the module's own list, so this row cannot spell one the guard does not use.
local ledger_marker = guard.MARKERS[2]
local key_marker = guard.MARKERS[1]
local marker = guard.reason({ home = "/w/row/.wasm-agent", scratch = "", root = "/w/row",
  exists = function(p) return p == "/w/row/.wasm-agent/.wasm-agent/" .. ledger_marker end })
says(marker, "carries a live node's own " .. ledger_marker, "the live ledger marker still refuses an allowed-looking home")
local keyed = guard.reason({ home = "/w/row/home", scratch = "/w/row", root = false,
  exists = function(p) return p == "/w/row/home/.wasm-agent/" .. key_marker end })
says(keyed, "carries a live node's own " .. key_marker, "and so does the node's key marker")

-- 6. THE LIBRARY READS NOTHING FROM THE ENVIRONMENT (Fable 27/11, read of b07050aa): the contract root is the
-- CALLER's to pass, never a variable this library goes looking for. A home under the runner's own contract root is
-- therefore REFUSED when the caller names no root - which is what "no env override in product code, ever" means in a
-- library the product's rows share.
ok(guard.reason({ home = "/w/row/home", scratch = "/w/row/tmp", root = "/w/row", exists = none }) == nil,
  "a caller-supplied root is used as given")
local contract_root = ""
if type(host) == "table" and type(host.getenv) == "function" then
  contract_root = host.getenv("WA_ROW_SCRATCH_ROOT") or ""
end
if contract_root ~= "" then
  local here = host.getenv("WASM_AGENT_HOME") or ""
  if here ~= "" and here:sub(1, #contract_root) == contract_root then
    local why = guard.reason({ home = here, scratch = "/nonexistent-scratch", exists = none })
    ok(why ~= nil, "a home under WA_ROW_SCRATCH_ROOT is REFUSED when the caller names no root (this library does not "
      .. "read the environment): got " .. tostring(why))
    local named = guard.reason({ home = here, scratch = "/nonexistent-scratch", root = contract_root, exists = none })
    ok(named == nil, "and it is admitted once the CALLER passes that root (got " .. tostring(named) .. ")")
  else
    ok(true, "this run's home is not under WA_ROW_SCRATCH_ROOT, so that half cannot be exercised here")
    ok(true, "and neither can the caller-named half")
  end
else
  ok(true, "no WA_ROW_SCRATCH_ROOT in this environment, so that half is not exercised here")
  ok(true, "and neither is the caller-named one")
end

print("home guard ok (" .. checks .. " checks): a ledger-writing row is admitted by its own run's root, and a real home is still refused")
