-- The lines one panel of a local view may carry, kept inside the length the client accepts.
--
-- `rust/wa-cli-views/src/spec.rs` (MAX_LINE_CHARS = 400) refuses a WHOLE view whose line is longer
-- than 400 characters, and a refused view is a panel the reader never sees: `/nodes` answered every
-- run with
--   ! the run view failed: local views: /nodes was not published: line_too_long views[2].lines[3]:
--   3030 characters
-- because `M.details` joined 143 capability names on one "Tools: ..." line (Victor, 21/11).
--
-- The limit is the CLIENT's, so it is spelled here once and every builder that can produce a long
-- line wraps with it: `M.list` for a "Label: a, b, c" detail row, `M.wrap_line` for a line that has
-- no separators, and `lua/core/balloon.lua`'s `publish` runs every page's lines through `M.wrap` as
-- the last resort - a builder that forgets then costs the reader nothing, and a line over the limit
-- is a test failure (`scripts/test-local-views.lua`), never a refusal at run time.
local M = {}

-- Characters, which is what the client counts (`text.chars().count()`): not bytes and not cells. A
-- node's tool names are ASCII, but a workspace path or a title is not, and a byte count would break a
-- line that fits.
M.MAX = 400

-- The characters of a string, or its bytes when it is not valid UTF-8 - a cut may not land inside a
-- character, and a string this module cannot decode is still one a panel has to carry.
local function split(text)
  local out = {}
  if pcall(function() for _, code in utf8.codes(text) do out[#out + 1] = utf8.char(code) end end) then
    return out
  end
  out = {}
  for index = 1, #text do out[#out + 1] = text:sub(index, index) end
  return out
end

-- The length the client measures. `utf8.len` answers `nil` for a malformed string, and the byte
-- count is then the safe upper bound: a line this module thinks is shorter than it is would refuse the
-- view.
function M.count(text)
  local ok, length = pcall(utf8.len, tostring(text or ""))
  if ok and length then return length end
  return #tostring(text or "")
end

-- One line, as the lines it has to be to stay inside `opts.limit` characters.
--
-- It breaks at the separators the line already carries (", ") and drops that separator, so a wrapped
-- detail row still reads as a list of facts rather than as prose someone cut in half; every
-- continuation line carries `opts.indent` (two spaces) so the row still looks like one row. A single
-- fact longer than a whole line (a URL, a schema) has no separator to break at and is cut: a cut costs
-- the reader two characters, a refusal costs them the panel.
function M.wrap_line(text, opts)
  opts = opts or {}
  local limit = math.max(16, tonumber(opts.limit) or M.MAX)
  local indent = opts.indent or "  "
  local rest = tostring(text or ""):gsub("[\r\n]+", " ")
  local lines, lead = {}, ""
  while true do
    if M.count(rest) <= limit - M.count(lead) then
      lines[#lines + 1] = lead .. rest
      break
    end
    local list = split(rest)
    local window = table.concat(list, "", 1, math.max(1, limit - M.count(lead)))
    -- The last ", " inside the window: the place a list is allowed to break.
    local cut, at = nil, 1
    while true do
      local found = window:find(", ", at, true)
      if not found then break end
      cut, at = found, found + 1
    end
    local head, tail
    if cut and cut > 1 then
      head, tail = window:sub(1, cut - 1), rest:sub(cut + 2)
    else
      head, tail = window, rest:sub(#window + 1)
    end
    lines[#lines + 1] = lead .. head
    rest, lead = (tail:gsub("^%s+", "")), indent
    if rest == "" then break end
  end
  return lines
end

-- A detail row: `prefix` and then `items` joined with ", ", as the lines it needs. One function for
-- every "Label: a, b, c" row a page draws, so no builder has to know what the client's limit is.
function M.list(prefix, items, opts)
  local shown = {}
  for _, item in ipairs(items or {}) do shown[#shown + 1] = tostring(item) end
  return M.wrap_line(tostring(prefix or "") .. table.concat(shown, ", "), opts)
end

-- Every line of a page, wrapped: what `balloon.publish` runs before a spec crosses to the client.
function M.wrap(lines, opts)
  local out = {}
  for _, line in ipairs(lines or {}) do
    for _, part in ipairs(M.wrap_line(line, opts)) do out[#out + 1] = part end
  end
  return out
end

return M
