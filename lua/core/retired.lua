-- The retired `*_many` tools, in one place (operator's decision, 12/11: "yes many can be retired as
-- naturally code mode can queue many"). Code mode IS the batch: `Promise.all(items.map(x => tools.<single>(x)))`
-- for reads, a serial loop for effects, and the pending handles (`wait`) for work that outlives a turn.
--
-- A `*_many` tool was a second way to queue the same calls, with a second contract - schema, 1-8 bound,
-- per-item guards, presentation - kept in step with the primitive it wrapped. Retiring it removes the
-- second contract, not the capability. This module holds the ONLY copy of the mapping and the ONLY
-- sentence, so the dispatcher, `tool_call`, a peer capability, `describeTool` inside a script and the
-- gate test cannot drift from each other: one name, one refusal, no working alias.
local M = {}

-- retired name -> the single tool that replaced it
M.NAMES = {
  read_many = 'read',
  write_many = 'write',
  edit_many = 'edit',
  grep_many = 'grep',
  session_many = 'session',
  search_messages_many = 'search_messages',
  symbol_source_many = 'graph',
}

-- The refusal, exactly (docs/BATCH-TOOLS.md quotes this string; scripts/test-retire-many.lua asserts it).
function M.text(name)
  local base = M.NAMES[name]
  if not base then return nil end
  return 'retired: batch in code mode - Promise.all(items.map(x => tools.' .. base .. '(x)))'
end

function M.list()
  local names = {}
  for name in pairs(M.NAMES) do names[#names + 1] = name end
  table.sort(names)
  return names
end

return M
