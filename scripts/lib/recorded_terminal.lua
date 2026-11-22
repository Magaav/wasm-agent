-- A recorded terminal: the bytes a view writes go in, the screen they make comes out, and a resize
-- reflows it the way a real terminal does.
--
-- Why it exists. scripts/test-cli-resize.lua rendered each component at 80, 200 and 60 and asserted it
-- fitted - a property of DRAWING, not of a resize. The defect Victor photographed in foot is a property
-- of what the TERMINAL does to bytes a chat left behind: foot re-wraps its own scrollback when the
-- window narrows, so a rule printed at 80 becomes 60 columns plus an orphan row of 20 (the stray
-- "─" under the rule), and nothing the process does afterwards can reflow it. Only a terminal that
-- keeps what was written can tell a redraw from a stale row, so this file is that terminal, in the
-- smallest form the assertions need: a grid, a scroll region, erase and clear, and a reflow that groups
-- soft-wrapped rows back into lines and wraps them again at the new width.
--
-- What it does NOT model, named so a green run is not read as more than it is: colour (SGR is parsed
-- and dropped, so every assertion is about visible cells), the cursor's shape and visibility, tabs,
-- and a font whose wide-glyph fallback differs from the cell count this module is given.
local M = {}

local METHODS = {}
METHODS.__index = METHODS

-- opts: width, height (cells and rows), columns (a function of one character -> cells; defaults to 1).
function M.new(opts)
  opts = opts or {}
  local term = {
    width = math.max(1, math.floor(tonumber(opts.width) or 80)),
    height = math.max(1, math.floor(tonumber(opts.height) or 24)),
    columns = opts.columns or function() return 1 end,
    rows = {},
    history = {},
    cursor = 1,
    col = 1,
    saved = nil,
  }
  term.region = { top = 1, bottom = term.height }
  for index = 1, term.height do term.rows[index] = { cells = {}, soft = false } end
  return setmetatable(term, METHODS)
end

local function blank_row() return { cells = {}, soft = false } end

-- How many cells a row holds right now (its written cells, spaces included).
function METHODS:cells(index)
  local row = self.rows[index]
  if not row then return 0 end
  local count = 0
  for _, cell in ipairs(row.cells) do count = count + self.columns(cell) end
  return count
end

-- The visible rows as text, trailing blanks trimmed (a terminal shows the same picture either way).
function METHODS:screen()
  local out = {}
  for index = 1, self.height do
    local joined = table.concat(self.rows[index].cells, "")
    out[index] = (joined:gsub("%s+$", ""))
  end
  return out
end

