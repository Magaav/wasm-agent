-- Shared by scripts/generate-prompt-goldens.lua and scripts/test-prompt-golden.lua, so the bytes the
-- goldens are RECORDED from and the bytes they are CHECKED against cannot drift apart.
--
-- What a golden pins: the FULL system prompt build_context builds (not a block rebuilt from its parts)
-- and the declared tool list, for one node shape. Two kinds of host data are normalised, because they
-- describe the machine and not the prompt: this run scratch home and the node working directory.
--
-- NOTHING ELSE is normalised away (rel review r3, item 2). The "conform: no profile for ..." notice is
-- KEPT where a27490af put it: inside the prompt. Measured, not assumed - a27490af appends it to the
-- prompt block (a27490af:lua/core/agent.lua:1190) and shows it ONCE per process
-- (raw_code.TRANSPORT_NOTICE_SHOWN), so in a recording run it lands in the FIRST case built and in no
-- other. The goldens therefore carry that one line in `progressive-only`, and the test compares the
-- bytes EXACTLY, naming that case. This branch moved the line to the operator log (commit 568ed30c), so
-- its built prompt has none; the test asserts that difference by name and by count instead of hiding it.
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
--
-- The host facts are normalised, and ONLY host facts: this run home, the tree the recorder ran in, the
-- working directory and the session workdir attribute. The conform notice is NOT normalised away (rel
-- review r3, item 2): it is kept where a27490af put it, inside the prompt, so the bytes compare exactly.
function M.normalize(build)
  local host_strings = M.host_strings()
  local system = tostring(build.system or '')
  -- Order matters: the TREE path may sit under the working directory (a base worktree does), so it is
  -- replaced first - otherwise the recorder own checkout name ends up inside the golden.
  if host_strings.home ~= '' then system = system:gsub(escape(host_strings.home), '<HOME>') end
  if host_strings.tree ~= '' then system = system:gsub(escape(host_strings.tree), '<TREE>') end
  if host_strings.cwd ~= '' then system = system:gsub(escape(host_strings.cwd), '<CWD>') end
  -- The session workdir is the PROCESS working directory when the session owns no worktree - a host
  -- fact that differs between the recorder (a base worktree) and the checker (whatever cwd the harness
  -- uses). The attribute is normalised, nothing else.
  system = system:gsub('<workdir path="[^"]*"', '<workdir path="<WORKDIR>"')
  local tools = {}
  for _, item in ipairs(build.tools or {}) do tools[#tools + 1] = item end
  return { system = system, tools = tools }
end

-- The conform notice lines a prompt carries, in order. Used by the TEST to say where a27490af had one
-- and this branch has none - never to remove one from a golden.
function M.notice_lines(text)
  local found = {}
  for line in (tostring(text or '') .. '\n'):gmatch('(.-)\n') do
    if line:match(M.NOTICE_PATTERN) then found[#found + 1] = line end
  end
  return found
end

-- A prompt with its conform notice lines taken out. The test uses it for the ONE named case whose base
-- bytes carry the notice (progressive-only): it compares the rest exactly and says the line is the
-- difference, against this branch having none anywhere.
function M.without_notices(text)
  local kept = {}
  for line in (tostring(text or '') .. '\n'):gmatch('(.-)\n') do
    if not line:match(M.NOTICE_PATTERN) then kept[#kept + 1] = line end
  end
  return table.concat(kept, '\n')
end

-- The exact bytes a golden file holds: one JSON object, keys in a fixed order, sorted tool order kept
-- as the node declared it (the declaration order is part of the prompt half of the request).
function M.encode(golden)
  return json.encode({ system = golden.system, tools = golden.tools })
end

-- The NAMED differences between this branch and the release it merges (39bbf2b6), as an ALLOW-LIST: a
-- line matching one of these is expected to differ, and the comparison removes it from BOTH sides.
-- Anything else that differs FAILS. That is what stops a self-recorded golden from agreeing with
-- itself: the reference is upstream's own bytes, and only these shapes may move.
M.DIFFERENT = {
  '^The %d+ other tools this role may call are found with',  -- this branch adds the run tool (count +1)
  '^%- run$',                                                -- and its schema row in the full envelope list
  '^Work in code: call the run tool with',                   -- the native guidance sentence
  '^You may also run a script by ending your message with',  -- the block guidance it replaces on on/stop
}

function M.upstream_view(system)
  local kept = {}
  for line in (tostring(system or '') .. '\n'):gmatch('(.-)\n') do
    local drop = false
    for _, pattern in ipairs(M.DIFFERENT) do
      if line:match(pattern) then drop = true break end
    end
    if not drop then kept[#kept + 1] = line end
  end
  return table.concat(kept, '\n')
end

M.json = json
return M
