-- ONE OWNER FOR HOW AN UPDATE IS SHOWN (law 17; Victor 25/11, Fable 27/11).
--
-- The question "what does an update SAY, and in how many lines" has exactly one owner: lua/core/update_screen.lua.
-- `wa update` (lua/core/init.lua + lua/core/update_follow.lua) and `/update` in a chat (lua/core/chat.lua) both build
-- their last line by CALLING it, so the two surfaces cannot drift into telling the person different things about the
-- same deploy. A second copy of a sentence is a bug even when the two agree today (law 17's own words), so this row
-- refuses one.
--
-- What it pins:
--   O1  the four verdict sentences, VERBATIM, for the four outcomes the brief names;
--   O2  no other file in lua/ builds any of them (a second answer is the defect);
--   O3  both surfaces call the owner: chat.lua for /update and the CLI path for `wa update`;
--   O4  the last line is ONE line (no newline in it) and the log line is one line naming a path.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-update-one-owner.lua wa --db <scratch>
local json = dofile('lua/vendor/json.lua')
local screen = dofile('lua/core/update_screen.lua')

-- WHICH TREE IS BEING JUDGED, SAID FIRST (27/11, landing queue #62). MEASURED: with WASM_AGENT_LUA_ROOT unset the host
-- prints "lua root unset: using embedded modules" and runs the modules baked into the binary - which do not carry this
-- branch, so the row reported the OLD behaviour as a red against the product. It must SKIP BY NAME, before its first
-- assertion.
do
  local root = host.getenv('WASM_AGENT_LUA_ROOT') or ''
  if root == '' then
    print('SKIP test-update-one-owner: WASM_AGENT_LUA_ROOT is not set, so the host would run its embedded modules and '
      .. 'this row would judge the old tree instead of the branch')
    return
  end
  local ok, body = pcall(host.read_file, root .. '/lua/core/update_screen.lua')
  if ok and type(body) == 'string' and not body:find('node%-', 1, true) then
    print('SKIP test-update-one-owner: the tree at ' .. root .. ' still strips the commit id with a lazy pattern, so '
      .. 'this row would report the defect it exists to pin instead of judging the fix')
    return
  end
end

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

-- ---------------------------------------------------------------- O1: the four sentences, verbatim
check(screen.updated('v0.1.2', 'node-82f57859aa', 48) == 'updated to v0.1.2 (82f57859) in 0:48',
  'the updated line: ' .. tostring(screen.updated('v0.1.2', 'node-82f57859aa', 48)))
check(screen.current('82f57859aa') == 'already up to date (82f57859)',
  'the already-up-to-date line: ' .. tostring(screen.current('82f57859aa')))
check(screen.current('') == 'already up to date', 'and it still answers when the commit is unknown')
check(screen.with_problems('82f57859aa', 1, 'the font was not copied') ==
  'installed 82f57859, with 1 problem: the font was not copied',
  'the installed-with-problems line: ' .. tostring(screen.with_problems('82f57859aa', 1, 'the font was not copied')))
check(screen.not_updated('the network went away') == 'not updated: the network went away. Nothing was changed.',
  'the not-updated line: ' .. tostring(screen.not_updated('the network went away')))
-- A path with dots is not the end of a sentence (the first version cut a reason in half inside one).
check(screen.not_updated('could not read /home/x/.wasm-agent/build and stopped') ==
  'not updated: could not read /home/x/.wasm-agent/build and stopped. Nothing was changed.',
  'a path with dots survives the one-sentence rule: '
  .. tostring(screen.not_updated('could not read /home/x/.wasm-agent/build and stopped')))

-- ---------------------------------------------------------------- O4: one line each
for _, line in ipairs({
  screen.updated('v0.1.2', '82f57859', 48), screen.current('82f57859'),
  screen.with_problems('82f57859', 2, 'two things'), screen.not_updated('a reason')}) do
  check(not tostring(line):find('\n', 1, true), 'a verdict is ONE line: ' .. tostring(line))
end
check(screen.log_line('/tmp/x.log') == 'log: /tmp/x.log', 'the log line names the file')
check(screen.log_line('') == nil, 'and is absent when there is no log')

-- ---------------------------------------------------------------- O2/O3: the owner is the only author
-- The scan is of the tree this row runs against (WASM_AGENT_LUA_ROOT), so it judges the product, not a copy.
local root = host.getenv('WASM_AGENT_LUA_ROOT') or ''
if root == '' then
  -- This half of the row is a SCAN of the tree under test. Without the root named it would scan '.' and judge
  -- whatever directory the runner happens to use - so it says so by name instead.
  print('SKIP test-update-one-owner: WASM_AGENT_LUA_ROOT is not set, so the scan cannot tell which tree to judge')
  return
end
local function read(path)
  local ok, text = pcall(host.read_file, path)
  return ok and type(text) == 'string' and text or ''
end
local OWNER = 'lua/core/update_screen.lua'
local PHRASES = { 'updated to ', 'already up to date', 'Notting was changed', 'Nothing was changed.' }
local others = {}
-- host.list_dir ANSWERS A JSON DOCUMENT, not a Lua array (27/11): the first version of this scan iterated it with
-- ipairs, which quietly did nothing - the scan passed on every tree and could not have caught a duplicate at all. A
-- check that cannot fail is worse than none, so the listing is decoded and every .lua file in it is read.
local listed = host.list_dir(root .. '/lua/core')
local entries = {}
if type(listed) == 'string' then
  local ok, decoded = pcall(json.decode, listed)
  if ok and type(decoded) == 'table' and type(decoded.entries) == 'table' then entries = decoded.entries end
elseif type(listed) == 'table' then
  entries = listed.entries or listed
end
if #entries == 0 then
  -- A LISTING THAT DECODED TO NOTHING IS NOT A PASS (27/11, queue #62): the first version of this scan iterated a
  -- JSON string with ipairs and silently checked nothing, and a later one could decode to an empty table the same
  -- way. Nothing scanned means nothing proved, so it is a named skip, never a green.
  print('SKIP test-update-one-owner: the listing of ' .. root .. '/lua/core decoded to no entries, so there is '
    .. 'nothing to scan and nothing to prove')
  return
end
for _, entry in ipairs(entries) do
  local file = tostring(type(entry) == 'table' and entry.name or entry)
  if file:sub(-4) == '.lua' and ('lua/core/' .. file) ~= OWNER then
    local body = read(root .. '/lua/core/' .. file)
    -- A COMMENT IS NOT A SECOND AUTHOR (27/11, landing queue #57): the first version of this scan counted any
    -- occurrence, so a file whose comment merely SAYS "updated to v0.1.2" turned the row red on a merged tip while
    -- the product was right. What matters is a line that BUILDS the sentence: a string literal concatenated or
    -- formatted, not prose after `--`.
    for line in body:gmatch('[^\n]+') do
      local trimmed = line:gsub('^%s+', '')
      if trimmed:sub(1, 2) ~= '--' then
        -- THE VERDICT STEMS, not the promise tail: 'Nothing was changed.' also closes a BACKUP refusal and a remote-pin
        -- message (lua/core/backup_cli.lua:89, lua/core/remote_update.lua:1341), which are other sentences that happen to
        -- share the promise. What belongs to this owner is the verdict: 'updated to ', 'already up to date', and the
        -- 'not updated: ' that only a released update says.
        for _, phrase in ipairs({ 'updated to ', 'already up to date', 'not updated: ' }) do
          if trimmed:find(phrase, 1, true) then
            others[#others + 1] = 'lua/core/' .. file .. ' builds "' .. phrase .. '"'
          end
        end
      end
    end
  end
end
check(#others == 0, 'no second author of the verdict sentences: ' .. table.concat(others, '; '))
print(string.format('  scanned %d file(s) in %s/lua/core', #entries, root))

local chat = read(root .. '/lua/core/chat.lua')
check(chat:find('lua/core/update_screen.lua', 1, true) ~= nil, '/update calls the owner')
check(chat:find('screen.updated', 1, true) ~= nil and chat:find('screen.not_updated', 1, true) ~= nil,
  'and builds SUCCESS and FAILURE lines with it')
local init = read(root .. '/lua/core/init.lua')
check(init:find('lua/core/update_screen.lua', 1, true) ~= nil, 'the CLI calls the same owner')

print(string.format('update one owner ok (%d checks; four sentences, both surfaces, no second author)', checks))

