-- Markdown for a terminal, in pi's palette.
--
-- Why this exists. `wa chat` printed the model's answer as raw text: a heading arrived as
-- `# Heading`, a bullet as `- item`, a fence as three backticks and a wall of uncoloured
-- lines. pi renders the same answer as *structure* - a heading in its own colour, a bullet
-- with a coloured mark, code in a bordered block with syntax colours - so a reader with
-- both open reads this one as broken rather than as plain.
--
-- Two properties decide the shape of this file:
--
--   * Width is measured on the **plain** text, never on the painted text. An escape
--     sequence is not a column, so a line painted before it is wrapped wraps early by the
--     length of its own colour codes. So this module builds lines out of segments, wraps
--     the segments, and paints last.
--   * `paint` is passed in, not required. The caller (`cli_view`) owns whether colour is
--     emitted at all, so a captured transcript comes out of here with no escape sequences
--     in it - the same text, minus the colour.
--
-- Nothing is ever dropped. An input this parser does not understand is a paragraph, so the
-- worst case is the plain rendering it replaced; `scripts/test-markdown.lua` asserts that
-- the visible text of a nasty reply survives the round trip.
--
-- What is deliberately not here, because a wrong rendering is worse than a plain one:
-- tables, images, footnotes, nested-list re-indentation, and multi-line strings inside a
-- fence (the highlighter keeps no state between lines, so a `[[` string spanning lines is
-- coloured to the end of its first line and no further).

local M = {}

-- ---- measuring -------------------------------------------------------------------

-- Columns, not bytes: `·` is two bytes and one column, so a byte count makes a line that
-- fits look like it does not, and lets a wrap land inside a character - a rendering bug
-- rather than a cosmetic one. This is the same rule as `cli_view.columns`; the two are
-- pinned against each other in `scripts/test-markdown.lua` so they cannot drift apart.
local function columns(text)
  local count, index = 0, 1
  while index <= #text do
    local byte = text:byte(index)
    index = index + ((byte >= 240 and 4) or (byte >= 224 and 3) or (byte >= 192 and 2) or 1)
    count = count + 1
  end
  return count
end
M.columns = columns

