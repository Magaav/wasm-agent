local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
memory.setup()
local view=dofile('lua/core/session_view.lua')
local sid=memory.start_session('','bounded',{user_id='owner'})
for i=1,24 do memory.append_turn(sid,{role='user',content=i==23 and string.rep('é\\"',30000) or ('row '..i)}) end
local task={subagent_id='child',session_id=sid,state='completed',settled=true}
local function page(args)
  local p=view.get(memory,sid,args,task)
  assert(not p.error,json.encode(p))
  assert(#json.encode(p)<=(args.byte_limit or 16000),'encoded page bound')
  for i=2,#p.messages do assert(p.messages[i].seq>p.messages[i-1].seq,'chronological order') end
  return p
end
local p=page({limit=8,byte_limit=2048})
assert(p.messages[#p.messages].seq==24 and p.next_before_seq,'latest page keeps newest row and cursor')
local seen={}
repeat
  for _,row in ipairs(p.messages) do assert(not seen[row.seq],'no duplicate');seen[row.seq]=true end
  if not p.next_before_seq then break end
  p=page({before_seq=p.next_before_seq,limit=8,byte_limit=2048})
until false
for i=1,24 do assert(seen[i],'backward cursor skipped '..i) end
local after=0;seen={}
repeat
  p=page({after_seq=after,limit=5,byte_limit=2048})
  for _,row in ipairs(p.messages) do assert(row.seq==after+1,'forward cursor skipped');after=row.seq;seen[after]=true end
  if not p.has_more_after then break end
until false
assert(after==24,'forward traversal complete')
p=page({before_seq=24,limit=1,byte_limit=2048})
local ref=p.messages[1].evidence
assert(ref and ref.message_id and ref.tool=='subagent','exact child evidence pointer')
local parts,offset,version={},1,nil
repeat
  local r=view.get(memory,sid,{message_id=ref.message_id,byte_offset=offset,message_version=version,byte_limit=2048},task)
  assert(not r.error and r.next_offset>offset,'exact page advances')
  parts[#parts+1]=r.content;offset=r.next_offset;version=r.message_version
  if r.eof then break end
until false
assert(table.concat(parts)==json.encode(memory.message(ref.message_id)),'byte exact recovery')
assert(memory.message_count(sid)==24,'no transcript modification')
assert(view.get(memory,sid,{after_seq='bad'},task).error=='invalid_session_cursor')
assert(view.get(memory,sid,{after_seq=0,before_seq=3},task).error=='session_cursor_conflict')
assert(view.get(memory,'other',{message_id=ref.message_id},task).error=='unknown_message')
-- Regression: an enormous compact failure used to lose its entire trace when
-- replaced by the oversized envelope (observed production seq829).
local failure_sid=memory.start_session('','failure-envelope',{user_id='owner'})
local trace={}
for n=1,60 do trace[#trace+1]={kind='model_call',model='fixture',ms=1000,ok=true,round=n}end
trace[#trace+1]={kind='model_call',model='fixture',ms=111236,ok=false,error='UND_ERR_SOCKET: other side closed'}
memory.append_turn(failure_sid,{role='assistant',content=string.rep('large output',3000),ok=false,trace=trace})
local failed_id=memory.session_messages(failure_sid,{limit=1})[1].id
local original=json.encode(memory.message(failed_id))
for _,mode in ipairs({'compact','full'})do
 local preview=view.get(memory,failure_sid,{limit=1,byte_limit=2048,view=mode})
 assert(not preview.error and #json.encode(preview)<=2048,'failure page bound')
 local failed=preview.messages[1]
 assert(failed.omitted and failed.ok==0 and failed.failure and failed.failure.error=='UND_ERR_SOCKET: other side closed','oversized row retains exact failure')
 assert(failed.failure.ms==111236 and failed.failure.model=='fixture' and failed.failure.scope=='last_failed_span_excerpt','failure timing and scope')
 assert(failed.evidence.message_id==failed_id and failed.evidence.byte_offset==1,'full original address retained')
end
local large_error=string.rep('é\\"',1000)
local ev=dofile('lua/core/evidence_view.lua').failure({trace={{ok=false,error=large_error}}})
assert(ev.error_truncated and ev.error_bytes==#large_error and utf8.len(ev.error),'long errors are explicit UTF8 excerpts')
assert(json.encode(memory.message(failed_id))==original,'original trace/content unchanged')
print('session view ok')
