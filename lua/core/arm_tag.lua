-- Arm E2 and E3: tagged text, no JSON (docs: next-round.md, 19/11 ~16:40, ~16:50, ~17:00).
--
-- The model writes plain text. A STEP starts only from a top-level <codeact> in the model's own
-- message; a TURN ends only in the arm's finish shape. Everything else is invalid_message_shape:
-- nothing runs and the turn does not end.
--
-- Pure: no host, no state. The texts below are VERBATIM from the directive and are the arm's contract;
-- changing one changes the measurement, so they are named rather than edited in place.
local M = {}

M.E2_PROMPT = table.concat({
  "Every message you send is one of exactly two shapes:",
  "1. To act:    <message>...</message> then ONE <codeact>...</codeact> block (JavaScript; the result comes back as <result>...</result>).",
  "2. To finish: <message>...</message> alone - this is your final answer.",
  "There is no other way to act or to finish. Anything outside these two tags - other tags, fences, tool-call markup, text before or after them - is an error: nothing runs and the turn does not end.",
}, "\n")
M.E2_CONTINUE = "[error: invalid_message_shape] Your message used neither shape, so nothing ran and the turn did not end. "
  .. "Send <message>...</message> with one <codeact>...</codeact> to act, or <message>...</message> alone to finish."

M.E3_PROMPT = table.concat({
  "Every message you send is one of exactly two shapes:",
  "1. To act:    optionally <message>...</message>, then ONE <codeact>...</codeact> block (JavaScript; the result comes back as <result>...</result>).",
  "2. To finish: <final_message>...</final_message> alone - this is your final answer and the only way to end your turn.",
  "There is no other way to act or to finish. Anything else - <message> alone, other tags, fences, tool-call markup, text outside these tags - is an error: nothing runs and the turn does not end.",
}, "\n")
M.E3_CONTINUE = "[error: invalid_message_shape] Your message used neither shape, so nothing ran and the turn did not end. "
  .. "To act, send one <codeact>...</codeact> (with an optional <message>); to finish, send <final_message>...</final_message> alone."

M.STOP = "</codeact>"
M.FAILURE = "invalid_message_shape"

function M.prompt(arm)
  if arm == "e2" then return M.E2_PROMPT end
  return M.E3_PROMPT
end

function M.continue_for(arm)
  if arm == "e2" then return M.E2_CONTINUE end
  return M.E3_CONTINUE
end

local function spans(text, open_tag, close_tag)
  local out, from = {}, 1
  while true do
    local s = text:find(open_tag, from, true)
    if not s then break end
    local e = text:find(close_tag, s + #open_tag, true)
    if not e then
      out[#out + 1] = { open = s, close = nil, inner = text:sub(s + #open_tag) }
      break
    end
    out[#out + 1] = { open = s, close = e + #close_tag - 1, inner = text:sub(s + #open_tag, e - 1) }
    from = e + #close_tag
  end
  return out
end

local function inside(offset, ranges)
  for _, r in ipairs(ranges) do
    if r.close and offset > r.open and offset < r.close then return true end
  end
  return false
end

local function trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function invalid(reason) return { shape = "invalid_message_shape", reason = reason } end

function M.parse(text, arm)
  local raw = tostring(text or "")
  if trim(raw) == "" then return invalid("the message was empty") end
  -- A model-written <result> is never read as one: only the harness writes it.
  if raw:find("<result>", 1, true) or raw:find("</result>", 1, true) then
    return invalid("a <result> is written by the harness, not by the model")
  end
  local messages = spans(raw, "<message>", "</message>")
  local finals = spans(raw, "<final_message>", "</final_message>")
  local codes = spans(raw, "<codeact>", "</codeact>")
  -- A <codeact> quoted inside <message>/<final_message> is an example, and never runs.
  local quoted = {}
  for _, r in ipairs(messages) do quoted[#quoted + 1] = r end
  for _, r in ipairs(finals) do quoted[#quoted + 1] = r end
  local live = {}
  for _, block in ipairs(codes) do
    if not inside(block.open, quoted) then live[#live + 1] = block end
  end
  -- An unclosed tag never acts, and it is named before anything else is judged.
  for _, r in ipairs(messages) do
    if not r.close then return invalid("a tag was never closed") end
  end
  for _, r in ipairs(finals) do
    if not r.close then return invalid("a <final_message> was never closed") end
  end
  for _, r in ipairs(live) do
    if not r.close then return invalid("the <codeact> block was never closed") end
  end
  -- Everything the tags do not account for is text outside them: an error in both arms.
  local stripped = raw
  local all = {}
  for _, r in ipairs(messages) do all[#all + 1] = r end
  for _, r in ipairs(finals) do all[#all + 1] = r end
  for _, r in ipairs(live) do all[#all + 1] = r end
  table.sort(all, function(a, b) return a.open > b.open end)
  for _, r in ipairs(all) do
    stripped = stripped:sub(1, r.open - 1) .. stripped:sub(r.close + 1)
  end
  if trim(stripped) ~= "" then
    return invalid("text outside the tags (fences, tool-call markup or prose)")
  end
  -- <final_message> together with an action is neither shape.
  if #finals > 0 and #live > 0 then
    return invalid("<final_message> and <codeact> together")
  end
  if #finals > 1 then return invalid("more than one <final_message>") end
  if arm == "e2" and #finals > 0 then
    return invalid("<final_message> is not a shape of this arm")
  end
  if #live > 0 then
    local first = live[1]
    local dropped = #live - 1
    return { shape = "act", code = first.inner,
      message = #messages > 0 and messages[1].inner or nil,
      dropped = dropped > 0 and dropped or nil,
      dropped_reason = dropped > 0 and "a second <codeact> in one message is dropped" or nil }
  end
  -- No action: the turn may end only in this arm's finish shape.
  if arm == "e3" then
    if #finals == 1 then return { shape = "finish", final_message = finals[1].inner } end
    return invalid("<message> alone does not end a turn in this arm")
  end
  if #messages == 1 then return { shape = "finish", final_message = messages[1].inner } end
  return invalid("neither shape: no <message> and no <codeact>")
end

return M
