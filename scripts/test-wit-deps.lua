-- The fast row for scripts/gen-wit-deps.lua: every WIT package a component vendors is the one
-- canonical file's text, and nothing is vendored that the manifest does not name.
--
-- WHY (22/11). Measured on main 44479b7f: TEN `kernel.wit` files in SEVEN different contents (161, 181,
-- 206, 321, 390, 82 and 45 lines), seven `clocks.wit` in two, `bus.wit` and `queue.wit` in one each.
-- Nothing copied them from one place - each component vendored the interface as it stood the day it was
-- built - so the tree could not answer "does a component compile against the contract the host serves?"
-- for any of its ten copies, and a hand edit could turn one of them into a copy that drops a function
-- (a component built against one contract, refused at run time by another) with every row still green.
--
-- WHAT THIS JUDGES, in the order the risk sits:
--   1. every copy the manifest names exists and is EXACTLY what the generator would write - named with
--      its line, so a stale one is a place to look, not a search;
--   2. every `.wit` under a `deps/` directory in this tree is either a canonical file or a declared
--      copy. This is the one that catches the NEXT vendored copy: it is an allow-list, so a file that
--      appears by hand fails by name instead of being judged by nobody;
--   3. the generator's own `--check` is green, run the way scripts/regenerate.sh runs it, so the CLI a
--      landing depends on is exercised and not only the module;
--   4. the comparison itself can FAIL: one character edited in a declaration is reported with its line.
--      A row that cannot fail catches nothing.
--
-- IT WRITES NOTHING and touches no state: it reads tracked files and the generator's plan. It needs no
-- WASM_AGENT_HOME for that reason, and it would refuse a scratch home if it did (rule: a test that
-- writes state makes its own).
--
-- WIRED: scripts/lib/fast-rows.sh, wa_fast_core_rows - a NEVER-DROPPED row, because it is a whole-tree
-- row: the set it judges is the manifest, not one path, so path-based narrowing cannot select it when a
-- copy is added elsewhere. The same outputs are declared in scripts/generators.txt, which is what makes
-- `bash scripts/regenerate.sh` put the canonical text back.

local checks = 0
local function check(value, why)
  assert(value, why)
  checks = checks + 1
end

local function read(path)
  local handle = io.open(path, 'rb')
  if not handle then return nil end
  local text = handle:read('a')
  handle:close()
  return text
end

-- THE PATHS, spelled out here even though the manifest is the same list, because
-- scripts/test-fast-rows.sh pairs every output scripts/generators.txt declares with the rows that NAME it
-- (a `grep -lF` over scripts/test-*.lua): a row that reached them through the manifest alone would be
-- invisible to that pairing, and the 18 copies no other row mentions would then have no check row at all.
-- Check 1 below asserts this list IS the manifest's outputs, so naming them here cannot rot into a lie.
local DECLARED = {
  'rust/components/wa-email/wit/deps/kernel.wit',
  'rust/components/wa-whatsapp/wit/deps/kernel.wit',
  'rust/components/svc-drain/wit/deps/kernel.wit',
  'rust/components/model-gateway/wit/deps/kernel.wit',
  'rust/components/svc-queue-echo/wit/deps/kernel.wit',
  'rust/components/telemetry-sink/wit/deps/kernel.wit',
  'wit/memory/deps/kernel/kernel.wit',
  'wit/selfloop/deps/kernel/kernel.wit',
  'rust/components/wa-email/wit/deps/clocks.wit',
  'rust/components/wa-whatsapp/wit/deps/clocks.wit',
  'rust/components/model-gateway/wit/deps/clocks.wit',
  'rust/components/svc-drain/wit/deps/clocks.wit',
  'rust/components/svc-queue-echo/wit/deps/clocks.wit',
  'rust/components/telemetry-sink/wit/deps/clocks.wit',
  'rust/components/model-gateway/wit/deps/cli.wit',
  'rust/components/model-gateway/wit/deps/filesystem.wit',
  'rust/components/model-gateway/wit/deps/random.wit',
  'rust/components/model-gateway/wit/deps/sockets.wit',
  'rust/components/wa-email/wit/deps/cli.wit',
  'rust/components/wa-email/wit/deps/filesystem.wit',
  'rust/components/wa-email/wit/deps/random.wit',
  'rust/components/wa-email/wit/deps/sockets.wit',
  'rust/components/wa-whatsapp/wit/deps/cli.wit',
  'rust/components/wa-whatsapp/wit/deps/filesystem.wit',
  'rust/components/wa-whatsapp/wit/deps/random.wit',
  'rust/components/wa-whatsapp/wit/deps/sockets.wit',
  'rust/components/telemetry-sink/wit/deps/telemetry.wit',
  'rust/components/svc-queue-echo/wit/deps/bus.wit',
  'rust/components/telemetry-sink/wit/deps/bus.wit',
  'rust/components/wa-email/wit/deps/bus/bus.wit',
  'rust/components/svc-drain/wit/deps/queue/queue.wit',
  'rust/components/svc-queue-echo/wit/deps/queue/queue.wit',
  'rust/components/wa-email/wit/deps/queue/queue.wit',
  'rust/components/wa-whatsapp/wit/deps/queue/queue.wit',
}

-- ---- 0. the generator this row judges -------------------------------------------------------------

