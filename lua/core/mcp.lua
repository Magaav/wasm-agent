-- MCP extension registry/policy. Platform execution stays in host.operation.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local platform=dofile('lua/core/platform.lua')
local M={KEY='mcp.extensions.v1'}
local function fail(error,extra)local result=extra or {};result.ok=false;result.error=error;return result end
local function decode(raw)local ok,value=pcall(json.decode,tostring(raw or ''));if not ok or type(value)~='table' then return nil end;return value end
local function query(sql,params)local value=decode(host.sql_query(sql,json.encode(params or {})));if not value or value.error then error(value and value.error or 'mcp_store_unreadable') end;return value end
local function exec(sql,params)local value=decode(host.sql_exec(sql,json.encode(params or {})));if not value or value.error or value.ok~=true then error(value and value.error or 'mcp_store_write_unverified') end;return value end
local function load_store()
 local rows=query('SELECT value FROM meta WHERE key=?',{M.KEY});local raw=rows[1] and rows[1].value
 if not raw then return {schema=1,revision=0,servers={}},nil end
 local value=decode(raw);if not value or value.schema~=1 or type(value.servers)~='table' or type(value.revision)~='number' then error('mcp_store_corrupt') end
 return value,raw
end
local function mutate(expected,change)
 local ok,value=pcall(function()
  local current,raw=load_store();if raw~=expected then return fail('mcp_store_changed') end
  local result=change(current);if result.error then return result end
  current.revision=current.revision+1;local encoded=json.encode(current);local saved
  -- One native atomic CAS statement. No Lua-spanning transaction on the
  -- shared connection: another worker must never join our BEGIN/COMMIT.
  if expected==nil then saved=exec('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)',{M.KEY,encoded})
  else saved=exec('UPDATE meta SET value=? WHERE key=? AND value=?',{encoded,M.KEY,expected}) end
  if saved.changes~=1 then return fail('mcp_store_changed') end
  return result
 end)
 if not ok then return fail(tostring(value)) end;return value
end
local function absolute(value)return type(value)=='string' and (value:sub(1,1)=='/' or value:match('^%a:[/\\]')) end
function M.script_dir()
 local override=host.getenv('WA_MCP_SCRIPT_DIR');if override and override~='' then return override end
 local root=host.getenv('WASM_AGENT_LUA_ROOT');if root and root~='' then return root..'/scripts' end
 local install=host.getenv('WA_INSTALL_DIR');if install and install~='' then return install..'/scripts' end
 if platform.os()=='windows' then local localapp=host.getenv('LOCALAPPDATA');if localapp then return localapp..'/wasm-agent/scripts' end end
 return nil
