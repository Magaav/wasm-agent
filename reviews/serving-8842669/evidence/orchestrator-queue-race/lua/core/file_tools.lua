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

-- A read selection is a stateless receipt, not a set of coordinates for the model to edit.
-- The binding catches a changed field before it can become a different source range; the file
-- version and selected-content digest are checked again against fresh bytes at edit time.
local RECEIPT_TAG='sel1'
local function selection_receipt(path,version,start_byte,end_byte,start_line,end_line,content_sha)
  local fields=table.concat({RECEIPT_TAG,host.sha256(path),version,tostring(start_byte),
    tostring(end_byte),tostring(start_line),tostring(end_line),content_sha},':')
  return fields..':'..host.sha256(fields..'\0'..path)
end

local function parse_selection_receipt(receipt,path)
  local tag,path_sha,version,start_byte,end_byte,start_line,end_line,content_sha,binding=
    receipt:match('^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)$')
  local function digest(value) return type(value)=='string' and #value==64 and not value:find('[^0-9a-f]') end
  if tag~=RECEIPT_TAG or not digest(path_sha) or not digest(version) or not digest(content_sha)
      or not digest(binding) then
    return nil,'selection_receipt_invalid'
  end
  if path_sha~=host.sha256(path) then return nil,'selection_path_mismatch' end
  local fields=table.concat({tag,path_sha,version,start_byte,end_byte,start_line,end_line,content_sha},':')
  if binding~=host.sha256(fields..'\0'..path) then return nil,'selection_receipt_modified' end
  start_byte,end_byte,start_line,end_line=tonumber(start_byte),tonumber(end_byte),tonumber(start_line),tonumber(end_line)
  if not start_byte or start_byte%1~=0 or not end_byte or end_byte%1~=0 or
      not start_line or start_line%1~=0 or not end_line or end_line%1~=0 or
      start_byte<1 or end_byte<=start_byte or start_line<1 or end_line<start_line then
    return nil,'selection_receipt_invalid'
  end
  return {path=path,version=version,start_byte=start_byte,end_byte=end_byte,
    start_line=start_line,end_line=end_line,sha256=content_sha}
end

-- The line a byte sits on, counting from 1. `edit` uses it to say which lines it actually replaced:
-- a caller that addressed a range by line number has no other way to see that it hit the lines it
-- meant, and a wrong-but-in-bounds range is otherwise indistinguishable from a right one.
local function line_of(text,byte)
  local line=1
  for _ in text:sub(1,math.max(byte-1,0)):gmatch('\n') do line=line+1 end
  return line
end

-- One recognisable line of what a range held: whitespace collapsed, bounded, never a newline. The
-- echo exists to be *seen*, so it has to survive the tool envelope on one line.
local function snippet(value)
  return (value:gsub('%s+',' '):gsub('^ ','')):sub(1,120)
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
    local result={path=args.path,content=part,version=hash,offset=line,column=column,
      next_offset=next_line,next_column=next_column,eof=next_byte>#text,range_complete=next_byte>last,
      total_lines=total,bytes=#text,returned_bytes=#part,
      end_offset=#part>0 and (next_column==1 and next_line-1 or next_line) or nil,
      note='Raw text, no synthetic line numbering. Continue with next_offset, next_column and version.'}
    -- A complete whole-line read is also a durable edit address. It is opaque so the model
    -- cannot accidentally trim byte coordinates while retaining the digest for the wider page.
    if column==1 and next_byte>last and #part>0 and line<=total then
      result.selection=selection_receipt(args.path,hash,first,last+1,line,result.end_offset,host.sha256(part))
      -- The frame the receipt addresses, in the open. An edit inside a receipt is addressed by these
      -- numbers, the page is deliberately unnumbered, and counting them by eye is how a caller lands
      -- on the wrong lines. These are the same two numbers the receipt carries.
      result.edit_lines={start_line=line,end_line=result.end_offset}
      result.note=result.note..' Copy selection unchanged into edit; start_line/end_line are inclusive lines inside edit_lines.'
    end
    return result
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

-- Return the one newline representation present in a byte range. A range with both LF and
-- CRLF (or a bare CR) has no safe implicit representation: normalising it would make an edit
-- change bytes the caller did not describe.
local function range_eol(text)
  local without_crlf,crlf=text:gsub("\r\n","")
  local lf=without_crlf:find("\n",1,true)~=nil
  local bare_cr=without_crlf:find("\r",1,true)~=nil
  if bare_cr or (crlf>0 and lf) then return nil,'mixed_line_endings' end
  if crlf>0 then return "\r\n" end
  if lf then return "\n" end
  return nil,'no_line_ending'
end

