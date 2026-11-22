-- What a code-mode block looks like, as a snapshot, at 80x24 and 120x40 - and the one boundary this
-- change must not cross: the model-facing tool result is byte-identical with a view listening.
--
-- Operator, 13/11 ~07:30: "i like your code mode suggestion ... once a new codemode starts running we
-- collapse that expanded and stream the new expanded". So there are two halves and this file pins the
-- one that decides the TEXT (`lua/core/codemode_block.lua`), at both screen sizes, for the seven
-- states the design names:
--
--   one call ok | one call failed (web_http_429) | Promise.all of 10, mixed | a pending call |
--   two consecutive blocks (first collapsed, second expanded) | a pinned block surviving a newer one |
--   a long script collapsed
--
-- The fold itself (which block is drawn expanded, what Ctrl+O pins) is the host's and is pinned in
-- `rust/wa-term/src/transcript.rs`; what this file asserts is exactly the rows the host is given -
-- the summary row a collapsed block shrinks to is `M.summary`, the rows an open block shows are
-- `M.lines` - so a change to either side shows up here or there, never nowhere.
--
-- `WA_CODEMODE_SNAPSHOT_UPDATE=1` rewrites `fixtures/codemode-blocks.txt` from the current renderer;
-- every other run compares against it. A snapshot that is regenerated without being read is not a
-- check, so the file is a fixture in the diff, not an artifact.
local json = dofile('lua/vendor/json.lua')
local block = dofile('lua/core/codemode_block.lua')
local markdown = dofile('lua/core/markdown.lua')

local checks, failed = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then failed = failed + 1; print('FAIL ' .. label) end
end
local function eq(actual, expected, label)
  check(actual == expected, label .. ' (got ' .. tostring(actual) .. ', wanted ' .. tostring(expected) .. ')')
end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

-- The plain rendering: the same text without colour. `paint` is not supplied, so every row is the
-- string a terminal would show with colour off - which is what a snapshot can diff.
local function opts()
  return { live = false, columns = markdown.columns, clip = function(text, limit)
    local value = tostring(text or '')
    if not limit or limit <= 0 or #value <= limit then return value end
    return value:sub(1, math.max(1, limit - 1)) .. '\226\128\166'
  end, summarise = function(name, args)
    local a = type(args) == 'table' and args or {}
    if name == 'bash' then return '$ ' .. tostring(a.command or '') end
    if name == 'web_read' then return tostring(a.url or '') end
    if name == 'mcp_whatsapp_send' then return 'to=' .. tostring(a.to or '') end
    return tostring(a.path or a.url or a.query or '')
  end, elapsed = function(ms)
    local value = tonumber(ms) or 0
    if value < 1000 then return string.format('%dms', math.floor(value)) end
    return string.format('%.1fs', value / 1000)
  end, encode = function(value) return json.encode(value) end }
end

local SHORT = "const files = await tools.ls({path: 'lua/core'});\n"
  .. "await tools.read({path: 'lua/core/chat.lua'});\n"
  .. "return {count: 2, first: 'chat.lua'};"

-- ---- the seven states -------------------------------------------------------------

local cases = {}

