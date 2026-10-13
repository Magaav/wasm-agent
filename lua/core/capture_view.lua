-- Structural capture metadata; original JSON types/bytes are never rewritten.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local output=dofile('lua/core/tool_output.lua')
local M={}
local function preview(s)
 s=type(s)=='string' and s or '';local text=output.slice(s,1,64);return text,#s,#text<#s
end
local function child(node,key)return node and node.children and node.children[key] end
local function summary(request,index)
 local tools=child(request,'tools');local messages=child(request,'messages') or child(request,'input')
 if tools and tools.kind~='array' then error('capture_tools_invalid') end
 if messages and messages.kind~='array' and messages.kind~='string' then error('capture_messages_invalid') end
 local list=tools and tools.children or {}
 local out={index=index,envelope_bytes=#contract.compact(request),schema_bytes=tools and #contract.compact(tools) or 2,
  tool_count=#list,message_count=messages and (messages.kind=='array' and #messages.children or 1) or 0,
  system_bytes=0,tools={},tools_omitted=math.max(0,#list-16)}
 if messages and messages.kind=='array' then for _,m in ipairs(messages.children)do
  local role=child(m,'role');local content=child(m,'content')
  if role and (role.value=='system' or role.value=='developer') and content then
   if content.kind=='string' then out.system_bytes=out.system_bytes+#content.value
   elseif content.kind=='array' then for _,p in ipairs(content.children)do local text=child(p,'text');if text and text.kind=='string' then out.system_bytes=out.system_bytes+#text.value end end end
  end
 end end
 for i=1,math.min(16,#list)do
  local fn=child(list[i],'function') or list[i];local nameNode=child(fn,'name')
  local name,bytes,truncated=preview(nameNode and nameNode.value)
  out.tools[i]={index=i,name=name,name_bytes=bytes,name_truncated=truncated,schema_bytes=#contract.compact(list[i])}
 end
 return out
end
function M.inspect(args)
 if type(args.path)~='string' or args.path=='' then return {error='path_required',effect='none'} end
 local text=host.read_file(args.path);if not text then return {error='capture_unreadable',effect='none'} end
 local sha=host.sha256(text)
 if args.snapshot~=nil and args.snapshot~=sha then return {error='capture_snapshot_changed',effect='none'} end
 local record,err=contract.parse(text)
 if not record or record.kind~='object' then return {error=err or 'capture_json_object_required',full_result=output.store(text),effect='none'} end
 local requests=child(record,'requests');local nodes
 if requests and requests.kind=='array' then nodes=requests.children
 elseif child(record,'request') and child(record,'request').kind=='object' then nodes={child(record,'request')}
 elseif child(record,'messages') or child(record,'input') or child(record,'tools') then nodes={record}
 else return {error='capture_layout_unsupported',full_result=output.store(text),effect='none'} end
 local view=args.view or 'summary';local ref=output.store(text)
 if view~='summary' then
  local index=args.request_index or 1
  if type(index)~='number' or index%1~=0 or index<1 or not nodes[index] then return {error='capture_request_index_invalid',effect='none'} end
  local value=nodes[index]
  if view=='tool' or view=='message' then
   local items=view=='tool' and child(value,'tools') or (child(value,'messages') or child(value,'input'))
   local item=args.item_index or 1
   if type(item)~='number' or item%1~=0 or item<1 or not items or items.kind~='array' or not items.children[item] then return {error='capture_item_index_invalid',effect='none'} end
   value=items.children[item]
  elseif view~='request' then return {error='capture_view_invalid',effect='none'} end
  return {view=view,value=json.raw(contract.raw(text,value)),snapshot=sha,full_result=ref,note='Exact selected JSON fragment, including null/empty shapes; complete original retained.'}
 end
 local offset,limit=args.offset or 0,args.limit or 1
 if type(offset)~='number' or offset%1~=0 or offset<0 or offset==math.huge then return {error='capture_offset_invalid',effect='none'} end
 if type(limit)~='number' or limit%1~=0 or limit<1 or limit>8 then return {error='capture_limit_invalid',effect='none'} end
 if offset>0 and not args.snapshot then return {error='capture_snapshot_required',effect='none'} end
 local results={};for i=offset+1,math.min(#nodes,offset+limit)do
  if nodes[i].kind~='object' then return {error='capture_request_invalid',index=i,full_result=ref,effect='none'} end
  local ok,item=pcall(summary,nodes[i],i);if not ok then return {error=tostring(item),index=i,full_result=ref,effect='none'} end
  results[#results+1]=item
 end
 local complete=offset+#results>=#nodes
 local result={ok=true,view='summary',source={path=args.path,bytes=#text,sha256=sha},snapshot=sha,
  total=#nodes,offset=offset,results=results,complete=complete,has_more=not complete,next_offset=not complete and offset+#results or nil,full_result=ref,
  note='Structural metadata only, not a content summary or quality verdict. Sizes use compact JSON preserving types; tool names beyond sixteen are counted. Inspect exact tool/message/request views when needed. No provider/app calls.'}
 if #json.encode(result)>output.MAX_BYTES then return {error='capture_metadata_exceeds_budget',full_result=ref,effect='none'} end
 return result
end
return M
