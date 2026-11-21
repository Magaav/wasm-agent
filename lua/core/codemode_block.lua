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
-- The vendor decoder, for the ONE shape a script's value crosses the sandbox boundary as: a JSON
-- string (measured on the parity capture, fixtures/raw-default/base-op-block.json). Pure and
-- global-free like the rest of this module - the caller's encoder stays injectable (`opts.encode`),
-- this is only how a string that IS an object is READ back.
local json = dofile('lua/vendor/json.lua')

-- The script's rows under the heading, before the fold names the rest (`… +N lines`).
M.CODE_ROWS = 6
-- The value's rows under the result mark: a few, then `... +N lines` (Victor 21/11: "the script's
-- return value is drawn compactly (pretty, truncated), never as a wrapped 4 KB blob"). This is the
-- PLAYOUT of a value, not a budget on what the model received: the whole of it stays one click away
-- (the `transcript_expand` fold) and in /console, which prints the result the tool answered with.
M.RESULT_ROWS = 8
-- How many lines of ONE call's own output are drawn under its row, and the indent they sit at: the
-- call row is drawn two columns in, so its content is drawn four.
M.CALL_CONTENT_ROWS = 4
M.CALL_CONTENT_INDENT = "    "
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
  -- The call's own CONTENT, when the event carried it: what the command said, never the operation
  -- envelope that carried it (M.output_of is the allow-list). Kept on the slot so the row is drawn
  -- again at any width, and so a settled call never loses what it said when the block is rewritten.
  call.output = f.output or call.output
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
    expandable = o.expandable == true,
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
    -- The erase that paints the rest of a band ROW: the caller owns the palette, so it hands one
    -- closure that sets the band colour and then EL. A caller with no palette gets nothing, and the
    -- row is exactly its text.
    band_erase = o.band_erase or function() return "" end,
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

-- The background-colour erase: paint the rest of the ROW in the colour in force, with no
-- characters. A row that ends in spaces is a row a narrow terminal re-wraps.
local BAND_ERASE = "\27[K"
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
  -- The modality, named: CodeAct is the model acting by writing code (codemode is its runtime; the
  -- tools named after the dot say what the script did).
  return o.paint("\226\143\186", style) .. " " .. o.paint("CodeAct", "bold") .. rest .. pad
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
  -- No argument summary: the script above already shows every argument whole, and a summary had to be
  -- clipped (`chat=1126… text=C…`) to keep the call one row - the row the view rewrites in place.
  inside = ""
  local text = mark .. " " .. call.name .. facts
  return o.clip(text, math.max(8, (width or 80) - 3))
end

-- ---- one call's own content ---------------------------------------------------------
--
-- Victor 21/11: "under each tool row draw that call's CONTENT: its stdout (and stderr if any,
-- dimmed), up to a few lines with +N lines folded, exactly like the old raw-channel view did. The
-- operation envelope (ids, paths, timing, owner, flags) is NOT content: never drawn by default."
--
-- A settled call therefore keeps what it SAID, and the object that carried it never reaches a row:
-- the same allow-list rule M.operation_of applies to a script's value, applied one level down.

-- The content of one call's answer: its stdout, and its stderr (a failed command answers through
-- stderr). An allow-list - a table carrying at least one of the two AS A STRING - so a read's value,
-- a status object or an evidence envelope is never mistaken for a command's output.
function M.output_of(value)
  if type(value) == "string" then
    local first = value:match("^%s*(.)") or ""
    if first ~= "{" then return nil end
    local ok, decoded = pcall(json.decode, value)
    if not ok or type(decoded) ~= "table" then return nil end
    value = decoded
  end
  if type(value) ~= "table" then return nil end
  if type(value.stdout) ~= "string" and type(value.stderr) ~= "string" then return nil end
  return { stdout = type(value.stdout) == "string" and value.stdout or "",
    stderr = type(value.stderr) == "string" and value.stderr or "" }
end

