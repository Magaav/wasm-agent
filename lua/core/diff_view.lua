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

-- Context rows around a change: three, the way Claude Code shows them, so a reader sees what the
-- changed line sat in and not only the line itself in isolation.
M.CONTEXT = 3
-- The host's ceiling for ONE block (`MAX_LINES` in rust/wa-term/src/transcript.rs). A card longer than
-- this cannot be honoured by "ctrl+o opens it fully", so it is cut HERE and says where the rest is
-- read (/console) rather than promising something the host would refuse. The bound a reader meets
-- first is the host's own DISPLAY bound (`CARD_ROWS` there): this file renders the whole diff, and the
-- host folds what does not fit and opens it on ctrl+o or a click. Neither bound costs the model
-- anything - both are drawing, not context.
M.MAX_LINES = 19960

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

-- A path as the reader names it (Victor 23/11, Claude Code's heading): relative to the workdir when
-- the file is inside it, `~` for the operator's home, the full path otherwise. PURE: the two
-- directories arrive as arguments, because a renderer that read the environment could draw a
-- different heading than the terminal does.
function M.short_path(path, opts)
  local function trim(dir) return (tostring(dir or ""):gsub("\\", "/"):gsub("/+$", "")) end
  local full = tostring(path or ""):gsub("\\", "/")
  local cwd, home = trim(opts and opts.cwd), trim(opts and opts.home)
  if cwd ~= "" and full:sub(1, #cwd + 1) == cwd .. "/" then return full:sub(#cwd + 2) end
  if home ~= "" and full:sub(1, #home + 1) == home .. "/" then return "~" .. full:sub(#home + 1) end
  return full
end

-- What happened to the file, in words, and ONLY what happened: a create says "Added 26 lines" and
-- never "removed 0 lines" (Victor 23/11 - the count row reported a change nobody made).
function M.counts(added, removed)
  local function lines(n, verb) return string.format("%s %d line%s", verb, n, n == 1 and "" or "s") end
  if added == 0 and removed == 0 then return "No lines changed" end
  if removed == 0 then return lines(added, "Added") end
  if added == 0 then return lines(removed, "Removed") end
  return lines(added, "Added") .. ", " .. lines(removed, "removed")
end

-- The rows of one file's change. change is {path, before, after} with the two texts already loaded;
-- opts.width is the cells available for a whole row, border included, and opts.cwd/opts.home/opts.node
-- name the change the way the heading says it.
--
-- Every row carries lead (the border, ONE line number and the marker), and then either code (the text,
-- padded to the width with spaces so a band covers the whole row) or parts (coloured pieces of one
-- row: the heading's bullet, which keeps the status colour, and its name) - with role, the palette role
-- the code is painted with, and band (the op kind, for a row that takes a background band).
--
-- The frame is exactly what a fence draws: an opening row of just the corner and its bar, body rows
-- that begin with the bar, a closing row. rust/wa-term/src/transcript.rs accepts an opening only as
-- the corner and the bar (or a fence language after it), so the heading (`Create(path)`, `Update(path)`,
-- `Delete(path)`) and the count row are the FIRST body rows - the card cannot carry them in its opening
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
  -- The border bar and its space, ONE line number, the marker and its space: what the code has left.
  -- One number, not two (Claude Code's): the new number for a context or an added row, the old one for
  -- a removed row - the number the line has, or had, in a file a reader can open.
  local lead_cells = 2 + digits + 3
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

  -- A row of coloured PARTS: the heading's bullet keeps the status colour while the name keeps the
  -- card's, and the row is cut and padded by the same cell rule as every other row (so the border ends
  -- on the same column). The plain rendering (`live = false`) is the same parts with no escape written
  -- into them, because the painter, never this renderer, decides colour.
  local function rich(lead, parts)
    local kept, used = {}, 0
    for _, part in ipairs(parts) do
      local text, at, last = tostring(part.text or ""), 1, 0
      while at <= #text do
        local size, cells = markdown.char_at(text, at)
        if used + cells > room then break end
        used, last, at = used + cells, at + size - 1, at + size
      end
      if last > 0 then kept[#kept + 1] = { text = text:sub(1, last), role = part.role } end
      if used >= room then break end
    end
    if used < room then kept[#kept + 1] = { text = string.rep(" ", room - used) } end
    rows[#rows + 1] = { kind = "body", lead = lead, parts = kept, lang = lang }
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
  -- its title): what happened to which path, named the way Claude Code names it - `● Create(path)`, the
  -- bullet in the colour of the outcome - then the counts in words. `deleted` is the caller's fact, not
  -- a guess from an empty after text: an emptied file and a removed file are different things, and only
  -- the caller knows which it saw.
  local deleted = change.deleted == true
  local created = (change.before or "") == "" and not deleted
  local what = deleted and "Delete" or (created and "Create" or "Update")
  local name = M.short_path(change.path, { cwd = opts.cwd, home = opts.home })
  -- A change made on ANOTHER node says so in the heading itself (Victor 23/11): `Create(nextcloud:/x)`,
  -- not a line after the card that the eye has to reach past the diff to find.
  if opts.node ~= nil and tostring(opts.node) ~= "" then name = tostring(opts.node) .. ":" .. name end
  rich("\226\148\130 ", {
    { text = "\226\151\143 ", role = deleted and "error" or "success" },
    { text = what .. "(" .. name .. ")", role = "mdCodeBlock" } })
  plain("\226\148\130 ", M.counts(added, removed), "dim")

  local blank = string.rep(" ", digits)
  local body, budget = {}, opts.max_lines or M.MAX_LINES
  for index, hunk in ipairs(hunks) do
    if index > 1 then body[#body + 1] = { kind = "gap" } end
    for _, op in ipairs(hunk) do body[#body + 1] = { kind = "body", op = op } end
  end
  local hidden = math.max(0, #body - budget)
  local from = #rows + 1
  local shown = 0
  for _, item in ipairs(body) do
    if shown >= budget then break end
    shown = shown + 1
    if item.kind == "gap" then
      -- Two hunks are separated by ONE dim mark in the line-number column - the vertical ellipsis a
      -- reader already knows - instead of a row of text in the middle of the code.
      plain("\226\148\130 " .. blank .. " ", "\226\139\174", "mdQuote")
    else
      local op = item.op
      local number = op.new or op.old or 0
      local lead = "\226\148\130 " .. string.format("%" .. digits .. "d", number) .. " " .. op.kind .. " "
      local role = op.kind == "+" and "toolDiffAdded" or op.kind == "-" and "toolDiffRemoved" or "toolDiffContext"
      push(lead, (op.text or ""):gsub("\t", "    "), role, op.kind, op.kind)
    end
  end
  local to = #rows
  if hidden > 0 then
    -- The host's own ceiling was reached: the rest of the diff is in /console, and the row says so
    -- instead of promising an expansion that cannot be honoured.
    plain("\226\148\130 " .. blank .. " ",
      string.format("\226\128\166 +%d lines: /console shows all", hidden), "dim")
  end
  rows[#rows + 1] = { kind = "close", lead = "\226\148\148\226\148\128", role = "mdCodeBlockBorder" }
  -- `body` is the span of rows that IS the diff (1-based, inclusive). The view hands it to the host, so
  -- the host's fold can keep the frame, the heading and the counts and fold only the code in between.
  return { rows = rows, added = added, removed = removed, hidden = hidden, width = width,
    body = { from = from, to = to } }
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
