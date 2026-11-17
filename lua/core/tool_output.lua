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
-- The one surviving batch surface is `tool_call`'s `calls` form (1-8 known reads in one call): its
-- result keeps every item's outcome visible even when the whole answer exceeds the view budget.
local BATCH_OUTPUTS={tool_call=true}

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

-- The session's variables as the observation lists them: names and JSON sizes, never values
-- (`vars: laura (30 B) \194\183 inbox (12 KB)`), at most VARS_SHOWN names and then `+N more`.
M.VARS_SHOWN = 10
local function size_text(bytes)
  bytes = math.floor(tonumber(bytes) or 0)
  if bytes < 1024 then return bytes .. ' B' end
  local kb = bytes / 1024
  if kb < 10 then return (string.format('%.1f', kb):gsub('%.0$', '')) .. ' KB' end
  if kb < 1024 then return string.format('%d KB', math.floor(kb + 0.5)) end
  return string.format('%.1f MB', kb / 1024)
end
function M.vars_line(vars)
  if type(vars) ~= 'table' or #vars == 0 then return nil end
  local parts = {}
  for index, entry in ipairs(vars) do
    if index > M.VARS_SHOWN then parts[#parts + 1] = '+' .. (#vars - M.VARS_SHOWN) .. ' more'; break end
    parts[#parts + 1] = tostring(entry.name) .. ' (' .. size_text(entry.bytes) .. ')'
  end
  return table.concat(parts, ' \194\183 ')
end
-- The line read back: `{ {name=, size="30 B"} ... }` and how many more there were.
function M.parse_vars(line)
  if type(line) ~= 'string' then return nil end
  local list, more = {}, nil
  for part in (line .. ' \194\183 '):gmatch('(.-) \194\183 ') do
    local name, size = part:match('^(%S+) %((.-)%)$')
    if name then list[#list + 1] = { name = name, size = size }
    else more = tonumber(part:match('^%+(%d+) more$')) or more end
  end
  return list, more
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
  -- A script's model view is its outcome, not its bookkeeping (operator 14/11, "will that bloat and hurt
  -- reasoning?"): `summary` says each call's status in one line; `calls` stays, because its evidence
  -- references are what a model passes to tool_result to read a nested original (a real run did); the
  -- `attempts` array (arguments + results again, per call) and the constant backend/context_policy
  -- strings leave the view. The complete result is kept as a file, named by full_result.
  -- `summary` is nil when the script made no tool call (only helpers such as searchTools): that script's
  -- view is lean too (17/11, session b01db30e: a searchTools-only script answered with the whole 8 KB
  -- envelope - attempts, backend, result-file paths - instead of the schema it returned).
  if name=='codemode' and output.attempts~=nil and (output.summary~=nil or output.ok~=false) then
    local full = json.encode(output)
    local lean = {}
    for key, value in pairs(output) do
      if key~='attempts' and key~='backend' and key~='context_policy'
          and not (key=='unexecuted' and type(value)=='table' and next(value)==nil)
          and not (key=='items' and type(value)=='table' and next(value)==nil) then lean[key]=value end
    end
    lean.vars = M.vars_line(output.vars)
    -- What the script returned, as what it is: an object, named `returned` (14/11: a script that did
    -- `return r` saw `value: "{\"candidates\":...}"`, a JSON string, and the next scripts read r.value from
    -- the TOOL as if every tool answered {value}).
    if type(lean.value) == 'string' then
      local parsed_ok, parsed = pcall(json.decode, lean.value)
      lean.returned = parsed_ok and parsed ~= nil and parsed or lean.value
      lean.value = nil
    elseif lean.value ~= nil then
      lean.returned = lean.value; lean.value = nil
    end
    -- Evidence the model can use, and only that (14/11: the per-call path, bytes, id and ok were 9% of
    -- what a real run read). `sha256` is what tool_result / results.get take, `bytes` says whether it is
    -- worth fetching; status says ok.
    if type(lean.calls) == 'table' then
      local light = {}
      for i, call in ipairs(lean.calls) do
        if type(call) ~= 'table' then light[i] = call else
          local evidence = type(call.evidence) == 'table' and call.evidence or {}
          local item = {}
          for key, value in pairs(call) do
            if key ~= 'id' and key ~= 'ok' and key ~= 'evidence' then item[key] = value end
          end
          item.sha256 = item.sha256 or evidence.sha256
          item.bytes = item.bytes or evidence.bytes
          light[i] = item
        end
      end
      lean.calls = light
    end
    local ref = M.store(full)
    lean.full_result = {sha256=ref.sha256, bytes=#full}
    -- A script's result is a header and EXACTLY what the script returned - raw text, or compact JSON - with
    -- no wrapper key around it (14/11 replay: a view key named `value`, then `returned`, was read back as
    -- the shape of the TOOL's answer: r.value, r.returned.messages, "cannot read property 'messages'").
    -- Line 1: status, the per-call summary, where the whole result is; line 2: each call's evidence
    -- (sha256:bytes, the order of the summary). Failures keep their structured error; a result carrying
    -- anything else (printed output, a partial presentation) keeps the JSON form.
    local plain = { ok = true, status = true, summary = true, returned = true, calls = true, full_result = true, sandbox_calls = true, vars = true }
    local simple = lean.ok ~= false and lean.error == nil
    for key in pairs(lean) do if not plain[key] then simple = false end end
    if simple then
      local header = 'status ' .. tostring(lean.status or 200) .. (lean.summary and (' \194\183 ' .. tostring(lean.summary)) or '')
        .. ' \194\183 full_result ' .. ref.sha256
      local evidence = {}
      for _, call in ipairs(type(lean.calls) == 'table' and lean.calls or {}) do
        if type(call) == 'table' and call.sha256 then evidence[#evidence + 1] = call.sha256 .. ':' .. tostring(call.bytes or 0) end
      end
      if #evidence > 0 then header = header .. '\ncalls: ' .. table.concat(evidence, ' ') end
      -- The session's variables, names and sizes only (`vars.<name>` in a script reads one back).
      if lean.vars then header = header .. '\nvars: ' .. lean.vars end
      local body
      if lean.returned == nil then body = '(the script returned nothing)'
      elseif type(lean.returned) == 'string' then body = lean.returned
      else body = json.encode(lean.returned) end
      local room = M.MAX_BYTES - #header - 160
      if #body > room then
        body = body:sub(1, room) .. '\n[cut at ' .. room .. ' of ' .. #body .. ' bytes: the whole result is tool_result({sha256:"' .. ref.sha256 .. '"})]'
      end
      return header .. '\n\n' .. body
    end
    output = lean
  end
  -- A script view in the JSON form names its variables in the same words as the header line.
  if name == 'codemode' and type(output.vars) == 'table' then
    local copy = {}
    for key, value in pairs(output) do copy[key] = value end
    copy.vars = M.vars_line(output.vars)
    output = copy
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
  if BATCH_OUTPUTS[name] and type(output.results)=='table' and #encoded>M.MAX_BYTES then
    -- Keep every slot's outcome visible even when a batch exceeds the total
    -- budget. Raw items and the whole response remain exactly retrievable.
    local batch={}
    for key,value in pairs(output) do if key~='results' then batch[key]=value end end
    batch.results={};batch.omitted=true;batch.full_result=M.store(encoded)
    batch.note='Batch exceeded the total view budget; omitted items retain exact full_result JSON. Retrieve an omitted item before using its content or continuation.'
    local per_item=math.floor((M.MAX_BYTES-4096)/math.max(1,#output.results))
    for i,item in ipairs(output.results) do
      local original=json.encode(item)
      if #original<=per_item then batch.results[i]=item else
        local view={omitted=true,full_result=M.store(original)}
        for _,key in ipairs({'ok','error','path','outcome','applied','executed','effect','no_change','count','complete','has_more','returned'}) do view[key]=item[key] end
        batch.results[i]=view
      end
    end
    local bounded=json.encode(batch)
    if #bounded<=M.MAX_BYTES then return bounded end
    -- Refuse to hide an unusually large outcome: generic exact-artifact fallback.
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
-- The one reader of a stored script view (both forms): the JSON object, or - for a script that returned
-- text - {status, summary, full_result = {sha256}, returned = <the text>} read back from the header line,
-- plus `vars` ({ {name, size} }) and `vars_more` when the observation listed session variables.
function M.parse_view(content)
  content = tostring(content or "")
  local ok, decoded = pcall(json.decode, content)
  if ok and type(decoded) == "table" then
    if type(decoded.vars) == "string" then decoded.vars, decoded.vars_more = M.parse_vars(decoded.vars) end
    return decoded
  end
  local first, rest = content:match("^(status %d+[^\n]*)\n(.*)$")
  if not first then return nil end
  -- After line 1: an optional `calls:` line, an optional `vars:` line, a blank line, the script's text.
  local body = rest
  local evidence = body:match("^calls: ([^\n]*)\n")
  if evidence then body = body:sub(#evidence + 9) end
  local varsline = body:match("^vars: ([^\n]*)\n")
  if varsline then body = body:sub(#varsline + 8) end
  local text = body:match("^\n(.*)$") or body
  local vars, vars_more = M.parse_vars(varsline)
  local status = tonumber(first:match("^status (%d+)"))
  local sha = first:match("full_result (%x+)$")
  local summary = first:match("^status %d+ \194\183 (.-) \194\183 full_result %x+$")
  local calls = {}
  local parts = {}
  if summary then for part in (summary .. " \194\183 "):gmatch("(.-) \194\183 ") do parts[#parts + 1] = part end end
  local index = 0
  for hash, bytes in (evidence or ""):gmatch("(%x+):(%d+)") do
    index = index + 1
    local name, code = (parts[index] or ""):match("^(%S+) (%d+)")
    calls[index] = { name = name, status = tonumber(code), sha256 = hash, bytes = tonumber(bytes) }
  end
  local decoded_ok, decoded = pcall(json.decode, text)
  local returned = (decoded_ok and decoded ~= nil) and decoded or text
  return { ok = true, status = status, summary = summary, full_result = sha and { sha256 = sha } or nil, calls = calls, returned = returned, vars = vars, vars_more = vars_more }
end

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

-- Only a proven pre-admission steering fence is cancellation, never an unknown/failed effect.
function M.cancelled(output)
  return type(output)=='table' and output.error=='superseded_by_steering'
    and output.executed==false and output.effect=='none'
    and (output.ok==nil or output.ok==false) and output.code==nil
end

function M.outcome(name, output)
  if type(output) ~= "table" then return true end
  if output.error ~= nil or output.ok == false then return false end
  -- grep's no-match exit is a valid search result, not a transport failure.
  if name == "grep" and tonumber(output.code) == 1 then return true end
  return output.code == nil or tonumber(output.code) == 0
end

return M
