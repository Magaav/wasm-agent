-- /keybindings: every special key the console handles, in the surfaces it handles them in.
--
-- ONE SOURCE OF TRUTH, and it is not this file. The rows come from host.keybindings(), which answers
-- from rust/wa-term/src/keymap.rs - the table the draft's editor, the slash menu, the transcript's
-- blocks, a panel, the pointer routing and the reader thread all dispatch on. Its fullscreen rows are
-- generated from the settings that console obeys (WA_TUI_KEYS), not copied. This module only lays the
-- rows out; it does not name a single key, so it cannot list one the console does not obey or miss one
-- it does. The two directions are asserted in Rust: every act has a row where the console reads its
-- keys (keymap), and every row is dispatched by the surface that owns it.
--
-- Why a command at all. A binding is the one part of this program nobody can find by reading: it is in
-- whatever match the key lands in, and Ctrl+X meaning redo (by design, operator 18/11) is exactly the
-- kind of fact a reader needs before pressing it. So the list is asked for, not remembered.
local json = dofile("lua/vendor/json.lua")
local balloon = dofile("lua/core/balloon.lua")

local M = {}

-- Where a key's description starts. Wide enough for "a letter the page names", so the list reads as a
-- column; a longer key pushes its sentence right rather than running into it.
M.COLUMN = 30
-- The width a row may occupy. The balloon is 80 columns wide and draws a border inside that, so a row
-- longer than this is CUT at the screen's edge - which is why a long sentence is wrapped here, under
-- its own column, instead of being laid out long and lost.
M.WIDTH = 78
-- Rows a page of the balloon shows: the CLI's own page size for a table (the same as /help's).
M.PER_PAGE = 14

-- Whether this binary can answer at all. False is an ordinary condition - an older build, a test
-- harness without a host - and every caller says so rather than printing an empty list, which would
-- read as "this console handles no keys".
function M.available()
  return type(host) == "table" and type(host.keybindings) == "function"
end

-- The rows, as the capability answers them: {surface, title, group, key, does}, in the table's order.
-- Returns the rows, or nil and the reason.
function M.rows()
  if not M.available() then return nil, "this build has no host.keybindings - it predates /keybindings" end
  local ok, answer = pcall(host.keybindings)
  if not ok or type(answer) ~= "string" then return nil, "host.keybindings answered nothing readable" end
  local decoded_ok, rows = pcall(json.decode, answer)
  if not decoded_ok or type(rows) ~= "table" then return nil, "host.keybindings answered something that is not a list of rows" end
  return rows
end

-- The rows as the lines a reader sees: the surface, then its groups, then one line per key.
function M.lines(rows)
  local out, surface, group = {}, nil, nil
  for _, row in ipairs(rows or {}) do
    local where = tostring(row.surface or "")
    if where ~= surface then
      surface, group = where, nil
      if #out > 0 then out[#out + 1] = "" end
      out[#out + 1] = tostring(row.title or where)
    end
    if tostring(row.group or "") ~= group then
      group = tostring(row.group or "")
      out[#out + 1] = "  " .. group
    end
    local key = tostring(row.key or "")
    if key == "" then key = "(unbound)" end
    local label = "    " .. key
    if #label < M.COLUMN then label = label .. string.rep(" ", M.COLUMN - #label) else label = label .. " " end
    -- The sentence, wrapped under its column: a key's meaning is the whole point of the list, and a
    -- row cut at the screen's edge ("...is run here as a ba…") is not a meaning.
    local body = balloon.wrap(tostring(row.does or ""), math.max(20, M.WIDTH - #label))
    out[#out + 1] = label .. (body[1] or "")
    for index = 2, #body do out[#out + 1] = string.rep(" ", M.COLUMN) .. body[index] end
  end
  return out
end

-- The whole list as one string, for a caller that prints it (the window's read route).
function M.text(rows)
  return table.concat(M.lines(rows or {}), "\n")
end

-- The same lines as pages to move through: the balloon a CLI command draws in. A long sentence
-- WRAPS rather than being cut at the screen's edge: a key's meaning is the whole point of the list,
-- and "send the draft; a !cmd line is run here as a ba…" is not a meaning. The key column stays a
-- column because every row starts with it; a wrapped sentence continues under its own text.
function M.view(rows)
  return balloon.paged("Keys", M.lines(rows or {}), { per = M.PER_PAGE, nowrap = true })
end

return M
