-- WHAT A NATIVE `run` CALL LOOKS LIKE WHILE IT IS WRITTEN (operator, 21/11: "i want our wa agent (run
-- code) to draw the JS as it used to do in raw code channel, so we can see it in real time writing
-- js ... the promises waiting for coming back, the way to explore result just like we had").
--
-- The transport does not change: the native `run` tool call is still the one way of executing. What
-- changes is what the reader SEES, and this file asserts it where the reader sees it - in the rows the
-- view hands the transcript, DURING the turn:
--
--   1. the script's lines are on screen before the call event that announces it (lua/core/run_stream.lua
--      decodes the provider's argument fragments, lua/core/cli_view.lua draws them);
--   2. every awaited tools.X(...) is a WAITING row when it starts and that same row flips to
--      checkmark + duration;
--   3. the native turn ends up drawing the SAME block a fenced run block does - same code rows, same
--      call rows - so the two transports cannot drift apart in the reader's eyes.
--
-- The streamed fragments are the REAL recorded wire of tests/fixtures/provider/
-- opencode-go-run-code-recorded.sse (fourteen frames, the script split mid-string), fed through the same
-- decoder the agent uses. The screen is drawn by scripts/replay-events.lua, the double the whole suite
-- already draws a run with, so nothing here is a second renderer.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local run_stream = dofile('lua/core/run_stream.lua')
local replay = dofile('scripts/replay-events.lua')

