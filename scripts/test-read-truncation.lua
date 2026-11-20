-- A read page says what it returned and what it did NOT: bytes_read vs file_size, the line count, and a
-- truncated flag carrying the range it returned and how to read the rest (change/read-truncation, item 1).
--
-- MEASURED, 19-20/11: two missions (harness-fixes-1, the fence-card notes) edited a file after a read
-- that had silently returned only part of it. The envelope carried next_offset and total_lines and
-- never the size of the file behind it, so a page of 4 KB out of 186 KB looked like the whole file.
--
-- Every read here goes through a REAL code-mode run block (the path real use takes), never a direct
-- call into file_tools: the fields have to survive the envelope the model actually reads.
-- Hermetic: its own scratch home, its own fixtures, no network and no other node.
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

local sid = memory.start_session('', 'read truncation', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end
local function run(code) return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx) end
local function value(result)
  assert(result.ok ~= false and type(result.value) == 'string',
    'the run block answered, not a refusal: ' .. json.encode(result):sub(1, 600))
  return json.decode(result.value)
end
-- One run block that reads one path and returns the fields a caller would look at.
local function read_probe(extra)
  return 'const r = await tools.read({' .. extra .. '});\n'
    .. 'return {file_size:r.file_size, bytes:r.bytes, bytes_read:r.bytes_read, returned_bytes:r.returned_bytes,'
    .. ' truncated:r.truncated, total_lines:r.total_lines, range:r.range, truncation:r.truncation,'
    .. ' how:r.how_to_read_rest, content:r.content, offset:r.offset, eof:r.eof,'
    .. ' range_complete:r.range_complete, next_offset:r.next_offset, next_column:r.next_column};'
end

local root = paths.data() .. '/read-truncation'
local big = root .. '/big.txt'
local small = root .. '/small.txt'
local long = root .. '/long.txt'
local tail = root .. '/tail.txt'
local lines = {}
for i = 1, 3000 do lines[i] = string.format('line %04d %s', i, string.rep('x', 52)) end
local big_text = table.concat(lines, '\n') .. '\n'
assert(host.write_file(big, big_text), 'fixture big.txt')
assert(host.write_file(small, 'alpha\nbeta\ngamma\n'), 'fixture small.txt')
assert(host.write_file(long, string.rep('y', 200000) .. '\n'), 'fixture long.txt')
assert(host.write_file(tail, table.concat((function()
  local t = {}
  for i = 1, 300 do t[i] = string.format('tail %03d %s', i, string.rep('z', 30)) end
  return t
end)(), '\n') .. '\n'), 'fixture tail.txt')

