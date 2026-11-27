-- A change under a component's source tree, or under a crate it path-depends on, is repinned in the SAME
-- change - the rule components.lock states, which nothing used to check (mission
-- fix-components-lock-email-whatsapp).
--
-- WHY THIS ROW EXISTS. On 26/11 `33f1eeec` changed `rust/wa-queue` - linked by BOTH the wa-email and the
-- wa-whatsapp components - plus the WhatsApp index, outbox and component sources, and said in its own message
-- that the component change was not repinned. Nothing checked, so both pins described bytes from before it and
-- every publish since e6bddc6f refused `artifact_not_pinned: wa-email wa-whatsapp`.
--
-- WHY IT HASHES FILES. A first version of this row compared COMMIT TIMES and passed on that broken tree: the
-- wa-whatsapp pin line came from the other side of a merge, so it looked NEWER than its sources while
-- describing older bytes. Content cannot be fooled that way. It still cannot prove the BYTES are the pinned
-- ones - only a rebuild does that - but it proves the pin was written against the sources under it.
--
-- The digest lives in the lock as `# SOURCES <name> <sha256>`; `scripts/update-components-sources.lua` writes
-- it, and both use `scripts/lib/components_sources.lua` so the promise and the check cannot drift.
local lib = dofile('scripts/lib/components_sources.lua')

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print('FAIL ' .. label) end
end

local function read(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local text = file:read('a')
  file:close()
  return text
end

local lock = read('components.lock')
assert(lock, 'components.lock is not readable; this row judges the tree it runs in')
local pins = lib.pins(lock)
local promises = lib.promises(lock)
ok(#pins > 0, 'the lock pins at least one component (it pins ' .. #pins .. ')')

local judged, missing, wrong = 0, {}, {}
for _, pin in ipairs(pins) do
  local digest = lib.digest(pin.name)
  if digest then
    judged = judged + 1
    if not promises[pin.name] then
      missing[#missing + 1] = pin.name
    elseif promises[pin.name] ~= digest then
      wrong[#wrong + 1] = pin.name
    end
  end
end
ok(judged > 0, 'at least one pinned component has its sources in this tree (judged ' .. judged .. ')')

for _, name in ipairs(missing) do
  print('UNPINNED ' .. name .. ': pinned artifacts, but no `# SOURCES ' .. name
    .. ' <sha256>` line - the pin cannot be checked against the sources under it')
end
for _, name in ipairs(wrong) do
  print('STALE ' .. name .. ': the sources under this pin changed since its `# SOURCES` line was written - rebuild\n'
    .. '      and commit both the artifact pin and the sources line in this change\n'
    .. '      (scripts/publish-components.sh prints the pin; scripts/update-components-sources.lua writes the sources)')
end
ok(#missing == 0, #missing .. ' pinned component(s) have no sources promise; run scripts/update-components-sources.lua')
ok(#wrong == 0, #wrong .. ' pinned component(s) had their sources changed after the pin was written')

-- A promise for a component nobody pins any more is a line that can only mislead.
local pinned_names = {}
for _, pin in ipairs(pins) do pinned_names[pin.name] = true end
local orphans = {}
for name in pairs(promises) do
  if not pinned_names[name] then orphans[#orphans + 1] = name end
end
table.sort(orphans)
for _, name in ipairs(orphans) do print('ORPHAN ' .. name .. ': a `# SOURCES` line for a component the lock does not pin') end
ok(#orphans == 0, #orphans .. ' `# SOURCES` line(s) name a component the lock does not pin')

print(string.format('ok components-lock-follows-source: %d checks, %d failed', checks, failed))
if failed > 0 then error('components-lock-follows-source failed') end