-- Where a piece of text is on the visible screen: every row index that contains it.
function METHODS:find(text)
  local found = {}
  for index, row in ipairs(self:screen()) do
    if row:find(text, 1, true) then found[#found + 1] = index end
  end
  return found
end

function METHODS:erase_region_row(index)
  self.rows[index] = blank_row()
end

-- One line feed inside the scroll region: at its last row the region scrolls, one row of it leaves the
-- screen, and the bottom row comes back blank. Below the region the cursor simply moves.
function METHODS:linefeed()
  if self.cursor == self.region.bottom then
    table.insert(self.history, table.remove(self.rows, self.region.top))
    table.insert(self.rows, self.region.bottom, blank_row())
    if #self.history > 200 then table.remove(self.history, 1) end
    return
  end
  if self.cursor < self.height then self.cursor = self.cursor + 1 end
end

function METHODS:put(char)
  local size = self.columns(char)
  if self.col + size - 1 > self.width then
    -- The row is full: a real terminal wraps before the NEXT character lands on it.
    self.rows[self.cursor].soft = true
    self.col = 1
    self:linefeed()
  end
  local row = self.rows[self.cursor]
  while #row.cells < self.col - 1 do row.cells[#row.cells + 1] = " " end
  row.cells[self.col] = char
  -- A cell this wide takes the ones after it: a terminal cannot draw half a glyph.
  for offset = 1, size - 1 do row.cells[self.col + offset] = "" end
  self.col = self.col + size
end

function METHODS:csi(params, final)
  if params:sub(1, 1) == "?" or params:sub(1, 1) == ">" or params:sub(1, 1) == "!" then return end
  local numbers = {}
  for piece in (params .. ";"):gmatch("([^;]*);") do numbers[#numbers + 1] = tonumber(piece) end
  local function at(index, default) return numbers[index] or default end
  if final == "H" or final == "f" then
    self.cursor = math.min(self.height, math.max(1, at(1, 1)))
    self.col = math.min(self.width, math.max(1, at(2, 1)))
  elseif final == "K" then
    local mode = at(1, 0)
    local row = self.rows[self.cursor]
    if mode == 2 then
      row.cells = {}
    elseif mode == 1 then
      for index = 1, math.min(self.col, #row.cells) do row.cells[index] = "" end
    else
      for index = self.col, #row.cells do row.cells[index] = "" end
    end
  elseif final == "J" then
    local mode = at(1, 0)
    if mode == 2 then
      for index = 1, self.height do self.rows[index] = blank_row() end
    elseif mode == 3 then
      -- Erase the scrollback: the rows this terminal scrolled off are gone for good.
      self.history = {}
    elseif mode == 0 then
      for index = self.cursor, self.height do self.rows[index] = blank_row() end
    end
  elseif final == "r" then
    self.region = { top = math.max(1, at(1, 1)), bottom = math.min(self.height, at(2, self.height)) }
    self.cursor, self.col = 1, 1
  elseif final == "s" then
    self.saved = { row = self.cursor, col = self.col }
  elseif final == "u" then
    if self.saved then self.cursor, self.col = self.saved.row, self.saved.col end
  elseif final == "A" then
    self.cursor = math.max(1, self.cursor - at(1, 1))
  elseif final == "B" then
    self.cursor = math.min(self.height, self.cursor + at(1, 1))
  elseif final == "C" then
    self.col = math.min(self.width, self.col + at(1, 1))
  elseif final == "D" then
    self.col = math.max(1, self.col - at(1, 1))
  elseif final == "G" then
    self.col = math.min(self.width, math.max(1, at(1, 1)))
  end
  -- "m" (colour), "h"/"l" (modes: cursor, autowrap, synchronized output) and everything else: parsed,
  -- and dropped. A colour is not a cell and a mode does not move one.
end

function METHODS:feed(text)
  text = tostring(text or "")
  local index, size = 1, #text
  while index <= size do
    local byte = text:sub(index, index)
    if byte == "\27" then
      local after = text:sub(index + 1, index + 1)
      if after == "[" then
        local start = index + 2
        local at = start
        while at <= size do
          local code = text:byte(at)
          if code >= 0x40 and code <= 0x7e then break end
          at = at + 1
        end
        self:csi(text:sub(start, at - 1), text:sub(at, at))
        index = at + 1
      elseif after == "]" then
        local bell = text:find("\7", index, true)
        index = bell and (bell + 1) or (size + 1)
      else
        index = index + 2
      end
    elseif byte == "\r" then
      self.col = 1; index = index + 1
    elseif byte == "\n" then
      self:linefeed(); index = index + 1
    elseif byte == "\b" then
      self.col = math.max(1, self.col - 1); index = index + 1
    elseif byte == "\7" or byte == "\0" then
      index = index + 1
    else
      local first = text:byte(index)
      local length = first < 0x80 and 1 or first < 0xE0 and 2 or first < 0xF0 and 3 or 4
      local char = text:sub(index, index + length - 1)
      self:put(char)
      index = index + length
    end
  end
  return self
end

-- The window changed size: the terminal wraps what it already holds again, at the new width.
--
-- This is the whole point of the file. Rows flagged soft are the terminal's own wrap, and a terminal
-- that is resized JOINS them back into the line they came from and wraps that line at the new width -
-- which is why a rule of 80 columns survives as 60 + an orphan row of 20 in a 60-column window, however
-- the process that wrote it feels about that.
function METHODS:resize(width, height)
  width = math.max(1, math.floor(tonumber(width) or self.width))
  height = math.max(1, math.floor(tonumber(height) or self.height))
  local groups, group = {}, nil
  for index = 1, self.height do
    local row = self.rows[index]
    group = group or { cells = {}, soft = false }
    if group.cells == nil then group.cells = {} end
    for _, cell in ipairs(row.cells) do group.cells[#group.cells + 1] = cell end
    group.soft = row.soft
    if not row.soft then groups[#groups + 1] = group; group = nil end
  end
  if group then
    -- The screen ends inside a wrapped line whose remainder is already off screen: what is here is all
    -- this terminal can wrap again, so it is treated as a whole line.
    group.soft = false
    groups[#groups + 1] = group
  end
  self.width, self.height = width, height
  local rows = {}
  for _, one in ipairs(groups) do
    local remaining = one.cells
    repeat
      local cells, taken = {}, 0
      while taken < width and taken < #remaining do
        cells[#cells + 1] = remaining[taken + 1]
        taken = taken + 1
      end
      for _ = 1, taken do table.remove(remaining, 1) end
      rows[#rows + 1] = { cells = cells, soft = #remaining > 0 }
    until #remaining == 0
  end
  while #rows > height do
    table.insert(self.history, table.remove(rows, 1))
    if #self.history > 200 then table.remove(self.history, 1) end
  end
  while #rows < height do rows[#rows + 1] = blank_row() end
  self.rows = rows
  self.region = { top = 1, bottom = height }
  self.saved = nil
  self.cursor = math.min(self.cursor, height)
  self.col = 1
  return self
end

return M
