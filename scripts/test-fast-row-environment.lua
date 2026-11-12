-- The runner's own promise, checked from inside a row: every variable `scripts/fast.sh` sets for a Lua
-- row reaches that row's node.
--
-- WHY THIS IS A ROW AND NOT A LINE IN THE RUNNER. A debug echo in `lua_run` prints what the *shell* has -
-- and in the incident this guards against the shell had the value while the node did not (measured on
-- wasm_the_first, 2026-11-10: `WA_FAST_COMPONENT_SOURCE` was exported, the row's shell printed it, and
-- `host.getenv` in the row returned nothing, so four graph tests installed no component and failed for a
-- reason three layers away from the code). Only the node can answer what the node sees.
--
-- So the runner writes the table it intends to hand over - `$FAST_WORK/env/<row>.env`, one `NAME=value`
-- per line, including `WA_FAST_ROW_ENV` itself and `WA_SCRIPT` - and this row compares that file with
-- `host.getenv`. A dropped variable is then a row that FAILS with its name in the message, in the same
-- table as any other check.
--
-- Absent - run by hand, or by the nightly gate, which sets nothing of this kind - it says so once and
-- returns. `scripts/fast.sh` refuses to call its own run green unless this row printed its ok line, so a
-- skipped probe there is a named failure and never a silent pass.
local path = host.getenv('WA_FAST_ROW_ENV')
if path == nil or path == '' then
  print('SKIP test-fast-row-environment: not run by scripts/fast.sh (WA_FAST_ROW_ENV is not set)')
  return
end

local text = host.read_file(path)
if type(text) ~= 'string' then
  error('fast-row-environment: the runner named ' .. tostring(path) .. ' but the row cannot read it')
end

local checks, failures = 0, {}
for line in text:gmatch('[^\r\n]+') do
  local name, want = line:match('^([^=]+)=(.*)$')
  if name then
    checks = checks + 1
    local got = host.getenv(name)
    if got ~= want then
      failures[#failures + 1] = string.format('%s: the runner set %q, the row saw %s', name, want,
        got == nil and 'nothing at all' or ('%q'):format(tostring(got)))
    end
  end
end

if checks == 0 then
  error('fast-row-environment: ' .. tostring(path) .. ' lists no variables, so nothing was checked')
end

-- The other half of the same promise, in the direction that matters in 11/11: a variable the runner says
-- it CLEARED must not reach the node. speed.log measured the leak - a fixture provider answered by the
-- operator's real vault route because the child inherited WASM_AGENT_VAULT_URL - so the runner removes
-- those variables for the whole run and lists them in WA_FAST_CLEARED. A row that still sees one fails
-- here, by name, instead of calling the operator's provider and passing.
local cleared = host.getenv('WA_FAST_CLEARED')
if cleared == nil or cleared == '' then
  error('fast-row-environment: the runner set no WA_FAST_CLEARED, so it does not say which variables this '
    .. 'row must not inherit (scripts/fast.sh, "the environment a row must never inherit")')
end
local cleared_count = 0
local home = host.getenv('WASM_AGENT_HOME') or ''
for name in cleared:gmatch('[^,]+') do
  cleared_count = cleared_count + 1
  local got = host.getenv(name)
  if got ~= nil and got ~= '' then
    if name == 'WASM_AGENT_VAULT_URL' then
      -- The provider redirect, and the measured harm: `provider.providers()` prefers this route over
      -- any base URL, so a row that still sees it is answered by the operator's real provider.
      failures[#failures + 1] = string.format(
        '%s: the runner cleared it but the row still sees %q - a fixture provider would be answered by '
          .. 'the operator\'s real vault (docs/VAULT.md, the measured run in speed.log)', name, tostring(got))
    elseif home == '' or got:sub(1, #home) ~= home then
      -- The other vault variables may legitimately be set AGAIN by the node itself: `wa` binds its own
      -- vault directory under HOME before anything reads it (rust/wa-host/src/main.rs,
      -- `bind_default_dir`), which is exactly how a scratch row is isolated. What must never survive is
      -- the operator's value - so the value has to live under this row's own home.
      failures[#failures + 1] = string.format(
        '%s: the runner cleared the operator\'s value but the row sees %q, which is not under its own '
          .. 'home %q', name, tostring(got), home)
    end
  end
end
if cleared_count == 0 then
  error('fast-row-environment: WA_FAST_CLEARED lists no variable, so nothing about clearing was checked')
end
if #failures > 0 then
  error('fast-row-environment: ' .. table.concat(failures, '; '))
end
print(('fast row environment ok (%d variables reached the node, %d cleared)'):format(checks, cleared_count))
