-- The path guard (lua/core/path_guard.lua): a recursive delete may not take a root, a home or anything
-- that contains one. Negative controls first - the five shapes the operator named - then the allow
-- case, then the two walls (host.exec and the bash tool), then a structural check on the test that
-- caused the 11/11 loss.
--
-- This test deletes exactly one directory: the `mktemp -d` it created itself one line earlier.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('lua/core/path_guard.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local tools = dofile('lua/core/tools.lua')
local checks, failed = 0, 0
local function check(value, label)
  checks = checks + 1
  if not value then failed = failed + 1; print('FAIL ' .. label) end
end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then failed = failed + 1
    print('FAIL ' .. label .. ' (got ' .. tostring(actual) .. ', wanted ' .. tostring(expected) .. ')') end
end

local function envor(name, fallback)
  local ok, value = pcall(host.getenv, name)
  if ok and type(value) == 'string' and value ~= '' then return value end
  return fallback
end
local home = envor('HOME', '')
local profile = envor('USERPROFILE', '')
local node_home = envor('WASM_AGENT_HOME', '')

-- ---- normalisation ------------------------------------------------------------------------------
eq(guard.normalise('/a/./b/../c//'), '/a/c', 'dot and double separators resolve')
eq(guard.normalise('C:\\Users\\Victor\\'), guard.normalise('c:/users/victor'), 'windows case and backslashes are one path')
eq(guard.normalise('/..'), '/', 'climbing past the root stops at the root')
check(guard.normalise('') == nil, 'an empty path has no meaning')

-- ---- the five negative controls ---------------------------------------------------------------
local refused = {
  { 'rm -rf ' .. home, 'rm -rf $HOME' },
  { 'rm -rf "' .. node_home .. '"', 'rm -rf "$WASM_AGENT_HOME"' },
  { 'rm -rf C:/Users/Victor', 'rm -rf C:/Users/Victor' },
  { 'rm -rf /', 'rm -rf /' },
  { 'rm -rf ' .. home .. '/.wasm-agent', 'rm -rf ~/.wasm-agent' },
}
for _, case in ipairs(refused) do
  local ok, reason = guard.command(case[1])
  check(not ok, 'refused: ' .. case[2])
  check(type(reason) == 'string' and reason:find('path_guard', 1, true) ~= nil, 'the refusal names the guard: ' .. case[2])
end
-- The tilde form must be judged as the home it means, not as a literal directory called "~".
local tilde_ok = guard.command('rm -rf ~/.wasm-agent')
check(not tilde_ok, 'a tilde path to the node state is expanded before the check')
-- Ancestors: deleting what CONTAINS a home is the same loss.
if home ~= '' then
  local parent = home:gsub('/[^/]+$', '')
  if parent ~= '' and parent ~= home then
    check(not guard.command('rm -rf ' .. parent), 'an ancestor of HOME is refused (' .. parent .. ')')
  end
end
-- A computed target is NOT refused for being computed: the runtime wall expands it and judges the
-- result. `T=$(mktemp -d); rm -rf "$T"` is what a test should do, and it must work.
check(guard.command('rm -rf "$SOME_DIR"') == true, 'a variable target passes the static wall (the runtime wall judges it)')
check(guard.command('rm -rf $(mktemp -d)') == true, 'a command substitution target passes the static wall')

-- ---- the allow case: a directory this run made and marked ---------------------------------------
local function shell(command)
  local ok, raw = pcall(host.exec, command, '', 30)
  if not ok or type(raw) ~= 'string' then return nil end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= 'table' then return nil end
  return tostring(decoded.stdout or ''):gsub('%s+$', '')
end
local scratch = shell('mktemp -d 2>/dev/null || mktemp -d -t wa-path-guard')
check(scratch ~= nil and scratch ~= '', 'this test made its own scratch with mktemp')
if scratch and scratch ~= '' then
  local marked = scratch .. '/.wa-test-scratch'
  check(host.write_file(marked, 'test-path-guard\n'), 'and marked it')
  local allow, why = guard.command("rm -rf '" .. scratch .. "'")
  check(allow, 'a markered mktemp directory is allowed (' .. tostring(why) .. ')')
  -- The allow case must actually delete, or "allowed" would mean nothing.
  shell("rm -rf '" .. scratch .. "'")
  check(host.read_file(marked) == nil, 'the allowed delete removed the marked scratch')
end

-- ---- wall one: host.exec, wrapped once ----------------------------------------------------------
check(guard.install(host), 'the wrapper is installed')
check(guard.install(host), 'and installing it twice is a no-op')
local calls = 0
local real_exec = host.exec
host.__path_guard_installed = nil
host.exec = function(...) calls = calls + 1; return real_exec(...) end
guard.install(host)
local raw = host.exec('rm -rf "' .. (home ~= '' and home or '/') .. '"', '', 5)
local decoded = json.decode(raw)
check(calls == 0, 'a refused command never reaches the shell (no exec call)')
check(decoded and decoded.blocked_by == 'path_guard' and tostring(decoded.error):find('protected path', 1, true) ~= nil,
  'the refusal is the operation shape, with the guard named: ' .. tostring(raw))
if home ~= '' then
  local kind_ok, kind = pcall(function() return host.path_kind(home) end)
  check(kind_ok and tostring(kind):find("dir", 1, true) ~= nil, "HOME still exists after the refused delete")
end

-- ---- wall two: the resolved target, through the bash tool --------------------------------------
local sid = memory.start_session('', 'path guard', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
-- EXPANDED form of the 11/11 loss: "$HOME" is not a literal, and it must still be refused - by the
-- prelude, after the shell expanded it. The proof is not an exit code (a shell keeps going after a
-- refused command, and that is normal): it is that the directory and a file inside it survive.
if home ~= '' then
  local made = tools.dispatch(memory, 'bash', { command = 'printf survives > "$HOME/keep.txt"; cat "$HOME/keep.txt"' }, 'master', ctx)
  check(tostring(made.stdout or ''):find('survives', 1, true) ~= nil, 'a file inside HOME was written before the attempt')
end
local expanded = tools.dispatch(memory, 'bash', { command = 'H="$HOME"; rm -rf "$H"; echo after' }, 'master', ctx)
local said = tostring(expanded.stderr or '') .. tostring(expanded.error or '')
check(said:find('path_guard', 1, true) ~= nil, 'H=$HOME; rm -rf "$H" is refused by name: ' .. said:sub(1, 200))
if home ~= '' then
  check(host.read_file(home .. '/keep.txt') ~= nil, 'and the file inside HOME survived the refused delete')
  check(host.path_kind(home) == 'dir', 'and HOME is still a directory')
end
-- The same shape, allowed: a directory this run made. This is the idiom the 66 regressions used.
local own = tools.dispatch(memory, 'bash', { command = 'T=$(mktemp -d); echo x > "$T/f"; rm -rf "$T"; if [ -e "$T" ]; then echo kept; else echo gone; fi' }, 'master', ctx)
check(own.ok == true and tostring(own.stdout or ''):find('gone', 1, true) ~= nil,
  'T=$(mktemp -d); rm -rf "$T" is allowed and actually deletes: ' .. json.encode(own):sub(1, 200))
-- `command rm` walks past a function; the prelude intercepts the builtin too.
local bypass = tools.dispatch(memory, 'bash', { command = 'H="$HOME"; command rm -rf "$H"; echo after' }, 'master', ctx)
check((tostring(bypass.stderr or '') .. tostring(bypass.error or '')):find('path_guard', 1, true) ~= nil,
  'command rm is refused as well: ' .. json.encode(bypass):sub(1, 200))
local root_delete = tools.dispatch(memory, 'bash', { command = 'rm -rf /' }, 'master', ctx)
check(tostring(root_delete.stderr or root_delete.error):find('path_guard', 1, true) ~= nil, 'a root delete is refused')
-- An ordinary command still runs: the guard is a fence, not a wall in front of everything.
local fine = tools.dispatch(memory, 'bash', { command = 'echo path-guard-ok' }, 'master', ctx)
check(fine.ok == true and tostring(fine.stdout or ''):find('path-guard-ok', 1, true) ~= nil, 'an ordinary command is untouched')
check(tostring(fine.stdout or ''):find('__wa_path_guard', 1, true) == nil, 'and carries no prelude bytes')

-- ---- the cause: the test that deleted a home ----------------------------------------------------
-- Read the tree under test, not the process's working directory: a run started inside another checkout
-- would otherwise inspect the wrong copy of the file and pass while the fixed one goes unread.
local repo = envor('WASM_AGENT_LUA_ROOT', dofile('lua/core/platform.lua').cwd())
local source = host.read_file(repo .. '/scripts/test-update-banner.lua') or ''
check(source ~= '', 'the banner test was read')
check(source:find('host.getenv("WASM_AGENT_HOME")', 1, true) == nil,
  'the banner test no longer takes its scratch from the environment')
check(source:find('mktemp -d', 1, true) ~= nil and source:find('.wa-test-scratch', 1, true) ~= nil,
  'it makes its own marked scratch')
check(source:find('local function cleanup()', 1, true) ~= nil and source:find('token, 1, true', 1, true) ~= nil,
  'and deletes only a directory that still carries the marker it wrote')

print(json.encode({ ok = failed == 0, checks = checks, failed = failed, paid_calls = 0 }))
if failed > 0 then os.exit(1) end
