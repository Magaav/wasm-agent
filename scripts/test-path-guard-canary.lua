-- The 11/11 incident, end to end, as a gate test.
--
-- A `WA_SCRIPT` child is exactly how a test deleted the operator's home: that runner executes the file
-- directly, with no `lua/core/init.lua`, so for a while `host.exec` there had no wrapper at all while the
-- guard's own unit test (`scripts/test-path-guard.lua`) was green. This test does not test the module; it
-- does what the incident did, on the entry path it took:
--
--   this process - is the guard installed in a `WA_SCRIPT` runner at all (`host.__path_guard_installed`),
--                  and does the bash tool still run an ordinary command and delete a file of ours
--   the child    - a real `WA_SCRIPT` run with HOME, USERPROFILE and WASM_AGENT_HOME at this test's own
--                  scratch, a canary file inside it, and two ways to ask for the delete: `host.exec`
--                  directly (the incident) and the bash tool (`tools.dispatch`). Both must answer
--                  `blocked_by=path_guard`, and the canary must still be there afterwards.
--
-- SAFETY, and why it is built this way: every command that tries to delete a home runs in the CHILD, whose
-- home is a directory this test created with `mktemp -d` and marked. In this process the bash tool only
-- removes a file this test wrote. A canary that runs `rm -rf "$HOME"` in the gate's own process to prove
-- the guard works is one guard bug away from repeating 11/11 on the machine running the gate - and the
-- fast path gives a row no `HOME` of its own, so that process's home is the operator's.
--
-- WHICH BINARY. The child is the tree's own `rust/target/release/wa` when there is one, because the row is
-- about the tree under test; `WA_TEST_BIN` overrides and is then the only binary considered. A binary that
-- predates this change cannot answer a question about it - the embedded Lua copy only changes with a
-- rebuild, so every prebuilt binary up to this commit still lets a `WA_SCRIPT` delete its home - so the
-- first candidate that reports a guard is the one gated on, and the others are named. When NO binary here
-- has it, the tree's own Rust decides: `rust/wa-host/src/main.rs` installs the guard or it does not, and
-- only the second is a failure. A machine with an old binary gets a named SKIP, never a quiet pass.
local json = dofile('lua/vendor/json.lua')
local checks, failed = 0, 0
local function check(value, label, detail)
  checks = checks + 1
  if not value then failed = failed + 1
    print('FAIL ' .. label .. (detail and (' :: ' .. tostring(detail):sub(1, 600)) or '')) end
end

local function envor(name)
  local ok, value = pcall(host.getenv, name)
  if ok and type(value) == 'string' and value ~= '' then return value end
  return nil
end

local function q(text) return "'" .. tostring(text):gsub("'", "'\\''") .. "'" end
local function trimmed(text) return (tostring(text or ''):gsub('%s+$', '')) end

-- The module is the guard's other half. With no Lua root a binary runs its embedded tree, and a binary
-- from before path_guard.lua simply does not have it: say that by name, once.
local module_ok, guard = pcall(dofile, 'lua/core/path_guard.lua')
if not module_ok then
  print('SKIP path-guard canary: this Lua tree has no lua/core/path_guard.lua (embedded modules predate the guard; rebuild on wasm_the_first)')
  os.exit(0)
end

local function shell(command)
  local ok, raw = pcall(host.exec, command, '', 120)
  if not ok or type(raw) ~= 'string' then return { code = -1, stdout = '', stderr = tostring(raw) } end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= 'table' then return { code = -1, stdout = '', stderr = tostring(raw) } end
  return decoded
end

