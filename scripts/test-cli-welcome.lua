
-- The view draws nothing about other sessions (item 1) and the welcome line's reason (item 3).
--
-- ITEM 1. This file once asserted the node-wide aggregate the row drew - "node: 2 ops elsewhere" -
-- from cli_view's own METHODS:elsewhere_text. Round 3 removed that method and every use of it: the
-- aggregate belongs to change/session-isolation, whose elsewhere_row stores a field of that name, so a
-- merged tree would call a string (and the two branches' ms/s clocks disagree). The assertions below
-- are the inverse: a progress module that answers elsewhere() must not reach this view's row.
--
-- ITEM 3. With no provider, the welcome box said "local mode (no model configured)" - true, and useless:
-- no cause, so a reader could not tell a node with no model from a shell that did not inherit the node's.
local cli_view = dofile("lua/core/cli_view.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end
local function visible(text) return (tostring(text):gsub("\27%[[%d;]*m", "")) end

-- The view draws NOTHING about other sessions (round 3, item 1).
--
-- This file used to assert the opposite: with nothing of its own in flight, the status row said
-- "node: 2 ops elsewhere" from cli_view's own METHODS:elsewhere_text. That method and every use of it
-- are gone. The aggregate belongs to change/session-isolation, whose elsewhere_row stores a field by
-- that name - merged, this file's status_template would call a string, and the two branches' ms/s
-- clocks disagree. So this tree has no reader of the count, and the assertions below are the inverse of
-- the old ones: a progress module that DOES answer elsewhere() must not reach this view.
local silent = cli_view.new({ out = function() end, live = true, now = function() return 1000 end,
  limit = 80, columns = function() return 80 end })
silent.session_id = "session-mine"
silent.tool_progress = {
  status = function() return nil end,
  elsewhere = function() return 2 end,
  elsewhere_text = function(count) return "node: " .. count .. " ops elsewhere" end,
}
ok(silent.elsewhere_text == nil, "the view has no elsewhere_text of its own: the aggregate is another branch's")
ok(silent.progress_module == nil, "and no second loader for the progress module")
local idle = silent:status_text(false)
ok(visible(idle) == "", "an idle row is empty, not a count of other sessions (got "
  .. tostring(visible(idle)) .. ")")
for _, leak in ipairs({ "elsewhere", "node:", "ops" }) do
  ok(not visible(idle):find(leak, 1, true), "the idle row never says " .. leak)
end
-- With a run in flight the row is this session's run, and still not the aggregate.
silent.turn = { started = 900, rounds = 1, baseline = {} }
ok(not visible(silent:status_text(false)):find("elsewhere", 1, true),
  "a run in flight draws this session's work and nothing about the node")

-- A session's own call still reaches its own row (tool_line is that row, unchanged by the removal).
local own_view = cli_view.new({ out = function() end, live = true, now = function() return 1000 end,
  limit = 80, columns = function() return 80 end })
own_view.tool_progress = { status = function() return { text = "\226\159\179 bash \194\183 3s", kind = "tool" } end }
local own = own_view:tool_line()
ok(own and own.text ~= "" and not own.dim, "a session's own call is its own row")

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

if failed == 0 then print("welcome reason and no elsewhere row ok (" .. checks .. " checks)")
else print("FAILED " .. failed .. "/" .. checks) end
os.exit(failed == 0 and 0 or 1)

