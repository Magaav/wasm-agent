-- A REHEARSAL AGAINST A SCRATCH RING (26/11, release-rehearsal item 4).
--
-- The other rehearsal row injects read/ring/canaries. This one drives the DEFAULT path: the default record read
-- (remote_update.status through the mesh seam), the default canary ask (`wa features canary json` through the same
-- seam) and this node own canaries for real, against a scratch ring of three nodes. It is the wiring a fleet run
-- uses, with the mesh replaced and nothing else.
local rehearse = dofile('lua/core/release_rehearse.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 120) .. ')') end

local RING = {
  { node = 'this node', mode = 'local' },
  { node = 'scratch-a', mode = 'release' },
  { node = 'scratch-b', mode = 'release' },
}
local DOC = '{"features":[{"feature":"release-update","ok":true,"stage":"identity"},{"feature":"mail","ok":true,"stage":"answered"}]}'

local asked = {}
rehearse.remote_call = function(node, tool, args)
  asked[#asked + 1] = { node = node, tool = tool, command = type(args) == 'table' and args.command or '' }
  if type(args) == 'table' and tostring(args.command or '') == 'wa features canary json' then
    return { ok = true, stdout = DOC }
  end
  return { ok = true, state = 'installed', installed_commit = '6b6afc72f188' }
end

-- 1. the default path, over a scratch ring
local report = rehearse.rehearse({ ring = RING })
ok(#report.rows == 3, 'three nodes were read (' .. #report.rows .. ')')
local status_reads, canary_asks = 0, 0
for _, one in ipairs(asked) do
  if one.command == 'wa features canary json' then canary_asks = canary_asks + 1 else status_reads = status_reads + 1 end
end
ok(status_reads == 2, 'each peer was read once for its record, and this node was not asked over the mesh (' .. status_reads .. ')')
ok(canary_asks == 2, 'and asked once for its canaries (' .. canary_asks .. ')')
ok(report.rows[2].commit == '6b6afc72f188', 'the peer row carries the commit the node named')
ok(report.rows[2].relation == 'named', 'and says the record named it')
has(table.concat(report.lines, '\n'), 'scratch-a', 'the report names the scratch peer')
ok(report.ok == true, 'a scratch ring that answers and passes is GREEN (' .. table.concat(report.red, '; ') .. ')')

-- 2. one peer whose canaries do not arrive is RED, and the report says which
rehearse.remote_call = function(node, tool, args)
  if type(args) == 'table' and tostring(args.command or '') == 'wa features canary json' then
    if node == 'scratch-b' then return { ok = false, error = 'no_answer' } end
    return { ok = true, stdout = DOC }
  end
  return { ok = true, state = 'installed', installed_commit = '6b6afc72f188' }
end
local partial = rehearse.rehearse({ ring = RING })
ok(partial.ok == false, 'a peer that did not answer its canaries is RED')
has(table.concat(partial.red, '\n'), 'scratch-b', 'named')

-- 3. a peer whose record read is refused is RED (unknown is not yes)
rehearse.remote_call = function(node, tool, args)
  if type(args) == 'table' and tostring(args.command or '') == 'wa features canary json' then return { ok = true, stdout = DOC } end
  if node == 'scratch-a' then return { ok = false, error = 'node_no_answer' } end
  return { ok = true, state = 'installed', installed_commit = '6b6afc72f188' }
end
local refused = rehearse.rehearse({ ring = RING })
ok(refused.ok == false, 'a refused record read is RED')
has(table.concat(refused.red, '\n'), 'node_no_answer', 'with the refusal named')

-- 4. and the CLI door turns the same verdict into an exit code
rehearse.remote_call = nil
ok(type(rehearse.run) == 'function', 'M.run is the door (its exit code is covered by the rehearsal row)')

if failed > 0 then print(string.format('release rehearse ring FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('release rehearse ring ok (%d checks)', checks))
return 0
