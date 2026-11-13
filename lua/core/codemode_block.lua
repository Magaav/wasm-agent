-- What ONE code-mode call looks like in the transcript, in one place.
--
-- The operator's report (13/11 ~07:30): a code-mode block repeated the script's first line in the
-- heading, printed the same code again under it, showed the evidence envelope
-- (`{"evidence":{"bytes":2473,"path":".../mcp/requests/..."}}`) where the script's value belonged,
-- and said nothing about which tools ran, whether they worked, or how long they took.
--
-- So the block is now five things, in this order, and nothing else:
--
--   ⏺ Code · bash ×3                                                     1.2s
--     const files = await tools.ls({path: 'lua/core'});
--     await tools.read({path: 'lua/core/chat.lua'});
--     … +4 lines
--     ✓ bash · ls lua/core · 0.2s
--     ✓ read · lua/core/chat.lua · 0.1s
--     ✗ web_read · example.com · web_http_429
--     ⎿ {"count":2,"first":"chat.lua"}
--
-- The heading names the TOOLS the script called, never the code: #121 put the script's first line
-- inside `Codemode(...)`, which made the heading a second copy of the body (Claude Code's
-- `⏺ Bash(npm test)` is a heading because the body is not shown; here the body is the script).
-- The time is the call's total, right-aligned on the heading's row.
--
-- A settled block collapses to ONE row (`M.summary`) when the next one starts - the live-follow
-- rule in `lua/core/cli_view.lua` and `rust/wa-term/src/transcript.rs`:
--
--   ⏺ Code · bash ×3 ✓ · 1.2s → "a,b,c"
--
-- Pure: no host call, no clock, no global state. The view injects the clock, the paint function,
-- the argument summariser and the JSON encoder (`opts`), which is what lets a snapshot test render
-- the same rows the terminal is given, at any width, without a terminal.
local M = {}

-- The script's rows under the heading, before the fold names the rest (`… +N lines`).
M.CODE_ROWS = 6
-- The value's rows under `⎿`.
M.RESULT_ROWS = 3
-- One parallel group is one row; a wider fan-out keeps the newest names.
M.GROUP_NAMES = 3
-- An evidence envelope is a pointer, not an answer: `path`/`bytes`/`sha256` and nothing else that a
-- reader asked for. Hidden from the value, named once under it, whole in /console.
local ENVELOPE_KEYS = { path = true, bytes = true, sha256 = true, sha = true, offset = true,
  limit = true, line = true, lines = true, view = true, byte_offset = true, message_id = true,
  session_id = true, tool = true }
M.ENVELOPE_MARK = "\226\128\166evidence"   -- …evidence

-- ---- the model -------------------------------------------------------------------

-- The block's facts, as the view collects them: the arguments, the calls in the order they started,
-- and (when it settles) the value. `started` is on the view's clock.
function M.new(args, started)
  return { args = (type(args) == "table") and args or {}, started = tonumber(started),
    calls = {}, index = {}, running = 0, started_calls = 0 }
end

