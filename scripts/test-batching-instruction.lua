-- The batching instruction is in every place the model can read it (batch-spec.md, 19/11).
--
-- The evidence it answers: in the task A/B every run measured 1.0 tool calls per round - B 58
-- rounds/57 calls, C 85/84, D 50/49 - so the model was doing one small call at a time. The sentence
-- asks for one program per step instead. It is written THREE times because the three texts are built
-- by different modules, so this test pins the exact bytes in each: a copy that drifts is the defect.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end

local guard = dofile('scripts/lib/test-home-guard.lua')
local guard_reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if guard_reason then error('this test refuses to run (' .. guard_reason .. ')') end

local raw = dofile('lua/core/raw_code.lua')
local tools = dofile('lua/core/tools.lua')
local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 0) end
end

-- VERBATIM, from the spec. A paraphrase is not the instruction Victor approved.
local SENT = 'One run(code) can do a whole step: read, search, edit and check in the same script, '
  .. 'with Promise.all for the parts that do not depend on each other, and return only what you need '
  .. 'to decide the next step. Prefer one script per step over many small calls.'
ok(raw.BATCHING == SENT, 'M.BATCHING is the sentence verbatim:\n  got: ' .. tostring(raw.BATCHING))

-- (a) the native run tool's description
ok(raw.run_tool_schema().description:find(SENT, 1, true) ~= nil,
  'the run tool description carries the sentence')

-- (b) the CodeAct guidance, for BOTH transports - the model is offered one of them, so both must say it
ok(raw.guidance_for('tool_call'):find(SENT, 1, true) ~= nil,
  'the tool-call guidance carries the sentence')
ok(raw.guidance_for('block'):find(SENT, 1, true) ~= nil,
  'the block guidance carries the sentence')

-- (c) codemode's script tool description, with ITS name in the sentence
local want = SENT:gsub('run%(code%)', 'codemode')
ok(want:find('codemode', 1, true) ~= nil and want ~= SENT, 'the codemode variant names codemode')
local seen = false
for _, item in ipairs(tools.catalog('master')) do
  local name = item['function'] and item['function'].name or ''
  if name == 'codemode' then
    seen = true
    ok(item['function'].description:find(want, 1, true) ~= nil,
      'the codemode tool description carries the sentence with its own name')
  end
end
ok(seen, 'the codemode tool is in the catalogue at all')
print('batching instruction ok (' .. checks .. ' checks)')

