-- The `wasm-agent-dev` skill: it loads, and what it says is true of THIS tree.
--
-- A skill is a procedure the model follows without checking it, so a skill that names a script that
-- no longer exists, or claims a Lua change needs no rebuild when the classifier says otherwise, is worse
-- than no skill: it spends the reader's steps and then fails. This test loads the skill through the same
-- `skill` tool the model calls, and then verifies two kinds of claim against the source:
--
--   * every path it tells the reader to open or run exists (files and directories, `host.path_kind`);
--   * the "no rebuild" table matches `wa_compiled_input` in `scripts/lib/node-binaries.sh`, which is the
--     one definition deploy and the release digests share - so the skill cannot drift from the code that
--     decides whether a change needs a binary.
--
-- It reads the tree only. No node, no network, no build: `scripts/fast.sh` runs it.
local json = dofile('lua/vendor/json.lua')
local skills = dofile('lua/core/skills.lua')
local tools = dofile('lua/core/tools.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()

local checks, failed = 0, 0
local function check(condition, label, detail)
  checks = checks + 1
  if condition then return true end
  failed = failed + 1
  print('FAIL ' .. label .. (detail and (' - ' .. tostring(detail)) or ''))
  return false
end

-- ---------------------------------------------------------------- it is discoverable

local NAME = 'wasm-agent-dev'
local found = skills.find(NAME)
if not check(found ~= nil, 'the skill is discovered by name (' .. NAME .. ')') then
  print('skill wasm-agent-dev: ' .. failed .. ' failed of ' .. checks .. ' checks')
  os.exit(1)
end
check(found.name == NAME, 'under its directory name')
check(type(found.description) == 'string' and #found.description > 80, 'with a description for the catalogue')
check(found.description:find('Use it before', 1, true) ~= nil,
  'and the trigger in the description, not only in the body (docs/SKILLS.md)')
check(found.description:lower():find('wasm%-agent') ~= nil, 'naming the repository it is about')

-- The body arrives through the tool the model actually calls, complete and unchanged.
local loaded = tools.dispatch(memory, 'skill', { name = NAME }, 'master')
if not check(type(loaded) == 'table' and type(loaded.content) == 'string', 'the `skill` tool loads it by name',
  type(loaded) == 'table' and loaded.error or nil) then
  print('skill wasm-agent-dev: ' .. failed .. ' failed of ' .. checks .. ' checks')
  os.exit(1)
end
local body = loaded.content
check(body:sub(1, 3) == '---', 'the loaded content keeps the frontmatter (the loader does not strip it)')
check(body:find('name: ' .. NAME, 1, true) ~= nil, 'whose name is the one it is stored under')
-- The frontmatter is folded (`>-`), so the trigger is matched by its opening words, not by a line.
check(body:find('Use it before', 1, true) ~= nil and body:find('test, build or', 1, true) ~= nil,
  'and whose trigger is in the frontmatter the catalogue shows')

-- `skills/<name>/SKILL.md`: the skill's own directory is how the tree root is found, so this test does
-- not need WASM_AGENT_LUA_ROOT to point anywhere in particular.
local dir = tostring(loaded.dir or '')
-- The hyphen in the name is a pattern quantifier, so it is escaped: an unescaped one silently matches
-- `/skills/wasmagentdev`, which is why this check exists in the test rather than in prose.
local suffix = '/skills/' .. NAME:gsub('%-', '%%-') .. '$'
check(dir:gsub('\\', '/'):match(suffix) ~= nil, 'loaded from skills/' .. NAME, dir)
local repo = dir:gsub('\\', '/'):gsub(suffix, '')
check(host.path_kind(repo .. '/lua/core/agent.lua') == 'file', 'the tree root above the skill is the checkout', repo)

-- ---------------------------------------------------------------- what it claims is true

-- The four rules the skill is built on, each of which must survive an edit of it.
for _, needle in ipairs({
  'WASM_AGENT_LUA_ROOT',                       -- the Lua root rule
  'embedded in the binary',                    -- why a test without it proves nothing
  'scripts/fast-path.exclude',                 -- what the fast path skips
  'operation start',                           -- long work is supervised
  'never compile on a weak node',              -- the Rust rule
  'Agent:',                                    -- the commit trailer
}) do
  check(body:lower():find(needle:lower(), 1, true) ~= nil, 'the skill still states: ' .. needle)
end

-- Every path it names exists. A token with a `/` in it and a known suffix is a path claim; directories
-- are checked too, because "rust/components" and "wit/kernel" are claims as well.
local paths, seen = {}, {}
for token in body:gmatch('[%w_./-]+%.[%a]+') do
  if token:find('/', 1, true) and not token:find('://', 1, true) and not seen[token] then
    local suffix = token:match('%.([%a]+)$')
    if suffix == 'lua' or suffix == 'sh' or suffix == 'md' or suffix == 'js' or suffix == 'ps1'
      or suffix == 'cmd' or suffix == 'rs' or suffix == 'toml' or suffix == 'json' then
      seen[token] = true
      paths[#paths + 1] = token
    end
  end
end
check(#paths >= 8, 'the skill names the scripts a reader has to run', #paths)
local missing = {}
for _, path in ipairs(paths) do
  local kind = host.path_kind(repo .. '/' .. path)
  if kind ~= 'file' and kind ~= 'dir' then missing[#missing + 1] = path .. ' (' .. tostring(kind) .. ')' end
end
check(#missing == 0, 'every path the skill names exists in this tree', table.concat(missing, ', '))
-- Not vacuous: the same check catches a path that is not there.
check(host.path_kind(repo .. '/scripts/test-no-such-skill-fixture.lua') == 'missing',
  'and the test would notice a path that is not there')

-- The directories it points at, which the extension scan above cannot see.
for _, path in ipairs({ 'rust/components', 'wit/kernel', 'rust/wa-host', 'rust/wa-term', 'rust/wa-capabilities',
  'skills/self-update', 'skills/git-orchestrator', 'lua/core', 'ui', 'docs' }) do
  check(host.path_kind(repo .. '/' .. path) == 'dir', 'the skill can point at ' .. path .. '/')
end

-- The "no rebuild" table against the one definition deploy and the release digests share.
local classifier = host.read_file(repo .. '/scripts/lib/node-binaries.sh') or ''
check(classifier:find('wa_compiled_input()', 1, true) ~= nil,
  'scripts/lib/node-binaries.sh still defines wa_compiled_input (the skill names it as the definition)')
local not_compiled = ''
for line in classifier:gmatch('[^\n]+') do
  if line:find('lua/*|docs/*', 1, true) then not_compiled = line break end
end
for _, root in ipairs({ 'lua/', 'docs/', 'tests/', 'ui/', 'skills/', 'scripts/' }) do
  check(not_compiled:find(root .. '*', 1, true) ~= nil,
    'the classifier agrees with the skill: ' .. root .. ' is not a compiled input', not_compiled)
end
check(classifier:find('*/*)', 1, true) ~= nil,
  'and everything else (rust/, wit/, the Cargo manifests) is compiled, which is the other half of the table')
-- The claim the skill makes about a test without a Lua root is the binary's own wording.
local main = host.read_file(repo .. '/rust/wa-host/src/main.rs') or ''
check(main:find('lua root unset: using embedded modules', 1, true) ~= nil,
  'the "a test only tested the tree with a Lua root" claim is the warning the binary prints itself')

-- The fast path it tells the reader to run really is the day-to-day check, and the gate it names as
-- release-only is the script it names.
check(host.read_file(repo .. '/scripts/fast.sh') ~= nil, 'scripts/fast.sh exists (the day-to-day check)')
check(host.read_file(repo .. '/scripts/fast.sh'):find('fast-path.exclude', 1, true) ~= nil,
  'and honours the exclusion list the skill points at')
local exclude = host.read_file(repo .. '/scripts/fast-path.exclude') or ''
check(exclude:find('test-skill-wasm-agent-dev', 1, true) == nil,
  'the test this change added is in the fast path, not excluded from it')

-- ---------------------------------------------------------------- the other half of the pair
--
-- The one-line rules this skill expands are in the frozen prefix (docs/AGENT-LOOP.md). Naming them
-- here keeps the two from drifting apart silently.
local agent = host.read_file(repo .. '/lua/core/agent.lua') or ''
check(agent:find('Long work (a build, a test suite, a migration) is supervised', 1, true) ~= nil,
  'the generic `work` section carries the long-work rule the skill expands')
local loop_doc = host.read_file(repo .. '/docs/AGENT-LOOP.md') or ''
check(loop_doc:find('skills/wasm-agent-dev/SKILL.md', 1, true) ~= nil,
  'and docs/AGENT-LOOP.md points the reader at this skill')

if failed > 0 then
  print(string.format('skill wasm-agent-dev: %d failed of %d checks', failed, checks))
  os.exit(1)
end
print(string.format('skill wasm-agent-dev ok (%d checks)', checks))
