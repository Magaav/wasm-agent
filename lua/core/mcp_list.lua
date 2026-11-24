-- The /mcp list: two groups, one row per connector, a mark, a short name and how many tools it gives.
--
-- Victor, 24/11: "we should list wasm-agent built-in MCPs and User MCPs and simplificate just list how many
-- tools it has." What it replaces, in his words on the laptop: "Services - 9 services - 1 built-in, 8 MCP -
-- 8 connected - 42 tools callable now", then nine numbered rows of which SIX were called "WhatsApp" (the
-- built-in, the same connector on four other nodes, two "(retired)" entries), one row whose NAME was a whole
-- sentence, and a right column cut off ("built-in - ac...", "MCP - on mail...").
--
-- So this module composes ROWS and nothing else. lua/core/mcp_command.lua still owns the connectors, their
-- state, their tools and the pages that open them; nothing here reads a registry, a probe or a peer.
--
-- The rules it keeps, one per line of the brief:
--   * two groups, in this order: "wasm-agent built-in MCPs" (it runs a script this agent ships, or it is a
--     built-in service such as WhatsApp) and "User MCPs" (added on this node);
--   * one row per connector ON THIS NODE: a mark, a short name, "<n> tools" - or, when it is not healthy,
--     the state in at most two words instead of the count ("needs token", "server changed", "not
--     reachable", "disabled"). No number, no description, no transport, no "callable now";
--   * a name is a NAME: at most 32 characters, cut with an ellipsis. A description never appears in a row;
--   * the SAME connector on another node is not a row of its own: one folded row at the end, "On other
--     nodes - <n> hidden", that opens to rows named "<connector> on <node>";
--   * a retired registry entry is not a row of the two groups either: one folded row, "<n> retired", whose
--     page says why it is retired and where the working surface is.
--
-- "Built-in or added here" is NOT decided here: `mcp_command.origin_of` decides it once, for every connector
-- of this node's registry, and `entry.origin` carries the answer. This file reads that answer - it never
-- repeats the test - which is what keeps /mcp and every other reader of the same row saying the same thing.
local balloon = dofile('lua/core/balloon.lua')

local M = {}

-- A name, not a sentence. The longest connector name on the laptop was a whole paragraph, and it was the row
-- that pushed every other row's count off the screen.
M.NAME_LIMIT = 32

-- The two groups, in the order the list shows them.
M.BUILT_IN = 'wasm-agent built-in MCPs'
M.USER = 'User MCPs'

-- The mark: a check for a connector the model is offered tools from, a warning for one that is not healthy.
-- One character each, so the two columns line up on every terminal (a wide glyph would shift the name).
M.MARK_OK = '\u{2714}'
M.MARK_WARN = '!'

-- The right column of a row that is not healthy: the state in at most two words, in the words a reader uses.
-- The registry's own vocabulary ("enabled", "failing", "stale") is what `mcp_command.state_label` translates
-- first; this table is the last step, from that word to the two-word phrase a row can afford.
M.STATE_WORDS = {
  ['needs login'] = 'needs token',
  stale = 'server changed',
  failed = 'not reachable',
  offline = 'not reachable',
  disabled = 'disabled',
  superseded = 'retired',
  retired = 'retired',
}

-- "6 tools", "1 tool", "no tool". One wording for every place that counts a connector's tools.
function M.tools_phrase(count)
  count = tonumber(count) or 0
  if count == 0 then return 'no tool' end
  return string.format('%d tool%s', count, count == 1 and '' or 's')
end

-- The state in at most two words. Anything the table does not name is said AS IT IS (bounded) rather than
-- promised healthy: an unknown state is never "connected".
function M.state_word(state)
  local word = tostring(state or 'unknown')
  local mapped = M.STATE_WORDS[word]
  if mapped then return mapped end
  local words = {}
  for part in word:gmatch('%S+') do words[#words + 1] = part; if #words == 2 then break end end
  return balloon.fit(#words > 0 and table.concat(words, ' ') or 'unknown', 16)
end

-- A connector's name as a NAME: one line, and at most M.NAME_LIMIT characters.
local function short_name(entry)
  local name = tostring(entry.name or entry.id or entry.key or '?')
  name = name:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then name = tostring(entry.id or entry.key or '?') end
  return balloon.fit(name, M.NAME_LIMIT)
end

-- Which group a connector of this node belongs to, from the answer the registry already gave:
--   'built_in'  a built-in SERVICE (WhatsApp) or a connector that runs a script this agent ships,
--   'user'      added on this node,
--   nil         not a connector of this node (a peer's), or a scope nothing recognises.
local function group_of(entry)
  if entry.scope == 'built-in' then return 'built_in' end
  if entry.scope == 'local' then
    -- `origin` is `mcp_command.origin_of`'s answer, carried on the row. A local connector that does not say
    -- which it is has NOT been classified: guessing "user" would claim the operator added something we
    -- cannot show they added, so it goes to the folded row that says so.
    if entry.origin == 'built-in' then return 'built_in' end
    if entry.origin == 'custom' then return 'user' end
  end
  return nil
end

-- One row: the mark, the short name, and the count or the state - never both, so the count column is one
-- thing to read.
function M.row(entry, state)
  local healthy = state == 'enabled' or state == 'connected'
  local name = short_name(entry)
  return {
    key = entry.key, name = name,
    label = (healthy and M.MARK_OK or M.MARK_WARN) .. ' ' .. name,
    hint = healthy and M.tools_phrase(entry.tool_count) or M.state_word(state),
    healthy = healthy, state = state, entry = entry,
  }
end

-- The whole list, as groups of rows plus the folded rows under them.
--
-- `state_label` is `mcp_command.state_label` (passed in, so this file holds no second copy of the mapping
-- from a registry state to the word a reader reads), and `view` is exactly what `mcp_command.list` answers.
function M.plan(view, opts)
  opts = opts or {}
  local state_label = opts.state_label or function(entry) return entry.state or 'unknown' end
  view = view or { connectors = {} }
  local built_in, user, peers, retired, other = {}, {}, {}, {}, {}
  for _, entry in ipairs(view.connectors or {}) do
    local state = tostring(state_label(entry) or 'unknown')
    if entry.state == 'retired' or state == 'retired' then
      retired[#retired + 1] = entry
    elseif entry.scope == 'peer' then
      peers[#peers + 1] = entry
    else
      local group = group_of(entry)
      if group == 'built_in' then built_in[#built_in + 1] = entry
      elseif group == 'user' then user[#user + 1] = entry
      else other[#other + 1] = entry end
    end
  end
  local function rows_of(entries)
    local rows = {}
    for _, entry in ipairs(entries) do rows[#rows + 1] = M.row(entry, tostring(state_label(entry) or 'unknown')) end
    table.sort(rows, function(a, b)
      -- Healthy first, then by name: the reader wants what works, then what to fix.
      if a.healthy ~= b.healthy then return a.healthy end
      return a.name:lower() < b.name:lower()
    end)
    return rows
  end
  -- A peer's connector is named by the connector AND the node: "whatsapp_native on openclaw". The same
  -- connector on four nodes is four rows HERE, which is why it is one folded row in the list above.
  local function peer_rows(entries)
    local rows = {}
    for _, entry in ipairs(entries) do
      local row = M.row(entry, tostring(state_label(entry) or 'unknown'))
      local name = balloon.fit(tostring(row.name) .. ' on ' .. tostring(entry.where or '?'), M.NAME_LIMIT + 12)
      row.name, row.label = name, (row.healthy and M.MARK_OK or M.MARK_WARN) .. ' ' .. name
      rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b) return a.name:lower() < b.name:lower() end)
    return rows
  end
  local retired_rows = {}
  for _, entry in ipairs(retired) do retired_rows[#retired_rows + 1] = M.row(entry, 'retired') end
  local other_rows = {}
  for _, entry in ipairs(other) do other_rows[#other_rows + 1] = M.row(entry, tostring(state_label(entry) or 'unknown')) end
  table.sort(other_rows, function(a, b) return a.name:lower() < b.name:lower() end)
  local sections = {}
  -- The two headings are written even when their group is empty: a reader looking for "User MCPs" must
  -- find the heading and the reason it is empty, not a list that silently lacks it.
  sections[#sections + 1] = { group = 'built_in', heading = M.BUILT_IN, rows = rows_of(built_in) }
  sections[#sections + 1] = { group = 'user', heading = M.USER, rows = rows_of(user) }
  local folded = {}
  local peer_rows_list = peer_rows(peers)
  if #peer_rows_list > 0 then
    folded[#folded + 1] = {
      kind = 'peers', title = 'On other nodes',
      label = string.format('On other nodes - %d hidden', #peer_rows_list),
      lines = { string.format('%d connector%s on another node, folded here rather than repeated above.',
        #peer_rows_list, #peer_rows_list == 1 and '' or 's') },
      rows = peer_rows_list,
    }
  end
  if #retired_rows > 0 then
    folded[#folded + 1] = {
      kind = 'retired', title = 'Retired',
      -- Still listed under a fold rather than dropped: the row is a registry entry the operator may want to
      -- remove, and a reader who wonders where it went must find it. It is not one of the two groups because
      -- its tools are not offered to the model any more (`mcp_whatsapp_*` is that surface).
      label = string.format('%d retired', #retired_rows),
      lines = { 'A retired row is one whose program went: its tools are not offered any more.' },
      rows = retired_rows,
    }
  end
  if #other_rows > 0 then
    folded[#folded + 1] = {
      kind = 'other', title = 'Not classified',
      label = string.format('%d not classified', #other_rows),
      lines = { 'These say neither that this agent ships them nor that they were added here.' },
      rows = other_rows,
    }
  end
  return {
    title = 'MCP servers',
    -- The count is what the two groups list: one per connector on this node. What is folded is said on the
    -- folded row itself, so the title never has to count what it does not show.
    lines = { string.format('%d server%s', #built_in + #user, (#built_in + #user) == 1 and '' or 's') },
    sections = sections, folded = folded,
    counts = { built_in = #built_in, user = #user, peers = #peer_rows_list, retired = #retired_rows,
      other = #other, servers = #built_in + #user },
  }
end

return M
