-- Pi1.2-compatible guest protocol over Node-free host.quickjs. Agent/tool policy
-- stays here and in the native dispatcher; JS never receives host capabilities.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local output=dofile('lua/core/tool_output.lua')
local telemetry=dofile('lua/core/telemetry.lua')
local presentation=dofile('lua/core/codemode_view.lua')
-- Discovery spellings are parsed in one place: searchTools({names={...}}) and searchTools("select:a,b") are
-- the same request as tool_search, so the guest cannot drift from the outer facade (07/11).
local envelope=dofile('lua/core/envelope.lua')
-- The node's own capability inventory: the same registry the CLI prints and `/health` digests.
local inventory=dofile('lua/core/capability_inventory.lua')
local M={}
-- Control plane stays ordinary where BEING A SINGLE REVIEWABLE ACTION, or owning the session, is the
-- safety argument: delegation/authority/recursion (subagent, integrate, session_worktree, resume_session),
-- session shaping (session_debug, session_fixture), the internal autoflush, and the outer facades
-- (codemode, tool_call, tool_search, capabilities) that have in-sandbox equivalents. Everything else is now
-- callable from a script - connectors (mcp), the user's own shell and client, spells, and every peer
-- capability - with exactly the per-call permission, effect, workspace and binding checks an ordinary call
-- gets (31/10: the operator asked code mode to do everything it can, after a peer effect was refused).
local forbidden={codemode=true,tool_call=true,tool_search=true,capabilities=true,
 subagent=true,integrate=true,session_worktree=true,resume_session=true,
 session_debug=true,session_fixture=true,wave_autoflush=true}
-- What a tool that is not callable here is for, so discovery never reads as "does not exist" (29/10).
local function route_of(name,status)
 if name=='codemode' then return 'You are inside codemode; scripts do not nest.' end
 if name=='tool_search' or name=='tool_call' then return 'Outer facade: inside a script use searchTools/describeTool and call await tools.<name>(args) directly.' end
 if name=='capabilities' then return 'Outer tool; inside a script call the capabilities() global.' end
 if status and (status.status=='blocked' or status.status=='unknown') then return 'Not callable in this run: '..tostring(status.reason or status.status)..'. '..tostring(status.next or '') end
 return 'Control plane: call '..name..' as an ordinary tool, outside codemode (end the script, then call it directly). Inside a script it is refused.'
end
-- Multi-action tools whose read actions belong inside and whose effects do not: a script may watch an
-- operation or list resource claims, never start, cancel or reconcile one.
-- Multi-action tools: every action is callable inside now, with the same admission, effect and workspace
-- checks an ordinary call gets - `operation start/cancel/await` and `resource reconcile` are how a script
-- supervises what it started (31/10). Kept as a named seam so a later fence has somewhere to live.
local function action_refusal(name,args) return nil end
-- ---------------------------------------------------------------- the code-mode seam
---
--- The guest's *protocol* - the fence, the tool table, `searchTools`/`describeTool`, the admit/deliver
--- order, the named refusals and the script's report - can be served by the `codemode` component
--- (docs/CORE-SPLIT.md, docs/CODEMODE.md), which imports `wa:kernel/quickjs` for the sandbox the kernel
--- hosts. `WA_CODEMODE_COMPONENT=1` routes a script there; **without it every line below runs exactly
--- the code it always ran**.
---
--- What stays here on both paths, because it needs the living turn: `codemode_policy.admit`, the tool
--- dispatcher with the current profile/catalog/workspace/effect checks and the strict JSON contract
--- against the live schema, the definition recheck, the retained originals and their evidence
--- references, the telemetry spans, the presentation (`showCall`) and the session store in `meta`.
---
--- A component that is missing or refuses *before a step is handed out* falls back to the native path
--- with one log line per reason. Once a script is live, a broken component is **reported**, never
--- replayed: the calls already dispatched had effects, and docs/CODEMODE.md's rule is that a failed
--- effectful script is never run again.
--
-- The switch is `docs/FEATURES.md`'s `codemode` feature, asked through `lua/core/features.lua` at every
-- route (not read once at load): an operator turns it on in `policy.json` and the next script takes the
-- component path, without a restart. A feature that is on with no component installed answers
-- `component_missing` and the fallback line says so.
local features = dofile("lua/core/features.lua")
-- The test seam: two instances of this module in one process (native and seam) share one `host.features`
-- table, so the component test sets this on the instance it wants routed. A node never sets it.
M.seam_override = nil
local function seam_component()
  if M.seam_override ~= nil then return M.seam_override() end
  return features.seam("codemode")