-- Break a string into pieces of at most `width` columns, never inside a character. Only
-- reached by a word too long to fit on a line of its own (a URL, a base64 blob).
local function chop(text, width)
  local pieces, current, col = {}, {}, 0
  local index = 1
  while index <= #text do
    local byte = text:byte(index)
    local size = (byte >= 240 and 4) or (byte >= 224 and 3) or (byte >= 192 and 2) or 1
    if col >= width then
      pieces[#pieces + 1] = table.concat(current)
      current, col = {}, 0
    end
    current[#current + 1] = text:sub(index, index + size - 1)
    col = col + 1
    index = index + size
  end
  if #current > 0 then pieces[#pieces + 1] = table.concat(current) end
  return pieces
end

-- ---- inline ----------------------------------------------------------------------

-- The inline forms, in the order they win. `**` before `*` matters: `**bold**` is a bold
-- word and not two italic ones, and a scanner that tried `*` first would render it as one.
-- Lua patterns have no backreferences, so each pair is written out rather than derived.
local INLINE = {
  { pattern = "`([^`]+)`", style = "mdCode" },
  { pattern = "%*%*(.-)%*%*", style = { "bold", "text" } },
  { pattern = "__(.-)__", style = { "bold", "text" } },
  { pattern = "~~(.-)~~", style = "dim" },
  { pattern = "%*([^%*]-)%*", style = "italic" },
  { pattern = "_([^_]-)_", style = "italic" },
  { pattern = "%[([^%]]*)%]%(([^%)]*)%)", link = true },
  { pattern = "<(https?://[^>]+)>", style = "mdLinkUrl" },
  { pattern = "https?://[%w%._%-/~%?%%&=:#%+@]+", style = "mdLinkUrl" },
}

-- Text, then the styled pieces of it. Styles are role names from pi's theme, or a list of
-- them (`{ "bold", "text" }`); `cli_view.paint` applies each in turn.
local function inline(text, base)
  local out, rest = {}, tostring(text or "")
  while rest ~= "" do
    local at, found = nil, nil
    for _, form in ipairs(INLINE) do
      local start, stop, first, second = rest:find(form.pattern)
      if start and (at == nil or start < at) then
        at, found = start, { start = start, stop = stop, first = first, second = second, form = form }
      end
    end
    if not at then break end
    if at > 1 then
      out[#out + 1] = { text = rest:sub(1, at - 1), style = base }
    end
    local form = found.form
    if form.link then
      out[#out + 1] = { text = found.first, style = "mdLink" }
      if found.second and found.second ~= "" then
        out[#out + 1] = { text = " ", style = base }
        out[#out + 1] = { text = found.second, style = "mdLinkUrl" }
      end
    else
      -- A pattern with no capture (a bare url, an autolink's brackets) has no `first`:
      -- the match itself is the text. Reading only the capture dropped the whole word.
      local piece = found.first
      if piece == nil then piece = rest:sub(found.start, found.stop) end
      out[#out + 1] = { text = piece, style = form.style or base }
    end
    rest = rest:sub(found.stop + 1)
  end
  if rest ~= "" then out[#out + 1] = { text = rest, style = base } end
  return out
end
M.inline = inline

-- ---- code ------------------------------------------------------------------------

local KEYWORDS = {
  lua = { ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
    ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
    ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true },
  rust = { ["as"] = true, ["async"] = true, ["await"] = true, ["break"] = true, ["const"] = true,
    ["continue"] = true, ["crate"] = true, ["dyn"] = true, ["else"] = true, ["enum"] = true,
    ["extern"] = true, ["false"] = true, ["fn"] = true, ["for"] = true, ["if"] = true,
    ["impl"] = true, ["in"] = true, ["let"] = true, ["loop"] = true, ["match"] = true,
    ["mod"] = true, ["move"] = true, ["mut"] = true, ["pub"] = true, ["ref"] = true,
    ["return"] = true, ["self"] = true, ["static"] = true, ["struct"] = true, ["super"] = true,
    ["trait"] = true, ["true"] = true, ["type"] = true, ["unsafe"] = true, ["use"] = true,
    ["where"] = true, ["while"] = true },
  sql = { ["select"] = true, ["from"] = true, ["where"] = true, ["insert"] = true, ["into"] = true,
    ["values"] = true, ["update"] = true, ["set"] = true, ["delete"] = true, ["create"] = true,
    ["table"] = true, ["index"] = true, ["join"] = true, ["left"] = true, ["right"] = true,
    ["inner"] = true, ["on"] = true, ["group"] = true, ["by"] = true, ["order"] = true,
    ["limit"] = true, ["as"] = true, ["and"] = true, ["or"] = true, ["not"] = true,
    ["null"] = true },
}
KEYWORDS.js = { ["async"] = true, ["await"] = true, ["break"] = true, ["case"] = true,
  ["catch"] = true, ["class"] = true, ["const"] = true, ["continue"] = true, ["default"] = true,
  ["delete"] = true, ["do"] = true, ["else"] = true, ["export"] = true, ["extends"] = true,
  ["false"] = true, ["finally"] = true, ["for"] = true, ["from"] = true, ["function"] = true,
  ["if"] = true, ["import"] = true, ["in"] = true, ["instanceof"] = true, ["let"] = true,
  ["new"] = true, ["null"] = true, ["of"] = true, ["return"] = true, ["static"] = true,
  ["super"] = true, ["switch"] = true, ["this"] = true, ["throw"] = true, ["true"] = true,
  ["try"] = true, ["typeof"] = true, ["undefined"] = true, ["var"] = true, ["void"] = true,
  ["while"] = true, ["yield"] = true }
KEYWORDS.ts = KEYWORDS.js
KEYWORDS.typescript = KEYWORDS.js
KEYWORDS.javascript = KEYWORDS.js
KEYWORDS.python = { ["and"] = true, ["as"] = true, ["assert"] = true, ["async"] = true,
  ["await"] = true, ["break"] = true, ["class"] = true, ["continue"] = true, ["def"] = true,
  ["del"] = true, ["elif"] = true, ["else"] = true, ["except"] = true, ["False"] = true,
  ["finally"] = true, ["for"] = true, ["from"] = true, ["global"] = true, ["if"] = true,
  ["import"] = true, ["in"] = true, ["is"] = true, ["lambda"] = true, ["None"] = true,
  ["not"] = true, ["or"] = true, ["pass"] = true, ["raise"] = true, ["return"] = true,
  ["True"] = true, ["try"] = true, ["while"] = true, ["with"] = true, ["yield"] = true }
KEYWORDS.py = KEYWORDS.python
KEYWORDS.sh = { ["case"] = true, ["do"] = true, ["done"] = true, ["elif"] = true, ["else"] = true,
  ["esac"] = true, ["exit"] = true, ["export"] = true, ["fi"] = true, ["for"] = true,
  ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true, ["return"] = true,
  ["then"] = true, ["while"] = true }
KEYWORDS.bash = KEYWORDS.sh
KEYWORDS.json = { ["true"] = true, ["false"] = true, ["null"] = true }

-- How a comment starts, per language. `--` in Lua and SQL, `#` in a shell and Python, `//`
-- in the C family. An untagged fence gets none of these rather than a guess: colouring half
-- a line as a comment because the wrong language was assumed is worse than leaving it plain.
local COMMENT = {
  lua = "--", sql = "--", haskell = "--",
  sh = "#", bash = "#", zsh = "#", python = "#", py = "#", ruby = "#", yaml = "#", toml = "#", ini = "#",
  js = "//", javascript = "//", ts = "//", typescript = "//", rust = "//", c = "//", h = "//",
  cpp = "//", hpp = "//", go = "//", java = "//", cs = "//", swift = "//", kotlin = "//",
}

-- A small scanner, not a grammar: comments, strings, numbers, keywords, and a name
-- followed by `(` as a call. It is honest about being approximate - it is here to make a
-- fence readable, and the plain rendering is what it degrades to.
local function scan_code(line, lang, emit)
  local n = #line
  local i = 1
  local comment = COMMENT[lang]
  local keywords = KEYWORDS[lang]
  while i <= n do
    local ch = line:sub(i, i)
    local is_comment = comment and #line - i + 1 >= #comment and line:sub(i, i + #comment - 1) == comment
    if is_comment then
      emit(line:sub(i), "syntaxComment")
      return
    elseif ch == '"' or ch == "'" or ch == "`" then
      local close = line:find(ch, i + 1, true)
      local stop = close or n
      emit(line:sub(i, stop), "syntaxString")
      i = stop + 1
    elseif ch:match("%d") then
      local stop = i
      while stop < n and line:sub(stop + 1, stop + 1):match("[%w_%.]") do stop = stop + 1 end
      emit(line:sub(i, stop), "syntaxNumber")
      i = stop + 1
    elseif ch:match("[%a_]") then
      local stop = i
      while stop < n and line:sub(stop + 1, stop + 1):match("[%w_]") do stop = stop + 1 end
      local word = line:sub(i, stop)
      if line:sub(stop + 1, stop + 1) == "(" then
        emit(word, "syntaxFunction")
      elseif keywords and keywords[word] then
        emit(word, "syntaxKeyword")
      else
        emit(word, nil)
      end
      i = stop + 1
    else
      local stop = i
      while stop < n do
        local next_ch = line:sub(stop + 1, stop + 1)
        if next_ch:match("[%w_]") or next_ch == '"' or next_ch == "'" or next_ch == "`" then break end
        if comment and line:sub(stop + 1, stop + #comment) == comment then break end
        stop = stop + 1
      end
      emit(line:sub(i, stop), nil)
      i = stop + 1
    end
  end
end
M.scan_code = scan_code

-- ---- blocks ----------------------------------------------------------------------

local function split_lines(text)
  local lines = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  if lines[#lines] == "" then lines[#lines] = nil end
  return lines
end

local function is_hr(trimmed)
  if #trimmed < 3 then return false end
  return trimmed:match("^%-+$") or trimmed:match("^%*+$") or trimmed:match("^_+$")
end

local function heading_of(line)
  local hashes, rest = line:match("^(#+)%s+(.*)$")
  if not hashes then return nil end
  return #hashes, rest
end

local function list_of(line)
  local indent, mark, rest = line:match("^(%s*)([-%*%+])%s+(.*)$")
  if mark then return indent, mark, rest end
  local indent2, num, rest2 = line:match("^(%s*)(%d+[%.%)])%s+(.*)$")
  if num then return indent2, num, rest2 end
  return nil
end

local function fence_of(line)
  local indent, marks, lang = line:match("^(%s*)(```+)%s*([%w%+%-%_#%.]*)$")
  if marks then return indent, marks, lang end
  local indent2, marks2, lang2 = line:match("^(%s*)(~~~+)%s*([%w%+%-%_#%.]*)$")
  if marks2 then return indent2, marks2, lang2 end
  return nil
end

-- ---- layout ----------------------------------------------------------------------

-- Words and the spaces between them. `pending` survives a segment boundary, because the
-- space that separated `**bold**` from the word after it belongs to the *next* segment and
-- dropping it glues two words together - and a segment that *starts* with a space (every
-- segment after an inline token does) has to be read from its first word, not rejected.
local function tokens_of(segments)
  local out = {}
  local pending = false
  for _, segment in ipairs(segments) do
    local text = segment.text or ""
    local at = 1
    while at <= #text do
      local space = text:match("^%s+", at)
      if space then
        pending = true
        at = at + #space
      end
      local word = text:match("^%S+", at)
      if not word then break end
      if pending then
        out[#out + 1] = { text = " ", glue = true }
        pending = false
      end
      out[#out + 1] = { text = word, style = segment.style }
      at = at + #word
    end
  end
  return out
end

-- Greedy wrapping, and the only place a width is spent. A line that ends on a space drops
-- it: a trailing space is invisible on screen and is not free in a diff.
local function layout(tokens, width, indent)
  local room = math.max(8, width - columns(indent))
  local lines, current, col = {}, {}, 0
  local function flush()
    while #current > 0 and current[#current].glue do current[#current] = nil end
    if #current > 0 then lines[#lines + 1] = current end
    current, col = {}, 0
  end
  for _, token in ipairs(tokens) do
    if not (token.glue and #current == 0) then
      local size = columns(token.text)
      if size > room then
        -- Longer than a whole line: break it rather than overflow the terminal.
        for _, piece in ipairs(chop(token.text, room)) do
          if col + columns(piece) > room and #current > 0 then flush() end
          current[#current + 1] = { text = piece, style = token.style }
          col = col + columns(piece)
          if col >= room then flush() end
        end
      else
        if col + size > room and #current > 0 then flush() end
        current[#current + 1] = token
        col = col + size
      end
    end
  end
  flush()
  if #lines == 0 then lines[1] = {} end
  return lines
end

-- ---- the renderer -----------------------------------------------------------------

-- `opts`: paint(text, style) -> string, width (columns, default 80), indent (default "  ").
-- Returns the rendered text, one line per `\n`, with no trailing newline.
function M.render(text, opts)
  opts = opts or {}
  local paint = opts.paint or function(plain) return plain end
  local width = tonumber(opts.width) or 80
  local indent = opts.indent or "  "
  local lines = split_lines(text)
  local out = {}

  local function push(segments, prefix, prefix_style)
    local body = layout(tokens_of(segments), width, prefix)
    for index, line in ipairs(body) do
      local parts = {}
      if index == 1 and prefix ~= "" then
        parts[#parts + 1] = paint(prefix, prefix_style)
      elseif index > 1 and prefix ~= "" then
        parts[#parts + 1] = string.rep(" ", columns(prefix))
      end
      for _, token in ipairs(line) do
        parts[#parts + 1] = paint(token.text, token.style)
      end
      out[#out + 1] = table.concat(parts)
    end
  end

  local function blank()
    if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
  end

  local index = 1
  while index <= #lines do
    local line = lines[index]
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")

    local fence_indent, marks, lang = fence_of(line)
    if marks then
      -- A fenced block: a bordered card, the way pi draws one, with the language named on
      -- the border so a reader knows what they are looking at.
      local body = {}
      index = index + 1
      while index <= #lines and not lines[index]:match("^%s*" .. marks:sub(1, 1) .. "+%s*$") do
        body[#body + 1] = lines[index]
        index = index + 1
      end
      if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
      local label = lang ~= "" and (" " .. lang) or ""
      out[#out + 1] = paint(indent .. "\226\148\140\226\148\128" .. label, "mdCodeBlockBorder")
      local bar = paint(indent .. "\226\148\130 ", "mdCodeBlockBorder")
      for _, code_line in ipairs(body) do
        local parts = { bar }
        scan_code(code_line, lang, function(piece, style)
          if piece == "" then return end
          -- A code block's own colour is the base; a token adds its syntax colour on top.
          parts[#parts + 1] = paint(piece, style or "mdCodeBlock")
        end)
        out[#out + 1] = table.concat(parts)
      end
      out[#out + 1] = paint(indent .. "\226\148\148\226\148\128", "mdCodeBlockBorder")
      if #out > 0 then out[#out + 1] = "" end
    elseif trimmed == "" then
      blank()
    elseif is_hr(trimmed) then
      blank()
      out[#out + 1] = paint(indent .. string.rep("\226\148\128", math.max(4, math.min(width - 4, 40))), "mdHr")
      out[#out + 1] = ""
    elseif heading_of(trimmed) then
      local level, rest = heading_of(trimmed)
      blank()
      local style = level <= 2 and { "bold", "mdHeading" } or "mdHeading"
      push(inline(rest, style), indent, style)
      out[#out + 1] = ""
    elseif trimmed:match("^>") then
      -- A quote: the border in `mdQuoteBorder`, the words in `mdQuote`, gathered from the
      -- consecutive quoted lines so a wrapped quote is one block rather than a stack.
      local gathered = {}
      while index <= #lines and lines[index]:gsub("^%s+", ""):match("^>") do
        gathered[#gathered + 1] = lines[index]:gsub("^%s*>%s?", "")
        index = index + 1
      end
      blank()
      for _, quoted in ipairs(gathered) do
        push(inline(quoted, "mdQuote"), indent .. "\226\148\130 ", "mdQuoteBorder")
      end
      out[#out + 1] = ""
      index = index - 1   -- the outer loop advances by one
    elseif list_of(line) then
      local item_indent, mark, rest = list_of(line)
      -- The view's indent, then the item's own: a bullet at column zero under an indented
      -- paragraph reads as a different block rather than as part of this one.
      local prefix = indent .. item_indent .. (mark:match("^%d") and mark or "\226\128\162") .. " "
      push(inline(rest, nil), prefix, "mdListBullet")
    else
      -- A paragraph: consecutive ordinary lines joined, because a hard-wrapped source line
      -- is not a hard-wrapped screen line.
      local gathered = { trimmed }
      index = index + 1
      while index <= #lines do
        local next_line = lines[index]
        local next_trimmed = next_line:gsub("^%s+", ""):gsub("%s+$", "")
        if next_trimmed == "" or fence_of(next_line) or is_hr(next_trimmed)
          or heading_of(next_trimmed) or list_of(next_line) or next_trimmed:match("^>") then
          break
        end
        gathered[#gathered + 1] = next_trimmed
        index = index + 1
      end
      push(inline(table.concat(gathered, " "), nil), indent, nil)
      index = index - 1
    end
    index = index + 1
  end

  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n")
end

-- Plain text, wrapped to a width, with an indent. For text that is not markdown (a model's
-- reasoning) but still has to fit the terminal.
function M.wrap(text, opts)
  opts = opts or {}
  local width = tonumber(opts.width) or 80
  local indent = opts.indent or ""
  local paint = opts.paint or function(plain) return plain end
  local style = opts.style
  local out = {}
  for _, paragraph in ipairs(split_lines(text)) do
    local body = layout(tokens_of({ { text = paragraph, style = style } }), width, indent)
    for _, line in ipairs(body) do
      local parts = { indent }
      for _, token in ipairs(line) do parts[#parts + 1] = paint(token.text, token.style) end
      out[#out + 1] = table.concat(parts)
    end
  end
  return table.concat(out, "\n")
end

return M
