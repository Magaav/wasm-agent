-- On-demand lexical discovery over canonical transcripts; never rewrites history.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/tool_output.lua')
local evidence=dofile('lua/core/evidence_view.lua')
local M={}
local retrieval={'search_messages','session','sessions','resume_session','recall','memories','search_ledger','conversation','list_conversations','tool_result'}
local roles={user=true,assistant=true,tool=true,summary=true,retry=true,system=true}
local function query(sql,params)
  local result=host.sql_query(sql,json.encode(params or {}))
  if type(result)=='string' then result=json.decode(result) end
  if result.error then error(result.error) end
  return result
end
local function integer(value,default,minimum,maximum)
  if value==nil then return default end
  if type(value)~='number' or value%1~=0 or value<minimum or value>maximum then return nil end
  return value
end
local function ref(row)
  return {tool='session',session_id=row.session_id,message_id=row.id,view='full',byte_offset=1}
end
-- SQLite snippet chooses a contiguous matching token window. Keep its original bytes,
-- not highlighted/normalized text; instr supplies canonical Unicode character addressing.
local function preview(row,terms)
  local text=row.excerpt or ''
  local max=1000
  local from=1
  if #text>max then
    local lower=text:lower()
    local best
    for _,term in ipairs(terms) do
      local at=lower:find(term:lower(),1,true)
      if at and (not best or at<best) then best=at end
    end
    from=math.max(1,(best or 1)-250)
  end
  local part,next_offset=output.slice(text,from,max)
  -- slice aligns to UTF-8; locate the actual aligned start for exact coordinates.
  local start=text:find(part,from,true) or from
  local chars_before=utf8.len(text:sub(1,start-1)) or 0
  local count=utf8.len(part) or 0
  local position=(tonumber(row.excerpt_start) or 1)+chars_before
  return {id=row.id,session_id=row.session_id,seq=row.seq,title=row.title,role=row.role,
    tool_name=row.tool_name,created_at=row.created_at,rank=row.rank,content=part,
    content_bytes=row.content_bytes,excerpt_start=position,excerpt_end=position+count-1,
    omitted=position>1 or next_offset<=#text or row.content_bytes>#part,
    evidence=ref(row),reason='fts_'..row.match,matched_terms=terms}
