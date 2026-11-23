-- `wa land <branch>`: THE COMPONENTS A ROW NAMES, handed to that row the way the fast path hands them over.
--
-- One of five parts by subject (scripts/lib/land-quick.lua says why). A row declares a component by naming
-- `WA_<NAME>_COMPONENT_WASM` in its text; the tests step hands over the artifact THIS NODE runs - module, pin
-- and manifest - because the host refuses a component with no pin. A component this node does not have is
-- NAMED as a row that did not run here and is never counted as a pass (measured 23/11).
local Q = dofile("scripts/lib/land-quick.lua")
Q.arm("test-land-quick-components.lua")
local R = Q.R
local land, repo, ok, eq, contains, must, write_file, read_file = Q.land, Q.repo, Q.ok, Q.eq, Q.contains, Q.must, Q.write_file, Q.read_file
local setup_fixture, journal_of, step_of, marker = Q.setup_fixture, Q.journal_of, Q.step_of, Q.marker
local json, state, ledger, trim = Q.json, Q.state, Q.ledger, Q.trim
local behaviour, observed, install_dir = Q.behaviour, Q.observed, Q.install_dir
local fixture, branch_with, main_grows, first_line_ish = Q.fixture, Q.branch_with, Q.main_grows, Q.first_line_ish
local running, said, rows_of = Q.running, Q.said, Q.rows_of
-- a row's own home for the string `WA_<NAME>_COMPONENT_WASM`; this step is not the fast path, so it hands over
-- the component THIS NODE runs from the node's own component directory. Measured 23/11: without it the
-- crash-recovery row read `component_not_installed:graph` and a landing stopped on a missing fixture instead of
-- on the branch's own change. The row below only passes if the override actually arrives.
local component_dir = dofile("lua/core/paths.lua").data() .. "/components"
fixture()
must("mkdir -p " .. component_dir .. " && printf '\\0asm' > " .. component_dir .. "/fake.wasm" ..
  " && printf 'pin' > " .. component_dir .. "/fake.wasm.sha256 && printf '{}' > " .. component_dir .. "/fake.json", "fake component")
branch_with("change/own-comp", {
  -- WA_FAKE_COMPONENT_WASM is the declaration; the host resolves components from WA_COMPONENTS_DIR, so the row
  -- proves the artifact itself arrived in its own home.
  -- THE WHOLE ARTIFACT MUST ARRIVE: the module, its pin and its manifest. The host refuses a component with
  -- no pin, so a row handed only the .wasm would read as a BROKEN component rather than a missing one - and a
  -- row that provisions itself finds the .wasm, stops looking, and then fails at the host (measured 23/11 in
  -- Fable's review of d61594ce: the step copied the module alone).
  ["scripts/test-own-comp.lua"] = "-- WA_FAKE_COMPONENT_WASM\nlocal dir = host.getenv('WA_COMPONENTS_DIR')\nassert(dir and dir ~= '', 'no WA_COMPONENTS_DIR was handed over')\nfor _, file in ipairs({ 'fake.wasm', 'fake.wasm.sha256', 'fake.json' }) do\n  assert(host.read_file(dir .. '/' .. file) ~= nil, 'the artifact is incomplete: ' .. file .. ' was not installed into this row home')\nend\nprint('own-component ok')\n", 
})
eq(running(function() return land.run({ run = "quick3c", landing = true, branches = { "change/own-comp" } }) end), 0,
  "a row that names a component lands when this node has that component")
contains(step_of("quick3c", "tests").detail, "1 green", "and the row really ran")
contains(read_file(land.evidence_path("quick3c", "tests")) or "", "WA_COMPONENTS_DIR=",
  "the row was handed the component directory")
contains(read_file(land.evidence_path("quick3c", "tests")) or "", "own-component ok",
  "and it found the component installed in its own home")
-- (the fake component stays: the node-state guard refuses a delete inside it, and no other case names it)

-- AND WHEN THIS NODE HAS NO SUCH COMPONENT THE ROW IS NAMED AS NOT RUN, never counted green: the component is
-- built by the fast path and judged by main-health, which is the division of labour a Rust change already has.
fixture()
-- The row names WA_MISSING_COMPONENT_WASM, and this node has no such component.
branch_with("change/own-miss", {
  ["scripts/test-own-miss.lua"] = "-- WA_MISSING_COMPONENT_WASM\nprint('never runs here')\n",
})
eq(running(function() return land.run({ run = "quick3m", landing = true, branches = { "change/own-miss" } }) end), 0,
  "a row whose component this node lacks does not stop the landing")
contains(step_of("quick3m", "tests").detail, "not run here", "the step says the row did not run")
contains(step_of("quick3m", "tests").detail, "missing", "and names the component it needs")
contains(step_of("quick3m", "tests").detail, "0 green", "it is not counted as a pass")

-- A COMPONENT WITH NO PIN IS NOT A COMPONENT: the host refuses it, so the row is NOT RUN rather than run with
-- half an artifact (Fable's review of d61594ce: the step copied only the module).
fixture()
must("printf '\\0asm' > " .. component_dir .. "/unpinned.wasm && printf '{}' > " .. component_dir ..
  "/unpinned.json", "a component with no pin")
branch_with("change/own-unpinned", {
  ["scripts/test-own-unpinned.lua"] = "-- WA_UNPINNED_COMPONENT_WASM\nprint('never runs here')\n",
})
eq(running(function() return land.run({ run = "quick3u", landing = true, branches = { "change/own-unpinned" } }) end), 0,
  "a row whose component this node has no pin for does not stop the landing")
contains(step_of("quick3u", "tests").detail, "not run here", "the step says that row did not run")
contains(step_of("quick3u", "tests").detail, "unpinned", "and names the component it needs")
contains(step_of("quick3u", "tests").detail, "0 green", "it is not counted as a pass either")


if R.count() > 0 and false then os.exit(1) end
print(string.format("landing ok (%d checks)", R.count()))
