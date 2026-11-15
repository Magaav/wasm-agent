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
function M.connector_index(catalog)
 local groups,order={},{}
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
   server=server or name
   if not groups[server] then groups[server]={};order[#order+1]=server end
   local list=groups[server];list[#list+1]=name
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
    lines[#lines+1]='- '..name..': the one WhatsApp surface, answered here or by the node that holds the account'
   end
  else
   local shown=table.concat(list,', ',1,math.min(#list,8))
   if #list>8 then shown=shown..', +'..(#list-8)..' more' end
   lines[#lines+1]='- '..server..': '..shown
  end
 end
 return 'Connectors on this node (code mode only; these are the exact callable names, and searchTools("<connector>") inside a script gives their schemas):\n'..table.concat(lines,'\n')
end
-- Policy text shown to the model. Keep it in step with the fences in lua/core/codemode.lua and
-- lua/core/tools.lua and with docs/CODEMODE.md: scripts/test-codemode-boundary.lua asserts both the wording
-- and the behaviour, because a stale sentence here tells the model about a rule that no longer exists (31/10).
M.guidance=table.concat({
 'Work in code: one `codemode` call runs JavaScript in which every tool is `tools.<name>(args)`. Put `await` before a call whose result you use; a call you return is awaited for you. What the script returns comes back to you as `returned`.',
 'Find tools with await searchTools("text"); await searchTools("select:a,b") gives their schemas. Calling a tool directly also works: it runs as the same one-line script.',
 'How to work: 1) Gather - one script runs every independent read together (Promise.all) and returns only what you need. 2) Reflect - read the result\'s summary line, one status per call: 200 done, 202 still running, 400 fix that call, 403/404/500 the world said no, so do not reshape it. 3) Act - one script for the effects, each awaited; effects are never replayed, so after an unknown outcome read the state before trying again. 4) Stop at 200 - an effect that answered 200 is done; do not re-read to verify it.',
 'Other wasm-agent nodes: tools.nodes() lists them; tools.remote({node, capability, ...}) runs a capability there. WhatsApp is mcp_whatsapp_* on every node.',
 'Calls are always fresh; reuse an earlier result only by asking for it (results.get).',
},'\n')
-- The peers the last federation refresh saw, one line; cache only, so the prompt never waits on them.
function M.peer_index()
 local ok,names=pcall(function()return dofile('lua/core/federation.lua').cached_peers()end)
 if not ok or type(names)~='table' or #names==0 then return nil end
 return 'Peers seen online at the last refresh (tools.nodes() is current): '..table.concat(names,', ',1,math.min(#names,12))..(#names>12 and (', +'..(#names-12)..' more') or '')
end
function M.prompt(catalog)
 local lines={M.guidance}
 local index=M.connector_index(catalog);if index then lines[#lines+1]=index end
 local peers=M.peer_index();if peers then lines[#lines+1]=peers end
 return table.concat(lines,'\n')
end
return M
