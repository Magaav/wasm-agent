-- Native routed calls: opt-in typed singles, preflighted serial read groups.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local envelope=dofile('lua/core/envelope.lua')
local pages=dofile('lua/core/read_batch.lua')
local M={}
local READS={read=true,grep=true,ls=true,capture_inspect=true,recall=true,skill=true}
function M.invoke(catalog,args,ctx,scope,dispatch)
 local raw=ctx.tool_arguments_json;local root,problem
 if raw then root,problem=contract.parse(raw);if not root or root.kind~='object' then return {error=problem or 'tool_call_object_required',effect='none'} end end
 if args.cursor~=nil then
  if args.name~=nil or args.arguments~=nil or args.calls~=nil or args.checked~=nil then return {error='tool_call_forms_are_exclusive',effect='none'} end
  return pages.resume(args.cursor,scope,'tool_call')
 end
 if args.checked~=nil and type(args.checked)~='boolean' then return {error='checked_boolean_required',effect='none'} end
 local function prepare(call,node,checked)
  if type(call)~='table' or type(call.name)~='string' or type(call.arguments)~='table' then return nil,'tool_arguments_object_required' end
  for key in pairs(call.arguments)do if type(key)~='string' then return nil,'tool_arguments_object_required' end end
  local selected,err=envelope.resolve(catalog,call.name,ctx);if not selected then return nil,err end
  local fragment=node and contract.raw(raw,node) or (next(call.arguments)==nil and '{}' or json.encode(call.arguments))
  local parsed,failure=contract.parse(fragment);if not parsed or parsed.kind~='object' then return nil,failure or 'tool_arguments_object_required' end
  if checked then local valid,why=contract.validate(selected['function'].parameters,fragment);if not valid then return nil,why end end
  return {name=call.name,arguments=call.arguments,raw=fragment}
 end
 if args.calls==nil then
  local plan,err=prepare(args,root and contract.at(root,{'arguments'}),args.checked==true)
  if not plan then return {error=err,effect='none'} end
  return dispatch(plan.name,plan.arguments,plan.raw)
 end
 if args.name~=nil or args.arguments~=nil then return {error='tool_call_forms_are_exclusive',effect='none'} end
 if type(args.calls)~='table' or #args.calls<1 or #args.calls>8 then return {error='calls_required_1_to_8',effect='none'} end
 local calls=root and contract.at(root,{'calls'})
 if calls and calls.kind~='array' then return {error='calls_array_required',effect='none'} end
 local count=calls and #calls.children or #args.calls
 if count<1 or count>8 then return {error='calls_required_1_to_8',effect='none'} end
 local plans={}
 for i=1,count do local call=args.calls[i]
  if type(call)~='table' or calls and calls.children[i].kind~='object' or not READS[call.name] then return {error='batch_target_not_pure_read',index=i,effect='none'} end
  local node=calls and contract.at(calls,{i,'arguments'})
  local plan,err=prepare(call,node,true);if not plan then return {error=err,index=i,effect='none'} end
  plans[i]=plan
 end
 local results,failed,executed={},0,0
 for i,plan in ipairs(plans)do
  local canceled=host.run_cancelled and json.decode(host.run_cancelled()).cancelled
  if canceled then
   for j=i,#plans do results[j]={error='run_cancelled',executed=false} end
   failed=failed+#plans-i+1;break
  end
  local selected,err=envelope.resolve(catalog,plan.name,ctx)
  if not selected then
   results[i]={error=err,executed=false};failed=failed+1
   for j=i+1,#plans do results[j]={error='batch_stopped_after_authority_drift',executed=false};failed=failed+1 end
   break
  end
  local ok,result=pcall(dispatch,plan.name,plan.arguments,plan.raw)
  results[i]=ok and result or {error=tostring(result),executed=true};executed=executed+1
  if type(results[i])~='table' then results[i]={result=results[i]} end
  if results[i].error or results[i].ok==false then failed=failed+1 end
 end
 return pages.start({ok=failed==0,failed=failed,results=results,executed=executed,typed=true,serial=true},scope,'tool_call')
end
return M
