-- Approved reads only. Every process remains under the existing operation supervisor.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local platform=dofile('lua/core/platform.lua')
local M={};local pool={}
local function decode(raw)local ok,value=pcall(json.decode,tostring(raw or ''));return ok and type(value)=='table' and value or nil end
local function failure(err,extra)local r=extra or {};r.ok=false;r.error=err;r.outcome=r.outcome or 'not_submitted';r.tool_call_issued=r.tool_call_issued==true;return r end
-- WHAT COUNTS AS DECIDED. The durable reservation below exists so a read that may have been issued is
-- never replayed; it must therefore be released by an ANSWER, not only by a happy one. The first
-- version accepted a result only when it carried `result_json` and a matching schema hash, so an
-- answer the MCP server itself gave as a refusal - `-32002 IMAP account 'default' is not configured`
-- (10/11) - was rewritten to `outcome=unknown`, the reservation stayed, and every later call to that
-- connector answered `mcp_connection_uncertain` for good. Nothing was in doubt: the call was issued
-- and the server answered it. An unreadable or unverifiable answer is still `unknown`.
function M.accepted(result,schema_hash)
 if type(result)~='table' then return false,'unreadable' end
 if result.outcome=='not_submitted' and result.tool_call_issued==false then return true,'not_submitted' end
 if result.tool_call_issued==true and type(result.ok)=='boolean' then
  if type(result.result_json)=='string' and result.schema_hash==schema_hash then return true,'verified' end
  if result.ok==false and type(result.error)=='string' and result.error:match('^mcp_rpc_error:') then return true,'server_error' end
 end
 return false,'unsettled'
end
-- Settling a reservation that was left behind is done from its evidence, never by replaying it.
--
-- A marker outlives the process that wrote it, so a session that died after issuing a read leaves that
-- connector answering `mcp_connection_uncertain` for ever - measured on this node: session db57bc92 was
-- killed at 18:14 while the `google` connector was mid-repair, and nothing could release the reservation
-- afterwards. What happened is still on disk: the request written before submission (`<id>.json`) and,
-- when the server answered, the retained answer beside it (`<id>.json.result.json`).
--
-- `M.reconcilable` names the only evidence that may settle a marker WITHOUT trusting an artifact that
-- nothing verified: an answer the server itself returned as a refusal (`mcp_rpc_error:`), and a
-- submission that was never issued (`not_submitted`). A complete result whose sha256 only the lost reply
-- could have confirmed is deliberately NOT enough - that reservation stays, and
-- `scripts/test-mcp-recovery.lua` owns the line (`same-VM no replay`).
function M.reconcilable(answer,schema_hash)
 local ok,why=M.accepted(answer,schema_hash)
 if not ok then return false,why end
 if why=='server_error' or why=='not_submitted' then return true,why end
 return false,'needs_the_lost_reply'
end
local function request_id_of(request)
 local name=tostring(request or ''):gsub('\\\\','/'):match('([^/]+)%.json$')
 return name
end
-- The evidence for one reserved request, or nil and why it cannot settle it. Reads only: the call that
-- may have been issued is never sent again from here.
function M.answered(request,schema_hash)
 local want=request_id_of(request)
 if not want or want=='' then return nil,'no_request' end
 local answer=decode(host.read_file(request..'.result.json'))
 if not answer then return nil,'no_retained_answer' end
 -- The answer must BE the answer to this request. The request file carries its own id; the file name
 -- carries it too, and they disagreeing means this evidence belongs to something else.
 local sent=decode(host.read_file(request))
 if type(sent)=='table' and type(sent.request_id)=='string' and sent.request_id~=want then
  return nil,'evidence_not_this_request'
 end
 if type(answer.request_id)~='string' or answer.request_id~=want then return nil,'evidence_not_this_request' end
 local ok,why=M.reconcilable(answer,schema_hash)
 if not ok then return nil,why end
 return answer,why
