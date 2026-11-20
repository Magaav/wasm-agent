-- Item 5 (rel review r2): the <bash>/<run> pair markers of the LEAK NET apply only in native mode.
--
-- a27490af's finish_contract.markup names the allow-list of call formats it treats as "markup written as
-- text". This branch widened that list with tool-call PAIRS; the review's point is that widening must not
-- reach the modes that existed before, or an answer that merely WRITES one of those shapes stops being an
-- answer. So: in every other mode the scan sees exactly a27490af's list, and in native mode it also sees
-- the native transport's own formats.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local raw = dofile('lua/core/raw_code.lua')
local contract = dofile('lua/core/finish_contract.lua')
local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end

local BASH_CALL = '<bash>{"command":"ls"}</bash>'
local RUN_CALL = '<run>{"code":"return 1"}</run>'
local INVOKE_CALL = '<invoke name="bash">ls</invoke>'
-- a marker a27490af DID name, so "found" below cannot be satisfied by a scan that finds nothing
local DS_CALL = '<ds_tool>{"command":"ls"}</ds_tool>'

-- The modes, WITHOUT a nil entry: ipairs stops at the first nil, so a table that held one would have
-- run these checks zero times and still printed a count (found by reading the count, not the green).
local MODES = { 'only', 'first', 'codemode', 'on', 'stop', 'e2', 'e3' }
-- The caller that passes no mode at all is the other real shape (markup_in_text(text)).
local function scan(call, mode)
  if mode == nil then return raw.markup_in_text(call) end
  return raw.markup_in_text(call, mode)
end

-- 1. the always-on list still sees exactly what a27490af saw, in both spellings of "no mode argument".
-- <invoke ...>...</invoke> is found in every mode BY THE BASE LIST, which names the bare </invoke>; the
-- pair scan adds the opener-must-close rule and changes nothing there (the comment in raw_code.lua).
ok(scan(DS_CALL, nil) ~= nil, 'a27490af marks <ds_tool> as markup with no mode argument')
for _, mode in ipairs(MODES) do
  ok(scan(DS_CALL, mode) ~= nil, 'a27490af marks <ds_tool> as markup in mode ' .. mode)
  ok(scan(INVOKE_CALL, mode) ~= nil,
    'a27490af marks an </invoke> answer as markup in mode ' .. mode)
end

-- 2. the PAIR scan is native only: a27490af had no pairs at all, so outside native mode a <bash> or
-- <run> written as text is prose and the answer stands.
ok(scan(BASH_CALL, nil) == nil, 'a <bash> pair is prose with no mode argument')
ok(scan(RUN_CALL, nil) == nil, 'a <run> pair is prose with no mode argument')
for _, mode in ipairs(MODES) do
  ok(scan(BASH_CALL, mode) == nil,
    'a <bash> pair is prose in mode ' .. mode .. ' (a27490af had no pair scan)')
  ok(scan(RUN_CALL, mode) == nil,
    'a <run> pair is prose in mode ' .. mode .. ' (a27490af had no pair scan)')
end

-- 3. native mode DOES name them: that node's transport is exactly those formats
for _, call in ipairs({ BASH_CALL, RUN_CALL, INVOKE_CALL, DS_CALL }) do
  local found = raw.markup_in_text(call, 'native')
  ok(found ~= nil and type(found.marker) == 'string' and found.marker ~= '',
    'native mode names the call shape: ' .. call)
end

-- 4. the same rule through the module that runs the scan for the turn contract
local function contract_with(mode, text)
  local real = host.getenv
  host.getenv = function(k)
    if k == 'WASM_AGENT_RAW_CODE' then return mode end
    return real(k)
  end
  local shape = contract.markup(text)
  host.getenv = real
  return shape
end
ok(contract_with('only', BASH_CALL) == nil, 'a contract in only mode does not fail a <bash> answer')
ok(contract_with('codemode', BASH_CALL) == nil, 'a contract in codemode mode does not fail it either')
ok(contract_with('only', DS_CALL) ~= nil, 'and it still fails the markup a27490af named')
ok(contract_with('native', BASH_CALL) ~= nil, 'a native contract does fail a <bash> written as text')

print('markup pairs ok (' .. checks .. ' checks)')
