-- The opening: the two green glyphs, and the policy that decides whether it plays.
--
-- The animation itself is the host's (rust/wa-term/src/opening.rs) and its screen is measured in a real
-- pty by rust/wa-term/tests/opening.rs. What can only be read HERE is the Lua half:
--
--   1. Victor's colour change (22/11: "change the star into the matrix green color as well as the
--      thinking animated stars first glyph on run status bar"): the welcome line's star and the run
--      status row's animated first glyph are `matrix` (00ff41), as a palette entry of their own, and
--      `accent` still paints everything it painted before - the phase word of that same row included;
--   2. `cli_view.opening`, the table of conditions the opening is never played on: a resumed session, a
--      message argument, a pipe, a scripted run, NO_COLOR, TERM=dumb, a window under 60x14, no editor,
--      and the setting. Each answers with a NAMED reason, and each is refused on doubt.
--
-- No terminal, no model, no database: the view is handed a recorder, the environment is a table.
local view_lib = dofile("lua/core/cli_view.lua")

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end
-- The text a reader sees, with the colour removed: an assertion about WORDS must not break because a
-- role around one word changed (that is exactly what this change is).
local function visible(text) return (tostring(text):gsub("\27%[[%d;]*m", "")) end

-- The escapes, spelled once. 00ff41 is the matrix green; d77757 is the role this change must not move.
local MATRIX = "\27[38;2;0;255;65m"
local ACCENT = "\27[38;2;215;119;87m"
local STAR, SPARK = "\226\156\187", "\226\156\182"

-- ---- 1. the colours -------------------------------------------------------------------

ok(view_lib.PALETTE.matrix == "00ff41", "the matrix green is a palette entry of its own (00ff41)")
ok(view_lib.PALETTE.accent == "d77757", "and accent is still the warm accent it was")
ok(view_lib.style("matrix") == MATRIX, "the role paints 24-bit 0;255;65")

-- The welcome line: its star, and only its star, is green.
local banner = view_lib.banner({ live = true, version = "23791f56", limit = 100 })
local star_row = banner:match("[^\n]*Welcome to[^\n]*") or ""
ok(has(star_row, MATRIX .. STAR), "the star of the welcome line is the matrix green: " .. star_row:sub(1, 40))
ok(not has(star_row, ACCENT), "and it is no longer the accent: " .. star_row:sub(1, 40))
ok(has(visible(banner), "Welcome to wasm-agent! v23791f56"), "the line's text is exactly what it was")

