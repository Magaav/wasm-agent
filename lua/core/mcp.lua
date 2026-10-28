-- MCP extension registry/policy. Platform execution stays in host.operation.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local platform=dofile('lua/core/platform.lua')
local read_sessions=dofile('lua/core/mcp_session.lua')
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
-- Where the MCP runtime (`mcp-*.mjs`, `web-*.mjs`) lives on disk. The Lua core is embedded in the
-- binary; these files are not. A node that cannot name their directory answers every MCP tool with
-- `mcp_script_directory_unbound` (and `web_adapter_not_installed` from the web facade), which is what a
-- fresh install did: the installer shipped `upgrade.sh` and nothing else.
--
-- Order: the explicit override, the checkout root used in development, the install directory, then the
-- node's own data directory. The last one needs no environment variable and no install layout - the host
-- always reports it - so a new node, or a node in a brand-new cluster, finds the runtime without being
-- told where it is.
local function script_candidates()
 local list={}
 local function add(dir)if type(dir)=='string' and dir~='' and absolute(dir) then list[#list+1]=dir end end
 add(host.getenv('WA_MCP_SCRIPT_DIR'))
 local root=host.getenv('WASM_AGENT_LUA_ROOT');if root and root~='' then add(root..'/scripts') end
 local install=host.getenv('WA_INSTALL_DIR');if install and install~='' then add(install..'/scripts') end
 -- The install a sentinel started this node from (it exports it): where every deploy ships the runtime.
 local operator=host.getenv('WA_INSTANCE_OPERATOR_INSTALL');if operator and operator~='' then add(operator..'/scripts') end
 local okdata,data=pcall(paths.data);if okdata and type(data)=='string' then add(data..'/scripts') end
 if platform.os()=='windows' then local localapp=host.getenv('LOCALAPPDATA');if localapp then add(localapp..'/wasm-agent/scripts') end end
 return list
end
function M.script_candidates()return script_candidates() end
-- The MCP runtime the node spawns: these files and nothing else they import. scripts/install.sh,
-- scripts/install.ps1 and scripts/deploy.sh ship exactly this list, and
-- scripts/test-mcp-runtime-closure.mjs fails when any of them, or the real import graph, disagrees.
M.RUNTIME={'mcp-client.mjs','mcp-client-core.mjs','mcp-server-core.mjs','mcp-session.mjs','mcp-web.mjs',
 'mcp-whatsapp.mjs','mcp-mail.mjs','web-core.mjs','web-http-outcomes.mjs'}
local function complete(dir)
 for _,file in ipairs(M.RUNTIME) do if host.path_kind(dir..'/'..file)~='file' then return false end end
 return true
end
function M.script_dir()
 -- A directory holding only part of the runtime is skipped: a stale copy with mcp-client.mjs but without
 -- web-core.mjs answered first and every web_search/web_read died at import (mcp_stdio_eof, 28/10).
 for _,dir in ipairs(script_candidates()) do
  if complete(dir) then return dir end
 end
 for _,dir in ipairs(script_candidates()) do
  if host.read_file(dir..'/mcp-client.mjs') then return dir end
 end
 -- Nothing holds the runtime. An operator's explicit override is still returned, so the error that follows
 -- names the directory they chose instead of a generic "not installed".
 local override=host.getenv('WA_MCP_SCRIPT_DIR');if override and override~='' then return override end
 return nil
end
-- The failure a missing runtime must produce: the code callers already check, plus what was searched and the
-- one-line fix. Losing that detail is what made the original report look like a permission refusal.
function M.scripts_missing()
 return fail('mcp_scripts_not_found',{searched=script_candidates(),tool_call_issued=false,outcome='not_submitted',
  fix='install the MCP runtime beside the node (scripts/install.sh does this) or set WA_MCP_SCRIPT_DIR'})
end
-- The Node program that runs the MCP runtime. An explicit `WA_NODE` wins; after that, the copy the
-- installer provisions beside the node (`<install>/node`, `<data>/node`, `node.exe` on Windows), because a
-- device whose PATH has no Node was a device where every MCP tool refused. `path_kind` is a stat, never a
-- read: this must not load a hundred megabytes of binary into Lua to answer a path question.
local function node_program()
 local override=host.getenv('WA_NODE');if override and override~='' then return override end
 local relative=platform.os()=='windows' and '/node/node.exe' or '/node/bin/node'
 local bases={}
 local install=host.getenv('WA_INSTALL_DIR');if install and install~='' then bases[#bases+1]=install end
 local okdata,data=pcall(paths.data);if okdata and type(data)=='string' then bases[#bases+1]=data end
 for _,base in ipairs(bases) do
  local program=base..relative
  if host.path_kind(program)=='file' then return program end
 end
 return 'node'
end
function M.node_program()return node_program() end
-- The read sessions launch the same runtime: they used `WA_NODE or 'node'`, so on a node with no
-- system Node (the sandbox image) every reused read failed `program_not_found_on_path` while a probe,
-- which comes through here, passed (28/10).
read_sessions.node_program=node_program
-- The mail-mcp binary the installer provisions (`<install>/bin/mail-mcp`, `mail-mcp.exe` on Windows).
-- `MAIL_MCP_BIN` wins, because that is what the installer records and what an operator overrides by hand.
local function mail_program()
 local override=host.getenv('MAIL_MCP_BIN');if override and override~='' then return override end
 local relative=platform.os()=='windows' and '/bin/mail-mcp.exe' or '/bin/mail-mcp'
 local bases={}
 local install=host.getenv('WA_INSTALL_DIR');if install and install~='' then bases[#bases+1]=install end
 local okdata,data=pcall(paths.data);if okdata and type(data)=='string' then bases[#bases+1]=data end
 for _,base in ipairs(bases) do
  local binary=base..relative
  if host.path_kind(binary)=='file' then return binary end
 end
 return nil
end
function M.mail_program()return mail_program() end
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
 ctx=ctx or {}
 local directory=M.script_dir()
 if input.persistent_read and host.getenv('WA_MCP_SESSION_MODE')~='request' then
  if not directory or not host.read_file(directory..'/mcp-session.mjs') then return fail('mcp_session_not_installed',{outcome='not_submitted',tool_call_issued=false}) end
  return read_sessions.invoke(input,ctx,directory)
 end
 local directory=M.script_dir();if not directory then local missing=M.scripts_missing();missing.error='mcp_script_directory_unbound';return missing end
 local client=directory..'/mcp-client.mjs';if not host.read_file(client)then return fail('mcp_client_not_installed',{tool_call_issued=false,outcome='not_submitted'}) end
 local request=paths.data()..'/mcp/requests/'..host.uuid()..'.json'
 input.result_file=request..'.result.json'
 if not host.write_file(request,json.encode(input))then return fail('mcp_request_not_written',{tool_call_issued=false,outcome='not_submitted'}) end
 local timeout=input.server.timeout_seconds or 30
 local start=decode(host.operation('start',json.encode({program=node_program(),args={client,'--request-file',request},cwd=ctx.cwd or platform.cwd(),timeout_seconds=math.min(86400,timeout+3),owner=ctx.session_id or 'mcp-control'})))
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
  answer.evidence={path=input.result_file,sha256=answer.result_sha256,bytes=answer.result_bytes}
  local parsed=decode(retained)
  if parsed then parsed.evidence=answer.evidence end
  answer=parsed
 end
 if not answer then return fail('mcp_operation_result_unreadable',{operation_id=id,request=request,tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'}) end
 answer.operation_id=id;answer.request=request
 return answer
end
function M.close_read_sessions()return read_sessions.close() end
function M.default_whatsapp()
 local directory=M.script_dir() or '<installed scripts directory>'
 return {id='whatsapp',name='WhatsApp',transport='stdio',program=node_program(),args={directory..'/mcp-whatsapp.mjs','--binding-json',json.encode({backend='linked_device',allowed_conversations=json.decode('[]')})},
  env={WA_MCP_WHATSAPP_ACCOUNT='WA_WHATSAPP_ACCOUNT',WA_MCP_WHATSAPP_GENERATION='WA_WHATSAPP_GENERATION',WA_MCP_WHATSAPP_URL='WA_WHATSAPP_CONNECTOR_URL',WA_MCP_WHATSAPP_TOKEN_FILE='WA_WHATSAPP_TOKEN_FILE'},
  timeout_seconds=60,tools={read_snapshot='read',lookup_self='read',inspect_chat='read'}}
end
function M.inventory()
 local store=load_store();local servers={}
 for id,row in pairs(store.servers)do
  servers[#servers+1]={id=id,name=row.definition.name or id,definition=row.definition,enabled=row.enabled==true,revision=row.revision,
   probe=row.probe,last_call=row.last_call,session_mode='read-reuse/write-request',observed_status=row.probe and (row.probe.ok and 'last probe passed' or 'last probe failed') or 'not verified'}
 end
 table.sort(servers,function(a,b)return a.id<b.id end)
 return {ok=true,revision=store.revision,servers=servers,templates={whatsapp=M.default_whatsapp()},can_manage=true,
  adapters={{id='whatsapp',name='WhatsApp',profile_managed=true,capabilities={'scoped linked-device journal reads','explicit self/target identity','draft visibility unsupported; general sends refused'},note='Linked-device connector only. Private deterministic transcript policy is activated by the operator separately; no generic send authority, Chrome fallback or automatic wake.'}},
  note='Explicit trusted connectors; last probe is not live health. Approved reads may reuse idle-bounded sessions; writes and WhatsApp stay request-scoped. Jobs owns wakes.'}
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
 if row.definition.tools[tool.name]=='read' then
  options.persistent_read=true;options.read_tools={}
  for allowed,effect in pairs(row.definition.tools)do if effect=='read' then options.read_tools[#options.read_tools+1]=allowed end end
  table.sort(options.read_tools)
 end
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
 return M.project(answer)
end
-- Catalogue/transport evidence stays exact on disk, outside ordinary model replies.
function M.project(answer)
 local out={ok=answer.ok,error=answer.error,phase=answer.phase,rpc_error=answer.rpc_error,outcome=answer.outcome,tool_call_issued=answer.tool_call_issued,evidence=answer.evidence,
  session_mode=answer.session_mode,reused=answer.reused,unsupported_content_types=answer.unsupported_content_types,content_delivery=answer.content_delivery,registry_observation_error=answer.registry_observation_error}
 if answer.result_json then out.result=json.raw(answer.result_json) elseif answer.result then out.result=answer.result end
 if not answer.evidence and not answer.result_json and not answer.result then out.detail=answer end
 return out
end
-- Trusted WhatsApp facade only. Its caller already reserved the effect and
-- checked profile/event/budget/operator-precedence; MCP cannot grant those.
function M.whatsapp(method,args,binding,ctx)
 local directory=M.script_dir();if not directory then return fail('mcp_script_directory_unbound') end
 binding=binding or {}
 local server={transport='stdio',program=node_program(),args={directory..'/mcp-whatsapp.mjs','--binding-json',json.encode(binding)},timeout_seconds=120}
 local input={action='call',server=server,tool=method};if next(args or {})then input.arguments=args end
 local answer=M.invoke(input,ctx);local data=native_data(answer)
 if data and not answer.error then data.mcp_operation_id=answer.operation_id;return data end
 return fail(answer.error or 'mcp_whatsapp_result_unreadable',{observed=answer,dispatch=answer.tool_call_issued and 'mcp' or nil,outcome=answer.outcome,operation_id=answer.operation_id})
end
return M