local loaded, generator = pcall(dofile, 'scripts/gen-wit-deps.lua')
check(loaded, 'scripts/gen-wit-deps.lua must load: ' .. tostring(generator))
check(type(generator) == 'table' and type(generator.plan) == 'function',
  'scripts/gen-wit-deps.lua must return the manifest module this row judges')

local planned, plan = pcall(generator.plan)
check(planned, 'the manifest must render: ' .. tostring(plan))
check(#plan > 0, 'the manifest names no copy at all')

-- ---- 1. the list above is the manifest's -------------------------------------------------------------

local function set_of(list)
  local set = {}
  for _, value in ipairs(list) do set[value] = true end
  return set
end

local named, written = set_of(DECLARED), set_of(generator.outputs())
local unnamed, invented = {}, {}
for _, path in ipairs(generator.outputs()) do
  if not named[path] then unnamed[#unnamed + 1] = path end
end
for _, path in ipairs(DECLARED) do
  if not written[path] then invented[#invented + 1] = path end
end
check(#unnamed == 0, 'this row does not name an output the generator writes, so the never-dropped pairing '
  .. 'in scripts/test-fast-rows.sh cannot see it:\n  ' .. table.concat(unnamed, '\n  '))
check(#invented == 0, 'this row names a path the generator does not write:\n  '
  .. table.concat(invented, '\n  '))

-- ---- 1. every copy is exactly what the generator writes -------------------------------------------

local stale, missing = {}, {}
for _, entry in ipairs(plan) do
  local actual = read(entry.out)
  if not actual then
    missing[#missing + 1] = string.format('%s is named by scripts/gen-wit-deps.lua and is not on disk',
      entry.out)
  else
    local diff = generator.difference(entry.text, actual)
    if diff then
      stale[#stale + 1] = string.format(
        '%s is not what its canonical file says: line %d should be %s and is %s',
        entry.out, diff.line, generator.show(diff.expected), generator.show(diff.actual))
    end
  end
end
check(#missing == 0, 'a copy the manifest names is gone:\n  ' .. table.concat(missing, '\n  '))
check(#stale == 0, string.format('%d of %d vendored WIT copies differ from their canonical text - run '
  .. 'bash scripts/regenerate.sh (or `lua5.4 scripts/gen-wit-deps.lua --write`):\n  %s', #stale, #plan,
  table.concat(stale, '\n  ')))

-- ---- 2. nothing is vendored that the manifest does not name ----------------------------------------

local function enumeration(command)
  local handle = io.popen(command .. ' 2>/dev/null')
  if not handle then return nil end
  local out = handle:read('a')
  local ok = handle:close()
  if ok ~= true then return nil end
  local paths = {}
  for path in (out or ''):gmatch('[^\n]+') do paths[#paths + 1] = path end
  return paths
end

local vendored = enumeration('find rust/components wit -name "*.wit" -path "*/deps/*"')
check(vendored ~= nil, 'the deps enumeration did not run: without it this row cannot say whether an '
  .. 'undeclared copy exists, and an unknown answer is not a pass')
check(#vendored > 0, 'the deps enumeration found no vendored WIT file at all, so it is looking in the '
  .. 'wrong place')

local declared = {}
for _, out in ipairs(generator.outputs()) do declared[out] = true end
for _, source in ipairs(generator.sources()) do declared[source] = true end
-- The package-local files: under a deps/ directory, but nobody's copy. The manifest names each with the
-- reason it is not one, so this allow-list cannot widen by staying silent about a file it does not know.
for _, path in ipairs(generator.package_local_paths()) do declared[path] = true end

local undeclared = {}
for _, path in ipairs(vendored) do
  if not declared[path] then undeclared[#undeclared + 1] = path end
end
-- Every declared path is really there: a manifest that lists a file the tree does not have would make
-- the allow-list above pass over nothing at all.
local absent = {}
for path in pairs(declared) do
  if not read(path) then absent[#absent + 1] = path end
end
table.sort(absent)
check(#absent == 0, 'the manifest names files this tree does not have:\n  ' .. table.concat(absent, '\n  '))

check(#undeclared == 0, 'a WIT file is vendored that no generator owns - add it to the manifest in '
  .. 'scripts/gen-wit-deps.lua with what it keeps, or delete it:\n  ' .. table.concat(undeclared, '\n  '))

-- ---- 3. the CLI a landing runs -------------------------------------------------------------------

local cli = io.popen('lua5.4 scripts/gen-wit-deps.lua --check 2>&1')
local cli_out = cli and cli:read('a') or ''
local cli_ok = cli and cli:close()
check(cli_ok == true, 'lua5.4 scripts/gen-wit-deps.lua --check is not green, and scripts/regenerate.sh '
  .. 'runs exactly that: ' .. tostring(cli_out))

-- ---- 4. the comparison can fail ------------------------------------------------------------------

local first = plan[1]
local tampered, edits = first.text:gsub('func', 'funk', 1)
check(edits == 1, 'the first copy declares a `func` for the mutation check: ' .. first.out)
local diff = generator.difference(first.text, tampered)
check(diff ~= nil, 'a one-word edit in a declaration must be seen: ' .. first.out)
check(diff.line >= 1 and tostring(diff.actual):find('funk', 1, true) ~= nil,
  string.format('the reported line must carry the edited text (line %d: %s)', diff.line or -1,
    tostring(diff.actual)))

print(string.format('wit deps: %d checks passed - %d vendored copies from %d canonical files', checks,
  #plan, #generator.sources()))
