-- An opt-in presentation, never a rewrite of stored history or the active conversation.
local json=dofile('lua/vendor/json.lua')
local M={}
function M.message(row)
  local view={}
  for _,key in ipairs({'id','seq','session_id','role','content','tool_call_id','tool_name','ok','ms','created_at','at','title','rank','user_id'}) do
    view[key]=row[key]
  end
  view.evidence={tool='session',session_id=row.session_id,message_id=row.id,view='full'}
  if #json.encode(row)>20000 then view.evidence.byte_offset=1 end
  view.omitted_fields={'trace_details','tool_arguments','reasoning','images','changes','accounting'}
  local calls=row.tool_calls
  if type(calls)=='string' then local ok,decoded=pcall(json.decode,calls);calls=ok and decoded or {} end
  if type(calls)=='table' and #calls>0 then
    view.tool_calls={}
    for _,call in ipairs(calls) do
      local f=call['function'] or {}
      view.tool_calls[#view.tool_calls+1]={id=call.id,name=f.name,arguments_bytes=#tostring(f.arguments or '')}
    end
  end
  local trace=row.trace
  if type(trace)=='string' then local ok,decoded=pcall(json.decode,trace);trace=ok and decoded or {} end
  if type(trace)=='table' and #trace>0 then
    view.trace={}
    for _,span in ipairs(trace) do
      view.trace[#view.trace+1]={kind=span.kind,name=span.name,ok=span.ok,ms=span.ms,error=span.error,round=span.round}
    end
  end
  return view
end
function M.messages(rows)
  local views={};for i,row in ipairs(rows) do views[i]=M.message(row) end;return views
end
return M