-- One inner call starting. The same id twice is the same call (a `pending` handle re-entering), so
-- a duplicate does not become a second row. Returns the call's slot.
function M.begin_call(model, id, name, args)
  local call = id and model.index[id]
  if call then return call end
  call = { id = id, name = tostring(name or "?"), args = (type(args) == "table") and args or {},
    state = "running", started = model.started }
  model.calls[#model.calls + 1] = call
  if id then model.index[id] = call end
  model.running = model.running + 1
  model.started_calls = model.started_calls + 1
  return call
end

-- The call settled: `ok`/`failed`, how long it took, and (when it failed) the error code the row
-- shows in red - `web_http_429`, not "failed".
function M.settle(model, id, facts)
  local f = facts or {}
  local call = id and model.index[id]
  if not call then return nil end
  if call.state == "running" then model.running = math.max(0, model.running - 1) end
  call.state = (f.ok == false or f.error ~= nil) and "failed" or "ok"
  call.ms = tonumber(f.ms) or call.ms
  call.error = f.error
  call.code = f.code
  return call
end

-- A handle the script still holds: `{state:"pending", op}`. It is not a failure and not a success -
-- it is a call that outlived its wait, and it stays ⏳ until a later script settles it.
function M.pending(model, id, op)
  local call = id and model.index[id]
  if not call then return nil end
  if call.state == "running" then model.running = math.max(0, model.running - 1) end
  call.state = "pending"
  call.op = op
  return call
end

-- The script's own answer. `result.calls` is the journal every code-mode result carries (the model's
-- view of the same call), so a replayed or plain-layout block still names its tools when nothing was
-- watching them live; the live rows are the truth when they exist.
function M.finish(model, result, seconds)
  local r = (type(result) == "table") and result or {}
  model.seconds = tonumber(seconds) or model.seconds
  model.ok = r.ok
  model.value = r.value
  model.error = r.error
  model.evidence = r.evidence
  model.raw = r
  if #model.calls == 0 and type(r.calls) == "table" then
    for index, call in ipairs(r.calls) do
      if type(call) == "table" then
        local slot = M.begin_call(model, call.id or ("journal-" .. index), call.name)
        M.settle(model, slot.id, { ok = call.ok ~= false, ms = call.ms, error = call.error, code = call.code })
      end
    end
  end
  return model
end

