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

-- 9. review r1 MUST 1: the page recorded is the page RETURNED, not a pass of the shrink loop. A file
-- whose raw bytes fit but whose JSON-escaped form does not (control characters cost 6 bytes each in
-- JSON) used to record a whole-file page first and turn the fence off for the rest of the session.
local dense = root .. '/dense.txt'
local dense_lines = {}
for i = 1, 1500 do dense_lines[i] = string.rep('\1', 24) .. string.format('#%05d#', i) end
assert(host.write_file(dense, table.concat(dense_lines, '\n') .. '\n'), 'fixture dense.txt')
local shrunk = value(run('const p = await tools.read({path:' .. json.encode(dense) .. '});\n'
  .. 'let outside = null;\n'
  .. 'try { await tools.edit({path:p.path, edits:[{old_text:"#01499#", new_text:"#X#999#"}]}); }\n'
  .. 'catch (e) { outside = String(e && e.message || e); }\n'
  .. 'return {truncated:p.truncated, bytes_read:p.bytes_read, file_size:p.file_size,'
  .. ' last_line:p.range.last_line, outside:outside};'))
check(shrunk.truncated == true,
  'the escaped page is partial although the raw bytes fit: ' .. json.encode(shrunk.truncated))
check(shrunk.bytes_read < shrunk.file_size,
  'and it says so in bytes: ' .. tostring(shrunk.bytes_read) .. '/' .. tostring(shrunk.file_size))
check(shrunk.last_line < 1500, 'the returned page ends before the last line: ' .. tostring(shrunk.last_line))
check(shrunk.outside ~= nil,
  'and an anchor past the returned page is refused, not applied: ' .. tostring(shrunk.outside):sub(1, 300))
check(tostring(shrunk.outside):find('edit_anchor_outside_read_page', 1, true) ~= nil,
  'by its own name: ' .. tostring(shrunk.outside):sub(1, 300))
check(host.read_file(dense) == table.concat(dense_lines, '\n') .. '\n', 'the refused edit wrote nothing')

-- 10. review r1 SHOULD 2: an anchor whose two ends each sit inside a served page but which spans an
-- UNSERVED gap between them used to be applied. Coverage is now required from end to end.
-- Two fixtures: the first edit below really lands, and an applied edit changes the version, so the
-- spanning case gets a file of its own.
local gap = root .. '/gap.txt'
local gap_lines = {}
for i = 1, 300 do gap_lines[i] = string.format('gap %03d %s', i, string.rep('g', 40)) end
assert(host.write_file(gap, table.concat(gap_lines, '\n') .. '\n'), 'fixture gap.txt')
local span = root .. '/span.txt'
assert(host.write_file(span, table.concat(gap_lines, '\n') .. '\n'), 'fixture span.txt')
local spanning = value(run('const a = await tools.read({path:' .. json.encode(gap) .. ', offset:5, limit:1});\n'
  .. 'const b = await tools.read({path:' .. json.encode(gap) .. ', offset:200, limit:1});\n'
  .. 'const e = await tools.edit({path:a.path, edits:[{old_text:"gap 005 ", new_text:"GAP 005 "}]});\n'
  .. 'return {first:{first_line:a.range.first_line, last_line:a.range.last_line},'
  .. ' second:{first_line:b.range.first_line, last_line:b.range.last_line}, inside:e.ok===true};'))
check(spanning.first.last_line == 5 and spanning.second.first_line == 200,
  'the two served pages are disjoint: ' .. json.encode({spanning.first, spanning.second}))
