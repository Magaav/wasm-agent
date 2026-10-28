-- Every MCP launcher starts the same Node: the bundled runtime `mcp.node_program()` resolves
-- (`WA_NODE`, else `<install>/node`, else `<data>/node`, else `node` on PATH).
--
-- 28/10: the read-session launcher used `WA_NODE or 'node'` while the probe used the resolver. On a node
-- with no system Node (the sandbox image, a fresh install with only the provisioned runtime) the probe
-- passed and every read - every Gmail call - failed `program_not_found_on_path`. This test fails if a
-- launcher stops using the resolver, and the source scan fails if any module launches a bare `node`.
local json=dofile('lua/vendor/json.lua')
dofile('lua/core/memory.lua').setup() -- the read session keeps its uncertainty claims in meta
local checks=0
local function check(v,label) checks=checks+1; if not v then error('MCP NODE RUNTIME CHECK FAILED: '..label) end end

-- A provisioned runtime under <data>/node and nothing else: no WA_NODE, no install dir.
local data=dofile('lua/core/paths.lua').data()
local runtime=data..'/node/bin/node'
assert(host.write_file(runtime,'#!/bin/sh\n'))
local env=host.getenv
host.getenv=function(k) if k=='WA_NODE' or k=='WA_INSTALL_DIR' then return nil end return env(k) end

local mcp=dofile('lua/core/mcp.lua')
check(mcp.node_program()==runtime,'the resolver finds the provisioned runtime: '..tostring(mcp.node_program()))

-- The read session launches through host.operation: capture what it asks for, start nothing.
local launched
local operation=host.operation
host.operation=function(action,raw)
  if action=='start' then launched=json.decode(raw); return json.encode({error='captured_by_test'}) end
  return operation(action,raw)
end
local sessions=dofile('lua/core/mcp_session.lua')
sessions.node_program=mcp.node_program
local dir=data..'/mcp-fixture'; assert(host.write_file(dir..'/mcp-session.mjs','// fixture\n'))
local r=sessions.invoke({server={id='fixture',transport='stdio',program=runtime,args={},timeout_seconds=5},
  read_tools={'echo'},tool='echo',arguments={},credential_refs={}},{session_id='fixture'},dir)
host.operation=operation
check(type(launched)=='table','the read session asked to launch something')
check(launched and launched.program==runtime,'the read session launches the resolved runtime, not '..tostring(launched and launched.program))
check(r and r.error=='mcp_session_not_started','the captured launch is reported, not hidden')

-- No module launches a bare `node` by itself: the only fallback to the PATH name is in the resolver.
local listing=json.decode(host.list_dir('lua/core'))
for _,entry in ipairs(listing.entries or {}) do
  local name=entry.name
  if entry.kind=='file' and name:match('%.lua$') and name~='mcp.lua' then
    local source=host.read_file('lua/core/'..name) or ''
    check(not source:find("WA_NODE'%)%s*or%s*'node'") and not source:find("WA_NODE'%)%s*or%s*\"node\"")
      and not source:find("program%s*=%s*'node'") and not source:find('program%s*=%s*"node"'),
      'lua/core/'..name..' launches a bare node instead of mcp.node_program()')
  end
end
-- A partial copy of the runtime is never chosen over a complete one (28/10: a stale <data>/scripts with
-- mcp-client.mjs but no web-core.mjs answered first, and web_search died at import).
local partial=data..'/partial-scripts';local whole=data..'/whole-scripts'
assert(host.write_file(partial..'/mcp-client.mjs','// stale\n'))
for _,file in ipairs(mcp.RUNTIME) do assert(host.write_file(whole..'/'..file,'// fixture\n')) end
host.getenv=function(k)
  if k=='WA_MCP_SCRIPT_DIR' then return partial end
  if k=='WA_INSTANCE_OPERATOR_INSTALL' then return data..'/whole-install' end
  if k=='WA_NODE' or k=='WA_INSTALL_DIR' or k=='WASM_AGENT_LUA_ROOT' then return nil end
  return env(k)
end
for _,file in ipairs(mcp.RUNTIME) do assert(host.write_file(data..'/whole-install/scripts/'..file,'// fixture\n')) end
check(mcp.script_dir()==data..'/whole-install/scripts','a complete runtime wins over a partial one listed first: '..tostring(mcp.script_dir()))
-- A node started by its own service unit has no install variable at all: the default install is searched.
local home=dofile('lua/core/paths.lua').home()
for _,file in ipairs(mcp.RUNTIME) do assert(host.write_file(home..'/.local/bin/scripts/'..file,'// fixture\n')) end
host.getenv=function(k)
  if k=='WA_MCP_SCRIPT_DIR' or k=='WA_INSTANCE_OPERATOR_INSTALL' or k=='WA_INSTALL_DIR' or k=='WA_NODE' or k=='WASM_AGENT_LUA_ROOT' then return nil end
  return env(k)
end
check(mcp.script_dir()==home..'/.local/bin/scripts','with no install variable the default install is found: '..tostring(mcp.script_dir()))
host.getenv=env
print(json.encode({ok=true,checks=checks}))