end

local fallback_logged = {}

local function note_fallback(op, reason)
  local key = tostring(op) .. "|" .. tostring(reason)
  if fallback_logged[key] then return end
  fallback_logged[key] = true
  pcall(host.log, "codemode: " .. tostring(op) .. " served natively: " .. tostring(reason))
end

-- One component call. The capability speaks JSON like every other `host.*`; the component boundary
-- itself is typed (`wit/codemode`).
local function seam(request)
  local active, reason = seam_component()
  if not active then return nil, reason end
  if type(host.codemode) ~= "function" then return nil, "component_capability_missing" end
  local ok, answer = pcall(host.codemode, json.encode(request))
  if not ok then return nil, "component_call_failed" end
  if type(answer) == "string" then
    local decoded_ok, decoded = pcall(json.decode, answer)
    answer = decoded_ok and decoded or nil
  end
  if type(answer) ~= "table" then return nil, "component_no_answer" end
  if not answer.ok then return nil, tostring(answer.error or "component_failed") end
  return answer
end

-- The fence's refusal, rendered the way the dispatcher already words a target that runs elsewhere.
local function refusal_value(refusal)
  if type(refusal) ~= "table" or refusal.kind ~= "target_not_available" then
    return { error = "codemode_target_not_available", effect = "none" }
  end
  if refusal.route then
    return { error = "codemode_target_not_available: " .. tostring(refusal.name) .. " runs outside code mode",
      route = refusal.route, effect = "none" }
  end
  return { error = "codemode_target_not_available" }
end

-- The guest's argument list for a global: no arguments is `[]`, and an argument list that is not JSON
-- is refused by the strict contract exactly as the native loop refuses it.
local function global_params(raw)
  local text = raw
  if text == nil or text == "" or text == "undefined" then text = "[]" end
  local ast, err = contract.parse(text)
  if not ast then error(err) end
  return json.decode(text)
end

-- The node's own globals, answered here because they read the living registry and the retained
-- evidence: `capabilities()`/`describe()` are the host capability inventory, `showCall` and
-- `describeTool("showCall")` are the presentation's.
local function host_global(name, params, calls, selected)
  if name == 'showCall' then return presentation.select(calls, selected, params) end
  if name == 'describeTool' then return presentation.help, true end
  local value, success = inventory.global(name, params)
  if value == nil then return { error = 'codemode_global_not_available' }, false end
  return value, success
end

