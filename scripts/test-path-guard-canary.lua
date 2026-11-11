-- The 11/11 incident, end to end, as a gate test.
--
-- A `WA_SCRIPT` child is exactly how a test deleted the operator's home: that runner executes the
-- file directly, with no `lua/core/init.lua`, so for a while `host.exec` there was unguarded while the
-- guard's own unit test was green. This test does not test the module; it does what the incident did.
--
--   canary A - host.exec inside a WA_SCRIPT child, HOME pointed at a fresh scratch with a canary file
--   canary B - the bash tool in this process, same scratch, same delete
--
-- Both must refuse with `blocked_by=path_guard` and leave the canary file in place. Its scratch is
-- always this run's own `mktemp -d`, marked; it deletes nothing else.
local json = dofile('lua/vendor/json.lua')
local checks, failed = 0, 0
local function check(value, label, detail)
  checks = checks + 1
  if not value then failed = failed + 1; print('FAIL ' .. label .. (detail and (' :: ' .. tostring(detail):sub(1, 300)) or '')) end
end

-- The module is the guard's other half. With no Lua root a binary runs its embedded tree, and a
-- prebuilt binary from before path_guard.lua simply does not have it: say that by name, once.
local module_ok, guard = pcall(dofile, 'lua/core/path_guard.lua')
if not module_ok then
  print('SKIP path-guard canary: this Lua tree has no lua/core/path_guard.lua (embedded modules predate the guard; rebuild on wasm_the_first)')
  os.exit(0)
end

local function shell(command, extra_env)
  local prefix = extra_env and extra_env .. ' ' or ''
  local ok, raw = pcall(host.exec, prefix .. command, '', 120)
  if not ok or type(raw) ~= 'string' then return { code = -1, stdout = '', stderr = tostring(raw) } end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= 'table' then return { code = -1, stdout = '', stderr = tostring(raw) } end
  return decoded
end

local function q(text) return "'" .. tostring(text):gsub("'", "'\\''") .. "'" end

-- ---- this run's own scratch ----------------------------------------------------------------------
local made = shell('mktemp -d 2>/dev/null || mktemp -d -t wa-canary')
local scratch = tostring(made.stdout or ''):gsub('%s+$', '')
check(scratch ~= '', 'this test made its own scratch with mktemp', made.stderr)
if scratch == '' then print('path-guard canary: no scratch, so nothing was run'); os.exit(1) end
local marker = scratch .. '/.wa-test-scratch'
local token = tostring(host.uuid and host.uuid() or (host.now and host.now() or ''))
host.write_file(marker, 'test-path-guard-canary ' .. token .. '\n')
local canary = scratch .. '/canary.txt'
host.write_file(canary, 'keep\n')
check(host.read_file(canary) ~= nil, 'the canary file exists before the attempt')

local function canary_survived(label)
  check(host.read_file(canary) ~= nil, label .. ': the canary file survived')
end

-- ---- canary B: the bash tool, in this process ----------------------------------------------------
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local sid = memory.start_session('', 'path guard canary', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
local binned = tools.dispatch(memory, 'bash', { command = 'rm -rf "$HOME"' }, 'master', ctx)
local binned_said = tostring(binned.stderr or '') .. tostring(binned.error or '') .. tostring(binned.blocked_by or '')
check(binned.blocked_by == 'path_guard' or binned_said:find('path_guard', 1, true) ~= nil,
  'the bash tool refuses rm -rf "$HOME" by name', binned_said)
canary_survived('the bash tool')

-- ---- canary A: host.exec inside a WA_SCRIPT child ------------------------------------------------
local function find_binary()
  local function executable(path)
    if not path or path == '' then return nil end
    local ok, kind = pcall(host.path_kind, path)
    if ok and tostring(kind) == 'file' then return path end
    return nil
  end
  local explicit = host.getenv('WA_BIN') or host.getenv('WA_TEST_BIN') or host.getenv('FAST_BIN')
  local found = executable(explicit)
  if found then return found end
  local which = shell('command -v wa')
  if which.code == 0 then
    found = executable(tostring(which.stdout or ''):gsub('%s+$', ''))
    if found then return found end
  end
  local home = host.getenv('HOME') or ''
  for _, candidate in ipairs({ home .. '/.local/bin/wa', home .. '/.local/bin/wa.exe' }) do
    found = executable(candidate)
    if found then return found end
  end
  local root = host.getenv('WASM_AGENT_LUA_ROOT') or ''
  for _, name in ipairs({ 'wa', 'wa.exe' }) do
    found = executable(root .. '/rust/target/release/' .. name)
    if found then return found end
  end
  return nil
end

local bin = find_binary()
check(bin ~= nil, 'the node binary was found for the child run')
if bin then
  -- The probe is the incident in six lines: delete the home through host.exec, and report what came back.
  local probe = scratch .. '/probe.lua'
  host.write_file(probe,
    'local ok, raw = pcall(host.exec, "rm -rf \\"$HOME\\"", "")\n'
    .. 'print("PROBE ok=" .. tostring(ok))\n'
    .. 'print("PROBE raw=" .. tostring(raw))\n')
  local root = host.getenv('WASM_AGENT_LUA_ROOT')
  local child_env = 'HOME=' .. q(scratch) .. ' USERPROFILE=' .. q(scratch) .. ' WASM_AGENT_HOME=' .. q(scratch)
    .. (root and (' WASM_AGENT_LUA_ROOT=' .. q(root)) or '') .. ' WA_SCRIPT=' .. q(probe)
  local ran = shell(child_env .. ' ' .. q(bin) .. ' --db ' .. q(scratch .. '/t.db'), nil)
  local said = tostring(ran.stdout or '') .. tostring(ran.stderr or '')
  check(said:find('PROBE', 1, true) ~= nil, 'the child ran the probe', said)
  check(said:find('blocked_by', 1, true) ~= nil and said:find('path_guard', 1, true) ~= nil,
    'host.exec inside a WA_SCRIPT child refuses rm -rf "$HOME" with blocked_by=path_guard', said)
  canary_survived('a WA_SCRIPT child')
end

-- ---- cleanup: only this run's own marked directory -----------------------------------------------
local read_ok, text = pcall(host.read_file, marker)
if read_ok and type(text) == 'string' and text:find(token, 1, true) then
  if guard.command('rm -rf ' .. q(scratch)) then
    pcall(host.exec, 'rm -rf ' .. q(scratch), '', 30)
  end
end

print(json.encode({ ok = failed == 0, checks = checks, failed = failed, paid_calls = 0 }))
if failed > 0 then os.exit(1) end