-- 1. one call, it worked.
do
  local model = block.new({ code = SHORT }, 0)
  block.settle(model, block.begin_call(model, 'c1', 'bash', { command = 'ls lua/core' }).id, { ok = true, ms = 210 })
  block.finish(model, { ok = true, value = { count = 2, first = 'chat.lua' } }, 1.2)
  cases[#cases + 1] = { name = 'one call ok', model = model }
end

-- 2. one call, it failed with a code the reader can act on.
do
  local model = block.new({ code = "await tools.web_read({url: 'https://example.com'});" }, 0)
  block.settle(model, block.begin_call(model, 'c1', 'web_read', { url = 'https://example.com' }).id,
    { ok = false, ms = 420, error = 'web_http_429', code = 'web_http_429' })
  block.finish(model, { ok = false, error = 'web_http_429' }, 0.4)
  cases[#cases + 1] = { name = 'one call failed web_http_429', model = model }
end

-- 3. a Promise.all fan-out: one row, not ten, with the live counts.
do
  local model = block.new({ code = "const out = await Promise.all(paths.map(p => tools.bash({command: 'wc -l ' + p})));\nreturn out.length;" }, 0)
  for index = 1, 10 do
    local call = block.begin_call(model, 'p' .. index, 'bash', { command = 'wc -l src/f' .. index .. '.txt' })
    if index == 10 then block.settle(model, call.id, { ok = false, ms = 300, error = 'exit_1', code = 'exit_1' })
    else block.settle(model, call.id, { ok = true, ms = 100 + index * 10 }) end
  end
  block.finish(model, { ok = false, value = 10 }, 1.35)
  cases[#cases + 1] = { name = 'promise.all of 10 mixed', model = model }
end

-- 4. a call still in flight: a pending handle is ⏳, not a failure and not a success.
do
  local model = block.new({ code = "const r = await tools.mcp_whatsapp_send({to: 'me', text: 'hi'});\nreturn r;" }, 0)
  block.pending(model, block.begin_call(model, 'h1', 'mcp_whatsapp_send', { to = 'me' }).id, 'op-77')
  block.finish(model, { ok = true, value = 1 }, 0.3)
  cases[#cases + 1] = { name = 'a pending call', model = model }
end

-- 5. two consecutive blocks: the first collapsed to its summary, the second open.
do
  local first = block.new({ code = SHORT }, 0)
  block.settle(first, block.begin_call(first, 'c1', 'bash', { command = 'ls lua/core' }).id, { ok = true, ms = 210 })
  block.finish(first, { ok = true, value = { count = 2, first = 'chat.lua' } }, 1.2)
  local second = block.new({ code = "const hits = await tools.grep({pattern: 'TODO'});\nreturn hits.count;" }, 1.2)
  block.settle(second, block.begin_call(second, 'c2', 'grep', { pattern = 'TODO' }).id, { ok = true, ms = 90 })
  block.finish(second, { ok = true, value = 4 }, 1.5)
  cases[#cases + 1] = { name = 'two consecutive blocks', model = second, collapsed = first }
end

-- 6. a pinned block: the first keeps every row while the newer one runs.
do
  local first = block.new({ code = SHORT }, 0)
  block.settle(first, block.begin_call(first, 'c1', 'bash', { command = 'ls lua/core' }).id, { ok = true, ms = 210 })
  block.finish(first, { ok = true, value = { count = 2, first = 'chat.lua' } }, 1.2)
  local second = block.new({ code = "return 1;" }, 1.2)
  block.settle(second, block.begin_call(second, 'c2', 'bash', { command = 'true' }).id, { ok = true, ms = 40 })
  block.finish(second, { ok = true, value = 1 }, 1.3)
  cases[#cases + 1] = { name = 'a pinned block survives a newer one', model = second, pinned = first }
end

-- 7. a long script: six rows and the count of what the fold keeps back.
do
  local long = {}
  for index = 1, 12 do long[#long + 1] = 'const v' .. index .. ' = await tools.read({path: ' .. "'f" .. index .. ".txt'});" end
  long[#long + 1] = 'return v1;'
  local model = block.new({ code = table.concat(long, '\n') }, 0)
  block.finish(model, { ok = true, value = 'alpha' }, 0.05)
  cases[#cases + 1] = { name = 'a long script collapsed', model = model }
end

-- ---- the snapshot ---------------------------------------------------------------

local SIZES = { { width = 80, rows = 24 }, { width = 120, rows = 40 } }
local lines = {}
local function emit(text) lines[#lines + 1] = text end

for _, case in ipairs(cases) do
  for _, size in ipairs(SIZES) do
    emit(string.format('### %s @ %dx%d', case.name, size.width, size.rows))
    local o = opts()
    -- A collapsed block is ONE row: the summary the next block leaves it with.
    if case.collapsed then emit(block.summary(case.collapsed, size.width, o)) end
    -- A pinned block keeps every row it had.
    if case.pinned then
      for _, row in ipairs(block.lines(case.pinned, size.width, o)) do emit(row) end
    end
    for _, row in ipairs(block.lines(case.model, size.width, o)) do emit(row) end
    emit('')
  end
end
local rendered = table.concat(lines, '\n') .. '\n'

local path = 'fixtures/codemode-blocks.txt'
if (host.getenv('WA_CODEMODE_SNAPSHOT_UPDATE') or '') == '1' then
  assert(host.write_file(path, rendered), 'the snapshot could not be written')
  print(string.format('codemode blocks: wrote %s (%d lines)', path, #lines))
  os.exit(0)
end
local expected = assert(host.read_file(path), 'fixtures/codemode-blocks.txt must be readable from the repository root')
eq(rendered, expected, 'the rendered blocks are the committed snapshot')

-- A long value folds to ONE row where the host can open it (operator 17/11), and the full rows ride along.
do
  local o = opts()
  o.expandable = true
  local model = block.new({ code = 'return big;' }, 0)
  local long = {}
  for i = 1, 40 do long[#long + 1] = 'item' .. i end
  block.finish(model, { ok = true, value = { list = long } }, 0.1)
  local tail = block.tail_rows(model, 80, o)
  check(#tail >= 1 and tail[1]:find('chars', 1, true) and tail[1]:find('\226\128\166 %+%d+ chars') ~= nil, 'folded to one row ending … +N chars: ' .. tostring(tail[1]))
  check(tail.expand and tail.expand[1] and tail.expand[1]:find('item40', 1, true), 'and the click shows the whole value')
  o.expandable = false
  local plainrows = block.tail_rows(model, 80, o)
  check(#plainrows > 1 and not plainrows.expand, 'without the host capability the whole value is shown')
  -- Call rows in their state colour: waiting yellow, done green, failed soft red.
  local painted = {}
  local po = opts(); po.paint = function(text, style) painted[#painted + 1] = style; return text end
  local m2 = block.new({ code = 'x' }, 0)
  block.begin_call(m2, 'a', 'bash', {}); block.begin_call(m2, 'b', 'read', {})
  block.settle(m2, 'b', { ok = true, ms = 3 })
  block.call_lines(m2, 80, po)
  check(painted[1] == 'callWait' and painted[2] == 'callOk', 'call rows: waiting callWait, done callOk: ' .. table.concat(painted, ','))
end

-- The snapshot says what it looks like; these say why, so a failure names the rule that broke.
do
  local o = opts()
  local ok_case = cases[1].model
  local heading = block.head(ok_case, 80, o)
  eq(markdown.columns(heading), 80, 'the heading fills the width it was given')
  check(has(heading, 'Code · bash'), 'the heading names the tool the script called')
  check(not has(heading, 'const'), 'and never the code')
  check(has(heading, '1.2s'), 'with the call\'s total time')
  check(heading:sub(-4) == '1.2s', 'right-aligned, as the last thing on the row')

  local failed_case = cases[2].model
  eq(block.verdict(failed_case, o), '\226\156\151 web_http_429', 'a failed script says which code')
  eq(block.verdict(ok_case, o), '\226\156\147', 'a successful one says so with a tick')
  eq(block.verdict(cases[4].model, o), '\226\143\179 pending', 'and one holding a handle says pending')

  local fan = cases[3].model
  local rows = block.call_rows(fan, 80, o)
  eq(#rows, 1, 'ten calls of one tool are ONE row')
  check(has(rows[1], 'bash \195\15110') and has(rows[1], '\226\156\1479') and has(rows[1], '\226\156\1511'),
    'with the counts: ' .. tostring(rows[1]))

  local long_rows, long_hidden = block.script_rows({ code = cases[7].model.args.code }, block.CODE_ROWS)
  eq(#long_rows, 6, 'a long script is six rows')
  eq(long_hidden, 7, 'and the other seven are counted')

  -- The evidence envelope: never the value, never its path in the block, named once instead.
  local envelope = block.new({ code = 'return r;' }, 0)
  block.finish(envelope, { ok = true, value = { operation_id = 'op-9', evidence = { bytes = 2473,
    path = '/home/agent/.wasm-agent/mcp/requests/op-9.json', sha256 = '5f2a1c9d8e7b6a5f4e3d2c1b' } } }, 0.1)
  local shown = table.concat(block.lines(envelope, 100, o), '\n')
  check(has(shown, '…evidence'), 'an evidence envelope is replaced in the value: ' .. shown)
  check(not has(shown, '/home/agent/.wasm-agent/mcp/requests'), 'its path is not in the block')
  check(has(shown, 'evidence: 2473 B · sha 5f2a1c9d'), 'it is named once, with its size and digest')
  check(has(shown, '/console has the path'), 'and says where the whole of it is')

  -- The summary a collapsed block shrinks to: one row, and it fits the width it is given.
  local summary = block.summary(ok_case, 80, o)
  eq(#summary:gsub('\n', ''), #summary, 'a summary is one row')
  check(#summary <= 80, 'that fits the width: ' .. #summary)
  check(has(summary, 'bash') and has(summary, '\226\156\147') and has(summary, '1.2s')
    and has(summary, '\226\134\146'), 'and carries the tools, the verdict, the time and the value: ' .. summary)
  local failed_summary = block.summary(failed_case, 80, o)
  check(has(failed_summary, '\226\156\151 web_http_429'), 'a collapsed FAILURE keeps its code: ' .. failed_summary)
  eq(block.summary_style(failed_case), 'error', 'and the row is painted as an error')
end

-- ---- the model-facing result is byte-identical with a view listening ----------------
-- The whole point of the presentation work is that it is presentation: a run, a peer or a subagent
-- has no view, so the tool must answer the same bytes either way. Two runs of one script in two
-- sessions - the second with an `emit` that records what it is told - compared as the exact JSON the
-- model receives.
do
  local ready = false
  if type(host.quickjs) == 'function' then
    local ok, raw = pcall(host.quickjs, 'ready', '{}')
    if ok then
      local decoded = json.decode(raw)
      ready = type(decoded) == 'table' and decoded.ok == true
    end
  end
  if not ready then
    print('SKIP model-facing bytes: this node has no embedded code-mode assets')
  else
    local env = host.getenv
    host.getenv = function(k) if k == 'WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
    local memory = dofile('lua/core/memory.lua'); memory.setup()
    local tools = dofile('lua/core/tools.lua')
    local codemode = dofile('lua/core/codemode.lua')
    local root = dofile('lua/core/paths.lua').data() .. '/codemode-blocks'
    assert(host.write_file(root .. '/a.txt', 'alpha'))
    local function run(code, extra)
      local sid = memory.start_session('', 'codemode blocks boundary', { user_id = 'master' })
      memory.set_session_workspace(sid, { required = true, state = 'allocated', worktree = root })
      local ctx = { session_id = sid, user_id = 'master' }
      for key, value in pairs(extra or {}) do ctx[key] = value end
      local catalog = tools.all('master', ctx, memory)
      local execution = tools.discovery_execution(memory, ctx)
      local function dispatch(name, params, raw) return tools.dispatch(memory, name, params, 'master', ctx) end
      local result = codemode.run(memory, { code = code }, 'master', ctx, catalog, function() return catalog end,
        dispatch, execution)
      return result
    end
    local SCRIPT = "const a = await tools.read({path: 'a.txt'});\n"
      .. "await tools.write({path: 'b.txt', content: 'beta'});\n"
      .. "return a.content;"
    local quiet = run(SCRIPT)
    local heard = {}
    local watched = run(SCRIPT, { emit = function(event) heard[#heard + 1] = event end })
    eq(json.encode(watched), json.encode(quiet), 'the model-facing result is the same bytes with a view listening')
    check(type(quiet) == 'table' and quiet.ok == true, 'and the script really ran: ' .. tostring(quiet and quiet.error))
    check(#heard > 0, 'the view was told about the calls')
    local states = {}
    for _, event in ipairs(heard) do states[event.state or '?'] = true end
    check(states.running == true and states.ok == true, 'each call started and settled: ' .. json.encode(heard[1] or {}))
    check(json.encode(quiet.calls) == json.encode(watched.calls), 'the call journal is unchanged too')
    -- The call's own CONTENT reaches the view, and the envelope it came in does not (Victor 21/11:
    -- "under each tool row draw that call's CONTENT ... The operation envelope (ids, paths, timing,
    -- owner, flags) is NOT content"). The script really runs a command here: a view that is handed
    -- the output is tested on the output the node really produced.
    local bash_heard = {}
    local ran = run("return (await tools.bash({command: 'printf hi'})).stdout;",
      { emit = function(event) bash_heard[#bash_heard + 1] = event end })
    check(type(ran) == 'table' and ran.ok == true, 'a bash call inside a script ran: ' .. tostring(ran and ran.error))
    local settle_event
    for _, event in ipairs(bash_heard) do
      if event.type == 'codemode_call' and event.state == 'ok' then settle_event = event end
    end
    check(settle_event ~= nil, 'the settled call reached the view: ' .. json.encode(bash_heard))
    check(settle_event and type(settle_event.output) == 'table' and settle_event.output.stdout == 'hi',
      'the view is handed the command\'s own output: ' .. json.encode(settle_event or {}))
    check(settle_event and settle_event.stdout == nil and settle_event.operation_id == nil
      and settle_event.owner == nil and settle_event.timing == nil,
      'and the envelope stays behind: ' .. json.encode(settle_event or {}))

  end
end


-- ---- a call's own content, and a value that is not a blob -----------------------------------
-- Victor 21/11: "under each tool row draw that call's CONTENT: its stdout (and stderr if any,
-- dimmed), up to a few lines with +N lines folded ... The operation envelope (ids, paths, timing,
-- owner, flags) is NOT content" and "the script's return value is drawn compactly (pretty,
-- truncated), never as a wrapped 4 KB blob". The rows here are the ones the transcript draws - the
-- same function, not a second renderer.
do
  local b = dofile('lua/core/codemode_block.lua')
  local o = opts()
  -- The operation the bash capability really answers with, every envelope field included.
  local op = { operation_id = 'op-1795000000000000-1-7', state = 'completed', ok = true,
    stdout = '1\n2\n3\n', stderr = '', code = 0, process_exit_code = 0, elapsed_ms = 7,
    owner = '51fc9f12', owner_boot = 'boot-2935946', owner_process_id = 2935946,
    stdout_path = '/home/victor/.wasm-agent/operations/op-7/stdout', cleanup = 'terminated',
    containment = 'posix_process_group', stdout_omitted = 6, output_omitted = true,
    timing = { measured_ms = 7, schema_version = 1 } }
  local model = b.new({ code = 'const a = await tools.bash({command: "seq 1 3"});\nreturn {seq: a};' }, 0)
  b.begin_call(model, 'c1', 'bash', { command = 'seq 1 3' })
  -- The running row says nothing yet: a call in flight has no output to show.
  eq(#b.call_rows(model, 100, o), 1, 'a running call is one row and no content')
  b.settle(model, 'c1', { ok = true, ms = 7, output = { stdout = op.stdout, stderr = op.stderr } })
  local rows = b.call_rows(model, 100, o)
  eq(#rows, 4, 'the settled call is its row plus the three lines it printed: ' .. table.concat(rows, '|'))
  check(has(rows[1], '\226\156\147 bash'), 'the row is the call, ticked: ' .. tostring(rows[1]))
  eq((rows[2]:gsub('^%s+', '')), '1', 'and under it, the command\'s first line: ' .. tostring(rows[2]))
  eq((rows[3]:gsub('^%s+', '')), '2', 'then the second')
  eq((rows[4]:gsub('^%s+', '')), '3', 'then the third')
  local drawn = table.concat(b.call_lines(model, 100, o), '\n')
  check(not has(drawn, 'operation_id') and not has(drawn, 'owner_boot') and not has(drawn, 'stdout_path')
    and not has(drawn, 'containment') and not has(drawn, 'output_omitted'),
    'the operation envelope is not content and is never drawn: ' .. drawn)

  -- More lines than M.CALL_CONTENT_ROWS fold, and the fold says how many were left out.
  local long_stdout = {}
  for i = 1, 30 do long_stdout[#long_stdout + 1] = 'line' .. i end
  local m2 = b.new({ code = 'x' }, 0)
  b.begin_call(m2, 'c1', 'bash', { command = 'seq 1 30' })
  b.settle(m2, 'c1', { ok = true, ms = 3, output = { stdout = table.concat(long_stdout, '\n') .. '\n', stderr = '' } })
  local folded = b.call_rows(m2, 100, o)
  eq(#folded, 1 + b.CALL_CONTENT_ROWS + 1, 'a call that printed 30 lines draws four and a fold')
  check(has(folded[#folded], '\226\128\166 +26 lines'), 'the fold counts the rest: ' .. tostring(folded[#folded]))

  -- A fan-out whose calls have content is one row per call (each with its own output), not a counter:
  -- a counter row cannot answer "what did each one say".
  local fan = b.new({ code = 'x' }, 0)
  b.begin_call(fan, 'a', 'bash', { command = 'seq 1 3' })
  b.begin_call(fan, 'b', 'bash', { command = 'uname -r' })
  b.settle(fan, 'a', { ok = true, ms = 5, output = { stdout = '1\n2\n3\n', stderr = '' } })
  b.settle(fan, 'b', { ok = true, ms = 6, output = { stdout = '7.2.15-1-omarchy\n', stderr = '' } })
  local frows = b.call_rows(fan, 100, o)
  check(has(table.concat(frows, '\n'), '7.2.15-1-omarchy'), 'each call of a fan-out shows its own output: '
    .. table.concat(frows, '|'))
  check(has(table.concat(frows, '\n'), 'uname') == false, 'and the rows stay call rows, not a counter')

  -- The VALUE: a script that returned a dictionary of two operations is drawn as what they SAID,
  -- pretty and compact, never as kilobytes of transport metadata.
  local value_model = b.new({ code = 'x' }, 0)
  b.finish(value_model, { ok = true, value = json.encode({ seq = op,
    uname = { operation_id = 'op-1795000000000001-2-9', state = 'completed', stdout = '7.2.15-1-omarchy\n',
      stderr = '', code = 0, owner_boot = 'boot-2935946',
      stdout_path = '/home/victor/.wasm-agent/operations/op-9/stdout' } }) }, 0.1)
  local vrows = b.tail_rows(value_model, 100, o)
  local vtext = table.concat(vrows, '\n')
  check(has(vtext, '1\\n2\\n3'), 'the value shows the operations\' own output: ' .. vtext)
  check(has(vtext, '7.2.15-1-omarchy'), 'both of them: ' .. vtext)
  check(not has(vtext, 'owner_boot') and not has(vtext, 'stdout_path') and not has(vtext, 'operation_id')
    and not has(vtext, 'schema_version'), 'and none of the envelope: ' .. vtext)
  check(#vtext < 400, 'the whole answer is under 400 bytes of rows, not four kilobytes: ' .. #vtext)

  -- A value longer than the cap is truncated with the count, and the whole of it is one click away.
  local big = {}
  for i = 1, 40 do big['key' .. i] = i end
  local big_model = b.new({ code = 'x' }, 0)
  b.finish(big_model, { ok = true, value = json.encode(big) }, 0.1)
  local brows = b.tail_rows(big_model, 100, o)
  check(#brows <= b.RESULT_ROWS + 2, 'a long value is truncated to its rows: ' .. #brows)
  local expandable = opts()
  expandable.expandable = false
  local capped = b.result_rows(big_model, 100, expandable)
  local _, hiddenv = b.result_rows(big_model, 100, expandable)
  check(hiddenv > 0, 'and says how many lines it left out: ' .. tostring(hiddenv))
end

-- A code line longer than the band wraps with a VISIBLE MARK at the break (round 3, item 3).
--
-- At 80 columns a 300-column line came out as several band rows with nothing joining them, so a reader
-- could not tell a wrap from a new statement. The mark is `\u21aa`, it sits in the last cell of every
-- piece but the last (which is the wrap point), and it is paid for out of the band's width - so the row
-- COUNT is the wrap and no marked row is wider than the band.
local block2 = dofile('lua/core/codemode_block.lua')
local o80 = opts()
local LONG = string.rep("abcdefghij", 30)  -- 300 columns of one line
local pieces = block2.wrap_marked(LONG, 79, o80)
check(#pieces > 1, "a 300-column line at 79 columns wraps (" .. #pieces .. " rows)")
local joined = 0
for index, piece in ipairs(pieces) do
  local cells = markdown.columns(piece)
  check(cells <= 79, "row " .. index .. " is no wider than the band (" .. cells .. ")")
  if index < #pieces then
    check(piece:sub(-3) == "\226\134\170", "row " .. index .. " ends with the continuation mark at the break")
    joined = joined + (cells - markdown.columns("\226\134\170"))
  else
    check(piece:sub(-3) ~= "\226\134\170", "the last row carries no mark: the line ends there")
    joined = joined + cells
  end
end
check(joined == markdown.columns(LONG), "the marks cost cells, not characters: the rows add up to the line ("
  .. joined .. " of " .. markdown.columns(LONG) .. ")")
check(table.concat(pieces, ""):gsub("\226\134\170", "") == LONG,
  "and nothing was dropped: the rows minus their marks are the line")
-- A line that FITS is one row and carries no mark: the mark must not turn a fitting line into two.
local fits = string.rep("x", 60)
local one = block2.wrap_marked(fits, 79, o80)
check(#one == 1 and one[1] == fits, "a line that fits is one unmarked row")
local exactly = string.rep("y", 79)
local edge = block2.wrap_marked(exactly, 79, o80)
check(#edge == 1 and edge[1] == exactly, "a line of exactly the band width is one unmarked row")
-- The block's own rows use it: the script rows of a block with a long line carry the mark, and the
-- count the transcript will draw is the number of rows this returns.
local long_model = { args = { code = "const a = " .. LONG .. ";" }, calls = {}, state = "done" }
local drawn = block2.rows(long_model, 80, o80)
local marked = 0
for _, row in ipairs(drawn) do
  if row:find("\226\134\170", 1, true) then marked = marked + 1 end
end
check(marked >= 1, "M.rows marks the wrapped rows of a long code line (" .. marked .. " marked)")

-- WHO CUTS A SCRIPT ROW: on the transcript's own call the row is stored WHOLE, with the band's fill
-- carried in a marker in front of it, and the host cuts it at the width it draws at
-- (`rust/wa-term/src/transcript.rs` `band_row` / `wrap_band`) - so a maximised window shows longer
-- rows and a shrunk one re-cuts them, and the continuation mark is the host's to draw, in the gutter
-- of the row the line goes on (Victor 22/11).
local hosted_opts = opts()
hosted_opts.live = true
hosted_opts.reflow = true
hosted_opts.syntax = markdown.scan_code
hosted_opts.band_erase = function() return "\27[48;2;23;23;23m\27[K" end
local LONG_LINE = "const a = " .. LONG .. ";"
local hosted_model = { args = { code = LONG_LINE }, calls = {}, state = 'done' }
local hosted = block2.rows(hosted_model, 80, hosted_opts)
check(#hosted == 1, "the transcript path stores a script line whole (one row, got " .. #hosted .. ")")
local hosted_row = tostring(hosted[1] or '')
local fill_mark, hosted_code = hosted_row:match("^\1b(.-)\1(.*)$")
check(fill_mark ~= nil, 'the row opens with the marker the host reads')
check(fill_mark == "\27[48;2;23;23;23m\27[K",
  'and the marker carries the band fill the host paints every cut row with: ' .. tostring(fill_mark))
check(hosted_code == LONG_LINE, 'the whole line travels, cell for cell: ' .. #tostring(hosted_code))
check(not has(hosted_code, "\226\134\170"), 'no mark is drawn where it was composed: the host draws it')
check(markdown.columns(hosted_code) > 80,
  'and it is wider than the 80-column band it was composed at (' .. markdown.columns(hosted_code) .. ')')

if failed > 0 then
  print(string.format('codemode blocks: %d failed of %d checks', failed, checks))
  os.exit(1)
end
print(string.format('codemode blocks ok (%d checks)', checks))
