-- The contract fake is judged against the real host: the same suite, both ways, and any difference fails.
--
--   WA_SCRIPT=scripts/test-contract-host.lua wa --db <scratch>
--
-- WHY. A stub kinder than the host turns a real failure into a green row - a node-ops stub accepted an
-- await the host refuses, and the harness-fixes-1 guard tests accepted answers the host never gives
-- (19-20/11 reviews). The fix is not a better stub per test; it is ONE fake whose answers are proved
-- against the host before any test is allowed to rely on them.
--
-- It runs INSIDE the node, so `host` here IS the real host: no second process, no build, no fleet. The
-- real side touches only the scratch home the runner gave this row.
local contract = dofile("scripts/lib/contract-host.lua")
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end

assert(type(host) == "table", "this test must run inside the node (WA_SCRIPT=... wa), where host is the real host")
local paths = host.paths() or {}
local real_home = tostring(paths.home or "")
local temp = tostring(paths.temp or "")
-- Rule 2 of the quality rules: a test that writes state refuses to run against the real home. The runner
-- gives every row its own WASM_AGENT_HOME, so a home equal to the operator's means this is not a row.
assert(real_home ~= "" and real_home ~= "/home/victor/.wasm-agent",
  "this row must run with a scratch home, never the operator's ~/.wasm-agent: got " .. real_home)
assert(temp ~= "", "this row needs a temp directory, got none")

-- --- the real host's answers ---------------------------------------------------------------------------
local real = contract.contract(host)

-- --- the fake's answers, for the same calls -------------------------------------------------------------
-- The fake lives in the SAME scratch directory the real host does, so the two are asked the same
-- question about the same path: a comparison across two different roots would compare the roots,
-- not the answers.
local root = temp
-- The one statement the contract asks about is SCRIPTED here, because the contract compares the
-- shape of an answer, and an unscripted statement is a different answer by design (the fake
-- refuses what nobody scripted; the host runs it).
local fake = contract.new({ root = root, paths = host.paths(),
  sql = { ["select 1 as one"] = { { one = 1 } } } })
local stand = contract.contract(fake)

-- --- the comparison --------------------------------------------------------------------------------------
-- Arity and answer TYPES must match exactly. That is what a caller is written against: `tonumber(host.getenv(x))`
-- broke because the capability answered one value instead of two, and a caller that trusted a comment put
-- JSON text through ipairs because the type was wrong.
for name, want in pairs(real) do
  local got = stand[name]
  if got == nil then
    ok(false, "the fake answers " .. name .. " at all")
  else
    ok(got.arity == want.arity, string.format("%s: the fake answers %d value(s), the host answers %d",
      name, got.arity, want.arity))
    ok(got.types == want.types, string.format("%s: the fake answers (%s), the host answers (%s)",
      name, got.types, want.types))
    -- The SHAPE too: a reason that loses the path it names is a different promise to a caller, and a fake
    -- that keeps only the type would pass a test the real host fails.
    ok(got.shapes == want.shapes, string.format("%s: the fake answers [%s], the host answers [%s]",
      name, tostring(got.shapes):gsub("\1", " | "), tostring(want.shapes):gsub("\1", " | ")))
  end
end
for name in pairs(stand) do
  ok(real[name] ~= nil, "the fake invents no capability the contract does not check: " .. name)
end

-- --- the cases where the fake is deliberately STRICTER than the host -----------------------------------
-- Ownership is the one difference allowed, and it is asserted here rather than compared: the fake refuses
-- a path outside the scratch root, so a test can never reach the operator's home through it.
do
  local text, why = fake.read_file("/etc/passwd")
  ok(text == nil, "the fake refuses to read outside its scratch root")
  ok(type(why) == "string" and why:find("outside_scratch_root", 1, true) ~= nil,
    "and it names the refusal: " .. tostring(why))
  ok(fake.write_file(root .. "/../escape.txt", "x") ~= true, "and refuses a dotted path that leaves the root")
end

-- --- an unknown capability is nil on both sides, so no test can lean on one nobody has -----------------
ok(host.wa_contract_no_such_capability == nil, "the real host has no such capability")
ok(fake.wa_contract_no_such_capability == nil, "and neither does the fake")

-- --- the fake really sleeps (a test about a timeout must not pass on a pretend wait) -------------------
do
  local started = os.clock()
  fake.sleep(1100)
  ok(os.clock() - started >= 1.0, "the fake really sleeps: a timeout test would pass on a pretend wait")
end

-- --- sql text, not a table (the list_dir lesson: 34 of 78 capabilities answer JSON text) ---------------
do
  local answer = fake.sql_query("select 1")
  ok(type(answer) == "string", "the fake answers SQL as JSON text, like the host")
  local decoded = json.decode(answer)
  ok(type(decoded) == "table" and decoded.error ~= nil, "and an unscripted statement is an ERROR, never empty rows")
end

if failed > 0 then print(string.format("%d of %d contract checks failed", failed, checks)); os.exit(1) end
print(string.format("host contract: %d checks ok, %d capabilities compared", checks, (function()
  local n = 0; for _ in pairs(real) do n = n + 1 end; return n end)()))
