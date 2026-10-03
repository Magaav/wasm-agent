-- Pi-style bounded model views with the complete output available as a file.
-- Projection is done once when the result is produced, and persisted unchanged.
--
-- The budget stays at 50 KiB, and that is a decision rather than an omission. 16 KiB was
-- measured on the navigation fixture with the arms *interleaved* (4 pairs, so a slow provider
-- minute cannot favour one arm): ~6% fewer tokens and ~11% fewer calls, every answer correct.
-- That is a real saving, and it is not evidence that the task result never degrades - one
-- fixture, four pairs, one model. A smaller view is less context for the model to reason with,
-- so the default keeps the bytes and the knob is there for an operator who wants the trade:
-- WASM_AGENT_TOOL_OUTPUT_BYTES. Prefer raw over compacted unless the loss is proven harmless.
--
-- What this change did keep is that the budget is now *one* number: the read page, the session
-- byte page, the evidence pointer and this note all derive from it, where each previously
-- hardcoded its own 50,000 or 20,000 and silently disagreed with the projector.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local M = {MAX_BYTES=50*1024, MAX_LINES=2000}
-- An operator may tighten the per-result budget. The complete output is kept as an artifact
-- either way, so a smaller view costs bytes and never data - but it can cost a *round*, and in
-- a large session one extra round costs more than the bytes it saved. The default is therefore
-- unchanged until an A/B says otherwise; this is the knob that measures it.
local configured_bytes = tonumber(host.getenv("WASM_AGENT_TOOL_OUTPUT_BYTES"))
if configured_bytes and configured_bytes >= 4096 and configured_bytes <= 4 * 1024 * 1024 then
  M.MAX_BYTES = math.floor(configured_bytes)
end
local legacy_views,legacy_count={},0

