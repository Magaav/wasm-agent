-- Approved reads only. Every process remains under the existing operation supervisor.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local platform=dofile('lua/core/platform.lua')
local M={};local pool={}
local function decode(raw)local ok,value=pcall(json.decode,tostring(raw or ''));return ok and type(value)=='table' and value or nil end
local function failure(err,extra)local r=extra or {};r.ok=false;r.error=err;r.outcome=r.outcome or 'not_submitted';r.tool_call_issued=r.tool_call_issued==true;return r end
function M.invoke(input,ctx,directory)
 ctx=ctx or {};if not input.read_tools or #input.read_tools==0 then return failure('mcp_read_scope_required') end
 local owner=tostring(ctx.user_id or '')..'\0'..tostring(ctx.session_id or '')..'\0'..tostring(ctx.role or '')
 local refs={};for _,field in ipairs({'env','headers'})do for name,variable in pairs(input.server[field] or {})do refs[field..':'..name]=host.sha256(tostring(host.getenv(variable) or '<missing>')) end end
 local key=host.sha256(owner..json.encode(input.server)..json.encode(refs)..json.encode(input.read_tools)..tostring(input.schema_hash or ''))
 local uncertain_key='mcp.read_uncertain.v1:'..key
 local saved=decode(host.sql_query('SELECT value FROM meta WHERE key=?',json.encode({uncertain_key})))
 if not saved or saved.error then return failure('mcp_session_store_unreadable') end
 if saved[1] then return failure('mcp_connection_uncertain',{request=saved[1].value}) end
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
 if result.outcome~='unknown' and not (result.outcome=='not_submitted' and result.tool_call_issued==false) and not (type(result.result_json)=='string' and type(result.ok)=='boolean' and result.tool_call_issued==true and result.schema_hash==input.schema_hash) then
  result.ok=false;result.error='mcp_result_settlement_unverified';result.outcome='unknown';result.tool_call_issued=true
 end
 if result.outcome~='unknown' then
  local released=decode(host.sql_exec('DELETE FROM meta WHERE key=? AND value=?',json.encode({uncertain_key,request})))
  if not released or released.error or released.ok~=true or released.changes~=1 then error('mcp_uncertainty_release_unverified: '..request) end
  slot.unknown=nil
 end
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
