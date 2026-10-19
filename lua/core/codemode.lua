-- Pi1.2-compatible guest protocol over Node-free host.quickjs. Agent/tool policy
-- stays here and in the native dispatcher; JS never receives host capabilities.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local output=dofile('lua/core/tool_output.lua')
local telemetry=dofile('lua/core/telemetry.lua')
local presentation=dofile('lua/core/codemode_view.lua')
-- The node's own capability inventory: the same registry the CLI prints and `/health` digests.
local inventory=dofile('lua/core/capability_inventory.lua')
local M={}
local forbidden={wave_autoflush=true,codemode=true,tool_call=true,tool_search=true,subagent=true,integrate=true,session_worktree=true,
 session=true,sessions=true,resume_session=true,session_debug=true,session_fixture=true,session_many=true,search_messages=true,search_messages_many=true,operation=true,
 remote=true,nodes=true,client=true,shell=true,mcp=true,capabilities=true,spell_run=true,spell_export=true,
 spell_save=true,spell_compose=true,spell_list=true,spell_get=true,spell_forget=true,resource=true}
function M.run(memory,args,role,ctx,catalog,current_catalog,dispatch,execution)
 local policy,refusal=dofile('lua/core/codemode_policy.lua').admit(memory,role,ctx)
 if not policy then return {ok=false,error=refusal,calls={},attempts={}} end
 if type(args.code)~='string' or args.code=='' then return {error='codemode_source_required'} end
 local workspace=memory.session_workspace and memory.session_workspace(ctx.session_id) or nil
 local scope=host.sha256(json.encode({session=ctx.session_id,user=ctx.user_id,role=role,workspace=workspace,profile=ctx.subagent and ctx.subagent.allowed or nil}))
 local descriptors,definitions={},{}
 for _,schema in ipairs(catalog)do
  local f=schema['function'];local status=execution(f.name)
  if not forbidden[f.name] and status.status~='blocked' and status.status~='unknown' then
   local js=f.name:gsub('[^%w_]','_')
   if definitions[js] and definitions[js].name~=f.name then return {error='codemode_identifier_collision'} end
   definitions[f.name]={name=f.name,schema=schema,hash=host.sha256(json.encode(schema))}
   definitions[js]=definitions[f.name]
   descriptors[#descriptors+1]={name=f.name,jsName=js,description=f.description}
  end
 end
 local globals={{name='searchTools',spread=true},{name='describeTool',spread=false},{name='showCall',spread=false},
  -- Introspection of what this node can do, for a workflow that would otherwise guess. They read
  -- the host capability registry and nothing else: no authority moves, no effect is admitted.
  {name='capabilities',spread=false},{name='describe',spread=false}}
 local selected={}
 local store_key='codemode-store.v1:'..scope
 local raw=memory.meta_get(store_key);local store=raw and json.decode(raw) or {}
 local spec={owner=scope,tools=descriptors,globals=globals,store=store,code=args.code,timeout_ms=args.timeout_ms or 30000}
 spec.wasm_path=policy.wasm_path;spec.prelude_path=policy.prelude_path
 local response=json.decode(host.quickjs('start',json.encode(spec)))
 if not response.ok then
  response.items={};response.unexecuted={}
  for _,event in ipairs(response.events or {})do
   if event.type=='output' then response.items[#response.items+1]=event.item
   elseif event.type=='call' then response.unexecuted[#response.unexecuted+1]={id=event.id,name=event.name,executed=false,effect='none',reason='sandbox_failed_before_admission'}end
  end
  return response
 end
 local sandbox=response.id;local pending,seen,items,calls,attempts={},{},{},{},{}
 local done
 local function consume(events)
  for _,e in ipairs(events or {})do
   if e.type=='call' then pending[#pending+1]=e
   elseif e.type=='output' then items[#items+1]=e.item
   elseif e.type=='done' then done=e
   else error('codemode_protocol_unknown_event')end
  end
 end
 local ok,problem=pcall(function()
  consume(response.events)
  while not done do
   local _,context_error=dofile('lua/core/codemode_policy.lua').admit(memory,role,ctx)
   if context_error then error(context_error) end
   if host.run_cancelled and json.decode(host.run_cancelled()).cancelled then error('run_cancelled')end
   local admitted_now=json.decode(host.quickjs('admit',json.encode({id=sandbox,owner=scope})))
   if not admitted_now.ok then error(admitted_now.error)end
   local call=table.remove(pending,1)
   if not call then error('codemode_stalled')end
   if seen[call.id] then error('codemode_duplicate_call')end;seen[call.id]=true
   local value,success,admitted
   local attempt_span=telemetry.start(ctx,'codemode_call',{name=call.name,target=call.target,nested=true,codemode_call=call.id,arguments_hash=host.sha256(call.args or '{}')})
   if call.target=='global' then
    -- A guest global called with no arguments sends the literal string `undefined`, not `[]`, and the
    -- strict JSON contract refuses it: `capabilities()` - the whole point of the inventory - died
    -- as `json_contract_invalid` before this line existed. No arguments is an empty argument list.
    local global_args=call.args
    if global_args==nil or global_args=='' or global_args=='undefined' then global_args='[]' end
    local ast,err=contract.parse(global_args);if not ast then error(err)end
    local params=json.decode(global_args)
    if call.name=='showCall' then
     value,success=presentation.select(calls,selected,params)
    elseif call.name=='searchTools' then
     local query=params[1];local options=params[2];local limit=type(options)=='table' and options.limit or 8
     if type(query)~='string' or #query>256 or not query:find('%S') then value={error='tool_search_query_required'};success=false
     elseif type(limit)~='number' or limit%1~=0 or limit<1 or limit>8 then value={error='invalid_tool_search_limit'};success=false
     else
      -- Guest discovery is metadata over its own exact ceiling, never an envelope
      -- facade invocation or a new delegation/load authority.
      local matches={}
      for _,descriptor in ipairs(descriptors)do
       local def=definitions[descriptor.name];local hay=(def.name..' '..tostring(def.schema['function'].description)):lower();local score=0
       for term in query:lower():gmatch('[%w_]+')do if hay:find(term,1,true)then score=score+1 end end
       if score>0 then matches[#matches+1]={name=def.name,schema=def.schema,execution=execution(def.name),score=score} end
      end
      table.sort(matches,function(a,b)return a.score==b.score and a.name<b.name or a.score>b.score end)
      local found={};for i=1,math.min(limit,#matches)do found[i]=matches[i];found[i].score=nil end
      value={tools=found,matches=#matches,invocation='Guest-local metadata only; native current-catalog/profile/type/effect checks apply to each call.'};success=true
     end
    elseif call.name=='describeTool' then
     local name=type(params)=='string' and params or params[1]
     local def=definitions[name];value=name=='showCall' and presentation.help or def and {name=def.name,description=def.schema['function'].description,parameters=def.schema['function'].parameters,execution=execution(def.name)} or nil;success=true
    elseif call.name=='capabilities' or call.name=='describe' then
     -- The host.* inventory, exactly as `wa capabilities --json` prints it and `/health`
     -- digests it. Read-only metadata over the registry; it admits no call, changes no ceiling.
     value,success=inventory.global(call.name,params)
     if value==nil then value={error='codemode_global_not_available'};success=false end
    else value={error='codemode_global_not_available'};success=false end
   elseif call.target=='tool' then
    local def=definitions[call.name]
    if not def or forbidden[call.name] then value={error='codemode_target_not_available'};success=false
    else
     local current
     for _,schema in ipairs(current_catalog())do if schema['function'].name==def.name then current=schema;break end end
     if not current or host.sha256(json.encode(current))~=def.hash then value={error='tool_definition_changed'};success=false
     else
      local _,err=contract.validate(current['function'].parameters,call.args or '{}')
      if err then value={error=err};success=false
      else
       local params=json.decode(call.args or '{}')
       local span=telemetry.start(ctx,'tool',{name=def.name,nested=true,codemode_call=call.id,arguments_hash=host.sha256(call.args or '{}')})
       local called,result=pcall(dispatch,def.name,params,call.args);admitted=true
       if called then
        value=result;success=type(value)~='table' or (not value.error and value.ok~=false)
       else value={error=tostring(result),effect='unknown',replay_allowed=false};success=false end
       local encoded=json.encode(value);local reference=output.store(encoded)
       calls[#calls+1]={id=call.id,name=def.name,ok=success,evidence=reference}
       telemetry.finish(span,{ok=success,name=def.name,nested=true,codemode_call=call.id,result_bytes=#encoded,result_hash=host.sha256(encoded)})
      end
     end
    end
   else error('codemode_target_unknown')end
   local argument_reference=output.store(call.args or '{}');local result_reference=output.store(json.encode(value))
   attempts[#attempts+1]={id=call.id,name=call.name,target=call.target,admitted=admitted or false,ok=success,arguments=argument_reference,result=result_reference}
   telemetry.finish(attempt_span,{name=call.name,target=call.target,ok=success,admitted=admitted or false,nested=true,codemode_call=call.id,result_hash=result_reference.sha256})
   local delivered=json.decode(host.quickjs('deliver',json.encode({owner=scope,id=sandbox,call_id=call.id,ok=success,payload=json.encode(value)})))
   consume(delivered.events)
   if not delivered.ok then error(delivered.error)end
  end
  if done.ok and done.writes and done.writes~='undefined' then
   local writes=json.decode(done.writes)
   for _,entry in ipairs(writes)do
    if type(entry)=='table' and type(entry[1])=='string' and (entry[2]==nil or type(entry[2])=='string') then store[entry[1]]=entry[2]
    else error('codemode_store_protocol_invalid') end
   end
   memory.meta_set(store_key,json.encode(store))
  end
 end)
 local closed=json.decode(host.quickjs('close',json.encode({id=sandbox,owner=scope})))
 if not closed.ok then return {ok=false,error='codemode_close_failed',detail=closed.error,items=items,calls=calls}end
 local skipped={};for _,call in ipairs(pending)do skipped[#skipped+1]={id=call.id,name=call.name,executed=false,effect='none',reason='script_finished_before_admission'}end
 local result={ok=ok and done and done.ok==true or false,error=not ok and tostring(problem) or done and not done.ok and done.error or nil,
  items=items,value=done and done.value,calls=calls,attempts=attempts,unexecuted=skipped,backend=response.backend or 'rust-wasmtime-quickjs-wasi',context_policy='only script output is model-facing; complete nested originals are retained by hash'}
 local presented,view=pcall(presentation.finish,result,selected)
 if presented then return view end
 result.ok=false;result.presentation_partial=true;result.presentation_error=tostring(view)
 result.shown=nil
 return result
end
return M