end
-- Release one marker when its evidence decides it. Returns {released=true,reason=..} or
-- {released=false,reason=..}; a release that is not durable is reported as not released, because a marker
-- that survives a failed DELETE must keep refusing.
function M.reconcile(uncertain_key,request,schema_hash)
 local answer,why=M.answered(request,schema_hash)
 if not answer then return {released=false,reason=why} end
 local released=decode(host.sql_exec('DELETE FROM meta WHERE key=? AND value=?',json.encode({uncertain_key,request})))
 if not released or released.error or released.ok~=true or released.changes~=1 then
  return {released=false,reason='reconcile_not_durable'}
 end
 return {released=true,reason=why}
end
function M.invoke(input,ctx,directory)
 ctx=ctx or {};if not input.read_tools or #input.read_tools==0 then return failure('mcp_read_scope_required') end
 local owner=tostring(ctx.user_id or '')..'\0'..tostring(ctx.session_id or '')..'\0'..tostring(ctx.role or '')
 local refs={};for _,field in ipairs({'env','headers'})do for name,variable in pairs(input.server[field] or {})do refs[field..':'..name]=host.sha256(tostring(host.getenv(variable) or '<missing>')) end end
 local key=host.sha256(owner..json.encode(input.server)..json.encode(refs)..json.encode(input.read_tools)..tostring(input.schema_hash or ''))
 local uncertain_key='mcp.read_uncertain.v1:'..key
 local saved=decode(host.sql_query('SELECT value FROM meta WHERE key=?',json.encode({uncertain_key})))
 if not saved or saved.error then return failure('mcp_session_store_unreadable') end
 -- A marker left behind by an earlier process is settled from its evidence before this one refuses, and a
 -- marker that no retained evidence decides keeps refusing exactly as before.
 local reconciled
 if saved[1] then
  local settled=M.reconcile(uncertain_key,saved[1].value,input.schema_hash)
  if not settled.released then
   return failure('mcp_connection_uncertain',{request=saved[1].value,reason=settled.reason})
  end
  reconciled={request=saved[1].value,reason=settled.reason}
 end
 local function hold(slot,request)
  slot.unknown=request
  local r=decode(host.sql_exec('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)',json.encode({uncertain_key,request})))
  if not r or r.error or r.ok~=true then error('mcp_uncertainty_not_durable: '..request) end
  local claim=decode(host.sql_query('SELECT value FROM meta WHERE key=?',json.encode({uncertain_key})))
  if not claim or claim.error or not claim[1] or claim[1].value~=request then error('mcp_uncertainty_claim_conflict: '..request) end
 end
 local slot=pool[key];local request_dir=paths.data()..'/mcp/requests'
 if not slot then
  local id=host.uuid();local seed_file=request_dir..'/'..id..'.seed.json';local ready_file=seed_file..'.ready.json'
  local seed={server=input.server,read_tools=input.read_tools,token=host.uuid()..host.uuid(),ready_file=ready_file,request_dir=request_dir,credential_hashes=refs,idle_ms=30000}
  if not host.write_file(seed_file,json.encode(seed)) then return failure('mcp_seed_not_written') end
  -- The runtime is the one mcp.lua resolves (it sets M.node_program); never a guess at `node` on PATH.
  if not M.node_program then return failure('mcp_node_runtime_unresolved') end
  local start=decode(host.operation('start',json.encode({program=M.node_program(),args={directory..'/mcp-session.mjs','--seed-file',seed_file},cwd=ctx.cwd or platform.cwd(),timeout_seconds=3600,owner=ctx.session_id or 'mcp-read-session'})))
  if not start or start.error or not start.operation_id then return failure('mcp_session_not_started',{detail=start}) end
  slot={operation_id=start.operation_id,seed_file=seed_file,ready_file=ready_file,token=seed.token};pool[key]=slot
  for _=1,math.min(36000,20+math.ceil((input.server.timeout_seconds or 30)*10)) do
   local raw=host.read_file(ready_file);if raw then slot.ready=decode(raw);break end
   local state=decode(host.operation('wait',json.encode({id=slot.operation_id,wait_ms=100})))
   if state and (state.settled or state.error) then return failure('mcp_session_startup_failed',{operation_id=slot.operation_id,detail=state}) end
  end
  if not slot.ready or slot.ready.token~=slot.token or not tostring(slot.ready.url):match('^http://127%.0%.0%.1:%d+$') then return failure('mcp_session_not_ready',{operation_id=slot.operation_id}) end
 end
 if slot.unknown then return failure('mcp_connection_uncertain',{operation_id=slot.operation_id,request=slot.unknown}) end
 if not slot.ready then return failure('mcp_session_not_ready',{operation_id=slot.operation_id}) end
 -- A clean idle shutdown may start a fresh read session; an uncertain one never does.
 local state=decode(host.operation('status',json.encode({id=slot.operation_id})))
 if state and state.settled==true and state.ok==true then pool[key]=nil;return M.invoke(input,ctx,directory) end
 if not state or state.error or state.settled then return failure('mcp_session_unavailable',{operation_id=slot.operation_id,detail=state}) end
 if type(slot.ready.metadata)~='table' or type(slot.ready.metadata.schema_hash)~='string' then return failure('mcp_session_metadata_unverified',{operation_id=slot.operation_id}) end
 -- Fixed built-in facades pin the first connected catalogue too; generic connectors already carry approval hashes.
 input.schema_hash=input.schema_hash or slot.ready.metadata.schema_hash
 local id=host.uuid();local request=request_dir..'/'..id..'.json';input.request_id=id;input.result_file=request..'.result.json'
 if not host.write_file(request,json.encode(input)) then return failure('mcp_request_not_written') end
 -- Reserve uncertainty BEFORE HTTP submission. A native crash cannot erase a possibly issued read.
 hold(slot,request)
 local ok,raw=pcall(host.http,'POST',slot.ready.url..'/call',json.encode({['Content-Type']='application/json',['x-wa-mcp-token']=slot.token}),json.encode(input))
 local response=ok and decode(raw);local answer=response and decode(response.body)
 if not response or tonumber(response.status)~=200 or not answer or answer.request_id~=id then
  hold(slot,request);return failure('mcp_session_reply_unverified',{operation_id=slot.operation_id,request=request,detail=answer,tool_call_issued=true,outcome='unknown'})
 end
 local retained=host.read_file(input.result_file)
 if type(answer.result_path)~='string' or type(answer.result_bytes)~='number' or type(answer.result_sha256)~='string' or answer.result_path:gsub('\\','/'):gsub('^//%?/','')~=input.result_file:gsub('\\','/'):gsub('^//%?/','') or not retained or #retained~=answer.result_bytes or host.sha256(retained)~=answer.result_sha256 then
  hold(slot,request);return failure('mcp_result_artifact_unverified',{operation_id=slot.operation_id,request=request,tool_call_issued=true,outcome='unknown'})
 end
 local result=decode(retained);if not result or result.request_id~=id then hold(slot,request);return failure('mcp_session_result_unreadable',{outcome='unknown',tool_call_issued=true,request=request}) end
 result.operation_id=slot.operation_id;result.request=request;result.evidence={path=input.result_file,sha256=answer.result_sha256,bytes=answer.result_bytes}
 local decided=M.accepted(result,input.schema_hash)
 if not decided then
  result.ok=false;result.error='mcp_result_settlement_unverified';result.outcome='unknown';result.tool_call_issued=true
 elseif result.outcome=='unknown' then
  -- The answer is on disk and it verifies, so it is decided: name what it was instead of hedging.
  result.outcome=result.ok and 'settled' or 'error'
 end
 if result.outcome~='unknown' then
  local released=decode(host.sql_exec('DELETE FROM meta WHERE key=? AND value=?',json.encode({uncertain_key,request})))
  if not released or released.error or released.ok~=true or released.changes~=1 then error('mcp_uncertainty_release_unverified: '..request) end
  slot.unknown=nil
 end
 -- A settled marker is named in the answer that follows it: the reader learns that an earlier reservation was
 -- reconciled from its evidence, not that a read was silently repeated.
 if reconciled then result.reconciled=reconciled end
 return result
end
function M.close()
 local results={}
 for key,slot in pairs(pool)do
  local cancelled=decode(host.operation('cancel',json.encode({id=slot.operation_id})))
  local settled=decode(host.operation('await',json.encode({id=slot.operation_id,wait_for='settled'})))
  results[#results+1]={operation_id=slot.operation_id,cancel=cancelled,settled=settled,unknown_request=slot.unknown}
  if settled and settled.settled and not slot.unknown then pool[key]=nil end
 end
 return results
end
return M
