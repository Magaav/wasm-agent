-- Opt-in native presentation, not a read cache or an authority boundary.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/tool_output.lua')
local contract=dofile('lua/core/json_contract.lua')
local redact=dofile('lua/core/redact.lua')
local M={}
M.help={name='showCall',version=1,description='await showCall({version:1,call:N}) selects the Nth admitted native call for a sanitized structured model view without text(JSON) escaping. Redaction flags distinguish this view from private exact originals; the journal remains retained. Partial views name exact unread byte ranges; an answer that carries a `results` array (a peer batch) keeps its own next_cursor on the native result. Does not execute, retry, refresh, or edit. See docs/CODEMODE.md.',parameters={type='object',properties={version={type='integer',enum={1}},call={type='integer',minimum=1}},required={'version','call'},additionalProperties=false}}
local function exact(ref,keymap)
 local raw=host.read_file(ref.path)
 if not raw or #raw~=ref.bytes or host.sha256(raw)~=ref.sha256 then error('codemode_presentation_evidence_changed') end
 local tree,err=contract.parse(raw);if not tree then error(err) end
 -- All strings are traversable by privacy boundaries; only payload-free
 -- empty-object/null tags are needed. Original bytes stay in the evidence.
 return contract.materialize(tree,keymap),raw,tree
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
local function sanitized(result,key_redacted)
 local view,hits=redact.value(result)
 view.presentation_sanitized=true
 view.presentation_redacted=next(hits)~=nil or key_redacted==true
 view.presentation_key_redacted=key_redacted==true or nil
 view.presentation_redactions=next(hits)~=nil and hits or nil
 return view
end
local function size(result,key_redacted)return #json.encode(sanitized(result,key_redacted)) end
function M.finish(result,selected)
 if #selected==0 then return result end
 local key_redacted=false
 local function keymap(key)
  local clean=redact.secrets(key);if clean~=key then key_redacted=true end;return clean
 end
 result.presentation_version=1;result.shown={}
 for _,n in ipairs(selected)do
  local call=result.calls[n];local value=exact(call.evidence,keymap)
  result.shown[#result.shown+1]={call=n,name=call.name,complete=true,result=value,evidence=call.evidence}
 end
 -- Measure the actual encoded sanitized model-facing object, including labels.
 -- Never clip source/receipt text to fit; legitimate redaction is explicit.
 if size(result,key_redacted)<=output.MAX_BYTES then return sanitized(result,key_redacted) end
 local full=output.store(json.encode(result))
 result.presentation_partial=true;result.full_result=full
 result.presentation_note='PARTIAL presentation: unread entries retain exact native result byte ranges. Use tool_result(sha256,offset,limit), following next_offset; do not rerun the script. A paged batch keeps its own next_cursor on the native result. complete describes sanitized captured result visibility, not file EOF or successful effects.'
 -- Pack whole results from any native answer that carries a top-level `results` ARRAY - a peer's
 -- `remote {capability:"batch"}`, a router batch, a plugin's own list - preserving ALL page metadata
 -- (including failures, late notes, outcomes and cached continuation). No tool NAME is special-cased:
 -- the retired `*_many` tools used to be the only producer, and a script's own loop cannot produce one,
 -- so the shape is what decides, not the name.
 local packs={}
 for i,entry in ipairs(result.shown)do
  local _,raw,tree=exact(entry.evidence,keymap)
  local decoded=json.decode(raw);local nodes=contract.at(tree,{'results'})
  if type(decoded)=='table' and nodes and nodes.kind=='array' then
   local metadata={}
   for _,k in ipairs(tree.keys)do if k~='results' then
    local mapped=keymap(k);if metadata[mapped]~=nil then error('json_materialize_key_collision')end
    metadata[mapped]=contract.materialize(tree.children[k],keymap)
   end end
   entry.result=nil;entry.metadata=metadata;entry.results={};entry.coverage={};entry.complete=false
   for j,node in ipairs(nodes.children)do
    local slot={index=(decoded.first_index or 1)+j-1,visible=false,unread={sha256=entry.evidence.sha256,offset=node.first,bytes=node.last-node.first+1}}
    local item=decoded.results[j]
    if type(item)=='table' then
     for _,key in ipairs({'ok','error','effect','outcome','applied','executed','unknown','partial','not_run','path'})do
      local field=node.children and node.children[key]
      if field then slot[key]=contract.materialize(field,keymap) end
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
    entry.results[j]=contract.materialize(node,keymap)
    local coverage=entry.coverage[j];coverage.visible=true;coverage.unread=nil
    if size(result,key_redacted)>output.MAX_BYTES then
     entry.results[j]=nil;coverage.visible=false;coverage.unread={sha256=entry.evidence.sha256,offset=node.first,bytes=node.last-node.first+1};break
    end
   end
   local all=true;for _,slot in ipairs(entry.coverage)do if not slot.visible then all=false end end;entry.complete=all
 end
 -- An unusually large journal/metadata/guest output may itself exceed the budget.
 -- Never pretend its omitted errors/effects or remaining caveats were reviewed.
 if size(result,key_redacted)>output.MAX_BYTES then
  return sanitized({ok=result.ok,error=result.error,presentation_version=1,presentation_partial=true,full_result=full,
   note='PARTIAL: entire captured presentation (including call outcomes, effects and exact native-original references) requires tool_result retrieval. Never replay effects to recover output.',
   unread={sha256=full.sha256,offset=1,bytes=full.bytes}},key_redacted)
 end
 return sanitized(result,key_redacted)
end
-- `searchTools("select:searchTools")` answers this: the shape of the guest's own discovery, in one place
-- so the prompt example and the answer cannot disagree (#119). It is a plain ARRAY of entries, and the
-- one form the model must remember is what each entry looks like.
M.searchtools_help = {
  name = "searchTools",
  description = "Discovery over this script's own catalogue, in ONE shape: every form answers a plain ARRAY of entries {name, description, parameters, schema, execution, callable, route}. searchTools(\"*\") (or no argument, or \"\") lists the catalogue, paged with {limit, offset} (default 50, max 200); a listing entry is {name, description, execution, callable, route} with no schema. searchTools(query, {limit}) returns the best keyword matches (default 8, max 8). searchTools({names=[...]}) or searchTools(\"select:a,b,c\") is an exact batch of 1-8 names, in the order asked for, each with its full schema. A name this script cannot see is a member of the same array - {name, found:false, reason, suggestions:[...]} - never a throw, so .map always works. The guest's own names (searchTools, results, showCall) are selectable the same way and carry their help as the entry's schema. Every call is metadata only: it loads and admits nothing.",
  shape = { { name = "<tool name>", description = "<one line>", parameters = { type = "object" }, schema = { ["function"] = { name = "<tool name>" } }, callable = true, route = "<only when callable is false: where it runs instead>", execution = { status = "available" } }, { name = "<unknown name>", found = false, reason = "no name like '<unknown name>' in this script's catalogue", suggestions = { "<nearest permitted name>" } } },
}

return M
