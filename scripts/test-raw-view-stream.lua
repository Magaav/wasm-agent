-- WHAT THE VIEW DRAWS WHILE A RUN BLOCK IS BEING WRITTEN (operator, 21/11: "i want our wa agent (run
-- code) to draw the JS as it used to do in raw code channel, so we can see it in real time writing
-- js ... the promises waiting for coming back, the way to explore result").
--
-- Three things, each asserted where the reader actually sees it - in the rows the view hands the
-- transcript, during the turn and not only at its end:
--
--   1. the script's code lines are on screen BEFORE the closing fence arrives (the block streams);
--   2. every awaited tools.X(...) shows a WAITING row when it starts and that same row flips to
--      ✓ + its duration when the call returns;
--   3. a tool result that is a managed OPERATION is drawn as the command's own output, with the whole
--      object one click away (`transcript_expand`) - never as ~30 rows of transport metadata.
--
-- The transcript double below is the host's own rules, not a copy of them: scripts/replay-events.lua
-- is the double the whole suite already draws a run with.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local view_lib = dofile('lua/core/cli_view.lua')

local checks, failed = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then failed = failed + 1; print('FAIL ' .. label) end
end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end
-- The reader's text: the layout is what is asserted, so colour is taken out.
local function visible(text)
  return (tostring(text):gsub('\27%[[%d;]*m', ''):gsub('\27%[K', ''):gsub('\27%]2;[^\7]*\7', ''))
end

