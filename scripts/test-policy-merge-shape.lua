-- The deploy's policy step on a master node whose file names no components (10/11).
--
-- Measured on wasm_the_first: every deploy logged
--   `policy: the rule merge could not run for .../policy.json (policy-merge: ours: components is not an object)`
--   -> `policy: kept policy.json`
-- because that node's file is the 98-byte bootstrap shape
--   `{"components":[],"features":{...},"sensitive_capabilities":[],"version":3}`.
-- The merge refused the whole file over the empty LIST, so no shipped rule ever arrived and the deploy
-- then listed every installed component as having `no rule in policy.json` - their sensitive capabilities
-- refused with no_policy. A grant loss with a green deploy.
--
-- This runs the step a deploy runs (`install-default-policy.sh`'s `install_default_policy`), on a fixture
-- that is a master node, and pins the three properties that matter:
--   1. the empty-list shape merges instead of being kept (the shipped rules arrive);
--   2. the node's own settings survive: version, features, sensitive_capabilities byte-equal by value;
--   3. the node's ROLE is untouched - `node.role` and `binding.json` are the files the runtime reads for
--      it (`lua/core/nodes.lua` role(), `lua/core/enrollment.lua` role()), and the step writes neither.
--
-- Hermetic: a temp directory per run, the tree's own `policies/default.json`, no deploy, no network.
local json = dofile('lua/vendor/json.lua')
local root = assert(host.getenv('WASM_AGENT_LUA_ROOT'), 'run with a Lua root (the fast path sets one)')
local node = host.getenv('WA_NODE') or 'node'
local checks = 0
local function check(value, label) assert(value, 'POLICY MERGE: ' .. label); checks = checks + 1 end
local function eq(got, want, label)
  assert(got == want, 'POLICY MERGE: ' .. (label or '') .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
  checks = checks + 1
end
local function decode(text) local ok, value = pcall(json.decode, tostring(text or '')); return ok and value or nil end
local function write(path, text)
  assert(host.write_file(path, text), 'could not write ' .. path)
end
local function read(path) return host.read_file(path) end
local function exec(command) return decode(host.exec(command, '')) end

local home = dofile('lua/core/paths.lua').temp() .. '/wa-policy-merge-test-' .. tostring(os.time()) .. '-' .. tostring(math.random(100000, 999999))
local state = home .. '/state'
local ok_mkdir = exec('mkdir -p ' .. '"' .. state:gsub('\\', '/'):gsub('^//%?/', '') .. '"')
check(ok_mkdir and ok_mkdir.code == 0, 'scratch directory')

-- A master node as the runtime sees it: the role files, and the bootstrap policy file plus the base the
-- install recorded (so the merge has a real three-way base and cannot fall back to additions-only).
local role = 'master\n'
local binding = '{"role":"master","operator":"operator-key-prefix"}\n'
local ours = {
  version = 3,
  components = {},                       -- written below as the empty LIST an install produced
  features = { hooks = true, memory = false, gateway = true },
  sensitive_capabilities = {},
}
local base = {
  version = 1,
  components = { ['wa-whatsapp'] = { capabilities = { ['kv.write'] = { allow = { 'ix/*' } } } } },
  features = { hooks = true },
  sensitive_capabilities = {},
}
local function seed()
  write(state .. '/node.role', role)
  write(state .. '/binding.json', binding)
  -- The exact shape measured on wasm_the_first: components is an ARRAY, the rest are objects.
  write(state .. '/policy.json', '{"components":[],"features":{"hooks":true,"memory":false,"gateway":true},"sensitive_capabilities":[],"version":3}\n')
  write(state .. '/policy.base.json', json.encode(base))
  write(state .. '/policy.base.sha256', string.rep('a', 64) .. '  policy.base.json\n')
end
seed()

local function step()
  local command = 'bash -c ' .. string.format('%q', 'source "' .. root .. '/scripts/lib/install-default-policy.sh"; install_default_policy "'
    .. root .. '/policies/default.json" "' .. state .. '/policy.json"')
  return exec(command)
end

local first = step()
check(first ~= nil, 'the deploy policy step ran')
local log = tostring(first.stdout or '') .. tostring(first.stderr or '')
check(not log:find('could not run', 1, true), 'the merge ran (it did not report "could not run"): ' .. log)
eq(first.code, 0, 'the step exited 0 (kept or merged is a deploy that continues)')

local merged = decode(read(state .. '/policy.json'))
check(merged ~= nil, 'the merged policy parses')
check(type(merged.components) == 'table' and json.encode(merged.components):sub(1, 1) == '{', 'components is an OBJECT after the merge')
local names, rules = 0, 0
for _, entry in pairs(merged.components) do
  names = names + 1
  for _ in pairs(entry.capabilities or {}) do rules = rules + 1 end
end
check(names >= 1, 'the shipped components arrived (' .. names .. ' named)')
check(rules >= 1, 'and their rules arrived (' .. rules .. ' rule(s))')

-- 2. The node's own settings survive by value, whatever the merge did to components.
eq(merged.version, ours.version, 'the node\'s version is unchanged')
eq(json.encode(merged.features), json.encode(ours.features), 'the node\'s features are unchanged')
eq(json.encode(merged.sensitive_capabilities), json.encode(ours.sensitive_capabilities), 'the node\'s sensitive_capabilities are unchanged')

-- 3. The role the runtime reads is exactly where it was, byte for byte.
eq(read(state .. '/node.role'), role, 'node.role is untouched (this is nodes.role(), the master decision)')
eq(read(state .. '/binding.json'), binding, 'binding.json is untouched (this is enrollment.role())')
check(log:find('bootstrap', 1, true) ~= nil or (read(state .. '/policy.merge.txt') or ''):find('bootstrap', 1, true) ~= nil,
  'the log names the bootstrap shape it merged, instead of leaving it unexplained')

-- A second deploy on the merged file changes nothing: the rules are already there.
local merged_before = read(state .. '/policy.json')
local second = step()
eq(second.code, 0, 'a second run of the step exits 0')
eq(read(state .. '/policy.json'), merged_before, 'and leaves the merged file exactly as it was')

-- A components LIST that is not empty is still not a policy: the tool refuses it rather than guessing.
local odd = home .. '/odd'
write(odd .. '/policy.json', '{"components":[{"name":"x"}],"version":1}\n')
local refused = exec(string.format('%s "%s/scripts/lib/policy-merge.mjs" --additions-only --ours "%s/policy.json" --theirs "%s/policies/default.json"',
  node, root, odd, root))
check(refused ~= nil and refused.code ~= 0, 'a non-empty components list is still refused')
check(tostring(refused.stderr or ''):find('components', 1, true) ~= nil, 'and the refusal names the field')

exec('rm -rf "' .. home .. '"')
print('test-policy-merge-shape: ' .. checks .. ' checks passed')
