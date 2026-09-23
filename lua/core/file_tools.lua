-- File mechanics only. Fresh bytes are read on every call; only their line index is cached.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/tool_output.lua')
local M={}
local cache,order,weight={}, {},0
local hits,builds,fallbacks=0,0,0
local VERSION='line-index-v1:lf-preserve-cr'
function M.cache_stats() return {entries=#order,index_bytes_estimate=weight,hits=hits,builds=builds,fallbacks=fallbacks,version=VERSION} end
local function index(text,hash)
  local key=VERSION..':'..hash
  if cache[key] then hits=hits+1;return cache[key] end
  builds=builds+1
  local starts={}
  if #text>0 then
    starts[1]=1
    for at in text:gmatch('()\n') do
      if at<#text then
        if #starts>=131072 then return nil end -- Do not build an unbounded index before deciding not to cache it.
        starts[#starts+1]=at+1
      end
    end
  end
  -- Bound both entries and approximate index storage. Never cache file contents or outcomes.
  local size=#starts*16
  if size<=2*1024*1024 then
    while #order>=16 or weight+size>2*1024*1024 do
      local old=table.remove(order,1);weight=weight-#cache[old]*16;cache[old]=nil
    end
    cache[key]=starts;order[#order+1]=key;weight=weight+size
  end
  return starts
end
local function integer(n,default,maximum)
  if n==nil then return default end
  if type(n)~='number' or n<1 or n%1~=0 or n>maximum then return nil end
  return n
end
function M.read(args)
  if type(args.path)~='string' or args.path=='' then return {error='path_required'} end
  local line=integer(args.offset,1,2147483647)
  local column=integer(args.column,1,2147483647)
  local limit=integer(args.limit,2000,2000)
  if not line or not column or not limit then return {error='invalid_read_range'} end
  local text=host.read_file(args.path)
  if not text then return {error='not_found',path=args.path} end
  local hash=host.sha256(text)
  if args.version and args.version~=hash then return {error='file_changed',path=args.path,version=hash} end
  local starts=index(text,hash)
  local total=starts and #starts or 0
  if not starts then
    fallbacks=fallbacks+1
    starts={}
    if #text>0 then
      total=1;if line==1 then starts[1]=1 end
      for at in text:gmatch('()\n') do
        if at<#text then
          total=total+1
          if total>=line and total<=line+limit then starts[total]=at+1 end
        end
      end
    end
  end
  if line>total+1 or (not starts[line] and column~=1) then return {error='read_range_out_of_bounds',version=hash} end
  local first=starts[line] or (#text+1)
  local finish=(starts[line+1] or (#text+1))-1
  if starts[line] and column>finish-first+1 then return {error='column_out_of_bounds',version=hash} end
  first=first+column-1
  if first<=#text and text:byte(first)>=128 and text:byte(first)<192 then return {error='column_inside_utf8',version=hash} end
  local last=(starts[line+limit] or (#text+1))-1
  -- JSON escaping, not just raw bytes, determines whether the outer tool view can retain the cursor.
  local capacity=48000
  local part,next_byte=output.slice(text:sub(1,last),first,capacity)
  local function envelope()
    local next_line=line
    while starts[next_line+1] and starts[next_line+1]<=next_byte do next_line=next_line+1 end
    if next_byte>#text then next_line=total+1 end
    local next_column=next_byte-(starts[next_line] or (#text+1))+1
    return {path=args.path,content=part,version=hash,offset=line,column=column,
      next_offset=next_line,next_column=next_column,eof=next_byte>#text,range_complete=next_byte>last,
      total_lines=total,bytes=#text,returned_bytes=#part,
      end_offset=#part>0 and (next_column==1 and next_line-1 or next_line) or nil,
      note='Raw text, no synthetic line numbering. Continue with next_offset, next_column and version.'}
  end
  local result=envelope()
  while #json.encode(result)>50000 and capacity>4 do
    capacity=math.floor(capacity/2);part,next_byte=output.slice(text:sub(1,last),first,capacity);result=envelope()
  end
  if #json.encode(result)>50000 or (#part==0 and next_byte<=#text) then return {error='read_envelope_exceeds_budget',version=hash} end
  return result
end
-- `old_text` is quoted from memory, and the usual reason it does not match is whitespace the
-- model cannot see: different indentation, a trailing space, CRLF. Locate the closest line and
-- hand back its exact bytes, so the correction is one step instead of a re-read of the file.
-- Bounded work: one pass over the lines, normalized comparison, no fuzzy library.
local function nearest_edit_hint(text, needle)
  local first
  for line in needle:gmatch("[^\r\n]+") do
    if line:match("%S") then first = line break end
  end
  if not first then return nil end
  local function norm(value)
    return (value:gsub("%s+", " ")):gsub("^%s+", ""):gsub("%s+$", "")
  end
  local wanted = norm(first)
  if wanted == "" then return nil end
  local number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if number > 50000 then break end
    local candidate = norm(line)
    if candidate ~= "" and (candidate == wanted or candidate:find(wanted, 1, true)) then
      return { line = number, text = line:sub(1, 200),
        note = "whitespace differs from old_text; quote this line exactly, or re-read the range" }
    end
  end
  return nil
end

function M.edit(args,record)
  if type(args.path)~='string' or args.path=='' then return {error='path_required'} end
  if args.edits and (args.old_text~=nil or args.new_text~=nil) then return {error='mixed_edit_forms'} end
  local allowed={path=true,version=true,edits=true,old_text=true,new_text=true}
  for key in pairs(args) do if not allowed[key] then return {error='unsupported_edit_option',option=key} end end
  local edits=args.edits or {{old_text=args.old_text,new_text=args.new_text}}
  if type(edits)~='table' or #edits<1 or #edits>64 then return {error='edits_required_1_to_64'} end
  for i=1,#edits do if edits[i]==nil then return {error='edits_must_be_dense_array'} end end
  for key in pairs(edits) do
    if type(key)~='number' or key%1~=0 or key<1 or key>#edits then return {error='edits_must_be_dense_array'} end
  end
  for i,item in ipairs(edits) do
    if type(item)~='table' or type(item.old_text)~='string' or item.old_text=='' then return {error='old_text_required',edit=i} end
    if type(item.new_text)~='string' then return {error='new_text_required',edit=i} end
    for key in pairs(item) do if key~='old_text' and key~='new_text' then return {error='unsupported_replacement_field',edit=i} end end
  end
  local text=host.read_file(args.path)
  if not text then return {error='not_found'} end
  local hash=host.sha256(text)
  if args.version and args.version~=hash then return {error='file_changed',version=hash} end
  local ranges={}
  for i,item in ipairs(edits) do
    local a,b=text:find(item.old_text,1,true)
    if not a then
      local failure={error='old_text_not_found',edit=i,path=args.path}
      local hint=nearest_edit_hint(text,item.old_text)
      if hint then failure.nearest=hint end
      return failure
    end
    -- Overlapping occurrences are ambiguous too (e.g. 'aa' in 'aaa').
    if text:find(item.old_text,a+1,true) then return {error='old_text_ambiguous',edit=i} end
    ranges[#ranges+1]={a=a,b=b,text=item.new_text,index=i}
  end
  table.sort(ranges,function(a,b)return a.a<b.a end)
  local parts,position={},1
  for _,r in ipairs(ranges) do
    if r.a<position then return {error='overlapping_edits',edit=r.index} end
    parts[#parts+1]=text:sub(position,r.a-1);parts[#parts+1]=r.text;position=r.b+1
  end
  parts[#parts+1]=text:sub(position)
  local updated=table.concat(parts)
  -- Detect intervening changes before writing. Not an OS-wide CAS against arbitrary editors.
  if host.read_file(args.path)~=text then return {error='file_changed_before_write'} end
  if updated==text then return {ok=true,path=args.path,edits=#ranges,version=hash,previous_version=hash,no_change=true} end
  if not host.write_file(args.path,updated) then return {ok=false,error='write_failed',path=args.path,outcome='unknown',note='Inspect the file before retrying.'} end
  if record then
    local ok=pcall(record,args.path,text,updated)
    if not ok then return {ok=false,error='edit_applied_but_record_failed',path=args.path,version=host.sha256(updated)} end
  end
  return {ok=true,path=args.path,edits=#ranges,previous_version=hash,version=host.sha256(updated)}
end
return M
