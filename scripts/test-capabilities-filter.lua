-- ONE FACT SHOULD NOT COST THE WHOLE CATALOGUE (25/11: an agent read all 90 entries to learn one tool's
-- workspace status). `capabilities()` takes `names` and `status` and answers only those entries; with no
-- arguments it answers exactly what it answered before the filter existed, because a healthy call's
-- answer must not move.
--
-- What this row pins, and why each one is here:
--   * the unfiltered answer keeps every key it had and gains no `filter` block - the shape a model has
--     read for months;
--   * `names` narrows BOTH halves (`capabilities` and `execution`) and says how many it matched of how
--     many there are;
--   * `status` narrows to the entries that carry that status word, and every entry it returns carries it;
--   * a name the catalogue does not carry, an empty `names`, a status word no entry carries, and a
--     `status` that is not a word are REFUSED by name - never answered with a short list that reads as
--     "there are no such tools" (the rule of this mission: unknown is not yes);
--   * the same asks through the OUTER tool answer the same bytes: the guest global and the tool are one
--     code path (`lua/core/tools.lua`), so they cannot drift.
--
-- Hermetic: its own scratch home, and it refuses to run against a live one. Every script it runs is local.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'capabilities filter', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function run(code) return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx) end
local function shown(result)
  return json.encode({ ok = result.ok, code = result.code, error = tostring(result.error):sub(1, 240),
    fix = tostring(result.fix):sub(1, 400), value = tostring(result.value):sub(1, 400) }):sub(1, 900)
end
-- What a script returned, decoded: the guest hands the loop the JSON text of its value, so one decode.
local function value_of(result)
  local ok, value = pcall(json.decode, tostring(result.value))
  return ok and value or nil
end
local function answered(result)
  check(result.ok == true, 'the script must run: ' .. shown(result))
  return value_of(result)
end
local function script(code) local r = run(code); return answered(r), r end

-- 1. NO ARGUMENTS: the answer a model has read for months, unchanged.
local whole, whole_run = script('return await capabilities()')
check(type(whole) == 'table', 'capabilities() answers an object: ' .. shown(whole_run))
local keys = {}
for key in pairs(whole) do keys[#keys + 1] = key end
table.sort(keys)
check(table.concat(keys, ',') == 'capabilities,execution,note,role,status,workspace',
  'the unfiltered answer keeps every key it had and gains no filter block: ' .. table.concat(keys, ','))
check(type(whole.capabilities) == 'table' and #whole.capabilities > 10,
  'and still lists the catalogue: ' .. tostring(#(whole.capabilities or {})))
local total = #whole.capabilities

-- The same answer through the outer tool, so the two doors cannot disagree about an unfiltered ask.
local direct = tools.dispatch(memory, 'capabilities', {}, 'master', ctx)
check(json.encode(direct) == json.encode(whole),
  'the guest global and the outer tool answer the unfiltered ask with the same bytes')

-- 2. BY NAME: only those entries, in the catalogue's own order, with the count said.
local picked, second = whole.capabilities[1], whole.capabilities[2]
local by_name = answered(run('return await capabilities({names:[' .. json.encode(picked) .. ','
  .. json.encode(second) .. ']})'))
check(json.encode(by_name.capabilities) == json.encode({ picked, second }),
  'only the named entries, in the catalogue order: ' .. json.encode(by_name.capabilities or {}))
local listed = 0
for _ in pairs(by_name.execution or {}) do listed = listed + 1 end
check(listed == 2, 'and the execution half is narrowed the same way: ' .. listed .. ' entries')
check(json.encode(by_name.execution[picked]) == json.encode(whole.execution[picked]),
  'the entry that came back is the entry the whole catalogue carries')
check(type(by_name.filter) == 'table' and by_name.filter.matched == 2 and by_name.filter.total == total,
  'the answer says it matched 2 of ' .. total .. ': ' .. json.encode(by_name.filter or {}))
check(#by_name.capabilities < total, 'so one fact costs two entries, not ' .. total)

-- 3. BY STATUS: the entries that carry that word, and no others.
local statuses, word, count = {}, nil, 0
for _, name in ipairs(whole.capabilities) do
  local said = tostring((whole.execution[name] or {}).status or '')
  statuses[said] = (statuses[said] or 0) + 1
end
for candidate, number in pairs(statuses) do
  if candidate ~= '' and (word == nil or number > count) then word, count = candidate, number end
end
check(word ~= nil, 'the catalogue carries at least one workspace status to filter by')
local by_status = answered(run('return await capabilities({status:' .. json.encode(word) .. '})'))
check(#by_status.capabilities == count,
  'every entry with status ' .. word .. ' (' .. count .. ') and no other: ' .. tostring(#(by_status.capabilities or {})))
for _, name in ipairs(by_status.capabilities or {}) do
  check(tostring(by_status.execution[name].status) == word,
    'an entry that came back carries the status asked for: ' .. tostring(name))
end

-- 4. THE REFUSALS: an ask that cannot be answered says which part is wrong, by name.
local unknown = answered(run('return await capabilities({names:["no_such_tool_at_all"]})'))
check(unknown.error == 'unknown_capability', 'a name the catalogue does not carry is refused: ' .. json.encode(unknown))
check(json.encode(unknown.unknown) == json.encode({ 'no_such_tool_at_all' }),
  'and the unknown name is named: ' .. json.encode(unknown.unknown or {}))
check(unknown.capabilities == nil, 'a refusal lists nothing that would read as an answer')
local empty = answered(run('return await capabilities({names:[]})'))
check(empty.error == 'capabilities_names_required',
  'an empty names array asks for nothing and says so: ' .. json.encode(empty))
local bad_status = answered(run('return await capabilities({status:"zebra"})'))
check(bad_status.error == 'unknown_capability_status',
  'a status word no entry carries is refused: ' .. json.encode(bad_status))
check(type(bad_status.accepted) == 'table' and #bad_status.accepted > 0,
  'and the words that exist are listed: ' .. json.encode(bad_status.accepted or {}))
local not_a_word = answered(run('return await capabilities({status:7})'))
check(not_a_word.error == 'capabilities_status_required',
  'a status that is not a word is refused: ' .. json.encode(not_a_word))

-- 5. THE OUTER TOOL takes the same filters and answers the same bytes for the same ask.
local picked_script = 'return await capabilities({names:[' .. json.encode(picked) .. ']})'
local outer = tools.dispatch(memory, 'capabilities', { names = { picked } }, 'master', ctx)
check(json.encode(outer.capabilities) == json.encode({ picked }), 'the outer tool filters by name too')
check(json.encode(outer) == json.encode(answered(run(picked_script))),
  'and the two doors answer the same bytes for the same ask')

print(json.encode({ ok = true, checks = checks, catalogue = total, status = word }))
