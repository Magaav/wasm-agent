-- A call that uses the OTHER well-known argument names works the FIRST time (change/edit-accepts-common-names).
--
-- EVIDENCE (a turn note, 22/11): "tools.edit rejected old_string/new_string (the tool takes
-- edits/old_text/new_text) and the error arrived only after the call; my first attempt at the fix burned
-- a round." A model trained on another harness writes old_string/new_string, and often file_path; this
-- node's names are old_text/new_text and path. The fix maps the well-known spelling at the door
-- (lua/core/file_tools.lua, ALIASES) and leaves the schema the model is sent untouched, because that
-- schema is the prompt prefix.
--
-- What is checked, in the order a call travels:
--   1. each accepted spelling, through the REAL dispatcher (the path `wa chat` takes): old_string/new_string
--      at the top level, inside one `edits` item, and file_path for edit, read and write;
--   2. the mapped call meets the SAME checks: an empty anchor, an ambiguous anchor and a non-string
--      replacement are refused by their own codes and nothing is written;
--   3. a call that sends both spellings is refused BY NAME, and the refusal names both;
--   4. an unknown argument's refusal names the accepted arguments in its FIRST line;
--   5. the schema the model is sent advertises none of the synonyms (prompt cache);
--   6. one real code-mode run block: `tools.edit({path, old_string, new_string})` rewrites the file in
--      one call, which is the acceptance test the operator runs by hand in `wa chat`.
-- Hermetic: its own scratch home, fixtures inside it, no network and no other node.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local policy = dofile('lua/core/codemode_policy.lua')
local paths = dofile('lua/core/paths.lua')

-- Own scratch home or nothing: a row that writes fixtures into the operator's home is not a test.
local home = paths.home()
local operator_home = (host.getenv('HOME') or '') .. '/.wasm-agent'
assert(home ~= '' and home ~= operator_home,
  'this row needs a scratch WASM_AGENT_HOME, not the operator home: ' .. tostring(home))

