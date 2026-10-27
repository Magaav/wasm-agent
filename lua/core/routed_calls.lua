-- Native routed calls: opt-in typed singles, preflighted serial read groups.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local envelope=dofile('lua/core/envelope.lua')
local pages=dofile('lua/core/read_batch.lua')
local M={}
local READS={read=true,grep=true,ls=true,capture_inspect=true,recall=true,skill=true}
local OWN={name=true,arguments=true,checked=true,calls=true,cursor=true}
local EXAMPLE='{"name":"read","arguments":{"path":"README.md"}}'
local function sorted(t)local out={};if type(t)=='table' then for k in pairs(t)do out[#out+1]=tostring(k)end end;table.sort(out);return out end
-- What arrived, without the payload: its JSON type and top-level keys.
function M.shape(value)
 local kind=type(value);if kind=='table' then kind=(next(value)~=nil and value[1]~=nil) and 'array' or 'object' end
 if kind=='nil' then kind='missing' end
 return {type=kind,keys=kind=='object' and sorted(value) or nil}
end
local function teach(code,call,problem)
 return {error=code,effect='none',problem=problem,received={tool_call_keys=sorted(call),arguments=M.shape(type(call)=='table' and call.arguments or nil)},
  note='tool_call takes the target name and ONE arguments object holding that tool\'s own parameters. Nothing was run.',example=EXAMPLE}
end
local function object_text(text)
 local node=contract.parse(text);if not node or node.kind~='object' then return nil end
 local ok,value=pcall(json.decode,text);return ok and type(value)=='table' and value or nil
end
-- Deterministic repairs of the single-call form, applied only where one reading exists:
--  * `arguments` sent as a JSON string holding an object is parsed;
--  * a doubled wrapper {name?:'tool_call', arguments:{name, arguments}} is unwrapped;
--  * target parameters placed beside `name` instead of inside `arguments` are moved in, and a key
--    present in both places with different values is refused as ambiguous;
--  * no `arguments` at all, and nothing beside `name`, means the empty object.
-- Returns the normalized call (or the original when nothing changed) and the list of repairs.
function M.normalize(args)
 if type(args)~='table' or args.calls~=nil or args.cursor~=nil then return args end
 local out,notes={},{};for k,v in pairs(args)do out[k]=v end
 local function parse_string()
  if type(out.arguments)~='string' then return true end
  local decoded=object_text(out.arguments)
  if not decoded then return nil,teach('tool_arguments_object_required',args,'arguments is a string that is not a JSON object') end
  out.arguments=decoded;notes[#notes+1]='arguments was a JSON string; parsed it as the object';return true
 end
 local ok,refusal=parse_string();if not ok then return nil,refusal end
 local inner=out.arguments
 if type(inner)=='table' and type(inner.name)=='string' and inner.arguments~=nil and (out.name==nil or out.name=='tool_call') then
  local only=true;for k in pairs(inner)do if k~='name' and k~='arguments' then only=false end end
  if only then out.name=inner.name;out.arguments=inner.arguments;notes[#notes+1]='unwrapped a nested {name, arguments}'
   ok,refusal=parse_string();if not ok then return nil,refusal end end
 end
 local extras={};for k,v in pairs(out)do if not OWN[k] then extras[k]=v end end
 if next(extras)~=nil then
  if out.arguments==nil then out.arguments={}
  elseif type(out.arguments)~='table' then return nil,teach('tool_arguments_object_required',args,'arguments is not an object, and other keys sit beside name') end
  local merged={};for k,v in pairs(out.arguments)do merged[k]=v end
  for k,v in pairs(extras)do
   if merged[k]~=nil and json.encode(merged[k])~=json.encode(v) then
    local r=teach('tool_call_arguments_ambiguous',args,'`'..tostring(k)..'` is both beside name and inside arguments, with different values');r.key=tostring(k);return nil,r
   end
   merged[k]=v;out[k]=nil
  end
  out.arguments=merged;notes[#notes+1]='moved '..table.concat(sorted(extras),', ')..' into arguments'
 elseif out.arguments==nil and type(out.name)=='string' then out.arguments={};notes[#notes+1]='no arguments given; used {}' end
 if #notes==0 then return args end
 return out,notes
end
function M.invoke(catalog,args,ctx,scope,dispatch)
 local raw=ctx.tool_arguments_json;local root,problem
 if raw then root,problem=contract.parse(raw);if not root or root.kind~='object' then return {error=problem or 'tool_call_object_required',effect='none'} end end
 if args.cursor~=nil then
  if args.name~=nil or args.arguments~=nil or args.calls~=nil or args.checked~=nil then return {error='tool_call_forms_are_exclusive',effect='none'} end
  return pages.resume(args.cursor,scope,'tool_call')
 end
 if args.checked~=nil and type(args.checked)~='boolean' then return {error='checked_boolean_required',effect='none'} end
 local function prepare(call,node,checked)
  if type(call)~='table' then return nil,'tool_arguments_object_required',teach('tool_arguments_object_required',{},'the call is '..M.shape(call).type..', not an object') end
  if type(call.name)~='string' then return nil,'tool_arguments_object_required',teach('tool_arguments_object_required',call,'name is '..M.shape(call.name).type..'; it must be the target tool name') end
  if type(call.arguments)~='table' then return nil,'tool_arguments_object_required',teach('tool_arguments_object_required',call,'arguments is '..M.shape(call.arguments).type..'; it must be an object') end
  for key in pairs(call.arguments)do if type(key)~='string' then return nil,'tool_arguments_object_required',teach('tool_arguments_object_required',call,'arguments is an array; it must be an object') end end
  local selected,err=envelope.resolve(catalog,call.name,ctx);if not selected then return nil,err end
  local fragment=node and contract.raw(raw,node) or (next(call.arguments)==nil and '{}' or json.encode(call.arguments))
  local parsed,failure=contract.parse(fragment);if not parsed or parsed.kind~='object' then return nil,failure or 'tool_arguments_object_required' end
  if checked then local valid,why=contract.validate(selected['function'].parameters,fragment);if not valid then return nil,why end end
  return {name=call.name,arguments=call.arguments,raw=fragment}
 end
 if args.calls==nil then
  local normalized,notes=M.normalize(args)
  if not normalized then return notes end
  -- A repaired call has no byte-exact fragment in the raw text; its arguments are re-encoded.
  local node=notes==nil and root and contract.at(root,{'arguments'}) or nil
  local plan,err,detail=prepare(normalized,node,normalized.checked==true)
  if not plan then return detail or {error=err,effect='none'} end
  local result=dispatch(plan.name,plan.arguments,plan.raw)
  if notes and type(result)=='table' then result.normalized='tool_call: '..table.concat(notes,'; ')..'. Canonical shape: '..EXAMPLE end
  return result
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
  local plan,err,detail=prepare(call,node,true);if not plan then if detail then detail.index=i;return detail end;return {error=err,index=i,effect='none'} end
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
