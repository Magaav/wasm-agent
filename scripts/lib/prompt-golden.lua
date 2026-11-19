-- Shared by scripts/generate-prompt-goldens.lua and scripts/test-prompt-golden.lua, so the bytes the
-- goldens are RECORDED from and the bytes they are CHECKED against cannot drift apart.
--
-- What a golden pins: the FULL system prompt build_context builds (not a block rebuilt from its parts)
-- and the declared tool list, for one node shape. Two kinds of host data are normalised, because they
-- describe the machine and not the prompt: this run's scratch home and the node's working directory.
-- One line is normalised away and named: the "conform: no profile for ..." notice, which a27490af put
-- INSIDE the prompt and this branch moved to the operator log (commit 568ed30c, review MUST 4). The
-- test asserts that line is absent from the built prompt, so the removal cannot hide its return.
local json = dofile('lua/vendor/json.lua')
local M = {}

M.NOTICE_PATTERN = '^conform: no profile for .+ using the conservative .+ transport; run .+ to measure it$'

local function escape(text)
  return (tostring(text):gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
end

-- The host strings of THIS run: the scratch home and the working directory.
function M.host_strings()
  return { home = os.getenv('WASM_AGENT_HOME') or '', cwd = dofile('lua/core/platform.lua').cwd() or '' }
end

-- Everything a golden stores, from one build: { system = <text>, tools = <array> }.
function M.normalize(build)
  local host_strings = M.host_strings()
  local system = tostring(build.system or '')
  if host_strings.home ~= '' then system = system:gsub(escape(host_strings.home), '<HOME>') end
  if host_strings.cwd ~= '' then system = system:gsub(escape(host_strings.cwd), '<CWD>') end
  local kept, removed = {}, 0
  for line in (system .. '\n'):gmatch('(.-)\n') do
    if line:match(M.NOTICE_PATTERN) then removed = removed + 1 else kept[#kept + 1] = line end
  end
  local tools = {}
  for _, item in ipairs(build.tools or {}) do tools[#tools + 1] = item end
  return { system = table.concat(kept, '\n'), tools = tools, notice_lines_removed = removed }
end

-- The exact bytes a golden file holds: one JSON object, keys in a fixed order, sorted tool order kept
-- as the node declared it (the declaration order is part of the prompt half of the request).
function M.encode(golden)
  return json.encode({ system = golden.system, tools = golden.tools })
end

M.json = json
return M