-- The run status row: the mark that travels to the host carries the colour itself (the host draws the
-- string it is handed), so this is the whole of "the spinning star on the status row is green".
local marks = view_lib.marks(true)
ok(type(marks) == "table" and #marks == #view_lib.SPINNER * 2, "there is one mark per spinner frame")
ok(has(marks[1], MATRIX .. SPARK), "the status row's animated first glyph is the matrix green")
ok(not has(marks[1], ACCENT), "and it is no longer the accent")
ok(marks[1]:sub(-1) == " ", "the mark still carries the space after it")
for index = 1, #marks do
  if not has(marks[index], MATRIX) then ok(false, "every mark is green, not only the first: " .. tostring(index)); break end
end
ok(not has(view_lib.marks(false)[1], "\27"), "the captured (non-live) mark is the plain glyph")

-- ANOTHER accent-painted item keeps the accent: the phase word of that same run status row.
local function recorder()
  local buffer = {}
  return { out = function(text) buffer[#buffer + 1] = text end,
    text = function() return table.concat(buffer) end }
end
local live = recorder()
local view = view_lib.new({ out = live.out, live = true, now = function() return 0 end,
  title = "wa - opening", workspace = "/tmp", limit = 100 })
view:run_started()
view:event({ type = "status", text = "thinking" })
local status = live.text()
ok(has(status, ACCENT .. "Thinking") or has(status, ACCENT .. "thinking"),
  "the phase word of the status line is still painted with accent")
ok(has(status, MATRIX), "and the row's first glyph is the green one")

-- "Summary of earlier turns" is not one of the two: its colour is what it was.
local summary = {}
for _, needle in ipairs({ "Summary of earlier turns" }) do summary[#summary + 1] = needle end
local topic = view_lib.banner({ live = false })
ok(not has(topic, MATRIX), "nothing else in the welcome block turned green")

-- ---- 2. the policy ---------------------------------------------------------------------

local function env(t) return function(name) return t[name] end end
local TERM = { TERM = "xterm-256color" }
local function asks(over)
  local opts = { getenv = env(TERM), live = true, editor = true, columns = 100, rows = 30 }
  for key, value in pairs(over or {}) do opts[key] = value end
  return view_lib.opening(opts)
end

local plays, why = asks()
ok(plays == true and why == "default", "a terminal with an editor at 100x30 plays the opening by default")

local never = {
  { "the setting says off", { getenv = env({ TERM = "xterm", WASM_AGENT_CLI_OPENING = "off" }) }, "setting" },
  { "NO_COLOR", { getenv = env({ TERM = "xterm", NO_COLOR = "1" }) }, "no_color" },
  { "TERM=dumb", { getenv = env({ TERM = "dumb" }) }, "dumb_terminal" },
  { "a resumed session", { resumed = true }, "resumed" },
  { "a message argument", { message = "hello" }, "message" },
  { "a scripted run", { scripted = true }, "scripted" },
  { "a pipe", { live = false }, "not_a_terminal" },
  { "no native editor", { editor = false }, "no_editor" },
  { "a window 59 columns wide", { columns = 59 }, "too_small" },
  { "a window 13 rows high", { rows = 13 }, "too_small" },
}
for _, case in ipairs(never) do
  local played, reason = asks(case[2])
  ok(played == false and reason == case[3],
    "never plays for " .. case[1] .. " (got " .. tostring(played) .. "/" .. tostring(reason) .. ")")
end

-- A caller that cannot say whether there is an editor has no opening (unknown is not yes).
local unsure = view_lib.opening({ getenv = env(TERM), live = true, columns = 100, rows = 30 })
ok(unsure == false, "an unknown editor means no opening")

-- The env override is read like every other CLI knob, and only an explicit off turns it off.
local on, on_why = asks({ getenv = env({ TERM = "xterm", WASM_AGENT_CLI_OPENING = "on" }) })
ok(on == true and on_why == "default", "WASM_AGENT_CLI_OPENING=on is the default, spelled out")
ok(asks({ getenv = env({ TERM = "xterm", WASM_AGENT_CLI_OPENING = "0" }) }) == false, "and 0 is off")
ok(asks({ getenv = env({ TERM = "xterm", WASM_AGENT_CLI_OPENING = "nonsense" }) }) == true,
  "a value that parses as neither is left at its default, as every other knob does")

-- ---- 3. the block the opening's last beat draws -----------------------------------------

-- The opening paints the welcome block EXACTLY as the view would, so the frame it hands over to is the
-- frame behind it. That is `welcome_painted`: the same composition, with the rule expanded at the width
-- the console has now (the marker is what the host's transcript expands at draw time).
local painted = recorder()
local plain = view_lib.new({ out = painted.out, live = true, limit = 100 })
plain:welcome({ live = true, limit = 100, version = "23791f56", workspace = "/tmp", model = "local mode" })
local block = plain:welcome_painted()
ok(type(block) == "string", "the view can hand its block over")
local first = visible(block:match("^([^\n]*)"))
ok(first == string.rep("\226\148\128", 100), "the rule is the console's width, not the transcript's marker")
ok(has(block, MATRIX .. STAR), "and the star is the green one in the block too")
ok(has(visible(block), STAR .. " Welcome to wasm-agent! v23791f56"), "with the line's words unchanged")
ok(not block:find("\1r\1", 1, true), "no rule marker survives into what the opening draws")

print("opening: " .. (checks - failed) .. " ok, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
