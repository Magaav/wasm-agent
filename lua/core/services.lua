-- Service components registry (docs/SERVICE-COMPONENTS.md): which installed `kind:"service"`
-- components this node runs, with what grants, and whether they start at boot. The host
-- (host.service) does the running and supervision; this file owns definitions and policy.
-- Master only; never from a child agent. Stored like the MCP registry: one meta row, CAS writes.
--
-- Versioned state is the host's business, not this file's (docs/STATE.md): `host.service start`
-- runs the manifest's `state_version` migration on a snapshot copy before the instance exists and
-- reports it in the answer's `state` field, which this registry passes through untouched. An `enable`
-- whose `started.ok` is false - including a refused migration - stores nothing, so a definition the
-- node cannot run never becomes an enabled one.
local json=dofile('lua/vendor/json.lua')
local hooks=dofile('lua/core/hooks.lua')
local M={KEY='services.v1'}
local function fail(error,extra)local r=extra or {};r.ok=false;r.error=error;return r end
local function decode(raw)local ok,v=pcall(json.decode,tostring(raw or ''));if ok and type(v)=='table' then return v end end
local function query(sql,params)local v=decode(host.sql_query(sql,json.encode(params or {})));if not v or v.error then error(v and v.error or 'services_store_unreadable') end;return v end
local function exec(sql,params)local v=decode(host.sql_exec(sql,json.encode(params or {})));if not v or v.error or v.ok~=true then error(v and v.error or 'services_store_write_unverified') end;return v end
local function load_store()
 local rows=query('SELECT value FROM meta WHERE key=?',{M.KEY});local raw=rows[1] and rows[1].value
 if not raw then return {schema=1,revision=0,services={}},nil end
 local v=decode(raw);if not v or v.schema~=1 or type(v.services)~='table' then error('services_store_corrupt') end
 return v,raw
end
local function mutate(expected_revision,change)
 local ok,result=pcall(function()
  local current,raw=load_store()
  if expected_revision~=current.revision then return fail('services_store_revision_changed',{revision=current.revision}) end
  local r=change(current);if r.error then return r end
  current.revision=current.revision+1;local encoded=json.encode(current);local saved
  if raw==nil then saved=exec('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)',{M.KEY,encoded})
  else saved=exec('UPDATE meta SET value=? WHERE key=? AND value=?',{encoded,M.KEY,raw}) end
  if saved.changes~=1 then return fail('services_store_changed') end
  r.revision=current.revision;return r
 end)
 if not ok then return fail(tostring(result)) end;return result
end
local function dense(list,max)if type(list)~='table' or #list>max then return false end;for k,v in pairs(list)do if type(k)~='number' or type(v)~='string' then return false end end;return true end
local function absolute(v)return type(v)=='string' and (v:sub(1,1)=='/' or v:match('^%a:[/\\]')~=nil) end

function M.validate(def)
 if type(def)~='table' then return 'invalid_service_definition' end
 local allowed={name=true,env=true,file_env=true,net=true,config=true,description=true}
 for k in pairs(def)do if not allowed[k] then return 'unsupported_service_definition_field:'..tostring(k) end end
 if type(def.name)~='string' or not def.name:match('^[a-z][a-z0-9-]*$') or #def.name>40 then return 'invalid_service_name' end
 if def.net~=nil then
  if not dense(def.net,32) then return 'invalid_service_net' end
  for _,a in ipairs(def.net)do if not (a:match('^%*?%.?[%w%.%-]+:%d+$') or a:match('^[%w%.%-]+:%*$')) then return 'invalid_service_net' end end
 end
 for _,field in ipairs({'env','file_env'})do
  if def[field]~=nil then
   if type(def[field])~='table' then return 'invalid_service_references' end
   for k,name in pairs(def[field])do
    if type(k)~='string' or type(name)~='string' or not (name:match('^[A-Za-z_][A-Za-z0-9_]*$') or (field=='file_env' and absolute(name) and not name:find('[\r\n%z]'))) then return 'service_credentials_require_references' end
   end
  end
 end
 if def.config~=nil and type(def.config)~='table' then return 'invalid_service_config' end
 return nil