check(spanning.inside == true, 'an anchor wholly inside one served page still edits: ' .. json.encode(spanning.inside))
-- The anchor that spans the unserved gap: its first line is served, its last line is served, and the
-- bytes between them were never returned by any read.
local cross = {}
for i = 5, 200 do cross[#cross + 1] = gap_lines[i] end
local wide = value(run('const d = ' .. json.encode(table.concat(cross, '\n')) .. ';\n'
  .. 'await tools.read({path:' .. json.encode(span) .. ', offset:5, limit:1});\n'
  .. 'await tools.read({path:' .. json.encode(span) .. ', offset:200, limit:1});\n'
  .. 'let said = null;\n'
  .. 'try { await tools.edit({path:' .. json.encode(span) .. ', edits:[{old_text:d, new_text:"X"}]}); }\n'
  .. 'catch (e) { said = String(e && e.message || e); }\n'
  .. 'return {said:said};'))
check(wide.said ~= nil, 'an anchor spanning the unserved gap is refused, not applied: '
  .. tostring(wide.said):sub(1, 300))
check(tostring(wide.said):find('edit_anchor_outside_read_page', 1, true) ~= nil,
  'by its own name: ' .. tostring(wide.said):sub(1, 300))
check(host.read_file(span) == table.concat(gap_lines, '\n') .. '\n', 'and it wrote nothing')

-- 11. review r1 SHOULD 1: a whole-file page does not repeat what offset/end_offset already say. The
-- three names the brief asks for stay; the range{} block exists only when the page is partial.
local lean = value(run('const r = await tools.read({path:' .. json.encode(small) .. '});\n'
  .. 'return {truncated:r.truncated, has_range:r.range!==undefined&&r.range!==null,'
  .. ' file_size:r.file_size, bytes:r.bytes, bytes_read:r.bytes_read, returned_bytes:r.returned_bytes,'
  .. ' offset:r.offset, end_offset:r.end_offset, total_lines:r.total_lines};'))
check(lean.truncated == false, 'the small file reads whole: ' .. json.encode(lean.truncated))
check(lean.has_range == false, 'a whole-file page carries no range{}: ' .. json.encode(lean.has_range))
check(lean.file_size == lean.bytes, 'file_size is still there (bytes kept equal): ' .. json.encode(lean))
check(lean.bytes_read == lean.returned_bytes, 'bytes_read is still there (returned_bytes kept equal)')
check(lean.offset == 1 and lean.total_lines == 3, 'and the cursor fields still say the whole thing: '
  .. json.encode(lean))

-- 12. review r1 SHOULD 5: a page of zero bytes says so, instead of a range whose last byte is before
-- its first ("returned bytes 18-17 of 17"), and carries no last_byte/last_line it does not have.
local past = value(run('const r = await tools.read({path:' .. json.encode(small) .. ', offset:4});\n'
  .. 'return {truncated:r.truncated, bytes_read:r.bytes_read, file_size:r.file_size,'
  .. ' how:r.how_to_read_rest, truncation:r.truncation, range:r.range};'))
check(past.bytes_read == 0 and past.file_size == 17,
  'the line past the last one returns zero bytes: ' .. json.encode({past.bytes_read, past.file_size}))
check(past.truncated == true, 'and is truncated (earlier lines were not returned)')
check(tostring(past.how):find('no bytes returned', 1, true) ~= nil,
  'the sentence says no bytes, not a backwards range: ' .. tostring(past.how))
check(tostring(past.how):find('18%-17') == nil, 'and never prints a backwards range: ' .. tostring(past.how))
check(past.truncation ~= nil and past.truncation.last_byte == nil
  and past.truncation.last_line == nil,
  'the truncation carries no last_byte/last_line it does not have: ' .. json.encode(past.truncation))
check(past.truncation ~= nil and past.truncation.first_byte == 18,
  'and still names where the (empty) page starts: ' .. json.encode(past.truncation))
check(past.range ~= nil and past.range.first_byte == 18 and past.range.last_byte == nil
  and past.range.last_line == nil,
  'and range{} carries no backwards last_byte either: ' .. json.encode(past.range))

-- 13. review r1 SHOULD 3: the fence's EDGES, in one place, because each one is a way the fence could
-- refuse work it has no business refusing (unknown is not yes: only a page this session was served
-- may refuse).
local edge = root .. '/edge.txt'
local edge_lines = {}
for i = 1, 400 do edge_lines[i] = string.format('edge %03d %s', i, string.rep('e', 40)) end
local edge_text = table.concat(edge_lines, '\n') .. '\n'
assert(host.write_file(edge, edge_text), 'fixture edge.txt')

-- (a) a partial read then a WHOLE-FILE read of the same version clears the fence: the caller has now
-- been given every byte, so no anchor can be outside what it saw.
local cleared = value(run('const p1 = await tools.read({path:' .. json.encode(edge) .. ', limit:5});\n'
  .. 'const p2 = await tools.read({path:p1.path});\n'
  .. 'const e = await tools.edit({path:p2.path, edits:[{old_text:"edge 300 ", new_text:"EDGE 300 "}]});\n'
  .. 'return {first:p1.truncated, second:p2.truncated, edited:e.ok===true};'))
check(cleared.first == true and cleared.second == false,
  'a partial page then a whole-file page: ' .. json.encode({cleared.first, cleared.second}))
check(cleared.edited == true, 'and the whole-file page clears the fence for any anchor')

-- (b) a file this session never read carries no record, so an edit is not fenced (nothing was
-- promised). This is the fail-open the report states.
local never = root .. '/never.txt'
assert(host.write_file(never, 'one\ntwo\nthree\n'), 'fixture never.txt')
local unread = value(run('const e = await tools.edit({path:' .. json.encode(never) .. ','
  .. ' edits:[{old_text:"two", new_text:"TWO"}]});\nreturn {edited:e.ok===true};'))
check(unread.edited == true, 'a never-read file is not fenced: ' .. json.encode(unread))

-- (c) a DIFFERENT session is not judged by this one's page. The record is keyed by scope, so a
-- second session editing an anchor it never read is not refused by the first session's read.
local other = root .. '/other.txt'
assert(host.write_file(other, edge_text), 'fixture other.txt')
local first_read = tools.dispatch(memory, 'tool_call',
  { calls = { { name = 'read', arguments = { path = other, limit = 5 } } } }, 'master', ctx)
check(first_read ~= nil and first_read.error == nil, 'the first session read a partial page: '
  .. json.encode(first_read):sub(1, 200))
local other_sid = memory.start_session('', 'read truncation other', { user_id = 'master' })
local other_ctx = { session_id = other_sid, user_id = 'master' }
local cross = tools.dispatch(memory, 'edit',
  { path = other, edits = { { old_text = 'edge 300 ', new_text = 'EDGE 300 ' } } }, 'master', other_ctx)
check(cross.applied == true,
  'another session is not fenced by a page it was never served: ' .. json.encode(cross):sub(1, 300))

-- (d) the file changed on disk after the partial read: the fence does not judge a version it has no
-- page for, and the edit's own version check is what answers. A stale anchor still gets a named
-- refusal (old_text_not_found or file_changed), never a silent apply.
assert(host.write_file(other, edge_text .. 'edge 401 extra\n'), 'fixture other.txt changed')
local moved = tools.dispatch(memory, 'edit',
  { path = other, edits = { { old_text = 'edge 300 ', new_text = 'EDGE 300 ' } } }, 'master', ctx)
check(moved.applied == true or moved.error ~= nil,
  'an edit after the file changed is decided, never silently lost: ' .. json.encode(moved):sub(1, 300))

-- (e) a WRITE after a partial read is not fenced: the fence is about an anchor quoted from a page,
-- and write carries its own whole content.
local written = root .. '/written.txt'
assert(host.write_file(written, edge_text), 'fixture written.txt')
local write_after = value(run('const p = await tools.read({path:' .. json.encode(written) .. ', limit:5});\n'
  .. 'const w = await tools.write({path:p.path, content:"replaced"});\n'
  .. 'return {read_truncated:p.truncated, wrote:w.ok===true};'))
check(write_after.read_truncated == true and write_after.wrote == true,
  'a write after a partial read is not fenced: ' .. json.encode(write_after))

print('read truncation ok (' .. checks .. ' checks)')
