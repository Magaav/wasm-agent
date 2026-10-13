-- Whole-result budget packing for independent file reads. Never refetch a continuation.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/tool_output.lua')
local paths=dofile('lua/core/paths.lua')
local M={}
local PREFIX='read_many.cursor.v1:'
local function decode(raw)local ok,value=pcall(json.decode,tostring(raw or ''));return ok and type(value)=='table' and value or nil end
local function save(record)
 local id=host.uuid();local value=json.encode(record)
 local r=decode(host.sql_exec('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)',json.encode({PREFIX..id,value})))
 if not r or r.error or r.ok~=true or r.changes~=1 then error('read_many_cursor_store_failed') end
 return id
end
local function artifact(ref,owner)
 if type(ref)~='table' or type(ref.sha256)~='string' or not ref.sha256:match('^%x+$') or #ref.sha256~=64 then return nil,'read_many_snapshot_invalid' end
 local text=host.read_file(paths.data()..'/tool-results/'..ref.sha256:lower()..'.txt')
 if not text or #text~=ref.bytes or host.sha256(text)~=ref.sha256 then return nil,'read_many_snapshot_changed' end
 local value=decode(text);if not value or type(value.results)~='table' then return nil,'read_many_snapshot_invalid' end
 if owner=='tool_call' then
  local contract=dofile('lua/core/json_contract.lua');local tree=contract.parse(text);local nodes=contract.at(tree,{'results'})
  if not nodes or nodes.kind~='array' or #nodes.children~=#value.results then return nil,'read_many_snapshot_invalid' end
  local function retain(decoded,node)
   if type(decoded)~='table' then return end
   setmetatable(decoded,{__json_raw=contract.raw(text,node)})
   for key,child in pairs(node.children or {})do retain(decoded[key],child) end
  end
  for i,node in ipairs(nodes.children)do
   if type(value.results[i])~='table' then return nil,'read_many_snapshot_invalid' end
   -- Lua field access remains; every table serializes its exact retained fragment.
   -- Plain decode loses nested nulls and empty-object distinctions.
   retain(value.results[i],node)
  end
 end
 return value
end
local function page(original,scope,ref,first,owner)
 owner=owner or 'read_many'
 local total=#original.results
 if type(first)~='number' or first%1~=0 or first<1 or first>total then return {error='read_many_cursor_invalid'} end
 local outcomes={};for i,item in ipairs(original.results)do outcomes[i]={index=i,ok=item.error==nil and item.ok~=false} end
 local view={ok=original.ok,failed=original.failed,results={},outcomes=outcomes,total=total,first_index=first,last_index=first-1,
  complete=false,has_more=true,full_result=ref,next_cursor=string.rep('0',36),
  note='Whole results packed within the unchanged view budget. Follow next_cursor with '..owner..'; cached originals are not refetched. Item positions start at first_index. Versions, errors, images and edit receipts remain exact.'}
 for i=first,total do
  view.results[#view.results+1]=original.results[i];view.last_index=i
  if #json.encode(view)>output.MAX_BYTES then view.results[#view.results]=nil;view.last_index=i-1;break end
 end
 if #view.results==0 then return {error='read_many_item_exceeds_budget',index=first,full_result=ref} end
 view.complete=view.last_index==total;view.has_more=not view.complete
 if view.has_more then view.next_cursor=save({scope=scope,ref=ref,first=view.last_index+1,owner=owner}) else view.next_cursor=nil end
 if #json.encode(view)>output.MAX_BYTES then error('read_many_page_exceeds_budget') end
 return view
end
function M.start(original,scope,owner)
 local encoded=json.encode(original)
 if #encoded<=output.MAX_BYTES then return original end
 local ref=output.store(encoded)
 return page(original,scope,ref,1,owner)
end
function M.resume(cursor,scope,owner)
 if type(cursor)~='string' or not cursor:match('^[a-f0-9%-]+$') or #cursor~=36 then return {error='read_many_cursor_invalid'} end
 local rows=decode(host.sql_query('SELECT value FROM meta WHERE key=?',json.encode({PREFIX..cursor})))
 if not rows or rows.error then return {error='read_many_cursor_store_unreadable'} end
 local record=rows[1] and decode(rows[1].value)
 if not record then return {error='read_many_cursor_not_found'} end
 if (record.owner or 'read_many')~=(owner or 'read_many') then return {error='batch_cursor_tool_changed'} end
 if record.scope~=scope then return {error='read_many_cursor_scope_changed'} end
 local original,err=artifact(record.ref,owner);if not original then return {error=err} end
 return page(original,scope,record.ref,record.first,owner)
end
return M
