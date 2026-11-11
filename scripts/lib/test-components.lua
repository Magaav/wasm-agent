-- A real WASI component, for a test whose subject is one (docs/COMPONENTS.md).
--
-- WHERE A TEST'S NODE LOOKS. `component_dir()` (rust/wa-host-support/src/paths.rs) is `WA_COMPONENTS_DIR`
-- when it is set, else `$HOME/.wasm-agent/components`. `scripts/fast.sh` gives every row its own scratch
-- home and the node publishes that home as HOME, so the directory is *empty* unless something puts a
-- component in it: a test that ran against it proved nothing while it passed, and failed on the node's
-- honest `component_not_installed:<name>`, which says nothing about this tree.
--
-- HOW THE COMPONENT GETS THERE. The nightly gate builds `graph` once and exports WA_COMPONENTS_DIR for
-- the whole run (scripts/test.sh). The fast path's rows are hermetic and run in parallel, so they cannot
-- share one directory: `scripts/fast.sh` builds the same pinned set from this tree once, and this module
-- copies the component a test asks for into that test's OWN directory. Only a test that calls
-- `require('graph')` pays the copy, and the pin is re-checked here the way the loader checks it, so a
-- copy that went wrong is named rather than surfacing as a component that "did not answer".
--
-- WHAT A TEST DOES WHEN IT IS ABSENT. `require` returns `false, reason` and the reason names what is
-- missing and the command that would build it; the test prints `SKIP <test>: <reason>` and returns. That
-- is only for a machine that genuinely cannot have the component (no wasi-sdk, the docker fast path,
-- a checkout that never built one); on a node that can build it, scripts/fast.sh builds it and the
-- assertions run.
local json = dofile('lua/vendor/json.lua')

local M = {}

local function slashes(path) return (tostring(path or ''):gsub('\\', '/')) end

local function shell_quote(path) return "'" .. slashes(path):gsub("'", "'\\''") .. "'" end

-- The pin the node will check, checked here: `sha256sum` of the copied module against the copied pin.
-- `host.read_file` has a size cap below a component's (8 MB for the graph), so the bytes are hashed by
-- the shell rather than compared in Lua.
local function pin_matches(dir, name)
  local pin = host.read_file(dir .. '/' .. name .. '.wasm.sha256')
  local declared = tostring(pin or ''):match('%x+')
  if not declared then return false, 'the pin file is missing or says no sha256' end
  local ok, answer = pcall(host.exec, 'sha256sum ' .. shell_quote(dir .. '/' .. name .. '.wasm'), '', 60)
  if not ok then return false, 'sha256sum could not run: ' .. tostring(answer) end
  local decoded = json.decode(tostring(answer or '{}')) or {}
  local actual = tostring(decoded.stdout or ''):match('%x+')
  if decoded.code ~= 0 or not actual then
    return false, 'sha256sum of the copied module failed (exit ' .. tostring(decoded.code) .. '): '
      .. tostring(decoded.stderr or answer)
  end
  if actual ~= declared then
    return false, ('the copied module does not match its pin (%s != %s), so the node would refuse it '):
      format(actual, declared)
  end
  return true
end

-- `true` when the component is installed in this test's own directory (or was just copied there),
-- else `false, <reason a reader can act on>`.
function M.require(name)
  name = tostring(name or '')
  local dir = tostring(host.getenv('WA_COMPONENTS_DIR') or '')
  if dir == '' then
    return false, 'WA_COMPONENTS_DIR is not set: this run has no component directory to install into '
      .. '(scripts/fast.sh sets one inside the test home; WA_COMPONENTS_DIR=<dir> by hand)'
  end
  local wasm = dir .. '/' .. name .. '.wasm'
  if host.path_kind(wasm) == 'file' and host.path_kind(wasm .. '.sha256') == 'file' then return true end
  local source = tostring(host.getenv('WA_FAST_COMPONENT_SOURCE') or '')
  if source == '' then
    return false, ('the %s component is not installed in %s and this run built no component set; '
      .. 'scripts/fast.sh builds it from this tree (bash scripts/build-components.sh %s installs one '
      .. 'by hand, and needs wasi-sdk for the ones with C inside)'):format(name, dir, name)
  end
  -- The manifest and the pin first, the module last: the same order `scripts/build-components.sh`
  -- installs in, so a reader never pairs a new module with an old pin.
  for _, suffix in ipairs({ '.json', '.wasm', '.wasm.sha256' }) do
    local from = source .. '/' .. name .. suffix
    if host.path_kind(from) ~= 'file' then
      return false, ('%s is not in the component set at %s; scripts/fast.sh builds it from this tree '
        .. '(bash scripts/build-components.sh %s)'):format(name .. suffix, source, name)
    end
  end
  local command = 'mkdir -p ' .. shell_quote(dir)
  for _, suffix in ipairs({ '.json', '.wasm', '.wasm.sha256' }) do
    command = command .. ' && cp ' .. shell_quote(source .. '/' .. name .. suffix) .. ' '
      .. shell_quote(dir .. '/' .. name .. suffix)
  end
  local ok, answer = pcall(host.exec, command, '', 120)
  if not ok then return false, 'copying ' .. name .. ' into ' .. dir .. ' failed: ' .. tostring(answer) end
  local decoded = json.decode(tostring(answer or '{}')) or {}
  if decoded.code ~= 0 then
    return false, ('copying %s into %s failed (exit %s): %s'):format(
      name, dir, tostring(decoded.code), tostring(decoded.stderr or ''))
  end
  local pinned, why = pin_matches(dir, name)
  if not pinned then return false, name .. ': ' .. tostring(why) end
  return true
end

-- The row a test prints instead of its checks when the component is absent. One spelling, so a skip is
-- greppable and always carries the reason.
function M.skip(test, why)
  print(('SKIP %s: %s'):format(tostring(test), tostring(why)))
end

return M
