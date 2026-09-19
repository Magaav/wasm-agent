-- Pi-style bounded model views with the complete output available as a file.
-- Projection is done once when the result is produced, and persisted unchanged.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local M = {MAX_BYTES=50*1024, MAX_LINES=2000}

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
  local part, next_offset = M.slice(text, offset, math.max(4,math.min(tonumber(limit) or M.MAX_BYTES,M.MAX_BYTES)))
  return {content=part,offset=tonumber(offset) or 1,next_offset=next_offset,bytes=#text,
    eof=next_offset>#text,sha256=id:lower()}
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

function M.project(name, output)
  local encoded = json.encode(output)
  if type(output) ~= "table" then return encoded end
  local view = {}
  for key,value in pairs(output) do view[key]=value end
  local changed=false
  for _, key in ipairs({"stdout","stderr","content"}) do
    if type(view[key]) == "string" then
      local clipped, truncated=M.truncate(view[key],name=="bash" or name=="shell")
      view[key]=clipped; changed=changed or truncated
    end
  end
  if #encoded>M.MAX_BYTES*3 and not changed then
    view={preview=M.slice(encoded,1,M.MAX_BYTES),code=output.code,ok=output.ok,error=output.error}
    changed=true
  end
  if changed then
    view.full_result=M.store(encoded)
    view.omitted=true
    view.note="Output view is bounded to 2000 lines / 50 KiB per text field. Full original JSON is stored at full_result.path; use tool_result with its sha256 and byte offset to retrieve any part."
  end
  return json.encode(view)
end

function M.outcome(name, output)
  if type(output) ~= "table" then return true end
  if output.error ~= nil or output.ok == false then return false end
  -- grep's no-match exit is a valid search result, not a transport failure.
  if name == "grep" and tonumber(output.code) == 1 then return true end
  return output.code == nil or tonumber(output.code) == 0
end

return M