local sid = memory.start_session('', 'edit aliases', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end
local root = paths.data() .. '/edit-aliases'
local function fixture(name, text)
  local path = root .. '/' .. name
  assert(host.write_file(path, text), 'fixture ' .. name)
  return path
end
local function call(name, args) return tools.dispatch(memory, name, args, 'master', ctx) end
local function body(path) return host.read_file(path) end

-- 1. old_string/new_string at the top level, through the dispatcher.
local one = fixture('one.txt', 'alpha foo omega\n')
local edited = call('edit', { path = one, old_string = 'foo', new_string = 'bar' })
check(edited.error == nil, 'edit with old_string/new_string is the same request: ' .. json.encode(edited):sub(1, 400))
check(edited.applied == true, 'the mapped edit applied: ' .. json.encode(edited):sub(1, 400))
check(body(one) == 'alpha bar omega\n', 'and the bytes changed once: ' .. tostring(body(one)))

-- 2. file_path stands for path, on all three file tools.
local two = fixture('two.txt', 'red green blue\n')
local mapped = call('edit', { file_path = two, old_string = 'green', new_string = 'GREEN' })
check(mapped.error == nil, 'edit takes file_path for path: ' .. json.encode(mapped):sub(1, 400))
check(body(two) == 'red GREEN blue\n', 'the file_path edit landed: ' .. tostring(body(two)))

local read_back = call('read', { file_path = two })
check(read_back.error == nil, 'read takes file_path for path: ' .. json.encode(read_back):sub(1, 400))
check(tostring(read_back.content):find('red GREEN blue', 1, true) ~= nil, 'read returned the file behind file_path')

local written = root .. '/three.txt'
local wrote = call('write', { file_path = written, content = 'made by file_path\n' })
check(wrote.error == nil and wrote.ok == true, 'write takes file_path for path: ' .. json.encode(wrote):sub(1, 400))
check(body(written) == 'made by file_path\n', 'the file_path write landed: ' .. tostring(body(written)))

-- 3. The same aliases inside one replacement of an `edits` array.
local three = fixture('four.txt', 'a1 b1 c1\n')
local items = call('edit', { path = three,
  edits = { { old_string = 'a1', new_string = 'a2' }, { old_string = 'c1', new_string = 'c2' } } })
check(items.error == nil, 'an edits item takes old_string/new_string: ' .. json.encode(items):sub(1, 400))
check(body(three) == 'a2 b1 c2\n', 'both replaced items landed: ' .. tostring(body(three)))

-- 4. After mapping, exactly the checks the declared names meet. Nothing here is looser.
local empty = call('edit', { path = three, old_string = '', new_string = 'x' })
check(empty.error == 'old_text_required', 'an empty old_string is refused by the same code: ' .. json.encode(empty):sub(1, 300))
local twice = fixture('five.txt', 'x x\n')
local ambiguous = call('edit', { path = twice, old_string = 'x', new_string = 'y' })
check(ambiguous.error == 'old_text_ambiguous', 'an ambiguous anchor is refused by the same code: ' .. json.encode(ambiguous):sub(1, 300))
check(body(twice) == 'x x\n', 'and nothing was written for it: ' .. tostring(body(twice)))
local not_text = call('edit', { path = three, old_string = 'a2', new_string = 5 })
check(not_text.error == 'new_text_required', 'a non-string new_string is refused by the same code: ' .. json.encode(not_text):sub(1, 300))
check(body(three) == 'a2 b1 c2\n', 'and the file is untouched: ' .. tostring(body(three)))

-- 5. Both spellings in one call: refused by name, never resolved by picking one.
local mixed = call('edit', { path = three, old_text = 'a2', old_string = 'a2', new_text = 'z' })
check(mixed.error == 'argument_alias_conflict', 'both spellings are refused by name: ' .. json.encode(mixed):sub(1, 300))
check(tostring(mixed.message):find('old_text', 1, true) ~= nil and tostring(mixed.message):find('old_string', 1, true) ~= nil,
  'the refusal names both spellings: ' .. tostring(mixed.message))
check(body(three) == 'a2 b1 c2\n', 'a conflicting call changes nothing: ' .. tostring(body(three)))
local both_paths = call('read', { path = two, file_path = two })
check(both_paths.error == 'argument_alias_conflict', 'path with file_path is the same conflict: ' .. json.encode(both_paths):sub(1, 300))

-- 6. A truly unknown argument: the FIRST line names what the tool does take.
local unknown = call('edit', { path = three, edits = { { old_text = 'a2', new_text = 'a3' } }, old_txt = 'typo' })
-- An unknown option is refused before the handler runs, by the ONE argument validator: the code is
-- `unknown_argument:<name>` instead of this handler's own `unsupported_edit_option`. The sentence names
-- the arguments the schema declares, and the synonyms the handler still maps are not in that sentence
-- because they are not in the schema (section 1 above proves they still work). Mission
-- tool-args-honest-and-same-on-peers, item 2.
check(unknown.error == 'unknown_argument:old_txt', 'an unknown option is refused by name: ' .. json.encode(unknown):sub(1, 300))
check(unknown.effect == 'none', 'and nothing ran: ' .. tostring(unknown.effect))
local first_line = tostring(unknown.message):match('^[^\n]*') or ''
check(first_line:find('edits', 1, true) ~= nil and first_line:find('range_edits', 1, true) ~= nil,
  'the first line names the accepted arguments: ' .. first_line)

-- 7. The schema the model is sent is the one it was sent before: no synonym appears in it.
local edit_parameters
for _, item in ipairs(tools.catalog('master')) do
  if item['function'].name == 'edit' then edit_parameters = item['function'].parameters end
end
check(type(edit_parameters) == 'table' and type(edit_parameters.properties) == 'table',
  'the catalogue declares edit with its own schema')
for _, name in ipairs({ 'old_string', 'new_string', 'file_path', 'oldtext', 'newtext' }) do
  check(edit_parameters.properties[name] == nil,
    'the schema the model is sent advertises no `' .. name .. '` (a synonym there costs the prompt cache)')
end
for _, name in ipairs({ 'path', 'edits', 'range_edits' }) do
  check(edit_parameters.properties[name] ~= nil,
    'the schema the model is sent keeps `' .. name .. '`')
end

-- 8. The acceptance test the operator runs by hand, through a real run block: one call, one edit.
local six = fixture('six.txt', 'const foo = 1\n')
local script = 'const r = await tools.edit({path:' .. json.encode(six) .. ', old_string:"foo", new_string:"bar"});\n'
  .. 'return {error:r.error||null, applied:r.applied};'
local ran = call('codemode', { code = script })
check(ran.ok ~= false and type(ran.value) == 'string',
  'the run block answered, not a refusal: ' .. json.encode(ran):sub(1, 600))
local value = json.decode(ran.value)
check(value.error == nil and value.applied == true,
  'inside a script, old_string names old_text in one call: ' .. json.encode(value):sub(1, 300))
check(body(six) == 'const bar = 1\n', 'the script replaced foo with bar: ' .. tostring(body(six)))

print('edit aliases ok (' .. checks .. ' checks)')
