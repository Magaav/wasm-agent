-- Rewrite the `# SOURCES <name> <digest>` lines of components.lock from the tree as it is now.
--
-- Run this after a change under a component's sources or under a crate it path-depends on, together with the
-- artifact pin that same change must carry (`scripts/publish-components.sh` prints the lines it refuses). The
-- checker is `scripts/test-components-lock-follows-source.lua`; both share `scripts/lib/components_sources.lua`,
-- so the promise and the check cannot drift.
local lib = dofile('scripts/lib/components_sources.lua')

local function read(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local text = file:read('a')
  file:close()
  return text
end

local lock = assert(read('components.lock'), 'components.lock is not readable')
local pins = lib.pins(lock)

-- One digest per pinned component that has its sources in this tree.
local digest_of = {}
for _, pin in ipairs(pins) do
  local digest, files = lib.digest(pin.name)
  if digest then digest_of[pin.name] = digest
    print(string.format('%s: %s over %d files', pin.name, digest:sub(1, 16), #files)) end
end

-- Rebuild the whole '# SOURCES' block in one place, right after the last pin line, so the file stays readable
-- and the lines are not scattered through the comments.
local kept = {}
for line in lock:gmatch('[^\n]+') do
  if not line:match('^#%s*SOURCES%s+') then kept[#kept + 1] = line end
end
local last_pin = 0
for index, line in ipairs(kept) do
  if line:match('^%S+%s+%x%x%x%x%x%x%x%x%x%x') then last_pin = index end
end
local block = {}
for name, digest in pairs(digest_of) do block[#block + 1] = { name = name, digest = digest } end
table.sort(block, function(a, b) return a.name < b.name end)
block[#block + 1] = { name = '', digest = '' }
block[#block] = nil

local lines_out = {}
for index, line in ipairs(kept) do
  lines_out[#lines_out + 1] = line
end
-- insert after the last pin
local insert_at = last_pin
for i = #block, 1, -1 do
  table.insert(lines_out, insert_at + 1, string.format('# SOURCES %s %s', block[i].name, block[i].digest))
end

local text = table.concat(lines_out, '\n')
if not text:match('\n$') then text = text .. '\n' end
local out = assert(io.open('components.lock', 'w'), 'components.lock is not writable')
out:write(text)
out:close()
print(string.format('components.lock: %d SOURCES line(s) written', #block))

