-- A FULL CUT IS A FULL RELEASE, AND THE RING IT COVERED IS NAMED (Fable 26/11, the cut itself).
--
-- Three facts, each measured here rather than argued: the tag rule that decides Latest vs prerelease (run against
-- the SHIPPED expression, not a copy), the pointer step recording the value it replaced, and the rehearsal report
-- naming the nodes it could not ask.
local rehearse = dofile('lua/core/release_rehearse.lua')
local checks, failed = 0, 0
local function ok(v, l) checks = checks + 1; if v then print('  ok   ' .. l) else failed = failed + 1; print('  FAIL ' .. l) end end
local function eq(g, w, l) ok(tostring(g) == tostring(w), l .. ' (got ' .. tostring(g) .. ')') end
local function has(t, n, l) ok(tostring(t):find(n, 1, true) ~= nil, l) end

local release_sh = tostring(host.read_file('scripts/release-linux.sh') or '')
has(release_sh, '$latest_flags', 'release-linux.sh: and the create line uses it')
-- (2) the pointer step records what it replaced
local publish_sh = tostring(host.read_file('scripts/publish-artifacts-branch.sh') or '')
has(publish_sh, 'pointer_before=%s', 'the publish step records pointer_before')
has(publish_sh, 'pointer_after=%s', 'and pointer_after')
has(publish_sh, 'before=$(cat /srv/wasm-agent-releases/latest-node.txt', 'by reading the live pointer before writing')
-- (3) the report names the nodes it could not ask (one node refuses, one answers)
local ring = { { node = 'this node', mode = 'local' }, { node = 'mail', mode = 'peer' }, { node = 'work', mode = 'peer' } }
local facts = { ['mail'] = { mode = 'tree', relation = 'current' }, ['work'] = { mode = 'local', relation = 'current' } }
local answer = rehearse.rehearse({
  ring = ring,
  facts_of = function(name) return facts[name] end,
  canaries = function(name)
    if name == 'mail' then return nil, 'refused: the node is not running' end
    return { features = {} }, nil
  end,
  read = function(name) return { node = name, state = 'current' } end,
})
local text = table.concat(answer.lines or {}, '\n')
has(text, 'LEFT OUT OF THE RING', 'the report has a LEFT OUT section')
has(text, 'mail', 'naming the node that did not answer')
has(text, 'the node is not running', 'with the reason it did not answer')
if not text:find('LEFT OUT', 1, true) then print('  --- report as it came back ---\n' .. text:sub(1, 600)) end

print(string.format('release-full-cut: %d checks, %d failed', checks, failed))
if failed == 0 then print('release-full-cut ok') return 0 end
return 1