-- One line of a child's own output, decoded where it is JSON.
local function said_line(said, prefix)
  for line in tostring(said):gmatch('[^\n]+') do
    if line:sub(1, #prefix + 1) == prefix .. ' ' then
      local payload = line:sub(#prefix + 2)
      local decoded_ok, decoded = pcall(json.decode, payload)
      if decoded_ok and type(decoded) == 'table' then return decoded end
      return payload
    end
  end
  return nil
end

-- ---- this run's own scratch: the home the child will be told it has ---------------------------------
local made = shell('mktemp -d 2>/dev/null || mktemp -d -t wa-canary')
local scratch = trimmed(made.stdout)
check(scratch ~= '', 'this test made its own scratch with mktemp', made.stderr)
if scratch == '' then print('path-guard canary: no scratch, so nothing was run'); os.exit(1) end
local token = tostring(host.uuid and host.uuid() or (host.now and host.now() or ''))
local marker = scratch .. '/.wa-test-scratch'
host.write_file(marker, 'test-path-guard-canary ' .. token .. '\n')
local fake_home = scratch .. '/home'
check(shell('mkdir -p ' .. q(fake_home)).code == 0, 'the scratch home was made')
host.write_file(fake_home .. '/canary.txt', 'keep\n')
check(host.read_file(fake_home .. '/canary.txt') ~= nil, 'the canary file exists before any delete is attempted')

local function cleanup()
  -- Only this run's own marked directory, and only while it still carries the marker this run wrote.
  local read_ok, text = pcall(host.read_file, marker)
  if read_ok and type(text) == 'string' and text:find(token, 1, true) and guard.command('rm -rf ' .. q(scratch)) then
    pcall(host.exec, 'rm -rf ' .. q(scratch), '', 30)
  end
end

-- ---- this process: a `WA_SCRIPT` runner gets the guard before its first line -------------------------
-- The incident was an entry point with no install, so the first question is whether THIS script - run by
-- the same runner - had `host.exec` wrapped before it ran. A binary from before this change answers no for
-- a reason that is about the machine and not the tree, and the tree's own Rust is what tells them apart
-- (`install_in_tree` below), so a no here is reported and the child below carries the verdict.
local in_process = host.__path_guard_installed == true
if in_process then
  check(true, 'the guard is installed in this WA_SCRIPT process (host.exec was wrapped before the script ran)')
else
  print('canary: this row\'s own binary does not install the guard (it predates the fix); the tree\'s Rust and the child below decide')
end

-- And the wrapper is a fence, not a blanket refusal: an ordinary command still runs, and the bash tool
-- still deletes a file of ours - in this process, on a path this test owns.
local ordinary = shell('echo path-guard-canary-ok')
check(ordinary.ok == true and tostring(ordinary.stdout or ''):find('path-guard-canary-ok', 1, true) ~= nil,
  'an ordinary command still runs through the wrapped host.exec', ordinary.stderr)
local throwaway = scratch .. '/throwaway.txt'
host.write_file(throwaway, 'x\n')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local sid = memory.start_session('', 'path guard canary', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
local removed = tools.dispatch(memory, 'bash', { command = 'rm -f ' .. q(throwaway) }, 'master', ctx)
check(host.read_file(throwaway) == nil and (removed.ok == true or removed.code == 0),
  'the bash tool still deletes a file this test owns (the guard is not a blanket refusal)',
  tostring(removed.stderr or removed.error or ''))

-- ---- the incident, in a child whose HOME is this test's scratch --------------------------------------
-- The probe: report whether the runner installed the guard, then ask for the delete twice - once through
-- `host.exec` (the incident path) and once through the bash tool - and report the canary.
local probe = scratch .. '/probe.lua'
host.write_file(probe, table.concat({
  'local json = dofile("lua/vendor/json.lua")',
  'print("GUARD " .. tostring(host.__path_guard_installed))',
  'local ok, raw = pcall(host.exec, [[rm -rf "$HOME"]], "")',
  'print("EXEC " .. tostring(raw))',
  'local memory = dofile("lua/core/memory.lua"); memory.setup()',
  'local tools = dofile("lua/core/tools.lua")',
  'local sid = memory.start_session("", "canary child", { user_id = "master" })',
  'local ctx = { session_id = sid, user_id = "master", role = "master" }',
  'local tool = tools.dispatch(memory, "bash", { command = [[rm -rf "$HOME"]] }, "master", ctx)',
  'print("TOOL " .. json.encode(tool))',
  'print("CANARY " .. tostring(host.read_file(host.getenv("HOME") .. "/canary.txt") ~= nil))',
  '',
}, '\n'))

local function executable(path)
  if not path or path == '' then return nil end
  local ok, kind = pcall(host.path_kind, path)
  if ok and tostring(kind) == 'file' then return path end
  return nil
end

local function tree_binary()
  local root = envor('WASM_AGENT_LUA_ROOT')
  if not root then return nil end
  for _, name in ipairs({ 'wa', 'wa.exe' }) do
    local found = executable(root .. '/rust/target/release/' .. name)
    if found then return found end
  end
  return nil
end

local function installed_binary()
  for _, name in ipairs({ 'wa', 'wa.exe' }) do
    local which = shell('command -v ' .. name)
    if which.code == 0 then
      local found = executable(trimmed(which.stdout))
      if found then return found end
    end
  end
  local home = envor('HOME') or ''
  for _, path in ipairs({ home .. '/.local/bin/wa', home .. '/.local/bin/wa.exe' }) do
    local found = executable(path)
    if found then return found end
  end
  return nil
end

-- Run the incident against one binary, in its own scratch home, and answer what it did.
local function incident(bin, label)
  local home = scratch .. '/' .. label:gsub('[^%w]', '-')
  shell('mkdir -p ' .. q(home))
  host.write_file(home .. '/canary.txt', 'keep\n')
  local root = envor('WASM_AGENT_LUA_ROOT')
  local prefix = 'HOME=' .. q(home) .. ' USERPROFILE=' .. q(home) .. ' WASM_AGENT_HOME=' .. q(home)
    .. (root and (' WASM_AGENT_LUA_ROOT=' .. q(root)) or '') .. ' WA_SCRIPT=' .. q(probe)
  local ran = shell(prefix .. ' ' .. q(bin) .. ' --db ' .. q(home .. '/t.db'))
  local said = tostring(ran.stdout or '') .. tostring(ran.stderr or '')
  return { bin = bin, said = said, guard = (said_line(said, 'GUARD') == 'true'),
    survived = host.read_file(home .. '/canary.txt') ~= nil }
end

local candidates, listed = {}, {}
local pinned = envor('WA_TEST_BIN')
local function candidate(path)
  if path and not listed[path] then listed[path] = true; candidates[#candidates + 1] = path end
end
if pinned then
  candidate(executable(pinned))
else
  candidate(tree_binary())
  candidate(executable(envor('WA_BIN')))
  candidate(executable(envor('FAST_BIN')))
  candidate(installed_binary())
end
check(#candidates > 0, 'a node binary was found to run the child')

-- What the TREE says it does, which no binary's vintage can change: the bootstrap in `boot_state` is the
-- one place every interpreter is built, so an install there reaches the WA_SCRIPT runner, serve, the CLI
-- and every child. Read from `WASM_AGENT_LUA_ROOT`; with no root there is nothing to read.
local root = envor('WASM_AGENT_LUA_ROOT')
local tree_source = root and (host.read_file(root .. '/rust/wa-host/src/main.rs') or '') or ''
local install_in_tree = tree_source:find("path_guard.lua').install(host)", 1, true) ~= nil

local chosen, last_ran
for _, bin in ipairs(candidates) do
  local ran = incident(bin, 'home')
  last_ran = ran
  if ran.guard then
    chosen = ran
    break
  end
  print(string.format('canary: %s -> guard=absent canary=%s (this binary predates the fix; it needs the rebuild)',
    bin, ran.survived and 'survived' or 'DELETED'))
end

if not chosen then
  -- No binary on this machine installs the guard. That is either this machine (an old binary: a rebuild
  -- fixes it) or this tree (no install at all: the incident's cause, and never a skip). A pinned
  -- WA_TEST_BIN is a harness asking about that binary, so its verdict is the row's verdict, not a skip.
  if pinned then
    check(false, 'the pinned binary installs the guard before a WA_SCRIPT script runs',
      pinned .. ' reports guard=absent and its canary was '
        .. ((last_ran and last_ran.survived) and 'still there' or 'DELETED')
        .. ' - a binary from before this change, rebuild it (cargo build --release)')
  elseif root == nil then
    print('SKIP path-guard canary: no Lua root here, so rust/wa-host/src/main.rs cannot be read to tell an old binary from a tree without the install, and the embedded modules are this binary\'s (rebuild: cargo build --release, then run again)')
  elseif not install_in_tree then
    check(false, 'the tree installs the guard in every interpreter (rust/wa-host/src/main.rs bootstrap)',
      'the bootstrap installs no path guard, so a WA_SCRIPT run gets none: this is the 11/11 cause')
  else
    print('SKIP path-guard canary: this tree installs the guard and no binary on this machine has it yet ('
      .. table.concat(candidates, ', ') .. ' predate the fix) - rebuild: cargo build --release, or deploy the new binary')
  end
  cleanup()
  print(json.encode({ ok = failed == 0, checks = checks, failed = failed, paid_calls = 0 }))
  os.exit(failed == 0 and 0 or 1)
end

print('canary: child binary ' .. chosen.bin .. ' (Lua root '
  .. (envor('WASM_AGENT_LUA_ROOT') or 'unset: embedded modules') .. ')')
local direct = said_line(chosen.said, 'EXEC')
check(type(direct) == 'table' and direct.blocked_by == 'path_guard',
  'host.exec inside a WA_SCRIPT child refuses rm -rf "$HOME" with blocked_by=path_guard', chosen.said)
check(type(direct) == 'table' and (direct.code or 0) ~= 0 and direct.stderr
    and tostring(direct.stderr):find('path_guard', 1, true) ~= nil,
  'and the refusal is the guard\'s own message, not a crash', direct and direct.stderr)
local via_tool = said_line(chosen.said, 'TOOL')
check(type(via_tool) == 'table' and via_tool.blocked_by == 'path_guard',
  'the bash tool in that child refuses rm -rf "$HOME" with blocked_by=path_guard', chosen.said)
check(said_line(chosen.said, 'CANARY') == 'true', 'the child saw its canary file after both attempts', chosen.said)
check(chosen.survived, 'the canary file in the child\'s home survived both attempts')

cleanup()
print(json.encode({ ok = failed == 0, checks = checks, failed = failed, paid_calls = 0 }))
if failed > 0 then os.exit(1) end
