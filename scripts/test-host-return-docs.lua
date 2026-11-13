-- Every `host.*` capability in rust/wa-capabilities/src/host.rs states the encoding it really answers.
--
-- Why this exists (measured 12/11): `host.list_dir` was documented as `-> [{name, kind, size, modified}]`
-- and returns a JSON **string**. A caller that trusted the comment put it through `ipairs`, which
-- found nothing, and `#value` reported 41 - a scan that silently discovered no files and read exactly
-- like "there are none". The same review found 34 of 78 host capabilities answering JSON text while
-- their comments read as Lua tables. This test is the fence around that fix: a new `push_json`
-- capability with a comment that does not say so is a failure here, not a debugging cycle later.
--
-- It reads source, so it needs the tree: WASM_AGENT_LUA_ROOT (fast.sh sets it to this checkout). A
-- missing tree is a failure with a reason, never a silent pass.
local json = dofile('lua/vendor/json.lua')
local root = (host.getenv and host.getenv('WASM_AGENT_LUA_ROOT')) or ''
assert(type(root) == 'string' and root ~= '', 'WASM_AGENT_LUA_ROOT must name this checkout to read its source')
local path = root .. '/rust/wa-capabilities/src/host.rs'
local source = host.read_file(path)
assert(type(source) == 'string' and #source > 1000, 'the host capability source is unreadable: ' .. path)
local checks, failed = 0, 0
local function check(value, label)
  checks = checks + 1
  if not value then failed = failed + 1; print('FAIL ' .. label) end
end

local lines = {}
for line in (source .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end

-- One entry per capability: its name, the line of its signature, and the doc comment above it.
local caps = {}
for index, line in ipairs(lines) do
  local name = line:match('^pub%(crate%) extern "C%-unwind" fn ([%w_]+)') or line:match('^pub extern "C%-unwind" fn ([%w_]+)')
  if name then
    local doc, cursor = {}, index - 1
    while cursor >= 1 and lines[cursor]:match('^%s*///') do
      table.insert(doc, 1, lines[cursor]); cursor = cursor - 1
    end
    caps[#caps + 1] = { name = name, line = index, doc = table.concat(doc, '\n') }
  end
end
check(#caps > 50, 'the source yields the capability list (' .. #caps .. ' found)')

-- A capability answers through `push_json` (one JSON-text string) or pushes a Lua value itself. The
-- JSON-text ones must say so, and must say it is a string rather than a table: that is the exact
-- confusion that cost the 12/11 debugging cycle.
local json_answers, undocumented = 0, {}
for position, cap in ipairs(caps) do
  local stop = caps[position + 1] and caps[position + 1].line or #lines
  local body = table.concat(lines, '\n', cap.line, stop)
  if body:find('push_json', 1, true) then
    json_answers = json_answers + 1
    local says_json = cap.doc:find('JSON', 1, true) ~= nil
    local says_encoding = cap.doc:find('table', 1, true) ~= nil or cap.doc:find('string', 1, true) ~= nil
    if not (says_json and says_encoding) then undocumented[#undocumented + 1] = cap.name end
  end
end
check(json_answers >= 30, 'the JSON-text capabilities are found (' .. json_answers .. ' of ' .. #caps .. ')')
check(#undocumented == 0, 'every capability that answers JSON text says so: ' .. json.encode(undocumented))

-- `host.list_dir` specifically: the comment names the shape AND that it is one string, because that is
-- the one a caller reads first.
local list_dir
for _, cap in ipairs(caps) do if cap.name == 'list_dir' then list_dir = cap end end
check(list_dir ~= nil, 'host.list_dir is in the source')
if list_dir then
  check(list_dir.doc:find('entries', 1, true) ~= nil, 'list_dir documents the entries it answers')
  check(list_dir.doc:find('string', 1, true) ~= nil and list_dir.doc:find('decode', 1, true) ~= nil,
   'list_dir says it is a string a caller decodes, not a table to iterate')
  check(list_dir.doc:find('ipairs', 1, true) ~= nil, 'and names the mistake it used to cause')
end

-- The behaviour itself, so this is not only a spelling test: the real call is a string whose decode is
-- the object the comment promises.
local listing = host.list_dir(root)
check(type(listing) == 'string', 'host.list_dir answers a string, as its comment now says')
if type(listing) == 'string' then
  local decoded = json.decode(listing)
  check(type(decoded) == 'table' and type(decoded.entries) == 'table', 'and the string decodes to {path, entries}')
end
local missing = json.decode(host.list_dir(root .. '/no-such-directory-for-this-test'))
check(type(missing) == 'table' and missing.error ~= nil and missing.entries == nil,
 'a directory that does not exist answers an error object, never an empty list')

if failed > 0 then
  print('host return docs: ' .. failed .. ' of ' .. checks .. ' checks failed')
  error('host return docs failed')
end
print('host return docs ok (' .. checks .. ' checks; ' .. json_answers .. ' JSON-text capabilities documented)')
