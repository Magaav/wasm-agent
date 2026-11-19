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

-- The instruction files, named EXPLICITLY so a build never depends on the process cwd (found the hard
-- way: the fast path runs every row from the repository root, my probe ran from the mission directory,
-- and the same tree built two different prompts because AGENTS.orchestrator.md was found in one and not
-- the other). Both the recorder and the test set these, so the goldens and the check see one shape.
function M.instruction_env()
  local root = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
  return {
    WASM_AGENT_AGENTS_MD = root .. '/AGENTS.md',
    WASM_AGENT_AGENTS_MD_ORCHESTRATOR = root .. '/AGENTS.orchestrator.md',
    WASM_AGENT_AGENTS_MD_SUBAGENTS = root .. '/AGENTS.subagents.md',
  }
end

-- The host strings of THIS run: the scratch home and the working directory.
function M.host_strings()
  return { home = os.getenv('WASM_AGENT_HOME') or '',
    tree = host.getenv('WASM_AGENT_LUA_ROOT') or '',
    cwd = dofile('lua/core/platform.lua').cwd() or '' }
end

-- Everything a golden stores, from one build: { system = <text>, tools = <array> }.
function M.normalize(build)
  local host_strings = M.host_strings()
  local system = tostring(build.system or '')
  -- Order matters: the TREE path may sit under the working directory (a base worktree does), so it is
  -- replaced first - otherwise the recorder's own checkout name ends up inside the golden.
  if host_strings.home ~= '' then system = system:gsub(escape(host_strings.home), '<HOME>') end
  if host_strings.tree ~= '' then system = system:gsub(escape(host_strings.tree), '<TREE>') end
  if host_strings.cwd ~= '' then system = system:gsub(escape(host_strings.cwd), '<CWD>') end
  -- The session workdir is the PROCESS working directory when the session owns no worktree - a host
  -- fact that differs between the recorder (a base worktree) and the checker (whatever cwd the harness
  -- uses, e.g. the repository root of the fast path). The attribute is normalised, nothing else.
  system = system:gsub('<workdir path="[^"]*"', '<workdir path="<WORKDIR>"')
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
