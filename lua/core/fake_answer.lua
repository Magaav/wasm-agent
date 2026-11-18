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
-- run keeps going (the model takes its next step), the event is recorded, and a model that repeats it
-- MAX_REPEATS times in a row fails the turn BY NAME (fake_tool_result) - never as "answered".
--
-- This is a *detector over text*, so it is written to be narrow on purpose:
--   * fenced code (three backticks or three tildes) and inline code spans are removed first: a model
--     documenting the markup, quoting a doc or writing a fixture is not imitating a tool result;
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

local function escape(name) return (name:gsub("%p", "%%%0")) end

-- Text with fenced blocks and inline code spans blanked out.
local function strip_code(text)
  local out = text:gsub(FENCE .. "[^\n]*\n.-" .. FENCE, "")
  out = out:gsub(TILDE .. "[^\n]*\n.-" .. TILDE, "")
  out = out:gsub("\96[^\96\n]-\96", "")
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

-- What the model wrote: nil when the text is an ordinary message, else
--   { code = "fake_tool_result", tags = {"result","name","output"}, blocks = 3,
--     excerpt = "<a bounded quote of the fabricated element>", stripped = "<text without them>" }
function M.scan(content)
  if type(content) ~= "string" or content == "" then return nil end
  local bare = strip_code(content)
  local tags, blocks, first = {}, 0, nil
  local stripped = bare
  -- Loop over what is left so several fabricated elements are all removed, not only the first.
  while true do
    local element = find_element(stripped)
    if not element then break end
    blocks = blocks + 1
    if not first then first = element end
    if not tags[element.tag] then tags[#tags + 1] = element.tag; tags[element.tag] = true end
    stripped = stripped:sub(1, element.from - 1) .. "\n" .. stripped:sub(element.to)
  end
  if blocks == 0 then return nil end
  local excerpt = bare:sub(first.from, math.min(first.to, first.from + 240))
  return { code = M.CODE, tags = tags, blocks = blocks,
    excerpt = (excerpt:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")),
    stripped = (stripped:gsub("^%s+", ""):gsub("%s+$", "")) }
end

-- The sentence the model is handed to take its next step. It names what it wrote and says the one
-- thing it must do instead: a harness notice in the user role, the same channel and the same shape as
-- the stream-cut notice in lua/core/agent.lua, and never a new user request.
function M.notice(scan)
  local wrote = scan and #scan.tags > 0 and table.concat(scan.tags, ", ") or "a tool result"
  return "[Harness notice] Your last message contained " .. wrote .. " markup you wrote yourself "
    .. "(" .. tostring(scan and scan.excerpt or "") .. "). A tool result is produced by the harness, "
    .. "not written into a message: that markup was NOT an answer, it was removed, and no call was run "
    .. "from it. This is not a new user request. Take your next step: call the tool you were describing "
    .. "with tools.<name>(args) and wait for its real result."
end

-- The failure sentence, used where a run ends by name after MAX_REPEATS imitations in a row.
function M.failure(repeats)
  return string.format("%s: the model imitated a tool result instead of calling one %d times in a row; "
    .. "no fabricated output was recorded as the answer, and the turn is failed rather than finished",
    M.CODE, tonumber(repeats) or M.MAX_REPEATS)
end

return M
