-- THE TURN NOTE READS BOTH SHAPES (27/11, turn-note-is-lean item e).
--
-- The lean block asks the model for three short fields (tool, cost, hurt) and makes buys/focus optional. Notes ALREADY
-- WRITTEN carry the old three headings and no tool/cost, and the journal must keep reading them: old rows stay exactly
-- as they were, /turns and `wa turns --day` answer for both shapes, and the new columns default to ''. This row pins
-- the parse of both, the write of both, and the silent case (no block, no note).
--
--   WASM_AGENT_HOME=<scratch> WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-turn-note-shapes.lua wa --db <scratch>
local journal = dofile('lua/core/turn_journal.lua')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

-- 1. THE OLD SHAPE (what 1,767 notes in the last 7 days look like)
local old_block = [[<turn>
**what hurt** - the tool list was stale after a rescan
**what it buys** - fewer steps to the same result
**focus** - refresh the cache on scan
</turn>]]
local old = journal.split('an answer\n' .. old_block)
check(old.note ~= nil, 'the old block parses')
check(old.note.hurt:find('stale') ~= nil, 'old what-hurt survives: ' .. tostring(old.note.hurt))
check(old.note.buys ~= nil and old.note.buys ~= '', 'old what-it-buys survives')
check((old.note.tool or '') == '' and (old.note.cost or '') == '', 'an old note has no tool and no cost')

-- 2. THE LEAN SHAPE (the proposal): tool, cost, hurt; buys/focus absent
local lean_block = [[<turn>
- **tool** - `wa turns`
- **cost** - 3 rounds
- **hurt** - the day report lost the cluster; an operator verb would have removed it
</turn>]]
local lean = journal.split('an answer\n' .. lean_block)
check(lean.note ~= nil, 'the lean block parses')
check(lean.note.tool == '`wa turns`', 'tool is kept: ' .. tostring(lean.note.tool))
check(lean.note.cost == '3 rounds', 'cost is kept: ' .. tostring(lean.note.cost))
check(lean.note.hurt:find('lost the cluster') ~= nil, 'hurt is kept: ' .. tostring(lean.note.hurt))
check((lean.note.buys or '') == '' and (lean.note.focus or '') == '', 'buys and focus are absent, not empty placeholders')

-- 3. THE BLOCK WITH NO HEADINGS AT ALL (the one-line answer)
local flat = journal.split('an answer\n<turn>\nNothing hurt this turn.\n</turn>')
check(flat.note ~= nil and flat.note.hurt:find('Nothing hurt') ~= nil, 'a one-line block is read as hurt')

-- 4. SILENT BY DEFAULT: no block, no note
local silent = journal.split('an answer with no block at all')
check(silent.note == nil, 'no block means no note')
check(silent.block == nil, 'and no block text')

-- 5. BOTH SHAPES WRITE AND READ BACK, old first so the migration path is the one exercised
journal.setup()
local old_id = journal.record(old.note, {session_id = 's-old', build = 'b1', mode = 'm', block = old.block})
check(type(old_id) == 'string' and #old_id > 0, 'the old note records')
local lean_id = journal.record(lean.note, {session_id = 's-lean', build = 'b1', mode = 'm', block = lean.block})
check(type(lean_id) == 'string' and #lean_id > 0, 'the lean note records')
local rows = journal.recent({limit = 10})
local list = type(rows) == 'table' and (rows.notes or rows.rows or rows) or {}
check(#list >= 2, 'both notes read back: ' .. tostring(#list))
local saw_old, saw_lean = false, false
for _, row in ipairs(list) do
  if row.session_id == 's-old' then
    saw_old = true
    check((row.tool or '') == '' and (row.cost or '') == '', 'the old row reads back with empty tool/cost')
    check(tostring(row.hurts or ''):find('stale') ~= nil, 'and its hurt is intact')
  elseif row.session_id == 's-lean' then
    saw_lean = true
    check(tostring(row.tool or '') == '`wa turns`', 'the lean row keeps its tool: ' .. tostring(row.tool))
    check(tostring(row.cost or '') == '3 rounds', 'and its cost: ' .. tostring(row.cost))
  end
end
check(saw_old and saw_lean, 'both shapes are in the journal')

-- 6. NOT TWICE IN ONE SESSION FOR THE SAME CAUSE (item c)
local first_id, first_why = journal.record(lean.note, {session_id = 's-dup', build = 'b1', mode = 'm', block = lean.block})
check(type(first_id) == 'string', 'the first note records: ' .. tostring(first_why))
local again_id, again_why = journal.record(lean.note, {session_id = 's-dup', build = 'b1', mode = 'm', block = lean.block})
check(again_id == nil, 'the same cause in the same session is not journalled twice')
check(again_why == 'turn_note_duplicate', 'and the refusal is named: ' .. tostring(again_why))
local other = {tool = lean.note.tool, cost = '1 round', hurt = 'a different wall altogether'}
local other_id = journal.record(other, {session_id = 's-dup', build = 'b1', mode = 'm', block = lean.block})
check(type(other_id) == 'string', 'a DIFFERENT cause in the same session still records')
local elsewhere = journal.record(lean.note, {session_id = 's-other', build = 'b1', mode = 'm', block = lean.block})
check(type(elsewhere) == 'string', 'and the same cause in ANOTHER session still records')

print(string.format('turn note shapes ok (%d checks; the journal reads the old block, the lean block, and no block)', checks))

