-- The adapter contract (docs/AGENT-SEAT.md, principles 2 and 3).
--
-- Every provider answer becomes ONE normalized message, and that record is the only thing the core
-- (lua/core/agent.lua, lua/core/raw_code.lua) reads:
--
--   { answer_text = "", reasoning = "", tool_calls = {}, finish_reason = "stop", usage = nil }
--
-- A provider quirk is fixed in its own adapter (lua/core/adapters/<transport>.lua), never in the
-- core: the three spellings of a reasoning field, a think block inside content, an empty field
-- shadowing a populated one. The core reads the record and nothing else.
local M = {}

-- The record's fields, and nothing else. A key outside this list is refused by name instead of
-- being carried quietly into the core - an adapter that invents a field is a bug, and a silent
-- extra key is how one provider's quirk becomes the core's assumption.
M.FIELDS = { "answer_text", "reasoning", "tool_calls", "finish_reason", "usage" }

-- The finish reasons the core understands. A provider's own vocabulary is mapped by its adapter;
-- anything left unmapped stays unknown, and M.normalize says so in its second return.
M.FINISH = { stop = true, length = true, tool_calls = true, content_filter = true, error = true }

-- The three spellings an OpenAI-compatible endpoint uses for a reasoning model's thinking, in the
-- order they are read: the first non-empty one wins, so an empty field never shadows a populated one.
M.REASONING_FIELDS = { "reasoning_content", "reasoning", "reasoning_text" }

-- The reasoning field of one provider message, or "" when it carries none.
function M.reasoning_of(message)
  if type(message) ~= "table" then return "" end
  for _, field in ipairs(M.REASONING_FIELDS) do
    local value = message[field]
    if type(value) == "string" and value ~= "" then return value end
  end
  return ""
end

-- What a reader would see. A reply that is only reasoning, or only whitespace, is not an answer -
-- and some endpoints put the thinking inside content as a think block, so those are removed here.
function M.visible_text(text)
  local out = tostring(text or "")
  local last = nil
  local from = 1
  while true do
    local _, closing = string.find(out, "</think>", from, true)
    if not closing then break end
    last = closing
    from = closing + 1
  end
  if last then out = out:sub(last + 1) end
  local opening = string.find(out, "<think", 1, true)
  if opening then out = out:sub(1, opening - 1) end
  out = out:gsub("</?think[^>]*>", "")
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- One provider answer, as the record. Absent fields take their empty value.
function M.normalize(fields)
  fields = type(fields) == "table" and fields or {}
  for key in pairs(fields) do
    local known = false
    for _, name in ipairs(M.FIELDS) do if name == key then known = true end end
    if not known then
      return nil, "adapter_unknown_field: " .. tostring(key) .. " is not part of the normalized message"
    end
  end
  local record = {
    answer_text = type(fields.answer_text) == "string" and fields.answer_text or "",
    reasoning = type(fields.reasoning) == "string" and fields.reasoning or "",
    tool_calls = type(fields.tool_calls) == "table" and fields.tool_calls or {},
    finish_reason = type(fields.finish_reason) == "string" and fields.finish_reason or "stop",
    usage = type(fields.usage) == "table" and fields.usage or nil,
  }
  if not M.FINISH[record.finish_reason] then return record, "unknown_finish_reason" end
  return record
end

return M
