-- One registry, two views (11/11): every tool the catalogue offers outside must be reachable inside
-- code mode. Three legal outcomes, and nothing else:
--   1. it executes inside with the outside result shape (the loop dispatches the same tool);
--   2. it is on `DIRECT_ONLY` - the reviewed list of effects that stay a single direct call with a
--      receipt - and refuses inside with that stated reason;
--   3. it refuses with the *identical* guard text outside would give, because both views reach the
--      same dispatcher (workspace binding, schema contract, managed capability, role).
-- A tool that exists outside and is absent, or throws a TypeError, inside is the failure this test
-- exists to catch (measured 11/11: `typeof tools.capabilities` killed a startup script).
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return nil end;return env(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local policy=dofile('lua/core/codemode_policy.lua')
local codemode=dofile('lua/core/codemode.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local sid=memory.start_session('','codemode parity',{user_id='master'})
local ctx={session_id=sid,user_id='master',role='master'}
policy.pin(memory,'master',ctx)
check(policy.enforced(ctx),'code mode is admitted for this run')
local function run_on(mem,code,c)return tools.dispatch(mem,'codemode',{code=code},'master',c or ctx)end
local function run(code,c)return run_on(memory,code,c)end
-- The guest's own bytes: `text()` is the output channel, so the value is exactly what the script
-- encoded - no second JSON layer to guess at.
local function ask(body,label,mem)
 local result=run_on(mem or memory,'text(JSON.stringify(await (async()=>{'..body..'})())); return 1;')
 if not result.ok then error((label or 'script')..' failed: '..json.encode(result):sub(1,500)) end
 local item=result.items and result.items[1]
 if not item or type(item.text)~='string' then error((label or 'script')..' printed no text: '..json.encode(result):sub(1,500)) end
 return json.decode(item.text)
end
local function array(value) -- the vendor decoder drops an empty array, so normalise it
 return type(value)=='table' and value or {}
end

-- 1. The direct-call list is exact and every entry says why. A silent addition fails here.
local expected={'codemode','email_send','integrate','node_update','resume_session','session_debug',
 'session_fixture','session_worktree','subagent','tool_call','tool_search','wave_autoflush'}
local actual={};for name in pairs(codemode.DIRECT_ONLY or {})do actual[#actual+1]=name end;table.sort(actual)
check(table.concat(actual,',')==table.concat(expected,','),
 'direct-call list is exactly the reviewed set, got: '..table.concat(actual,','))
for _,name in ipairs(actual)do
 check(type(codemode.DIRECT_ONLY[name])=='string' and #codemode.DIRECT_ONLY[name]>20,
  'every direct-call entry states its reason: '..name)
end

-- 2. No catalogue tool is missing inside code mode.
local catalog,known={},{}
for _,item in ipairs(tools.all('master',ctx,memory))do
 local name=item['function'].name;catalog[#catalog+1]=name;known[name]=true
end
check(#catalog>=40,'the master catalogue is the reference: '..#catalog)
local reach=ask('const names='..json.encode(catalog)..';'
 ..' const bad=[]; for(const n of names){ if(!(n in tools)) bad.push(n); }'
 ..' return {bad,total:names.length,all:ALL_TOOLS.length};','reachability')
check(#array(reach.bad)==0,'no catalogue tool is missing inside code mode: '..json.encode(reach.bad))
check(reach.all>=reach.total,'ALL_TOOLS covers the catalogue: '..json.encode(reach))

-- 3. A direct-call name refuses with its stated reason - never a TypeError, never a silent dispatch.
local fenced=ask('const names='..json.encode(actual)..'; const out={};'
 ..' for(const n of names){ try{ const r=await tools[n]({}); out[n]=(r&&r.error)||("NO_ERROR:"+typeof r); }'
 ..' catch(e){ out[n]="THROW:"+String((e&&e.message)||e); } } return out;','direct-call refusals')
for _,name in ipairs(actual)do
 if known[name] then
  local text=tostring(fenced[name] or '')
  -- The guest surfaces a refusal either as the returned value or as a thrown error carrying the same
  -- object; both are the route. What must never appear is "does not exist" - the TypeError this
  -- replaces.
  check(text:find('Direct call only',1,true)~=nil,
   'the refusal states the direct-call rule: '..name..' -> '..text)
  check(text:find('does not exist',1,true)==nil,
   'reading a direct-call name never reads as absent: '..name..' -> '..text)
 end
end

-- 4. The tools that work must *work*, with the outside result, not a refusal dressed as a result.
for _,name in ipairs({'capabilities','notes_read','memories','nodes'})do
 if known[name] then
  local direct=tools.dispatch(memory,name,{},'master',ctx)
  local inside=ask('return await tools.'..name..'({});',name)
  check(json.encode(inside)==json.encode(direct),
   'code mode returns the outside result for '..name..': inside '..json.encode(inside):sub(1,200)
    ..' outside '..json.encode(direct):sub(1,200))
 end
end
-- `capabilities()` is the grant list, the same object the tool returns - the drift that made the
-- global answer the host inventory (audio, disk, http) under the tool's name.
if known.capabilities then
 local global=ask('return await capabilities();','capabilities()')
 local outer=tools.dispatch(memory,'capabilities',{},'master',ctx)
 check(json.encode(global)==json.encode(outer),'capabilities() is the tool grant list: '..json.encode(global):sub(1,200))
 check(#array(global.capabilities)>=40,'the grant list is the permitted catalogue, not a search: '..json.encode(global):sub(1,120))
end
-- describeTool(name) is that name's definition, callable or direct-only, never the presentation help.
if known.read then
 local described=ask('return {read:await describeTool("read"),direct:await describeTool("session_worktree"),unknown:await describeTool("sesion_worktree")};','describeTool')
 check(type(described.read)=='table' and described.read.name=='read' and type(described.read.parameters)=='table',
  'describeTool("read") is read\'s schema: '..json.encode(described.read):sub(1,160))
 check(type(described.direct)=='table' and described.direct.callable==false
  and tostring(described.direct.route):find('Direct call only',1,true)~=nil,
  'describeTool names the route for a direct-only tool: '..json.encode(described.direct):sub(1,200))
 check(type(described.unknown)=='table' and described.unknown.error=='unknown_tool'
  and #array(described.unknown.suggestions)>0,
  'describeTool suggests permitted names for an unknown one: '..json.encode(described.unknown):sub(1,200))
end

-- 5. Guards, identical text on both views. Each pair runs the same call twice.
local root=dofile('lua/core/paths.lua').data()..'/work';host.write_file(root..'/parity.txt','alpha')
-- A nested refusal arrives as a thrown value carrying the same object the dispatcher returned.
local function nested(body,label,mem)
 local answer=ask('try{ return {value: await (async()=>{'..body..'})()}; }'
  ..' catch(e){ return {threw:String((e&&e.message)||e)}; }',label,mem)
 if type(answer.threw)=='string' then
  local ok,decoded=pcall(json.decode,answer.threw)
  if ok and type(decoded)=='table' and decoded.error then return tostring(decoded.error) end
  return answer.threw
 end
 local value=answer.value
 if type(value)=='table' and value.error then return tostring(value.error) end
 return ''
end
local function same(label,outside,inside)
 check(tostring(outside.error)~='' and tostring(outside.error)~='nil','the guard refuses the direct call: '..label..' '..json.encode(outside):sub(1,160))
 check(inside==tostring(outside.error),
  'the guard text is identical inside code mode: '..label..' inside '..inside..' outside '..tostring(outside.error))
end
-- (a) the schema contract. This is the one place the two views deliberately differ: code mode validates
-- the advertised schema before dispatch (`schema_type:arguments.path`) because a script may hold a
-- pinned definition, while a direct call reaches the tool's own check (`path_required`). Both refuse,
-- neither has an effect, and code mode is the stricter one - recorded here rather than flattened.
local outside_schema=tools.dispatch(memory,'read',{path=42},'master',ctx)
local inside_schema=nested('return await tools.read({path:42});','schema')
check(tostring(outside_schema.error)~='' and inside_schema~='','both views refuse a wrong argument type: '
 ..tostring(outside_schema.error)..' / '..inside_schema)
check(inside_schema:find('schema_',1,true)~=nil,'code mode validates the advertised schema before dispatch: '..inside_schema)
-- (b) a required workspace binding: a root the session does not hold refuses writes in both views.
local bound=setmetatable({session_worktree=function()return root end,
 session_workspace=function()return {required=true,state='allocated',worktree=root}end},{__index=memory})
local escape=root..'/../parity-escape.txt'
same('write outside the bound root',tools.dispatch(bound,'write',{path=escape,content='x'},'master',ctx),
 nested('return await tools.write({path:'..json.encode(escape)..',content:"x"});','binding',bound))
check(host.read_file(escape)==nil,'neither view wrote outside the bound root')
-- (c) a managed-node rule: an unknown peer refuses identically.
same('remote to an unknown node',tools.dispatch(memory,'remote',{node='nowhere',capability='read',path='/x'},'master',ctx),
 nested('return await tools.remote({node:"nowhere",capability:"read",path:"/x"});','peer'))
-- (d) a role rule: a guest is refused code mode itself, before any script can be a bypass.
local guest=tools.dispatch(memory,'codemode',{code='return 1'},'guest',{session_id=sid,user_id='guest',role='guest'})
check(tostring(guest.error):find('forbidden_for_role:guest',1,true)~=nil,
 'a guest cannot run a script at all: '..json.encode(guest):sub(1,160))

print(json.encode({ok=true,checks=checks,tools=#catalog,direct_only=#actual,paid_calls=0}))