-- 1. A partial page names the file behind it, in bytes and in lines.
local page = value(run(read_probe('path:' .. json.encode(big) .. ', limit:10')))
check(page.file_size == #big_text, 'the page reports the file size: ' .. tostring(page.file_size))
check(page.bytes == #big_text, 'and keeps the legacy bytes field equal to it: ' .. tostring(page.bytes))
check(page.bytes_read == #page.content, 'bytes_read is exactly the bytes it returned: '
  .. tostring(page.bytes_read) .. ' vs ' .. tostring(#page.content))
check(page.returned_bytes == page.bytes_read, 'returned_bytes agrees with bytes_read')
check(page.truncated == true, 'a 10-line page of a 3000-line file is truncated: ' .. json.encode(page.truncated))
check(page.total_lines == 3000, 'and the line count is the file\'s: ' .. tostring(page.total_lines))
check(type(page.truncation) == 'table', 'the truncation says what is missing: ' .. json.encode(page.truncation))
check(page.truncation.file_size == #big_text and page.truncation.bytes_read == page.bytes_read,
  'the truncation repeats the sizes: ' .. json.encode(page.truncation))
check(page.truncation.lines_in_file == 3000, 'and the lines in the file')
check(page.truncation.first_byte == 1 and page.truncation.last_byte == page.bytes_read,
  'and the byte range it returned: ' .. json.encode(page.range))
check(page.range.first_line == 1 and page.range.last_line == 10,
  'and the line range it returned: ' .. json.encode(page.range))
check(page.truncation.missing_after == true and page.truncation.missing_before ~= true,
  'missing is named on the side it is missing')
check(type(page.truncation.next) == 'table' and page.truncation.next.path == big,
  'and how to read the rest is a call, not a sentence: ' .. json.encode(page.truncation.next))
check(type(page.how) == 'string' and page.how:find(tostring(#big_text), 1, true) ~= nil,
  'the sentence carries the file size: ' .. tostring(page.how))

-- 2. Following truncation.next is the continuation, byte-exact.
local followed = value(run('const p1 = await tools.read({path:' .. json.encode(big) .. ', limit:10});\n'
  .. 'const p2 = await tools.read(p1.truncation.next);\n'
  .. 'return {first:p1.range, second:p2.range, truncated2:p2.truncated, next2:p2.truncation&&p2.truncation.next?true:false};'))
check(followed.second.first_byte == followed.first.last_byte + 1,
  'the next page starts at the byte after this one: ' .. json.encode(followed))
check(followed.second.first_line == 11, 'and at the next line: ' .. json.encode(followed.second))

-- 3. A whole file says so, and says nothing else.
local whole = value(run(read_probe('path:' .. json.encode(small))))
check(whole.truncated == false, 'a whole-file read is not truncated: ' .. json.encode(whole.truncated))
check(whole.truncation == nil, 'and carries no truncation block: ' .. json.encode(whole.truncation))
check(whole.bytes_read == whole.file_size and whole.file_size == #('alpha\nbeta\ngamma\n'),
  'with bytes_read equal to the file size: ' .. tostring(whole.bytes_read) .. '/' .. tostring(whole.file_size))
check(whole.eof == true and whole.range_complete == true, 'and reaches eof')

-- 4. A page that STARTS late is truncated too, on the other side, and does not offer a dead cursor.
local late = value(run(read_probe('path:' .. json.encode(tail) .. ', offset:200')))
check(late.truncated == true, '200 lines into a 300-line file is not the whole file: ' .. json.encode(late.truncated))
check(late.truncation.missing_before == true, 'the missing lines are named as before this page')
check(late.truncation.missing_after == false, 'and nothing is claimed to follow a page that reaches eof')
check(late.truncation.next == nil, 'so no continuation is offered: ' .. json.encode(late.truncation.next))
check(late.how:find('offset 1', 1, true) ~= nil, 'and the sentence says where to start: ' .. tostring(late.how))
check(late.range.first_line == 200, 'the range starts where the caller asked: ' .. json.encode(late.range))

-- 5. A page cut by the byte budget, not by the lines asked for, says which.
local cut = value(run(read_probe('path:' .. json.encode(long) .. ', limit:1')))
check(cut.truncated == true and cut.truncation.missing_after == true,
  'one very long line is cut by the budget: ' .. json.encode(cut.truncation))
check(cut.truncation.reason:find('byte budget', 1, true) ~= nil,
  'and the reason is the budget, not the requested lines: ' .. tostring(cut.truncation.reason))
check(cut.bytes_read < cut.file_size, 'fewer bytes than the file: ' .. tostring(cut.bytes_read) .. '/' .. tostring(cut.file_size))
check(cut.range_complete == false and cut.next_column > 1, 'and the cursor points inside the line: '
  .. tostring(cut.next_column))

-- 6. The fence: an anchor quoted from a page the caller was NOT given is refused by name. MEASURED
-- 19-20/11: two missions edited a file from a partial read; the edit landed on a view.
local fence = root .. '/fence.txt'
local fence_lines = {}
for i = 1, 400 do fence_lines[i] = string.format('fence %03d %s', i, string.rep('f', 40)) end
assert(host.write_file(fence, table.concat(fence_lines, '\n') .. '\n'), 'fixture fence.txt')
-- The outside anchor FIRST: an applied edit changes the version, and a page belongs to one version.
-- A refusal in code mode is a throw, so the run block catches it and returns what it said.
local fenced = value(run('const p = await tools.read({path:' .. json.encode(fence) .. ', limit:5});\n'
  .. 'let outside = null;\n'
  .. 'try { await tools.edit({path:p.path, edits:[{old_text:"fence 300 ", new_text:"FENCE 300 "}]}); }\n'
  .. 'catch (e) { outside = {message:String(e && e.message || e), code:e && e.code,'
  .. ' fix:String(e && e.fix || ""), data:e && e.data}; }\n'
  .. 'return {outside:outside, truncated:p.truncated, page:p.range};'))
check(fenced.truncated == true, 'the page the fence is judged against was partial: ' .. json.encode(fenced.truncated))
check(fenced.outside ~= nil, 'an anchor outside the served page is refused, not applied: ' .. json.encode(fenced.outside):sub(1, 400))
-- A refusal thrown into a script arrives as a sentence whose body is the refusal JSON; parse it so the
-- test asserts the fields a caller would act on, not the wrapper.
local said = {}
local parsed_ok, parsed = pcall(json.decode, tostring(fenced.outside.message))
if parsed_ok and type(parsed) == 'table' then said = parsed end
check(said.error == 'edit_anchor_outside_read_page',
  'and it is refused by its own name: ' .. tostring(fenced.outside.message):sub(1, 300))
check(said.anchor_line == 300, 'naming the line the anchor really sits on: ' .. tostring(said.anchor_line))
check(tostring(said.message):find('only part of this file', 1, true) ~= nil,
  'in words that say the page was partial: ' .. tostring(said.message))
check(tostring(said.fix):find('read', 1, true) ~= nil, 'with the way on: ' .. tostring(said.fix))
-- And the file is untouched by the refused edit.
check(host.read_file(fence) == table.concat(fence_lines, '\n') .. '\n', 'the refused edit wrote nothing')

-- 7. An anchor INSIDE the served page still edits: the fence refuses only what was never served.
local inside = value(run('const p = await tools.read({path:' .. json.encode(fence) .. ', limit:5});\n'
  .. 'const e = await tools.edit({path:p.path, edits:[{old_text:"fence 002 ", new_text:"FENCE 002 "}]});\n'
  .. 'return {edited:e.ok===true};'))
check(inside.edited == true, 'an anchor from the page that was served still edits: ' .. json.encode(inside))

-- 8. A whole-file read of the same version allows any anchor: the fence never refuses a caller who
-- was given every byte.
local small2 = root .. '/small2.txt'
assert(host.write_file(small2, 'one\ntwo\nthree\n'), 'fixture small2.txt')
local whole_ok = value(run('const p = await tools.read({path:' .. json.encode(small2) .. '});\n'
  .. 'const e = await tools.edit({path:p.path, edits:[{old_text:"three", new_text:"THREE"}]});\n'
  .. 'return {truncated:p.truncated, edited:e.ok===true};'))
check(whole_ok.truncated == false and whole_ok.edited == true,
  'a whole-file read leaves every anchor legal: ' .. json.encode(whole_ok))

print('read truncation ok (' .. checks .. ' checks)')
