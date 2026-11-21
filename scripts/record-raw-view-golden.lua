-- RECORD the raw-channel view goldens (rule 14: parity first).
--
-- Runs ONE real turn through the REAL agent loop with a stubbed provider and writes the events the
-- CLI view receives plus the rows it draws from them, so a change to the live block is checked against
-- what a reader saw before it. The recordings live in fixtures/raw-default/ and are committed.
--
--   WA_CAPTURE_MODE=only   WA_CAPTURE_OUT=/tmp/block.json  WA_SCRIPT=scripts/record-raw-view-golden.lua wa --db scratch.db
--   WA_CAPTURE_MODE=native WA_CAPTURE_OUT=/tmp/native.json WA_SCRIPT=scripts/record-raw-view-golden.lua wa --db scratch.db
--
-- It must run from the TREE (WASM_AGENT_LUA_ROOT), in a scratch HOME (the guard below refuses the
-- operator's own home), and it never reaches a network: host.http errors and host.http_stream answers
-- from the fixture.
--
-- The script under test is the one in SCRIPT below; it is the case the operator described
-- ("the promises waiting for coming back, the way to explore result"): an awaited tools.bash whose
-- result the script hands back WHOLE, so the block has to draw a managed operation.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this recorder refuses to run (' .. reason .. ')') end
local mode = os.getenv('WA_CAPTURE_MODE') or ''
if mode == '' then mode = nil end
local out_path = assert(os.getenv('WA_CAPTURE_OUT'), 'WA_CAPTURE_OUT')
local real_getenv = host.getenv
local overrides = { WASM_AGENT_PROVIDER = 'opencode-go', WASM_AGENT_LLM_API_KEY = 'capture-fixture',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_MAX_TOOL_ROUNDS = '4' }
host.getenv = function(k)
  if k == 'WASM_AGENT_RAW_CODE' then return mode end
  if overrides[k] ~= nil then return overrides[k] end
  return real_getenv(k)
end
host.http = function() error('network forbidden in the capture fixture') end
-- The script returns what a shell call returns: the whole operation object.
local SCRIPT = "return await tools.bash({command: 'seq 1 40'});"
local BLOCK_TEXT = 'Checking the range.\n\n```js run\n' .. SCRIPT .. '\n```'
local requests = {}
host.http_stream = function(_, _, _, body)
  local req = json.decode(body)
  local names = {}
  for _, item in ipairs(req.tools or {}) do names[#names + 1] = (item['function'] or {}).name end
  requests[#requests + 1] = { tool_names = names }
  local round = #requests
  local usage = { prompt_tokens = 100, completion_tokens = 20, total_tokens = 120 }
  if round == 1 then
    local declared_run = false
    for _, name in ipairs(names) do if name == 'run' then declared_run = true end end
    if declared_run then
      -- WA_CAPTURE_STREAM=1 replays WHAT THE HOST NOW DELIVERS while the model writes: the same
      -- argument fragments, one tool_call_delta each, through the global the real host calls
      -- (rust/wa-capabilities/src/host.rs). The assembled call still follows, exactly as the stream
      -- returns it - so the recording is the live path and not a second description of it.
      if (os.getenv('WA_CAPTURE_STREAM') or '') == '1' then
        local emit = rawget(_G, 'wa_stream_event')
        if emit then
          local split = { '{"code":"', SCRIPT:sub(1, 24), SCRIPT:sub(25, 60), SCRIPT:sub(61), '"}' }
          for _, fragment in ipairs(split) do
            pcall(emit, json.encode({ type = 'tool_call_delta', index = 0, call_id = 'call-run-1',
              name = 'run', arguments = fragment }))
          end
        end
      end
      return json.encode({ status = 200, content = 'checking', stream_complete = true,
        finish_reason = 'tool_calls', tool_calls = { { id = 'call-run-1', type = 'function',
          ['function'] = { name = 'run', arguments = json.encode({ code = SCRIPT }) } } }, usage = usage })
    end
    return json.encode({ status = 200, content = BLOCK_TEXT, stream_complete = true,
      finish_reason = 'stop', tool_calls = {}, usage = usage })
  end
  return json.encode({ status = 200, content = 'the range is 1 to 40.', stream_complete = true,
    finish_reason = 'stop', tool_calls = {}, usage = usage })
end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools_lib = dofile('lua/core/tools.lua')
local original = dofile
dofile = function(p) if p == 'lua/core/tools.lua' then return tools_lib end return original(p) end
local agent = original('lua/core/agent.lua')
dofile = original
local sid = memory.start_session('', 'capture op ' .. tostring(mode), { user_id = 'master', title = 'capture op' })
local events = {}
local okc, err = pcall(function()
  return agent.new(sid, function(event) events[#events + 1] = event end, 'master', 'master', ''):run('check the range')
end)
local replay = dofile('scripts/replay-events.lua')
local rows_ok, blocks = pcall(replay.rows, events, { width = 100 })
local rendered = {}
if rows_ok then
  for _, block in ipairs(blocks) do
    rendered[#rendered + 1] = string.format('--- block %d%s%s', block.index,
      block.topic and ' topic' or '', block.code and ' code' or '')
    for _, row in ipairs(block.rows) do rendered[#rendered + 1] = row end
  end
else
  rendered[1] = 'render failed: ' .. tostring(blocks)
end
local body = { mode = tostring(mode), run_ok = okc, error = okc and nil or tostring(err),
  declared = requests[1] and requests[1].tool_names or {}, requests = #requests,
  events = events, rendered = table.concat(rendered, '\n') }
assert(host.write_file(out_path, json.encode(body)))
print('captured op ' .. tostring(mode) .. ': ok=' .. tostring(okc))