end
function M.search(memory,args,user_id)
  args=args or {}
  local started=host.now()
  local scope=args.scope or 'dialogue'
  local view=args.view or 'snippets'
  local group=args.group_by or 'session'
  local sort=args.sort or 'relevance'
  local match=args.match or 'terms'
  if scope~='dialogue' and scope~='evidence' and scope~='all' then return {error='invalid_search_scope'} end
  if view~='snippets' and view~='full' and view~='compact' then return {error='invalid_view'} end
  if group~='session' and group~='message' then return {error='invalid_search_group'} end
  if sort~='relevance' and sort~='newest' then return {error='invalid_search_sort'} end
  if match~='terms' and match~='phrase' then return {error='invalid_search_match'} end
  local limit=integer(args.limit,20,1,50)
  local offset=integer(args.offset,0,0,1000000)
  local budget=integer(args.byte_limit,math.min(16000,output.MAX_BYTES-2048),2048,output.MAX_BYTES-2048)
  if not limit or not offset or not budget then return {error='invalid_search_range'} end
  if type(args.query)~='string' or #args.query>4096 then return {error='invalid_search_query'} end
  local text=args.query
  local expression=match=='phrase' and ('"'..text:gsub('"','""')..'"') or memory.fts_query(text)
  local terms={}
  for term in text:gmatch('[^%s%p]+') do terms[#terms+1]=term end
  local page={matches={},scope=scope,view=view,group_by=group,sort=sort,match=match,
    returned=0,has_more=false,limit_reached=false,preview_only=view=='snippets',
    snapshot_policy='live_ranking',note='Originals preserved. Excerpts are discovery, not settlement; use evidence or session around_seq. Pagination follows live ranks, not a frozen snapshot.'}
  if #terms==0 then page.search_ms=(host.now()-started)*1000;return page end
  local where={'messages_fts MATCH ?'};local params={expression}
  local function condition(sql,value) where[#where+1]=sql;params[#params+1]=value end
  if user_id and user_id~='' then condition('s.user_id=?',user_id) end
  if scope=='dialogue' then
    where[#where+1]="t.role IN ('user','assistant') AND NOT (t.role='user' AND substr(t.content,1,17)='[Sentinel notice]')"
  elseif scope=='evidence' then
    where[#where+1]="t.role='tool'"
    local names={};for _,name in ipairs(retrieval) do names[#names+1]='?';params[#params+1]=name end
    where[#where+1]='t.tool_name NOT IN ('..table.concat(names,',')..')'
  end
  for _,field in ipairs({'session_id','tool_name'}) do
    if args[field]~=nil then
      if type(args[field])~='string' or #args[field]>1024 then return {error='invalid_search_filter:'..field} end
      condition('t.'..field..'=?',args[field])
    end
  end
  if args.roles~=nil then
    if type(args.roles)~='table' or #args.roles<1 or #args.roles>6 then return {error='invalid_search_roles'} end
    local names={}
    for key,role in pairs(args.roles) do
      if type(key)~='number' or key%1~=0 or key<1 or key>#args.roles or not roles[role] then return {error='invalid_search_roles'} end
    end
    for _,role in ipairs(args.roles) do names[#names+1]='?';params[#params+1]=role end
    where[#where+1]='t.role IN ('..table.concat(names,',')..')'
  end
  for _,field in ipairs({'after','before'}) do
    local value=args[field]
    if value~=nil then
      if type(value)~='number' or value~=value or math.abs(value)==math.huge or value<0 then return {error='invalid_search_date'} end
      condition('t.created_at'..(field=='after' and '>=?' or '<=?'),value)
    end
  end
  if args.after and args.before and args.after>args.before then return {error='invalid_search_date_range'} end
  local order=sort=='newest' and 'created_at DESC,id ASC' or 'rank ASC,created_at DESC,id ASC'
  local base='SELECT messages_fts.rowid AS fts_rowid,t.id,t.session_id,t.seq,t.role,t.tool_name,t.created_at,s.title,bm25(messages_fts) AS rank FROM messages_fts JOIN messages t ON t.id=messages_fts.message_id JOIN sessions s ON s.id=t.session_id WHERE '..table.concat(where,' AND ')
  local sql='WITH matched AS MATERIALIZED ('..base..') '
  if group=='session' then
    sql=sql..',diverse AS (SELECT *,row_number() OVER (PARTITION BY session_id ORDER BY '..order..') AS session_hit FROM matched) SELECT * FROM diverse WHERE session_hit<=2'
  else sql=sql..'SELECT * FROM matched' end
  sql=sql..' ORDER BY '..order..' LIMIT ? OFFSET ?'
  params[#params+1]=limit+1;params[#params+1]=offset
  local candidates=query(sql,params)
  if view=='snippets' and #candidates>0 then
    local placeholders={};local body_params={expression}
    for i=1,math.min(limit,#candidates) do placeholders[#placeholders+1]='?';body_params[#body_params+1]=candidates[i].fts_rowid end
    local bodies=query("SELECT t.id,CASE WHEN length(CAST(t.content AS BLOB))<=1000 THEN t.content ELSE snippet(messages_fts,0,'','','',32) END AS excerpt,length(CAST(t.content AS BLOB)) AS content_bytes,CASE WHEN length(CAST(t.content AS BLOB))<=1000 THEN 1 ELSE instr(t.content,snippet(messages_fts,0,'','','',32)) END AS excerpt_start FROM messages_fts JOIN messages t ON t.id=messages_fts.message_id WHERE messages_fts MATCH ? AND messages_fts.rowid IN ("..table.concat(placeholders,',')..')',body_params)
    local byid={};for _,body in ipairs(bodies) do byid[body.id]=body end
    for i=1,math.min(limit,#candidates) do
      local row=candidates[i];local body=assert(byid[row.id],'search_source_disappeared')
      for k,v in pairs(body) do row[k]=v end
      row.match=match
      -- A noncontiguous/tokenizer-altered snippet must never claim exact coordinates.
      if row.excerpt_start==0 and row.excerpt~='' then error('search_excerpt_not_in_original') end
      candidates[i]=preview(row,terms)
    end
  else
    for i=1,math.min(limit,#candidates) do
      local meta=candidates[i];local row=memory.message(meta.id)
      if not row or row.session_id~=meta.session_id then error('search_source_disappeared') end
      row.title=meta.title;row.rank=meta.rank
      candidates[i]=view=='compact' and evidence.message(row) or row
    end
  end
  for i=1,math.min(limit,#candidates) do
    local item=candidates[i]
    page.matches[#page.matches+1]=item;page.returned=#page.matches
    page.has_more=#candidates>page.returned
    page.next_offset=page.has_more and offset+page.returned or nil
    if #json.encode(page)>budget-256 then
      if view~='snippets' then
        page.matches[#page.matches]={id=item.id,session_id=item.session_id,seq=item.seq,role=item.role,tool_name=item.tool_name,
          content='[Oversized message: retrieve the original using evidence.]',omitted=true,evidence=ref(item)}
      end
      if #json.encode(page)>budget-256 then table.remove(page.matches);break end
    end
  end
  page.returned=#page.matches;page.has_more=#candidates>page.returned
  page.next_offset=page.has_more and offset+page.returned or nil
  page.limit_reached=page.returned==limit
  page.search_ms=(host.now()-started)*1000
  if page.returned==0 and #candidates>0 then return {error='search_page_budget_too_small'} end
  return page
end
return M
