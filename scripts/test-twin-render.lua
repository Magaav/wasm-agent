-- The Lua half of the twin-render contract.
--
-- `lua/core/cli_view.lua` and `rust/wa-term`'s `Editor` draw the same console for the same frame, and
-- on 2026-11-11 two rendering bugs came from the twins disagreeing (the status-row geometry and
-- `session_content`) rather than from either side being wrong alone. Both tests read
-- `fixtures/twin-frames.json`: this one asserts the Lua side, and the Rust test
-- `twin_frames_agree_with_the_shared_fixture` in `rust/wa-term/src/terminal_editor.rs` asserts the
-- other. A change to one renderer that the other does not follow fails where it was made.
local view = dofile("lua/core/cli_view.lua")
local json = dofile("lua/vendor/json.lua")

local checks, failed = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then failed = failed + 1; print("FAIL " .. label) end
end

local file = io.open("fixtures/twin-frames.json", "rb")
assert(file, "fixtures/twin-frames.json must be readable from the repository root (fast.sh runs tests there)")
local fixture = json.decode(file:read("*a"))
file:close()

-- A view with no terminal and no clock: the frame is what is asserted, not the animation.
local function frame(case)
  local v = view.new({
    out = function() end, live = false, limit = case.width, rows = case.rows,
    getenv = function() return nil end, now = function() return 0 end,
  })
  if case.notice ~= nil and case.notice ~= "" then v.session_notice = case.notice end
  if case.build ~= nil and case.build ~= "" then
    v.session_status = function() return { text = case.build, kind = "building" } end
  end
  return v
end

for _, case in ipairs(fixture.cases) do
  local name = tostring(case.name)
  -- The geometry both renderers own: the session-status-content row is the row directly above the
  -- footer, and the footer is the screen's last row.
  local screen = view.screen_rows(case.rows, true)
  check(screen.session == case.rows - 1, name .. ": Lua session row is the row above the footer (" .. tostring(screen.session) .. ")")
  check(screen.footer == case.rows, name .. ": Lua footer is the last row (" .. tostring(screen.footer) .. ")")

  local line = frame(case):session_line()
  if case.session_text == nil then
    check(line == nil, name .. ": Lua draws no row when nothing claims it")
  else
    check(line ~= nil, name .. ": Lua draws the row")
    local text = line or ""
    -- `session_line` paints only when `live`; with live=false the text is already plain.
    check(text == case.session_text, name .. ': Lua text "' .. tostring(text) .. '" == "' .. tostring(case.session_text) .. '"')
  end
end

if failed > 0 then
  print(string.format("%d of %d twin-render checks failed", failed, checks))
  os.exit(1)
end
print(string.format("twin render ok (%d checks; lua side of fixtures/twin-frames.json)", checks))