function M.slice(text, from, count)
  text = tostring(text or "")
  from = math.max(1, math.floor(tonumber(from) or 1))
  local last = math.min(#text, from + math.max(1,math.floor(count or M.MAX_BYTES)) - 1)
  while from <= #text and (text:byte(from) or 0) >= 128 and (text:byte(from) or 0) < 192 do from=from+1 end
  while last < #text and (text:byte(last+1) or 0) >= 128 and (text:byte(last+1) or 0) < 192 do last=last-1 end
  return text:sub(from,last), last + 1
end

function M.store(text)
  local hash = host.sha256(text)
  local path = paths.data() .. "/tool-results/" .. hash .. ".txt"
  if host.read_file(path) ~= text then
    if not host.write_file(path, text) then error("tool_output_store_failed:" .. path) end
  end
  return {sha256=hash,path=path,bytes=#text}
end

function M.read(id, offset, limit)
  if type(id) ~= "string" or #id ~= 64 or id:find("[^0-9a-fA-F]") then return {error="invalid_output_id"} end
  local path = paths.data() .. "/tool-results/" .. id:lower() .. ".txt"
  local text = host.read_file(path)
  if not text then return {error="output_not_found"} end
  if host.sha256(text) ~= id:lower() then return {error="output_hash_mismatch"} end
  -- Bound the *encoded view*, not the raw slice. The model sees the JSON of this table, and
  -- escaping inflates it - a slice of `\"` roughly doubles - so a slice sized to the budget
  -- produced a view over it, which the projector replaced with the omitted envelope. That lost
  -- `next_offset`, which is the whole point of this route: the caller could no longer page. Same
  -- discipline `file_tools.read` already uses for its pages.
  local budget = M.MAX_BYTES
  local want = math.max(4, math.min(tonumber(limit) or budget, budget))
  while true do
    local part, next_offset = M.slice(text, offset, want)
    local page = {content=part,offset=tonumber(offset) or 1,next_offset=next_offset,bytes=#text,
      eof=next_offset>#text,sha256=id:lower()}
    if #json.encode(page) <= budget then return page end
    if want <= 4 then return {error="output_page_exceeds_budget"} end
    want = math.floor(want * 0.75)
  end
end

function M.truncate(text, tail)
  text = tostring(text or "")
  local lines = {}
  for line in (text.."\n"):gmatch("(.-)\n") do lines[#lines+1]=line end
  if #text<=M.MAX_BYTES and #lines<=M.MAX_LINES then return text,false end
  local from = tail and math.max(1,#lines-M.MAX_LINES+1) or 1
  local to = tail and #lines or math.min(#lines,M.MAX_LINES)
  local selected = table.concat(lines,"\n",from,to)
  if #selected>M.MAX_BYTES then
    selected=M.slice(selected,tail and (#selected-M.MAX_BYTES+1) or 1,M.MAX_BYTES)
  end
  return selected,true
end

local function output_note()
  return "The model view is bounded to 2000 lines / " .. math.floor(M.MAX_BYTES / 1024) ..
    " KiB in total. Full original JSON is stored at full_result.path; use tool_result with its sha256 and byte offset to retrieve any part."
end

local function preview_view(name, output, encoded, ref)
  local view={tool=name,code=output.code,ok=output.ok,error=output.error,
    full_result=ref,omitted=true,note=output_note()}
  local capacity=M.MAX_BYTES-1024
  repeat
    local from=(name=="bash" or name=="shell") and math.max(1,#encoded-capacity+1) or 1
    view.preview=M.slice(encoded,from,capacity)
    if #json.encode(view)<=M.MAX_BYTES then return json.encode(view) end
    capacity=math.floor(capacity*.75)
  until capacity<1
  error("tool_output_envelope_exceeds_budget")
end

local function session_view(output, ref)
  if type(output.messages)~="table" then return nil end
  local session={}
  for key,value in pairs(output.session or {}) do session[key]=value end
  if type(session.summary)=="string" and #session.summary>8192 then
    session.summary=M.slice(session.summary,1,8192)
    session.summary_omitted=true
  end
  local view={session=session,messages={},note=output.note,full_result=ref,omitted=true,
    view_omitted_messages=#output.messages,view_note="Newest returned messages shown; use next_before_seq for earlier messages or tool_result for the exact original.",
    next_before_seq=output.next_before_seq}
  for index=#output.messages,1,-1 do
    table.insert(view.messages,1,output.messages[index])
    view.view_omitted_messages=index-1
    view.next_before_seq=view.messages[1].seq
    if #json.encode(view)>M.MAX_BYTES then
      table.remove(view.messages,1)
      view.view_omitted_messages=index
      view.next_before_seq=view.messages[1] and view.messages[1].seq or output.next_before_seq
      break
    end
  end
  if #view.messages==0 and #output.messages>0 then
    local latest=output.messages[#output.messages]
    view.latest_turn={seq=latest.seq,role=latest.role,id=latest.id,session_id=latest.session_id,
      evidence={tool='session',session_id=latest.session_id,message_id=latest.id,byte_offset=1,view='full'},
      preview=M.slice(json.encode(latest),1,8192)}
  end
  local encoded=json.encode(view)
  if #encoded<=M.MAX_BYTES then return encoded end
  return nil
end

function M.project(name, output)
  -- Encode a non-table only through pcall: a decoded scalar can be `inf` (a numeric
  -- literal too large for a float), and json.encode throws on that *before* the
  -- non-table branch below could handle it. A stored result of 16 KB of digits is
  -- enough to reach this, and the context build must not die on it.
  if type(output) ~= "table" then
    local encodable, encoded = pcall(json.encode, output)
    if not encodable then encoded = tostring(output) end
    if #encoded<=M.MAX_BYTES then return encoded end
    return preview_view(name,{},encoded,M.store(encoded))
  end
  local encoded = json.encode(output)
  -- A native read page already obeys both limits and carries a byte-exact cursor. A trailing
  -- newline is not a 2001st line; re-truncating here would skip bytes on the next page.
  if name=='read' and output.version and output.next_column and type(output.content)=='string'
      and output.returned_bytes==#output.content and #encoded<=M.MAX_BYTES then return encoded end
  -- A tool result can be a JSON *array*, not only an object. The envelope added below
  -- (full_result/omitted/note) has nowhere to live on an array: copying it into `view`
  -- and then setting those string keys builds a table with both numeric and string
  -- keys, which json.encode refuses outright - so the whole context build fails and
  -- the thread cannot move at all. An `operation` result that was a list did exactly
  -- that. A large array therefore takes the bounded textual preview a non-object
  -- result already gets, with the exact bytes kept in full_result; one that fits needs
  -- no envelope and is returned as-is by the length check below.
  local array = true
  for key in pairs(output) do
    if type(key) ~= "number" then array = false break end
  end
  if array and #encoded > M.MAX_BYTES then
    return preview_view(name, output, encoded, M.store(encoded))
  end
  local view = {}
  for key,value in pairs(output) do view[key]=value end
  local changed=false
  for _, key in ipairs({"stdout","stderr","content"}) do
    if type(view[key]) == "string" then
      local clipped, truncated=M.truncate(view[key],name=="bash" or name=="shell")
      view[key]=clipped; changed=changed or truncated
    end
  end
  if not changed and #encoded<=M.MAX_BYTES then return encoded end
  local ref=M.store(encoded)
  view.full_result=ref
  view.omitted=true
  view.note=output_note()
  if #json.encode(view)<=M.MAX_BYTES then return json.encode(view) end
  -- Preserve head-for-read / tail-for-shell after adding the artifact envelope.
  if changed then
    for _,key in ipairs({"stdout","stderr","content"}) do
      if type(view[key])=="string" and #view[key]>M.MAX_BYTES-2048 then
        local size=M.MAX_BYTES-2048
        local from=(name=="bash" or name=="shell") and math.max(1,#view[key]-size+1) or 1
        view[key]=M.slice(view[key],from,size)
      end
    end
    if #json.encode(view)<=M.MAX_BYTES then return json.encode(view) end
  end
  if name=="session" then
    local bounded=session_view(output,ref)
    if bounded then return bounded end
  end
  return preview_view(name,output,encoded,ref)
end

-- Older transcripts may contain a pre-budget nested result. Rebuild only its
-- model-facing view; never rewrite the ledger row. Cache the projection so a
-- long run does not reparse and rehash the same stored evidence every round.
function M.context_view(name, content)
  content=tostring(content or "")
  if #content<=M.MAX_BYTES then return content end
  local key=host.sha256(tostring(name or "").."\0"..content)
  if legacy_views[key] then return legacy_views[key] end
  local ok,decoded=pcall(json.decode,content)
  local view
  -- A tool result is not always JSON: a bare number too large for a float decodes to `inf`,
  -- and a non-table is not a result that can be projected. Preview the original bytes
  -- instead of handing a scalar to the projector.
  if ok and type(decoded)=="table" then
    if type(decoded)=="table" and type(decoded.full_result)=="table" then
      local ref=decoded.full_result
      local id=ref.sha256
      local valid=type(id)=="string" and #id==64 and not id:find("[^0-9a-fA-F]")
      local original=valid and host.read_file(paths.data().."/tool-results/"..id:lower()..".txt") or nil
      if original and host.sha256(original)==id:lower() then
        local read_ok,full=pcall(json.decode,original)
        if read_ok then decoded=full end
      end
    end
    view=M.project(name,decoded)
  else
    view=preview_view(name,{},content,M.store(content))
  end
  if legacy_count>=32 then legacy_views,legacy_count={},0 end
  legacy_views[key]=view; legacy_count=legacy_count+1
  return view
end

-- Native execution phase timing is aggregate telemetry on a call that settled on its own: it
-- would spend context on every shell line, and the same numbers are reported by the tool span.
-- A call that was *killed by its bound* is the exception. There the phases are the whole account
-- of where the time went, and dropping them is what left a reader with a sentence it could not
-- check - an agent read a deadline, found no breakdown anywhere in the result, and carried the
-- error message's invented cause onward as a finding. So: report the timing either way, and take
-- it out of the model-facing result only when the call was not terminated.
local BOUND_ERRORS = {
  deadline_exceeded = true, operation_supervisor_overdue = true,
  cleanup_incomplete = true, output_incomplete = true, output_limit_exceeded = true,
}

function M.execution_timing(name, output)
  if type(output) ~= "table" then return nil end
  local timing = output.timing
  if type(timing) ~= "table" then return nil end
  if name ~= "bash" and name ~= "shell" then return timing end
  if output.overdue == true or BOUND_ERRORS[output.error] then return timing end
  output.timing = nil
  return timing
end

function M.outcome(name, output)
  if type(output) ~= "table" then return true end
  if output.error ~= nil or output.ok == false then return false end
  -- grep's no-match exit is a valid search result, not a transport failure.
  if name == "grep" and tonumber(output.code) == 1 then return true end
  return output.code == nil or tonumber(output.code) == 0
end

return M
