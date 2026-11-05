-- Component MCP transport (docs/COMPONENTS.md): a pinned WASI component behind the same registry,
-- schemas, dispatch and code-mode routing as every other MCP server. Real host, real wasmtime.
-- Needs the mcp-echo fixture installed in WA_COMPONENTS_DIR (scripts/build-components.sh mcp-echo);
-- without it only the definition and refusal checks run.
local json=dofile('lua/vendor/json.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)','[]')).ok)
local memory=dofile('lua/core/memory.lua')
memory.setup()
local mcp=dofile('lua/core/mcp.lua')
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode_policy.lua')
local checks=0
local function check(value,label)checks=checks+1;if not value then error('COMPONENT CHECK FAILED: '..label)end end
local ctx={role='master',session_id='component-fixture'}
local function control(action,extra)local args=extra or {};args.action=action;args.expected_revision=mcp.inventory().revision;return mcp.control(args,ctx)end

-- Definitions: a component takes no command; its grants are references; send stays on the operator route.
local base={id='echo',name='Echo',transport='component',component='mcp-echo',tools={echo='read',env='read',spin='read'},timeout_seconds=5}
check(mcp.validate(base)==nil,'component definition accepted')
check(mcp.validate({id='x',transport='component',component='Bad/Name',tools={}})=='invalid_mcp_component','component name fenced')
check(mcp.validate({id='x',transport='component',component='c',program='node',tools={}})=='mcp_component_takes_no_command','no program on a component')
check(mcp.validate({id='x',transport='component',component='c',env={K='not a name'},tools={}})=='mcp_credentials_require_environment_references','env stays a reference')
check(mcp.validate({id='x',transport='component',component='c',net={'evil host:1'},tools={}})=='invalid_mcp_component_net','net addresses fenced')
check(mcp.validate({id='x',transport='stdio',program='p',args={},net={'127.0.0.1:1'},tools={}})=='mcp_component_fields_require_component_transport','component fields only on components')
check(mcp.validate({id='w',transport='component',component='mcp-whatsapp',tools={send_message='write'}})=='whatsapp_send_uses_operator_route','WhatsApp send stays on the operator route')

-- A missing component refuses before anything runs.
local missing=mcp.invoke({action='probe',server={transport='component',component='not-installed-'..host.uuid():sub(1,8):lower():gsub('[^a-z0-9]','a'),tools={}}},ctx)
check(missing.ok==false and missing.tool_call_issued==false and missing.outcome=='not_submitted','missing component is not submitted')

local installed=false
for _,c in ipairs(json.decode(host.components()) or {})do if c.name=='mcp-echo' and c.ok then installed=true end end
if not installed then print('component checks: '..checks..' (mcp-echo not installed; runtime checks skipped)');return end

-- Grants beyond the manifest are refused before instantiation.
local wide={transport='component',component='mcp-echo',net={'127.0.0.1:9'},tools={}}
local refused=mcp.invoke({action='probe',server=wide},ctx)
check(refused.ok==false and refused.error:find('component_capability_not_declared:net',1,true)~=nil and refused.tool_call_issued==false,'undeclared net grant refused')

-- Registry lifecycle: put, probe, enable, schemas, dispatch.
local def=base;def.env={WA_ECHO='MCP_COMPONENT_TEST_VALUE'}
check(control('put',{definition=def}).ok,'store disabled component definition')
local probed=control('probe',{id='echo'})
check(probed.ok,'component probe: '..tostring(probed.error))
check(probed.session_mode=='component' and type(probed.schema_hash)=='string' and #probed.schema_hash==64,'schema hash is the component pin')
check(probed.tools[1].input_schema_json:find('"value":{}',1,true)~=nil,'exact schema string through serde')
check(control('enable',{id='echo'}).ok,'enable after probe')
local names={};for _,s in ipairs(mcp.schemas())do names[s['function'].name:match('^mcp_echo_(%a+)_')]=s['function'].name end
check(names.echo and names.env and names.spin,'component tools exposed as mcp_* schemas')
check(codemode.connector(names.echo),'component tools are connector tools: callable inside code mode')

local rawargs='{"value":{"empty":{},"array":[],"nil":null}}'
local result=tools.dispatch(memory,names.echo,{},'master',{session_id='component-fixture',tool_arguments_json=rawargs})
check(result.ok and result.tool_call_issued,'one real component call')
local exact=json.encode(result.result)
check(exact:find('"empty":{}',1,true) and exact:find('"array":[]',1,true) and exact:find('"nil":null',1,true),'arguments survive exactly')

-- The sandbox: only granted env keys exist, no filesystem.
local seen=tools.dispatch(memory,names.env,{},'master',{session_id='component-fixture'}).result.structuredContent
check(seen.fs_root_readable==false,'no filesystem inside the component')
local only_granted=true;for _,k in ipairs(seen.vars or {})do if k~='WA_ECHO' then only_granted=false end end
check(only_granted,'no inherited environment: only granted keys')

-- Deadline: a component that never returns is stopped, and the call is reported unknown, not ok.
local spun=tools.dispatch(memory,names.spin,{},'master',{session_id='component-fixture'})
check(spun.ok==false and spun.outcome=='unknown','a stuck component hits the deadline, outcome unknown')

print('component checks: '..checks)