-- The native path: byte for byte the loop this file has always run. `workspace` and `scope` are the
-- run's, computed once by `M.run` so both paths agree on them.
local function native_run(policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope)
 local descriptors,definitions,outside={},{},{}
 for _,schema in ipairs(catalog)do
  local f=schema['function'];local status=execution(f.name)
  if forbidden[f.name] or status.status=='blocked' or status.status=='unknown' then
   outside[f.name]={name=f.name,schema=schema,route=route_of(f.name,status)}
  else
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
 local cached,cache=pcall(function()return dofile('lua/core/paths.lua').cache()end)
 if cached and type(cache)=='string' then spec.module_cache=cache..'/codemode' end
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
     -- Both shapes the model knows: searchTools("text", {limit}) and the tool_search shape
     -- searchTools({query, limit}). The object form used to be refused (`tool_search_query_required`),
     -- and "" or "*" could not list anything, so the guest could not see its own catalogue (28/10).
     local query=params[1];local options=params[2]
     if type(query)=='table' then options=query;query=options.query end
     options=type(options)=='table' and options or {}
     -- An exact batch (names=[...] or "select:a,b,c") is the same request as tool_search's: the same
     -- 1-8 names, the same mutual exclusion, and the same `missing` with nearest permitted names. This
     -- route returns metadata over the guest's own ceiling; it never loads or admits anything.
     local wanted,batch_error=envelope.requested_names({query=query,names=options.names})
     local catalogue={}
     for _,descriptor in ipairs(descriptors)do catalogue[descriptor.name]=true end
     for name in pairs(outside)do catalogue[name]=true end
     local function searchable(name)
      local def=definitions[name]
      if def then return {name=def.name,schema=def.schema,execution=execution(def.name),callable=true} end
      local out=outside[name]
      if out then return {name=out.name,schema=out.schema,execution=execution(out.name),callable=false,route=out.route} end
     end
     local listing=not wanted and (query==nil or query=='*' or (type(query)=='string' and not query:find('%S')))
     local limit=options.limit or (listing and 50 or 8)
     local offset=options.offset or 0
     if batch_error then value={error=batch_error};success=false
     elseif wanted then
      if options.limit~=nil and (type(options.limit)~='number' or options.limit%1~=0 or options.limit<1 or options.limit>8) then value={error='invalid_tool_search_limit'};success=false
      else
       local tools,missing={},{}
       for _,name in ipairs(wanted)do
        local entry=searchable(name)
        if entry then tools[#tools+1]=entry else local echo=envelope.echo_name(name);missing[#missing+1]={name=echo,suggestions=envelope.nearest(echo,catalogue,3)} end
       end
       value={tools=tools,matches=#tools,missing=missing,requested=#wanted,
        invocation='Guest-local metadata only; every entry listed here is callable in this script (callable:false entries run outside, see route). Native current-catalog/profile/type/effect checks apply to each call.'};success=true
      end
     elseif listing then
      if type(limit)~='number' or limit%1~=0 or limit<1 or limit>200 or type(offset)~='number' or offset%1~=0 or offset<0 then value={error='invalid_tool_search_limit'};success=false
      else
       -- The whole guest catalogue, names and one-line descriptions only; describeTool(name) gives a schema.
       local names={};for _,descriptor in ipairs(descriptors)do names[#names+1]=descriptor.name end
       for name in pairs(outside)do names[#names+1]=name end
       table.sort(names)
       local page={};for i=offset+1,math.min(#names,offset+limit)do
        local def=definitions[names[i]] or outside[names[i]];local text=tostring(def.schema['function'].description or '')
        page[#page+1]={name=def.name,description=text:match('^[^\n]*'):sub(1,200),execution=execution(def.name),callable=outside[def.name]==nil,route=outside[def.name] and outside[def.name].route or nil}
       end
       value={tools=page,matches=#names,offset=offset,has_more=offset+limit<#names,
        invocation='The whole catalogue, paged; describeTool(name) gives the full schema. callable:false entries run outside the script: their route says how. Native checks apply to each call.'};success=true
      end
     elseif type(query)~='string' or #query>256 then value={error='tool_search_query_required'};success=false
     elseif type(limit)~='number' or limit%1~=0 or limit<1 or limit>8 then value={error='invalid_tool_search_limit'};success=false
     else
      -- Guest discovery is metadata over its own exact ceiling, never an envelope
      -- facade invocation or a new delegation/load authority.
      local matches={}
      local function consider(def,route)
       local hay=(def.name..' '..tostring(def.schema['function'].description)):lower();local score=0
       for term in query:lower():gmatch('[%w_]+')do if hay:find(term,1,true)then score=score+1 end end
       if score>0 then matches[#matches+1]={name=def.name,schema=def.schema,execution=execution(def.name),score=score,callable=route==nil,route=route} end
      end
      for _,descriptor in ipairs(descriptors)do consider(definitions[descriptor.name]) end
      for _,def in pairs(outside)do consider(def,def.route) end
      table.sort(matches,function(a,b)return a.score==b.score and a.name<b.name or a.score>b.score end)
      local found={};for i=1,math.min(limit,#matches)do found[i]=matches[i];found[i].score=nil end
      value={tools=found,matches=#matches,invocation='Guest-local metadata only; callable:false entries run outside the script (see route). Native current-catalog/profile/type/effect checks apply to each call.'};success=true
     end
    elseif call.name=='describeTool' then
     local name=type(params)=='string' and params or params[1]
     local def=definitions[name];local out=type(name)=='string' and outside[name]
     value=name=='showCall' and presentation.help or def and {name=def.name,description=def.schema['function'].description,parameters=def.schema['function'].parameters,execution=execution(def.name),callable=true}
      or out and {name=out.name,description=out.schema['function'].description,parameters=out.schema['function'].parameters,callable=false,route=out.route} or nil;success=true
    elseif call.name=='capabilities' or call.name=='describe' then
     -- The host.* inventory, exactly as `wa capabilities --json` prints it and `/health`
     -- digests it. Read-only metadata over the registry; it admits no call, changes no ceiling.
     value,success=inventory.global(call.name,params)
     if value==nil then value={error='codemode_global_not_available'};success=false end
    else value={error='codemode_global_not_available'};success=false end
   elseif call.target=='tool' then
    -- tools.nodes() with no argument sends `undefined`, as a global does: no arguments is {} (29/10).
    if call.args=='undefined' or call.args=='' then call.args='{}' end
    local def=definitions[call.name]
    if not def or forbidden[call.name] then
     local out=outside[call.name]
     value=out and {error='codemode_target_not_available: '..call.name..' runs outside code mode',route=out.route,effect='none'} or {error='codemode_target_not_available'};success=false
    else
     local current
     for _,schema in ipairs(current_catalog())do if schema['function'].name==def.name then current=schema;break end end
     if not current or host.sha256(json.encode(current))~=def.hash then value={error='tool_definition_changed'};success=false
     else
      local _,err=contract.validate(current['function'].parameters,call.args or '{}')
      if err then value={error=err};success=false
      else
       local params=json.decode(call.args or '{}')
       local fenced=action_refusal(def.name,params)
       if fenced then value=fenced;success=false else
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
-- ---------------------------------------------------------------- the component path
--
-- One script, driven step by step. `open` starts the guest, each `advance` delivers the previous
-- answer and hands back one step, `finish` closes the guest and reports what the script did. The steps
-- are the component's decisions; the answers are this loop's, with the same checks the native path
-- makes. Nothing here changes what a script may do: the fence comes back as a `refusal` record, the
-- dispatch is `dispatch`, and the arguments are validated against the schema the node holds now.
local function component_run(policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope)
 local session=host.uuid()
 -- The catalogue as typed records: the node's own pre-flight status per tool is pinned here (the
 -- component decides the fence from it), and the schema hash is kept for the per-call recheck.
 local entries,hashes,selected={},{},{}
 for _,schema in ipairs(catalog)do
  local f=schema['function']
  entries[#entries+1]={name=f.name,description=tostring(f.description or ''),
   schema_json=json.encode(schema),execution=execution(f.name)}
  hashes[f.name]=host.sha256(json.encode(schema))
 end
 local store_key='codemode-store.v1:'..scope
 local raw=memory.meta_get(store_key);local store=raw and json.decode(raw) or {}
 local cache
 do local ok,value=pcall(function()return dofile('lua/core/paths.lua').cache()end);if ok and type(value)=='string' then cache=value..'/codemode' end end
 local opened,open_reason=seam({op='open',session=session,owner=scope,code=args.code,
  timeout_ms=args.timeout_ms or 30000,catalogue=entries,store=store,
  wasm_path=policy.wasm_path,prelude_path=policy.prelude_path,module_cache=cache})
 -- Nothing has run yet: the native path is still a valid answer, and the router logs the reason.
 if not opened then return nil,open_reason end
 if opened.aborted then return {error=tostring(opened.aborted)} end
 if opened.sandbox_failure then
  -- The guest never started. This is the answer the native path gives too: the sandbox's own detail,
  -- the output it managed before it stopped, and the calls it never admitted.
  return {ok=false,error=tostring(opened.sandbox_failure),effect='none',
   items=opened.items or {},unexecuted=opened.unexecuted or {}}
 end
 -- Live from here on: a failure is reported, never replayed.
 local items,calls,attempts={},{},{}
 local function failed(message)
  -- A live script whose component stopped answering: the calls already dispatched may have had
  -- effects, so this is `unknown` and it is never replayed (docs/CODEMODE.md).
  return {ok=false,error=tostring(message),effect='unknown',replay_allowed=false,
   items=items,calls=calls,attempts=attempts,unexecuted={}}
 end
 for _,item in ipairs(opened.items or {})do items[#items+1]=item end
 local reply,loop_error,outcome
 local guard_policy=dofile('lua/core/codemode_policy.lua')
 while not loop_error do
  -- The same two checks the native loop makes before it admits the next call: the run's authority is
  -- rechecked, and a cancelled run stops before another effect.
  local _,context_error=guard_policy.admit(memory,role,ctx)
  if context_error then loop_error=context_error
  elseif host.run_cancelled and json.decode(host.run_cancelled()).cancelled then loop_error='run_cancelled'
  else
   local progress,reason=seam({op='advance',session=session,reply=reply})
   reply=nil
   if not progress then loop_error=reason
   else
    for _,item in ipairs(progress.items or {})do items[#items+1]=item end
    -- The globals this seam answered inside the guest, journaled exactly as the native loop journals
    -- the same call: one attempt per guest call, `target: "global"`, `admitted: false`. The seam hands
    -- the answer as JSON text and it is re-encoded here through the same encoder the native path uses,
    -- so the argument and result references hold the same bytes on both paths (`output.store` hashes
    -- them, and the parity suite compares those hashes).
    for _,answer in ipairs(progress.answered or {})do
     attempts[#attempts+1]={id=answer.id,name=answer.name,target='global',admitted=false,ok=answer.ok==true,
      arguments=output.store(answer.args_json or '{}'),
      result=output.store(json.encode(json.decode(answer.result_json or '{}')))}
    end
    local step=progress.step or {}
    if step.kind=='aborted' then loop_error=tostring(step.reason)
    elseif step.kind=='finished' then outcome=step.outcome;break
    elseif step.kind=='host_global' or step.kind=='call' then
     local value,success,admitted
     local argument_text=step.args_json
     if step.kind=='host_global' then
      local called,params=pcall(global_params,argument_text)
      if not called then error(params) end
      value,success=host_global(step.name,params,calls,selected)
     elseif step.refusal then
      value,success=refusal_value(step.refusal),false
     else
      local current
      for _,schema in ipairs(current_catalog())do if schema['function'].name==step.name then current=schema;break end end
      if not current or host.sha256(json.encode(current))~=hashes[step.name] then
       value,success={error='tool_definition_changed'},false
      else
       local _,err=contract.validate(current['function'].parameters,argument_text or '{}')
       if err then value,success={error=err},false
       else
        local params=json.decode(argument_text or '{}')
        local fenced=action_refusal(step.name,params)
        if fenced then value,success=fenced,false
        else
         local span=telemetry.start(ctx,'tool',{name=step.name,nested=true,codemode_call=step.id,arguments_hash=host.sha256(argument_text or '{}')})
         local called,result=pcall(dispatch,step.name,params,argument_text)
         admitted=true
         if called then value=result;success=type(value)~='table' or (not value.error and value.ok~=false)
         else value,success={error=tostring(result),effect='unknown',replay_allowed=false},false end
         local encoded=json.encode(value);local reference=output.store(encoded)
         calls[#calls+1]={id=step.id,name=step.name,ok=success,evidence=reference}
         telemetry.finish(span,{ok=success,name=step.name,nested=true,codemode_call=step.id,result_bytes=#encoded,result_hash=host.sha256(encoded)})
        end
       end
      end
     end
     attempts[#attempts+1]={id=step.id,name=step.name,
      target=(step.kind=='host_global' and 'global') or step.target or 'tool',admitted=admitted or false,
      ok=success,arguments=output.store(argument_text or '{}'),result=output.store(json.encode(value))}
     reply={call_id=step.id,ok=success and true or false,payload_json=json.encode(value)}
    else loop_error='codemode_protocol_unknown_step'
    end
   end
  end
 end
 local report,finish_reason=seam({op='finish',session=session})
 if not report then return failed(finish_reason or 'component_finish_failed') end
 if report.close_failure then
  return {ok=false,error='codemode_close_failed',detail=report.close_failure,items=items,calls=calls,attempts=attempts}
 end
 loop_error=loop_error or report.aborted
 for _,item in ipairs(report.items or {})do items[#items+1]=item end
 outcome=outcome or report.outcome
 -- The session store is the core's: the component hands over the entries, this writes the row.
 if not loop_error and outcome and outcome.ok==true then
  for _,entry in ipairs(outcome.writes or {})do
   if type(entry)=='table' and type(entry[1])=='string' then
    if entry[2]==nil then store[entry[1]]=nil else store[entry[1]]=tostring(entry[2]) end
   else loop_error='codemode_store_protocol_invalid' end
  end
  if not loop_error then memory.meta_set(store_key,json.encode(store)) end
 end
 local result={ok=(not loop_error) and outcome and outcome.ok==true or false,
  error=loop_error or (outcome and not outcome.ok and outcome.error) or nil,
  items=items,value=outcome and outcome.value,calls=calls,attempts=attempts,
  unexecuted=report.unexecuted or {},backend=opened.backend or 'rust-wasip2-wa:codemode',
  sandbox_calls=report.sandbox_calls,
  context_policy='only script output is model-facing; complete nested originals are retained by hash'}
 local presented,view=pcall(presentation.finish,result,selected)
 if presented then return view end
 result.ok=false;result.presentation_partial=true;result.presentation_error=tostring(view)
 result.shown=nil
 return result
end

-- The router: the run's authority, its scope and its workspace are decided once, then one of the two
-- loops runs. A component that cannot answer *before the first step* falls back; after that it is a
-- failure with `effect: unknown`, because the calls it already handed out may have had effects.
function M.run(memory,args,role,ctx,catalog,current_catalog,dispatch,execution)
 local policy,refusal=dofile('lua/core/codemode_policy.lua').admit(memory,role,ctx)
 if not policy then return {ok=false,error=refusal,calls={},attempts={}} end
 if type(args.code)~='string' or args.code=='' then return {error='codemode_source_required'} end
 local workspace=memory.session_workspace and memory.session_workspace(ctx.session_id) or nil
 local scope=host.sha256(json.encode({session=ctx.session_id,user=ctx.user_id,role=role,workspace=workspace,profile=ctx.subagent and ctx.subagent.allowed or nil}))
 if seam_component() then
  local called,result,reason=pcall(component_run,policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope)
  -- A table is the component's answer (including its refusals and its sandbox failures). `nil, reason`
  -- means it could not answer *before a step was handed out*: only then is the native path run.
  if called and type(result)=='table' then return result end
  if not called then note_fallback('run',tostring(result))
  else note_fallback('run',tostring(reason or 'component_no_answer')) end
 end
 return native_run(policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope)
end
return M