-- ---- the transcript double ----------------------------------------------------------------
local function fake_transcript()
  local blocks = { { topic = false, lines = {} } }
  local api = { blocks = blocks, expansions = {} }
  local function last() return blocks[#blocks] end
  api.block = function(topic, code)
    if #last().lines == 0 then last().topic, last().code = topic, code == true
    else blocks[#blocks + 1] = { topic = topic, code = code == true, lines = {} } end
    return true
  end
  api.write = function(text)
    for line in (tostring(text):gsub('\n$', '') .. '\n'):gmatch('([^\n]*)\n') do
      last().lines[#last().lines + 1] = line
    end
    return true
  end
  api.rewrite = function(offset, text)
    local index = #last().lines + offset + 1
    if not last().lines[index] then return false end
    last().lines[index] = tostring(text or '')
    return true
  end
  api.fold = function() return true end
  api.live = function() return true end
  api.head = function() return true end
  api.expand = function(payload)
    api.expansions[#api.expansions + 1] = payload
    return true
  end
  api.rows = function()
    local out = {}
    for _, block in ipairs(blocks) do
      for _, line in ipairs(block.lines) do out[#out + 1] = visible(line) end
    end
    return table.concat(out, '\n')
  end
  api.last_rows = function() return last().lines end
  api.all_blocks_text = function()
    local out = {}
    for _, block in ipairs(blocks) do
      for _, line in ipairs(block.lines) do out[#out + 1] = visible(line) end
    end
    return table.concat(out, '\n')
  end
  return api
end

local saved = { host.transcript_write, host.transcript_block, host.transcript_live, host.transcript_head,
  host.transcript_rewrite, host.transcript_fold, host.transcript_expand, host.input_editor }
local fake = fake_transcript()
host.transcript_block, host.transcript_write = fake.block, fake.write
host.transcript_live, host.transcript_head = fake.live, fake.head
host.transcript_rewrite, host.transcript_fold = fake.rewrite, fake.fold
host.transcript_expand = fake.expand
host.input_editor = function() return true end
local written = {}
local clock = { now = 100 }
local view = view_lib.new({ live = true, stdout = true, limit = 100, rows = function() return 40 end,
  out = function(text) written[#written + 1] = text end, now = function() return clock.now end })
view.screen = view_lib.screen_rows(40, true)
view.editor, view.editor_ready = true, true
view:prompt('wa> ')
view:run_started()

-- ---- 1. the script streams as it is written ------------------------------------------------
view:event({ type = 'delta', text = 'Let me look.\n\n``' })
view:event({ type = 'delta', text = '`js run\nconst files = await tools.ls({path: \'lua\'});\n' })
local mid = fake.all_blocks_text()
check(has(mid, "const files = await tools.ls"),
  'the first line is drawn while the block is still open: ' .. mid)
check(not has(mid, '```'), 'and the fence itself is never drawn as text: ' .. mid)
view:event({ type = 'delta', text = "const hits = files.filter(f => f.endsWith('.lua'));\n" })
mid = fake.all_blocks_text()
check(has(mid, 'const hits = files.filter'), 'the second line is drawn as its delta arrives: ' .. mid)
check(has(mid, 'const files = await tools.ls'),
  'and the block still holds the first line (the script is streamed, never redrawn row by row): ' .. mid)
-- The closing fence has NOT arrived. That is the property: the code is on screen before it can be.
check(not has(table.concat(written), '```js run\nconst files'),
  'no escaping copy of the script is printed as prose either: ' .. table.concat(written))

-- ---- 2. a call waits, then settles IN PLACE ------------------------------------------------
local calls = 'await tools.bash({command: \'ls lua\'});\nreturn hits.length;\n'
view:event({ type = 'delta', text = calls })
-- The closing fence, then the call event the loop emits for the block it read: in real use the block
-- is always named before its inner calls, which is what `self.code` is built from.
view:event({ type = 'delta', text = '```\n' })
view:event({ type = 'tool', name = 'codemode', call_id = 'block-1',
  arguments = { code = "const files = await tools.ls({path: 'lua'});\nconst hits = files.filter(f => f.endsWith('.lua'));\n"
    .. "await tools.bash({command: 'ls lua'});\nreturn hits.length;" } })
local before_call = #fake.last_rows()
view:event({ type = 'codemode_call', id = 'c1', name = 'bash',
  arguments = { command = 'ls lua' }, state = 'running' })
local rows = fake.last_rows()
check(#rows == before_call + 1, 'a call that starts adds exactly one row: ' .. tostring(#rows - before_call))
check(has(visible(rows[#rows]), 'bash'), 'the row names the tool the moment it starts: ' .. visible(rows[#rows]))
check(has(visible(rows[#rows]), '\226\143\179'),
  'and it is WAITING (the ⏳ mark), not done: ' .. visible(rows[#rows]))
check(not has(visible(rows[#rows]), '\226\156\147'),
  'a call still in flight is never drawn as a success: ' .. visible(rows[#rows]))
view:event({ type = 'codemode_call', id = 'c1', name = 'bash', state = 'ok', ms = 123 })
rows = fake.last_rows()
check(#rows == before_call + 1, 'settling rewrites that row, it does not add a second one')
check(has(visible(rows[#rows]), '\226\156\147 bash') and has(visible(rows[#rows]), '123ms'),
  'to ✓ with its duration: ' .. visible(rows[#rows]))

-- The answer the script computed.
clock.now = 100.5
view:event({ type = 'tool_result', name = 'codemode', result = { ok = true, value = 2 } })
check(has(fake.all_blocks_text(), '2'), 'the script\'s value is the block\'s answer: ' .. fake.all_blocks_text())

-- ---- 3. an operation result is the command's OUTPUT --------------------------------------
local operation = {
  operation_id = 'op-1795000000000000-1174662-77', state = 'completed', ok = true,
  stdout = '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n', stderr = '', code = 0, process_exit_code = 0,
  elapsed_ms = 42, cwd = '/home/victor/work', containment = 'posix_process_group',
  cleanup = 'terminated', cleanup_budget_ms = 1000, cpu_priority = 'default',
  stdout_path = '/home/victor/.wasm-agent/operations/op-77/stdout', output_truncated = false,
}
local op_written = {}
local op_fake = fake_transcript()
host.transcript_block, host.transcript_write = op_fake.block, op_fake.write
host.transcript_rewrite, host.transcript_fold = op_fake.rewrite, op_fake.fold
host.transcript_expand = function(payload) op_fake.expansions[#op_fake.expansions + 1] = payload; return true end
local op_view = view_lib.new({ live = true, stdout = true, limit = 100, rows = function() return 40 end,
  out = function(text) op_written[#op_written + 1] = text end, now = function() return 200 end })
op_view.screen = view_lib.screen_rows(40, true)
op_view.editor, op_view.editor_ready = true, true
op_view:prompt('wa> ')
op_view:run_started()
op_view:event({ type = 'delta', text = '```js run\nreturn await tools.bash({command: \'seq 1 40\'});\n```' })
op_view:event({ type = 'tool', name = 'codemode', arguments = { code = "return await tools.bash({command: 'seq 1 40'});" } })
op_view:event({ type = 'codemode_call', id = 'b1', name = 'bash', arguments = { command = 'seq 1 40' }, state = 'running' })
op_view:event({ type = 'codemode_call', id = 'b1', name = 'bash', state = 'ok', ms = 42 })
op_view:event({ type = 'tool_result', name = 'codemode', result = { ok = true, value = operation } })
local op_text = op_fake.all_blocks_text()
-- THE OPERATION IS ONE ROW NOW (chat-view-round-2, item 4; Victor 23/11: "script output should show
-- 'script output · <n> chars' so we can expand"). This row used to require the command's first lines drawn
-- as the answer; the answer became the row that names its size, and the lines moved one press away -
-- asserted in the two checks below, so nothing this test was guarding is dropped.
check(has(op_text, 'script output · 21 chars'),
  'the answer is one row naming the size of the command\'s output: ' .. op_text)
check(not has(op_text, '1\n2\n3'), 'and the output is not printed under it: ' .. op_text)
check(not has(op_text, 'cleanup_budget_ms') and not has(op_text, 'containment') and not has(op_text, 'operation_id":'),
  'and none of the operation\'s transport fields is drawn as the answer: ' .. op_text)
check(has(op_text, '/console'),
  'the full result is still reachable, named on the block: ' .. op_text)
check(#op_fake.expansions > 0, 'and one click carries the whole object (transcript_expand)')
if #op_fake.expansions > 0 then
  local payload = json.decode(op_fake.expansions[1])
  local expanded = payload and payload[1] and payload[1].text or ''
  check(has(expanded, 'operation_id') and has(expanded, 'cleanup'),
    'the expanded rows are the WHOLE object, byte for byte: ' .. tostring(expanded):sub(1, 200))
  local out_at, object_at = expanded:find('1\n2\n3', 1, true), expanded:find('operation_id', 1, true)
  check(out_at ~= nil and object_at ~= nil and out_at < object_at,
    'and the command\'s own output comes first in them, because that is what the reader opened: '
      .. tostring(expanded):sub(1, 120))
end

-- A value that merely LOOKS like a status object is still drawn whole: the preview is an allow-list
-- (an operation id AND captured output), never "any table with a state field".
-- The REAL shape first: a script's return crosses the sandbox boundary as a JSON STRING (measured on
-- the parity capture), so the same allow-list has to answer for that shape and the decoded one.
do
  local block_lib = dofile('lua/core/codemode_block.lua')
  local string_model = block_lib.new({ code = 'return await tools.bash({command: "seq 1 40"});' }, 0)
  block_lib.finish(string_model,
    { ok = true, value = json.encode({ operation_id = 'op-1795000000000000-1-9', state = 'completed',
      ok = true, stdout = '1\n2\n3\n', stderr = '', code = 0, elapsed_ms = 7, cleanup = 'terminated' }) }, 0.1)
  local string_tail = block_lib.tail_rows(string_model, 100, { columns = view_lib.columns,
    paint = function(text) return text end, encode = function(v) return json.encode(v) end })
  local string_text = table.concat(string_tail, '\n')
  check(has(string_text, '1') and not has(string_text, 'cleanup_budget_ms') and not has(string_text, '"cleanup"'),
    'the JSON STRING a script actually returns is drawn as the output too: ' .. string_text)
end
local plain_view = view_lib.new({ live = true, stdout = true, limit = 100, rows = function() return 40 end,
  out = function() end, now = function() return 300 end })
plain_view.screen = view_lib.screen_rows(40, true)
local block_lib = dofile('lua/core/codemode_block.lua')
local model = block_lib.new({ code = 'return x;' }, 0)
block_lib.finish(model, { ok = true, value = { state = 'completed', code = 0, note = 'not an operation' } }, 0.1)
local tail = block_lib.tail_rows(model, 100, { columns = view_lib.columns,
  paint = function(text) return text end, encode = function(v) return json.encode(v) end })
local tail_text = table.concat(tail, '\n')
check(has(tail_text, 'not an operation'),
  'a table with state/code but no operation id and no captured output is still drawn whole: ' .. tail_text)

for name, value in pairs(saved) do host[name] = value end
print(string.format('raw view stream %s (%d checks, %d failed)', failed == 0 and 'ok' or 'FAILED', checks, failed))
if failed > 0 then os.exit(1) end
