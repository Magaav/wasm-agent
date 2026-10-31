-- What runs inside code mode and what stays ordinary (29/10, widened 31/10): read-only history/spells/peers
-- open, effects and multi-action tools open with their ordinary checks, connectors code-mode-only,
-- delegation/session-ownership and the outer facades still refused, and the upfront routing hint.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return nil end;return env(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local policy=dofile('lua/core/codemode_policy.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local sid=memory.start_session('','codemode boundary',{user_id='master'})
local ctx={session_id=sid,user_id='master'};policy.pin(memory,'master',ctx)
check(policy.enforced(ctx),'default node pins code mode')
local function run(code)return tools.dispatch(memory,'codemode',{code=code},'master',ctx)end
local function first_error(r)local a=r.attempts and r.attempts[1];return a and json.encode(r) or json.encode(r)end

-- Read-only control data is reachable from a script.
local open=run('const r=["sessions","search_messages","session","spell_list","spell_get","nodes","operation","resource","web_search","web_read","remote"].map(n=>n in tools); return JSON.stringify(r);')
check(open.ok and tostring(open.value):find('[true,true,true,true,true,true,true,true,true,true,true]',1,true),'read-only, web and remote visible inside: '..json.encode(open):sub(1,300))
local listed=run('const r=await tools.sessions({limit:5}); return Array.isArray(r.sessions||r)||typeof r==="object";')
check(listed.ok,'sessions runs inside code mode: '..json.encode(listed):sub(1,300))

-- Control plane that is refused stays out: delegation/authority/recursion, session shaping and the outer
-- facades. Effects, the user's shell/client, spells and multi-action tools are callable now (31/10).
local closed=run('return JSON.stringify(["subagent","integrate","session_worktree","resume_session","tool_call","codemode","capabilities"].map(n=>n in tools));')
check(closed.ok and tostring(closed.value):find('[false,false,false,false,false,false,false]',1,true),'delegation, session shaping and the facades stay out inside: '..json.encode(closed):sub(1,300))
local widened=run('return JSON.stringify(["shell","client","spell_save","spell_run","operation","resource"].map(n=>n in tools));')
check(widened.ok and tostring(widened.value):find('[true,true,true,true,true,true]',1,true),'effects, shell/client, spells and multi-action tools are callable inside: '..json.encode(widened):sub(1,300))
-- ...but discoverable, with its route (29/10): never indistinguishable from "does not exist".
local found=run('const s=await searchTools("subagent"); const d=await describeTool("session_worktree"); const all=await searchTools("*",{limit:200}); return JSON.stringify({s:s.tools.find(t=>t.name==="subagent"),d,listed:all.tools.filter(t=>t.callable===false).map(t=>t.name)});')
local fv=found.value;for _=1,2 do if type(fv)=='string' then fv=json.decode(fv) end end;fv=type(fv)=='table' and fv or {}
check(fv.s and fv.s.callable==false and tostring(fv.s.route):find('outside codemode',1,true) and fv.s.schema,'searchTools finds an outside tool with schema and route: '..json.encode(found):sub(1,400))
check(fv.d and fv.d.callable==false and fv.d.parameters and tostring(fv.d.route):find('outside codemode',1,true),'describeTool gives an outside tool its schema and route')
local listed_outside={};for _,n in ipairs(fv.listed or {}) do listed_outside[n]=true end
check(listed_outside.subagent and listed_outside.tool_call and not listed_outside.remote,'the full listing marks outside tools; remote is callable')
check(not listed_outside.shell and not listed_outside.spell_run and not listed_outside.client,'the widened set is not listed as outside: '..json.encode(fv.listed))
local rd=run('return JSON.stringify(await describeTool("remote"));').value;for _=1,2 do if type(rd)=='string' then rd=json.decode(rd) end end
check(type(rd)=='table' and rd.callable==true and rd.parameters.properties.calls,'remote is described as callable with its batch form')
-- A remote effect from a script is refused before any network, with the route.
local eff=run('return await tools.remote({node:"nowhere",capability:"write",path:"/x",content:"y"});')
check(not json.encode(eff):find('remote_effect_outside_codemode',1,true) and json.encode(eff):find('unknown_node',1,true),'remote write is no longer fenced inside; it reaches the ordinary unknown-node refusal: '..json.encode(eff):sub(1,300))
local rb=run('return await tools.remote({node:"nowhere",capability:"bash",command:"git status --short"});')
check(not json.encode(rb):find('remote_effect_outside_codemode',1,true),'remote read-only bash passes the fence (then meets the network)')

-- Multi-action tools: every action is admitted with its ordinary checks (31/10); the tool refuses what it
-- refuses anywhere else, not a code-mode-only rule.
local start=run('return await tools.operation({action:"start",command:"true"});')
local text=json.encode(start)
check(not text:find('codemode_action_not_available',1,true) and #(start.calls or {})==1,'operation start is admitted inside: '..text:sub(1,300))
local watch=run('return await tools.operation({action:"list"});')
check(not json.encode(watch):find('codemode_action_not_available',1,true) and #(watch.calls or {})==1,'operation list admitted inside')
local reconcile=run('return await tools.resource({action:"reconcile",key:"k"});')
check(not json.encode(reconcile):find('codemode_action_not_available',1,true),'resource reconcile is admitted inside')
local claims=run('return await tools.resource({action:"list"});')
check(#(claims.calls or {})==1,'resource list admitted inside')

-- Connectors: direct or routed calls are pointed at code mode; nested calls pass the gate.
local direct=tools.dispatch(memory,'mcp_mail_list_messages_deadbeef',{},'master',ctx)
check(tostring(direct.error):find('codemode_only',1,true) and direct.effect=='none','direct connector call points to code mode')
local peer=tools.dispatch(memory,'peer_box__mail',{},'master',ctx)
check(tostring(peer.error):find('codemode_only',1,true),'peer connector also code mode only')
ctx.codemode_nested=true
local nested=tools.dispatch(memory,'mcp_mail_list_messages_deadbeef',{},'master',ctx)
ctx.codemode_nested=nil
check(not tostring(nested.error):find('codemode_only',1,true),'nested connector call passes the gate')
local off={session_id=sid,user_id='master',codemode_policy={enabled=false}}
check(not tostring(tools.dispatch(memory,'mcp_mail_list_messages_deadbeef',{},'master',off).error):find('codemode_only',1,true),'code mode off keeps connectors ordinary')
check(not policy.connector('web_search') and not policy.connector('web_read'),'web is not gated: outer calls stay allowed')

-- Prompt projection drops connectors; the hint names them.
local catalog={
 {type='function',['function']={name='read',description='Read a file',parameters={type='object',properties={}}}},
 {type='function',['function']={name='mcp_mail_list_messages_deadbeef',description='MCP mail / list_messages: list',parameters={type='object',properties={}}}},
 {type='function',['function']={name='mcp_whatsapp_read_messages_cafebabe',description='MCP whatsapp / read_messages: read',parameters={type='object',properties={}}}},
 {type='function',['function']={name='web_search',description='Search public web sources',parameters={type='object',properties={}}}},
 {type='function',['function']={name='peer_box__fetch',description='[on peer box] fetch a page',parameters={type='object',properties={}}}},
}
local prior=tools.all;tools.all=function()return catalog end
local projected=tools.envelope('master',{session_id=sid,user_id='master',codemode_policy={enabled=true}})
tools.all=prior
local names={};for _,s in ipairs(projected)do names[s['function'].name]=true end
check(not names.mcp_mail_list_messages_deadbeef and not names.peer_box__fetch,'connectors left out of the outer tool list')
check(names.web_search,'web stays an outer tool under code mode')
local prompt=policy.prompt(catalog)
check(prompt:find('- mail: list_messages',1,true) and prompt:find('- whatsapp: read_messages',1,true) and prompt:find('- peer box: fetch',1,true),'hint lists connectors: '..prompt:sub(-300))
check(prompt:find('tools.web_search(',1,true) and prompt:find('Default to code mode',1,true),'hint prefers code mode and names web inside it')
check(prompt:find('preferred programmatic coding path',1,true) and prompt:find('Use ordinary tools for',1,true),'hint carries the routing rule')
check(policy.prompt({catalog[1]})==policy.guidance,'no connectors, no index line')
-- The model-facing guidance is policy text, not documentation: keep it in step with the fence above, or the
-- model is told about a rule that no longer exists (31/10: the guidance still promised the retired peer
-- fence). Both halves are asserted so a one-sided edit fails here.
check(not policy.guidance:find('ordinary remote calls outside the script',1,true) and not policy.guidance:find('read-only command (git status',1,true),'the routing hint does not describe the retired read-only peer fence')
check(policy.guidance:find('including write, edit and effectful bash',1,true) and policy.guidance:find('a batch stays read-only',1,true),'the routing hint states the widened peer rule and the batch limit')
print(json.encode({ok=true,checks=checks}))