local function dense_array(value,maximum)
  if type(value)~='table' or #value>maximum then return false end
  for key in pairs(value) do
    if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end
  end
  for i=1,#value do if value[i]==nil then return false end end
  return true
end

function M.edit(args,record)
  if type(args.path)~='string' or args.path=='' then return {error='path_required'} end
  local range_form=args.range_edits~=nil
  local legacy_form=args.edits~=nil or args.old_text~=nil or args.new_text~=nil
  if range_form and legacy_form then return {error='mixed_edit_forms'} end
  if args.edits and (args.old_text~=nil or args.new_text~=nil) then return {error='mixed_edit_forms'} end
  local allowed={path=true,version=true,range_edits=true,edits=true,old_text=true,new_text=true}
  for key in pairs(args) do if not allowed[key] then return {error='unsupported_edit_option',option=key} end end
  local edits=args.range_edits or args.edits or {{old_text=args.old_text,new_text=args.new_text}}
  if not dense_array(edits,64) or #edits<1 then return {error='edits_required_1_to_64'} end
  if range_form then
    for i,item in ipairs(edits) do
      if type(item)~='table' or (type(item.selection)~='string' and type(item.selection)~='table') then
        return {error='selection_required',edit=i}
      end
      if not dense_array(item.replacement_lines,2000) then return {error='replacement_lines_must_be_dense_array',edit=i} end
      if (item.start_line==nil)~=(item.end_line==nil) then return {error='selection_line_range_requires_both',edit=i} end
      if item.start_line~=nil and (not integer(item.start_line,nil,2147483647) or not integer(item.end_line,nil,2147483647)) then
        return {error='invalid_selection_line_range',edit=i}
      end
      for key in pairs(item) do
        if key~='selection' and key~='replacement_lines' and key~='start_line' and key~='end_line' then
          return {error='unsupported_range_edit_field',edit=i}
        end
      end
      for line,value in ipairs(item.replacement_lines) do
        if type(value)~='string' then return {error='replacement_line_must_be_string',edit=i,line=line} end
        if value:find("\r",1,true) or value:find("\n",1,true) then
          return {error='replacement_line_contains_newline',edit=i,line=line}
        end
      end
    end
  else
    for i,item in ipairs(edits) do
      if type(item)~='table' or type(item.old_text)~='string' or item.old_text=='' then return {error='old_text_required',edit=i} end
      if type(item.new_text)~='string' then return {error='new_text_required',edit=i} end
      for key in pairs(item) do if key~='old_text' and key~='new_text' then return {error='unsupported_replacement_field',edit=i} end end
    end
  end
  local text=host.read_file(args.path)
  if not text then return {error='not_found'} end
  local hash=host.sha256(text)
  if args.version and args.version~=hash then
    return {error=range_form and 'stale_selection' or 'file_changed',version=hash}
  end
  local ranges={}
  for i,item in ipairs(edits) do
    if range_form then
      local selection
      if type(item.selection)=='string' then
        local problem
        selection,problem=parse_selection_receipt(item.selection,args.path)
        if not selection then
          return {error=problem,edit=i,note='Copy read.selection unchanged. Use start_line/end_line to target a subset; never edit the receipt.'}
        end
      else
        -- Compatibility for calls already present in transcripts and mixed-version peers. New
        -- model schemas expose only opaque string receipts, but a rollout must not strand a live
        -- session merely because it learned the preceding object form.
        selection=item.selection
        local selection_allowed={path=true,version=true,start_byte=true,end_byte=true,sha256=true}
        for key in pairs(selection) do
          if not selection_allowed[key] then return {error='unsupported_selection_field',edit=i,field=key} end
        end
        if selection.path~=args.path then return {error='selection_path_mismatch',edit=i} end
      end
      if type(selection.version)~='string' or selection.version=='' then return {error='selection_version_required',edit=i} end
      if args.version and selection.version~=args.version then return {error='selection_version_mismatch',edit=i} end
      if selection.version~=hash then return {error='stale_selection',edit=i,version=hash} end
      local a,b=selection.start_byte,selection.end_byte
      if type(a)~='number' or a%1~=0 or type(b)~='number' or b%1~=0 or
          a<1 or b<=a or b>#text+1 or type(selection.sha256)~='string' then
        return {error='invalid_selection',edit=i}
      end
      local selected=text:sub(a,b-1)
      if host.sha256(selected)~=selection.sha256 then
        return {error='selection_hash_mismatch',edit=i,
          note='The selection coordinates were changed without a matching receipt. Copy read.selection unchanged and use start_line/end_line for a subset.'}
      end
      if not selection.start_line then
        local first_line=1
        for _ in text:sub(1,a-1):gmatch('\n') do first_line=first_line+1 end
        local count=1
        for at in selected:gmatch('()\n') do if at<#selected then count=count+1 end end
        selection.start_line,selection.end_line=first_line,first_line+count-1
      end
      local target=selected
      if item.start_line~=nil then
        if item.start_line>item.end_line or item.start_line<selection.start_line or item.end_line>selection.end_line then
          return {error='selection_line_range_out_of_bounds',edit=i,
            selection_start_line=selection.start_line,selection_end_line=selection.end_line,
            note='Use start_line/end_line inside the returned selection, or read the needed lines again.'}
        end
        local starts={1}
        for at in selected:gmatch('()\n') do if at<#selected then starts[#starts+1]=at+1 end end
        if #starts~=selection.end_line-selection.start_line+1 then return {error='selection_receipt_invalid',edit=i} end
        local first=item.start_line-selection.start_line+1
        local last=item.end_line-selection.start_line+1
        local relative_a=starts[first]
        local relative_b=starts[last+1] or (#selected+1)
        a=a+relative_a-1;b=selection.start_byte+relative_b-1
        target=text:sub(a,b-1)
      end
      local eol,eol_error=range_eol(target)
      if eol_error=='mixed_line_endings' then return {error='selection_mixed_line_endings',edit=i} end
      if not eol then
        eol,eol_error=range_eol(text)
        if eol_error=='mixed_line_endings' then return {error='selection_eol_ambiguous',edit=i} end
        eol=eol or "\n"
      end
      local replacement=table.concat(item.replacement_lines,eol)
      if target:sub(-1)=="\n" and #item.replacement_lines>0 then replacement=replacement..eol end
      ranges[#ranges+1]={a=a,b=b-1,text=replacement,index=i,target=target}
    else
      local a,b=text:find(item.old_text,1,true)
      if not a then
        -- The same text with the file's own line endings is not a misquote, and refusing it made
        -- every patcher re-derive the ending by hand - which is how one file in this repository
        -- cost four rounds of anchors in a single session. Normalise both sides, and only accept a
        -- match that is unique, so an anchor that is genuinely wrong still fails.
        local eol=file_eol(text)
        local alt=in_eol(item.old_text,eol)
        if alt~=item.old_text then
          a,b=text:find(alt,1,true)
          if a then item={ old_text=alt, new_text=in_eol(item.new_text,eol), } end
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
      ranges[#ranges+1]={a=a,b=b,text=item.new_text,index=i,target=text:sub(a,b)}
    end
  end
  table.sort(ranges,function(a,b)return a.a<b.a end)
  local parts,position={},1
  for _,r in ipairs(ranges) do
    if r.a<position then return {error='overlapping_edits',edit=r.index} end
    parts[#parts+1]=text:sub(position,r.a-1);parts[#parts+1]=r.text;position=r.b+1
  end
  parts[#parts+1]=text:sub(position)
  local updated=table.concat(parts)
  -- What each range actually replaced, so the caller can see the address it hit instead of assuming it.
  -- A slice inside a receipt is in-bounds or refused and never diagnosed: the receipt proves the page,
  -- not the part of it the caller meant. No refusal can catch a wrong-but-in-bounds slice, so this echo
  -- is the evidence, and reading it is part of using the form.
  local replaced={}
  for _,r in ipairs(ranges) do
    local first_line=line_of(text,r.a)
    local last_line=line_of(text,r.b)
    local body=r.target:sub(-1)=='\n' and r.target:sub(1,-2) or r.target
    replaced[#replaced+1]={edit=r.index,first_line=first_line,last_line=last_line,
      lines=last_line-first_line+1,bytes=#r.target,sha256=host.sha256(r.target),
      first=snippet(body:match('^[^\r\n]*') or ''),last=snippet(body:match('[^\r\n]*$') or '')}
  end
  -- Detect intervening changes before writing. Not an OS-wide CAS against arbitrary editors.
  if host.read_file(args.path)~=text then return {error='file_changed_before_write'} end
  if updated==text then return {ok=true,path=args.path,edits=#ranges,version=hash,previous_version=hash,no_change=true,replaced=replaced} end
  if not host.write_file(args.path,updated) then return {ok=false,error='write_failed',path=args.path,outcome='unknown',note='Inspect the file before retrying.'} end
  if record then
    local ok=pcall(record,args.path,text,updated)
    if not ok then return {ok=false,error='edit_applied_but_record_failed',path=args.path,version=host.sha256(updated)} end
  end
  return {ok=true,path=args.path,edits=#ranges,previous_version=hash,version=host.sha256(updated),replaced=replaced}
end
return M
