-- Pi1.2-compatible guest protocol over Node-free host.quickjs. Agent/tool policy
-- stays here and in the native dispatcher; JS never receives host capabilities.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local output=dofile('lua/core/tool_output.lua')
local telemetry=dofile('lua/core/telemetry.lua')
local presentation=dofile('lua/core/codemode_view.lua')
-- The ergonomics layer the model's script is wrapped in (natural promises, explicit reuse) and the
-- per-scope journal that `results`/`{reuse}`/`prior` read. Both are this node's own code, so both
-- are testable from this tree (`scripts/test-codemode-promises.lua`, `scripts/test-codemode-reuse.lua`).
local harness=dofile('lua/core/codemode_harness.lua')
local session_results=dofile('lua/core/codemode_results.lua')
-- One pending-call handle for every call (docs/CODEMODE.md, "Pending calls"): a call still running
-- after its wait answers {state:"pending", op}, and `wait(op)`/`cancel(op)` resume or stop it. Built
-- on the managed operations the node already supervises - this file only names which tool call an
-- operation is (`lua/core/codemode_pending.lua`).
local pending_calls=dofile('lua/core/codemode_pending.lua')
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
-- Direct-call-only (operator's decision, 11/11): the effect stays one reviewable call with a receipt
-- outside the script, and each entry carries the reason it is not a script step. Everything NOT in this
-- table is callable inside code mode with exactly the per-call permission, effect, workspace and
-- binding checks an ordinary call gets - the fence is this table, never a second policy. A tool that
-- outside would refuse (binding, role, managed capability, operator gate) refuses inside with the same
-- text, because it reaches the same dispatcher.
local DIRECT_ONLY={
 codemode='a script does not nest: a second sandbox inside the first would hide one effect stream behind another',
 tool_call='the outer facade pins definitions into this session\'s loadout; a script calls await tools.<name>(args) directly instead',
 tool_search='the outer facade pins definitions into this session\'s loadout; searchTools answers the same question inside without changing it',
 subagent='delegation spends model calls and creates a child session: one reviewable call, never a step inside a script',
 integrate='landing a worker tip is a single receipted integration action, never a script step',
 session_worktree='it allocates and owns this session\'s worktree; a bound root that re-points mid-script would change what every later call means',
 resume_session='it folds another session into the conversation the script is already running in',
 session_debug='it sets this session\'s recording mode: changing what is recorded mid-script makes the script its own unrecorded effect',
 session_fixture='it exports this session as a fixture while the script is still writing that session',
 wave_autoflush='it installs a durable wave-end obligation for the coordinator; installation is a direct receipted action',
 node_update='it updates and restarts a node: a deployment, not a script step',
 -- `mcp_whatsapp_send` is NOT here (11/12): it is one callable tool with two shapes, and both belong
 -- inside a script - the send form is an effect the dispatcher runs one at a time (operator decision,
 -- 11/11: several sends stay serialized), and the resume form waits on a job and is classified a read
 -- (`lua/core/whatsapp.lua`, `M.effect`), so a script can queue three sends with wait_s:0 and collect
 -- them with ONE `{ids}` resume.
 email_send='an outbound message is one operator-gated effect with a durable message id and a documented status; it stays a direct call',
}
local forbidden={}
for name in pairs(DIRECT_ONLY)do forbidden[name]=true end
M.DIRECT_ONLY=DIRECT_ONLY
-- What a tool that is not callable here is for, so discovery never reads as "does not exist" (29/10).
-- A retired batch name (`read_many`, `edit_many`, ...) is answered with the same one sentence outside
-- and inside a script, so `describeTool('read_many')` teaches the form instead of leaving a script to
-- guess from the nearest-name suggestions. One table, in `lua/core/retired.lua`, shared with the
-- dispatcher and `tool_call`.
local retired_lib=dofile('lua/core/retired.lua')
local function retired_text(name) return retired_lib.text(name) end
local function route_of(name,status)
 if DIRECT_ONLY[name] then return 'Direct call only: '..DIRECT_ONLY[name]..'. End the script, then call '..name..' as an ordinary tool.' end
 if name=='tool_search' or name=='tool_call' then return 'Outer facade: inside a script use searchTools and call await tools.<name>(args) directly.' end
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

-- The view's row for one nested call (`lua/core/codemode_block.lua`): it appears as `⏳` when the call
-- starts and its own row is rewritten to `✓`/`✗` when it settles, inside the block the CLI opened
-- for this script. A caller with no view (a run, a peer, a subagent, a test) has no `emit`, so this is
-- one nil check - and nothing on the result path reads it, which is why the model-facing result is
-- the same bytes whether a reader is watching or not.
local function live(ctx, event)
  local emit = type(ctx) == 'table' and ctx.emit or nil
  if type(emit) ~= 'function' then return end
  pcall(emit, event)
end

-- What a settled nested call says: its state, how long it took, and the error code the row shows in
-- red (`web_http_429`, not "failed"). `{state:"pending", op}` is its own state - a call that
-- outlived its wait is not a failure and not a success.
local function live_settled(ctx, id, name, result, called, started)
  local r = type(result) == 'table' and result or nil
  local state = 'ok'
  if not called or (r and (r.error or r.ok == false)) then state = 'failed' end
  if r and r.state == 'pending' then state = 'pending' end
  live(ctx, { type = 'codemode_call', id = id, name = name, state = state,
    ms = math.floor(((tonumber(host.now()) or started) - started) * 1000),
    error = r and r.error or nil, code = r and (r.code or r.error) or nil, op = r and r.op or nil })
end

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
local function host_global(name, params, calls, selected, lookup, ctx, journal, popts)
  if name == 'showCall' then return presentation.select(calls, selected, params) end
  -- `wait(op|[ops], {wait_s, until})` and `cancel(op|[ops])`: the one resume and the one stop for a
  -- call that answered a handle. A READ and an effect-stopper, both over managed operations, both
  -- answered by the same module for this loop and the component's.
  if name == 'wait' or name == 'cancel' or name == 'pending' then
    if not popts then return { error = 'codemode_global_not_available' }, false end
    local asked = type(params) == 'table' and params[1] or nil
    local value
    if name == 'wait' then
      value = pending_calls.wait(popts.dispatch, popts, asked, type(params) == 'table' and params[2] or nil)
    elseif name == 'pending' then
      -- The whole pool this scope holds: a read, so a later step or turn needs no memory of handles.
      value = pending_calls.list(popts.dispatch, popts)
    else
      value = pending_calls.cancel(popts.dispatch, popts, asked)
    end
    if type(value) ~= 'table' then return { error = 'codemode_global_not_available' }, false end
    return value, value.error == nil
  end
  -- `describeTool(name)` is the hidden alias of `searchTools("select:"..name)[0]`, and `searchTools`
  -- itself is answered here as well when the component hands a call back: one implementation of every
  -- discovery form (`tool_lookup`) for both loops, so the two paths cannot answer differently.
  if name == 'describeTool' then
    local asked = type(params) == 'string' and params or (type(params) == 'table' and params[1]) or nil
    return lookup.describe(asked), true
  end
  if name == 'searchTools' then return lookup.discover(params) end
  -- `capabilities()` inside is the tool grant list: the same object the outer `capabilities` tool
  -- returns, and it is answered by dispatching that tool. It used to return the host inventory
  -- (`wa capabilities --json`: audio, disk, http), which is a different question under the same name
  -- (measured 11/11). `describe()` keeps the inventory.
  if name == 'capabilities' then return lookup.capabilities(params), true end
  if name == 'results' then return session_results.answer(type(params) == 'table' and params[1] or nil, ctx, journal) end
  local value, success = inventory.global(name, params)
  if value == nil then return { error = 'codemode_global_not_available' }, false end
  return value, success
end

-- The guest's own names - `searchTools`, `results`, `showCall` - are discovery entries like any other,
-- and their help is both the entry's `schema` and the entry's own fields (name, description,
-- parameters, code). That keeps `searchTools("select:showCall")[0]` and the compatibility alias
-- `describeTool("showCall")` the same object, and keeps the help text in one place.
local function builtin_entries()
 local entries={}
 local function add(help)
  local entry={}
  for key,value in pairs(help)do entry[key]=value end
  entry.schema=help
  entry.execution={status='available',scope='codemode',workspace_binding='none'}
  entry.callable=true
  entry.builtin=true
  entries[#entries+1]=entry
 end
 add(presentation.searchtools_help)
 add(session_results.HELP)
 add(pending_calls.WAIT_HELP)
 add(pending_calls.PENDING_HELP)
 add(pending_calls.CANCEL_HELP)
 add(presentation.help)
 table.sort(entries,function(a,b)return a.name<b.name end)
 return entries
end

-- One lookup for both seams: the definition a name has - callable, or fenced with the route that says
-- where it runs - or a `found:false` entry that says the name is not here. `capabilities()` is the
-- outer `capabilities` tool dispatched, so the two views of the grant list cannot drift.
--
-- It is also the ONE implementation of discovery: a batch entry, a keyword match, a listing row and
-- `describeTool(name)` are all `entry(name)`, so the one tool cannot answer four shapes. The operator's
-- decision (11/11): `searchTools` always answers an ARRAY; `describeTool` stays only as a hidden
-- compatibility alias for element 0 of a one-name batch.
local function tool_lookup(catalog,execution,dispatch)
 local builtins=builtin_entries()
 local function copy(value) local out={} for key,item in pairs(value)do out[key]=item end return out end
 local function names()
  local list={}
  for _,schema in ipairs(catalog)do list[#list+1]=schema['function'].name end
  for _,builtin in ipairs(builtins)do list[#list+1]=builtin.name end
  table.sort(list)
  return list
 end
 local function unknown(name,list)
  local echo=envelope.echo_name(tostring(name))
  local set={}for _,known in ipairs(list or names())do set[known]=true end
  return {name=echo,found=false,missing=true,error='unknown_tool',
   reason="no name like '"..echo.."' in this script's catalogue",
   suggestions=envelope.nearest(echo,set,3),retired=retired_text(echo)}
 end
 -- One name, one object: {name, description, parameters, schema, execution, callable, route} - the
 -- shape `describeTool(name)` has always answered, plus the `schema` a batch entry carries. A name the
 -- script cannot see is a MEMBER of the answer (found:false, the reason, the nearest permitted names),
 -- never a throw and never a second envelope, so `.map` works on every form.
 local function entry(name,list)
  local wanted=tostring(name)
  for _,schema in ipairs(catalog)do
   local f=schema['function']
   if f.name==wanted then
    local status=execution(f.name)
    local fenced=forbidden[f.name] or status.status=='blocked' or status.status=='unknown'
    local out={name=f.name,description=tostring(f.description or ''),parameters=f.parameters,
      schema=schema,execution=status,callable=not fenced}
    if fenced then out.route=route_of(f.name,status) end
    return out
   end
  end
  for _,builtin in ipairs(builtins)do if builtin.name==wanted then return copy(builtin) end end
  return unknown(wanted,list)
 end
 -- `searchTools(args)`: the batch (`{names}`/`"select:a,b"`), the listing (`"*"`, `""` or nothing) and
 -- the keyword form, in that order - the same branches as the outer `tool_search`, over the guest's own
 -- ceiling. Every branch answers a plain ARRAY.
 local function discover(params)
  params=type(params)=='table' and params or {}
  local query=params[1];local options=params[2]
  if type(query)=='table' then options=query;query=options.query end
  options=type(options)=='table' and options or {}
  local wanted,batch_error=envelope.requested_names({query=query,names=options.names})
  local list=names()
  local listing=not wanted and (query==nil or query=='*' or (type(query)=='string' and not query:find('%S')))
  local limit=options.limit or (listing and 50 or 8)
  local offset=options.offset or 0
  if batch_error then return {error=batch_error},false end
  if wanted then
   if options.limit~=nil and (type(options.limit)~='number' or options.limit%1~=0 or options.limit<1 or options.limit>8) then
    return {error='invalid_tool_search_limit'},false
   end
   local tools={}
   for _,name in ipairs(wanted)do tools[#tools+1]=entry(name,list) end
   return tools,true
  end
  if listing then
   if type(limit)~='number' or limit%1~=0 or limit<1 or limit>200 or type(offset)~='number' or offset%1~=0 or offset<0 then
    return {error='invalid_tool_search_limit'},false
   end
   local page={}
   for index=offset+1,math.min(#list,offset+limit)do
    local found=entry(list[index],list)
    page[#page+1]={name=found.name,description=tostring(found.description or ''):match('^[^\n]*'):sub(1,200),
      execution=found.execution,callable=found.callable}
    if found.route then page[#page].route=found.route end
   end
   return page,true
  end
  if type(query)~='string' or #query>256 then return {error='tool_search_query_required'},false end
  if type(limit)~='number' or limit%1~=0 or limit<1 or limit>8 then return {error='invalid_tool_search_limit'},false end
  local matches={}
  for _,name in ipairs(list)do
   local found=entry(name,list)
   local hay=(found.name..' '..tostring(found.description or '')):lower()
   local score=0
   for term in query:lower():gmatch('[%w_]+')do if hay:find(term,1,true)then score=score+1 end end
   if score>0 then found.score=score;matches[#matches+1]=found end
  end
  table.sort(matches,function(a,b)return a.score==b.score and a.name<b.name or a.score>b.score end)
  local found={}
  for index=1,math.min(limit,#matches)do found[index]=matches[index];found[index].score=nil end
  return found,true
 end
 -- `describeTool(name)` - the hidden compatibility alias
 -- (`searchTools("select:"..name)[0]`, same object): a script written against the old one name keeps
 -- working, and no catalogue or guidance list offers it any more. No argument is the presentation help
 -- it has always answered.
 return {describe=function(name) return entry(name==nil and 'showCall' or name) end,discover=discover,
  codemode_only=function(name) return codemode_only(name,{}) end,
  capabilities=function(params)
   local ok,value=pcall(dispatch,'capabilities',type(params)=='table' and params or {})
   if ok and type(value)=='table' then return value end
   return {error='capabilities_unavailable',effect='none'}
  end}
end

-- The native path: byte for byte the loop this file has always run. `workspace` and `scope` are the
-- run's, computed once by `M.run` so both paths agree on them.
local function native_run(policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope,popts)
 local descriptors,definitions,outside={},{},{}
 for _,schema in ipairs(catalog)do
  local f=schema['function'];local status=execution(f.name);local js=f.name:gsub('[^%w_]','_')
  local fenced=forbidden[f.name] or status.status=='blocked' or status.status=='unknown'
  if fenced then
   outside[f.name]={name=f.name,schema=schema,route=route_of(f.name,status)}
  else
   if definitions[js] and definitions[js].name~=f.name then return {error='codemode_identifier_collision'} end
   definitions[f.name]={name=f.name,schema=schema,hash=host.sha256(json.encode(schema))}
   definitions[js]=definitions[f.name]
  end
  -- Every name the model can see outside is a member inside, so *reading* one is never a TypeError
  -- that reads as "does not exist" (11/11: `typeof tools.capabilities` killed a startup script and
  -- sent it hunting for a capability it already had). A fenced member answers with its route - the
  -- same refusal a call to it already got. `searchTools` still marks it callable:false.
  descriptors[#descriptors+1]={name=f.name,jsName=js,description=tostring(f.description or ''),outside=fenced}
 end
 -- One lookup for both paths: the definition a name has, callable or fenced-with-route, or the
 -- nearest permitted names when there is none.
 local lookup=tool_lookup(catalog,execution,dispatch)
 local globals={{name='searchTools',spread=true},{name='results',spread=true},
  -- A call that outlives its wait answers {state:"pending", op}; these two are how a script resumes
  -- or stops it. Both are registered with `spread` so `wait(op, {wait_s:120})` arrives with both
  -- arguments (`lua/core/codemode_pending.lua`).
  {name='wait',spread=true},{name='cancel',spread=true},{name='pending',spread=true},
  {name='describeTool',spread=false},{name='showCall',spread=false},
  -- Introspection of what this node can do, for a workflow that would otherwise guess. They read
  -- the host capability registry and nothing else: no authority moves, no effect is admitted.
  {name='capabilities',spread=false},{name='describe',spread=false}}
 local selected={}
 -- One journal per script, loaded from the scope's own metadata and written back once the script is
 -- over - success or failure, because a call that *ran* is what `prior`/`{reuse}` ask about later.
 local journal=session_results.load(memory,scope)
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
     -- One implementation, shared with the component path (`tool_lookup`): the batch, the listing and
     -- the keyword form all answer a plain ARRAY here, so `.map` works on whatever was asked for.
     value,success=lookup.discover(params)
    elseif call.name=='describeTool' then
     -- The hidden compatibility alias of `searchTools("select:"..name)[0]`, same object.
     local name=type(params)=='string' and params or (type(params)=='table' and params[1]) or nil
     value=lookup.describe(name);success=true
    elseif call.name=='results' then
     -- The retained results and this session's journal: `results.get`/`last`/`diff`/`reuse`. Read-only
     -- over records the node already keeps; it dispatches nothing and admits nothing.
     value,success=session_results.answer(type(params)=='table' and params[1] or nil,ctx,journal)
    elseif call.name=='wait' or call.name=='cancel' or call.name=='pending' then
     -- The one resume and the one stop, answered by the same module the component's loop answers them
     -- through (`host_global` above): a pending call is a managed operation, and reading it takes no
     -- lock, so a wait never blocks the script that asked.
     value,success=host_global(call.name,params,calls,selected,lookup,ctx,journal,popts)
    elseif call.name=='capabilities' then
     value,success=lookup.capabilities(params),true
    elseif call.name=='describe' then
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
      -- `wait_s` on any call: taken out of the arguments before the tool's own schema sees them,
      -- because it is a property of this call's *wait* and not an argument of the tool. A call that
      -- names none keeps its original text and its original answer.
      local stripped,wait_s,wait_error=pending_calls.strip(call.args)
      if wait_error then value={error=wait_error,effect='none'};success=false
      else
      local _,err=contract.validate(current['function'].parameters,stripped or '{}')
      if err then value={error=err};success=false
      else
       local params=json.decode(stripped or '{}')
       local fenced=action_refusal(def.name,params)
       if fenced then value=fenced;success=false else
       local span=telemetry.start(ctx,'tool',{name=def.name,nested=true,codemode_call=call.id,arguments_hash=host.sha256(call.args or '{}')})
       live(ctx,{type='codemode_call',id=call.id,name=def.name,arguments=params,state='running'})
       local live_started=tonumber(host.now()) or 0
       local called,result=pcall(pending_calls.invoke,dispatch,popts,def.name,params,stripped,wait_s);admitted=true
       live_settled(ctx,call.id,def.name,result,called,live_started)
       if called then
        value=result;success=type(value)~='table' or (not value.error and value.ok~=false)
        -- Journaled before it is encoded: a fresh read-only call that repeats an identical earlier one
        -- comes back with `prior:{call, age_s, same}`, and the repeat is counted in telemetry.
        value=session_results.record(ctx,journal,{id=call.id,tool=def.name,args=host.sha256(call.args or '{}'),
         args_value=params,result=host.sha256(json.encode(value)),ok=success},value)
        success=type(value)~='table' or (not value.error and value.ok~=false)
       else value={error=tostring(result),effect='unknown',replay_allowed=false};success=false end
       local encoded=json.encode(value);local reference=output.store(encoded)
       calls[#calls+1]={id=call.id,name=def.name,ok=success,evidence=reference}
       telemetry.finish(span,{ok=success,name=def.name,nested=true,codemode_call=call.id,result_bytes=#encoded,result_hash=host.sha256(encoded)})
       end
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
 session_results.save(memory,scope,journal)
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
local function component_run(policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope,popts)
 local session=host.uuid()
 -- The lookup the globals this loop owns are answered through, exactly as the native loop builds it:
 -- `capabilities()`, a `searchTools` call the seam hands back, and `describeTool` all dispatch through
 -- here, so the two paths answer one implementation.
 local lookup=tool_lookup(catalog,execution,dispatch)
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
 -- The guest's own names travel as discovery entries, composed HERE and copied verbatim by the seam:
 -- the help text (`searchTools`, `results`, `showCall`) has one copy, and the component's batch,
 -- listing, keyword and alias answers are the node's bytes, not a second rendering of them.
 local builtins={}
 for _,entry in ipairs(builtin_entries())do
  builtins[#builtins+1]={name=entry.name,description=tostring(entry.description or ''),
   execution=entry.execution,entry_json=json.encode(entry)}
 end
 local opened,open_reason=seam({op='open',session=session,owner=scope,code=args.code,
  timeout_ms=args.timeout_ms or 30000,catalogue=entries,builtins=builtins,store=store,
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
 -- The same journal the native loop keeps, for the same scope: `prior`/`{reuse}`/`results` answer
 -- identically whichever loop drove the script (scripts/test-codemode-parity.lua compares the two).
 local journal=session_results.load(memory,scope)
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
      value,success=host_global(step.name,params,calls,selected,lookup,ctx,journal,popts)
     elseif step.refusal then
      value,success=refusal_value(step.refusal),false
     else
      local current
      for _,schema in ipairs(current_catalog())do if schema['function'].name==step.name then current=schema;break end end
      if not current or host.sha256(json.encode(current))~=hashes[step.name] then
       value,success={error='tool_definition_changed'},false
      else
       local stripped,wait_s,wait_error=pending_calls.strip(argument_text)
       if wait_error then value,success={error=wait_error,effect='none'},false
       else
       local _,err=contract.validate(current['function'].parameters,stripped or '{}')
       if err then value,success={error=err},false
       else
        local params=json.decode(stripped or '{}')
        local fenced=action_refusal(step.name,params)
        if fenced then value,success=fenced,false
        else
         local span=telemetry.start(ctx,'tool',{name=step.name,nested=true,codemode_call=step.id,arguments_hash=host.sha256(argument_text or '{}')})
         live(ctx,{type='codemode_call',id=step.id,name=step.name,arguments=params,state='running'})
         local live_started=tonumber(host.now()) or 0
         local called,result=pcall(pending_calls.invoke,dispatch,popts,step.name,params,stripped,wait_s)
         admitted=true
         live_settled(ctx,step.id,step.name,result,called,live_started)
         if called then value=result;success=type(value)~='table' or (not value.error and value.ok~=false)
          value=session_results.record(ctx,journal,{id=step.id,tool=step.name,args=host.sha256(argument_text or '{}'),
           args_value=params,result=host.sha256(json.encode(value)),ok=success},value)
          success=type(value)~='table' or (not value.error and value.ok~=false)
         else value,success={error=tostring(result),effect='unknown',replay_allowed=false},false end
         local encoded=json.encode(value);local reference=output.store(encoded)
         calls[#calls+1]={id=step.id,name=step.name,ok=success,evidence=reference}
         telemetry.finish(span,{ok=success,name=step.name,nested=true,codemode_call=step.id,result_bytes=#encoded,result_hash=host.sha256(encoded)})
        end
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
 session_results.save(memory,scope,journal)
 local presented,view=pcall(presentation.finish,result,selected)
 if presented then return view end
 result.ok=false;result.presentation_partial=true;result.presentation_error=tostring(view)
 result.shown=nil
 return result
end

-- The router: the run's authority, its scope and its workspace are decided once, then one of the two
-- loops runs. A component that cannot answer *before the first step* falls back; after that it is a
-- failure with `effect: unknown`, because the calls it already handed out may have had effects.
local function run_script(memory,args,role,ctx,catalog,current_catalog,dispatch,execution)
 local policy,refusal=dofile('lua/core/codemode_policy.lua').admit(memory,role,ctx)
 if not policy then return {ok=false,error=refusal,calls={},attempts={}} end
 if type(args.code)~='string' or args.code=='' then return {error='codemode_source_required'} end
 -- The model's source is wrapped in this node's ergonomics layer before either loop sees it: the
 -- harness is prepended and appended as TEXT, so it reaches the native guest and the component's guest
 -- alike, and the script's own line 1 is line 2 of what the interpreter compiles
 -- (lua/core/codemode_harness.lua). A copy, so the decorated source never becomes the tool's args.
 args={code=harness.decorate(args.code),timeout_ms=args.timeout_ms}
 local workspace=memory.session_workspace and memory.session_workspace(ctx.session_id) or nil
 local scope=host.sha256(json.encode({session=ctx.session_id,user=ctx.user_id,role=role,workspace=workspace,profile=ctx.subagent and ctx.subagent.allowed or nil}))
 -- One handle table for this script, on either loop: a call that outlives its wait answers
 -- {state:"pending", op}, `wait(op)`/`cancel(op)` answer it, and every wait is bounded by what is
 -- left of the script (a wait never outlives the script that started it).
 local started_at=host.now()
 local popts={ctx=ctx,scope=scope,session=ctx.session_id,dispatch=dispatch}
 local budget=tonumber(args.timeout_ms) or 30000
 popts.remaining_ms=budget
 popts.remaining=function() return budget-math.floor(((tonumber(host.now()) or started_at)-started_at)*1000) end
 -- Handles outlive the script, so an operation that finished while nobody waited is settled here
 -- (a status read each, never a wait) and reported once, on the next script of this scope.
 pending_calls.begin(dispatch,popts)
 local function finish(result)
  if type(result)~='table' then return result end
  local settled=pending_calls.announce(scope)
  if settled then result.pending_settled=settled end
  return result
 end
 if seam_component() then
  local called,result,reason=pcall(component_run,policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope,popts)
  -- A table is the component's answer (including its refusals and its sandbox failures). `nil, reason`
  -- means it could not answer *before a step was handed out*: only then is the native path run.
  if called and type(result)=='table' then return finish(result) end
  if not called then note_fallback('run',tostring(result))
  else note_fallback('run',tostring(reason or 'component_no_answer')) end
 end
 return finish(native_run(policy,memory,args,role,ctx,catalog,current_catalog,dispatch,execution,workspace,scope,popts))
end
-- The script's own clock, stamped where the sandbox's own `timeout_ms` is decided, so both ends of a
-- script agree on when it ends. One nested effect reads it today: a WhatsApp send waits for the answer
-- only until this deadline minus a margin (`lua/core/whatsapp.lua`, `M.wait_budget`), because the
-- sandbox refuses an admission after the same instant - a wait that spent it would turn a queued message
-- into a dead script, the one outcome worse than `pending`. Restored afterwards, so a ctx shared by
-- later calls carries no stale deadline.
function M.run(memory,args,role,ctx,catalog,current_catalog,dispatch,execution)
  local budget_ms=tonumber(args and args.timeout_ms) or 30000
  budget_ms=math.max(1,math.min(300000,budget_ms))
  local previous=type(ctx)=='table' and ctx.codemode_deadline or nil
  if type(ctx)=='table' then
    ctx.codemode_deadline=(tonumber(host.now()) or 0)+budget_ms/1000
  end
  local ok,answer=pcall(run_script,memory,args,role,ctx,catalog,current_catalog,dispatch,execution)
  if type(ctx)=='table' then ctx.codemode_deadline=previous end
  if not ok then error(answer,0) end
  return answer
end

return M
