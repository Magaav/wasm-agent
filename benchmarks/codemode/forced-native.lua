-- Explicit benchmark adapter, including for b384; not a replacement runtime.
local M={}
function M.install(config,adapter)
 local json=dofile('lua/vendor/json.lua')
 local tools=adapter.tools
 local all,dispatch=tools.all,tools.dispatch
 local nested=false
 local schema=json.decode(config.codemode_schema)
 local core=assert(load(assert(host.read_file(config.codemode_core)),'benchmark-codemode-adapter'))()
 local sequence=0;local journal=''
 local function record(row)
  sequence=sequence+1;row.seq=sequence;row.arm=config.arm;row.binding=config.binding
  journal=journal..json.encode(row)..'\n';assert(host.write_file(config.vm_journal,journal)~=false,'VM journal write failed')
 end
 local quickjs=assert(host.quickjs)
 local invocation=0;local current
 host.quickjs=function(action,raw)
  local result=quickjs(action,raw)
  record({type='host',invocation=current,action=action,args=json.decode(raw),result=json.decode(result)})
  return result
 end
 tools.envelope=function()return {schema},'full'end
 tools.all=function(role)if nested then return all(role)end;return {schema}end
 tools.dispatch=function(memory,name,args,role,ctx)
  if nested then return dispatch(memory,name,args,role,ctx)end
  if name~='codemode' then record({type='bypass',name=name});return {error='benchmark_codemode_only',effect='none'}end
  invocation=invocation+1;current=invocation
  record({type='outer',invocation=current,name=name,session=ctx.session_id,args=args})
  local contract=dofile('lua/core/json_contract.lua')
  local _,err=contract.validate(schema['function'].parameters,ctx.tool_arguments_json or json.encode(args))
  local result
  if err then result={error=err,effect='none'}
  elseif role~='master' or not memory.session_workspace(ctx.session_id).worktree then result={error='benchmark_scope_refused',effect='none'}
  else
   local catalog=all(role)
   local describe=tools.discovery_execution(memory,ctx)
   local ok,value=pcall(core.run,memory,args,role,ctx,catalog,function()return all(role)end,function(target,parameters,fragment)
    -- Only the trusted VM broker callback can enter this scope; outer model
    -- arguments cannot set it. The original dispatcher remains authoritative.
    local old=ctx.tool_arguments_json;ctx.tool_arguments_json=fragment;nested=true
    record({type='nested_start',invocation=current,name=target,arguments=fragment})
    local admitted,value=pcall(dispatch,memory,target,parameters,role,ctx)
    nested=false;ctx.tool_arguments_json=old
    record({type='nested_end',invocation=current,name=target,ok=admitted,result=admitted and value or tostring(value)})
    if not admitted then
     host.http('POST',config.sandbox..'/halt',json.encode({['content-type']='application/json'}),'{}')
     error(value)
    end;return value
   end,describe)
   nested=false
   result=ok and value or {error=tostring(value),effect='unknown',replay_allowed=false}
  end
  record({type='outer_end',invocation=current,result=result});current=nil
  return result
 end
 return M
end
return M
