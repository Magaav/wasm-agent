-- Refresh this repo's subscription catalogue from pi's model store - once, by hand.
--
-- `lua/core/openai_sub_catalogue.lua` is the catalogue the runtime reads, and nothing under `lua/`
-- reads `~/.pi` at request time any more. This script is the documented way to bring the checked-in
-- facts up to date when pi's store moves: it imports the route's entries and rewrites *only* the
-- block between the catalogue's own markers, then prints what it changed. The reviewed diff is the
-- point, which is why this is a script a maintainer runs and not something a run does - and why it
-- writes nothing at all when the file already matches the store.
--
--   WASM_AGENT_PI_MODELS_STORE=<store> WA_SCRIPT=scripts/import-openai-sub-catalogue.lua \
--     <repo>/rust/target/release/wa --db <scratch>.db
--
-- With no override the store is `~/.pi/agent/models-store.json`. No network, no model, no
-- credential: it reads one file and rewrites one block. Exit is non-zero when nothing was written,
-- so "imported, no change" can never be mistaken for "the store was unreadable".
local catalogue = dofile('lua/core/openai_sub_catalogue.lua')
local paths = dofile('lua/core/paths.lua')

local FILE = 'lua/core/openai_sub_catalogue.lua'
local BEGIN_MARKER = '-- BEGIN IMPORTED CATALOGUE'
local END_MARKER = '-- END IMPORTED CATALOGUE'

local store = host.getenv('WASM_AGENT_PI_MODELS_STORE')
  or (paths.home() .. '/.pi/agent/models-store.json')

local imported = catalogue.import_from_pi(store)
if not imported then
  error('catalogue_import_unreadable: could not read or parse ' .. store ..
    '; nothing was written', 0)
end
print(string.format('import: %d %s entry/entries from %s', imported.count, catalogue.api,
  imported.source))

local text = host.read_file(FILE)
if not text then error('catalogue_missing: ' .. FILE .. ' is not readable', 0) end
local begin_at, begin_end = text:find(BEGIN_MARKER, 1, true)
local end_at = text:find(END_MARKER, 1, true)
if not begin_at or not end_at or end_at < begin_end then
  error('catalogue_markers_missing: ' .. FILE .. ' must carry both markers, in order, so the ' ..
    'import knows which block it owns; nothing was written', 0)
end

-- The block the import owns, as it stands now, so the change can be named rather than only written.
local current = text:sub(begin_end, end_at)
local before = {}
for id in current:gmatch("id = '([^']+)'") do before[id] = true end
local after = {}
for _, model in ipairs(imported.models) do after[model.id] = true end
local added, dropped = {}, {}
for id in pairs(after) do if not before[id] then added[#added + 1] = id end end
for id in pairs(before) do if not after[id] then dropped[#dropped + 1] = id end end
table.sort(added); table.sort(dropped)

local updated = text:sub(1, begin_end) .. '\n' .. catalogue.render(imported.models) ..
  '\n' .. text:sub(end_at)
if updated == text then
  print('catalogue unchanged: ' .. FILE .. ' already matches the store, so nothing was written')
  return
end
print('catalogue update:'
  .. (#added > 0 and (' added ' .. table.concat(added, ', ')) or ' no ids added')
  .. (#dropped > 0 and ('; dropped ' .. table.concat(dropped, ', ')) or '; no ids dropped')
  .. ' (' .. tostring(#imported.models) .. ' entries)')
if not host.write_file(FILE, updated) then
  error('catalogue_write_failed: ' .. FILE .. ' could not be written', 0)
end
print('catalogue written: ' .. FILE .. ' - review the diff before committing it')
