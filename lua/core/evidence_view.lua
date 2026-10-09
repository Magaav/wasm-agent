-- An opt-in presentation, never a rewrite of stored history or the active conversation.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/tool_output.lua')
local M={}
-- Even an oversized row must expose why it failed, not just where to fetch it.
-- This is an exact excerpt of the LAST failed span; it is not a generated diagnosis.
function M.failure(row)
  local trace=row.trace
  if type(trace)=='string' then local ok,value=pcall(json.decode,trace);trace=ok and value or {} end
  local failed
  if type(trace)=='table' then
    for n=#trace,1,-1 do
      local span=trace[n]
      if type(span)=='table' and (span.ok==false or span.ok==0 or span.error~=nil) then failed=span;break end
    end
  end
  if not failed then return nil end
  local error=tostring(failed.error or '')
  -- Escaping-heavy errors still fit the smallest session page. Originals remain
  -- accessible through the reference; never imply this excerpt is the whole trace.
  local text=output.slice(error,1,192)
  return {kind=failed.kind,name=failed.name,model=failed.model,round=failed.round,ms=failed.ms,ok=failed.ok,
    error=text,error_bytes=#error,error_truncated=#text<#error,scope='last_failed_span_excerpt'}
end

function M.message(row)
  local view={}
  for _,key in ipairs({'id','seq','session_id','role','content','tool_call_id','tool_name','ok','ms','created_at','at','title','rank','user_id'}) do
    view[key]=row[key]
  end
  view.evidence={tool='session',session_id=row.session_id,message_id=row.id,view='full'}
  -- Point at the byte range whenever the row would not survive the model view, which is the
  -- projector's budget and not a number of its own.
  if #json.encode(row)>output.MAX_BYTES then view.evidence.byte_offset=1 end
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
