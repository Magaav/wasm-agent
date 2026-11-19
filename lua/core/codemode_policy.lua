-- Trusted run context only. No task classifier and no authority derived from JS.
local json=dofile('lua/vendor/json.lua')
local users=dofile('lua/core/users.lua')
local M={}
function M.setting()
 local value=host.getenv('WASM_AGENT_CODEMODE') or ''
 -- Code mode is the default of every node, not an opt-in. Unset used to mean the fenced 'default'
 -- mode, which required an allocated session worktree and therefore stayed invisible in every
 -- ordinary run: the capability existed, nothing advertised it, and it read as "code mode only
 -- works inside code mode" (measured 2026-10-27). Unset now means native; an operator who wants
 -- the worktree fence back asks for it by name.
 if value=='' then return 'native' end
 if value~='native' and value~='off' and value~='default' then error('invalid_codemode_setting:'..value) end
 return value
end
function M.eligible(memory,role,ctx,mode)
 if not users.is_master(role) then return false end
 if ctx.subagent then
  local child=ctx.subagent;local allowed=child.allowed or {}
  -- Explicit wrapper authorization never grants a missing primitive or delegation.
  if not allowed.codemode or not allowed.read or not allowed.write or not allowed.edit or not allowed.bash then return false end
  if child.id~='orchestration-worker' then return false end
 end
 if mode=='native' then return true end -- historical MASTER opt-in, still native-fenced
 if not memory or not ctx.session_id or not memory.session_worktree then return false end
 local path=memory.session_worktree(ctx.session_id)
 if type(path)~='string' or path=='' then return false end
 local workspace=memory.session_workspace and memory.session_workspace(ctx.session_id)
 return not workspace or not workspace.required or workspace.state=='allocated' and workspace.worktree==path
end
function M.pin(memory,role,ctx)
 ctx=ctx or {}
 if ctx.codemode_policy then return ctx.codemode_policy end
 local mode=M.setting();local policy={mode=mode,enabled=false}
 -- Code mode is a capability of the node, not a property of the turn. When the node cannot honour it, the
 -- honest outcome is ordinary tools plus a visible reason, not a fatal error before the first model call:
 -- that error left the conversation silent while the operator saw a finished run (measured 2026-10-22).
 local function unavailable(reason)
  policy.unavailable=tostring(reason);ctx.codemode_policy=policy;return policy
 end
 if mode=='off' or not M.eligible(memory,role,ctx,mode) then ctx.codemode_policy=policy;return policy end
 if not host.quickjs then return unavailable('native_host_unavailable') end
 local assets=host.getenv('WASM_AGENT_CODEMODE_ASSETS')
 if assets and assets~='' then policy.wasm_path=assets..'/quickjs.wasm';policy.prelude_path=assets..'/prelude.js' end
 local called,ready=pcall(host.quickjs,'ready',json.encode(policy))
 if not called then return unavailable('readiness_error: '..tostring(ready)) end
 local decoded_ok,decoded=pcall(json.decode,ready)
 if not decoded_ok or type(decoded)~='table' then return unavailable('readiness_malformed') end
 if not decoded.ok then return unavailable(decoded.error or 'readiness_refused') end
 policy.enabled=true;policy.backend=decoded.backend;ctx.codemode_policy=policy
 return policy
end
function M.admit(memory,role,ctx)
 local p=M.pin(memory,role,ctx)
 if not p.enabled then return nil,'codemode_not_enabled' end
 -- A pin preserves configuration, not authority: role/profile/workspace still recheck.
 if not M.eligible(memory,role,ctx,p.mode) then return nil,'codemode_context_changed' end
 return p
end
-- Connector tools - every MCP server (mail, the WhatsApp linked device, ...) and every peer's
-- connectors - run only inside code mode when the run has it. Their results are large, paged and
-- usually filtered before they are worth reading, which is exactly what a script does; offering them
-- on two routes left an empty-context model choosing between them and missing both (29/10).
function M.connector(name)
 return type(name)=='string' and (name:sub(1,4)=='mcp_' or name:sub(1,5)=='peer_')
end
function M.enforced(ctx)
 local p=ctx and ctx.codemode_policy
 return type(p)=='table' and p.enabled==true