local checks, failed = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then failed = failed + 1; print('FAIL ' .. label) end
end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end
local function screen(events)
  local rows = replay.rows(events, { width = 100 })
  local out = {}
  for _, block in ipairs(rows) do
    for _, row in ipairs(block.rows) do out[#out + 1] = row end
  end
  return table.concat(out, '\n')
end

-- ---- 1. the decoder: split escapes, split unicode, split surrogate pairs -----------------------
local function decode(fragments)
  local state = run_stream.new()
  local pieces = {}
  for _, fragment in ipairs(fragments) do
    local piece = run_stream.feed(state, fragment)
    if piece ~= '' then pieces[#pieces + 1] = piece end
  end
  return table.concat(pieces), state
end

do
  -- A backslash and the letter of its escape in two different fragments, which is the case that made
  -- a plain json.decode fail: no single fragment is valid JSON.
  local text = decode({ '{"code":"a', '\\', 'n', 'b\\', '"c\\\\d"', '}' })
  check(text == 'a\nb"c\\d', 'an escape split across fragments decodes to its character: ' .. tostring(text))
  local unicode = decode({ '{"code":"x\\u00', 'e9y"}' })
  check(unicode == 'x\195\169y', 'a \\uXXXX split across fragments is one character: ' .. tostring(unicode))
  local pair = decode({ '{"code":"\\ud83d', '\\ude00"}' })
  check(pair == '\240\159\152\128', 'a surrogate pair split across fragments is its code point: ' .. tostring(pair))
  -- The key itself split, and the code before raw: the scanner reads the object, not a prefix match.
  local late = decode({ '{"ra', 'w":{"a":"}\\""},"co', 'de":"return 1;"}' })
  check(late == 'return 1;', 'the code key is found after another key, even split: ' .. tostring(late))
  local state = select(2, decode({ '{"code":"abc"}' }))
  check(run_stream.done(state) and run_stream.text(state) == 'abc', 'the closing brace ends the value')
end

-- ---- the recorded wire: the fragments the provider really sent ---------------------------------
local frames = {}
for line in io.lines('tests/fixtures/provider/opencode-go-run-code-recorded.sse') do
  local data = line:match('^data: (.*)$')
  if data and data ~= '[DONE]' then
    local ok, chunk = pcall(json.decode, data)
    if ok and type(chunk) == 'table' then
      local calls = chunk.choices and chunk.choices[1] and chunk.choices[1].delta
        and chunk.choices[1].delta.tool_calls
      for _, call in ipairs(calls or {}) do
        if type(call) == 'table' and call['function'] and call['function'].arguments then
          frames[#frames + 1] = call['function'].arguments
        end
      end
    end
  end
end
check(#frames > 1, 'the recorded turn streams its arguments in several frames: ' .. #frames)
local state = run_stream.new()
local grown, pieces = 0, {}
for _, fragment in ipairs(frames) do
  local piece = run_stream.feed(state, fragment)
  if piece ~= '' then grown = grown + 1; pieces[#pieces + 1] = piece end
end
local script = table.concat(pieces)
local whole = json.decode(table.concat(frames))
check(script == whole.code, 'the decoder reproduces the recorded script byte for byte')
check(grown > 1, 'and it grew as the fragments arrived, not in one jump: ' .. grown)

-- ---- 2. the view: the script is on screen BEFORE the call is announced -------------------------
-- The events a CLI run is handed for this turn, in the order the host emits them.
local deltas = {}
do
  local decoder = run_stream.new()
  for _, fragment in ipairs(frames) do
    local piece = run_stream.feed(decoder, fragment)
    if piece ~= '' then
      deltas[#deltas + 1] = { type = 'run_code_delta', call_id = 'call-run-1', text = piece }
    end
  end
end
local turn = {
  { type = 'step_phase', phase = 'commentary', text = 'checking the hostname.' },
}
for _, event in ipairs(deltas) do turn[#turn + 1] = event end
local mid = screen(turn)
check(has(mid, 'await tools.bash'), 'the script is drawn while the model is still writing it: ' .. mid)
check(has(mid, 'head -n 1 /etc/hostname'), 'and the line the model finished is whole: ' .. mid)
check(not has(mid, 'Run('), 'never behind a Run(code=...) wrapper: ' .. mid)
check(not has(mid, '{\"code\"'), 'and never as the tool call arguments (JSON) either: ' .. mid)

-- The call announces itself only now, after its last fragment.
turn[#turn + 1] = { type = 'tool', name = 'run', call_id = 'call-run-1', arguments = { code = script } }
turn[#turn + 1] = { type = 'codemode_call', id = 1, name = 'bash',
  arguments = { command = 'head -n 1 /etc/hostname' }, state = 'running' }
local waiting = screen(turn)
check(has(waiting, 'bash'), 'the awaited call is a row the moment it starts: ' .. waiting)
check(has(waiting, '\226\143\179'), 'and that row is WAITING (the hourglass), not done: ' .. waiting)
check(not has(waiting, '\226\156\147 bash'), 'a call still in flight is never drawn as a success: ' .. waiting)
turn[#turn + 1] = { type = 'codemode_call', id = 1, name = 'bash', state = 'ok', ms = 122 }
turn[#turn + 1] = { type = 'tool_result', name = 'run',
  result = { ok = true, value = 'avell\n' } }
local settled = screen(turn)
check(has(settled, '\226\156\147 bash') and has(settled, '122ms'),
  'the same row flips to checkmark and its duration: ' .. settled)
check(has(settled, 'avell'), 'the script\'s value is the block\'s answer: ' .. settled)
check(has(settled, 'await tools.bash'), 'and the script is still there, whole: ' .. settled)

-- ---- 3. parity: the native turn draws what a fenced run block draws ----------------------------
local block = {
  { type = 'step_phase', phase = 'commentary', text = 'checking the hostname.' },
  { type = 'delta', text = '```js run\n' .. script .. '\n```' },
  { type = 'tool', name = 'codemode', call_id = 'call_raw_1', arguments = { code = script } },
  { type = 'codemode_call', id = 1, name = 'bash',
    arguments = { command = 'head -n 1 /etc/hostname' }, state = 'running' },
  { type = 'codemode_call', id = 1, name = 'bash', state = 'ok', ms = 122 },
  { type = 'tool_result', name = 'codemode', result = { ok = true, value = 'avell\n' } },
}
local native_text = screen(turn)
local block_text = screen(block)
check(native_text == block_text,
  'a native run turn and a fenced one draw the SAME block:\n--- native ---\n' .. native_text
    .. '\n--- block ---\n' .. block_text)

print(string.format('run live ok (%d checks, %d failed)', checks, failed))
if failed > 0 then error('run live: ' .. failed .. ' check(s) failed') end
