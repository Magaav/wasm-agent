-- Offline contract probe of the actual production projector. No model or runtime policy switch.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/tool_output.lua')
local mode=host.getenv('WA_VIEW_PROBE')
assert(mode=='read' or mode=='tail','probe mode must be read or tail')
local head='HEAD_EVIDENCE_7f19'
local tail='TAIL_EVIDENCE_c392'
local lines={head}
for i=1,4000 do lines[#lines+1]=string.format('line %04d: exact evidence; quotes " and unicode café 日本語',i) end
lines[#lines+1]=tail
local text=table.concat(lines,'\n')
local name=mode=='read' and 'read' or 'bash'
local original=mode=='read' and {path='synthetic-fixture.txt',content=text} or {code=1,ok=false,stdout=text,stderr='fixture failure'}
local raw=json.encode(original)
local view=output.project(name,original)
assert(host.sha256(raw)~=host.sha256(view),'invalid comparison: identical original and projected payloads')
assert(#view<=output.MAX_BYTES,'model view exceeds actual production byte limit')
local decoded=json.decode(view)
assert(decoded.omitted==true and decoded.full_result,'missing omission or original reference')
local selected=(mode=='read' and decoded.content or decoded.stdout) or decoded.preview
assert(type(selected)=='string','fixture requires an explicit text field or documented JSON preview')
assert(utf8.len(selected),'view split a UTF-8 character')
if mode=='read' then
  assert(selected:find(head,1,true) and not selected:find(tail,1,true),'read must keep head evidence')
else
  assert(selected:find(tail,1,true) and not selected:find(head,1,true),'shell must keep tail evidence')
  assert(not output.outcome(name,decoded),'projection masked a failing command')
end
local pieces,cursor,pages={},1,0
repeat
  local page=output.read(decoded.full_result.sha256,cursor,8192)
  assert(not page.error and page.next_offset>cursor,'artifact retrieval failed or stopped advancing')
  pieces[#pieces+1]=page.content;cursor=page.next_offset;pages=pages+1
until page.eof
assert(table.concat(pieces)==raw,'retained original is not byte-exact')
-- A tool result is not always an object: `operation list` returns a JSON array, and a
-- large one used to brick the session because the envelope cannot live on an array
-- without making a mixed table json.encode refuses. Assert the array case is bounded
-- and still retrievable byte for byte.
local array={}
for i=1,4000 do array[i]={index=i,detail='exact evidence; quotes " and unicode café 日本語'} end
local array_raw=json.encode(array)
local array_view=output.project('operation',array)
assert(#array_view<=output.MAX_BYTES,'array view exceeds the production byte limit')
local array_decoded=json.decode(array_view)
assert(array_decoded.omitted==true and array_decoded.full_result,'an array view must reference its original')
local array_pieces,array_cursor,array_pages={},1,0
repeat
  local page=output.read(array_decoded.full_result.sha256,array_cursor,8192)
  assert(not page.error and page.next_offset>array_cursor,'array artifact retrieval failed or stopped advancing')
  array_pieces[#array_pieces+1]=page.content;array_cursor=page.next_offset;array_pages=array_pages+1
until page.eof
assert(table.concat(array_pieces)==array_raw,'array original is not byte-exact')
-- A negative control, NOT a claimed legacy runtime arm or a model-quality experiment.
local lossy=text:sub(1,600)
assert(not lossy:find(tail,1,true),'negative control must actually omit the target')
print(json.encode({schema='wasm-agent.tool-view-probe/v1',mode=mode,
  original_bytes=#raw,view_bytes=#view,original_sha256=host.sha256(raw),view_sha256=host.sha256(view),
  distinct_payloads=true,exact_original_roundtrip=true,artifact_pages=pages,
  view_encoding=decoded.preview and 'json_excerpt' or 'text_field',
  head_visible=selected:find(head,1,true)~=nil,tail_visible=selected:find(tail,1,true)~=nil,
  synthetic_head600_loses_tail=true,model_calls=0,
  array_view_bytes=#array_view,array_projection_bounded=true,array_original_roundtrip=true,array_artifact_pages=array_pages,
  scope='projection and retrieval contract only; not task quality, token counts or measured savings'}))
