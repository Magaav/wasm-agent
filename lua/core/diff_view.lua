-- The file change a run makes, as a block a reader can follow in the terminal.
--
-- Measured 20/11, before this file: a write/edit call reached the TUI as its result table, and the
-- before/after text WAS available - changeset.record already stores both sides of every write/edit
-- in the content-addressed store (lua/core/changeset.lua), and the tool result carries the two
-- digests as previous_version/version. What was missing was a display: cli_view.M.preview answers
-- nothing for write/edit, so a change showed as "written" and no lines at all.
--
-- So this module is the display only, and it is deliberately pure: it takes the two texts and
-- returns rows. It paints nothing and reads no host, because colour is cli_view's decision (it owns
-- the palette and the live flag), and because a pure renderer is what a test can pin without a
-- terminal - including the NO_COLOR path, which is the same rows with no escape written into them.
--
-- The rows are shaped as a card (top bar, body bar, bottom bar), the same frame
-- lua/core/markdown.lua draws for a fence and rust/wa-term/src/transcript.rs keeps whole: a body row
-- is cut inside the border rather than wrapped to column 0, which is what "survives a narrow width
-- and a resize" means here - the wrapping happens where the text is made, at the width the view has
-- now.
--
-- The model's context is unchanged: none of this is in a tool result. It is rendered from the
-- session's own change record after the call returned.
local changeset = dofile("lua/core/changeset.lua")
local markdown = dofile("lua/core/markdown.lua")

local M = {}

-- Context rows around a change, and how many body rows a block shows before it folds. Both are
-- display facts: a reader scrolling the terminal wants the shape of the change, and a 2000-line
-- rewrite is not more useful for being shown whole.
M.CONTEXT = 2
M.MAX_BODY = 40

local function cells_of(text)
  local used, from = 0, 1
  while from <= #text do
    local size, cells = markdown.char_at(text, from)
    used, from = used + cells, from + size
  end
  return used
end