end
function M.js_name(name) return (tostring(name):gsub('[^%w_]','_')) end
-- The script a direct call stands for: `return await tools.<name>(<args>)`. An empty table is {} (the
-- vendor encoder would write [] for it).
function M.one_line(name,args)
 local json=dofile('lua/vendor/json.lua')
 local body=(type(args)=='table' and next(args)~=nil) and json.encode(args) or '{}'
 return 'return await tools.'..M.js_name(name)..'('..body..')'
end
function M.connector_refusal(name)
 return {error='codemode_only: '..tostring(name)..' is a connector tool; call it inside codemode: const r = await tools.'..M.js_name(name)..'({...}); return r',effect='none'}
end
-- One compact line per connector: what the model needs to route a request such as "look at
-- WhatsApp" or "check my mail" to code mode from an empty context, without the schemas.
--
-- The names printed are the CALLABLE names, verbatim (`peer_openclaw__mcp_whatsapp_native_read_newest_...`),
-- not a shortened form: a peer tool's prefix says where it runs and its suffix is a pinned hash, so any
-- abbreviation is a name the model must then hunt for (session 10/11: "mcp_whatsapp_*" cost six calls of
-- guessing before the real names were dumped). The group label stays, the name is exact.
-- A connector's call shape on one line: `name({required, optional?})`, at most eight arguments (14/11 replay:
-- every first WhatsApp/email call was preceded by a schema lookup, because the index gave names only).
local function signature(f)
 local p=type(f.parameters)=='table' and f.parameters or {}
 local props=type(p.properties)=='table' and p.properties or {}
 local required={};for _,k in ipairs(type(p.required)=='table' and p.required or {})do required[k]=true end
 local req,opt={},{}
 for k in pairs(props)do if required[k] then req[#req+1]=k else opt[#opt+1]=k..'?' end end
 -- The arguments a first call needs come first (14/11: alphabetical order hid send's chat and text behind
 -- cancel/draft/id), then the rest alphabetically; at most eight.
 local FIRST={chat=1,text=2,q=3,query=4,account_id=5,mailbox=6,message_id=7,path=8,command=9,limit=10,id=11}
 local function rank(a,b) local x,y=FIRST[a:gsub('%?$','')] or 99,FIRST[b:gsub('%?$','')] or 99; if x~=y then return x<y end return a<b end
 table.sort(req,rank);table.sort(opt,rank)
 local all={};for _,k in ipairs(req)do all[#all+1]=k end;for _,k in ipairs(opt)do all[#all+1]=k end
 local shown=table.concat(all,', ',1,math.min(#all,8))
 if #all>8 then shown=shown..', ...' end
 return f.name..'({'..shown..'})'
end
-- The name a connector is listed under: its stem when the stem names exactly one catalogue tool (15/11:
-- a model that saw `..._828ac338` copied the ews tool's hash onto the imap one). The stem is callable
-- as is - `tools.<stem>`, `select:<stem>` and a direct call all resolve a unique stem - so the index
-- shows the shorter name and there is no hash left to copy. Two tools with one stem keep their full names.
local HASH='_%x%x%x%x%x%x%x%x$'
local function listed_names(catalog)
 local count,full={},{}
 for _,item in ipairs(catalog or {})do
  local name=(item['function'] or {}).name
  if type(name)=='string' then
   full[name]=true
   local base=name:match('^(.-)'..HASH)
   if base and base~='' then count[base]=(count[base] or 0)+1 end
  end
 end
 -- A stem that is one of our own WhatsApp names (or a renamed/retired one) is routed to that surface
 -- before any connector, so such a connector keeps its full name.
 local ok,wa=pcall(dofile,'lua/core/whatsapp.lua');if not ok or type(wa)~='table' then wa={} end
 local function ours(base)
  for _,k in ipairs({'tool','renamed','retired_name'})do
   if type(wa[k])=='function' then local hit_ok,hit=pcall(wa[k],base);if hit_ok and hit then return true end end
  end
  return false
 end
 return function(name)
  local base=name:match('^(.-)'..HASH)
  if base and base~='' and count[base]==1 and not full[base] and not ours(base) then return base end
  return name
 end
end
M.listed_name=function(catalog,name) return listed_names(catalog)(name) end
function M.connector_index(catalog)
 local groups,order={},{}
 local sigs={}
 local listed=listed_names(catalog)
 local known={}
 -- What each connector answers (lua/core/return_shapes.lua): ours, then the server's declared
 -- outputSchema, then the shape learned from this node's real answers - read once per index.
 local shapes_ok,shapes=pcall(dofile,'lua/core/return_shapes.lua');if not shapes_ok then shapes=nil end
 local declared,learned
 if shapes then
  local d_ok,d=pcall(function() return dofile('lua/core/mcp.lua').output_schemas() end);declared=d_ok and d or {}
  learned=shapes.load()
 end
 local shaped=false
 -- The one surface's *exact* names (#118), loaded once: only the nine `mcp_whatsapp_<verb>` tools are the
 -- family. A connector whose namespace merely begins with `mcp_whatsapp` is still a connector, and is
 -- still listed under its own label.
 local whatsapp=nil
 local loaded,module=pcall(dofile,'lua/core/whatsapp.lua')
 if loaded and type(module)=='table' and module.tool then whatsapp=module end
 for _,item in ipairs(catalog or {})do
  local f=item['function'] or {};local name=f.name
  if M.connector(name) then
   local text=tostring(f.description or '')
   local server=text:match('^MCP (%S+) / ([^:]+):')
   if not server then server=text:match('^%[on peer ([^%]]+)%]');if server then server='peer '..server end end
   -- One surface, one line per name: the nine `mcp_whatsapp_<verb>` tools are the same family on every
   -- node (#118), so they are grouped under the surface rather than listed as nine unrelated connectors.
   if not server and whatsapp and whatsapp.tool(name) then server='whatsapp' end
   server=server or listed(name)
   if not groups[server] then groups[server]={};order[#order+1]=server end
   local list=groups[server];list[#list+1]=name
   sigs[name]=signature(f)
   local shown_name=listed(name)
   if shown_name~=name then sigs[name]=shown_name..sigs[name]:sub(#name+1) end
   if shapes then
    local suffix=shapes.suffix(f,declared,learned)
    if suffix~='' then sigs[name]=sigs[name]..suffix;shaped=true;known[name]=true end
   end
  end
 end
 if #order==0 then return nil end
 table.sort(order)
 local lines={}
 for _,server in ipairs(order)do
  local list=groups[server];table.sort(list)
  -- The one WhatsApp surface is nine names and no connector of its own (#118): it is listed one name
  -- per line, like a built-in, because the index's own contract is one callable name per `- name` line
  -- (`scripts/test-prompt-tool-names.lua`) - and because hiding the ninth behind "+N more" is how a
  -- model concludes `mcp_whatsapp_send_status` does not exist.
  -- The group is the one surface only when every name in it is one of its nine (#118). A connector whose
  -- own id happens to be `whatsapp` (an older registry row, a fixture) keeps the ordinary grouped line.
  local family=whatsapp~=nil
  if family then
   for _,name in ipairs(list) do if not whatsapp.tool(name) then family=false end end
  end
  if family then
   for _,name in ipairs(list) do
    lines[#lines+1]='- '..sigs[name]
   end
  else
   -- The tools this node knows the answer of (it has called them, or they declare it) come first, so the
   -- eight full signatures are the ones in use - alphabetical order hid imap_search_messages, the mail
   -- task's main read, behind "+6 more" while unused ews tools were shown (15/11).
   table.sort(list,function(a,b)
    local x,y=known[a] and 0 or 1,known[b] and 0 or 1
    if x~=y then return x<y end
    return a<b
   end)
   local with={};for i,name in ipairs(list)do with[i]=sigs[name] end
   -- A shape has commas of its own, so a group whose entries carry one is separated by `; `.
   local sep=', '
   for _,sig in ipairs(with) do if sig:find(' → ',1,true) then sep='; ';break end end
   local shown=table.concat(with,sep,1,math.min(#with,8))
   -- The rest are still NAMED (names only): a name that is not in the index reads as a tool that does
   -- not exist (#118), and select:<name> gives its schema.
   if #list>8 then
    local rest={};for i=9,#list do rest[#rest+1]=listed(list[i]) end
    shown=shown..sep..'+'..(#list-8)..' more: '..table.concat(rest,', ')
   end
   lines[#lines+1]='- '..server..': '..shown
  end
 end
 local head='Connectors on this node (code mode only; exact callable names with their arguments, ? = optional'
 if shaped then head=head..'; → what the script receives, keys only' end
 return head..'; await searchTools("select:<name>") gives a full schema):\n'..table.concat(lines,'\n')
end
-- Policy text shown to the model. Keep it in step with the fences in lua/core/codemode.lua and
-- lua/core/tools.lua and with docs/CODEMODE.md: scripts/test-codemode-boundary.lua asserts both the wording
-- and the behaviour, because a stale sentence here tells the model about a rule that no longer exists (31/10).
local GUIDANCE_LINES={
 'Work in code: one `codemode` call runs JavaScript in which every tool is `tools.<name>(args)`. Put `await` before a call whose result you use; a call you return is awaited for you. What the script returns comes back to you as `returned`.',
 'Find tools with await searchTools("text"); await searchTools("select:a,b") gives their schemas. Calling a tool directly also works: it runs as the same one-line script.',
 -- Operator, 19/11 (verbatim, item 9 of docs/missions/reports/thinking-block.md): the one rule a model needs
 -- when a script ends while a call is still running, or it treats the call as lost and repeats the effect.
 'A call still running when your script ends is not cancelled: it keeps running as a pending operation and its id is in the result - wait(op) resumes it in a later script, cancel(op) stops it.',
 'How to work: 1) Gather - one script runs every independent read together (Promise.all) and returns only what you need. 2) Reflect - read the result\'s summary line, one status per call: 200 done, 202 still running, 400 fix that call, 403/404/500 the world said no, so do not reshape it. 3) Act - one script for the effects, each awaited; effects are never replayed, so after an unknown outcome read the state before trying again. 4) Stop at 200 - an effect that answered 200 is done; do not re-read to verify it.',
 'Other wasm-agent nodes: tools.nodes() lists them; tools.remote({node, capability, ...}) runs a capability there. WhatsApp is mcp_whatsapp_* on every node.',
 'Calls are always fresh; reuse an earlier result only by asking for it (results.get).',
 '`vars` is your session state: whatever you assign to it, functions included, persists across scripts and turns.',
 'Use full paths, as given (programs and files); never `~`.',
}
M.guidance=table.concat(GUIDANCE_LINES,'\n')
-- WASM_AGENT_RAW_CODE=first (lua/core/raw_code.lua): codemode is not declared, so no line may tell the
-- model to make a codemode call or a direct tool call; the run-block sentence (operator-reviewed,
-- verbatim) opens the guidance and the rest is unchanged.
function M.guidance_for(opts)
 local only = type(opts)=='table' and opts.raw_only
 if not (type(opts)=='table' and (opts.raw_first or only)) then return M.guidance end
 local lines={}
 for i,line in ipairs(GUIDANCE_LINES) do lines[i]=line end
 lines[1]=dofile('lua/core/raw_code.lua').FIRST_GUIDANCE..' Put `await` before a call whose result you use; a call you return is awaited for you.'
 lines[2]='Find tools with await searchTools("text"); await searchTools("select:a,b") gives their schemas.'
 return table.concat(lines,'\n')
end
-- The peers the last federation refresh saw, one line; cache only, so the prompt never waits on them.
function M.peer_index()
 local ok,names=pcall(function()return dofile('lua/core/federation.lua').cached_peers()end)
 if not ok or type(names)~='table' or #names==0 then return nil end
 return 'Peers seen online at the last refresh (tools.nodes() is current): '..table.concat(names,', ',1,math.min(#names,12))..(#names>12 and (', +'..(#names-12)..' more') or '')
end
-- `opts.native`: the node acts through the native run tool (arm B), so its ONE guidance source is
-- raw_code.guidance_for("tool_call") - the run-tool sentence with the batching instruction riding
-- inside it (rel review r2, item 1). The codemode lines above are never sent beside it: they name a
-- call and a direct-call shortcut the node does not offer, and a model reads every door it is shown.
-- The connector and peer indexes stay: they are the facts a script needs, not a second guidance.
function M.prompt(catalog,opts)
 local native=type(opts)=='table' and opts.native==true
 local lines={native and dofile('lua/core/raw_code.lua').guidance_for('tool_call') or M.guidance_for(opts)}
 local index=M.connector_index(catalog);if index then lines[#lines+1]=index end
 local peers=M.peer_index();if peers then lines[#lines+1]=peers end
 return table.concat(lines,'\n')
end
return M
