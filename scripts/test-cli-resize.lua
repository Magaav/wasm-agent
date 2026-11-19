
-- A terminal resize, in the components that draw a rule, a box or a right-aligned part.
--
-- The finding (Victor, 18/11): maximising the terminal stretched the input rule and the footer - the
-- host redraws those from its own size - while the welcome header box and its top rule, the code-mode
-- box and the rest of the framed components kept the old width. Shrinking it left them WIDER than the
-- window, where the terminal wraps them into a second row and everything below moves: the bounce.
--
-- The width was measured once, before the welcome box was printed, and cached for the life of the
-- process. So the test is the property, not a component: render each one at 80, at 200 and back at 60,
-- and assert that no drawn row is wider than the terminal it is drawn in, and that a rule is exactly as
-- wide as it.
--
-- No console and no node: the view takes `columns`, the probe that stands in for the console
-- (`METHODS:refresh_limit`).
local cli_view = dofile("lua/core/cli_view.lua")
local codemode_block = dofile("lua/core/codemode_block.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end

-- The visible text of a drawn row: colour is not width, and a rule's cells are what is counted.
local function visible(text)
  return (tostring(text):gsub("\27%[[%d;]*m", ""):gsub("\27%]2;[^\7]*\7", ""))
end
local function width_of(text) return cli_view.columns(visible(text)) end

-- Every component this mission names, as the rows it draws at the width the view has NOW. Each is a
-- function of the view, so the same list is re-rendered after every resize.
local function components(view)
  local out = {}
  local banner = cli_view.banner({ live = view.live, limit = view.limit,
    version = "e5ba9089",
    model = "deepseek-v4.1-flash @ http://127.0.0.1:1/v1",
    session = "abc", workspace = "~/work/wasm-agent", branch = "change/tui-polish-2" })
  out["welcome box"] = {}
  for line in banner:gmatch("[^\n]*") do out["welcome box"][#out["welcome box"] + 1] = line end
  local model = codemode_block.new({ code = "const a = await tools.bash({command: 'echo hi'})\nreturn a" }, 0)
  codemode_block.begin_call(model, "call-1", "bash", { command = "echo hi" })
  codemode_block.settle(model, "call-1", { ok = true, ms = 12 })
  codemode_block.finish(model, "hi", 1.2)
  out["code-mode block"] = codemode_block.rows(model, view.limit, view:codemode_opts())
  out["status row"] = { view:status_text(false) }
  out["footer"] = { cli_view.footer({ rounds = 3, tools = 5, prompt = 1200, completion = 340, cached = 900 },
    { context = 45000, budget = 128000 }) }
  out["elsewhere row"] = { "node: 2 ops elsewhere" }
  return out
end

-- The widths a window is driven through, in the order Victor drove them: start, maximise, shrink.
local widths = { 80, 200, 60 }
local view = cli_view.new({ out = function() end, live = false, now = function() return 1000 end,
  columns = function() return widths[1] end, limit = widths[1] })

for _, width in ipairs(widths) do
  -- What a resize does: the console reports a new width, and the next frame reads it.
  view.columns_probe = function() return width end
  view:refresh_limit()
  ok(view.limit == width, "the view reads the terminal at " .. width .. " (got " .. tostring(view.limit) .. ")")
  for name, rows in pairs(components(view)) do
    for index, row in ipairs(rows) do
      local cells = width_of(row)
      ok(cells <= view.limit, name .. " row " .. index .. " is not wider than " .. width
        .. " (drawn " .. cells .. ")")
    end
  end
  -- The rule is the component that is nothing BUT its width: it must be the whole of it, not a narrower
  -- line that leaves the box looking cut off.
  local banner = cli_view.banner({ live = false, limit = view.limit, version = "e5ba9089" })
  local rule = banner:match("^([^\n]*)")
  ok(width_of(rule) == view.limit, "the welcome rule is exactly " .. width .. " wide (drawn "
    .. width_of(rule) .. ")")
  ok(not banner:find(cli_view.RULE, 1, true), "no rule marker reaches the screen at " .. width)
end

-- The terminal is unanswerable (a pipe, a CI log): the width the view already had stands, rather than
-- collapsing to a guess. A resize that reports nothing must not redraw the chat narrow.
view.columns_probe = function() return nil end
view:refresh_limit()
ok(view.limit == widths[3], "an unanswerable console keeps the width the view had")
view.columns_probe = function() return -1 end
view:refresh_limit()
ok(view.limit == widths[3], "a nonsense width keeps the width the view had")
-- A console narrower than any layout can be drawn in takes the floor, so a box is never all border.
view.columns_probe = function() return 4 end
view:refresh_limit()
ok(view.limit == cli_view.MIN_COLUMNS, "a 4-column terminal is drawn at the floor, not at 4")

if failed == 0 then print("resize ok (" .. checks .. " checks)") else print("FAILED " .. failed .. "/" .. checks) end
os.exit(failed == 0 and 0 or 1)