-- The tool names the script called, in the order they first appear: `{ {name, count}, ... }`.
function M.tools(model)
  local seen, list = {}, {}
  for _, call in ipairs(model.calls or {}) do
    if not seen[call.name] then seen[call.name] = { name = call.name, count = 0 }; list[#list + 1] = seen[call.name] end
    seen[call.name].count = seen[call.name].count + 1
  end
  return list
end

-- ---- the injection ---------------------------------------------------------------

-- `paint(text, style, live)` is the view's colour decision; without it nothing is coloured, which is
-- what a snapshot wants.
function M.opts(options)
  local o = options or {}
  -- Widths are CELLS, never bytes: `·` is two bytes and one column, `⏺` three and one, so a pad
  -- computed from `#text` comes out short and the row a reader sees is not the width that was asked
  -- for. `markdown.columns` is the one count the rest of the CLI uses (`cli_view.columns`).
  local columns = o.columns or function(text) return #tostring(text or "") end
  -- The view's painter takes `(text, style, live)`; the live flag is bound here, once, so a caller in
  -- this module cannot forget it and silently draw a plain row (`paint` with no `live` is the plain
  -- rendering by design).
  local paint = o.paint or function(text) return tostring(text or "") end
  local live = o.live == true
  return {
    paint = function(text, style) return paint(text, style, live) end,
    live = live,
    columns = columns,
    clip = o.clip or function(text, limit)
      local value = tostring(text or "")
      if not limit or limit <= 0 or columns(value) <= limit then return value end
      local index, kept = 1, 0
      while index <= #value do
        local byte = value:byte(index)
        local size = (byte >= 240 and 4) or (byte >= 224 and 3) or (byte >= 192 and 2) or 1
        local cells = columns(value:sub(index, index + size - 1))
        if kept + cells > limit - 1 then break end
        index = index + size
        kept = kept + cells
      end
      return value:sub(1, index - 1) .. "\226\128\166"
    end,
    summarise = o.summarise or function(name) return tostring(name or "") end,
    -- The script row's highlighter (`markdown.scan_code`): a row is dim text whose own tokens carry
    -- their syntax colour, which is what "dim + syntax-highlighted" means on a terminal.
    syntax = o.syntax,
    elapsed = o.elapsed or function(ms)
      local value = tonumber(ms) or 0
      if value < 1000 then return string.format("%dms", math.floor(value)) end
      return string.format("%.1fs", value / 1000)
    end,
    encode = o.encode or function() return "?" end,
  }
end

-- ---- the heading -----------------------------------------------------------------

-- `⏺ Code · bash ×3` with the call's total right-aligned: the tool names are what the script did, so
-- they are the heading; the clock is what a reader checks it against. A row too narrow for both keeps
-- the names (the clock is also in the footer) and never wraps the code into the heading.
function M.head_text(model, o)
  local parts = {}
  for _, tool in ipairs(M.tools(model)) do
    parts[#parts + 1] = tool.count > 1 and (tool.name .. " \195\151" .. tool.count) or tool.name
  end
  return table.concat(parts, ", ")
end

local MARK_OK, MARK_NO, MARK_WAIT = "\226\156\147", "\226\156\151", "\226\143\179"  -- ✓ ✗ ⏳
M.MARK_OK, M.MARK_NO, M.MARK_WAIT = MARK_OK, MARK_NO, MARK_WAIT

-- The heading's verdict: ✓ when every call worked, the first error code in red when one did not,
-- and ⏳ while the script is still running one.
function M.verdict(model, o)
  o = M.opts(o)
  if (model.running or 0) > 0 then return MARK_WAIT .. model.running, "accent" end
  for _, call in ipairs(model.calls or {}) do
    if call.state == "pending" then return MARK_WAIT .. " pending", "accent" end
  end
  for _, call in ipairs(model.calls or {}) do
    if call.state == "failed" then
      return MARK_NO .. " " .. o.clip(call.code or call.error or "failed", 24), "error"
    end
  end
  if model.error then return MARK_NO .. " " .. o.clip(model.error, 24), "error" end
  return MARK_OK, "success"
end

-- The heading's three parts: `⏺ Code · bash ×3`, the pad that pushes the clock right, and the
-- clock. Laid out on PLAIN text - padding a coloured string by its bytes is how a row comes out one
-- column short on screen - so the painter and the measurer cannot disagree about the width.
function M.head_parts(model, width, o)
  o = M.opts(o)
  local names = M.head_text(model, o)
  local left = "\226\143\186 Code" .. (names ~= "" and (" \194\183 " .. names) or "")
  local right = model.seconds and o.elapsed(model.seconds * 1000) or ""
  local limit = math.max(1, width or 80)
  if right == "" then return o.clip(left, limit), "", "" end
  local room = limit - o.columns(right) - 2
  -- A row too narrow for both keeps the names: the clock is also in the block's own summary and in
  -- the footer, and a heading clipped to `⏺ Code · ba` says nothing.
  if room < 12 then return o.clip(left, limit), "", "" end
  left = o.clip(left, room)
  return left, string.rep(" ", math.max(2, limit - o.columns(left) - o.columns(right))), right
end

function M.head(model, width, o)
  o = M.opts(o)
  local left, pad, right = M.head_parts(model, width, o)
  return left .. pad .. right
end

-- The heading as the view paints it: the step mark in the verdict's colour, `Code` bold, the tool
-- names plain, the clock dim.
function M.heading(model, width, o)
  o = M.opts(o)
  local left, pad, right = M.head_parts(model, width, o)
  if not o.live then return left .. pad .. right end
  local names = M.head_text(model, o)
  local rest = (names ~= "" and (" \194\183 " .. names) or "")
  local _, style = M.verdict(model, o)
  return o.paint("\226\143\186", style) .. " " .. o.paint("Code", "bold") .. rest .. pad
    .. (right ~= "" and o.paint(right, "dim") or "")
end


-- The script's own rows, up to `M.CODE_ROWS`, then how many were left: the whole script is one
-- keystroke away (`/console`, and the expanded block), so the block shows the shape of it.
function M.script_rows(args, count)
  local a = (type(args) == "table") and args or {}
  local code = a.code
  if code == nil and type(a.script) == "string" then code = a.script end
  if code == nil then return {}, 0 end
  if type(code) ~= "string" then code = tostring(code) end
  local lines = {}
  for line in (tostring(code):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("%s+$", ""))
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  local rows, hidden = {}, 0
  for index, line in ipairs(lines) do
    if index <= (count or M.CODE_ROWS) then rows[#rows + 1] = line else hidden = hidden + 1 end
  end
  return rows, hidden
end

-- ---- one inner call --------------------------------------------------------------

-- `✓ bash · ls lua/core · 0.2s`: what ran, its key argument, how long. A failure carries the error
-- code the caller paints red - the code is the fact, "failed" is not.
function M.call_text(call, o, width)
  o = M.opts(o)
  local mark = call.state == "ok" and MARK_OK or (call.state == "failed" and MARK_NO or MARK_WAIT)
  local inside = ""
  if o.summarise then
    local shown = o.summarise(call.name, call.args)
    if type(shown) == "string" and shown ~= "" then inside = " \194\183 " .. shown end
  end
  local facts = ""
  if call.state == "failed" then
    facts = " \194\183 " .. tostring(call.code or call.error or "failed")
  elseif call.state == "pending" then
    facts = " \194\183 pending" .. (call.op and (" " .. tostring(call.op)) or "")
  elseif call.ms then
    facts = " \194\183 " .. o.elapsed(call.ms)
  end
  local room = (width or 80) - 2 - o.columns(mark) - 1 - o.columns(call.name) - o.columns(facts)
  local text = mark .. " " .. call.name .. (inside ~= "" and o.clip(inside, math.max(8, room)) or "") .. facts
  return o.clip(text, math.max(8, (width or 80) - 2))
end

-- A fan-out of the same tool is one row, not ten: `bash ×10 ⏳4 ✓5 ✗1`. Ten rows of `✓ bash` say the
-- same thing as one row and cost a screen, and the list is still there when the block is expanded.
function M.groups(model)
  local order, groups = {}, {}
  for _, call in ipairs(model.calls or {}) do
    local group = groups[call.name]
    if not group then
      group = { name = call.name, calls = {} }
      groups[call.name] = group
      order[#order + 1] = group
    end
    group.calls[#group.calls + 1] = call
  end
  return order
end

function M.group_text(group, o, width)
  o = M.opts(o)
  local counts = { running = 0, ok = 0, failed = 0, pending = 0 }
  for _, call in ipairs(group.calls) do
    local state = call.state == "running" and "running" or call.state
    counts[state] = (counts[state] or 0) + 1
  end
  local parts = {}
  for _, state in ipairs({ "running", "ok", "failed", "pending" }) do
    if counts[state] > 0 then
      local mark = state == "ok" and MARK_OK or (state == "failed" and MARK_NO or MARK_WAIT)
      parts[#parts + 1] = mark .. counts[state]
    end
  end
  local text = group.name .. " \195\151" .. #group.calls .. " " .. table.concat(parts, " ")
  -- One call that failed with a code says which: a counter row that only counts hides the reason.
  if counts.failed == 1 and counts.ok + counts.running + counts.pending == 0 then
    for _, call in ipairs(group.calls) do
      if call.state == "failed" then
        text = text .. " \194\183 " .. tostring(call.code or call.error or "failed")
      end
    end
  end
  return o.clip(text, math.max(8, (width or 80) - 2))
end

-- The call rows: one per call, unless a name repeated (a `Promise.all`/`.map` fan-out), which
-- collapses to its counter row.
function M.call_rows(model, width, o)
  o = M.opts(o)
  local rows = {}
  for _, group in ipairs(M.groups(model)) do
    if #group.calls == 1 then
      rows[#rows + 1] = M.call_text(group.calls[1], o, width)
    else
      rows[#rows + 1] = M.group_text(group, o, width)
    end
  end
  return rows
end

-- ---- the value -------------------------------------------------------------------

-- A deep copy of `value` with every evidence envelope replaced by `…evidence`: the pointer is not
-- the answer, and a row of `path`/`bytes` where a script's value belongs reads as a failed call.
function M.hide_evidence(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return value end
  seen[value] = true
  local envelope = true
  for key in pairs(value) do
    if not ENVELOPE_KEYS[key] then envelope = false; break end
  end
  if envelope and (value.path ~= nil or value.sha256 ~= nil or value.bytes ~= nil) then
    return M.ENVELOPE_MARK
  end
  local out = {}
  for key, item in pairs(value) do out[key] = M.hide_evidence(item, seen) end
  return out
end

-- The value as the reader should see it: one row per line of pretty JSON, cut to `M.RESULT_ROWS`,
-- with the count of what it left out. A string value is its own text rather than a quoted one.
function M.result_rows(model, width, o)
  o = o or M.opts()
  local rows, hidden = {}, 0
  local value = M.hide_evidence(model.value)
  local text
  if model.value ~= nil then
    text = (type(value) == "string") and value or o.encode(value)
  elseif model.error then
    text = tostring(model.error)
  end
  if text == nil or text:gsub("%s", "") == "" then return rows, 0 end
  for line in (tostring(text):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    if line:gsub("%s", "") ~= "" then
      if #rows < M.RESULT_ROWS then rows[#rows + 1] = line else hidden = hidden + 1 end
    end
  end
  return rows, hidden
end

-- The first evidence envelope inside a value: a script that returned a connector's answer carries the
-- pointer INSIDE its value (`{operation_id, evidence:{path, bytes, sha256}}`), not beside it, and that
-- is exactly the shape the operator's screenshot showed where the answer should have been.
function M.find_evidence(value, seen)
  if type(value) ~= "table" then return nil end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local envelope = true
  for key in pairs(value) do
    if not ENVELOPE_KEYS[key] then envelope = false; break end
  end
  if envelope and (value.path ~= nil or value.sha256 ~= nil or value.bytes ~= nil) then return value end
  for key, item in pairs(value) do
    if key ~= "evidence" or type(item) == "table" then
      local found = M.find_evidence(item, seen)
      if found then return found end
    end
  end
  return nil
end

-- The envelope, named once, under the value: how many bytes it was and its digest - never its path,
-- which is the longest and least useful part of it. The whole envelope (path included) is in
-- `/console`, which prints the result the model received; this row is what the block can say without
-- turning an answer into a file listing.
function M.evidence_text(envelope, o)
  o = M.opts(o)
  local e = (type(envelope) == "table") and envelope or {}
  local parts = {}
  if e.bytes then parts[#parts + 1] = tostring(e.bytes) .. " B" end
  if e.sha256 then parts[#parts + 1] = "sha " .. tostring(e.sha256):sub(1, 8) end
  if #parts == 0 then return nil end
  return "evidence: " .. table.concat(parts, " \194\183 ") .. " (/console has the path)"
end

-- Did the block hide anything? Both of these are worth one dim row saying where it went.
function M.hidden_evidence(model)
  local value = model.value
  if type(value) ~= "table" then return false end
  if value.evidence ~= nil then return true end
  for key in pairs(value) do
    if not ENVELOPE_KEYS[key] then return false end
  end
  return true
end

-- ---- the block -------------------------------------------------------------------

-- The call rows as the transcript draws them: one row per call (or per fan-out), the ✓/✗/⏳ mark in
-- its own colour. This is the row a running block rewrites in place as each call settles
-- (`host.transcript_rewrite`), so it is built by one function and nothing else.
function M.call_lines(model, width, o)
  o = M.opts(o)
  local rows = {}
  for _, row in ipairs(M.call_rows(model, width, o)) do
    local mark = row:sub(1, #MARK_NO)
    local style = (mark == MARK_NO and "error") or (mark == MARK_WAIT and "accent") or "dim"
    if o.live and mark == MARK_NO then
      rows[#rows + 1] = "  " .. o.paint(mark, style) .. row:sub(#MARK_NO + 1)
    else
      rows[#rows + 1] = o.paint("  " .. row, style)
    end
  end
  return rows
end

-- The rows above the value: the heading, the script once, then a row per inner call. A running
-- block is exactly these, and they only grow (a call appears once and is rewritten in place), which
-- is what lets the view stream them without redrawing the block.
function M.rows(model, width, options)
  local o = M.opts(options)
  width = math.max(20, tonumber(width) or 80)
  local rows = { M.heading(model, width, o) }
  local code, code_hidden = M.script_rows(model.args)
  for _, line in ipairs(code) do
    -- The row is fitted BEFORE it is highlighted: clipping a string that already carries escape
    -- sequences by width would cut one in half, and a cut token paints the rest of the block.
    local shown = o.clip(line, math.max(8, width - 2))
    if o.live and o.syntax then
      local parts = {}
      o.syntax(shown, "js", function(piece, style)
        if piece == "" then return end
        parts[#parts + 1] = o.paint(piece, style or "dim")
      end)
      rows[#rows + 1] = "  " .. table.concat(parts)
    else
      rows[#rows + 1] = o.paint("  " .. shown, "dim")
    end
  end
  if code_hidden > 0 then
    rows[#rows + 1] = o.paint("  \226\128\166 +" .. code_hidden .. " lines", "dim")
  end
  for _, row in ipairs(M.call_lines(model, width, o)) do rows[#rows + 1] = row end
  return rows
end

-- The rows under the calls: the value the script returned (a few rows, the rest counted), then where
-- the evidence envelope went. Empty while the script runs - there is no answer yet.
function M.tail_rows(model, width, options)
  local o = M.opts(options)
  width = math.max(20, tonumber(width) or 80)
  local rows = {}
  local value, value_hidden = M.result_rows(model, width, o)
  -- A script that failed with no value has already said why on its ✗ row: the answer row would be
  -- the same code twice, one line apart.
  if model.value == nil and model.error ~= nil then
    for _, call in ipairs(model.calls or {}) do
      if call.state == "failed" and tostring(call.code or call.error or "") == tostring(model.error) then
        value, value_hidden = {}, 0
        break
      end
    end
  end
  local lead = "\226\142\191 "
  for index, line in ipairs(value) do
    local style = model.error and not model.value and "error" or "text"
    rows[#rows + 1] = (index == 1 and o.paint(lead, "muted") or "  ")
      .. o.paint(o.clip(line, width - 4), style)
  end
  if value_hidden > 0 then
    rows[#rows + 1] = o.paint("  \226\128\166 +" .. value_hidden .. " lines (/console shows all)", "dim")
  end
  local evidence = M.evidence_text(model.evidence or M.find_evidence(model.value), o)
  if evidence == nil and M.hidden_evidence(model) then
    evidence = "evidence: pointer kept (/console has it)"
  end
  if evidence then rows[#rows + 1] = o.paint("  " .. o.clip(evidence, width - 2), "dim") end
  return rows
end

-- The block's rows, in the order the transcript draws them: heading, script, calls, value, where the
-- evidence is. `width` is the screen the rows must fit in (the transcript wraps again at this width,
-- so a row built here that fits is drawn as it is).
function M.lines(model, width, options)
  local rows = M.rows(model, width, options)
  for _, row in ipairs(M.tail_rows(model, width, options)) do rows[#rows + 1] = row end
  return rows
end

-- The one row a settled block collapses to when the next code-mode block starts, and the row a
-- failed or pinned one keeps: `⏺ Code · bash ×3 ✓ · 1.2s → "a,b,c"`. Plain text: the host draws it
-- as a line of the block, and the collapsed state must not depend on this process painting it.
function M.summary(model, width, options)
  local o = M.opts(options)
  width = math.max(20, tonumber(width) or 80)
  local names = M.head_text(model, o)
  local mark = M.verdict(model, o)
  -- The verdict rides with the names (`bash ×3 ✓`), a space apart: the reader is asking "what ran,
  -- and did it work", and that is one thought.
  local parts = { "\226\143\186 Code", names ~= "" and (names .. " " .. mark) or mark }
  if model.seconds then parts[#parts + 1] = o.elapsed(model.seconds * 1000) end
  local text = table.concat(parts, " \194\183 ")
  local value = M.hide_evidence(model.value)
  local shown
  if model.value ~= nil then
    shown = (type(value) == "string") and value or o.encode(value)
  elseif model.error then
    shown = tostring(model.error)
  end
  if shown and shown:gsub("%s", "") ~= "" then
    shown = o.clip((tostring(shown):gsub("%s+", " ")), math.max(8, width - o.columns(text) - 5))
    text = text .. " \226\134\146 " .. shown
  end
  return o.clip(text, width)
end

-- The style of the summary row's mark, for the caller that paints it: a collapsed failure keeps its
-- ✗ in red (`lua/core/cli_view.lua`).
function M.summary_style(model)
  local mark = M.verdict(model, M.opts())
  if mark:sub(1, #MARK_NO) == MARK_NO then return "error" end
  if mark:sub(1, #MARK_WAIT) == MARK_WAIT then return "accent" end
  return "success"
end

return M