-- Longest common subsequence, bounded exactly as changeset.diff_lines bounds it, so a huge rewrite
-- degrades to the block form (all removals, then all additions) instead of building a table that
-- costs the turn. Ops carry REAL line numbers: old is the line in the before text, new in the after
-- text, and a row has only the one that exists - which is what lets a removed line show the number
-- it HAD rather than a number that never existed in either file.
function M.ops(before, after)
  local a, b = changeset.split_lines(before), changeset.split_lines(after)
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < (#a - head) and tail < (#b - head) and a[#a - tail] == b[#b - tail] do tail = tail + 1 end
  local ops = {}
  for i = 1, head do ops[#ops + 1] = { kind = " ", old = i, new = i, text = a[i] } end
  local n, m = #a - head - tail, #b - head - tail
  if n * m > 250000 then
    for i = 1, n do ops[#ops + 1] = { kind = "-", old = head + i, text = a[head + i] } end
    for j = 1, m do ops[#ops + 1] = { kind = "+", new = head + j, text = b[head + j] } end
  else
    local lcs = {}
    for i = 0, n do
      lcs[i] = {}
      for j = 0, m do lcs[i][j] = 0 end
    end
    for i = n - 1, 0, -1 do
      for j = m - 1, 0, -1 do
        if a[head + i + 1] == b[head + j + 1] then
          lcs[i][j] = lcs[i + 1][j + 1] + 1
        else
          lcs[i][j] = math.max(lcs[i + 1][j], lcs[i][j + 1])
        end
      end
    end
    local i, j = 0, 0
    while i < n and j < m do
      if a[head + i + 1] == b[head + j + 1] then
        ops[#ops + 1] = { kind = " ", old = head + i + 1, new = head + j + 1, text = a[head + i + 1] }
        i, j = i + 1, j + 1
      elseif lcs[i + 1][j] >= lcs[i][j + 1] then
        ops[#ops + 1] = { kind = "-", old = head + i + 1, text = a[head + i + 1] }
        i = i + 1
      else
        ops[#ops + 1] = { kind = "+", new = head + j + 1, text = b[head + j + 1] }
        j = j + 1
      end
    end
    while i < n do
      ops[#ops + 1] = { kind = "-", old = head + i + 1, text = a[head + i + 1] }
      i = i + 1
    end
    while j < m do
      ops[#ops + 1] = { kind = "+", new = head + j + 1, text = b[head + j + 1] }
      j = j + 1
    end
  end
  for k = 1, tail do
    local o, w = #a - tail + k, #b - tail + k
    ops[#ops + 1] = { kind = " ", old = o, new = w, text = a[o] }
  end
  return ops
end

-- The runs of a diff worth showing: each changed row with context rows either side, and adjacent
-- ranges merged so a change three rows below another is one hunk rather than two with an ellipsis
-- between them that hides nothing.
function M.hunks(ops, context)
  context = context or M.CONTEXT
  local changed = {}
  for index, op in ipairs(ops) do
    if op.kind ~= " " then changed[#changed + 1] = index end
  end
  if #changed == 0 then return {} end
  local ranges = {}
  local first, last = math.max(1, changed[1] - context), math.min(#ops, changed[1] + context)
  for i = 2, #changed do
    local index = changed[i]
    if index - context <= last + 1 then
      last = math.min(#ops, index + context)
    else
      ranges[#ranges + 1] = { first, last }
      first, last = math.max(1, index - context), math.min(#ops, index + context)
    end
  end
  ranges[#ranges + 1] = { first, last }
  local hunks = {}
  for _, range in ipairs(ranges) do
    local lines = {}
    for at = range[1], range[2] do lines[#lines + 1] = ops[at] end
    hunks[#hunks + 1] = lines
  end
  return hunks
end

-- The rows of one file's change. change is {path, before, after} with the two texts already loaded;
-- opts.width is the cells available for a whole row, border included.
--
-- Every row carries lead (the border, the two line numbers and the marker), code (the text, padded to
-- the width with spaces so a band covers the whole row), role - the palette role its code is painted
-- with - and band (the op kind, for a row that takes a background band). hidden is how many body rows
-- were folded away, never dropped silently.
--
-- The frame is exactly what a fence draws: an opening row of just the corner and its bar, body rows
-- that begin with the bar, a closing row. rust/wa-term/src/transcript.rs accepts an opening only as
-- the corner and the bar (or a fence language after it), so the heading (`Create(path)`, `Update(path)`,
-- `Delete(path)`) and the counts are the FIRST body rows - the card cannot carry them in its opening
-- without being read as prose.
function M.rows(change, opts)
  opts = opts or {}
  local width = math.max(24, tonumber(opts.width) or 80)
  local ops = M.ops(change.before or "", change.after or "")
  local added, removed = 0, 0
  for _, op in ipairs(ops) do
    if op.kind == "+" then added = added + 1 elseif op.kind == "-" then removed = removed + 1 end
  end
  local hunks = M.hunks(ops, opts.context or M.CONTEXT)
  local most, digits = 1, 2
  for _, op in ipairs(ops) do most = math.max(most, op.old or 0, op.new or 0) end
  digits = math.max(2, #tostring(most))
  -- The border bar and its space, two number columns, the marker and its space: what the code has left.
  local lead_cells = 2 + digits * 2 + 4
  -- The room the CODE has: the whole row is exactly `width` cells, so a band and a border end together.
  local room = math.max(8, width - lead_cells)
  -- The fence language the row tokens are coloured as, from the file name: the set
  -- markdown.scan_code knows, and empty when it knows none (the row is then plain, never guessed).
  local lang = tostring(change.path or ""):match("%.([%w_]+)$") or ""

  local rows = {}

  -- One body row, cut to the room it has by the same cell rule the fence uses, and padded so the band
  -- and the border end on the same column at every width.
  local function push(lead, text, role, band, marker)
    local first = true
    repeat
      local take, used = 1, 0
      while take <= #text do
        local size, cells = markdown.char_at(text, take)
        if used + cells > room then break end
        used, take = used + cells, take + size
      end
      local chunk, rest = text:sub(1, take - 1), text:sub(take)
      local left = math.max(0, room - cells_of(chunk))
      rows[#rows + 1] = { kind = "body", op = band,
        lead = (first and lead or string.rep(" ", lead_cells)),
        code = (chunk:gsub("\27%[[%d;]*m", "")) .. string.rep(" ", left),
        role = role, band = band, marker = first and marker or " ", lang = lang }
      text, first = rest, false
    until text == ""
  end

  -- A row of text that is not code: cut too, so a long path never pushes the border out.
  local function plain(lead, text, role)
    while #text > 0 do
      local take, used = 1, 0
      while take <= #text do
        local size, cells = markdown.char_at(text, take)
        if used + cells > room then break end
        used, take = used + cells, take + size
      end
      local chunk, rest = text:sub(1, take - 1), text:sub(take)
      rows[#rows + 1] = { kind = "body", lead = lead, lang = lang,
        code = chunk .. string.rep(" ", math.max(0, room - cells_of(chunk))), role = role }
      text, lead = rest, string.rep(" ", lead_cells)
    end
  end

  rows[#rows + 1] = { kind = "open", lead = "\226\148\140\226\148\128", role = "mdCodeBlockBorder" }
  -- The two rows a reader reads first, INSIDE the frame (a card's opening is exact, so they cannot be
  -- its title): what happened to which path, named the way Claude Code names it, then the counts in
  -- words. `deleted` is the caller's fact, not a guess from an empty after text - an emptied file and a
  -- removed file are different things, and only the caller knows which it saw.
  local heading = change.deleted == true and "Delete"
    or ((change.before or "") == "" and "Create" or "Update")
  plain("\226\148\130 ", heading .. "(" .. tostring(change.path or "?") .. ")", "mdCodeBlock")
  plain("\226\148\130 ", string.format("Added %d lines, removed %d lines", added, removed), "dim")

  local blank = string.rep(" ", digits)
  local body, budget = {}, opts.max_body or M.MAX_BODY
  for index, hunk in ipairs(hunks) do
    if index > 1 then body[#body + 1] = { kind = "gap" } end
    for _, op in ipairs(hunk) do body[#body + 1] = { kind = "body", op = op } end
  end
  local hidden = math.max(0, #body - budget)
  local shown = 0
  for _, item in ipairs(body) do
    if shown >= budget then break end
    shown = shown + 1
    if item.kind == "gap" then
      plain("\226\148\130 " .. blank .. " " .. blank .. "   ", "...", "mdQuote")
    else
      local op = item.op
      local old = op.old and string.format("%" .. digits .. "d", op.old) or blank
      local new = op.new and string.format("%" .. digits .. "d", op.new) or blank
      local role = op.kind == "+" and "toolDiffAdded" or op.kind == "-" and "toolDiffRemoved" or "toolDiffContext"
      push("\226\148\130 " .. old .. " " .. new .. " " .. op.kind .. " ", (op.text or ""):gsub("\t", "    "),
        role, op.kind, op.kind)
    end
  end
  if hidden > 0 then
    plain("\226\148\130 " .. blank .. " " .. blank .. "   ",
      string.format("... +%d more lines: /console shows all", hidden), "dim")
  end
  -- The footnote is the card's LAST body row, so it is inside the frame and dim, not a line under it.
  plain("\226\148\130 ", "convenience view, not a review", "dim")
  rows[#rows + 1] = { kind = "close", lead = "\226\148\148\226\148\128", role = "mdCodeBlockBorder" }
  return { rows = rows, added = added, removed = removed, hidden = hidden, width = width }
end

-- The two texts for one recorded file, or nil and why. A change the run could not record (too large,
-- or a file whose previous text was unreadable) has no honest diff to show, and this says so instead
-- of drawing an empty one.
function M.texts(file)
  if type(file) ~= "table" then return nil, "no_change" end
  if file.recorded == false then return nil, "not_recorded" end
  local before, why = changeset.load(file.before)
  if before == nil then return nil, why or "no_before_text" end
  local after, why_after = changeset.load(file.after)
  if after == nil then return nil, why_after or "no_after_text" end
  return before, after
end

return M
