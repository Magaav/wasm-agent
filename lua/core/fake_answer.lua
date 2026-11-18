-- A tool result is a fact the harness produces, never text a model writes.
--
-- Measured 18/11, session 100c54ab (three times in one session: 12:48, 13:40, 14:16): the last
-- assistant message of a turn was markup imitating a tool result - "<result>\n<name>bash</name>\n
-- <output>..." - and the harness recorded it as the answer. The turn ended there, mid-task, with a
-- fabricated "bash output" as its reply and no call ever dispatched. The model had been about to ask
-- for a tool and instead wrote what it expected the tool to answer.
--
-- The rule this file implements is the operator's (Victor, 18/11): a message whose content contains
-- result/call markup the model wrote itself is never an answer. It is stripped from the content, the
-- run keeps going (the model takes its next step), the event is recorded with the removed markup kept
-- verbatim, and a model that repeats it MAX_REPEATS times in a row fails the turn BY NAME
-- (fake_tool_result) - never as "answered".
--
-- This is a *detector over text*, so it is written to be narrow on purpose:
--   * fenced code (three backticks or three tildes, closed or not), inline code spans and Markdown's
--     indented code are masked first: a model documenting the markup, quoting a doc or writing a
--     fixture is not imitating a tool result, and markup inside code is never fake;
--   * the mask is the SAME LENGTH as the text it covers (only the visible bytes are blanked, newlines
--     stay), so every span the detector finds in the masked copy is a span of the original message -
--     the cut is then made in the ORIGINAL (18/11 round 2: cutting from the stripped copy deleted the
--     model's code and the rest of its message along with the markup);
--   * an element only counts where it starts a line (leading whitespace allowed) or where a
--     <name>...</name> is immediately followed by <output>: prose that merely mentions a tag is prose;
--   * the tags counted are the ones a tool result or a tool call is spelled with across the protocols
--     this node speaks (the measured shape plus its siblings), not every angle bracket.
local M = {}

-- How many times in a row a fabricated block may replace a step before the turn fails by name. Three
-- is the measured worst case in one session; a fourth would be the model answering the harness notice
-- with the same imitation, which is a model failure, not a harness one.
M.MAX_REPEATS = 3
-- The tags that spell a tool result or a tool call.
M.ELEMENTS = {
  "function_results", "function_call", "tool_result", "tool_calls", "tool_call",
  "result", "output", "invoke",
}
-- The code this detector ends a turn with, exported so the failure layer and a test agree on the name
-- instead of spelling it twice.
M.CODE = "fake_tool_result"

local FENCE = "\96\96\96"
local TILDE = "~~~"

-- The same bytes, blanked: only the visible bytes become spaces, every newline stays. A mask that
-- removed or shortened its region would move every span after it, and the spans are cut from the
-- original text.
local function blank(region)
  return (region:gsub("[^\n]", " "))
end

-- Text with the code in it masked IN PLACE: closed fences, an unterminated fence (the rest of the
-- message is code), inline spans, and indented code blocks.
local function mask_code(text)
  local out = text
  out = out:gsub(FENCE .. "[^\n]*\n.-" .. FENCE, blank)
  out = out:gsub(TILDE .. "[^\n]*\n.-" .. TILDE, blank)
  local at = out:find(FENCE, 1, true)
  if at then out = out:sub(1, at - 1) .. blank(out:sub(at)) end
  at = out:find(TILDE, 1, true)
  if at then out = out:sub(1, at - 1) .. blank(out:sub(at)) end
  out = out:gsub("\96[^\96\n]-\96", blank)
  -- Markdown's indented code: a line that starts with four spaces or a tab. Conservative on purpose
  -- (a deeply indented list continuation is masked too): failing to see a fake is a wrong answer kept
  -- in the record, while seeing one inside code is the model's own work deleted.
  out = out:gsub("([\n])([ \t][ \t][ \t][ \t][^\n]*)", function(newline, line)
    return newline .. blank(line)
  end)
  return out
end

-- The first fabricated element in 'bare', as { tag, from, to } (1-based byte positions; 'to' is the
-- position after the whole element: its closer when there is one, else the end of its payload).
--   <result> ... </result>        the measured shape
--   <name>bash</name><output>     the same shape with the wrapper left off
--   <tool_call> {"name": ...}     the call-side sibling
local function find_element(bare)
  local best
  local function take(tag, from, to)
    if not best or from < best.from then best = { tag = tag, from = from, to = to } end
  end
  -- Is everything from the start of the match's own line up to it whitespace? An element that a
  -- sentence merely mentions is prose; an element alone on its line is the model imitating a result.
  local function at_line_start(from)
    local before = bare:sub(1, from - 1)
    local cut = (before:find("\n[^\n]*$") or 0) + 1
    return (bare:sub(cut, from - 1):match("^%s*$")) ~= nil
  end
  for _, tag in ipairs(M.ELEMENTS) do
    -- Longest tag first in M.ELEMENTS, so "<tool_calls>" is read as itself and not as "<tool_call".
    local init = 1
    while true do
      local from, after = bare:find("<" .. tag .. "[%s>]", init)
      if not from then break end
      if at_line_start(from) then
        local _, close_after = bare:find("</" .. tag .. ">", after, true)
        -- An unclosed element runs to the end of the text: leaving the fabricated body behind would
        -- put the invented output in the transcript as prose, which is the failure this file removes.
        take(tag, from, close_after and close_after + 1 or (#bare + 1))
      end
      init = from + 1
    end
  end
  -- A name element immediately answered by an output element: the measured shape without its wrapper.
  local name_from, name_to = bare:find("%s*<name>[^<]-</name>%s*<output>")
  if name_from then
    local _, output_close = bare:find("</output>", name_to, true)
    take("name", name_from, output_close and output_close + 1 or (#bare + 1))
  end
  return best
end

-- The tool the model was describing, as far as its own markup says it: the <name> element of the
-- measured shape, or the "name" field of a markup tool call. nil when the markup names none - the
-- notice then says "the tool" instead of inventing a name (18/11 round 2, model-facing text).
local function named_tool(text)
  local name = text:match("<name>%s*([%w_%.%-]+)%s*</name>")
  if name then return name end
  name = text:match('"name"%s*:%s*"([%w_%.%-]+)"')
  return name
end

-- What the model wrote: nil when the text is an ordinary message, else
--   { code = "fake_tool_result", tags = {"result","name","output"}, blocks = 3,
--     excerpt = "<a bounded quote of the fabricated element>",
--     removed = "<the markup itself, verbatim>", removed_blocks = { "<first element>", ... },
--     tool = "bash" or nil,
--     stripped = "<the original text with those spans cut out>" }
function M.scan(content)
  if type(content) ~= "string" or content == "" then return nil end
  -- Detection happens on the masked copy; the cut happens on the ORIGINAL, by span.
  local work = mask_code(content)
  local found = {}
  while true do
    local element = find_element(work)
    if not element then break end
    found[#found + 1] = element
    -- Blank what was found, in place, so the next element is found by offset and every offset still
    -- means the same byte of the original message.
    local from = element.from
    local stop = math.min(element.to, #work + 1)
    work = work:sub(1, from - 1) .. (stop > from and blank(work:sub(from, stop - 1)) or "") .. work:sub(stop)
  end
  if #found == 0 then return nil end
  table.sort(found, function(a, b) return a.from < b.from end)
  local pieces, removed, tags, at = {}, {}, {}, 1
  local first = found[1]
  for _, element in ipairs(found) do
    -- Spans come out of the same offsets, so two elements never overlap; the guard makes a nested
    -- match (an element found wholly inside one already cut) impossible to cut twice.
    if element.from >= at then
      local stop = math.min(element.to, #content + 1)
      pieces[#pieces + 1] = content:sub(at, element.from - 1)
      removed[#removed + 1] = content:sub(element.from, stop - 1)
      at = stop
      if not tags[element.tag] then tags[#tags + 1] = element.tag; tags[element.tag] = true end
    end
  end
  pieces[#pieces + 1] = content:sub(at)
  local quote = content:sub(first.from, math.min(first.to, first.from + 240) - 1)
  local text = table.concat(removed, "\n")
  return { code = M.CODE, tags = tags, blocks = #removed,
    excerpt = (quote:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")),
    -- The evidence, verbatim: what was taken out of the message is kept in the run record, byte for
    -- byte, not only as the bounded excerpt the notice and the status line can afford.
    removed = text, removed_blocks = removed,
    tool = named_tool(text),
    stripped = (table.concat(pieces):gsub("^%s+", ""):gsub("%s+$", "")) }
end

-- The sentence the model is handed to take its next step. It names what it wrote and says the one
-- thing it must do instead: a harness notice in the user role, the same channel and the same shape as
-- the stream-cut notice in lua/core/agent.lua, and never a new user request.
--
-- 'ref' is how this session can actually call that tool - the caller spells it from the session's own
-- catalogue with the same rule the prompt uses (lua/core/agent.lua, tool_ref), and passes nil when it
-- cannot tell. A notice that told a model to call tools.<name>(args) in a session without code mode
-- named a door that is not there (18/11 round 2, model-facing text).
function M.notice(scan, ref)
  local wrote = scan and #scan.tags > 0 and table.concat(scan.tags, ", ") or "a tool result"
  local how = (type(ref) == "string" and ref ~= "") and ref or "the tool you were describing"
  return "[Harness notice] Your last message contained " .. wrote .. " markup you wrote yourself "
    .. "(" .. tostring(scan and scan.excerpt or "") .. "). A tool result is produced by the harness, "
    .. "not written into a message: that markup was NOT an answer, it was removed, and no call was run "
    .. "from it. This is not a new user request. Take your next step: call " .. how
    .. " and wait for its real result."
end

-- The failure sentence, used where a run ends by name after MAX_REPEATS imitations in a row.
function M.failure(repeats)
  return string.format("%s: the model imitated a tool result instead of calling one %d times in a row; "
    .. "no fabricated output was recorded as the answer, and the turn is failed rather than finished",
    M.CODE, tonumber(repeats) or M.MAX_REPEATS)
end

return M
