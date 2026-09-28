-- Run-scoped durable control. Only the run's writer consumes into its transcript.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local M={}
local function sql(method,s,p)
  local r=json.decode(host[method](s,json.encode(p or {})))
  if r.error then error(r.error) end
  return r
end
local function query(s,p) return sql('sql_query',s,p) end
local function exec(s,p) return sql('sql_exec',s,p) end
local function boot() return assert(json.decode(host.runtime_info()).boot_id,'steering_requires_boot_identity') end
local function recover(owner,sid)
  local r=query('SELECT * FROM steering_runs WHERE owner=? AND session_id=?',{owner,sid})[1]
  if r and r.state=='active' and r.boot~=boot() then
    exec("UPDATE steering_runs SET state='unknown' WHERE session_id=? AND boot=?",{sid,r.boot})
    exec("UPDATE steering_inbox SET state='deferred',detail='run interrupted; reconcile before resubmitting' WHERE owner=? AND session_id=? AND run_id=? AND state='queued'",{owner,sid,r.run_id})
    r.state='unknown'
  end
  return r
end
function M.begin(owner,sid,rid)
  return memory.transaction(function()
    recover(owner,sid)
    exec("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,?,?,?,'active',?) ON CONFLICT(session_id) DO UPDATE SET owner=excluded.owner,run_id=excluded.run_id,boot=excluded.boot,state='active',updated_at=excluded.updated_at",{sid,owner,rid,boot(),host.now()})
    return true
  end)
end
function M.finish(owner,sid,rid,state)
  return memory.transaction(function()
    exec('UPDATE steering_runs SET state=?,updated_at=? WHERE owner=? AND session_id=? AND run_id=?',{state,host.now(),owner,sid,rid})
    exec("UPDATE steering_inbox SET state='deferred',detail='run settled before next context boundary' WHERE owner=? AND session_id=? AND run_id=? AND state='queued'",{owner,sid,rid})
    return true
  end)
end
function M.control(args,ctx,target)
  local owner,sid=ctx.user_id,tostring(args.session_id or '')
  local session=memory.session(sid)
  if not session or session.user_id~=owner then return {error='forbidden_steering_session'} end
  return memory.transaction(function()
    local active=recover(owner,sid)
    if args.action=='steering_status' then
      return {target=active,receipts=query('SELECT id,ordinal,run_id,state,created_at,read_at,message_seq,detail FROM steering_inbox WHERE owner=? AND session_id=? AND ordinal>? ORDER BY ordinal LIMIT 100',{owner,sid,tonumber(args.after) or 0}),note='read means durable context, not verified compliance'}
    end
    local key,text=tostring(args.idempotency_key or ''),tostring(args.text or '')
    if key=='' or #key>200 then return {error='idempotency_key_required'} end
    if text:match('^%s*$') or #text>32768 then return {error='steering_text_required_or_too_large'} end
    local old=query('SELECT * FROM steering_inbox WHERE owner=? AND session_id=? AND request_key=?',{owner,sid,key})[1]
    if old then
      if old.text~=text or (args.run_id and old.run_id~=args.run_id) then return {error='idempotency_conflict'} end
      old.deduplicated=true;return old
    end
    local rid=target or (active and active.state=='active' and active.run_id)
    if target and active and active.run_id==target and active.state~='active' then
      return {error='no_active_steering_target',target=active}
    end
    if not rid then return {error='no_active_steering_target',target=active} end
    if args.run_id and args.run_id~=rid then return {error='steering_target_changed'} end
    if query("SELECT COUNT(*) AS n FROM steering_inbox WHERE owner=? AND session_id=? AND state='queued'",{owner,sid})[1].n>=128 then return {error='steering_inbox_full'} end
    local id=host.uuid()
    exec('INSERT INTO steering_inbox(id,owner,session_id,run_id,request_key,text,attribution,created_at) VALUES(?,?,?,?,?,?,?,?)',{id,owner,sid,rid,key,text,tostring(ctx.session_id or ''),host.now()})
    return query('SELECT * FROM steering_inbox WHERE id=?',{id})[1]
  end)
end
function M.pending(owner,sid,rid)
  return query("SELECT id FROM steering_inbox WHERE owner=? AND session_id=? AND run_id=? AND state='queued' LIMIT 1",{owner,sid,rid})[1]~=nil
end
-- Submission committed before admission fences dispatch. After admission, the
-- call is in flight: steering cannot undo it or promise to cancel its effects.
function M.admit(owner,sid,rid)
  return memory.transaction(function()
    return not M.pending(owner,sid,rid)
  end)
end
function M.consume(owner,sid,rid)
  return memory.transaction(function()
    local rows=query("SELECT * FROM steering_inbox WHERE owner=? AND session_id=? AND run_id=? AND state='queued' ORDER BY ordinal",{owner,sid,rid})
    for _,row in ipairs(rows) do
      row.message_seq=memory.append_turn_in_transaction(sid,{id=row.id,role='user',content=row.text})
      exec("UPDATE steering_inbox SET state='read',read_at=?,message_seq=? WHERE id=?",{host.now(),row.message_seq,row.id})
      row.state='read'
    end
    return rows
  end)
end
return M
