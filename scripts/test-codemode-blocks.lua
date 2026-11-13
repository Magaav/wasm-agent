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
  end
end

if failed > 0 then
  print(string.format('codemode blocks: %d failed of %d checks', failed, checks))
  os.exit(1)
end
print(string.format('codemode blocks ok (%d checks)', checks))
