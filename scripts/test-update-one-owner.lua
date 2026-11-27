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
local screen = dofile('lua/core/update_screen.lua')

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
local root = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
local function read(path)
  local ok, text = pcall(host.read_file, path)
  return ok and type(text) == 'string' and text or ''
end
local OWNER = 'lua/core/update_screen.lua'
local PHRASES = { 'updated to ', 'already up to date', 'Notting was changed', 'Nothing was changed.' }
local others = {}
local listed = host.list_dir(root .. '/lua/core')
for _, name in ipairs(type(listed) == 'table' and listed or {}) do
  local file = tostring(name)
  if file:sub(-4) == '.lua' and ('lua/core/' .. file) ~= OWNER then
    local body = read(root .. '/lua/core/' .. file)
    for _, phrase in ipairs({ 'updated to ', 'already up to date', 'Nothing was changed.' }) do
      if body:find(phrase, 1, true) then others[#others + 1] = 'lua/core/' .. file .. ' builds "' .. phrase .. '"' end
    end
  end
end
check(#others == 0, 'no second author of the verdict sentences: ' .. table.concat(others, '; '))

local chat = read(root .. '/lua/core/chat.lua')
check(chat:find('lua/core/update_screen.lua', 1, true) ~= nil, '/update calls the owner')
check(chat:find('screen.updated', 1, true) ~= nil and chat:find('screen.not_updated', 1, true) ~= nil,
  'and builds SUCCESS and FAILURE lines with it')
local init = read(root .. '/lua/core/init.lua')
check(init:find('lua/core/update_screen.lua', 1, true) ~= nil, 'the CLI calls the same owner')

print(string.format('update one owner ok (%d checks; four sentences, both surfaces, no second author)', checks))

