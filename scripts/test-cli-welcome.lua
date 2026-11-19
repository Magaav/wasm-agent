
-- The node-wide aggregate (item 1) and the welcome line's reason (item 3).
--
-- ITEM 1. The long-call row used to be node-wide: every session drew whichever call had written the one
-- file last, with that caller's own last line of output in it. The backend fix keys the file by owning
-- session (change/session-isolation, not landed yet); this is the TUI half - with nothing of its own in
-- flight, a session may say only THAT the node is busy, never with what, and never for whom:
--
--   node: 2 ops elsewhere
--
-- ITEM 3. With no provider, the welcome box said "local mode (no model configured)" - true, and useless:
-- no cause, so a reader could not tell a node with no model from a shell that did not inherit the node's.
local cli_view = dofile("lua/core/cli_view.lua")
local tool_progress = dofile("lua/core/tool_progress.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end
local function visible(text) return (tostring(text):gsub("\27%[[%d;]*m", "")) end

-- ---- item 1: the aggregate ------------------------------------------------------------

-- With no module that can answer elsewhere (a binary older than the branch that added it), the row is
-- NOT drawn: a count that cannot be read is not invented.
local quiet = cli_view.new({ out = function() end, live = true, now = function() return 1000 end,
  limit = 80, columns = function() return 80 end })
quiet.tool_progress = { status = function() return nil end }
ok(quiet:elsewhere_text() == nil, "no module answer means no aggregate, never a made-up count")

-- The wording belongs to the module that change/session-isolation adds. THIS tree is built against that
-- name and not against that branch, so: where the function is present it is the one that speaks, and
-- where it is not yet the view's own fallback says the identical sentence. Both are asserted below.
if type(tool_progress.elsewhere_text) == "function" then
  ok(tool_progress.elsewhere_text(1) == "node: 1 op elsewhere", "one other op is singular")
  ok(tool_progress.elsewhere_text(3) == "node: 3 ops elsewhere", "several are plural")
else
  ok(true, "elsewhere_text arrives with change/session-isolation; the view carries the same words")
end

-- The row the view composes: dim, and carrying nothing but the count.
local counted = cli_view.new({ out = function() end, live = true, now = function() return 1000 end,
  limit = 80, columns = function() return 80 end })
counted.session_id = "session-mine"
counted.tool_progress = {
  status = function() return nil end,
  elsewhere = function() return 2 end,
  elsewhere_text = type(tool_progress.elsewhere_text) == "function" and tool_progress.elsewhere_text or nil,
}
local composed = counted:elsewhere_text()
ok(composed ~= nil and visible(composed) == "node: 2 ops elsewhere",
  "the aggregate says the count and nothing else (got " .. tostring(visible(composed or "")) .. ")")
ok(tostring(composed):find("\27[38;2;119;119;119m", 1, true) ~= nil, "and it is drawn dim")
-- Never a name, never a session id, never a line of anybody's output: the three things the old
-- node-wide row leaked.
for _, leak in ipairs({ "bash", "session-mine", "cargo", "Building", "session-a" }) do
  ok(not visible(composed or ""):find(leak, 1, true), "the aggregate never names " .. leak)
end
-- And it reaches the STATUS ROW, which is where a reader sees it: with nothing of this session's in
-- flight, the row is the aggregate; with a run in flight it is the run, and the aggregate is not there.
-- Live: the aggregate is a live-view fact (a captured transcript has no row to redraw, and a log line
-- per frame would be noise), which is why this view is the live one.
local st = cli_view.new({ out = function() end, live = true, now = function() return 1000 end,
  limit = 80, columns = function() return 80 end })
st.tool_progress = counted.tool_progress
st.tool_progress.status = function() return nil end
local row = st:status_text(false)
ok(visible(row) == "node: 2 ops elsewhere", "the status row carries the aggregate when nothing runs (got "
  .. tostring(visible(row)) .. ")")
st.turn = { started = 900, rounds = 1, baseline = {} }
ok(not visible(st:status_text(false)):find("elsewhere", 1, true),
  "and a run in flight takes the row back: the aggregate never stands in for this session's own work")

-- A session with work of its OWN does not draw it: tool_line is that row, and it is the only one.
counted.tool_progress.status = function() return { text = "\226\159\179 bash \194\183 3s", kind = "tool" } end
local own = counted:tool_line()
ok(own and own.text ~= "" and not own.dim, "a session's own call is its own row, not the aggregate")

-- ---- item 3: why there is no model ----------------------------------------------------

-- The sentence is the default cause: a shell with no provider env on a node that has one.
local provider = dofile("lua/core/provider.lua")
local why = provider.why_unconfigured()
ok(why:find("this shell has no provider env", 1, true) ~= nil,
  "the default cause names the environment, not a mood (got " .. tostring(why) .. ")")
ok(why:find("wa-serve has one", 1, true) ~= nil, "and says the node has one")
ok(why:find("wa chat", 1, true) ~= nil, "and the one command that runs inside it")
ok(why:find("/login", 1, true) ~= nil, "and the other way out")
ok(why:find("local mode (no model configured)", 1, true) == nil,
  "never the sentence that named no cause")

-- The banner prints it in the model line, so it is a whole line of the welcome box.
local banner = cli_view.banner({ live = false, limit = 200, model = "none - " .. why })
ok(banner:find("model: none - this shell has no provider env", 1, true) ~= nil,
  "the welcome box says model: none - <the cause>")
ok(not banner:find("local mode", 1, true), "and nothing in it still says local mode")

if failed == 0 then print("welcome and elsewhere ok (" .. checks .. " checks)")
else print("FAILED " .. failed .. "/" .. checks) end
os.exit(failed == 0 and 0 or 1)

