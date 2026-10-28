-- Trusted run context only. No task classifier and no authority derived from JS.
local json=dofile('lua/vendor/json.lua')
local users=dofile('lua/core/users.lua')
local M={}
function M.setting()
 local value=host.getenv('WASM_AGENT_CODEMODE') or ''
 if value=='' then return 'default' end
 if value~='native' and value~='off' then error('invalid_codemode_setting:'..value) end
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
 -- On by default for every MASTER run on every node (first install, a new cluster, a plain CLI in its
 -- home): code mode used to need a session worktree binding, so an ordinary operator session - the
 -- common case - silently ran without it while /health said `ready`. The one remaining refusal is a
 -- session whose binding demands a worktree that is not allocated (or is another path) yet.
 if not memory or not ctx.session_id then return true end
 local workspace=memory.session_workspace and memory.session_workspace(ctx.session_id)
 if type(workspace)~='table' or not workspace.required then return true end
 local path=memory.session_worktree and memory.session_worktree(ctx.session_id)
 return workspace.state=='allocated' and type(path)=='string' and path~='' and workspace.worktree==path
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
M.guidance='Native code mode is the preferred programmatic coding path for this run. Use codemode for appropriate multi-step read/edit/verification workflows; keep trivial calls and control-plane operations (sessions, subagents, worktrees, integration) ordinary. Direct read/edit/write/read_many/Bash remain the ordinary-tools escape; WASM_AGENT_CODEMODE=off disables code mode for a new run. Filtered output can hide relevant evidence: inspect complete nested originals when needed. Never replay a failed effectful script; unknown effects require explicit reconciliation. The VM is not the OS security boundary for Bash/write.'
return M
