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

-- Match the node's existing request-body ceiling. This is a refusal boundary, not
-- an excuse to silently resize or recompress an image the model was asked to inspect.
local IMAGE_MAX_BYTES=4*1000*1000

-- `nil` means the path is not a supported image and the caller should continue
-- through the exact-text path. Every other return is a complete read outcome.
local function read_image(args,store_image)
  if not host.read_image_base64 then return nil end
  local called,raw=pcall(host.read_image_base64,args.path,IMAGE_MAX_BYTES)
  if not called then return {error='image_read_failed',path=args.path} end
  local decoded_ok,value=pcall(json.decode,tostring(raw or ''))
  if not decoded_ok or type(value)~='table' then
    return {error='invalid_image_read_response',path=args.path}
  end
  -- A Lua test shim or future virtual filesystem may satisfy `read_file` even
  -- when the native path does not exist, so missing joins not-image on the text
  -- fallback. If that also misses, the caller still returns `not_found`.
  if value.error=='not_image' or value.error=='not_found' then return nil end
  if value.error then
    value.path=value.path or args.path
    return value
  end
  if type(value.base64)~='string' or type(value.mime)~='string' then
    return {error='invalid_image_read_response',path=args.path}
  end
  if type(store_image)~='function' then
    return {error='image_storage_unavailable',path=args.path}
  end
  local name=args.path:match('[^/\\]+$') or args.path
  local stored_ok,reference,problem=pcall(store_image,{
    name=name,mime=value.mime,b64=value.base64,
  })
  if not stored_ok then return {error='image_store_failed',path=args.path} end
  if not reference then return {error=problem or 'image_store_failed',path=args.path} end
  if args.version and args.version~=reference.sha256 then
    return {error='file_changed',path=args.path,version=reference.sha256}
  end
  return {
    path=args.path,type='image',mime=reference.mime,bytes=reference.bytes,
    sha256=reference.sha256,version=reference.sha256,
    note='Image content is attached to this tool result.',
    -- Agent-only transport. It is removed before projection and persisted in the
    -- turn's images column, so base64 never enters the JSON tool result.
    _images={reference},
  }
end

function M.read(args,store_image)
  if type(args.path)~='string' or args.path=='' then return {error='path_required'} end
  local line=integer(args.offset,1,2147483647)
  local column=integer(args.column,1,2147483647)
  local limit=integer(args.limit,2000,2000)
  if not line or not column or not limit then return {error='invalid_read_range'} end
  local image=read_image(args,store_image)
  if image then return image end
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
  -- One budget for the model view, shared with the projector. The read page has to fit
  -- inside the same envelope `tool_output` enforces; otherwise an oversized page comes
  -- back "omitted" and the model loses the exact-cursor contract that makes pagination
  -- work at all. Deriving it here is what keeps the two from drifting apart again.
  local view_budget=output.MAX_BYTES
  local capacity=view_budget-2048
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
  while #json.encode(result)>view_budget and capacity>4 do
    capacity=math.floor(capacity/2);part,next_byte=output.slice(text:sub(1,last),first,capacity);result=envelope()
  end
  if #json.encode(result)>view_budget or (#part==0 and next_byte<=#text) then return {error='read_envelope_exceeds_budget',version=hash} end
  return result
