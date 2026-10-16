-- Opt-in native presentation, not a read cache or an authority boundary.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/tool_output.lua')
local contract=dofile('lua/core/json_contract.lua')
local M={}
M.help={name='showCall',version=1,description='await showCall({version:1,call:N}) selects the Nth admitted native call for structured, budget-aware output without text(JSON) escaping. Complete originals and journal remain retained. Partial views name exact unread byte ranges; read_many next_cursor resumes cached later results. Does not execute, retry, refresh, or edit. See docs/CODEMODE.md.',parameters={type='object',properties={version={type='integer',enum={1}},call={type='integer',minimum=1}},required={'version','call'},additionalProperties=false}}
local function exact(ref)
 local raw=host.read_file(ref.path)
 if not raw or #raw~=ref.bytes or host.sha256(raw)~=ref.sha256 then error('codemode_presentation_evidence_changed') end
 local tree,err=contract.parse(raw);if not tree then error(err) end
 -- Keep typed null/object/array JSON exactly, including nested values.
 return setmetatable({}, {__json_raw=raw}),raw,tree
end
function M.select(calls,selected,params)
 if type(params)~='table' or params.version~=1 or type(params.call)~='number' or params.call%1~=0 or params.call<1 or not calls[params.call] then
  return {error='showCall_requires_version_1_and_admitted_call_index'},false
 end
 for k in pairs(params)do if k~='version' and k~='call' then return {error='showCall_unknown_option'},false end end
 for _,n in ipairs(selected)do if n==params.call then return {ok=true,call=n,already_selected=true},true end end
 selected[#selected+1]=params.call
 return {ok=true,call=params.call,presentation='structured-v1'},true
end
function M.finish(result,selected)
 if #selected==0 then return result end
 result.presentation_version=1;result.shown={}
 for _,n in ipairs(selected)do
  local call=result.calls[n];local value=exact(call.evidence)
  result.shown[#result.shown+1]={call=n,name=call.name,complete=true,result=value,evidence=call.evidence}
 end
 -- Measure the actual encoded outer model-facing object, not JS characters or
 -- raw file bytes. Never shorten source/receipt text to make a view fit.
 if #json.encode(result)<=output.MAX_BYTES then return result end
 local full=output.store(json.encode(result))
 result.presentation_partial=true;result.full_result=full
 result.presentation_note='PARTIAL presentation: unread entries retain exact native result byte ranges. Use tool_result(sha256,offset,limit), following next_offset; do not rerun the script. Cached later read_many results still use next_cursor. complete describes captured result visibility, not file EOF or successful effects.'
 -- Pack whole results from each read_many page, preserving ALL page metadata
 -- (including failures, late notes, outcomes and cached continuation).
 local packs={}
 for i,entry in ipairs(result.shown)do
  local _,raw,tree=exact(entry.evidence)
  local decoded=json.decode(raw);local nodes=contract.at(tree,{'results'})
  if entry.name=='read_many' and type(decoded)=='table' and nodes and nodes.kind=='array' then
   -- Preserve metadata with its exact JSON shape, not decode/re-encode nulls.
   local pieces={};for _,k in ipairs(tree.keys or {})do if k~='results' then pieces[#pieces+1]=json.encode(k)..':'..contract.raw(raw,tree.children[k]) end end
   local metadata=setmetatable({}, {__json_raw='{'..table.concat(pieces,',')..'}'})
   entry.result=nil;entry.metadata=metadata;entry.results={};entry.coverage={};entry.complete=false
   for j,node in ipairs(nodes.children)do
    local slot={index=(decoded.first_index or 1)+j-1,visible=false,unread={sha256=entry.evidence.sha256,offset=node.first,bytes=node.last-node.first+1}}
    local item=decoded.results[j]
    if type(item)=='table' then
     for _,key in ipairs({'ok','error','effect','outcome','applied','executed','unknown','partial','not_run','path'})do
      local field=node.children and node.children[key]
      if field then slot[key]=setmetatable({}, {__json_raw=contract.raw(raw,field)}) end
     end
    end
    entry.coverage[j]=slot
   end
   packs[#packs+1]={entry=entry,raw=raw,nodes=nodes}
  else
   entry.result=nil;entry.complete=false;entry.unread={sha256=entry.evidence.sha256,offset=1,bytes=entry.evidence.bytes}
  end
 end
 for _,pack in ipairs(packs)do
   local entry,raw,nodes=pack.entry,pack.raw,pack.nodes
   for j,node in ipairs(nodes.children)do
    entry.results[j]=setmetatable({}, {__json_raw=contract.raw(raw,node)})
    local coverage=entry.coverage[j];coverage.visible=true;coverage.unread=nil
    if #json.encode(result)>output.MAX_BYTES then
     entry.results[j]=nil;coverage.visible=false;coverage.unread={sha256=entry.evidence.sha256,offset=node.first,bytes=node.last-node.first+1};break
    end
   end
   local all=true;for _,slot in ipairs(entry.coverage)do if not slot.visible then all=false end end;entry.complete=all
 end
 -- An unusually large journal/metadata/guest output may itself exceed the budget.
 -- Never pretend its omitted errors/effects or remaining caveats were reviewed.
 if #json.encode(result)>output.MAX_BYTES then
  return {ok=result.ok,error=result.error,presentation_version=1,presentation_partial=true,full_result=full,
   note='PARTIAL: entire exact script result (including call outcomes, effects, selected data and journal references) requires tool_result retrieval. Never replay effects to recover output.',
   unread={sha256=full.sha256,offset=1,bytes=full.bytes}}
 end
 return result
end
return M