-- The rows one settled call adds under its own row: its stdout, then its stderr, at most
-- M.CALL_CONTENT_ROWS of them and the count of the non-blank lines left out. A call still running
-- has no content yet; a call that said nothing adds no row at all.
function M.call_content(call, width, o)
  o = M.opts(o)
  if type(call) ~= "table" then return {}, 0 end
  if call.state == "running" or call.state == "pending" then return {}, 0 end
  local output = M.output_of(call.output)
  if not output then return {}, 0 end
  local limit = math.max(8, (width or 80) - o.columns(M.CALL_CONTENT_INDENT) - 1)
  local rows, shown, hidden = {}, 0, 0
  local function add(text)
    if text:gsub("%s", "") == "" then return end
    if shown >= M.CALL_CONTENT_ROWS then hidden = hidden + 1; return end
    shown = shown + 1
    for _, piece in ipairs(M.wrap(text, limit, o)) do rows[#rows + 1] = M.CALL_CONTENT_INDENT .. piece end
  end
  for line in (output.stdout:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do add(line) end
  for line in (output.stderr:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do add(line) end
  if hidden > 0 then rows[#rows + 1] = M.CALL_CONTENT_INDENT .. "… +" .. hidden .. " lines" end
  return rows, hidden
end

-- The block's inner rows as ENTRIES, so its two renderers cannot disagree about them: a call's own
-- row ("call", rewritten in place as it settles) and the content under it ("content", dim).
function M.call_entries(model, width, o)
  o = M.opts(o)
  local entries = {}
  local function add_call(call)
    entries[#entries + 1] = { kind = "call", text = M.call_text(call, o, width) }
    for _, row in ipairs(M.call_content(call, width, o)) do
      entries[#entries + 1] = { kind = "content", text = row }
    end
  end
  for _, group in ipairs(M.groups(model)) do
    if #group.calls == 1 then
      add_call(group.calls[1])
    else
      -- A fan-out of one tool is ONE counter row while none of its calls has content; once the
      -- commands have said something, each call is its own row with its own output under it - a
      -- counter row (bash x10, check marks) cannot answer "what did each one say".
      local said = false
      for _, call in ipairs(group.calls) do
        if #(M.call_content(call, width, o)) > 0 then said = true; break end
      end
      if said then
        for _, call in ipairs(group.calls) do add_call(call) end
      else
        entries[#entries + 1] = { kind = "call", text = M.group_text(group, o, width) }
      end
    end
  end
  return entries
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
-- The call rows: one per call, unless a name repeated (a Promise.all / .map fan-out) and none of
-- them has content to show - which collapses to its counter row - plus the content rows under each.
function M.call_rows(model, width, o)
  o = M.opts(o)
  local rows = {}
  for _, entry in ipairs(M.call_entries(model, width, o)) do rows[#rows + 1] = entry.text end
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

-- ---- the value, read for a human --------------------------------------------------
--
-- A script's value crosses the sandbox boundary as a JSON STRING (measured on the parity capture),
-- so a table arrives as text; and a dictionary of managed operations arrives as kilobytes of
-- transport metadata around two lines of output. Three helpers turn either shape into what a reader
-- can read: M.decoded (the string that is an object), M.readable (every envelope replaced by what it
-- carried) and M.pretty (JSON, one row per member, M.RESULT_ROWS of them).

-- The value a script really returned: a JSON string is read back, a plain string is prose, anything
-- else is itself.
function M.decoded(value)
  if type(value) ~= "string" then return value end
  local first = value:match("^%s*(.)") or ""
  if first ~= "{" and first ~= "[" then return value end
  local ok, decoded = pcall(json.decode, value)
  if not ok or type(decoded) ~= "table" then return value end
  return decoded
end

-- What ONE managed operation contributes to a value: its own output, trimmed - its stdout, or its
-- stderr when stdout said nothing. Never the envelope: an id, a path, a timing and an owner are how
-- the node carried the answer, not the answer. An operation that said nothing at all still says so,
-- or a key that returned nothing reads as a key that is missing.
function M.operation_output(operation, o)
  local out = M.output_of(operation)
  if not out then return nil end
  local text = out.stdout
  if text:gsub("%s", "") == "" then text = out.stderr end
  if text:gsub("%s", "") == "" then return "… no output" end
  return (text:gsub("[\r\n]+$", ""))
end

-- value as the reader should see it: every operation envelope inside it replaced by its output (one
-- level down or ten - a script that returned {seq: op, uname: op} returned two answers, not two
-- envelopes). Evidence envelopes are hidden afterwards, by M.hide_evidence.
function M.readable(value, o, seen)
  o = M.opts(o)
  seen = seen or {}
  if type(value) ~= "table" then return value end
  if seen[value] then return value end
  seen[value] = true
  local output = M.operation_output(value, o)
  if output then return output end
  local out = {}
  for key, item in pairs(value) do out[key] = M.readable(item, o, seen) end
  return out
end

-- value as rows of pretty JSON, two columns per level, one member per row. A short array of scalars
-- stays on one row ([1, 2, 3]): three numbers are one thought, not five rows.
function M.pretty(value, o, indent, out)
  o = M.opts(o)
  indent = tonumber(indent) or 0
  out = out or {}
  local pad = string.rep("  ", indent)
  if type(value) ~= "table" then
    out[#out + 1] = pad .. tostring(o.encode(value))
    return out
  end
  local keys, array, count = {}, true, 0
  for key in pairs(value) do
    count = count + 1
    keys[#keys + 1] = key
    if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then array = false end
  end
  if count == 0 then
    out[#out + 1] = pad .. (array and "[]" or "{}")
    return out
  end
  if array then table.sort(keys) else table.sort(keys, function(a, b) return tostring(a) < tostring(b) end) end
  local open, close = array and "[" or "{", array and "]" or "}"
  local scalars = true
  for _, key in ipairs(keys) do if type(value[key]) == "table" then scalars = false; break end end
  if scalars and count <= 6 then
    -- A shallow object is ONE row, in the caller's encoder's own compact form: a value that already
    -- fits a row is drawn exactly as it always was, so a small answer cannot change shape for a
    -- formatting rule nobody asked for.
    out[#out + 1] = pad .. tostring(o.encode(value))
    return out
  end
  out[#out + 1] = pad .. open
  for index, key in ipairs(keys) do
    local item = value[key]
    local label = pad .. "  "
    if not array then label = label .. tostring(o.encode(tostring(key))) .. ": " end
    if type(item) == "table" then
      local start = #out + 1
      M.pretty(item, o, indent + 1, out)
      -- The member's label rides on its opening row, which already carries the deeper indent.
      out[start] = label .. tostring(out[start]):sub(#pad + 3)
    else
      out[#out + 1] = label .. tostring(o.encode(item))
    end
    if index < #keys then out[#out] = out[#out] .. "," end
  end
  out[#out + 1] = pad .. close
  return out
end

-- The whole of a value, exactly as the node carried it: what a fold answers when the reader asks to
-- see the rest. Nothing is replaced and nothing is hidden - an operation envelope is EXPLORABLE, it
-- is only never drawn by default (Victor 21/11).
function M.raw_rows(value, o)
  o = M.opts(o)
  local decoded = value
  if type(value) == "string" then
    local ok, one = pcall(json.decode, value)
    if ok and type(one) == "table" then decoded = one end
  end
  if type(decoded) ~= "table" then return { tostring(value) } end
  return M.pretty(decoded, o)
end

-- ---- a managed operation's answer ------------------------------------------------
--
-- `await tools.bash(...)` returns the node's OWN operation object (the host's `bash` capability):
-- `operation_id`, `state`, `stdout`, `stderr`, `code`, `cwd`, `containment`, `timing`, `stdout_path`,
-- ... Drawn whole that is ~30 rows of transport metadata where the reader asked what the command said
-- (measured on the parity golden, fixtures/raw-default/base-op-block.json: one row of
-- `{"cleanup":"terminated","cleanup_budget_ms":1000,...` and `… +1483 chars`).
--
-- So the block shows the command's OWN OUTPUT, and the object stays whole in two places it always was:
-- `tail_rows`' fold (`rows.expand`, one click in the host) and `/console`, which prints the result the
-- model received. Recognised by an ALLOW-LIST - an operation id AND an output string - so a value that
-- merely has a `state` or a `code` (a parsed JSON answer, a status object) is still drawn whole.
M.OPERATION_PREVIEW_ROWS = 6

function M.operation_of(value)
  -- The value arrives in TWO shapes, both real: a table (a fixture, or a caller that decoded it) and
  -- the JSON STRING a script's return crosses the sandbox boundary as (measured on the parity capture:
  -- `value` was `{"cleanup":"terminated",...(1657 chars)}`, not a table). One decoder, then the same
  -- allow-list, so the two shapes cannot be drawn differently.
  if type(value) == "string" then
    local first = value:match("^%s*(.)") or ""
    if first ~= "{" then return nil end
    local ok, decoded = pcall(json.decode, value)
    if not ok or type(decoded) ~= "table" then return nil end
    value = decoded
  end
  if type(value) ~= "table" then return nil end
  if type(value.operation_id) ~= "string" or value.operation_id == "" then return nil end
  if type(value.stdout) ~= "string" and type(value.stderr) ~= "string" then return nil end
  return value
end

-- The rows of the operation's own output: stdout, or stderr when stdout is blank (a failed command
-- answers through stderr), at most M.OPERATION_PREVIEW_ROWS non-blank lines. Returns those rows and
-- how many non-blank lines were left out.
function M.operation_preview(operation, width, o)
  o = M.opts(o)
  local text = tostring(operation.stdout or "")
  if text:gsub("%s", "") == "" then text = tostring(operation.stderr or "") end
  local rows, hidden = {}, 0
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    if line:gsub("%s", "") ~= "" then
      if #rows < M.OPERATION_PREVIEW_ROWS then rows[#rows + 1] = line else hidden = hidden + 1 end
    end
  end
  return rows, hidden
end

-- The one dim row that names the operation without becoming a second answer: how it ended, how long,
-- its exit code, a short id - and where the whole object is. Never the JSON.
function M.operation_note(operation, o, hidden)
  o = M.opts(o)
  local parts = { "operation " .. tostring(operation.operation_id):sub(1, 11) }
  local state = operation.state or (operation.ok == false and "failed" or nil)
  if state then parts[#parts + 1] = tostring(state) end
  local exit = operation.process_exit_code
  if exit == nil then exit = operation.code end
  if exit ~= nil then parts[#parts + 1] = "exit " .. tostring(exit) end
  local ms = operation.elapsed_ms or (type(operation.timing) == "table" and operation.timing.measured_ms) or nil
  if ms ~= nil then parts[#parts + 1] = o.elapsed(tonumber(ms) or 0) end
  local text = table.concat(parts, " \194\183 ")
  if hidden and hidden > 0 then
    text = text .. " \194\183 \226\128\166 +" .. tostring(hidden) .. " lines"
  end
  return text .. " \194\183 the whole result is in /console"
end

-- The value as the reader should see it: one row per line of pretty JSON, cut to `M.RESULT_ROWS`,
-- with the count of what it left out. A string value is its own text rather than a quoted one.
function M.result_rows(model, width, o)
  o = o or M.opts()
  local rows, hidden = {}, 0
  local lines
  if model.value ~= nil then
    local value = M.decoded(model.value)
    if type(value) == "table" then
      -- Readable first (an operation becomes its output), then the evidence pointers hidden.
      lines = M.pretty(M.hide_evidence(M.readable(value, o)), o)
    else
      lines = {}
      for line in (tostring(value):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
      end
    end
  elseif model.error then
    lines = { tostring(model.error) }
  end
  if lines == nil then return rows, 0 end
  local whole = {}
  for _, line in ipairs(lines) do
    if line:gsub("%s", "") ~= "" then whole[#whole + 1] = line end
  end
  if #whole == 0 then return rows, 0 end
  for index, line in ipairs(whole) do
    if index <= M.RESULT_ROWS then rows[#rows + 1] = line else hidden = hidden + 1 end
  end
  if hidden > 0 then rows.whole = table.concat(whole, "\n") end
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


-- `text` cut into rows of at most `limit` display columns, on UTF-8 boundaries, nothing dropped and no
-- `…` (operator 17/11: "each step shows its output completely"). A row that is exactly as wide as the
-- transcript is wrapped AGAIN by it, which is what drew a blank band row under every code line - the
-- caller leaves one column free.
-- THE one wrapper: every component that breaks a long piece of text into rows calls this.
--
-- It breaks at the last SPACE that fits, and inside a word only when that word alone is wider than
-- the row (a URL, a hash, a schema). It used to cut at the exact cell, which is what Victor's
-- screenshot of 19/11 11:15 shows in his own message bubbles: “nee|d”, “he|re”, “notati|on”,
-- “lin|e” - a reader's sentence chopped mid-word at the margin, on every row.
--
-- Cells, not bytes, are what the limit counts, and it walks the string one CHARACTER at a time with
-- its byte width, so a multi-byte character is never split.
-- A CODE LINE cut by CELLS: the exact column, no regard for words.
--
-- Code is not prose (review, item D): breaking it at a space DROPS that space and changes what the
-- reader sees the line say. A statement is cut where it stops fitting, with M.wrap_marked marking
-- the break so the pieces read as one line. Prose uses M.wrap; code uses this.
function M.wrap_cells(text, limit, o)
  o = M.opts(o)
  local value = tostring(text or "")
  limit = math.max(8, tonumber(limit) or 80)
  if o.columns(value) <= limit then return { value } end
  local rows, start, used, index = {}, 1, 0, 1
  while index <= #value do
    local byte = value:byte(index)
    local size = (byte >= 240 and 4) or (byte >= 224 and 3) or (byte >= 192 and 2) or 1
    local piece = value:sub(index, index + size - 1)
    local cells = o.columns(piece)
    if used + cells > limit and index > start then
      rows[#rows + 1] = value:sub(start, index - 1)
      start, used = index, 0
    end
    used = used + cells
    index = index + size
  end
  if start <= #value then rows[#rows + 1] = value:sub(start) end
  return rows
end

function M.wrap(text, limit, o)
  o = M.opts(o)
  local value = tostring(text or "")
  limit = math.max(8, tonumber(limit) or 80)
  if o.columns(value) <= limit then return { value } end
  -- One entry per character, with its byte range and its width: the rows are cut between entries,
  -- never inside one.
  local chars, index = {}, 1
  while index <= #value do
    local byte = value:byte(index)
    local size = (byte >= 240 and 4) or (byte >= 224 and 3) or (byte >= 192 and 2) or 1
    local piece = value:sub(index, index + size - 1)
    chars[#chars + 1] = { start = index, size = size, cells = o.columns(piece), space = piece == " " }
    index = index + size
  end
  local function text_of(from, to)
    if to < from then return "" end
    return value:sub(chars[from].start, chars[to].start + chars[to].size - 1)
  end
  local rows, first = {}, 1
  while first <= #chars do
    -- How far this row reaches: every character that fits, and where the last space in it was.
    local used, last_fit, last_space = 0, first - 1, nil
    local cursor = first
    while cursor <= #chars do
      local cells = chars[cursor].cells
      if used + cells > limit and cursor > first then break end
      used = used + cells
      if chars[cursor].space then last_space = cursor end
      last_fit = cursor
      cursor = cursor + 1
    end
    local stop, next_first = last_fit, last_fit + 1
    if cursor <= #chars and last_space and last_space > first then
      -- Break AT the space and swallow it: the next row starts on the word that follows, and the
      -- space itself is the break, never a leading blank in the row below.
      stop = last_space - 1
      next_first = last_space + 1
      while next_first <= #chars and chars[next_first].space do next_first = next_first + 1 end
    end
    if stop < first then stop = first end
    rows[#rows + 1] = text_of(first, stop)
    first = next_first
  end
  return rows
end

-- A LINE OF CODE THAT DOES NOT FIT, WRAPPED WITH A MARK WHERE IT BREAKS.
--
-- A 300-column line at 80 columns used to come out as four band rows with nothing joining them: the
-- reader saw a token cut in half with a row of fresh code under it and could not tell a wrap from a
-- new statement (round 3, item 3). Every piece but the last now ends with `↪` IN ITS LAST CELL - at
-- the wrap point, which is where the line continues - so four rows read as one line broken three times.
--
-- The row COUNT is the wrap: one piece is one screen row, and the mark is paid for out of the width
-- rather than added to it, so a marked row is never wider than the band and the transcript never wraps
-- it again (which is what drew a blank band row under every code line before 17/11).
--
-- A line that fits is returned as it is, unmarked and one row: wrapping at `limit - 1` first would turn
-- a line of exactly `limit` cells into two rows that both fit on one.
function M.wrap_marked(text, limit, o, mark)
  o = M.opts(o)
  mark = mark or "\226\134\170"
  limit = math.max(8, tonumber(limit) or 80)
  local whole = M.wrap_cells(text, limit, o)
  if #whole <= 1 then return whole end
  local room = math.max(1, limit - o.columns(mark))
  local pieces = M.wrap_cells(text, room, o)
  if #pieces <= 1 then return pieces end
  for index = 1, #pieces - 1 do pieces[index] = pieces[index] .. mark end
  return pieces
end

-- The call rows as the transcript draws them: one row per call (or per fan-out), the ✓/✗/⏳ mark in
-- its own colour. This is the row a running block rewrites in place as each call settles
-- (`host.transcript_rewrite`), so it is built by one function and nothing else.
function M.call_lines(model, width, o)
  o = M.opts(o)
  local rows = {}
  for _, entry in ipairs(M.call_entries(model, width, o)) do
    if entry.kind == "content" then
      -- A command's own words, dim: evidence for the row above, not a verdict of their own.
      rows[#rows + 1] = o.paint(entry.text, "dim")
    else
      -- The whole row in its state's colour (operator 17/11): waiting light yellow, done light green,
      -- failed soft red. MARK_OK/MARK_NO/MARK_WAIT are 3 bytes each.
      local mark = entry.text:sub(1, 3)
      local style = (mark == MARK_NO and "callFail") or (mark == MARK_WAIT and "callWait")
        or (mark == MARK_OK and "callOk") or "dim"
      rows[#rows + 1] = o.paint("  " .. entry.text, style)
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
  -- No title: the block is the code, on its band. What the script called is said on the call rows
  -- inside it (`✓ bash · …`), so a heading above the code only repeated them.
  local rows = {}
  local code, code_hidden = M.script_rows(model.args, math.huge)
  -- No inset: the code starts at the band's left edge (operator 17/11), and the band ends one column
  -- short of the screen, where the transcript's scrollbar is drawn.
  local band = math.max(8, width - 1)
  local pieces = {}
  for _, line in ipairs(code) do
    -- Wrapped, never clipped, and BEFORE it is highlighted: cutting a string that already carries
    -- escape sequences would cut one in half, and a cut token paints the rest of the block. A line
    -- that continues onto the next band row says so at the break (`M.wrap_marked`).
    for _, piece in ipairs(M.wrap_marked(line, band, o)) do pieces[#pieces + 1] = piece end
  end
  for _, shown in ipairs(pieces) do
    -- The band is padded by display columns (not bytes) to one column short of the screen, so it is a
    -- band and the transcript never wraps it into an empty second row.
    if o.live and o.syntax then
      -- The band is re-applied around every token: `paint` ends each piece with a reset, so a band
      -- painted once around the row would stop at the first coloured token. Padding to the full width
      -- is what makes it a band instead of a ragged stripe.
      local parts = {}
      o.syntax(shown, "js", function(piece, style)
        if piece == "" then return end
        parts[#parts + 1] = o.paint(piece, { "codeBand", style or "mdCodeBlock" })
      end)
      -- The rest of the ROW is painted by EL (ESC[K) in the band colour, never by a run of spaces
      -- (item F, Victor 19/11 11:20). Padding is characters: a narrow terminal re-wraps them, so on a
      -- resize a painted block came apart into ragged fragments. EL erases with the CURRENT
      -- background, so the row is solid and carries no trailing blanks at all. The band stays active
      -- after the erase on purpose - the host draws a code block's copy icon on that right-hand cell,
      -- and it must wear the band, not the terminal default - and the transcript resets the row when
      -- it draws it.
      parts[#parts + 1] = o.band_erase()
      rows[#rows + 1] = table.concat(parts)
    else
      rows[#rows + 1] = shown
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
  -- A managed operation is drawn as its OUTPUT; the object itself is the fold and /console (above).
  local operation = model.value ~= nil and M.operation_of(model.value) or nil
  local operation_rows, operation_hidden
  if operation then
    value, value_hidden = M.operation_preview(operation, width, o), 0
    -- The fold under the preview is the WHOLE object as the node carried it (ids, paths, timing and
    -- all): never drawn by default, always explorable (Victor 21/11).
    operation_rows, operation_hidden = M.raw_rows(model.value, o), 0
  end
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
  local first = true
  local style = model.error and not model.value and "error" or "dim"
  for _, line in ipairs(value) do
    for _, piece in ipairs(M.wrap(line, width - 5, o)) do
      rows[#rows + 1] = (first and o.paint(lead, "muted") or "  ") .. o.paint(piece, style)
      first = false
    end
  end
  -- Folded (operator 17/11): where the host can open a row on a click, a value longer than one row is
  -- ONE row - its start, then `… +N chars` - and the full rows are what the click shows. An operation
  -- is NOT folded here: the operator asked for its first lines ("results are a compact preview"), and
  -- the whole object rides on the same `rows.expand` below.
  if not operation and o.expandable and #rows > 1 then
    local whole = value.whole or table.concat(value, " ")
    local room = math.max(8, width - 5 - 16)
    local shown = M.wrap(whole, room, o)[1] or ""
    local rest = o.columns(whole) - o.columns(shown)
    local full = value.whole or table.concat(M.raw_rows(model.value, o), "\n")
    rows = { o.paint(lead, "muted") .. o.paint(shown, style) .. o.paint(" \226\128\166 +" .. rest .. " chars", "muted") }
    rows.expand = { [1] = full }
  end
  if value_hidden > 0 then
    rows[#rows + 1] = o.paint("  \226\128\166 +" .. value_hidden .. " lines (/console shows all)", "dim")
  end
  if operation then
    rows[#rows + 1] = o.paint("  " .. M.operation_note(operation, o, operation_hidden), "dim")
    -- The whole object, one click away - the same mechanism a long value uses (`rows.expand`), which
    -- the host draws only where it has a transcript to expand into.
    if operation_rows and (operation_hidden or 0) + #operation_rows > 0 then
      rows.expand = { [1] = table.concat(operation_rows, "\n") }
    end
  end
  local evidence = M.evidence_text(model.evidence or M.find_evidence(model.value), o)
  if evidence == nil and M.hidden_evidence(model) then
    evidence = "evidence: pointer kept (/console has it)"
  end
  if evidence then
    for _, piece in ipairs(M.wrap(evidence, width - 3, o)) do rows[#rows + 1] = o.paint("  " .. piece, "dim") end
  end
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
  -- No modality word in the folded line either: the block above it has none, and the tools are what
  -- the reader is asking about ("what ran, and did it work").
  local parts = { "\226\143\186 " .. (names ~= "" and (names .. " " .. mark) or mark) }
  if model.seconds then parts[#parts + 1] = o.elapsed(model.seconds * 1000) end
  local text = table.concat(parts, " \194\183 ")
  local value = M.decoded(model.value)
  if type(value) == "table" then value = M.hide_evidence(M.readable(value, o)) end
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
