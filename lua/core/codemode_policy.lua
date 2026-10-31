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
function M.connector_refusal(name)
 return {error='codemode_only: '..tostring(name)..' is a connector tool; call it inside codemode: const r = await tools.'..M.js_name(name)..'({...}); return r',effect='none'}
end
-- One compact line per connector: what the model needs to route a request such as "look at
-- WhatsApp" or "check my mail" to code mode from an empty context, without the schemas.
function M.connector_index(catalog)
 local groups,order={},{}
 for _,item in ipairs(catalog or {})do
  local f=item['function'] or {};local name=f.name
  if M.connector(name) then
   local text=tostring(f.description or '')
   local server,tool=text:match('^MCP (%S+) / ([^:]+):')
   if not server then server=text:match('^%[on peer ([^%]]+)%]');if server then server='peer '..server;tool=name:match('__(.+)$') end end
   server=server or name;tool=tool or name
   if not groups[server] then groups[server]={};order[#order+1]=server end
   local list=groups[server];list[#list+1]=tool
  end
 end
 if #order==0 then return nil end
 table.sort(order)
 local lines={}
 for _,server in ipairs(order)do
  local list=groups[server];table.sort(list)
  local shown=table.concat(list,', ',1,math.min(#list,8))
  if #list>8 then shown=shown..', +'..(#list-8)..' more' end
  lines[#lines+1]='- '..server..': '..shown
 end
 return 'Connectors on this node (code mode only; searchTools("<connector>") inside a script gives exact names and schemas):\n'..table.concat(lines,'\n')
end
-- Policy text shown to the model. Keep it in step with the fences in lua/core/codemode.lua and
-- lua/core/tools.lua and with docs/CODEMODE.md: scripts/test-codemode-boundary.lua asserts both the wording
-- and the behaviour, because a stale sentence here tells the model about a rule that no longer exists (31/10).
M.guidance=table.concat({
 'Code mode is the preferred programmatic coding path for this run: one `codemode` call runs a JavaScript script that calls tools as `await tools.<name>(args)` and returns only what you need.',
 'Default to code mode for any work a script can do: every tool except the control plane below is callable inside it, so prefer one script over a sequence of ordinary calls. That covers (1) connectors - WhatsApp, mail and every other MCP or peer connector exist only inside code mode; (2) web research - await tools.web_search({query,limit}) returns results with cache refs, await tools.web_read({url}) or ({ref}) reads a page; prefer them over curl for public pages, keep curl in bash for authenticated APIs, POST or local hosts; (3) two or more dependent calls, loops, or searching and filtering large output (history, logs, many files); (4) read -> edit -> verify sequences.',
 'Use ordinary tools for: a single quick call whose whole output you need (one read, edit, bash or web_search); and the few control-plane actions code mode refuses: subagent, integrate, session_worktree, resume_session, session_debug, session_fixture, nested codemode and the outer facades (tool_call, tool_search, capabilities) that have in-sandbox equivalents. Everything else runs inside too - shell, client, spells, every operation/resource action, and remote calls that change a peer - with the same per-call checks an ordinary call gets.',
 'Peers: other wasm-agent nodes hold their own files, repositories and history; await tools.nodes() lists them. From a script, await tools.remote({node, capability:"read", path}) reads a peer; capability may be read, read_many, ls, grep, sessions, session, search_messages, recall, bash (pass cwd, not cd) - and any capability the peer authorizes, including write, edit and effectful bash, which run with the same per-call permission and binding checks an ordinary remote call gets. One call is ~0.35 s; tools.remote({node, capability:"batch", calls:[{capability:"read",path},{capability:"bash",command:"git log -1",cwd}]}) runs up to 8 reads in one round trip (a batch stays read-only).',
 'History is per node: work done on a peer is in that peer\'s history, not yours. search_messages({query, node}) searches a peer; sessions({node, all_owners:true, path:"/repo"}) lists the sessions on that peer that worked in that repository, newest first - the first row is the last agent session there; session({node, session_id}) reads one.',
 'WhatsApp is the linked-device connector (mcp_whatsapp_*, or peer_<node>__* where another node holds it): read and send through it from a script.',
 'Inside a script, searchTools("text") finds tools (searchTools("*") lists all) and describeTool(name) gives a schema. Filtered output can hide relevant evidence: inspect complete nested originals when needed. Never replay a failed effectful script; unknown effects require explicit reconciliation. WASM_AGENT_CODEMODE=off disables code mode for a new run. The VM is not the OS security boundary for bash/write.',
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