end
-- `old_text` is quoted from memory, and the measured cause of a miss is *not* whitespace: in
-- 42 of 44 failures over 24h the anchor was in nothing the model had read, and in none of them
-- was it a whitespace difference. A hint keyed on the first line is therefore useless when the
-- first line is what was misremembered. Slide a window the size of the quoted block over the
-- file, score each position by the leading characters it shares line by line, and return the
-- best one with its exact bytes: the model re-quotes what is actually there and the edit lands
-- on the second attempt instead of costing a fresh read of the whole file.
local function nearest_edit_hint(text, needle)
  local target = {}
  for line in needle:gmatch("[^\r\n]+") do
    if line:match("%S") then target[#target + 1] = line end
  end
  -- A miss is not always a misquote. The same bytes with the other line ending do not match, and
  -- the file may be CRLF while the anchor was written with LF. Silently, that reads as "your
  -- anchor is not in the file", which sends the reader off to re-derive anchors that were right
  -- apart from the ending - measured here: four rounds lost to exactly that in one session. So
  -- normalise both sides once and, when that matches, say which ending the file uses. Normalising
  -- the *file* instead would rewrite the endings of every line the edit touched, which is a
  -- different change from the one that was asked for.
  local function as(value, eol) return (value:gsub("\r\n", "\n"):gsub("\n", eol)) end
  if not text:find(needle, 1, true) then
    for _, eol in ipairs({ "\r\n", "\n" }) do
      local alt = as(needle, eol)
      if alt ~= needle then
        local at = text:find(alt, 1, true)
        if at then
          local line = 1
          for _ in text:sub(1, at):gmatch("\n") do line = line + 1 end
          local last = line + select(2, alt:gsub("\n", ""))
          return { line = line, last_line = last, text = alt:sub(1, 400),
            note = "old_text is absent byte-for-byte, but the same text with " ..
              (eol == "\r\n" and "CRLF" or "LF") .. " line endings is present: this file's lines " ..
              "end that way. Re-send the edit with " .. (eol == "\r\n" and "\\r\\n" or "\\n") ..
              " line endings, or copy the bytes from read." }
        end
      end
    end
  end
  if #target == 0 then return nil end
  local function norm(value)
    return (value:gsub("%s+", " ")):gsub("^%s+", ""):gsub("%s+$", "")
  end
  for i = 1, #target do target[i] = norm(target[i]) end
  local have = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    have[#have + 1] = norm(line)
    if #have >= 8000 then break end
  end
  local span, best, best_score = #target, nil, 0
  for start = 1, math.max(1, #have - span + 1) do
    local score = 0
    for i = 1, span do
      local a, b = target[i], have[start + i - 1] or ""
      if a == "" then
        score = score + 1
      elseif a == b then
        score = score + 1000 + #a
      else
        local shared, limit = 0, math.min(#a, #b, 40)
        while shared < limit and a:sub(shared + 1, shared + 1) == b:sub(shared + 1, shared + 1) do
          shared = shared + 1
        end
        score = score + shared
      end
    end
    if score > best_score then best_score, best = score, start end
  end
  -- A blank-only overlap is not a candidate: a wrong hint is worse than silence.
  if not best or best_score <= span then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local last = math.min(#lines, best + span - 1)
  return { line = best, last_line = last,
    text = table.concat(lines, "\n", best, last):sub(1, 400),
    note = "no region matches old_text; this is the closest. Quote it exactly, or re-read the range with read and copy the bytes." }
end

-- The file's own line ending, and the same text written in it. A worktree form is not always the
-- form a file was written in: .gitattributes gives *.cmd/*.bat/*.ps1 CRLF on disk over an LF blob,
-- so an anchor quoted from the stored bytes misses by one carriage return per line. Reading the
-- file's ending here is what keeps that from being the caller's problem.
local function file_eol(text) return text:find("\r\n",1,true) and "\r\n" or "\n" end
local function in_eol(value, eol) return (value:gsub("\r\n","\n"):gsub("\n",eol)) end

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
    local ending_note=nil
    if not a then
      -- The same text with the file's own line endings is not a misquote, and refusing it made
      -- every patcher re-derive the ending by hand - which is how one file in this repository
      -- cost four rounds of anchors in a single session. Normalise both sides, and only accept a
      -- match that is unique, so an anchor that is genuinely wrong still fails.
      local eol=file_eol(text)
      local alt=in_eol(item.old_text,eol)
      if alt~=item.old_text then
        a,b=text:find(alt,1,true)
        if a then
          ending_note = eol=="\r\n" and "matched with this file's CRLF line endings"
            or "matched with this file's LF line endings"
          item={ old_text=alt, new_text=in_eol(item.new_text,eol), }
        end
      end
    end
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
