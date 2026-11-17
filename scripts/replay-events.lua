-- Record a real run's view events, or replay recorded events through the view on a transcript that keeps
-- the host's rules - so a screen change is checked in milliseconds, with no model call and no build.
--
-- WHY (operator 17/11, "make the evolution faster"). The interactive transcript is drawn by the host from
-- what `lua/core/cli_view.lua` writes; checking a spacing or colour change used to mean a build, an install
-- and a live model call (~5 min). The events a run emits are data, so the same run can be drawn again.
--
--   record:  WA_REPLAY_RECORD="<prompt>" WA_REPLAY_FILE=events.json WA_SCRIPT=scripts/replay-events.lua wa --db scratch.db
--            (one real run through the agent - a model call - its events written to the file)
--   replay:  WA_REPLAY_FILE=events.json WA_SCRIPT=scripts/replay-events.lua wa --db scratch.db [WA_REPLAY_ANSI=1]
--            (prints the transcript's rows as the host would keep them, block by block)
--
-- The transcript double below follows rust/wa-term/src/transcript.rs: a write continues an open last line;
-- a block is reused while empty; a topic block does not draw its trailing blank rows. `M.rows(events)` is
-- what scripts/test-cli-flow.lua asserts on.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function strip(text) return (tostring(text):gsub("\27%[[%d;?]*[A-Za-z]", "")) end

function M.rows(events, opts)
  opts = opts or {}
  local blocks = { { topic = false, lines = {}, open = false } }
  local function last() return blocks[#blocks] end
  local saved = {}
  local function stub(name, fn) saved[name] = host[name]; host[name] = fn end
  stub("transcript_block", function(topic, code)
    local b = last()
    if #b.lines == 0 then b.topic, b.code = topic, code else blocks[#blocks + 1] = { topic = topic, code = code, lines = {}, open = false } end
    return true
  end)
  stub("transcript_write", function(text)
    local b = last()
    text = tostring(text):gsub("\r", "")
    local body, ends = text:match("^(.-)(\n?)$")
    local first = true
    for segment in (body .. "\n"):gmatch("([^\n]*)\n") do
      if first and b.open then b.lines[#b.lines] = b.lines[#b.lines] .. segment else b.lines[#b.lines + 1] = segment end
      first = false
    end
    b.open = (ends == "")
    return true
  end)
  for _, name in ipairs({ "transcript_live", "transcript_head", "transcript_fold" }) do stub(name, function() return true end) end
  stub("transcript_rewrite", function(offset, text)
    local b = last(); local index = #b.lines + offset + 1
    if b.lines[index] then b.lines[index] = text end
    return true
  end)
  stub("input_editor", function() return true end)
  local ok, problem = pcall(function()
    local view_lib = dofile("lua/core/cli_view.lua")
    local view = view_lib.new({ out = function() end, live = opts.ansi == true, stdout = true, limit = opts.width or 100,
      rows = function() return 40 end, now = function() return 1 end, register = false })
    view.screen = view_lib.screen_rows(40, true)
    view.editor, view.editor_ready = true, true
    -- The status line is the host's own row, never a transcript row (a live view hands it to the host
    -- ticker); a non-live view would write it here, which the reader never sees.
    view.paint = function() end
    view:accepted(opts.prompt or "the reader's line")
    view:run_started()
    local reply
    for _, event in ipairs(events) do
      if event.type == "reply" then reply = event.text else view:event(event) end
    end
    view:answered(reply or "")
  end)
  for name, fn in pairs(saved) do host[name] = fn end
  if not ok then error(problem, 0) end
  local out = {}
  for index, block in ipairs(blocks) do
    local rows = {}
    for _, line in ipairs(block.lines) do rows[#rows + 1] = opts.ansi and line or strip(line) end
    if block.topic then while #rows > 0 and strip(rows[#rows]):match("^%s*$") do table.remove(rows) end end
    out[#out + 1] = { topic = block.topic and true or false, code = block.code and true or false, rows = rows, index = index }
  end
  return out
end

-- Every row in order, as one list (block boundaries dropped): what the reader sees, top to bottom.
function M.flat(blocks)
  local rows = {}
  for _, block in ipairs(blocks) do for _, row in ipairs(block.rows) do rows[#rows + 1] = row end end
  return rows
end

local function record(prompt, file)
  local memory = dofile("lua/core/memory.lua"); memory.setup()
  local sid = memory.start_session("", "replay-record", { user_id = "master", title = "replay-record" })
  local events = {}
  local agent = dofile("lua/core/agent.lua").new(sid, function(event)
    local copy = {}
    for key, value in pairs(event) do if type(value) ~= "function" then copy[key] = value end end
    events[#events + 1] = copy
  end, "master", "master", "")
  agent:run(prompt)
  assert(host.write_file(file, json.encode(events)), "cannot write " .. file)
  print(string.format("replay: recorded %d events to %s", #events, file))
end

if WA_SCRIPT_LIBRARY then return M end
local file = host.getenv("WA_REPLAY_FILE")
local prompt = host.getenv("WA_REPLAY_RECORD")
if prompt and prompt ~= "" then
  record(prompt, assert(file, "WA_REPLAY_FILE names where the events go"))
elseif file and file ~= "" then
  local events = json.decode(assert(host.read_file(file), "cannot read " .. file))
  for _, block in ipairs(M.rows(events, { ansi = host.getenv("WA_REPLAY_ANSI") == "1",
      width = tonumber(host.getenv("COLUMNS") or "") or 100 })) do
    print(string.format("--- block %d%s%s", block.index, block.topic and " topic" or "", block.code and " code" or ""))
    for _, row in ipairs(block.rows) do print(row) end
  end
else
  return M
end
