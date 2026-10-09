-- Explicit bounded inspection; originals remain in memory and are never rewritten.
local json = dofile('lua/vendor/json.lua')
local output = dofile('lua/core/tool_output.lua')
local evidence = dofile('lua/core/evidence_view.lua')
local M = {}

function M.exact(row,args)
  if args.byte_offset == nil then
    return {message=args.view=='compact' and evidence.message(row) or row}
  end
  local maximum=output.MAX_BYTES-2048
  local offset,limit=tonumber(args.byte_offset),tonumber(args.byte_limit) or maximum
  if not offset or offset<1 or offset%1~=0 or limit<4 or limit>maximum or limit%1~=0 then
    return {error='invalid_message_range'}
  end
  local encoded=json.encode(row)
  local version=host.sha256(encoded)
  if offset>#encoded+1 then return {error='message_range_out_of_bounds'} end
  if offset<=#encoded and encoded:byte(offset)>=128 and encoded:byte(offset)<192 then return {error='offset_inside_utf8'} end
  if args.message_version and args.message_version~=version then return {error='message_changed',message_version=version} end
  while true do
    local content,next_offset=output.slice(encoded,offset,limit)
    local page={content=content,encoding='exact_message_json',message_id=row.id,message_version=version,
      next_offset=next_offset,bytes=#encoded,eof=next_offset>#encoded}
    if #json.encode(page)<=output.MAX_BYTES or limit<=4 then return page end
    limit=math.max(4,math.floor(limit*0.75))
  end
end

local function reference(row,sid,id)
  local address={session_id=sid,message_id=row.id,byte_offset=1,view='full'}
  if id then address.tool='subagent';address.action='session';address.id=id else address.tool='session' end
  return {id=row.id,seq=row.seq,role=row.role,tool_name=row.tool_name,ok=row.ok,ms=row.ms,
    created_at=row.created_at,failure=evidence.failure(row),
    content='[Oversized message: retrieve the original using evidence.]',omitted=true,evidence=address}
end

local function bounded_rows(rows,sid,args,task,mode)
  local bytes=tonumber(args.byte_limit) or math.min(16000,output.MAX_BYTES-2048)
  if bytes<2048 or bytes>output.MAX_BYTES-2048 or bytes%1~=0 then return {error='invalid_session_byte_limit'} end
  local page={session_id=sid,messages={},view=args.view or 'full',mode=mode,returned=0,
    note='Originals unchanged. Oversized rows have exact-retrieval evidence.'}
  for _,row in ipairs(rows) do
    local item=args.view=='compact' and evidence.message(row) or row
    page.messages[#page.messages+1]=item;page.returned=#page.messages
    if #json.encode(page)>bytes then
      page.messages[#page.messages]=reference(row,sid,task and (args.id or task.subagent_id))
      if #json.encode(page)>bytes then return {error='session_batch_budget_too_small',requested=#rows} end
    end
  end
  return page
end

function M.get(memory,sid,args,task)
  args=args or {}
  if args.view~=nil and args.view~='full' and args.view~='compact' then return {error='invalid_view'} end
  local modes=(args.message_id and 1 or 0)+(args.message_ids and 1 or 0)+(args.around_seq~=nil and 1 or 0)
  if modes>1 or (modes>0 and (args.before_seq~=nil or args.after_seq~=nil)) or
      ((args.message_ids or args.around_seq~=nil) and (args.byte_offset~=nil or args.message_version~=nil)) then return {error='session_cursor_conflict'} end
  if args.around_seq==nil and (args.before~=nil or args.after~=nil) then return {error='session_window_anchor_required'} end
  if args.message_ids then
    local ids=args.message_ids
    if type(ids)~='table' or #ids<1 or #ids>20 then return {error='invalid_message_ids'} end
    for key,id in pairs(ids) do
      if type(key)~='number' or key%1~=0 or key<1 or key>#ids or type(id)~='string' then return {error='invalid_message_ids'} end
    end
    local rows,seen={},{}
    for _,id in ipairs(ids) do
      if seen[id] then return {error='duplicate_message_id'} end
      seen[id]=true
      local row=memory.message(id)
      if not row or row.session_id~=sid then return {error='unknown_message'} end
      rows[#rows+1]=row
    end
    table.sort(rows,function(a,b)return a.seq<b.seq end)
    return bounded_rows(rows,sid,args,task,'batch')
  end
  if args.around_seq~=nil then
    local seq,before,after=tonumber(args.around_seq),args.before or 2,args.after or 2
    if not seq or seq<1 or seq%1~=0 or type(before)~='number' or before<0 or before>20 or before%1~=0 or type(after)~='number' or after<0 or after>20 or after%1~=0 then return {error='invalid_session_window'} end
    local rows=memory.session_messages(sid,{around_seq=seq,before=before,after=after})
    local found=false;for _,row in ipairs(rows) do if row.seq==seq then found=true end end
    if not found then return {error='unknown_message'} end
    local page=bounded_rows(rows,sid,args,task,'around')
    if not page.error then
      page.around_seq=seq
      local bounds=memory.session_message_bounds(sid)
      local first,last=rows[1].seq,rows[#rows].seq
      page.has_more_before=first>bounds.first_seq;page.has_more_after=last<bounds.last_seq
      page.next_before_seq=page.has_more_before and first or nil
      page.next_after_seq=page.has_more_after and last or nil
      -- Include cursor overhead in the same encoded bound.
      if #json.encode(page)>(args.byte_limit or math.min(16000,output.MAX_BYTES-2048)) then return {error='session_batch_budget_too_small',requested=#rows} end
    end
    return page
  end
  if args.message_id then
    local row=memory.message(args.message_id)
    if not row or row.session_id~=sid then return {error='unknown_message'} end
    return M.exact(row,args)
  end
  local limit=tonumber(args.limit) or 8
  local bytes=tonumber(args.byte_limit) or math.min(16000,output.MAX_BYTES-2048)
  if limit<1 or limit>1000 or limit%1~=0 then return {error='invalid_session_page_limit'} end
  if bytes<1024 or bytes>output.MAX_BYTES-2048 or bytes%1~=0 then return {error='invalid_session_byte_limit'} end
  if args.before_seq~=nil and args.after_seq~=nil then return {error='session_cursor_conflict'} end
  local before,after=tonumber(args.before_seq),tonumber(args.after_seq)
  if (args.before_seq~=nil and (not before or before<1 or before%1~=0)) or
     (args.after_seq~=nil and (not after or after<0 or after%1~=0)) then return {error='invalid_session_cursor'} end
  local bounds=memory.session_message_bounds(sid)
  local rows=memory.session_messages(sid,{limit=limit,before_seq=before,after_seq=after,forward_after_seq=after~=nil})
  local page={session_id=sid,messages={},view=args.view or 'full',returned=0,
    note='Bounded inspection only; original transcript unchanged. Oversized rows have exact-retrieval evidence.'}
  if task then page.task={subagent_id=task.subagent_id,session_id=sid,state=task.state,settled=task.settled,
    profile=task.profile,model=task.model,reasoning=task.reasoning} end
  local function frame()
    local first=page.messages[1] and page.messages[1].seq
    local last=page.messages[#page.messages] and page.messages[#page.messages].seq
    page.returned=#page.messages
    page.has_more_before=first~=nil and bounds.first_seq~=nil and first>bounds.first_seq or false
    page.has_more_after=last~=nil and bounds.last_seq~=nil and last<bounds.last_seq or false
    page.next_before_seq=page.has_more_before and first or nil
    page.next_after_seq=page.has_more_after and last or nil
  end
  -- Latest/backward pages choose nearest rows first but always return chronological order.
  for n=1,#rows do
    local row=rows[after~=nil and n or (#rows-n+1)]
    local item=args.view=='compact' and evidence.message(row) or row
    local position=after~=nil and (#page.messages+1) or 1
    table.insert(page.messages,position,item);frame()
    if #json.encode(page)>bytes then
      page.messages[position]=reference(row,sid,task and (args.id or task.subagent_id));frame()
      if #json.encode(page)>bytes then
        table.remove(page.messages,position);frame()
        if #page.messages==0 then return {error='session_page_budget_too_small',minimum_bytes=2048} end
        break
      end
    end
  end
  frame()
  return page
end
return M