end
local function valid_id(id)return type(id)=='string' and #id<=24 and id:match('^[a-z][a-z0-9_-]*$') end
local function dense(list,maximum)if type(list)~='table' or #list>maximum then return false end;for key,value in pairs(list)do if type(key)~='number' or key<1 or key>#list or key%1~=0 or type(value)~='string' then return false end end;return true end
function M.validate(def)
 if type(def)~='table' or not valid_id(def.id) then return 'invalid_mcp_id' end
 local allowed={id=true,name=true,transport=true,program=true,args=true,cwd=true,url=true,env=true,headers=true,secret_env=true,timeout_seconds=true,tools=true}
 for key in pairs(def)do if not allowed[key]then return 'unsupported_mcp_definition_field:'..tostring(key) end end
 if def.name~=nil and (type(def.name)~='string' or #def.name>200)then return 'invalid_mcp_name' end
 if def.transport=='stdio' then
  if type(def.program)~='string' or def.program=='' or def.program:find('[\r\n%z]') or not dense(def.args,128)then return 'invalid_mcp_command' end
  if def.cwd~=nil and not absolute(def.cwd)then return 'mcp_cwd_requires_absolute_path' end
 elseif def.transport=='http' then
  if type(def.url)~='string' or #def.url>2048 or not def.url:match('^https?://') or def.url:find('[\r\n%z]')then return 'invalid_mcp_url' end
 else return 'invalid_mcp_transport' end
 for _,field in ipairs({'env','headers'})do
  if def[field]~=nil then if type(def[field])~='table' then return 'invalid_mcp_references' end
   for key,name in pairs(def[field])do if type(key)~='string' or type(name)~='string' or not name:match('^[A-Za-z_][A-Za-z0-9_]*$')then return 'mcp_credentials_require_environment_references' end end
  end
 end
 if def.secret_env~=nil then
  if not dense(def.secret_env,64) then return 'invalid_mcp_secret_env_tags' end
  for _,key in ipairs(def.secret_env)do if not def.env or not def.env[key] then return 'invalid_mcp_secret_env_tags' end end
 end
 if def.timeout_seconds~=nil and (type(def.timeout_seconds)~='number' or def.timeout_seconds%1~=0 or def.timeout_seconds<1 or def.timeout_seconds>86400)then return 'invalid_mcp_timeout' end
 if type(def.tools)~='table' then return 'mcp_tool_permissions_required' end
 for name,effect in pairs(def.tools)do if type(name)~='string' or name=='' or #name>128 or (effect~='read' and effect~='write')then return 'invalid_mcp_tool_permission' end end
 if def.tools.send_message and def.transport=='stdio' then
  for _,arg in ipairs(def.args)do if arg:gsub('\\','/'):lower():match('[/]mcp%-whatsapp%.mjs$') or arg:lower()=='mcp-whatsapp.mjs' then return 'whatsapp_send_requires_scoped_facade' end end
 end
 return nil
end
function M.namespace(id,name)
 local prefix='mcp_'..id..'_';local clean=tostring(name):gsub('[^A-Za-z0-9_-]','_'):sub(1,24)
 return prefix..clean..'_'..host.sha256(id..'\0'..name):sub(1,8)
end
local function native_data(answer)
 if type(answer)~='table' then return nil end
 local result=answer.result or decode(answer.result_json)
 if result then
  if type(result.structuredContent)=='table' then return result.structuredContent end
  local content=result.content;if type(content)=='table' and #content==1 and content[1].type=='text' then return decode(content[1].text) end
 end
end
function M.invoke(input,ctx)
 ctx=ctx or {};local directory=M.script_dir();if not directory then return fail('mcp_script_directory_unbound',{tool_call_issued=false,outcome='not_submitted'}) end
 local client=directory..'/mcp-client.mjs';if not host.read_file(client)then return fail('mcp_client_not_installed',{tool_call_issued=false,outcome='not_submitted'}) end
 local request=paths.data()..'/mcp/requests/'..host.uuid()..'.json'
 input.result_file=request..'.result.json'
 if not host.write_file(request,json.encode(input))then return fail('mcp_request_not_written',{tool_call_issued=false,outcome='not_submitted'}) end
 local timeout=input.server.timeout_seconds or 30
 local start=decode(host.operation('start',json.encode({program=host.getenv('WA_NODE') or 'node',args={client,'--request-file',request},cwd=ctx.cwd or platform.cwd(),timeout_seconds=math.min(86400,timeout+3),owner=ctx.session_id or 'mcp-control'})))
 if not start or start.error or not start.operation_id then return fail('mcp_operation_not_started',{detail=start,tool_call_issued=false,outcome='not_submitted',request=request}) end
 local id=start.operation_id
 local settled=decode(host.operation('await',json.encode({id=id,wait_for='settled'})))
 if not settled or settled.error or not settled.settled then
  pcall(host.operation,'cancel',json.encode({id=id}));return fail('mcp_operation_unsettled',{operation_id=id,request=request,tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'})
 end
 local raw=settled.stdout_path and host.read_file(settled.stdout_path);local answer=decode(raw)
 if answer and (settled.ok==false or settled.error or settled.code and settled.code~=0) then
  return fail('mcp_operation_failed',{observed=answer,operation=settled,operation_id=id,request=request,tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'})
 end
 if answer and answer.result_path then
  if answer.result_path~=input.result_file then return fail('mcp_result_path_mismatch',{operation_id=id,outcome='unknown',tool_call_issued=input.action=='call'}) end
  local retained=host.read_file(answer.result_path)
  if not retained or #retained~=answer.result_bytes or host.sha256(retained)~=answer.result_sha256 then return fail('mcp_result_artifact_unverified',{operation_id=id,outcome='unknown',tool_call_issued=input.action=='call'}) end
  answer=decode(retained)
 end
 if not answer then return fail('mcp_operation_result_unreadable',{operation_id=id,request=request,tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'}) end
 answer.operation_id=id;answer.request=request
 return answer
end
function M.default_whatsapp()
 local directory=M.script_dir() or '<installed scripts directory>'
 return {id='whatsapp',name='WhatsApp',transport='stdio',program=host.getenv('WA_NODE') or 'node',args={directory..'/mcp-whatsapp.mjs','--binding-json',json.encode({cache_dir=paths.cache()..'/mcp/whatsapp'})},
  env={WA_MCP_WHATSAPP_ACCOUNT='WA_WHATSAPP_ACCOUNT',WA_MCP_WHATSAPP_ENDPOINT='WA_WHATSAPP_BROWSER_ENDPOINT'},
  timeout_seconds=60,tools={read_snapshot='read',lookup_self='read',inspect_chat='read',download_audio='read'}}
end
function M.inventory()
 local store=load_store();local servers={}
 for id,row in pairs(store.servers)do
  servers[#servers+1]={id=id,name=row.definition.name or id,definition=row.definition,enabled=row.enabled==true,revision=row.revision,
   probe=row.probe,last_call=row.last_call,session_mode='request',observed_status=row.probe and (row.probe.ok and 'last probe passed' or 'last probe failed') or 'not verified'}
 end
 table.sort(servers,function(a,b)return a.id<b.id end)
 return {ok=true,revision=store.revision,servers=servers,templates={whatsapp=M.default_whatsapp()},can_manage=true,
  adapters={{id='whatsapp',name='WhatsApp',profile_managed=true,capabilities={'snapshot reads','verified self/target lookup','media retrieval','profile-scoped verified send'},note='Built-in MCP app adapter. Profile/compatibility callers retain approval and reservations; Jobs own eligibility, cursors and wakes. This row is not an enabled generic send tool.'}},
  note='Explicit trusted connectors; last probe is not a persistent connection. Jobs owns wakes. Definitions/edits stay disabled until approval.'}
end
function M.control(args,ctx)
 args=args or {};ctx=ctx or {};if ctx.role~='master' and ctx.role~='admin' then return fail('forbidden') end
 if ctx.subagent then return fail('mcp_management_forbidden_for_subagent') end
 local action=args.action or 'list';if action=='list' then return M.inventory() end
 local store,raw=load_store()
 if args.expected_revision~=store.revision then return fail('mcp_store_revision_changed',{revision=store.revision}) end
 if action=='put' then
  local problem=M.validate(args.definition);if problem then return fail(problem) end
  return mutate(raw,function(current)local old=current.servers[args.definition.id];current.servers[args.definition.id]={definition=args.definition,enabled=false,revision=(old and old.revision or 0)+1};return {ok=true,id=args.definition.id,enabled=false}end)
 end
 local row=store.servers[args.id];if not row then return fail('unknown_mcp_server') end
 if action=='enable' or action=='disable' then
  if action=='enable' and (not row.probe or row.probe.ok~=true or not row.probe.schema_hash)then return fail('mcp_probe_required') end
  if action=='enable' then
   local found,total={},0;for _,tool in ipairs(row.probe.tools or {})do if row.definition.tools[tool.name] then found[tool.name]=true;total=total+#(tool.input_schema_json or '')+#tostring(tool.description or '') end end
   for name in pairs(row.definition.tools)do if not found[name] then return fail('mcp_approved_tool_missing:'..name) end end
   if total>131072 then return fail('mcp_selected_schema_budget_exceeded',{bytes=total,maximum=131072}) end
  end
  return mutate(raw,function(current)current.servers[args.id].enabled=action=='enable';return {ok=true,id=args.id,enabled=action=='enable'}end)
 elseif action=='probe' then
  local answer=M.invoke({action='probe',server=row.definition},ctx)
  local saved=mutate(raw,function(current)current.servers[args.id].probe=answer;current.servers[args.id].enabled=false;return {ok=true} end)
  if not saved.ok then answer.registry_observation_error=saved.error end
  return answer
 end
 return fail('unknown_mcp_action')
end
function M.schemas()
 local ready=query("SELECT name FROM sqlite_master WHERE type='table' AND name='meta'",{})
 if #ready==0 then return {} end -- schema-only bootstrap, not a cached empty store
 local store=load_store();local schemas,seen={},{}
 for id,row in pairs(store.servers)do if row.enabled and row.probe and row.probe.ok then
  for _,tool in ipairs(row.probe.tools or {})do if row.definition.tools[tool.name] then
   local name=M.namespace(id,tool.name);if seen[name]then error('mcp_namespace_collision') end;seen[name]=true
   if type(tool.input_schema_json)~='string' then error('mcp_cached_schema_invalid') end
   local parameters=json.raw(tool.input_schema_json)
   schemas[#schemas+1]={type='function',['function']={name=name,description='MCP '..id..' / '..tool.name..': '..tostring(tool.description or ''),parameters=parameters}}
  end end
 end end
 table.sort(schemas,function(a,b)return a['function'].name<b['function'].name end);return schemas
end
function M.resolve_tool(name)
 local store=load_store()
 for id,row in pairs(store.servers)do if row.enabled and row.probe and row.probe.ok then
  for _,tool in ipairs(row.probe.tools or {})do if M.namespace(id,tool.name)==name and row.definition.tools[tool.name] then return id,row,tool,store end end
 end end
end
function M.is_read(name)local id,row,tool=M.resolve_tool(name);return id~=nil and row.definition.tools[tool.name]=='read' end
function M.call(name,args,ctx)
 local id,row,tool=M.resolve_tool(name);if not id then return fail('mcp_tool_not_approved') end
 local options={action='call',server=row.definition,tool=tool.name,schema_hash=row.probe.schema_hash}
 if ctx and ctx.tool_arguments_json then options.arguments_json=ctx.tool_arguments_json elseif next(args or {})then options.arguments=args end
 local answer=M.invoke(options,ctx)
 local current,raw=load_store();local same=current.servers[id]
 if same and same.revision==row.revision then
  local recorded=mutate(raw,function(value)
   local entry=value.servers[id];entry.last_call={at=host.now(),ok=answer.ok,error=answer.error,outcome=answer.outcome,operation_id=answer.operation_id}
   if answer.error=='mcp_tool_schemas_changed' then entry.enabled=false;entry.probe=nil end
   return {ok=true}
  end)
  if not recorded.ok then answer.registry_observation_error=recorded.error end
 end
 return answer
end
-- Trusted WhatsApp facade only. Its caller already reserved the effect and
-- checked profile/event/budget/operator-precedence; MCP cannot grant those.
function M.whatsapp(method,args,binding,ctx)
 local directory=M.script_dir();if not directory then return fail('mcp_script_directory_unbound') end
 binding=binding or {};binding.cache_dir=binding.cache_dir or paths.cache()..'/mcp/whatsapp'
 local server={transport='stdio',program=host.getenv('WA_NODE') or 'node',args={directory..'/mcp-whatsapp.mjs','--binding-json',json.encode(binding)},timeout_seconds=120}
 local input={action='call',server=server,tool=method};if next(args or {})then input.arguments=args end
 local answer=M.invoke(input,ctx);local data=native_data(answer)
 if data and not answer.error then data.mcp_operation_id=answer.operation_id;return data end
 return fail(answer.error or 'mcp_whatsapp_result_unreadable',{observed=answer,dispatch=answer.tool_call_issued and 'mcp' or nil,outcome=answer.outcome,operation_id=answer.operation_id})
end
return M
