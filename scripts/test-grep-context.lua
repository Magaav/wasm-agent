-- grep {context}: the lines around each match (mission tool-args-honest-and-same-on-peers, item 5).
--
-- The finding it answers: "a tools.grep on a peer returning line context, not just the matching lines,
-- would have shown the string boundary in one call". Context is now a field of the tool, so it is the same
-- on a peer as here - the peer path IS this call - and the default (0) returns exactly the answer this
-- search gave before the field existed, key for key, so nothing a model already reads changed.
--
-- What this row pins:
--   * default 0 and an explicit 0 are byte-identical answers, with no `context`/`before`/`after` key;
--   * 2 lines before and after each match, and a line two matches share appears ONCE (merged ranges);
--   * context lines are clipped and counted exactly as a matching line is;
--   * a window at the edge of the file stops at the edge instead of inventing lines;
--   * a range outside 0-10 is refused by name without running the search.
--
-- Run it with the tree's own binary: host.grep is a host capability.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local home = host.paths().home
local ctx = { user_id = 'master' }
local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end
local function grep(args) return tools.dispatch(memory, 'grep', args, 'master', ctx) end

local root = home .. '/grep-context'
assert(host.write_file(root .. '/a.txt', 'one\ntwo\nhit three\nfour\nhit five\nsix\nseven\n'),
  'the fixture file is written')
assert(host.write_file(root .. '/b.txt', string.rep('y', 500) .. '\nhit\n'), 'the clipping fixture is written')

-- 1. The default answer is unchanged: no context key, no windows, and identical to an explicit 0.
local plain = grep({ pattern = 'hit', path = root })
check(plain.context == nil, 'a default search carries no context key: ' .. json.encode(plain.context))
check(plain.matches[1].before == nil and plain.matches[1].after == nil, 'and no window keys')
local zero = grep({ pattern = 'hit', path = root, context = 0 })
check(json.encode(plain) == json.encode(zero), 'context=0 is the same answer as the default, byte for byte')

-- 2. The window around each match, and the shared line once.
local window = grep({ pattern = 'hit', path = root, context = 2 })
check(window.context == 2, 'the answer says which window it used')
local a = nil
for _, match in ipairs(window.matches) do if match.file:sub(-5) == 'a.txt' then a = match break end end
check(a ~= nil and a.line == 3, 'the first match in a.txt is line 3')
check(#a.before == 2 and a.before[1].text == 'one' and a.before[2].text == 'two',
  'two lines before: ' .. json.encode(a.before))
check(#a.after == 2 and a.after[1].text == 'four' and a.after[2].text == 'hit five',
  'two lines after, and the second match itself is inside the window: ' .. json.encode(a.after))
-- Line 4 is inside BOTH windows (it is the first match's second line after and the second match's first
-- line before). It appears once, as the earlier match's after, and the later match's before is empty.
local shared, second = 0, nil
for _, match in ipairs(window.matches) do
  if match.file:sub(-5) == 'a.txt' then
    for _, line in ipairs(match.after or {}) do if line.line == 4 then shared = shared + 1 end end
    for _, line in ipairs(match.before or {}) do if line.line == 4 then shared = shared + 1 end end
    if match.line == 5 then second = match end
  end
end
check(shared == 1, 'a line two windows share appears once across the answer: ' .. shared)
check(second ~= nil and #second.before == 0, 'and the later match does not repeat it: ' .. json.encode(second and second.before))

-- 3. A context line is clipped and counted like a matching line.
local clipped = nil
for _, match in ipairs(window.matches) do if match.file:sub(-5) == 'b.txt' then clipped = match break end end
check(clipped ~= nil and #clipped.before == 1, 'b.txt has one context line before its match: ' .. json.encode(clipped and clipped.before))
check(clipped.before[1].text_truncated == true and clipped.before[1].line_chars == 500,
  'the long context line is clipped and its real length counted: ' .. json.encode(clipped.before[1]):sub(1, 160))

-- 4. The window runs to the edge of the file and stops there (a.txt has seven lines).
check(second ~= nil and #second.after == 2 and second.after[2].text == 'seven',
  'the window runs to the last line: ' .. json.encode(second and second.after))

-- 5. A range outside 0-10 is refused by name, and nothing is searched.
local wide = grep({ pattern = 'hit', path = root, context = 11 })
check(wide.error == 'invalid_search_range' and wide.option == 'context', 'context above 10 is refused: ' .. json.encode(wide):sub(1, 200))
local fractional = grep({ pattern = 'hit', path = root, context = 1.5 })
check(fractional.error == 'invalid_search_range', 'a fractional context is refused: ' .. json.encode(fractional):sub(1, 160))

print(('grep context: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
