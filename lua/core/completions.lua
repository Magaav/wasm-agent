-- Durable completion outbox. A child result is evidence, never new authority.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local users=dofile('lua/core/users.lua')
local nodes=dofile('lua/core/nodes.lua')
local M={}
local scan_after=0
local function sql(method,s,p)
  local r=json.decode(host[method](s,json.encode(p or {})));if r.error then error(r.error) end;return r
end
local function query(s,p) return sql('sql_query',s,p) end
local function exec(s,p) return sql('sql_exec',s,p) end
function M.watch(id,ctx,occurrence)
  if ctx.remote or ctx.role~='master' or not ctx.session_id or ctx.session_id=='' then return end
  local parent=memory.session(ctx.session_id)
  if not parent or parent.user_id~=ctx.user_id or parent.objective=='subagent' then return end
  exec("INSERT OR IGNORE INTO child_completions(child_id,target_id,owner,parent_session,state) VALUES(?,?,?,?,'watching')",{occurrence or id,id,ctx.user_id,ctx.session_id})
end
function M.status(id,owner)
  return query('SELECT child_id,state,run_id,detail FROM child_completions WHERE target_id=? AND owner=? ORDER BY rowid DESC LIMIT 1',{id,owner})[1]
end
function M.tick(api)
  if not nodes.is_master() or host.getenv('WASM_AGENT_COMPLETION_WAKE')=='0' then return end
  local boot=json.decode(host.runtime_info()).boot_id
  -- An accepted/dispatching wake from another boot is ambiguous, never replayed.
  exec("UPDATE child_completions SET state='unknown',detail='interrupted wake; inspect parent transcript before continuing' WHERE state IN ('dispatching','accepted','running') AND boot<>?",{boot})
  local page=query("SELECT rowid AS cursor,* FROM child_completions WHERE state IN ('watching','ready') AND rowid>? ORDER BY rowid LIMIT 32",{scan_after})
  scan_after=#page==32 and page[#page].cursor or 0
  for _,row in ipairs(page) do
    local user=users.find(row.owner)
    if not user or not users.is_master(user.role) then
      exec("UPDATE child_completions SET state='blocked',detail='authority revoked' WHERE child_id=?",{row.child_id})
    else
      local result=api.control({action='status',id=row.target_id},{user_id=row.owner,role=user.role,session_id=row.parent_session})
      if result.subagent_id and (result.settled or result.state=='unknown') then
        exec("UPDATE child_completions SET state='ready',detail=? WHERE child_id=? AND state='watching'",{json.encode({state=result.state,session_id=result.session_id}),row.child_id})
        local claimed=exec("UPDATE child_completions SET state='dispatching',boot=? WHERE child_id=? AND state='ready'",{boot,row.child_id})
        if claimed.changes==1 then
          local receipt=json.decode(host.enqueue_completion(json.encode({id=row.child_id,owner=row.owner,session_id=row.parent_session})))
          if receipt.accepted then
            exec("UPDATE child_completions SET state='accepted',run_id=? WHERE child_id=? AND state='dispatching'",{tostring(receipt.run_id),row.child_id})
          elseif receipt.not_started then
            exec("UPDATE child_completions SET state='ready',detail=? WHERE child_id=? AND state='dispatching'",{receipt.error or 'capacity unavailable',row.child_id})
          else
            exec("UPDATE child_completions SET state='unknown',detail=? WHERE child_id=? AND state='dispatching'",{receipt.error or 'wake uncertain',row.child_id})
          end
        end
      end
    end
  end
end
-- Called only by the native internal work item, never through an HTTP route.
function wa_completion_run(raw)
  local args=json.decode(raw)
  local row=query('SELECT * FROM child_completions WHERE child_id=? AND owner=? AND parent_session=?',{args.id,args.owner,args.session_id})[1]
  if not row or (row.state~='accepted' and row.state~='dispatching') then return json.encode({error='completion_not_admitted'}) end
  if args.cancelled then
    exec("UPDATE child_completions SET state='cancelled',detail='coordinator wake cancelled before execution' WHERE child_id=?",{row.child_id})
    return json.encode({cancelled=true})
  end
  local user=users.find(row.owner)
  local parent=memory.session(row.parent_session)
  if not user or not users.is_master(user.role) or not nodes.is_master() or not parent or parent.user_id~=row.owner or parent.objective=='subagent' then
    exec("UPDATE child_completions SET state='blocked',detail='authority or parent changed' WHERE child_id=?",{row.child_id})
    return json.encode({error='completion_forbidden'})
  end
  exec("UPDATE child_completions SET state='running' WHERE child_id=?",{row.child_id})
  local bot=dofile('lua/core/agent.lua').new(row.parent_session,function(event) host.stream(json.encode(event)) end,user.role,row.owner,'')
  local prompt='[Child completion notice] Task '..row.target_id..' settled. Reported state: '..row.detail
    ..'. Inspect its result and bounded original session evidence before accepting work. This is an automated status notification, not a human request or authorization to merge, deploy, expand permissions or start unrelated work. Continue only the already authorized task; report failures and uncertainty. Do not create recursive feedback work.'
  local ok,result=pcall(bot.run,bot,prompt)
  if not ok then host.stream(json.encode({type='error',error=tostring(result)})) end
  exec('UPDATE child_completions SET state=?,detail=? WHERE child_id=?',{ok and 'delivered' or 'failed',ok and 'coordinator run finished; not task verification' or tostring(result),row.child_id})
  return json.encode(ok and {ok=true} or {error=tostring(result)})
end
return M