end

local function start_request(def)
 return {action='start',name=def.name,env=def.env,file_env=def.file_env,net=def.net,config=def.config}
end
local function host_call(request)
 if not host.service then return fail('service_runtime_unavailable') end
 return decode(host.service(json.encode(request))) or fail('service_answer_unreadable')
end

function M.inventory()
 local store=load_store();local list={}
 local live={};for _,s in ipairs(host.service and decode(host.service(json.encode({action='status'}))) or {})do live[s.name]=s end
 for name,row in pairs(store.services)do list[#list+1]={name=name,enabled=row.enabled,definition=row.definition,live=live[name] or {state='not_running'}} end
 table.sort(list,function(a,b)return a.name<b.name end)
 return {ok=true,revision=store.revision,services=list}
end

local function component_hook(event,args,extra,ctx)
 local verdict=hooks.fire(event,{component=tostring(args.name or (type(args.definition)=='table' and args.definition.name) or ''),
  action=tostring(args.action or extra and extra.action or ''),artifact=tostring(args.source or ''),
  state=extra and extra.state},{session_id=ctx and ctx.session_id,user_id=ctx and ctx.user_id,role=ctx and ctx.role,cwd=nil})
 for _,text in ipairs(verdict.system_messages or {}) do pcall(host.log,'component hook: '..tostring(text)) end
 return verdict
end

function M.control(args,ctx)
 ctx=ctx or {}
 if ctx.role~='master' and ctx.role~='admin' then return fail('forbidden') end
 if ctx.subagent then return fail('services_management_forbidden_for_subagent') end
 local action=args.action
 if action=='list' then return M.inventory() end
 -- The speech queue's node half (docs/QUEUE.md "Phase 2"): the role this node plays, the workers
 -- attached to its queue, their recent latency and the local-vs-remote decode counts. Reads the
 -- node's own runtime; never a transcript.
 if action=='stt' then return dofile('lua/core/stt.lua').view() end
 -- The effective configuration after base -> node -> user -> patch (docs/KERNEL.md, "Profiles as
 -- layers"), rows by id. Read-only and needed by every operator, so no registry revision.
 if action=='profile_dump' then return host_call({action='profile_dump',name=args.name}) end
 if action=='status' or action=='logs' then
  if type(args.name)~='string' then return fail('service_name_required') end
  return host_call({action=action,name=args.name,bytes=args.bytes})
 end
 if action=='restart' then
  -- Operational, not a definition change: no registry revision needed.
  local row=type(args.name)=='string' and load_store().services[args.name]
  if not row then return fail('service_unknown') end
  if not row.enabled then return fail('service_not_enabled') end
  host_call({action='stop',name=args.name});return host_call(start_request(row.definition))
 end
 if action=='upgrade' then
  -- Transactional install/upgrade (docs/KERNEL.md, lesson 5). The *grants* stay the ones the
  -- definition was enabled with - an upgrade replaces bytes, not authority - and the artifact comes
  -- from `source`. A candidate that fails any stage leaves the running instance untouched, so this is
  -- not a registry change either: nothing is stored unless the host answers ok.
  local row=type(args.name)=='string' and load_store().services[args.name]
  if not row then return fail('service_unknown') end
  if not row.enabled then return fail('service_not_enabled') end
  -- `ComponentInstall` can refuse the swap before a single byte is staged (a pin that names the
  -- wrong commit, an operator freezing installs). It answers before the host is asked, so a refusal
  -- leaves the running instance exactly as it was.
  local install=component_hook('ComponentInstall',args,{action='upgrade'},ctx)
  if install.blocked then return fail('component_install_refused',{reason=install.reason,refused_by=install.blocked_by}) end
  local request=start_request(row.definition)
  request.action='upgrade'
  request.source=args.source
  if args.ready_ms~=nil then request.ready_ms=args.ready_ms end
  local answer=host_call(request)
  if answer.ok then
   answer.definition=row.definition
   local swap=component_hook('ComponentSwap',args,{action='upgrade',state=answer.state},ctx)
   answer.hook_context=swap.additional_context
  end
  return answer
 end
 if type(args.expected_revision)~='number' then return fail('services_store_revision_changed',{revision=load_store().revision}) end
 if action=='put' then
  local problem=M.validate(args.definition);if problem then return fail(problem) end
  return mutate(args.expected_revision,function(store)
   local old=store.services[args.definition.name]
   if old and old.enabled then return fail('service_enabled: disable it before changing its definition') end
   store.services[args.definition.name]={definition=args.definition,enabled=false};return {ok=true,name=args.definition.name,enabled=false}
  end)
 end
 if action=='enable' or action=='disable' or action=='remove' then
  local store=load_store();local row=type(args.name)=='string' and store.services[args.name]
  if not row then return fail('service_unknown') end
  if action=='enable' then
   local install=component_hook('ComponentInstall',args,{action='enable'},ctx)
   if install.blocked then return fail('component_install_refused',{reason=install.reason,refused_by=install.blocked_by}) end
   local started=host_call(start_request(row.definition))
   -- `started.state` is the install's own report (`fresh` / `up-to-date` / `migrated`); a refusal
   -- there means the instance never started, so the definition is not enabled either.
   if not started.ok then return started end
   local saved=mutate(args.expected_revision,function(s)s.services[args.name].enabled=true;return {ok=true,name=args.name,enabled=true}end)
   if not saved.ok then host_call({action='stop',name=args.name}) end
   saved.start=started;return saved
  end
  local stopped=host_call({action='stop',name=args.name})
  local saved=mutate(args.expected_revision,function(s)
   if action=='remove' then s.services[args.name]=nil else s.services[args.name].enabled=false end
   return {ok=true,name=args.name,enabled=false,removed=action=='remove' or nil}
  end)
  saved.stop=stopped;return saved
 end
 return fail('invalid_services_action')
end

-- Boot: start every enabled service **by imports** (docs/KERNEL.md, lesson 3). `host.service supervise`
-- plans against what each artifact imports, starts providers before consumers whatever order this
-- store enumerates them in, and answers what still waits - so a channel that needs a provider which is
-- also enabled comes up without the operator ordering the definitions by hand. A definition whose
-- component is not installed yet is reported as waiting (with the reason), not as an error, and a
-- second interpreter loading server.lua is harmless: a running instance with the same pin is left
-- alone.
function M.autostart()
 local ready=query("SELECT name FROM sqlite_master WHERE type='table' AND name='meta'",{})
 if #ready==0 then return {ok=true,started={}} end
 local store=load_store();local definitions={}
 for _,row in pairs(store.services)do if row.enabled then definitions[#definitions+1]=row.definition end end
 if #definitions==0 then return {ok=true,started={}} end
 table.sort(definitions,function(a,b)return a.name<b.name end)
 local answer=host_call({action='supervise',definitions=definitions})
 if answer.error then return answer end
 -- `started` keeps the shape callers already read: one entry per enabled definition that is up, whether
 -- this call started it or found it running (`already_running`, the old `host.service start` idempotency
 -- answer), so a second interpreter loading server.lua sees the same registry.
 local started={}
 for name,row in pairs(answer.started or {})do started[name]=row end
 for _,row in ipairs(answer.already_running or {})do started[row.name]={ok=true,already_running=true,sha256=row.sha256,instance=row.instance} end
 return {ok=answer.ok~=false,started=started,waiting=answer.waiting or {},refused=answer.refused or {}}
end

return M
