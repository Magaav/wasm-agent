-- Which directories a pinned component's bytes are built from, one line per pin: `<name>\t<dir>\t<dir>...`.
--
-- WHY A ROW OF ITS OWN. The landing has to answer one question before it merges anything: does this diff
-- touch what some component is BUILT from? Not its sources only - every crate it links, transitively
-- (`M.closure`). On 27/11 a landing published a lock line whose bytes no build of the tree produced, and
-- nothing at landing time compared "what this tree builds" with "what this tree pins", so publishing
-- stayed blocked for hours. The answer is the same closure `components_sources.lua` hashes for the
-- `# SOURCES` line, so the gate and the promise cannot disagree.
local sources = dofile('scripts/lib/components_sources.lua')

local lock = io.open('components.lock', 'rb')
if not lock then
  io.stderr:write('component-closures: components.lock is not readable from ' .. tostring(host.getenv('PWD')) .. '\n')
  os.exit(2)
end
local text = lock:read('a')
lock:close()

for _, pin in ipairs(sources.pins(text)) do
  local dirs = sources.closure(pin.name)
  if #dirs > 0 then print(pin.name .. '\t' .. table.concat(dirs, '\t')) end
end
