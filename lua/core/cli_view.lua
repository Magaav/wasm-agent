-- The live view `wa chat` prints: what the agent is doing right now, and what each
-- tool call actually did.
--
-- Why this exists. `wa chat` runs in a terminal (or in an orchestrator reading one),
-- and before this module a run printed `· <tool>` followed by 120 characters of
-- redacted JSON. Two properties of a CLI run made that unreadable rather than merely
-- plain, and both are worth stating because they are what the view is shaped around:
--
--   * The answer is never streamed here. Content deltas are written to the node's SSE
--     sink (`rust/wa-capabilities/src/host.rs`, `serve::write_event`), and a CLI run has no
--     sink, so the terminal shows tool noise for as long as the run lasts and the
--     reply only when it ends.
--   * A model call spends most of its time thinking, and nothing was printed for it
--     at all, so a run that is thinking and a run that is hung looked identical.
--
-- So the view keeps one thing on screen for as long as a run is in flight - what it is
-- doing, for how long, and which step - and prints one line per tool call that says
-- what was run and what came back, plus a footer with the numbers.
--
-- Two renderings of the same information, chosen once (`M.wants_live`):
--
--   live  - the status line is rewritten in place (`\r` and a pad over its own columns inline,
--           its own row padded and erased to the end of that row once a screen exists - never
--           erased and redrawn, which is what a reader saw as a blink on every tool call), colour
--           marks the phases, a spinner frame advances with each event, and the terminal title
--           carries the same word, so a reader watching another tab can still see it
--           running.
--   plain - one line per event, no escape sequences: an orchestrator, a pipe or a test
--           capturing this output must stay readable, and a line rewritten in place is
--           not a transcript.
--
-- What keeps the line moving cannot live in this process: Lua is blocked inside the model
-- call and inside a tool, so nothing here can repaint while one is in flight - a slow call
-- showed a frozen frame and a clock that had stopped, which is exactly what a hung run looks
-- like. The timer is therefore in the host (`host.ticker`, rust/wa-capabilities/src/host.rs), which
-- draws the same line between events: this module hands it the line and takes it back before
-- printing anything else. One limit does remain, and it is a different one - the *answer* is
-- not streamed here, because content deltas go to the node's SSE sink and a CLI run has no
-- sink.

local json = dofile("lua/vendor/json.lua")
-- The answer is markdown, and a terminal has to be told so: headings, bullets, fences and
-- inline code all arrive as punctuation without it. The renderer is its own module because
-- its wrapping rule - measure the plain text, paint last - is the whole of its design, and
-- because that rule is worth a test that needs no terminal.
local markdown = dofile("lua/core/markdown.lua")
-- One code-mode call, as a block that reads: heading with the tools it called, the script once, a row
-- per inner call, then the value. The rules (and why they are those rules) live there; this module
-- owns where the rows go - the running block streams, the one before it collapses to a line.
local codemode_block = dofile("lua/core/codemode_block.lua")
-- A file change as a block, rendered from the session's change store (lua/core/diff_view.lua).
-- Display only: the tool result the model reads is untouched.
local diff_view = dofile("lua/core/diff_view.lua")
-- Live reload (docs/HOTRELOAD.md). This module is one of the reloadable ones, so it reads the store the
-- core owns rather than keeping state of its own, registers every view it creates so a swap can point it
-- at the new methods, and ticks the watcher at each frame it begins: a save is visible on the next one.
local reload = dofile("lua/core/reload.lua")
-- The window the node actually compacts on (lua/core/model_window.lua): the context ball's COLOUR
-- is read from the thing that compacts, never from a second copy of the arithmetic. Loaded here so
-- the view asks one function (`threshold_percent`) instead of guessing a threshold (Victor, 19/11).
local windowlib = dofile("lua/core/model_window.lua")

local M = {}

-- ---- styling -------------------------------------------------------------------

-- Roles named after pi's theme (`@earendil-works/pi-coding-agent/.../theme/dark.json`), so a
-- component is coloured by what it *is* rather than by a literal at the call site. The values
-- follow Claude Code's dark terminal look: the warm accent for the spinner and the welcome mark,
-- grey borders and secondary text, green/red for a tool that worked or failed.
--
-- Truecolor is the point: these roles are 24-bit colours, and the terminals this runs in
-- (Windows Terminal, Orca's terminal, xterm-256color) render them. A terminal that does not
-- understand `38;2;r;g;b` ignores the sequence, so the degradation is uncoloured text -
-- visible, and not a garbled line. `NO_COLOR` still wins over all of it, and
-- `WASM_AGENT_CLI_VIEW=plain` turns colour off for a captured transcript.
local RESET = "\27[0m"
local PALETTE = {
  accent = "d77757", border = "888888", borderAccent = "b1b9f9", borderMuted = "505050",
  success = "4eba65", error = "ff6b80", warning = "ffc107", muted = "999999",
  -- Thinking is the view's one blue (`borderAccent`, the colour of inline code and links), so it
  -- reads as the agent's own work; commentary is said *to* the reader, so it is plain white.
  dim = "777777", text = "ffffff", thinkingText = "b1b9f9", commentaryText = "ffffff",
  -- A code-mode script's inner calls (operator 17/11): waiting ⏳ light yellow, done ✓ light green,
  -- failed ✗ a soft red - never the alarm red for a call that is only waiting.
  callWait = "e8d58a", callOk = "8fd19e", callFail = "e57373",
  mdHeading = "ffffff", mdLink = "8ab4f8", mdLinkUrl = "8ab4f8", mdCode = "b1b9f9",
  mdCodeBlock = "d4d4d4", mdCodeBlockBorder = "777777", mdQuote = "999999",
  mdQuoteBorder = "777777", mdHr = "777777", mdListBullet = "999999",
  toolDiffAdded = "4eba65", toolDiffRemoved = "ff6b80", toolDiffContext = "999999",
  -- The BANDS behind a removed/added row of the diff block (Victor 20/11: a red band and a green band,
  -- full width). Dark enough that the role's own foreground stays readable on them, and painted only
  -- when the view is live: the plain rendering carries the +/- marker instead.
  toolDiffAddedBand = "12301c", toolDiffRemovedBand = "3a1620",
  syntaxComment = "6a9955", syntaxKeyword = "569cd6", syntaxFunction = "dcdcaa",
  syntaxString = "ce9178", syntaxNumber = "b5cea8", syntaxType = "4ec9b0",
  -- The reasoning ramp, darkest to brightest: how much thinking the model was asked for.
  thinkingOff = "505050", thinkingMinimal = "6e6e6e", thinkingLow = "5f87af",
  thinkingMedium = "81a2be", thinkingHigh = "b294bb", thinkingXhigh = "d183e8",
  thinkingMax = "ff5fff",
  -- The matrix green (Victor, 22/11: the star of the welcome line and the animated first glyph of the
  -- run status row). Its OWN entry, so those two turn green without moving `accent`, which keeps
  -- painting the spinner's trail, the prompt mark and every other thing that was warm.
  matrix = "00d75f",
}

-- A role is a 24-bit colour (`rrggbb`), or `ansi:<n>` for one of the terminal's own palette slots,
-- which its theme decides.
local function fg(hex)
  local sgr = hex:match("^ansi:(%d+)$")
  if sgr then return "\27[" .. sgr .. "m" end
  return string.format("\27[38;2;%d;%d;%dm",
    tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end

local STYLE = { bold = "\27[1m", italic = "\27[3m", faint = "\27[2m", underline = "\27[4m" }

-- A code-mode block is drawn on a band: the background is what says "this ran inside the sandbox",
-- the way a fenced block reads in pi. 24-bit like every other role, and a terminal that cannot do it
-- degrades to no background rather than to garbled text.
local function bg(hex)
  return string.format("\27[48;2;%d;%d;%dm",
    tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end
STYLE.codeBand = bg("171717")
for role, hex in pairs(PALETTE) do STYLE[role] = fg(hex) end
-- The names the earlier view used, kept because callers and tests use them: each is now a
-- role rather than a literal, so `green` and `success` cannot drift apart.
STYLE.red = STYLE.error
STYLE.green = STYLE.success
STYLE.yellow = STYLE.warning
STYLE.cyan = STYLE.borderAccent
M.PALETTE = PALETTE
M.style = function(role) return STYLE[role] end

-- Colour is a rendering decision, never a fact: every caller passes `live`, and the plain
-- rendering is the same text without it. A style is one role or a list of them
-- (`{ "bold", "mdHeading" }`), which is how a heading is both at once.
local function paint(text, style, live)
  if not live or not style then return text end
  local codes = ""
  if type(style) == "table" then
    for _, name in ipairs(style) do codes = codes .. (STYLE[name] or "") end
  else
    codes = STYLE[style] or ""
  end
  if codes == "" then return text end
  return codes .. text .. RESET
end
M.paint = paint

-- A star that grows, then shrinks: · • ✧ ✦ ✶ ✳ ✷ ✸ ✹ ✺ and back. It starts mid-cycle (✶) so the
-- first frame is never `·`, which is also this view's separator. Each frame is held for two of the
-- host's ticks, so the cycle breathes rather than flickers.
local SPINNER = { "\226\156\182", "\226\156\179", "\226\156\183", "\226\156\184", "\226\156\185",
  "\226\156\186", "\226\156\185", "\226\156\184", "\226\156\183", "\226\156\179", "\226\156\182",
  "\226\156\166", "\226\156\167", "\226\128\162", "\194\183", "\226\128\162", "\226\156\167", "\226\156\166" }
local HOLD = 2
M.SPINNER = SPINNER

function M.spinner(frame)
  return SPINNER[(math.floor(math.max(0, math.floor(frame or 0)) / HOLD) % #SPINNER) + 1]
end

-- The marks the animated line cycles, each carrying the space that separates it from the
-- phase. They travel to the host rather than being rebuilt there, so the frames on screen are
-- the same characters in the same order as the ones this module prints for itself.
function M.marks(live)
  local list = {}
  for index = 1, #SPINNER * HOLD do list[index] = paint(M.spinner(index - 1), "matrix", live) .. " " end
  return list
end

-- The marks the transcript uses: a step (`⏺`), what it returned (`⎿`), and the welcome glyph.
local DOT, RESULT, STAR = "\226\143\186", "\226\142\191", "\226\156\187"
-- The prompt glyph, Claude Code's `❯` (U+276F: three bytes, one cell), on the input row and on the
-- reader's own turn in the transcript. `rust/wa-term/src/terminal_editor.rs` (`PROMPT`) is its twin.
local PROMPT = "\226\157\175 "
M.PROMPT = PROMPT
local SPARKLE = "\226\156\166" -- ✦, the UI's commentary glyph
M.DOT, M.RESULT = DOT, RESULT

-- ---- text ----------------------------------------------------------------------

-- One line, clipped to what a terminal can show. The count is *columns*, not bytes:
-- `·` is two bytes and one column, `↑` three and one, so a byte limit makes a line that
-- fits look like it does not - and it is also what keeps a cut from landing inside a
-- character, which is a rendering bug rather than a cosmetic one.
local columns = markdown.columns -- cells, not characters: the one rule (see markdown.lua)
M.columns = columns

-- The same count over text that carries escape sequences: what a terminal actually shows. The
-- status line is padded to the width it last drew, and a pad counted over the *bytes* of
-- `\27[33m` would be a pad of the wrong size on screen - with the reader's own typing, which
-- starts one column after that line ends, taking the difference.
local function visible_columns(text)
  local plain = tostring(text or ""):gsub("\27%[[%d;]*m", ""):gsub("\27%]2;[^\7]*\7", "")
  return columns(plain)
end
M.visible_columns = visible_columns

-- CSI cursor save/restore is supported by Windows and Unix VT terminals. Hide
-- the cursor during output; the native writer finally places it at the draft's
-- actual cursor because ConPTY may move saved positions when output scrolls.
local CURSOR_SAVE, CURSOR_RESTORE = "\27[?25l\27[s", "\27[u\27[?25h"

-- DEC private mode 2026, synchronized output: between these two sequences the terminal holds what
-- it is given and paints it as one update. One frame here rewrites several rows - the transcript,
-- the status line, the footer, the session-status-content line - and without this a terminal may
-- show that half-drawn (a row committed while the row under it still belongs to the last frame).
-- A terminal that does not know the mode ignores both sequences, which is the whole of the
-- degradation: two short escapes and nothing on screen.
local SYNC_START, SYNC_END = "\27[?2026h", "\27[?2026l"
M.SYNC_START, M.SYNC_END = SYNC_START, SYNC_END

local function clip(text, limit)
  text = tostring(text or ""):gsub("%s+", " ")
  if not limit or limit <= 0 or columns(text) <= limit then return text end
  local index, kept = 1, 0
  while index <= #text do
    local size, cells = markdown.char_at(text, index)
    if kept + cells > limit - 1 then break end
    index = index + size
    kept = kept + cells
  end
  return text:sub(1, index - 1) .. "\226\128\166"   -- …
end
M.clip = clip

-- A horizontal rule that is as wide as the terminal WHEN IT IS DRAWN, not when it was composed.
--
-- A rule is the one component that is nothing but its width, so a measured-once width leaves it wrong
-- for the rest of the session: the welcome box's top line sat at the old width after a maximise, and
-- wider than the window after a shrink, which wraps it into a second row and moves everything below it
-- (Victor, 18/11). So the view writes a MARKER and the renderer that knows the current width expands
-- it: `rust/wa-term/src/transcript.rs` at draw time for the native editor, and `M.expand_rules` here
-- for the plain layout, where the write itself is the only moment there is.
--
-- `r` is one marker. Nothing else in this module emits a bare , so the expansion cannot touch
-- text a tool printed.
local RULE_MARK = "r"
M.RULE = RULE_MARK

-- `text` with every rule marker drawn as `n` rule characters - the plain layout's expansion, where a
-- line is written once and a rule is therefore fixed at the width of that write.
function M.expand_rules(text, limit)
  text = tostring(text or "")
  if not text:find(RULE_MARK, 1, true) then return text end
  local width = math.max(1, tonumber(limit) or 80)
  return (text:gsub("\1r\1", function() return string.rep("\226\148\128", width) end))
end

-- The same fit without collapsing runs of whitespace: a code row's indentation is part of what it
-- says, and `clip` is a prose rule (`a  b` -> `a b`). Everything else about it is the same count.
local function fit(text, limit)
  text = tostring(text or "")
  if not limit or limit <= 0 or columns(text) <= limit then return text end
  local index, kept = 1, 0
  while index <= #text do
    local size, cells = markdown.char_at(text, index)
    if kept + cells > limit - 1 then break end
    index = index + size
    kept = kept + cells
  end
  return text:sub(1, index - 1) .. "\226\128\166"
end
M.fit = fit

function M.tokens(count)
  local n = tonumber(count) or 0
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return string.format("%d", math.floor(n))
end

function M.duration(seconds)
  local s = tonumber(seconds) or 0
  if s < 60 then return string.format("%.1fs", s) end
  return string.format("%dm%02ds", math.floor(s / 60), math.floor(s % 60))
end

-- The status line's clocks, twins of `ticker_step` / `ticker_clock` in rust/wa-capabilities/src/host.rs:
-- the current step in whole seconds (`5s`, `1m05s`), the whole run as `m:ss`.
function M.step_clock(seconds)
  local s = math.max(0, math.floor(tonumber(seconds) or 0))
  if s < 60 then return s .. "s" end
  return string.format("%dm%02ds", math.floor(s / 60), s % 60)
end
-- The wall clock a finished run leaves behind: HH:MM in the READER'S zone, 24 h.
--
-- Deliberately the reader's zone and not UTC: every other timestamp in the ledger is UTC because a
-- fleet compares them, and this one is not a fact about the fleet - it is "when did that answer come
-- back", which the person reading it asks in the clock on their own wall. The epoch is passed in,
-- so a test clock decides the moment and not the wall the suite happens to run on.
function M.finish_time(epoch)
  local at = tonumber(epoch)
  if not at then return "" end
  return os.date("%H:%M", math.floor(at))
end

function M.run_clock(seconds)
  local s = math.max(0, math.floor(tonumber(seconds) or 0))
  if s < 3600 then return string.format("%d:%02d", math.floor(s / 60), s % 60) end
  return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end

-- ---- the status bar's glyphs -------------------------------------------------------
--
-- A glyph is a FONT fact, not a rendering choice, so every one the terminal's two status rows draw is
-- named here, once. Victor measured the set these replace in his own terminal (18/11, JetBrainsMono
-- Nerd Font): U+25D1 (`◑`) and U+25F7 (`◷`) are NOT in that font, so the terminal takes them from a
-- fallback face and draws them at another size, and `👣` is a colour emoji - it ignores the row's
-- colour and takes two cells. What is here instead is Nerd Fonts' Material Design set: in the font,
-- one cell per glyph, drawn in the row's own colour, one glyph per fact. The width is asserted by the
-- two functions that actually lay these rows out - `M.columns` (the count `clip` and the status line
-- use) and `wa-term`'s `cell_width_of` for the box the row sits in - because a glyph two cells
-- wide moves every number after it.
-- The icons and the gap between an icon and its value come from ONE table, by set (item 4 of the
-- wa-fonts mission, Victor 19/11). This module USES the set; lua/core/icons.lua decides what each set
-- draws. The DELTA, UP, DOWN and SIGMA marks are TEXT, not icons: they stay glued to their number.
local icons = dofile("lua/core/icons.lua")
M.icons = icons

-- The active set, resolved once at load (env > config > what this terminal is drawing > unicode) and
-- moved by /icons. Every row below asks GLYPH/GAP/BALLS, so one call re-draws them all.
local resolved = icons.resolve(host.getenv("WA_ICONS"))
local active = resolved

local GAP, GLYPH, BALLS

-- Adopt one set: its glyphs, its gap, and its nine balls. Refuses an unknown name by name.
function M.use_icons(name)
  local set, why = icons.set(name)
  if not set then return nil, why end
  GAP = set.gap
  GLYPH = set
  -- NINE states, EIGHT slices: context_ball's k is the nearest eighth (1..8), so the empty ball is
  -- asked for by name and never by index. Taking the nine as they come put every reading one slot low -
  -- 93.75% drew the seventh slice - which only a render check on each set can see.
  local nine = icons.balls(icons.valid(name))
  BALLS = {}
  for index = 2, 9 do BALLS[index - 1] = nine[index] end
  M.GAP, M.GLYPH, M.BALLS = GAP, GLYPH, BALLS
  active = { set = icons.valid(name), source = "use_icons" }
  return true
end

-- What this process draws, and why: the reader /icons and the status line ask.
function M.icon_set() return active.set, active.source end

assert(M.use_icons(active.set))
-- THE REASON SURVIVES THE ADOPTION. Measured 21/11 (item 5): use_icons() replaces the active record with
-- source = "use_icons", so /icons printed "(use_icons)" at start-up and threw away the one thing that
-- tells an operator WHY this window draws what it draws - which face wa found, and when the window
-- started. The resolved source is put back here, and /icons <set> keeps saying what the operator did.
active.source = resolved.source


-- ONE function decides which ball a context percentage wears: five bands, each starting at its own
-- floor - 3% is the second ball, 50% the third, 75% the fourth, 100% the full one. A context measured
-- past its window (it happens across a compaction boundary) is the full ball, and a percentage nobody
-- measured is the empty one - the same ball 0% wears, because "nothing measured" is not "nearly full".
-- The ball for a context percentage: the nearest eighth, with an empty floor below 3%.
--
-- The floor is there because "nothing measured" is not "nearly full": a context with no reading at all
-- (0%) and one just starting (2.9%) both wear the empty ball. From 3% - the first eighth's floor - the
-- ball is the nearest eighth of the window, so the 8 slices are wired up.
function M.context_ball(percent)
  local p = tonumber(percent) or 0
  if p < 3 then return GLYPH.ballEmpty end
  local k = math.floor(p / 100 * 8 + 0.5)     -- half UP: a boundary belongs to the higher eighth
  if k < 1 then k = 1 end
  if k > 8 then k = 8 end
  return BALLS[k]
end

-- How full the window is, as the word a colour is chosen from: normal, warning, alert.
--
-- The threshold is the node's REAL one, read from the code that compacts (model_window.policy, through
-- model_window.threshold_percent) and never guessed here: normal below it by 15 points, warning from
-- there, alert at or above it. With no window to measure against everything is normal - a colour is a
-- claim about the window, and there is no window to make it about.
function M.context_level(percent, threshold)
  local p = tonumber(percent)
  local t = tonumber(threshold) or 0
  if not p or t <= 0 then return "normal" end
  if p >= t then return "alert" end
  if p >= t - 15 then return "warning" end
  return "normal"
end
-- The colour the ball wears, from the same level: the window's own signal, not decoration.
--
-- NORMAL IS NO COLOUR OF ITS OWN (Victor, 19/11 09:05). A ball with room is a fact in the row like
-- the step count, the clock, the turn count and the cache rate beside it, so it wears exactly what
-- those wear - the row's own secondary colour, whatever role that row happens to paint (the run row
-- says "muted", the session bar under the box says "dim"). Returning nil says that: the caller paints
-- nothing and the glyph inherits its neighbours, so the ball cannot be the one shade that disagrees
-- with the four icons it sits between.
--
-- It was the success green, and green is not this row's icon pattern: on a status row a colour MEANS
-- something, so it may only appear when the window is a problem. warning is the amber from
-- threshold-15, alert the alarm red at the compaction trigger. Nothing measured is normal: a colour is
-- a claim about the window, and an unmeasured window makes none.
function M.ball_role(level)
  if level == "alert" then return "error" end
  if level == "warning" then return "warning" end
  return nil
end

-- The reserve the COMPACTOR will actually use for a model, or nil when this host cannot say.
--
-- `provider.budget(model).reserve` is the one number `agent.maybe_compact` spends, and it is not
-- `model_window.policy`'s: it honours WASM_AGENT_COMPACT_RESERVE and the per-model `reserve` in
-- WASM_AGENT_MODEL_LIMITS, and it caps the result at a quarter of the window. The ball used to ask
-- model_window for the threshold with NO reserve, so a node that had set either escape hatch was
-- coloured against a trigger the compactor never uses - the ball said "alert" at 90% while the
-- compactor waited for 87% (round 3, item 4).
--
-- Loaded once, on the first row that needs it: a dofile per frame is a disk read on the footer's
-- path (the reason windowlib above is loaded once). `false` means "cannot say", never "no reserve".
local providerlib
local function compactor_budget(model)
  if providerlib == nil then
    local ok, loaded = pcall(dofile, "lua/core/provider.lua")
    providerlib = (ok and type(loaded) == "table") and loaded or false
  end
  if not providerlib or type(providerlib.budget) ~= "function" then return nil end
  local ok, budget = pcall(providerlib.budget, model)
  return ok and type(budget) == "table" and budget or nil
end

-- The percentage of the window at which THIS node compacts, from the code that compacts
-- (model_window.threshold_percent), WITH the reserve the compactor will use. nil when the window is
-- unknown, which colours nothing.
--
-- `model` is optional (a caller with no model gets the policy's default reserve, which is what a
-- fresh node uses); every view passes its own, so the ball and the compactor agree.
function M.compaction_threshold(budget, model)
  if not windowlib or not windowlib.threshold_percent then return nil end
  local context = tonumber(budget) or 0
  if context <= 0 then return nil end
  -- A reserve from ANOTHER window is not this window's. provider.budget resolves the same model, so a
  -- mismatch means the caller's window and the compactor's came from different models, and then the
  -- policy's own reserve is the only honest answer.
  local reserve
  local resolved = compactor_budget(model)
  if resolved and tonumber(resolved.context) == context then reserve = tonumber(resolved.reserve) end
  local ok, threshold = pcall(windowlib.threshold_percent, context, reserve)
  return ok and tonumber(threshold) or nil
end

-- The footer's session numbers: `󰑐runs Σ↑in Σ↓out 󰪟ctx%/window 󰆼cache-hit%`. `Σ↑` is every
-- request's input summed (each step resends the context), so it is marked apart from the run line's
-- `Δ` - what one run ADDED to the context (operator 17/11: "why do these differ?"). No tool count:
-- with code mode one script makes many calls, so the number said nothing (operator 17/11). The ball is
-- the one `M.context_ball` chose, so the band and the percentage beside it cannot disagree.
function M.session_summary(t)
  t = t or {}
  -- BOTH totals wear the SIGMA (Victor, 19/11 ~10:50: the row reads
  -- `1 Σ↑9.5k Σ↓851`): they are the session's two SUMS, and the arrow alone read as the last
  -- call's input and output. The arrow says the direction, the sigma says it is a total.
  local parts = { GLYPH.turns .. GAP .. (t.runs or 0),
    "\206\163\226\134\145" .. M.tokens(t.prompt) .. " \206\163\226\134\147" .. M.tokens(t.completion) }
  -- The percentage this row was built from, returned beside the text: it chose the glyph, and the
  -- colour must come from the SAME number rather than one measured again at draw time.
  local used
  if (tonumber(t.budget) or 0) > 0 then
    local percent = 100 * (tonumber(t.context) or 0) / t.budget
    used = percent
    -- The percentage stays printed after the ball, one space apart (Victor, 19/11).
    parts[#parts + 1] = M.context_ball(percent) .. GAP
      .. string.format("%.1f%%/%s", percent, M.tokens(t.budget))
  end
  if (tonumber(t.prompt) or 0) > 0 then
    parts[#parts + 1] = GLYPH.cache .. GAP .. string.format("%.2f%%", 100 * (t.cached or 0) / t.prompt)
  end
  return table.concat(parts, " "), used
end

-- The session bar with its CONTEXT BALL in the colour of its level, and the rest of the row left in
-- the secondary gray it was drawn in: the role opens at the glyph, closes after it, and the dim
-- colour is re-opened so one glyph's warning does not bleed into the percentage beside it
-- (Victor, 19/11: the percentage stays printed after the ball).
--
-- Colour is a rendering decision, so `live` is honoured exactly like every other paint here: a
-- captured transcript gets the same characters, uncoloured. A window nobody measured (budget 0) or
-- a bar with no ball in it is returned untouched.
-- The ball a row ACTUALLY DREW, and where: the first of the nine that the text carries, or nil.
--
-- Why not recompute it from the percentage: the footer's glyph and the glyph this function would
-- choose are two separate arithmetics over the same number, and the moment they disagree - a row
-- built from a stale summary, a percentage rounded elsewhere, a row clipped before the ball - the
-- search finds nothing and the ball is drawn UNCOLOURED, silently. Reading the glyph off the text
-- is the only way the colour and the character cannot disagree (round 3, item 4).
function M.ball_in(text)
  local row = tostring(text or "")
  for _, glyph in ipairs(BALLS) do
    local at = row:find(glyph, 1, true)
    if at then return glyph, at end
  end
  local at = row:find(GLYPH.ballEmpty, 1, true)
  if at then return GLYPH.ballEmpty, at end
  return nil, nil
end

function M.colour_ball(text, context, budget, live, model, percent)
  text = tostring(text or "")
  local window = tonumber(budget) or 0
  if not live or window <= 0 then return text end
  -- The percentage behind the level: the caller that composed the row hands over the one it used, so
  -- the colour and the glyph are the same reading. A caller holding only a row measures it here.
  percent = tonumber(percent) or (100 * (tonumber(context) or 0) / window)
  local ball, at = M.ball_in(text)
  if not ball then return text end
  local level = M.context_level(percent, M.compaction_threshold(window, model))
  local role = M.ball_role(level)
  -- A level with no role of its own (normal) leaves the row byte for byte as it came: the glyph then
  -- wears the row's own secondary colour, exactly like the steps, clock, turn and cache icons.
  if not role then return text end
  local painted = paint(ball, role, true) .. (STYLE.dim or "")
  return text:sub(1, at - 1) .. painted .. text:sub(at + #ball)
end

-- How long a step took: milliseconds below a second, seconds above it. The unit is
-- carried because "0.2s" and "200ms" are the same number and only one of them is how
-- a person reads a fast call.
function M.elapsed(ms)
  local value = tonumber(ms)
  if not value or value < 0 then return "" end
  if value < 1000 then return string.format("%dms", math.floor(value)) end
  return string.format("%.1fs", value / 1000)
end

-- ---- what a call is ------------------------------------------------------------

-- The verb in the status line, so "running" is not the only word the reader ever sees.
local PHASE = {
  bash = "Running", shell = "Running", read = "Reading", write = "Writing",
  edit = "Editing", grep = "Searching", ls = "Listing", recall = "Recalling",
  remember = "Remembering", memories = "Reading memory", forget = "Forgetting",
  search_messages = "Searching history",
  skill = "Loading a skill",
  subagent = "Waiting on a subagent", nodes = "Asking the fabric", remote = "Asking a peer",
  spell_run = "Running a spell", spell_save = "Saving a spell", operation = "Supervising an operation",
  client = "Driving the machine", diagnose = "Diagnosing", graph = "Walking the graph",
  capabilities = "Listing capabilities", tool_call = "Running a batch:",
}

function M.phase(name)
  if not name or name == "" then return "Thinking" end
  return (PHASE[name] or "Working:") .. " " .. name
end

-- What the call was given. The words are the web UI's (`toolTitle` in `ui/app.js`) so
-- the two surfaces describe the same call the same way.
function M.call_line(name, args, limit)
  local a = (type(args) == "table") and args or {}
  local path = tostring(a.path or a.file_path or "")
  limit = limit or 96
  if name == "tool_call" and type(a.calls) == "table" then
    return string.format('%d independent requests',#a.calls)
  elseif name == "bash" or name == "shell" then
    return "$ " .. clip(a.command or "", limit)
  elseif name == "read" then
    local range = (a.offset or a.limit)
      and string.format(" (lines %d-%s)", a.offset or 1,
        a.limit and (math.floor(tonumber(a.offset) or 1) + math.floor(tonumber(a.limit)) - 1) or "")
      or ""
    return clip(path .. range, limit)
  elseif name == "write" or name == "edit" then
    return clip(path, limit)
  elseif name == "grep" then
    return clip("/" .. tostring(a.pattern or "") .. "/" .. (a.path and (" in " .. tostring(a.path)) or ""), limit)
  elseif name == "ls" then
    return clip(path ~= "" and path or ".", limit)
  elseif name == "recall" or name == "search_messages" or name == "search" then
    return clip(a.query or "", limit)
  elseif name == "remember" then
    return clip(a.content or a.text or "", limit)
  elseif name == "skill" then
    return clip(a.name or "", limit)
  elseif name == "subagent" then
    return clip(a.prompt or a.task or "", limit)
  elseif name == "forget" then
    return clip(a.id or "", limit)
  elseif name == "remote" or name == "client" or name == "operation" then
    return clip((a.action or a.capability or "") .. (a.node and (" " .. a.node) or ""), limit)
  elseif name == "codemode" then
    -- A script is not an argument to summarise: its first line names it, and the rows under the
    -- heading are the script itself (`M.code_rows`, #121).
    return clip(M.code_rows(a, 1)[1] or "", limit)
  end
  -- Unknown tool (a plugin, a new capability): show its first scalar arguments rather
  -- than nothing, because a name alone does not say what was asked for.
  local parts = {}
  for key, value in pairs(a) do
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      parts[#parts + 1] = key .. "=" .. tostring(value)
    end
    if #parts >= 3 then break end
  end
  table.sort(parts)
  return clip(table.concat(parts, " "), limit)
end

-- A code-mode call's script, as rows (#121). The reader saw ONE row of it - the whole script clipped
-- into `code=...` - so a call that rewrote three files read as a single truncated line, and the
-- script itself was only available through `/console`. The block gets the first `count` lines (three
-- in the transcript, where the fold shows three rows and `->` expands the rest), and the count of
-- what it left out for the caller's `... +N lines` marker.
--
-- `json.encode` is the fallback for a script that arrives as anything but text: a model that sent
-- `arguments` in another shape still gets its call shown rather than an empty block.
function M.code_rows(args, count)
  local a = (type(args) == "table") and args or {}
  local code = a.code
  if code == nil and type(a.script) == "string" then code = a.script end
  if code == nil then return {}, 0 end
  if type(code) ~= "string" then code = json.encode(code) end
  local lines = {}
  for line in (tostring(code):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("%s+$", ""))
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  local rows, hidden = {}, 0
  for index, line in ipairs(lines) do
    if index <= (count or 3) then rows[#rows + 1] = line else hidden = hidden + 1 end
  end
  return rows, hidden
end

-- The call as a heading, the way Claude Code writes one: a capitalised tool name and what it was
-- given in parentheses - `Bash(npm test)`, `Read(src/main.rs)`, `Search(pattern: "foo")`.
local TITLE = {
  bash = "Bash", shell = "Bash", read = "Read", write = "Write", edit = "Update", grep = "Search",
  ls = "List", subagent = "Task", skill = "Skill", recall = "Recall", remember = "Remember",
  search_messages = "Search", remote = "Remote", client = "Client", codemode = "CodeAct",
}

-- The tool that actually ran. `tool_call` routes a call to another tool by name, and `remote` runs
-- one on a peer; a line that named the wrapper (`tool_call name=remote`) said a call happened and
-- nothing about what it did. So both are unwrapped to the inner tool and its arguments, plus the
-- peer for `remote`, and that tool's own summariser and outcome describe it. The batch form
-- (`tool_call{calls}`) and a page cursor are not one tool, and stay `tool_call`.
function M.target(name, args)
  local a = (type(args) == "table") and args or {}
  local node
  if name == "tool_call" and type(a.name) == "string" and a.calls == nil and a.cursor == nil then
    name, a = a.name, (type(a.arguments) == "table") and a.arguments or {}
  end
  if name == "remote" and type(a.capability) == "string" and a.capability ~= "" then
    node = tostring(a.node or "?")
    name, a = a.capability, (type(a.args) == "table") and a.args or {}
  end
  return name, a, node
end

-- A batch's calls as one heading: each inner call as its own title would read, in order.
local function batch_inside(a, limit)
  if a.cursor ~= nil then return "next page" end
  local parts = {}
  for _, call in ipairs(type(a.calls) == "table" and a.calls or {}) do
    local label, inside = M.tool_title(type(call) == "table" and call.name or "?",
      type(call) == "table" and call.arguments or nil, 48)
    parts[#parts + 1] = label .. ((inside ~= "") and ("(" .. inside .. ")") or "")
  end
  return clip(table.concat(parts, " \194\183 "), limit)
end

function M.tool_title(name, args, limit)
  name = tostring(name or "?")
  local a = (type(args) == "table") and args or {}
  if name == "tool_call" and (a.calls ~= nil or a.cursor ~= nil) then
    return "Batch", batch_inside(a, math.max(8, (limit or 96) - 7))
  end
  local inner, inner_args, node = M.target(name, a)
  if inner ~= name then
    -- `Remote openclaw · Bash(git status)`: the peer in the heading, the call as it would read here.
    local peer = node and ("Remote " .. clip(node, 24) .. " \194\183 ") or ""
    local label, inside = M.tool_title(inner, inner_args, (limit or 96) - columns(peer))
    return peer .. label, inside
  end
  local label = TITLE[name] or (name:sub(1, 1):upper() .. name:sub(2))
  -- A code-mode call's heading is `⏺ Code` and nothing else: its tools are named on the heading the
  -- block draws (`lua/core/codemode_block.lua`), and the script is never in a heading (#121 put its
  -- first line there, which made the heading a second copy of the body).
  if name == "codemode" then return "CodeAct", "" end
  limit = math.max(8, (limit or 96) - #label - 2)
  local inside
  if name == "bash" or name == "shell" then
    inside = clip(a.command or "", limit)
  elseif name == "grep" then
    inside = clip('pattern: "' .. tostring(a.pattern or "") .. '"'
      .. (a.path and (', path: "' .. tostring(a.path) .. '"') or ""), limit)
  else
    inside = M.call_line(name, args, limit)
  end
  return label, inside
end

-- Whether the call worked, in the caller's terms: `ok` is false when the tool returned
-- an error or a non-zero exit code, and the second value is what to say about it.
-- A routed result is the inner tool's own result, and a peer's can arrive as JSON text.
local function routed_result(result)
  if type(result) == "string" and result:match("^%s*{") then
    local decoded_ok, decoded = pcall(json.decode, result)
    if decoded_ok and type(decoded) == "table" then return decoded end
  end
  return result
end

-- One routed batch item, as a line: the call, then what it returned or why it failed.
local function batch_line(call, item)
  local name = type(call) == "table" and call.name or "?"
  local label, inside = M.tool_title(name, type(call) == "table" and call.arguments or nil, 48)
  local ok, note = M.outcome(name, item)
  if item == nil then ok, note = false, "not in this page" end
  return label .. ((inside ~= "") and ("(" .. inside .. ")") or "") .. " \226\134\146 "
    .. (ok and (note ~= "" and note or "done") or ("failed: " .. (note ~= "" and note or "?"))), ok
end

-- `args` is what the call was given: with it, `tool_call` and `remote` are judged as the tool that
-- ran (`exit 1` is a failure whichever wrapper carried it). Without it, a routed result is still
-- read for the facts every tool shares: an error, `ok: false`, an exit code.
function M.outcome(name, result, args)
  if name == "tool_call" or name == "remote" then
    result = routed_result(result)
    local r = (type(result) == "table") and result or {}
    if r.error then
      return false, clip(tostring(r.error) .. (r.detail and (": " .. tostring(r.detail)) or ""), 80)
    end
    local a = (type(args) == "table") and args or {}
    if name == "tool_call" and (a.calls ~= nil or a.cursor ~= nil or type(r.results) == "table") then
      local total = tonumber(r.total) or #(type(r.results) == "table" and r.results or {})
      local failed = tonumber(r.failed) or 0
      return r.ok ~= false and failed == 0, string.format("%d call%s; %d failed%s", total,
        total == 1 and "" or "s", failed, r.has_more and "; more pages" or "")
    end
    local inner = M.target(name, a)
    if inner ~= name then return M.outcome(inner, result) end
    if r.code ~= nil then return M.outcome("bash", result) end
    if r.ok == false then return false, "failed" end
    return true, ""
  end
  local r = (type(result) == "table") and result or {}
  if r.error then return false, clip(r.error, 80) end
  if name == "tool_call" and type(r.results)=='table' then
    return r.ok==true,string.format('%d items; %d failed; %d not run',#r.results,r.failed or 0,r.not_run or 0)
  end
  if name == "read" then
    local lines = select(2, tostring(r.content or ""):gsub("\n", ""))
    return true, string.format("%d lines", lines)
  elseif name == "bash" or name == "shell" then
    local code = r.code
    return code == 0 or code == nil, string.format("exit %s", code == nil and "?" or tostring(code))
  elseif name == "grep" then
    local count = tonumber(r.count) or 0
    return true, string.format("%d match%s", count, count == 1 and "" or "es")
  elseif name == "ls" then
    return true, string.format("%d entries", #(type(r.entries) == "table" and r.entries or {}))
  elseif name == "write" or name == "edit" then
    return true, "written"
  elseif name == "remember" then
    return true, "stored"
  elseif name == "forget" then
    return r.forgotten and true or false, r.forgotten and "removed" or "not found"
  elseif name == "recall" or name == "memories" then
    return true, string.format("%d memories", type(r) == "table" and #r or 0)
  elseif name == "search_messages" then
    local matches = type(r) == "table" and (r.matches or r) or {}
    return true, string.format("%d messages", #(type(matches) == "table" and matches or {}))
  elseif name == "skill" then
    return true, "loaded"
  elseif name == "subagent" then
    return r.ok ~= false, tostring(r.status or r.outcome or "finished")
  elseif name == "operation" then
    return r.ok ~= false, tostring(r.state or "observed")
  end
  if type(result) == "string" then return true, clip(result, 60) end
  if r.ok == false then return false, "failed" end
  return true, ""
end

-- The files a shell command changed while it ran (Victor 20/11), as one block: each file with its
-- +N -M and its own diff card, and a dim line for a file whose diff cannot honestly be drawn. The
-- rows come from the same renderer a write/edit uses (lua/core/diff_view.lua), so the frame, the
-- line numbers and the widths are one rule. Bounded twice: the snapshot caps how many files are
-- read (lua/core/bash_changes.lua), and this caps how many rows each file shows.
function M.bash_changes_block(event, width, live)
  local files = type(event) == "table" and type(event.files) == "table" and event.files or {}
  local refused = type(event) == "table" and type(event.refused) == "table" and event.refused or {}
  if #files == 0 and #refused == 0 then return nil, "no_changes" end
  local out = {}
  for _, file in ipairs(files) do
    local lines = M.diff_block({ path = file.path, before_text = file.before_text,
      after_text = file.after_text, deleted = file.deleted }, width, live)
    for _, row in ipairs(lines or {}) do out[#out + 1] = row end
  end
  -- A file whose starting text is not known is NAMED, never drawn with a guessed one: a reader who
  -- cannot see the diff must be told why, or an empty block reads as no change.
  for _, item in ipairs(refused) do
    out[#out + 1] = paint("b91 " .. tostring(item.path) .. " changed ("
      .. tostring(item.why):gsub("_%a", function(s) return " " .. s:sub(2) end) .. ")", "dim", live)
  end
  return out
end
-- A file change, as the rows a reader follows it by: the path and its counts, then the diff with
-- real line numbers, removed rows on a red band and added rows on a green one, a few context rows and
-- an ellipsis between hunks. The frame is a fence's (lua/core/diff_view.lua), so the host keeps it
-- whole at any width; width is the view's own, so a resize re-renders instead of clipping.
--
-- Returns the lines to write, or nil and why there is nothing honest to show. change carries the two
-- content addresses the tool result already names (previous_version and version), not the texts: this
-- reads them from the session's change store, which is where changeset.record put them.
local BANDS = { ["+"] = "toolDiffAddedBand", ["-"] = "toolDiffRemovedBand" }
function M.diff_block(change, width, live)
  if type(change) ~= "table" then return nil, "no_change" end
  -- Two texts may arrive already read (a shell command change, lua/core/bash_changes.lua): then
  -- they ARE the diff, and the content addresses are not consulted at all.
  local before, after
  if type(change.before_text) == "string" and type(change.after_text) == "string" then
    before, after = change.before_text, change.after_text
  else
    before, after = diff_view.texts(change)
  end
  if before == nil then return nil, tostring(after or "no_text") end
  local block = diff_view.rows({ path = change.path, before = before, after = after,
    deleted = change.deleted }, { width = width })
  local out = {}
  for _, row in ipairs(block.rows) do
    if row.kind == "open" or row.kind == "close" then
      out[#out + 1] = paint(row.lead, row.role, live)
    else
      local band = row.band and BANDS[row.band] or nil
      local base = { row.role or "text", band }
      -- Syntax colour inside the row, from the same walker a fence uses: one definition of what a
      -- keyword or a string looks like in this terminal. A row that is context (unchanged) keeps the
      -- diff colour alone, because a hunk is read for what changed.
      local body = row.code or ""
      local painted = {}
      if row.op ~= " " and row.lang and row.lang ~= "" then
        markdown.scan_code(body, row.lang, function(text, style)
          if text == "" then return end
          painted[#painted + 1] = paint(text, style and { style, band } or base, live)
        end)
      end
      out[#out + 1] = paint(row.lead, { "mdCodeBlockBorder", band }, live)
        .. (#painted > 0 and table.concat(painted) or paint(body, base, live))
    end
  end
  return out
end

-- The lines worth showing under a result. Only where output *is* the answer: a command's
-- own words, or why it failed. A file's contents, a memory, a page of grep matches are
-- not repeated here - they are in the transcript, and repeating them is how a terminal
-- becomes a wall.
function M.preview(name, result, lines, args)
  if name == "tool_call" or name == "remote" then
    result = routed_result(result)
    local a = (type(args) == "table") and args or {}
    local r = (type(result) == "table") and result or {}
    if name == "tool_call" and not r.error and type(r.results) == "table" then
      -- A batch: one line per call, so each says what it was and what came back.
      local calls = type(a.calls) == "table" and a.calls or {}
      local first = math.floor(tonumber(r.first_index) or 1)
      local out, hidden = {}, 0
      for index, item in ipairs(r.results) do
        if #out < (lines or 2) then
          local call = calls[first + index - 1] or { name = "?" }
          out[#out + 1] = (batch_line(call, item))
        else
          hidden = hidden + 1
        end
      end
      return out, hidden
    end
    local inner, inner_args = M.target(name, a)
    if inner ~= name then return M.preview(inner, result, lines, inner_args) end
    -- Unknown inner tool: a command-shaped result still shows its output.
    if r.stdout or r.stderr then name = "bash" end
  end
  local r = (type(result) == "table") and result or {}
  local text = ""
  if name == "codemode" then
    -- What the MODEL received (#121): the script's value - the one fact the tool returned to it -
    -- then its error, then how many nested calls it made. The model never sees the journal this
    -- result also carries (`calls`, `items`, `attempts`), so the CLI shows the model's own view of
    -- the call rather than a summary of it.
    local value = codemode_block.hide_evidence(r.value)
    if r.value ~= nil then text = (type(value) == "string") and value or json.encode(value) end
    if tostring(text):gsub("%s", "") == "" and r.error ~= nil then text = tostring(r.error) end
    if tostring(text):gsub("%s", "") == "" and type(r.calls) == "table" and #r.calls > 0 then
      text = string.format("%d call%s", #r.calls, #r.calls == 1 and "" or "s")
      for _, call in ipairs(r.calls) do
        if type(call) == "table" and call.name then
          text = text .. "\n" .. tostring(call.name) .. (call.ok == false and " (failed)" or "")
        end
      end
    end
  elseif name == "bash" or name == "shell" then
    text = tostring(r.stdout or "")
    if text:gsub("%s", "") == "" then text = tostring(r.stderr or "") end
  elseif r.error then
    text = tostring(r.error)
  end
  -- The second value is how many non-blank lines were left out, for the `… +N lines` marker.
  local out, kept, hidden = {}, 0, 0
  for line in tostring(text):gmatch("[^\r\n]+") do
    if line:gsub("%s", "") ~= "" then
      if kept < (lines or 2) then
        out[#out + 1] = line
        kept = kept + 1
      else
        hidden = hidden + 1
      end
    end
  end
  return out, hidden
end

-- ---- the footer -----------------------------------------------------------------

-- The window the footer divides by is the *model's*, resolved where compaction and the
-- window's balloon resolve it (`provider.budget`, over `model_window`) - never the global
-- `WASM_AGENT_LLM_CONTEXT` read directly. The global is the last resort in that chain, and
-- a footer that reads it shows a number no model has: this deployment's model has a
-- 1,000,000-token window and the global says 128000, so the same context read as eight
-- times fuller than it was.
--
-- `resolve` is passed in rather than required here, so the decision is testable without a
-- model: a resolver that fails, or that answers "unknown", falls back to the global rather
-- than printing a guess - unknown is visible, a guess is not.
function M.window(model, resolve)
  local ok, budget = pcall(resolve, model)
  local context = ok and type(budget) == "table" and tonumber(budget.context) or nil
  if context and context > 0 then return context end
  return tonumber(host.getenv("WASM_AGENT_LLM_CONTEXT")) or 0
end

-- The run's own numbers, the way pi keeps them in its footer: what it cost, what it
-- used, and how full the window is. The model and its reasoning level are in the banner
-- instead - they do not change between runs, and a line that has to hold both is a line
-- that gets clipped on a narrow terminal.
-- `run` is this turn's usage (the caller diffs the session totals), `ctx` the
-- process-wide facts that do not change per turn.
function M.footer(run, ctx)
  run, ctx = run or {}, ctx or {}
  local parts = {}
  if run.rounds then parts[#parts + 1] = run.rounds .. (run.rounds == 1 and " round" or " rounds") end
  if run.tools then parts[#parts + 1] = run.tools .. (run.tools == 1 and " tool" or " tools") end
  if run.seconds then parts[#parts + 1] = M.duration(run.seconds) end
  if run.prompt or run.completion then
    parts[#parts + 1] = string.format("\226\134\145%s \226\134\147%s", M.tokens(run.prompt), M.tokens(run.completion))
  end
  -- THE SET'S OWN GLYPHS, where the row has an icon's worth of fact (review finding 4, 21/11).
  --
  -- This footer was written pi-style, plain words and no glyph at all, so 'wa chat --once' drew NOT ONE
  -- wa Icons code point: the run showed "1 round · 0 tools · 1.7s · ↑3.7k ↓3 · CH79.7% · ctx 0.4%/1.0M"
  -- while the session bar two lines above used the set. Victor's decision is that wa's rows wear its
  -- icons - the cache rate and the context are exactly the two facts the session bar already draws with
  -- them - so the same two facts take the same glyphs here. The ARROWS stay: they are text (UP/DOWN of a
  -- count), which the module's own rule keeps glued to their number.
  if run.cached and run.cached > 0 and run.prompt and run.prompt > 0 then
    -- No "CH" beside the glyph: the session bar draws this same fact as '<cache glyph> 75.20%', and an
    -- icon that needs a word to explain it is two facts where the set has one.
    parts[#parts + 1] = string.format("%s%s%.1f%%", GLYPH.cache, GAP, 100 * run.cached / run.prompt)
  end
  if run.cost and run.cost > 0 then parts[#parts + 1] = string.format("$%.4f", run.cost) end
  if ctx.context and ctx.context > 0 and ctx.budget and ctx.budget > 0 then
    local percent = 100 * ctx.context / ctx.budget
    -- The ball is the one M.context_ball chooses, so the glyph and the number beside it are one reading.
    -- No "ctx" beside the ball, for the reason "CH" left the cache: the ball IS the context, and the word
    -- cost the four cells that pushed this row past a 60-column terminal (test-cli-resize, land242 gate).
    parts[#parts + 1] = string.format("%s%s%.1f%%/%s", M.context_ball(percent), GAP, percent, M.tokens(ctx.budget))
  end
  return table.concat(parts, " \194\183 ")   -- ·
end

-- The footer's self-wake fact (docs/SELF-LOOP.md): `⏰ 2 wakes · next 14:05`, or "" when this
-- session has nothing pending. Read from the ledger through `selfloop`, and never fatal: a footer
-- that cannot count is a footer, not a failed run.
function M.wake_text(session_id)
  if not session_id or session_id == "" then return "" end
  local ok, text = pcall(function() return dofile("lua/core/selfloop.lua").footer_text(session_id) end)
  return ok and type(text) == "string" and text or ""
end

-- The footer's mod segments (docs/MODS.md): a `mods.statusline` command's own words, cached for a
-- few seconds because the footer is redrawn far more often than a shell command can answer. Never
-- fatal: a footer that cannot read a mod is a footer, not a failed run, and an empty answer adds
-- nothing to the row.
function M.hook_text(session_id, model, facts)
  local ok, text = pcall(function()
    return dofile("lua/core/hooks.lua").statusline({ session_id = session_id, model = model,
      runs = facts and facts.runs, tokens = facts and facts.tokens,
      context = facts and facts.context, context_percent = facts and facts.context_percent })
  end)
  return ok and type(text) == "string" and text or ""
end

-- ---- is this a terminal? --------------------------------------------------------

-- Output that is not a terminal (`wa chat | tee log`) never gets the live view: the host says so
-- directly (`host.isatty`). Past that it is a heuristic, stated as one: every terminal this runs in
-- sets one of these variables. NO_COLOR always wins, and the explicit override exists because a guess
-- needs a way to be overruled. `istty` is injectable for tests, like `getenv`.
function M.wants_live(getenv, istty)
  getenv = getenv or function(name) return host.getenv(name) end
  istty = istty or function() if host.isatty then return host.isatty("stdout") end return nil end
  local explicit = getenv("WASM_AGENT_CLI_VIEW") or ""
  if explicit == "plain" or explicit == "off" or explicit == "0" then return false end
  if explicit == "live" or explicit == "on" or explicit == "1" then return true end
  if istty() == false then return false end
  if (getenv("NO_COLOR") or "") ~= "" then return false end
  local term = getenv("TERM") or ""
  if term == "dumb" then return false end
  return term ~= "" or (getenv("COLORTERM") or "") ~= ""
    or (getenv("WT_SESSION") or "") ~= "" or (getenv("ORCA_TERMINAL_HANDLE") or "") ~= ""
end

-- ---- the opening -------------------------------------------------------------------------------

-- Whether this start should have one (Victor, 22/11: green rain, a supernova - flash, debris sphere,
-- one ring - the star of the welcome
-- line landing in its cell, and the title translated from the alien alphabet). The animation itself is
-- the host's - `rust/wa-term/src/opening.rs`, on the alternate screen, beside this start work and never
-- in front of it - and this is the decision it is started or not started on.
--
-- Every condition is answered from what the caller has in hand, over a `host` a test can replace, so
-- the whole table is a Lua test instead of a terminal (scripts/test-opening.lua). It refuses on the
-- doubt: a caller that cannot say whether it has a terminal, an editor or a size has no opening.
-- The host refuses AGAIN, by name, whatever it cannot draw (`host.opening_start`), so a wrong answer
-- here costs a frame and never a broken screen.
M.OPENING_COLUMNS, M.OPENING_ROWS = 60, 14

function M.opening(o)
  o = o or {}
  local getenv = o.getenv or function(name) return host.getenv(name) end
  local setting = tostring(getenv("WASM_AGENT_CLI_OPENING") or ""):lower()
  if setting == "off" or setting == "0" or setting == "no" or setting == "false" then return false, "setting" end
  if o.scripted then return false, "scripted" end
  if o.live ~= true then return false, "not_a_terminal" end
  if o.editor ~= true then return false, "no_editor" end
  if o.resumed then return false, "resumed" end
  if (o.message or "") ~= "" then return false, "message" end
  if (getenv("NO_COLOR") or "") ~= "" then return false, "no_color" end
  if (getenv("TERM") or "") == "dumb" then return false, "dumb_terminal" end
  local columns, rows = tonumber(o.columns), tonumber(o.rows)
  if columns and columns < M.OPENING_COLUMNS then return false, "too_small" end
  if rows and rows < M.OPENING_ROWS then return false, "too_small" end
  return true, "default"
end

-- The console's height, asked the way the width is: `host.terminal_size`, nil when there is no
-- console or it will not answer. The frame is the only caller, and it needs this and nothing else.
function M.rows(probe)
  probe = probe or function()
    local ok, raw = pcall(host.terminal_size)
    if not ok or type(raw) ~= "string" then return nil end
    local decoded
    if not pcall(function() decoded = json.decode(raw) end) then return nil end
    if type(decoded) ~= "table" then return nil end
    return tonumber(decoded.rows)
  end
  local rows = tonumber(probe())
  if not rows or rows <= 0 then return nil end
  return math.floor(rows)
end

-- The console's width, asked the same way; nil when there is no console or it will not answer. The
-- welcome box is drawn before the screen exists, and a box laid out for a guessed width wraps on
-- every row of a narrower terminal.
--
-- ASKED AGAIN, PER FRAME. This used to be read exactly once - in `chat.lua`, before the banner - and
-- every component then drew at that width for the life of the process: maximising the terminal left
-- the welcome rule, the code-mode box and the footer at the old width, hugging the left of a window
-- twice their size, and shrinking it left them wider than the window, which wraps (Victor, 18/11).
-- `METHODS:refresh_limit` is the per-frame read; this stays the one place that asks the console.
function M.terminal_columns()
  if not (host and host.terminal_size) then return nil end
  local ok, raw = pcall(host.terminal_size)
  if not ok or type(raw) ~= "string" then return nil end
  local decoded
  if not pcall(function() decoded = json.decode(raw) end) or type(decoded) ~= "table" then return nil end
  local columns = tonumber(decoded.columns)
  return columns and columns > 0 and math.floor(columns) or nil
end

-- The rows a screen owns, from a height. `nil` when the console is too short to hold one - an
-- output row is not optional - and the caller then draws the way it did before this existed.
--
-- Canonical fallback (no native editor), top down: the output region, the session-status-content
-- line, the status line and the reader's input row. There is no separate text area or status bar
-- here - one row carries both the run and the session numbers - so the line keeps the row it has
-- always had.
--
-- With the native editor the layout is Claude Code's, bottom up: a footer of hints and session
-- numbers on the last row (this screen's **session status bar**), the session-status-content line,
-- the input box (bottom border, up to three draft rows, top border), the run's own status line and
-- the output region above that. The line is ONE row directly BELOW the text area and directly ABOVE
-- the status bar, the order the window has; it is not the row above the run-status line (that was
-- the 07/11 layout, and Victor's 08/11 position spec moves it). `rust/wa-capabilities/src/host.rs`
-- (`editor_status_row`, `resize_editor`) and `rust/wa-term/src/terminal_editor.rs` (`status_row`,
-- `session_row`) keep the same rows while Lua is blocked, so the three must change together.
--
-- Per layout: `session` is where the line is drawn, `region` is the output region's last row while
-- it shows, `bottom` is that row when it does not (nothing is reserved that is not drawn), and
-- `content` is kept for the fallback, where the line sits on the region's own last row.
M.EDITOR_ROWS = 3
-- The narrowest layout this view will draw: below it a framed component is all border and no text, so
-- a terminal that reports 12 columns is drawn as if it had 24 and the terminal wraps it. The floor is
-- named once because every component clips to it (METHODS:refresh_limit).
M.MIN_COLUMNS = 24
local function screen_rows(rows, editor)
  rows = tonumber(rows)
  if not rows or rows < (editor and 10 or 4) then return nil end
  rows = math.floor(rows)
  if editor then
    -- The worst case the reservation covers: the line showing and three draft rows.
    return { top = 1, bottom = rows - 7, status = rows - 7, region = rows - 8, content = rows - 7,
             session = rows - 1, input_top = rows - 6, input = rows - 1, footer = rows }
  end
  return { top = 1, bottom = rows - 2, status = rows - 1, region = rows - 3, content = rows - 2,
           session = rows - 2, input = rows }
end
M.screen_rows = screen_rows


-- ---- where this is running -----------------------------------------------------

-- The workspace as a reader recognises it: the home directory abbreviated, the rest
-- as-is, with forward slashes - the way the same tree is named everywhere else here.
function M.workspace(path, home)
  if not path or path == "" then return "" end
  local clean = tostring(path):gsub("\\", "/")
  if home and home ~= "" then
    local short_home = tostring(home):gsub("\\", "/")
    if clean:sub(1, #short_home) == short_home then return "~" .. clean:sub(#short_home + 1) end
  end
  return clean
end

-- The branch this worktree is on, read from `.git` rather than by running `git`: a
-- banner must not fail, or take a lock, because of a PATH or a repository state. In a
-- linked worktree `.git` is a *file* naming the real git directory, which is the case
-- this project's own checkouts are always in.
--
-- The line endings matter: `.git` is written with the platform's, and a branch name with
-- a carriage return in it is a path that cannot be opened and a label nobody wants.
function M.branch(root, read)
  if not root or root == "" then return "" end
  read = read or function(path)
    local ok, text = pcall(host.read_file, path)
    if not ok or type(text) ~= "string" then return nil end
    return text
  end
  local pointer = read(root .. "/.git")
  local head
  -- A linked worktree has a `.git` *file* naming the real git directory; a plain checkout
  -- has a `.git` directory, and reading a directory as a file fails - so a failed read
  -- here is not "not a repository", it is "look one level down".
  local gitdir = type(pointer) == "string" and pointer:match("^gitdir:%s*(.-)%s*$") or nil
  if gitdir then
    gitdir = gitdir:gsub("\\", "/")
    if gitdir:sub(1, 1) ~= "/" and not gitdir:match("^%a:") then gitdir = root .. "/" .. gitdir end
    head = read(gitdir .. "/HEAD")
  else
    head = read(root .. "/.git/HEAD")
  end
  if type(head) ~= "string" then return "" end
  return head:match("^ref:%s*refs/heads/(.-)%s*$") or head:sub(1, 8)
end

-- ---- the view -------------------------------------------------------------------

local METHODS = {}
METHODS.__index = METHODS
-- What a swap points a live view at: `reload` rebinds `getmetatable(view).__index` through this, so the
-- object (the state) is never touched and the methods (the code) are always the newest.
M.__methods = METHODS

-- `opts`: out (write text), live (nil = decide), now (clock), limit (columns),
-- title (terminal title), workspace/branch/budget (the banner and the footer).
-- **The terminal's width, read again.** Every framed component lays itself out from `self.limit`,
-- and that value used to be measured once - before the banner, in `chat.lua` - and never looked at
-- again. So maximising the terminal stretched the input rule and the footer (the host redraws those
-- from its own size) while the welcome rule, the welcome box, the code-mode box and the status bar's
-- right-hand parts stayed at the old width; shrinking it left them wider than the window, where they
-- wrap and bounce (Victor, 18/11). This is the read that makes every one of them follow.
--
-- `opts.columns` is the probe (a test has no console); absent, it is M.terminal_columns. The value is
-- clamped the way every other width in this module is, and a console that will not answer keeps the
-- width the view already had - an unanswerable console is not a narrow one.
function METHODS:refresh_limit()
  local probe = self.columns_probe or M.terminal_columns
  local ok, columns = pcall(probe)
  if not ok then return self.limit end
  columns = tonumber(columns)
  if not columns or columns <= 0 then return self.limit end
  local width = math.max(M.MIN_COLUMNS, math.floor(columns))
  -- The width this view had, kept for the frame boundary that answers a resize: reading the console and
  -- ACTING on what it says are two different steps, and the action (clear + draw again, METHODS:resized)
  -- belongs at the frame boundary, not inside a probe a dozen callers make.
  if width ~= self.limit then self.width_from = self.limit end
  self.limit = width
  return self.limit
end

-- A rule as wide as the terminal is NOW: the marker a component writes, expanded for the plain
-- layout. One function, so the welcome box and anything else that draws a rule cannot disagree
-- about what "the width" is.
function METHODS:rule()
  return M.expand_rules(M.RULE, self.limit)
end

function M.new(opts)
  opts = opts or {}
  -- `opts.live == false` must mean plain: `x = opts.live or default` would silently
  -- fall through to the terminal guess, and a caller asking for a transcript would get
  -- escape sequences in it.
  local live = opts.live
  if live == nil then live = M.wants_live(opts.getenv) end
  -- The host's ticker draws on the process's own stdout and nowhere else, so a view whose
  -- output goes somewhere else (a buffer, a captured transcript) must not have a second
  -- writer appear on the terminal behind it. The default `out` *is* stdout, which is why this
  -- is derived from it; `opts.stdout` overrules the guess, the way `opts.live` does.
  local stdout = opts.stdout
  if stdout == nil then stdout = (opts.out == nil) end
  -- The environment, for the one knob that turns the screen off, and the one that turns the frames
  -- off (`WASM_AGENT_CLI_SYNC=off`).
  local getenv = opts.getenv or function(name) return host.getenv(name) end
  -- `opts.sync` overrules the environment, the way `opts.live` overrules the terminal guess.
  local sync = opts.sync
  if sync == nil then sync = (getenv("WASM_AGENT_CLI_SYNC") or "") ~= "off" end
  local view = {
    -- The width probe: a test passes its own, a live view asks the console (METHODS:refresh_limit).
    columns_probe = opts.columns,
    out = opts.out or function(text)
      if host and host.terminal_write then
        assert(host.terminal_write(text), "terminal write failed")
      else
        io.write(text); io.flush()
      end
    end,
    live = live and true or false,
    stdout = stdout and true or false,
    animating = false,
    now = opts.now or function() return host.now() end,
    limit = opts.limit or 80,
    -- The console's height, and the rows it makes possible: injectable, because a test has no
    -- console and the height is the whole of what the screen needs - see `METHODS:screen_on`.
    rows = opts.rows or M.rows,
    -- The environment, for the one knob that turns the screen off, and the one that turns the
    -- frames off (`WASM_AGENT_CLI_SYNC=off`).
    getenv = getenv,
    sync = sync and true or false,
    title = opts.title or "",
    workspace = opts.workspace or "",
    branch = opts.branch or "",
    -- The session whose self-wakes the footer counts (docs/SELF-LOOP.md). Nil in a caller with no
    -- session (a test, a replay view); the footer then simply omits the fact.
    session_id = opts.session_id or nil,
    budget = opts.budget or 0,
    context = 0,
    frame = 0, phase = "", round = 0, runs = 0, total_rounds = 0, pending = nil,
    -- The code-mode block that is running (`lua/core/codemode_block.lua`'s model), how many call rows
    -- of it are on screen, and the one that settled last - the block a newer one collapses.
    code = nil, code_rows = 0, code_done = nil,
    -- `shown_cols` is how many columns of the terminal the status line currently holds: the
    -- bound every in-place write is kept inside - see `METHODS:status_draw`. `screen` is the rows
    -- the view owns once it knows the console's height - see `METHODS:screen_on`. `framing` says a
    -- frame is open, `frame_open` whether its first byte has gone out - see `METHODS:with_frame`.
    shown = nil, shown_cols = 0, screen = nil, framing = false, frame_open = false,
    -- The self-wake fact as last read (`⏰ 2 wakes · next 14:05`), "" when nothing is scheduled.
    wakes = "",
    logged = "", logged_session = nil, turn = nil, totals = nil, deltas = 0, warned = nil,
    -- the update sentence while a newer release is published - `lua/core/update_banner.lua` owns it
    -- (`M.LINE`, and `M.COMMANDS` for the two words it asks the reader to type; never restated here).
    -- It is the standing text of the **session-status-content** area:
    -- ONE line directly above the session status bar, never a transcript line and never a prefix on
    -- the status bar's own content, and the same sentence the window shows.
    session_notice = nil,
    -- What that area says now, resolved: `function() return { text, kind } end`, where `kind` is
    -- `notice` (the yellow line), `building` (the rebuild loader REPLACES the notice on the same
    -- line), `installed` or `failed` (the result, briefly). `lua/core/update_banner.lua`
    -- (`session_content`) owns the precedence; absent, `session_notice` alone is the line. It is a
    -- function because the build's progress moves while a run is in flight and Lua is not asked.
    session_status = opts.session_status or nil,
    -- The row the line was last drawn on, and how wide; nil = nothing drawn (no line, no gap).
    session_shown = nil, session_shown_cols = 0, region_bottom = nil,
  }
  view = setmetatable(view, METHODS)
  -- A live view is session view state, and every field above survives a reload because the OBJECT does:
  -- a swap only points it at the reloaded methods. `register = false` is for a throwaway view (the
  -- reloader's own render probe, a test) that must not be kept alive for the life of the process.
  if opts.register ~= false then
    reload.view(view, function(module)
      local methods = module.__methods
      if type(methods) ~= "table" then return end
      setmetatable(view, methods)
    end)
  end
  return view
end

-- The row to address for `kind` ("O" output's last row, "S" status): a token when the host's editor
-- is drawing the bottom of the screen - the slash menu and panels move those rows while Lua is
-- blocked, and the host fills the token in under its lock - and the number otherwise.
function METHODS:row(kind)
  if self.editor and self.editor_ready and self.stdout and host and host.panel then return "{" .. kind .. "}" end
  if kind == "O" then return tostring(self:region_bottom()) end
  return tostring(self.screen.status)
end

-- Whether output goes to the host's transcript (blocks it draws, folds and focuses) rather than
-- being streamed into the terminal.
function METHODS:transcript()
  return self.editor and self.editor_ready and self.stdout and host and host.transcript_write ~= nil
end

-- Start a transcript block: `topic` = collapsible (the model's thinking, a tool call). A no-op
-- outside the transcript.
function METHODS:topic(topic)
  if self:transcript() and host.transcript_block then pcall(host.transcript_block, topic and true or false) end
end

-- How many newlines what this view wrote ends with (escapes ignored): 0 = a line is open, 1 = a line
-- ended, 2 = one blank line. `gap(n)` asks for exactly n blank lines before what comes next and writes
-- only what is missing - the ONE spacing rule (operator 17/11: one blank line between the reader's line,
-- a thought, the commentary, a code block and a status row; never two, never glued).
local function trailing_newlines(text)
  local plain = tostring(text or ""):gsub("\27%[[%d;?]*[A-Za-z]", "")
  if plain == "" then return nil end
  local tail = plain:match("\n*$")
  return #tail, #tail == #plain
end
function METHODS:gap(blank)
  local want = (tonumber(blank) or 1) + 1
  local have = self.tail_nl
  if have == nil then return end
  if have < want then self:write(string.rep("\n", want - have)) end
end

function METHODS:write(text)
  local count, only = trailing_newlines(text)
  if count then self.tail_nl = only and ((self.tail_nl or 0) + count) or count end
  -- Output - the transcript, a tool line, an answer - belongs in the region above the status and
  -- input rows, and this is the one place that knows where that region is. Every caller of the
  -- plain writer keeps working unchanged, and the reader's cursor comes back to the row they were
  -- typing on: a write that left the cursor in the output region would send their next keystroke
  -- into the middle of the transcript.
  if self.screen and self:transcript() then
    -- The host's own writer does not come through `out`, so the frame is opened here, before it: the
    -- transcript block belongs inside the same frame as the status row it is drawn with.
    self:open_frame()
    pcall(host.transcript_write, text)
    return
  end
  if self.screen then
    self:screen_on()
    text = text:gsub("\r?\n", "\r\n")
    self:emit(CURSOR_SAVE .. "\27[" .. self:row("O") .. ";1H" .. text .. CURSOR_RESTORE)
    return
  end
  -- The native editor puts the terminal in raw mode before the welcome box is printed, and a raw
  -- terminal does not return the carriage on a newline: without `\r` every line starts where the
  -- previous one ended.
  if self.live and self.editor then text = text:gsub("\r?\n", "\r\n") end
  self:emit(text)
end

-- A write that is not output: cursor movement this view owns. Never framed - the frame's own
-- sequences wrapped in the frame's sequences is how a cursor ends up somewhere nobody planned.
function METHODS:control(text)
  self:emit(text)
end

-- Everything this view puts on the terminal goes out here, which is what lets a frame be opened by
-- its first byte rather than by the call that might write one. Outside a frame this is `out`.
function METHODS:emit(text)
  self:open_frame()
  self.out(text)
end

-- Open the frame a write belongs to, once: the synchronized-output sequence goes out immediately
-- before the frame's first byte, so a frame that writes nothing (a status redraw that has nothing to
-- say, a session line that is not showing) costs nothing at all - no empty pair in a capture, and no
-- empty update for a terminal to paint.
function METHODS:open_frame()
  if not self.framing or self.frame_open then return end
  self.frame_open = true
  self.out(SYNC_START)
end

-- Run `fn` as one frame: everything it writes is painted together, between the synchronized-output
-- sequences above. A frame is a transcript write plus the redraws that follow it (the status line,
-- the footer, the session-status-content line), which is why that is the unit here rather than each
-- write: a status row erased for a write and redrawn a moment later is what a reader sees as a blink
-- on every tool call.
--
-- Only the live view frames anything (a transcript is a log, and a log with terminal control in it
-- is not one), and only once the screen is up - that is the layout where one frame spans rows, and
-- it is the layout the blink was reported on. The inline layout keeps writing exactly the bytes it
-- always has: its status line shares the reader's row, so a frame there would wrap a cursor the
-- reader is typing at. Nested calls are part of the frame they are in rather than frames of their
-- own: the sequences do not nest in the terminals that implement the mode.
-- `WASM_AGENT_CLI_SYNC=off` turns the frames off for a terminal whose mode-2026 support is worse than
-- the tearing it prevents. It is the frames only: the status row is updated in place either way, so
-- what a reader reported as a blink does not come back with the knob.
function METHODS:with_frame(fn, ...)
  if not (self.sync and self.live and self.screen) or self.framing then return fn(self, ...) end
  self.framing, self.frame_open = true, false
  -- Closed on failure too: a terminal left holding an unterminated frame is worse than the error
  -- being reported, and the message is re-raised as it was, for the caller's own `pcall`.
  local results = table.pack(pcall(fn, self, ...))
  local opened = self.frame_open
  self.framing, self.frame_open = false, false
  if opened then self.out(SYNC_END) end
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

function METHODS:line(text)
  self:clear()
  if self.tail_nl == 0 then self:write("\n") end
  self:write(tostring(text or "") .. "\n")
end

-- The status line with its two moving parts left as tokens: `{m}` is the spinner mark and
-- `{t}` the clock. One layout, two renderers - this module fills them for a line it prints
-- itself, and `host.ticker` fills them on a timer while this process is blocked. The second
-- value is when the timed thing started, which is what the clock counts from either way.
-- HOW LONG A PROVIDER'S PROMPT CACHE LASTS, as far as this row is concerned: five minutes, the shortest
-- of the providers this deployment talks to. It is an ASSUMPTION, named as one, and it decides one
-- sentence on one row - after a longer silence the provider re-reads the whole conversation, which is
-- exactly why the first reply after an idle hour takes far longer than the second (measured 23/11: 47
-- minutes after the previous answer, 21 s inside one silent provider read).
M.COLD_CONTEXT_SECONDS = 300

-- How much silence makes a model call worth a row of its own. A word for the wait costs the reader
-- something: the phase word it replaces ("Thinking") is two frames' worth of a fast reply, and a row
-- that flickers for every 200 ms call is noise, not information. One second is where a reply stops
-- feeling immediate (warm ttft here is 1.4-2.8 s, so a warm call DOES show it - which is the point).
M.WAIT_AFTER_SECONDS = 1

-- A MODEL CALL IS WAITING FOR ITS FIRST BYTE, and this is when that wait began (change/esc-stops-now,
-- item 5). Set where a model call begins - the run's first round, a round boundary, a status event that
-- announces one, and after a tool result - and cleared by the first thing the provider says: a delta, a
-- thought, a tool call, or the usage numbers. Display only: nothing here reaches the request bytes.
function METHODS:model_waiting()
  -- FRESH every time: this is called where a model call BEGINS (a run start, a round boundary, a status
  -- event that announces one, the end of a tool block), and each call's wait is its own. Keeping an
  -- older start would report the previous call's silence as this one's.
  self.model_wait = { started = self.now() }
end

function METHODS:model_spoke()
  self.model_wait = nil
end

-- The row while a model call has produced NO BYTE: what the run is waiting on, how long it has been
-- waiting, and the one key that ends the wait. A silent provider used to look exactly like a dead
-- session, and the reader's only lever - a key they may not know they have - was nowhere on screen.
-- The cold-context sentence is the other half of the same fact: after a silence longer than a
-- provider's prompt cache, the first reply is slower, and that is not a hang either.
function METHODS:waiting_text()
  local wait = self.model_wait
  if not wait then return nil end
  if (self.now() - wait.started) < M.WAIT_AFTER_SECONDS then return nil end
  local line = "waiting for the model \194\183 {w} \194\183 esc to stop"
  local last = self.last_answer_at
  if last and (self.now() - last) >= M.COLD_CONTEXT_SECONDS then
    line = line .. " \194\183 the context is cold (" .. M.duration(self.now() - last) .. " idle): the first reply is slower"
  end
  return line
end

-- Is the context this turn sends older than the provider's cache? Read by the composer, so the numbers
-- (all zero while nothing has arrived) can give the cold sentence the room it needs.
function METHODS:cold_context()
  local last = self.last_answer_at
  return (last and (self.now() - last) >= M.COLD_CONTEXT_SECONDS) and true or false
end

function METHODS:status_template()
  local boxed = self.screen and self.screen.footer
  if self.screen and not self.turn and self.last_summary then
    -- Boxed, the numbers live in the footer under the box and the status row is EMPTY between runs.
    -- Nothing about the rest of the node goes here: the `node: N ops elsewhere` aggregate is
    -- change/session-isolation's, it is drawn there and nowhere else (this view has no reader of it,
    -- and a row composed from a module another branch owns drifts the moment either side changes).
    if boxed then return "", nil end
    return paint(clip(self.last_summary, self.limit), "dim", self.live), nil
  end
  -- Nothing of this session's is running and there is no run to describe: the row is empty. Never a
  -- named row, and never a count either - another session's tool, its clock and its output are not
  -- ours to draw (session isolation, finding 1), and this branch draws nothing about other sessions.
  local phase = self.pending and (self.pending.raw and "Running your script"
    or M.phase((M.target(self.pending.name, self.pending.arguments)))) or self.phase
  -- A MODEL CALL THAT HAS SAID NOTHING YET outranks the phase word while it lasts: Thinking is what a
  -- run does, and waiting for the model is what this second is (change/esc-stops-now, item 5).
  local waiting = (not self.pending) and self:waiting_text() or nil
  local started = self.screen and self.turn and self.turn.started
    or (self.pending and self.pending.started) or (self.turn and self.turn.started)
  local step = self.turn and (self.turn.step_started or self.turn.started)
  -- The reload source, on the row a reader looks at: `dev reload` while this CLI draws from the
  -- operator's working tree (docs/HOTRELOAD.md). It goes on every line this function composes, including
  -- the one the host's ticker keeps redrawing while Lua is blocked, because a CLI running code that is
  -- not what it was installed with has to say so in the one place that is always on screen. A deployed
  -- payload says nothing: it is the node's own bytes.
  local function with_source(line, live)
    local marker = reload.status()
    if not marker or line == "" then return line end
    return line .. paint(" \194\183 " .. marker, "warning", live)
  end
  local function compose(shown, live)
    -- THE WAIT FIRST: while a model call has said nothing, the row is about that wait, whatever else the
    -- run has done. A cold context takes the numbers row's place, because they are all zero until the
    -- first byte arrives and the sentence is the thing worth the room (change/esc-stops-now, item 5).
    if waiting then
      local text = "{m}" .. paint(waiting, "muted", live)
      if not self:cold_context() then
        text = text .. paint(" \194\183 ", "muted", live) .. paint(self:run_numbers("{s}", "{T}"), "muted", live)
      end
      return with_source(text, live)
    end
    if boxed and self.turn then
      -- `✶ 󰷺2·5s Δ12.4k ↑4.6M ↓310 󰔛1:51`: the step this run is on and how long it has taken, what
      -- it ADDED to the context (`Δ`) and the session's input total (`↑`), its output tokens and its
      -- whole time. `{s}` and `{T}` are clocks the host keeps moving while Lua is blocked. ONE muted
      -- span, the step pair included: the count is secondary text like the numbers beside it, so it
      -- wears that gray and cannot drift into a colour of its own (Victor, 18/11).
      return with_source("{m}" .. paint(self:run_numbers("{s}", "{T}"), "muted", live), live)
    end
    local line = "{m}" .. (waiting and paint(waiting, "accent", live) or shown)
    if not self.turn then return with_source(line, live) end
    if self.screen then
      local run, base, totals = self.turn, self.turn.baseline or {}, self.totals or {}
      local summary = M.footer({
        rounds = run.rounds, tools = run.tools,
        prompt = math.max(0, (totals.prompt or 0) - (base.prompt or 0)),
        completion = math.max(0, (totals.completion or 0) - (base.completion or 0)),
        cached = math.max(0, (totals.cached or 0) - (base.cached or 0)),
      }, { context = self.context, budget = self.budget })
      return with_source(line .. " \194\183 {t} \194\183 " .. summary, live)
    end
    local step = self.total_rounds > 0 and (" \194\183 step " .. self.total_rounds) or ""
    local bound = self.pending and self.pending.bound and (" of " .. M.duration(self.pending.bound)) or ""
    return with_source(line .. " \194\183 {t}" .. bound .. " \194\183 run " .. self.runs .. step, live)
  end
  local plain = compose(phase, false)
  -- The phase word carries the colour: the host's ticker draws this same line, and the mark and
  -- the clock are its own. A terminal too narrow for the plain line gets the plain line, because
  -- `clip` counts columns and an escape sequence is not one - a coloured line clipped by width
  -- loses its reset and bleeds into the next line.
  if columns(plain) + 10 > self.limit then return plain, started end
  return compose(paint(phase, "accent", self.live), self.live), started
end

-- The status line, and the only thing on screen that is rewritten. `with_spinner` is
-- false for the captured rendering: a spinner frame is a moving picture, and a
-- transcript is not one.
-- ---- a restart the sentinel is about to perform ----------------------------------
--
-- A queued restart is the one thing a reader needs from this row before the node stops: the terminal
-- goes quiet while it is down, and "it is restarting" is the difference between waiting and wondering
-- whether it crashed. The source is the queue the sentinel already writes - a `request` file is
-- durable, so it survives the process that wrote it and needs no socket, event or new state here.
--
-- Cached for a second: the status row is redrawn on every spinner frame, and this reads a directory.
local RESTART_NOTICE_TTL = 1
local RESTART_VERBS = { restart = true, deploy = true, upgrade = true, recover = true }
-- The last answer, in the core's store rather than in a table of this module: the status row is redrawn
-- on every spinner frame and this reads a directory, so the cache has to outlive a reload of this file
-- (a module-level table would come back empty and re-read the disk on the next frame, or - worse - keep
-- an answer the new copy can no longer refresh).
local restart_seen = reload.state("restart_notice")
if restart_seen.at == nil then restart_seen.at, restart_seen.verb = -1, nil end
function M.restart_pending(now, data_dir)
  now = tonumber(now) or 0
  if restart_seen.at >= 0 and (now - restart_seen.at) < RESTART_NOTICE_TTL then return restart_seen.verb end
  restart_seen.at = now
  restart_seen.verb = nil
  if not host.list_dir or not host.read_file then return nil end
  local root = data_dir
  if not root then
    local ok, data = pcall(function() return dofile("lua/core/paths.lua").data() end)
    if not ok or type(data) ~= "string" or data == "" then return nil end
    root = data
  end
  local listed, raw = pcall(host.list_dir, root .. "/sentinel/requests")
  if not listed or type(raw) ~= "string" then return nil end
  local decoded_ok, listing = pcall(json.decode, raw)
  if not decoded_ok or type(listing) ~= "table" or type(listing.entries) ~= "table" then return nil end
  local checked = 0
  for _, entry in ipairs(listing.entries) do
    if checked >= 8 then break end
    local name = tostring(entry.name or "")
    if entry.kind == "file" and (entry.size or 0) <= 65536 and name:sub(-5) == ".json" then
      checked = checked + 1
      local body = host.read_file(root .. "/sentinel/requests/" .. name)
      if body then
        local body_ok, request = pcall(json.decode, body)
        if body_ok and type(request) == "table" and RESTART_VERBS[tostring(request.verb)] then
          restart_seen.verb = tostring(request.verb)
          return restart_seen.verb
        end
      end
    end
  end
  return nil
end

function METHODS:status_text(with_spinner)
  -- Outranks the run's own numbers: when the node is about to stop, that is the whole message.
  local restarting = M.restart_pending(self.now(), self.data_dir)
  if restarting then
    return paint("⟳ restarting (" .. restarting .. ") - this session resumes automatically", "warning", self.live)
  end
  local template, started = self:status_template()
  -- Coloured only when the line fits: a clipped line must not cut through a colour.
  local fits = visible_columns(template) + 10 <= self.limit
  -- The same green as the mark that travels to the host (`M.marks`): the fallback layout draws the same
  -- glyph on the same row, and one of the two being warm would be the old colour leaking back.
  local mark = with_spinner and (paint(M.spinner(self.frame), "matrix", self.live and fits) .. " ") or ""
  -- Through a function, so a mark or a clock containing a `%` is inserted as itself.
  local text = template:gsub("{m}", function() return mark end)
  if started then
    local now = self.now()
    local elapsed = M.duration(now - started)
    text = text:gsub("{t}", function() return elapsed end)
    local step = M.step_clock(now - ((self.turn and self.turn.step_started) or started))
    local total = M.run_clock(now - started)
    -- The wait for the model's first byte (change/esc-stops-now, item 5): the twin of the host ticker's
    -- {w}, so the frame this process draws and the frames the host draws while it is blocked agree.
    if self.model_wait then
      local waited = M.step_clock(now - self.model_wait.started)
      text = text:gsub("{w}", function() return waited end)
    end
    text = text:gsub("{s}", function() return step end):gsub("{T}", function() return total end)
  end
  return text
end

-- Hand the line to the host, which keeps drawing it while this process cannot.
--
-- `started` is when the timed thing began rather than "now": the clock has to be continuous
-- across the events that redraw the line, and `frame` is where the mark cycle continues from,
-- so a redraw does not send the spinner back to its first frame. A failure here is silent on
-- purpose - it is one frame of decoration, and the run it describes must not die of it.
function METHODS:animate()
  if not self.live or not self.stdout then return end
  if not (host and host.ticker) then return end
  local template, started = self:status_template()
  if template == "" then return end
  if not started and not (self.screen and self.last_summary) then return end
  local ok = pcall(host.ticker, json.encode({
    line = template, marks = started and M.marks(self.live) or {}, started = started or self.now(), frame = self.frame,
    step_started = self.turn and self.turn.step_started or nil,
    -- The wait for the model's first byte, so the host's frames count THIS wait and not the run
    -- (change/esc-stops-now, item 5).
    wait_started = self.model_wait and self.model_wait.started or nil,
    -- A row of its own while there is a screen: the ticker draws on the status row and hands the
    -- cursor back, which is what lets the reader keep typing on the input row at the same time.
    row = self.screen and self.screen.status or nil,
    width = self.limit,
  }))
  if not ok then return end
  self.animating = true
end

-- Take the line back. Called before this module writes anything at all: two writers on one
-- line is how a status line becomes two half-lines. Stopping is cheap and immediate - the
-- host wakes its own thread rather than waiting out a tick.
function METHODS:unanimate()
  if not self.animating then return end
  self.animating = false
  if host and host.ticker then pcall(host.ticker, nil) end
end

-- One in-place frame of the status line, bounded to the columns the last frame drew.
--
-- This row is the row the reader types on: a run is exactly when they type, the terminal echoes at
-- the cursor, and the cursor sits at the end of this line. So the frame
--
--   * rewrites only the columns it drew itself, padding a shorter line with spaces rather than
--     erasing to the end of the row. `\27[2K` erases from the cursor to the right - which is the
--     reader's half-typed message, and erasing it is what they reported;
--   * commits the row (a newline) when it needs more room than it drew, instead of writing over
--     columns that may now hold their text. A status line is not worth a reader's message; the
--     cost is one line in the scrollback, when the clock or a token count grows;
--   * saves and restores the cursor around the write (CSI `s` / `u`), because the cursor is
--     also where the reader's *next* keystroke lands. Leaving it at the end of the frame would
--     make their next character overwrite the line they had already typed.
--
-- Risk, named: a terminal that ignores cursor save/restore leaves the cursor at the end of the frame,
-- and continued typing then lands a few columns away from the reader's text. That garbles the
-- *display* of a line typed during a run and loses nothing: the line is read from the host's
-- reader, never from the screen. The alternatives are the erase this replaces, or owning the input
-- row with raw mode, which is a larger change than this one.
function METHODS:status_draw(text)
  -- Live only: a captured transcript is a log, and a log with cursor movement in it is not one.
  if not self.live then return end
  local cols = visible_columns(text)
  local pad = self.shown_cols > cols and (self.shown_cols - cols) or 0
  if self.screen then
    -- A row of its own: the reader's cursor stays on the input row, so this neither commits a line
    -- nor is bounded by what the reader may have typed - the row belongs to the status line and
    -- nothing else writes on it. So it is updated in place - rewritten, padded over the columns the
    -- last frame drew, erased to the end of its own row - and never erased first: an erase plus a
    -- redraw in two frames is the blink this row used to make on every tool call. The `\27[K` here
    -- is the counterpart of the host ticker's own frame (`ticker_frame` in wa-capabilities): a mark
    -- can count one cell and draw two, so the tail of a wider frame is erased rather than padded.
    self:control(CURSOR_SAVE .. "\27[" .. self:row("S") .. ";1H" .. text
      .. string.rep(" ", pad) .. "\27[K" .. CURSOR_RESTORE)
    self.shown_cols = cols
    return
  end
  if self.shown_cols > 0 and cols > self.shown_cols then
    -- Needs more room than it drew: start a fresh row rather than take the reader's columns.
    self:control("\r\n")
    self.shown_cols = 0
    pad = 0
  end
  self:control(CURSOR_SAVE .. "\r" .. text .. string.rep(" ", pad) .. CURSOR_RESTORE)
  self.shown_cols = math.max(self.shown_cols, cols)
end

-- ---- session-status-content ------------------------------------------------------
--
-- ONE line between the CLI's text area and its session status bar, reserved for transient session
-- notices (Victor's 08/11 position spec: below the text area, above the status bar, never on the row
-- above the run-status line). The update notice is its standing occupant, so it stops competing with
-- the status bar's own content (the session numbers used to be pushed to the right of it on the same
-- row) and stops shortening it.
--
-- **The row is the update notice's, and nothing else's** (Victor, 2026-11-10: "this bash description
-- should be printed in the bash toolcall not at the footer. that place belongs to update message and
-- update launcher seeker, not info about tools, which should be in the terminal content"). A running
-- tool call's progress - its name, its clock and the newest line of its output - is drawn INSIDE that
-- call's own block in the transcript, under its heading (`METHODS:tool_live`,
-- `wa_term::transcript::Transcript::live`), and never here. The kinds below are therefore only the
-- update's own:
--
-- What the line says now is `update_banner.session_content`'s decision, not this module's:
--
--   notice     the standing sentence in the warning yellow, which `update_banner` owns
--              (`M.LINE`) - `Update available (<sha>) \226\128\148 /update here, or wa update in a
--              terminal` - with the two commands it names in bold (`M.COMMANDS`), the same sentence
--              and the same emphasis the native editor draws;
--   building   the rebuild loader REPLACES the notice on the same line - while a build is in flight
--              the terminal says what it is doing, and the notice would be a stale instruction - and
--              a finished build shows its result for a moment;
--   failed     the failure is visible, and then the notice comes back: a failed build leaves the
--              update available, so the notice is never the thing that gets lost;
--   empty      no line at all: the row goes back to the box (the native layout) or to the output
--              region (the fallback), and there is no blank gap.
--
-- The rust twin is `wa_term::terminal_editor::Editor` (`session_row`, `session_content`) plus
-- `wa_term::build_status::session_line`, which draw the same row when the native editor owns the
-- screen; the wording and the freshness windows are pinned against each other by the tests.
function METHODS:session_content()
  local status = self.session_status
  if type(status) == "function" then
    local ok, value = pcall(status)
    if ok and type(value) == "table" and value.text and tostring(value.text) ~= "" then
      return { text = tostring(value.text), kind = tostring(value.kind or "notice"),
        commands = type(value.commands) == "table" and value.commands or nil }
    end
  end
  if self.session_notice and self.session_notice ~= "" then
    return { text = self.session_notice, kind = "notice" }
  end
  -- The one thing this row says about OTHER sessions: a count. A running call's progress is still not a
  -- session notice (Victor, 2026-11-10) - its own row lives inside its own block in the transcript - but
  -- "the node is busy" is not another session's tool and not a line of its output: it is a number, drawn
  -- dim, with no name and no text (session isolation, finding 1).
  local elsewhere = self:elsewhere_row()
  if elsewhere then return { text = elsewhere, kind = "progress" } end
  return nil
end

-- Bold the commands a sentence asks the reader to type, and only those: `words` is the list the
-- sentence's own module owns (`update_banner.COMMANDS`), so no renderer keeps a copy of it. Renderers
-- that can do colour only (the fallback row) call this; the native editor bolds the same two words.
function M.emphasise(text, words)
  if type(words) ~= "table" then return text end
  for _, word in ipairs(words) do
    if type(word) == "string" and word ~= "" then
      local pattern = word:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
      text = text:gsub(pattern, STYLE.bold .. word .. "\27[22m", 1)
    end
  end
  return text
end

-- How many other sessions are running a call right now, as the one aggregate line - or nil. Read at most
-- once a quarter second (the host publishes at most four times a second), because this row is asked on
-- every frame.
function METHODS:elsewhere_row()
  if self.console or not self.live then return nil end
  local module = self.tool_progress
  if not module then
    local ok, loaded = pcall(dofile, 'lua/core/tool_progress.lua')
    if not ok or type(loaded) ~= 'table' then return nil end
    module = loaded; self.tool_progress = module
  end
  if not module.elsewhere then return nil end
  local ms = math.floor(self:now() * 1000)
  if self.elsewhere_at and (ms - self.elsewhere_at) < 250 then return self.elsewhere_text end
  local ok, count = pcall(module.elsewhere, { session = self.session_id, now = self.now() })
  self.elsewhere_at = ms
  self.elsewhere_text = (ok and (tonumber(count) or 0) > 0) and module.elsewhere_text(count) or nil
  return self.elsewhere_text
end

-- The colour of each kind of line: the notice is the warning yellow, a loader (a build) is the
-- border accent, and a result is success or error. A tool call has no kind here at all - its line
-- lives in its own block in the transcript.
local SESSION_ROLES = { building = "borderAccent", installed = "success", failed = "error",
  notice = "warning", progress = "dim" }
function M.session_role(kind)
  return SESSION_ROLES[tostring(kind or "")] or "warning"
end

-- The line as drawn: one row, clipped to the terminal's width (an ellipsis, never a wrap), coloured
-- by what it is - the notice is the warning yellow. `live` is the switch every other colour here
-- obeys, so NO_COLOR and a captured transcript get the same text in the same place, uncoloured.
function METHODS:session_line()
  local content = self:session_content()
  if not content then return nil end
  local text = clip(content.text, math.max(1, self.limit))
  -- The words the sentence asks the reader to TYPE are bold (Victor, 18/11), inside the same warning
  -- yellow line: `/update` and `wa update`, the list the sentence's own module owns
  -- (`update_banner.COMMANDS`). Clipped first and emphasised second, so no escape sequence is ever
  -- counted as a column.
  if content.commands and self.live then text = M.emphasise(text, content.commands) end
  return paint(text, M.session_role(content.kind), self.live), content.kind
end

-- The layout as it reads *now*: `screen_rows` reserves the worst case once, and the self-wake fact is the
-- one row that comes and goes with the world. When it is showing, it takes the row directly above the
-- session status bar and everything above it moves up one line - the output region included, so the chat
-- is pushed up rather than drawn over.
function METHODS:layout()
  local screen = self.screen
  if not screen then return nil end
  if not self:has_wakes() then return screen end
  -- The wake row is the one directly above the status bar. In the boxed layout every other row is named
  -- absolutely and the native editor owns them, so only the fallback's rows move.
  local wake = screen.status - 1
  local shifted = { top = screen.top, status = screen.status, input = screen.input, footer = screen.footer,
    wake = wake, session = wake - 1, content = wake - 1, region = wake - 2, bottom = wake - 2 }
  return shifted
end

-- Whether the self-wake row has anything to say.
function METHODS:has_wakes()
  return type(self.wakes) == "string" and self.wakes ~= ""
end

-- The output region's last row: one less while the line is showing, because the line is reserved
-- rather than drawn over whatever the chat had there. The two layouts reserve different rows - the
-- fallback's line sits on the region's own last row, the boxed one's below the box - so `region` is
-- the row stated by `screen_rows` and `content - 1` is the fallback's own spelling of it.
-- `row("O")` and `screen_on` are the two places that already answer "where does output end", so they
-- ask this instead of the height.
--
-- TWO claimants take that row above the box, and both must be honoured here: the
-- session-status-content line, and a run's own status line while it is in flight. The boxed layout
-- puts both on rows of their own, but the chat's own last row (`bottom`) is the row directly above the
-- box - the status line's - so a run that reserved nothing for itself had its status line written over
-- by the next transcript block and repainted under it: the blink `METHODS:clear` was rewritten to
-- avoid (`scripts/test-cli-view.lua`, "a turn of ten tool calls erases the status row no times").
-- `rust/wa-term/src/terminal_editor.rs`'s `out_bottom` reserves the same row from the same two facts.
function METHODS:region_bottom()
  local screen = self:layout()
  if not screen then return nil end
  -- The self-wake row is reserved the same way (`layout` already moved these rows up when it shows), so a
  -- chat line never lands under it.
  if self:session_content() or self.turn or self:has_wakes() then
    return math.max(1, screen.region or (screen.content - 1))
  end
  return screen.bottom
end

-- Where the line goes, as a cursor address. In the boxed layout it is the row directly under the box
-- and directly above the footer, which is fixed: it does not move when the draft grows, when the
-- slash menu opens or when a run's status line comes and goes, so it needs no token. The fallback
-- names the row `screen_rows` gave it, which is the output region's last row.
function METHODS:session_address()
  local screen = self:layout()
  if not screen then return nil end
  if self.editor and self.editor_ready and self.stdout and host and host.panel then
    return "\27[" .. tostring(screen.session or screen.status) .. ";1H"
  end
  return "\27[" .. tostring(screen.session or screen.content) .. ";1H"
end

-- Draw it, or clear it when it goes away. Bounded to its own row: it never wraps, never commits a
-- newline and never touches the reader's input row. A captured transcript (not live) draws nothing
-- here - `paint` writes the line once, as text, where a reader of the log can see it.
function METHODS:session_draw()
  local screen = self.screen
  if not screen or not self.live then return end
  local text, kind = self:session_line()
  local native = self.editor and self.editor_ready and self.stdout
  -- The native editor's row is drawn by the host from the same facts (`wa-term`'s loader, which has
  -- the progress bar): this module draws only the notice there, so the loader is never written twice
  -- on one row. The layout this module owns shrinks its scroll region so output cannot reach the row.
  if native and text and kind ~= "notice" then text = nil end
  -- ONE drawer (14/11): the editor owns the row and draws the notice from the text it is handed, so this
  -- view never writes there - two writers on one row painted the notice over the box's bottom border.
  if native and host and host.editor_notice then
    local content = kind == "notice" and self:session_content() or nil
    pcall(host.editor_notice, content and content.text or "")
    return
  end
  local bottom = self:region_bottom()
  if not native and bottom and self.region_row ~= bottom then
    self:control("\27[1;" .. bottom .. "r")
    self.region_row = bottom
  end
  local address = self:session_address()
  if not address then return end
  if text then
    local cols = visible_columns(text)
    local pad = self.session_shown_cols > cols and (self.session_shown_cols - cols) or 0
    self:control(CURSOR_SAVE .. address .. text .. string.rep(" ", pad) .. "\27[K" .. CURSOR_RESTORE)
    self.session_shown, self.session_shown_cols = text, math.max(self.session_shown_cols, cols)
    return
  end
  if self.session_shown then
    self:control(CURSOR_SAVE .. address .. "\27[2K" .. CURSOR_RESTORE)
    self.session_shown, self.session_shown_cols = nil, 0
  end
end

-- The self-wake fact, read once and handed to its own row: `host.editor_wakes` when the native editor owns
-- the bottom of the screen, `wake_draw` (the fallback layout) otherwise. Both footer writers - the live one
-- during a run and `run_finished` at its end - call THIS, so the fact cannot creep back into the status
-- bar's numbers through the one of them somebody forgot (it did: `run_finished` appended it until 13/11).
function METHODS:wake_row()
  self.wakes = M.wake_text(self.session_id)
  if host and host.editor_wakes then pcall(host.editor_wakes, self.wakes) end
  return self.wakes
end

-- The self-wake row: the fact on ONE line directly above the session status bar, or nothing when no wake is
-- scheduled. Drawn only in the fallback layout - with the native editor, `rust/wa-term`'s `Editor` owns that
-- row from the same text (`host.editor_wakes`), so the two renderers cannot disagree about what it says.
function METHODS:wake_draw()
  local layout = self:layout()
  local wake_row = (layout and layout.wake) or (self.screen and self.screen.status and self.screen.status - 1)
  if not wake_row then return end
  if self.editor and self.editor_ready and self.stdout and host and host.editor_wakes then return end
  if not self.live then return end
  local row = wake_row
  if self:has_wakes() then
    local text = clip(self.wakes, math.max(1, self.limit))
    self:control(CURSOR_SAVE .. "\27[" .. row .. ";1H\27[2K" .. paint(text, "dim", self.live) .. CURSOR_RESTORE)
    self.wake_shown = true
    return
  end
  if self.wake_shown then
    self:control(CURSOR_SAVE .. "\27[" .. row .. ";1H\27[2K" .. CURSOR_RESTORE)
    self.wake_shown = false
  end
end

-- The hint row under the input box: the last run's numbers, or what to type. Boxed screens only.
-- Its own content only: the update notice has a line of its own above the status bar now, so the
-- numbers are never pushed right to make room for it (07/11).
function METHODS:footer_draw()
  if not (self.live and self.screen and self.screen.footer) then return end
  local hint = (self.last_summary and self.last_summary ~= "") and self.last_summary
    or "/ for commands \194\183 /login to sign in \194\183 ctrl+c twice to quit"
  -- The editor owns that row (the slash menu uses it), so it is handed the text, not drawn on.
  -- The ball wears its level's colour in BOTH drawers: the native editor's row is clipped by CELLS
  -- with escapes counting zero (`visible_cells`, rust/wa-term/src/terminal_editor.rs), so a coloured
  -- row is measured like a plain one and cannot wrap the row under the box (Victor, 19/11).
  local shown = M.colour_ball(clip(hint, math.max(10, self.limit - 1)), self.context, self.budget,
    self.live, self.model, self.summary_percent)
  if self.editor and self.stdout and host and host.editor_footer then
    pcall(host.editor_footer, shown, self.model or "")
  else
    self:control(CURSOR_SAVE .. "\27[" .. self.screen.footer .. ";1H\27[2K"
      .. paint(shown, "dim", self.live) .. CURSOR_RESTORE)
  end
  -- After the footer, never before: the host's footer write redraws the whole bottom of the screen,
  -- so a line drawn first would be erased by it. The wake row first, so the session line above it is
  -- drawn last and owns its own row.
  self:wake_draw()
  self:session_draw()
end

-- The footer's session numbers, now: refreshed while a run is in flight (on usage and tool events)
-- so they move together with the status line, and left there when it ends.
function METHODS:live_footer()
  if not (self.screen and self.screen.footer) then return end
  local totals = self.totals or {}
  self.last_summary, self.summary_percent = M.session_summary({ runs = self.runs, tools = self.session_tools or 0,
    prompt = totals.prompt, completion = totals.completion, cached = totals.cached,
    context = self.context, budget = self.budget })
  -- The self-wake fact has a row of its own, directly above the session status bar: it used to be
  -- appended to the numbers on that bar, where it squeezed them and, on a narrow terminal, wrapped the
  -- bar it was sharing (Victor, 13/11). "" takes the row away again when nothing is scheduled.
  self:wake_row()
  local hook = M.hook_text(self.session_id, self.model, { runs = self.runs, tokens = self.tokens,
    context = self.context, context_percent = (self.context and self.budget and self.budget > 0)
      and (100 * self.context / self.budget) or nil })
  if hook ~= "" then self.last_summary = self.last_summary .. " \194\183 " .. hook end
  self:footer_draw()
end

-- `󰷺steps·step-time Δadded ↑in ↓out 󰔛run-time` for the current run.
--
-- THIS RUN ONLY (Victor, 19/11 12:15, item H). The row carries the run's own additions - the
-- SIGMA-UP of what this run sent and the down arrow of what it received - and NO session total:
-- the session's two sums live in the footer (SIGMA-UP and SIGMA-DOWN), and a number printed on
-- both rows makes a reader compare two things that are not the same thing.
function METHODS:run_numbers(step_clock, run_clock, finish)
  local run, base, totals = self.turn or {}, (self.turn and self.turn.baseline) or {}, self.totals or {}
  local input = math.max(0, (self.context or 0) - (run.context or 0))
  local output = math.max(0, (totals.completion or 0) - (base.completion or 0))
  local row = GLYPH.steps .. GAP .. math.max(1, run.rounds or 0) .. (step_clock and ("\194\183" .. step_clock) or "")
    .. " \206\148\226\134\145" .. M.tokens(input)
    .. " \226\134\147" .. M.tokens(output)
    .. " " .. GLYPH.clock .. GAP .. run_clock
  if finish and finish.ok then
    -- The check wears the same one space every other icon here does, and the stamp is set off by a
    -- middle dot: "0:25 \194\183 18:47" reads as a duration followed by a moment.
    local at = M.finish_time(finish.at)
    if at ~= "" then row = row .. " \194\183 " .. GLYPH.check .. at end
  end
  return row
end

-- Called on every event: a new frame, and a repaint. In the plain rendering the line is
-- only printed when the *phase* changes - a log line per spinner frame would be noise,
-- and there is nothing here a reader could not get from the tool lines.
-- The plain rendering's session-status-content line: written once when it appears or changes, and
-- not when it clears - a log has no row to blank, and an empty line would be a gap the live view does
-- not have. Same text, same place above the status bar's own lines, no escape sequences.
function METHODS:session_log()
  local content = self:session_content()
  local key = content and (content.kind .. ":" .. content.text) or nil
  if key == self.logged_session then return end
  self.logged_session = key
  if content then self:write(paint(clip(content.text, math.max(1, self.limit)), M.session_role(content.kind), self.live) .. "\n") end
end

function METHODS:paint(force)
  -- The console draws every event as its own line, so a line rewritten in place has nothing
  -- to say and would fight it for the cursor.
  if self.console then return end
  if self.screen then self:screen_on() end
  self.frame = self.frame + 1
  local line = clip(self:status_text(self.live), self.limit)
  if self.live then
    -- The host may be drawing this line at this instant: take it back before writing on it,
    -- then hand it over again, because this process is about to block.
    self:unanimate()
    if line ~= self.shown then
      self:status_draw(line)
      self.shown = line
    end
    self:animate()
    -- Last, so the status bar's own frame cannot paint over the line above it.
    self:session_draw()
    return
  end
  self:session_log()
  if force or self.phase ~= self.logged then
    self.logged = self.phase
    self:write(line .. "\n")
    self.shown = line
  end
end

-- Take the status line back. Called before this module writes anything at all: two writers on
-- one line is how a status line becomes two half-lines.
--
-- Inline, the row is the reader's own row, so what it leaves behind is its own columns blanked and
-- nothing of the reader's touched: clearing it is as bounded as drawing on it. The cursor ends at
-- column zero of that row, where the next line of output starts - the layout this view has always
-- had, and which keeps a reply from being indented by the width of a status line.
-- A screen has already given the line a row of its own, so there is nothing to take back: see the
-- body.
function METHODS:clear()
  -- Never wipe a line the host is still drawing: stopping waits for its last frame to land.
  self:unanimate()
  if self.screen then
    -- What it leaves behind is nothing at all: the status line has a row of its own, and a transcript
    -- write goes into the output region above it, so there is nothing here to take back. Erasing the
    -- row and drawing it again a moment later was a visible blink on every tool call (Victor,
    -- 08/11), and `\27[2K` is the one thing this method must not do to a row that only ever holds
    -- its own line. The row is left exactly as it is: the host ticker may have advanced the mark
    -- since this module last drew it (`shown`), and rewriting `shown` would step that backwards. A
    -- line that is really going away is taken off the row once, where the run ends
    -- (`status_blank`); every other frame rewrites it in place (`status_draw`).
    return
  end
  if self.live and self.shown_cols > 0 then
    self:control("\r" .. string.rep(" ", self.shown_cols) .. "\r")
    self.shown_cols = 0
  end
  self.shown = nil
end

-- The status line, gone from its row: its own columns rewritten as blanks and erased to the end of
-- that row, once, at the moment it really goes away (the end of a run, where the boxed layout leaves
-- the row empty until the next one). Never before a transcript write - an erase followed by the
-- redraw is exactly the blink `METHODS:clear` no longer makes. Bounded to the row and to the live
-- view: a transcript has no row to blank.
function METHODS:status_blank()
  if not self.screen then return end
  if self.live then
    self:control(CURSOR_SAVE .. "\27[" .. self:row("S") .. ";1H"
      .. string.rep(" ", self.shown_cols) .. "\27[K" .. CURSOR_RESTORE)
  end
  self.shown, self.shown_cols = nil, 0
end

-- The rows this view owns, once the console's height is known.
--
-- Canonical fallback: output through R-2, the session-status-content line on R-2 as well (it has
-- no text area of its own), status R-1, input R.
-- Native editor, bottom up: the footer (session status bar) on R, the session-status-content line on
-- R-1, the box (bottom border, three draft rows, top border) on R-2..R-6, the run-status line above
-- it, and the output above that.
-- A reserved scroll region keeps output from scrolling over the draft. The raw
-- editor owns the bottom rows and handles echo/Enter itself while Lua is blocked.
-- `WASM_AGENT_CLI_FRAME=off` or a console too short for the regions falls back
-- to a shell-style prompt at the output cursor.
function METHODS:screen_on()
  if not self.live then return nil end
  if (self.getenv("WASM_AGENT_CLI_FRAME") or "") == "off" then return nil end
  -- The width, through the one function that reads and clamps it, so this path takes the same floor
  -- (M.MIN_COLUMNS) and honours the same probe (columns_probe, a test's console) as every frame.
  if self.stdout then self:refresh_limit() end
  local screen = screen_rows(self.rows and self.rows(), self.editor)
  -- A console that cannot report a height keeps whatever screen it already had: the caller falls
  -- back to the prompt at the cursor, which is on the input row anyway.
  if not screen then return nil end
  -- A resized window moves the rows with it. The old screen is given back (its scroll region with
  -- it) and a new one is laid out on the height the console now reports; without this, a window
  -- made smaller leaves output scrolling over the status and input rows for the life of the chat.
  if self.screen and self.screen.status == screen.status and self.screen.input == screen.input then return self.screen end
  local resized = self.screen ~= nil
  if resized then self:unanimate(); self:screen_off() end
  self.screen = screen
  -- The region first, then one newline inside it: the region's last row may hold output from
  -- before the screen existed, and every write below assumes the row it writes into is free.
  -- Its last row is `region_bottom`, one less while the session-status-content line is showing.
  local bottom = self:region_bottom() or screen.bottom
  self.region_row = bottom
  self.session_shown, self.session_shown_cols = nil, 0
  self:control("\27[1;" .. bottom .. "r")
  self:control("\27[" .. bottom .. ";1H\r\n")
  self:control("\27[" .. screen.status .. ";1H\27[2K")
  if self:session_content() then
    self:control("\27[" .. tostring(screen.session or screen.content) .. ";1H\27[2K")
  end
  for row = screen.input_top or screen.input, screen.footer or screen.input do
    self:control("\27[" .. row .. ";1H\27[2K")
  end
  if resized and self.editor then
    assert(host.input_editor(screen.input, self.limit, M.EDITOR_ROWS),
      "terminal editor could not resize")
  elseif self.editor and self.stdout and host.input_editor and not self.editor_ready then
    -- Hand the editor its rows now, before anything is written: from here on output goes through
    -- the host's row tokens, which is what lets it put the chat back after the slash menu closes.
    pcall(host.input_editor, screen.input, self.limit, M.EDITOR_ROWS)
  end
  if self.editor and self.stdout then self.editor_ready = true end
  self:footer_draw()
  return screen
end

-- Give the screen back. The scroll region outlives this process if it is not reset, and a shell
-- whose output scrolls only the top 22 rows of a 24-row window is a bug the next reader gets to
-- explain.
function METHODS:screen_off()
  self:unanimate()
  local screen = self.screen
  self.screen = nil
  self.region_row, self.session_shown, self.session_shown_cols = nil, nil, 0
  if not screen then return end
  if self.editor and host.input_editor then pcall(host.input_editor, 0, self.limit, M.EDITOR_ROWS) end
  self:control("\27[" .. screen.status .. ";1H\27[2K")
  for row = screen.input_top or screen.input, screen.footer or screen.input do
    self:control("\27[" .. row .. ";1H\27[2K")
  end
  self:control("\27[r")
  self:control("\27[" .. math.max(screen.footer or screen.input, screen.status) .. ";1H\r\n")
end

-- The welcome block, as something the view OWNS and can draw again.
--
-- MEASURED on the base (0b9d574c): the banner was written ONCE as a finished block -
-- `print(cli_view.banner{...})` in `lua/core/chat.lua`, where that `print` is the file's own alias for
-- `view:line` - and its rule was ALREADY EXPANDED to the width of that moment (`M.banner` called
-- `M.expand_rules`). So no renderer downstream could draw it at another width: with a native editor the
-- host's transcript held a stored row of 80 rule characters and re-wrapped it into 60 + an orphan row
-- of 20 when the window narrowed (rust/wa-term/src/transcript.rs `wrap_rows`), and in the plain layout
-- the terminal itself reflowed the same characters. That is the stray "─" under the rule (Victor,
-- 21/11), and a rule is nothing but its width, so it is the one component that cannot be committed at
-- a measured width at all.
--
-- Hence: the view keeps the BANNER'S OWN INPUTS (`self.welcome`), and the rule reaches the renderer as
-- the MARKER (`M.banner`'s `opts.marker`). With the native editor the block goes into the host's
-- transcript, which expands the marker at every frame's width; in the plain layout this view expands it
-- at the width the console reports now, and draws the block again when that width moves
-- (`METHODS:resized`).
function METHODS:welcome(opts)
  self.welcome = opts or {}
  return self:render_welcome()
end

-- The welcome block at the width the view has NOW. Idempotent: it writes the block where output goes,
-- so calling it again after a clear is exactly what a repaint is.
function METHODS:render_welcome()
  local stored = self.welcome
  if not stored then return false end
  local opts = {}
  for key, value in pairs(stored) do opts[key] = value end
  local transcript = self:transcript()
  if transcript then
    -- The host expands the rule per frame; the width that matters is the one it draws at, so nothing
    -- here is fitted to a measured width.
    opts.marker, opts.limit = true, 1000000
  else
    opts.limit = self.limit
  end
  local text = M.banner(opts)
  if transcript then self:topic(false) end
  -- `tail_nl` says how many newlines the last write ended with, and a clear has just made that
  -- unknowable: starting the block with an open line rather than a gap is the honest state.
  self.tail_nl = 0
  self:write(text .. "\n")
  -- The lines that belong to the block and come after it (the reload source, `METHODS:note`): kept
  -- with it, so the redraw puts them back instead of leaving them at the width they were written at.
  for _, line in ipairs(self.welcome_notes or {}) do self:write(line .. "\n") end
  return true
end

-- The welcome block as it would be drawn NOW, escapes and all: the same composition `render_welcome`
-- writes, with the rule at the console's width. The opening paints these as its last beat on the
-- alternate screen, so the frame it hands the reader over to is the frame behind it - `chat.lua` hands
-- them over with `host.opening_header`, and the two must agree, so this is the one that composes.
function METHODS:welcome_painted()
  local stored = self.welcome
  if not stored then return nil end
  local opts = {}
  for key, value in pairs(stored) do opts[key] = value end
  if self:transcript() then
    opts.marker, opts.limit = true, 1000000
    return M.expand_rules(M.banner(opts), self.limit)
  end
  opts.limit = self.limit
  return M.banner(opts)
end

-- A line of the welcome block that is not the box itself: what this CLI is running from, said under
-- the banner. Owned like the banner is (kept in `self.welcome_notes` and written where output goes) so
-- a width change draws it again with the block - a line left at the old width is the same defect as a
-- rule left at the old width, only quieter.
function METHODS:note(text)
  self.welcome_notes = self.welcome_notes or {}
  self.welcome_notes[#self.welcome_notes + 1] = tostring(text)
  self:write(tostring(text) .. "\n")
  return true
end

-- The window changed width, at the frame boundary that noticed it (METHODS:refresh_limit): draw again
-- what this view owns, at the width the console has now, and leave nothing behind at the old one.
--
-- A row the terminal already holds cannot be reflowed by the process that wrote it - foot, like every
-- other terminal, re-wraps its own scrollback - so the robust answer is Claude Code's: clear the screen
-- AND the scrollback and draw the owned content again from state. What that content is, per layout:
--
--   * native editor: the host's transcript model, and it repaints itself on a resize (host.rs
--     REPAINT_CLEAR + `layout_frame`), expanding every rule marker at the new width. The welcome block
--     is one of its blocks (METHODS:welcome), so there is nothing for this method to do;
--   * plain layout: no transcript model exists - this view streams the bytes it is given - so the
--     content it holds is the welcome block plus the frame rows it redraws on every render. They are
--     what comes back; the rows between them are what the clear removed, and that is said plainly
--     rather than pretended away.
function METHODS:resized(previous)
  -- What makes it safe to clear the screen is that this view OWNS a screen (live, with a layout it drew),
  -- not that the bytes go to the process's stdout: a view written to a buffer (a test, a capture) is the
  -- same surface, and the one a test can drive.
  if not self.live then return false end
  local screen = self.screen
  if not screen then return false end
  -- Nothing it holds to draw again: clearing the screen for a view with no welcome block would cost the
  -- reader their transcript and put nothing in its place.
  if not self.welcome then return false end
  if self:transcript() then return false end
  self:unanimate()
  -- The screen is given back (its scroll region with it) BEFORE the clear: the region is a function of
  -- the height as well as the width, and `screen_on` lays it out again for the console that is there now.
  self:screen_off()
  self.tail_nl = nil
  self:control(SYNC_START .. "\27[?25l\27[2J\27[3J\27[H" .. SYNC_END)
  self:screen_on()
  self:render_welcome()
  return true
end

-- A framed terminal gives its input rows to the native editor; captured/plain
-- output and consoles without raw input retain the shell-style line prompt.
-- Reclaim only the submitted input row, after Enter and before a run starts.
-- Never do this during a model call: the user may already be typing another line.
function METHODS:submitted()
  if self.editor then return end -- the native editor cleared the row on Enter
  if self.screen then
    self:control("\27[" .. self.screen.input .. ";1H\27[2K" .. PROMPT)
  end
end

-- `text` is the prompt: `❯ ` for a chat line, or a question (`/login` asking which provider). The
-- boxed editor has its own `❯ `, so a question is written into the transcript above the box -
-- otherwise the reader is asked something they cannot see.
function METHODS:prompt(text)
  local question = text and text ~= PROMPT and text ~= "> " and text ~= "wa> " and text or nil
  text = text or PROMPT
  local screen = self:screen_on()
  if not screen then
    self:clear()
    return self:control(text)
  end
  self:unanimate()
  if self.last_summary and not screen.footer then
    self:status_draw(paint(clip(self.last_summary, self.limit), "dim", self.live))
  end
  -- A native editor, when available, owns the bottom row and redraws it on every
  -- keystroke even when Lua is blocked. No terminal echo or Enter newline is involved.
  if self.editor then
    if question then self:write(paint((question:gsub("%s+$", "")), "text", self.live) .. "\n") end
    self:footer_draw()
    assert(host.input_editor(screen.input, self.limit, M.EDITOR_ROWS),
      "terminal editor could not draw")
  else
    self:control("\27[" .. screen.input .. ";1H\27[2K" .. text)
  end
  if not self.turn then self:animate() end
end

-- The reader's line, moved into the transcript.
--
-- The input row is about to be reused, and the terminal's echo of what they typed lives only on
-- that row: without this, pressing Enter would leave them unable to check what they sent. Written
-- as a `wa> ` line into the output region, the shape pi and codex use for the same reason.
function METHODS:accepted(text)
  text = tostring(text or "")
  if text == "" or not self.screen then return end
  self:clear() -- the host ticker must not write while this line is committed
  -- The width this bubble wraps at is the terminal as it is NOW, not as it was when the view was
  -- made: a window maximised or split before the reader sends a line must wrap that line at the
  -- new width (item E, the same read every other framed component makes).
  if self.stdout then self:refresh_limit() end
  -- `❯ what you typed`, greyed, the way Claude Code keeps your message in the transcript.
  -- White on a grey bar the width of the screen, the way the message stands out from the replies.
  local shown, first = {}, true
  -- Every word the reader sent, wrapped - never clipped with `…` (operator 17/11: "user input sent to the
  -- cli chat content should render fully 100% what he said"). One column is left for the scrollbar.
  local width = math.max(10, self.limit - 3)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local pieces = codemode_block.wrap(line, width, { columns = columns })
    if #pieces == 0 then pieces = { "" } end
    for _, piece in ipairs(pieces) do
      local body = (first and PROMPT or "  ") .. piece
      if self.live then
        -- The grey goes to the end of the ROW by EL (ESC[K), not by a run of spaces: padding is
        -- characters, so a narrow terminal re-wraps them and a resize turns a painted row into
        -- ragged fragments (Victor, 19/11 11:20). The erase takes the row background colour, so
        -- the band stays solid and the line holds no trailing blanks at all (item F).
        body = "\27[38;2;255;255;255m\27[48;2;68;68;68m" .. body .. "\27[K" .. RESET
      end
      shown[#shown + 1] = body
      first = false
    end
  end
  self:topic(false)
  self:write(table.concat(shown, "\n") .. "\n\n")
  self.tail_nl = 2
  if self.turn then self:paint(true) end
end

-- The terminal title carries the same word as the status line, which is how a reader
-- looking at another tab still knows the run is alive (pi does the same).
function METHODS:title_text()
  local name = self.title ~= "" and self.title or "wa"
  if self.pending then return M.spinner(self.frame) .. " " .. name .. " \194\183 " .. self.phase end
  if self.turn then return M.spinner(self.frame) .. " " .. name .. " \194\183 " .. self.phase end
  return name
end

function METHODS:set_title()
  if not self.live then return end
  self:control("\27]2;" .. self:title_text() .. "\7")
end

-- ---- the events ----------------------------------------------------------------

-- Streamed text up to a model's own tool-call markup (`<｜DSML｜...`, `<tool_call>`): from there on the
-- step is a run call that runs as a script, so the markup is not shown
-- (17/11: the raw DSML lines were printed live, then the same call ran as a block). A trailing `<...`
-- without `>` waits for the next piece, so a marker split across deltas is still caught.
local function fence_at(text)
  -- a ```js / ```javascript fence (tagged `run` or not) at the start of a line: the script is drawn by the
  -- run block, so its streamed copy (and anything after it, which the step drops) is held back
  for _, lead in ipairs({ "```js", "```javascript" }) do
    if text:sub(1, #lead) == lead then return 1 end
    local at = text:find("\n" .. lead, 1, true)
    if at then return at + 1 end
  end
end
local function markup_at(text)
  local found = text:find("<%s*\239\189\156%s*DSML") or text:find("<%s*|%s*DSML") or text:find("<tool_call>", 1, true)
  local fence = fence_at(text)
  if found and fence then return math.min(found, fence) end
  return found or fence
end
-- The two streams of a step, written as one flow: thinking (`✻ ` then the thought, gray) and saying
-- (white). A switch between them, or into a code block, is one blank line. Trailing newlines of a piece
-- are held until text follows, so a stream never ends with a blank line of its own that a boundary then
-- doubles (17/11: two blank rows above every code block, "Let me send.Enviando" glued).
function METHODS:flow(kind, text)
  text = tostring(text or "")
  if text == "" then return end
  if self.flow_kind ~= kind then
    self:flow_flush()
    self.flow_held = 0
    if self.flow_kind ~= nil or (self.tail_nl or 1) ~= 0 then self:gap(1) end
    self.flow_kind = kind
    text = kind == "think" and text:gsub("^%s+", "") or text:gsub("^\n+", "")
    if text == "" then self.flow_kind = nil return end
  end
  if kind == "think" then
    -- Thinking: gray, no mark (operator 17/11). Painted LINE BY LINE: the host keeps colour per line, so
    -- one paint around a chunk that crosses a newline left the next paragraph's first words in the
    -- terminal's own colour until the next chunk arrived ("first words blue, then gray").
    local body, tail = text:match("^(.-)(\n*)$")
    if body ~= "" then
      if (self.flow_held or 0) > 0 then self:write(string.rep("\n", self.flow_held)) end
      self.flow_held = 0
      local parts, first = {}, true
      for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        parts[#parts + 1] = (first and "" or "\n") .. (line ~= "" and paint(line, "dim", self.live) or "")
        first = false
      end
      self:write(table.concat(parts))
    end
    self.flow_held = (self.flow_held or 0) + #tail
    return
  end
  -- Saying (commentary, the answer): markdown, rendered a complete line at a time (17/11: `**bold**`
  -- was printed raw). A fence or a table is collected whole first; a partial line waits for its newline.
  self.say_buf = (self.say_buf or "") .. text
  while true do
    local line, rest = self.say_buf:match("^([^\n]*)\n(.*)$")
    if not line then break end
    self.say_buf = rest
    self:say_line(line)
  end
end

-- One complete line of what the model is saying, into the markdown block it belongs to.
function METHODS:say_line(line)
  local md = self.say_md
  if md and md.kind == "fence" then
    md.lines[#md.lines + 1] = line
    if line:match("^%s*```") then self:say_emit(table.concat(md.lines, "\n")); self.say_md = nil end
    return
  end
  if line:match("^%s*```") then
    self:say_table_end()
    self.say_md = { kind = "fence", lines = { line } }
    return
  end
  if line:match("^%s*|") then
    if not (md and md.kind == "table") then self.say_md = { kind = "table", lines = {} } end
    self.say_md.lines[#self.say_md.lines + 1] = line
    return
  end
  self:say_table_end()
  if line:match("^%s*$") then self.flow_held = (self.flow_held or 0) + 1 return end
  self:say_emit(line)
end

function METHODS:say_table_end()
  local md = self.say_md
  if md and md.kind == "table" then self.say_md = nil; self:say_emit(table.concat(md.lines, "\n")) end
end

function METHODS:say_emit(text)
  -- The held newlines go out FIRST: `markdown` hands the host a fence's copy marker for the NEXT write
  -- (transcript_copy), and a newline written after it took the marker - no copy icon on fences (17/11).
  if (self.flow_held or 0) > 0 then self:write(string.rep("\n", self.flow_held)); self.flow_held = 0 end
  local rendered = self:markdown(text, {
    paint = function(plain, style) return paint(plain, style, self.live) end,
    width = self.limit - 2, indent = "", reflow = self:transcript(), style = "commentaryText",
  })
  if rendered == "" then rendered = paint(text, "commentaryText", self.live) end
  self:write(rendered)
  self.flow_held = 1
end

-- What is still held: a partial line, an open fence or table. Written as it stands.
function METHODS:flow_flush()
  if self.say_buf and self.say_buf ~= "" then
    local line = self.say_buf
    self.say_buf = ""
    self:say_line(line)
  end
  local md = self.say_md
  self.say_md = nil
  if md then self:say_emit(table.concat(md.lines, "\n")) end
end

-- A boundary (a code block, the answer's end): the flow is over; held newlines are dropped and the next
-- writer asks for its own gap.
function METHODS:flow_end()
  self:flow_flush()
  self.flow_kind, self.flow_held = nil, 0
end

function METHODS:delta_piece(text)
  local d = self.dstream or { buf = "", shown = 0 }
  self.dstream = d
  -- Hidden text is still kept: if the step turns out to be the answer, `delta_reset(true)` writes it.
  d.buf = d.buf .. text
  if d.hidden then
    if d.code then self:code_stream(d) end
    return
  end
  local at = markup_at(d.buf)
  if at then
    if at - 1 > d.shown then self:flow("say", d.buf:sub(d.shown + 1, at - 1)) end
    d.shown = math.max(d.shown, at - 1)
    d.hidden = true
    -- A run block streams AS CODE (operator 17/11: "codeact does not stream, it just prints"): its block
    -- opens now and every line is drawn on its band as it completes; the call event that follows finds
    -- the block already on screen and only adds its call rows.
    if fence_at(d.buf) == at and self:transcript() then
      d.code = { pos = at, opened = false }
      self:code_stream(d)
    end
    return
  end
  -- hold a tail that may still become a marker: `<...` without `>`, or a last line that is a fence prefix
  local hold = d.buf:match("<[^>]*$")
  local held = (hold and #hold <= 32) and #hold or 0
  local last = d.buf:match("\n([^\n]*)$") or d.buf
  if #last <= 13 and last ~= "" and ("```javascript"):sub(1, #last) == last then held = math.max(held, #last) end
  local upto = #d.buf - held
  if upto > d.shown then self:flow("say", d.buf:sub(d.shown + 1, upto)); d.shown = upto end
end
-- The native `run` tool's script, drawn as the model writes it. `event.text` is the decoded `code`
-- argument (lua/core/run_stream.lua): never JSON, never an argument preview, so what lands on the band
-- is the program itself. Whole lines only - a band row is a row, and a half line redrawn in place is not
-- what a stream of code looks like - with the last one flushed when the call announces itself.
function METHODS:run_code_piece(event)
  if not self:transcript() then return end
  local text = tostring(event.text or "")
  if text == "" then return end
  local stream = self.run_stream
  if not stream then
    -- The prose before the call is already written, as the tool path does it, and then the block opens
    -- one blank line below it - the same shape a fenced run block has.
    self:commentary_flush()
    self:flow_end()
    self:gap(1)
    if host.transcript_block then pcall(host.transcript_block, true, true) end
    self.code_streamed = true
    stream = { pending = "" }
    self.run_stream = stream
  end
  stream.pending = stream.pending .. text
  local o = self:codemode_opts()
  while true do
    local nl = stream.pending:find("\n", 1, true)
    if not nl then break end
    local line = stream.pending:sub(1, nl - 1):gsub("\r$", "")
    stream.pending = stream.pending:sub(nl + 1)
    for _, row in ipairs(codemode_block.rows(codemode_block.new({ code = line }, self.now()), self.limit, o)) do
      self:run_code_row(row)
    end
  end
end

-- The line the model was still writing when its call announced itself: drawn now, so no line of the
-- script is ever lost to the timing of the provider's last chunk.
function METHODS:run_code_flush()
  local stream = self.run_stream
  self.run_stream = nil
  if not stream or stream.pending == "" then return end
  local o = self:codemode_opts()
  for _, row in ipairs(codemode_block.rows(codemode_block.new({ code = stream.pending }, self.now()), self.limit, o)) do
    self:run_code_row(row)
  end
  stream.pending = ""
end

-- One row of the streaming script, written AND remembered: the rows are what `run_code_settle_block`
-- rewrites in place once the whole script is known.
function METHODS:run_code_row(row)
  self.code_stream_rows = self.code_stream_rows or {}
  self.code_stream_rows[#self.code_stream_rows + 1] = row
  self:write(row .. "\n")
end

-- THE SCRIPT ON SCREEN IS THE SCRIPT (Victor 21/11).
--
-- The stream can stop early or repeat itself - a provider chunk, a relay, a decoder that met a
-- fragment it could not split - and the block then held ONE row (`const a = await{`) where the model's
-- program should be. The call event carries the arguments WHOLE, so when it arrives the block's rows
-- are rewritten in place to exactly what the script is, and the rows it never got are appended. That
-- is the same mechanism a settling block uses (`codemode_sync`): a row is rewritten, never removed, so
-- nothing the reader already sees moves under them.
function METHODS:run_code_settle_block(script)
  local drawn = self.code_stream_rows
  self.code_stream_rows = nil
  -- Only the rows THIS function's own streaming wrote are completed: a fenced run block streamed its
  -- code through `code_stream` (it is already whole on screen, and its rows are not tracked here), and
  -- drawing the script again over it was a second copy of the program under the first.
  if not drawn or #drawn == 0 then return end
  local o = self:codemode_opts()
  local code = type(script) == "string" and script or ""
  if code == "" then return end
  local rows = codemode_block.rows(codemode_block.new({ code = code }, self.now()), self.limit, o)
  local same = #drawn == #rows
  if same then
    for index = 1, #drawn do
      if drawn[index] ~= rows[index] then same = false; break end
    end
  end
  if same then return end
  if self:transcript() and host.transcript_rewrite then
    for index = 1, math.min(#drawn, #rows) do
      pcall(host.transcript_rewrite, index - #drawn - 1, rows[index])
    end
  end
  for index = #drawn + 1, #rows do self:write(rows[index] .. "\n") end
end

-- The streaming run block: complete lines after the opening fence, each drawn as band rows; the closing
-- fence ends it (what follows it is dropped by the step, so it is not drawn either).
function METHODS:code_stream(d)
  local c = d.code
  if not c or c.closed then return end
  while true do
    local nl = d.buf:find("\n", c.pos, true)
    if not nl then return end
    local line = d.buf:sub(c.pos, nl - 1):gsub("\r$", "")
    c.pos = nl + 1
    if not c.opened then
      -- the fence line itself: open the block, one blank line above it
      c.opened = true
      self:flow_end()
      self:gap(1)
      if host.transcript_block then pcall(host.transcript_block, true, true) end
      self.code_streamed = true
    elseif line:match("^%s*```%s*$") then
      c.closed = true
      return
    else
      local o = self:codemode_opts()
      for _, row in ipairs(codemode_block.rows(codemode_block.new({ code = line }, self.now()), self.limit, o)) do
        self:write(row .. "\n")
      end
    end
  end
end

-- `answer`: the step ended as the reply, so whatever was held back (a code block that did not run, a
-- held tail) is the reader's and is written now. Otherwise (a call ran) the held text was the call.
function METHODS:delta_reset(answer)
  local d = self.dstream
  if d and d.code and d.code.opened then
    -- the code is already on screen; an answer keeps only what it wrote after the closing fence
    if answer and d.code.closed and #d.buf >= d.code.pos then self:flow("say", d.buf:sub(d.code.pos)) end
  elseif d and (answer or not d.hidden) and #d.buf > d.shown then self:flow("say", d.buf:sub(d.shown + 1)) end
  if answer then self.code_streamed = nil end
  self.dstream = nil
end

function METHODS:run_started()
  self.reasoning_streamed = nil
  self:flow_end()
  self.runs = self.runs + 1
  self.dstream = nil
  self.frame = 0
  self.phase = "Thinking"
  self.pending = nil
  self.round = 0
  self.deltas = 0
  self.warned = nil
  -- The run's first model call: the wait the status row counts until the first byte arrives.
  self:model_waiting()
  -- The usage event carries the *session's* running totals, so a run's own numbers are
  -- the difference across it. The first run's baseline is zero, not nil: a footer with
  -- no numbers on the first turn is a footer that looks broken.
  if self.editor and self.stdout and host and host.editor_status then pcall(host.editor_status, true) end
  -- A copy, never the totals table itself: the agent adds to that table in place, so a
  -- baseline that *is* it moves with it and every run after the first diffs to zero.
  local totals = self.totals or {}
  self.turn = {
    started = self.now(), step_started = self.now(), rounds = 0, tools = 0,
    baseline = { prompt = totals.prompt or 0, completion = totals.completion or 0,
      cached = totals.cached or 0, cost = totals.cost or 0 },
    context = self.context or 0,
  }
  self:set_title()
  self:paint(true)
end

function METHODS:run_finished(finish)
  self:commentary_flush()
  self:progress("finish")
  self:clear()
  local run, baseline = nil, self.turn and self.turn.baseline
  if self.turn then
    run = {
      rounds = self.turn.rounds, tools = self.turn.tools,
      seconds = math.max(0, self.now() - self.turn.started),
    }
    if self.totals and baseline then
      run.prompt = (self.totals.prompt or 0) - (baseline.prompt or 0)
      run.completion = (self.totals.completion or 0) - (baseline.completion or 0)
      run.cached = (self.totals.cached or 0) - (baseline.cached or 0)
      run.cost = (self.totals.cost or 0) - (baseline.cost or 0)
    end
    run.cost = run.cost or (self.totals and self.totals.cost) or 0
  end
  local text = M.footer(run, { context = self.context, budget = self.budget })
  local wake = M.wake_text(self.session_id)
  if wake ~= "" then text = text == "" and wake or (text .. "  \194\183  " .. wake) end
  self.last_summary = text
  if self.screen and self.screen.footer and self.turn then
    -- The run's own numbers, left under it in the transcript: the status line, stopped.
    local now = self.now()
    self:topic(false)
    if self.tail_nl == 0 then self:write("\n") end
    -- The STEP clock stays on the finished row too, as Victor wrote it: the last step own
    -- duration is what the reader is looking at, and dropping it on finish made the row change
    -- shape at the moment it stopped.
    local step = M.step_clock(now - (self.turn.step_started or self.turn.started))
    self:write(paint(self:run_numbers(step, M.run_clock(now - self.turn.started), finish), "dim", self.live) .. "\n\n")
  end
  if self.screen and self.screen.footer then
    local totals = self.totals or {}
    self.last_summary = M.session_summary({ runs = self.runs, tools = self.session_tools or 0,
      prompt = totals.prompt, completion = totals.completion, cached = totals.cached,
      context = self.context, budget = self.budget })
    -- The fact is NOT appended here: it has its own row above the bar (`wake_row`). The `text` built
    -- above keeps it for a caller with no screen, where the once-printed line is the only place it can be.
    self:wake_row()
  end
  if text ~= "" and not self.screen then
    -- One line, clipped to the width: a footer that wraps puts its own tail at column
    -- zero, which reads as a second, unrelated line. The workspace and the branch are in
    -- the banner, where there is room for them.
    self:line(paint(clip(text, math.max(20, self.limit)), "dim", self.live))
  end
  self.turn = nil
  self.pending = nil
  self.phase = ""
  if self.screen and self.screen.footer then
    -- The run's numbers are in the footer and its status line is over: the row it drew on is taken
    -- back here, once, rather than by the erase `clear` used to make before every transcript write.
    self:status_blank()
    if self.editor and self.stdout and host and host.editor_status then pcall(host.editor_status, false) end
    self:footer_draw()
  elseif self.screen then
    -- The canonical layout leaves the run's numbers on the status row - the line, stopped - and with
    -- no numbers to leave takes the row back rather than leaving the last frame's text on it.
    if text ~= "" then
      self:status_draw(paint(clip(text, self.limit), "dim", self.live))
      self:animate()
    else
      self:status_blank()
    end
  end
  self:set_title()
end

-- The long-call row (`lua/core/tool_progress.lua`, docs/TOOL-PROGRESS.md): `begin` when a call
-- starts, `finish` when its result lands. The module is loaded on first use and every call into it is
-- guarded, because a transcript (`wa run`, a replay) has no row to draw and must not pay for one.
function METHODS:progress(action, tool)
  if self.console then return end
  local module = self.tool_progress
  if not module and self.live then
    local ok, loaded = pcall(dofile, 'lua/core/tool_progress.lua')
    if ok and type(loaded) == 'table' then module = loaded; self.tool_progress = module end
  end
  if not module then return end
  if action == "begin" then pcall(module.begin, tool, self.now()) else pcall(module.finish) end
end

-- What the call's own line says now: `{ text, kind }` or nil. It is the row *inside* the call's
-- block - `⟳ bash · 43s · remote call shape ok`, from this process's tail or the host's live file -
-- and it is never offered to the session-status-content row (Victor, 2026-11-10).
function METHODS:tool_line()
  local module = self.tool_progress
  if not module then return nil end
  -- The reader's own session: the live row is that session's file and no other's (session isolation,
  -- finding 1).
  local ok, value = pcall(module.status, { now = self.now(), limit = self.limit, session = self.session_id })
  if not ok or type(value) ~= 'table' or type(value.text) ~= 'string' or value.text == "" then return nil end
  return value
end


-- The live line of the call in flight, written inside its own transcript block: `""` takes it away.
-- Nothing here can repaint it while the call runs (a foreground `bash` blocks this interpreter inside
-- `host.exec`), so the host's ticker owns it - `wa-capabilities`' `refresh_tool_progress` rewrites the
-- same row from `tool-progress.json`; this only opens it, seeds it and takes it down.
function METHODS:tool_live(text)
  if not (self:transcript() and host and host.transcript_live) then return end
  pcall(host.transcript_live, tostring(text or ""))
end

-- A code-mode call's script, written into the call's own block (#121): the first `count` rows under
-- the heading - three, which is what the transcript's fold shows - and, where nothing folds (the
-- plain layout), a `\u{2026} +N lines` marker for the rest. The colour is the code block's own, so a
-- script reads as one thing rather than as prose with a basename in front of it.
function METHODS:code_block(name, args, count, marker)
  if M.target(name, args) ~= "codemode" then return 0 end
  local rows, hidden = M.code_rows(args, count or 3)
  for _, line in ipairs(rows) do
    self:write(paint("  " .. M.clip(line, math.max(8, self.limit - 2)), "mdCodeBlock", self.live) .. "\n")
  end
  if marker and hidden > 0 then
    self:write(paint("\226\128\166 +" .. hidden .. " lines (/console shows all)", "dim", self.live) .. "\n")
  end
  return #rows
end

-- ---- a code-mode block -------------------------------------------------------------

-- A call is a code-mode call when the tool that runs is `codemode`, whatever wrapper named it
-- (`tool_call name=codemode` unwraps through `M.target`).
local function is_codemode(name, args)
  -- The native `run` tool IS a code-mode call: its `code` argument is the script, its inner calls are
  -- `tools.X(...)`, and it settles with the same result object. It is drawn by the same block, so the
  -- reader cannot tell which transport asked for the script (Victor 21/11: the native arm must look
  -- like the block one).
  if name == "run" then return true end
  return M.target(name, args) == "codemode"
end
M.is_codemode = is_codemode

-- What `lua/core/codemode_block.lua` needs from this view: the colour decision, the width fitter that
-- keeps a code row's indentation, the argument summariser the rest of the transcript uses, and the
-- JSON the model was given - so the block reads the same wherever it is drawn.
function METHODS:codemode_opts()
  return {
    live = self.live,
    paint = paint,
    clip = fit,
    columns = columns,
    -- The code band's rest-of-row: the band colour, then EL, so a painted row holds no trailing
    -- spaces for a narrow terminal to re-wrap (item F).
    band_erase = function() return STYLE.codeBand .. "\27[K" end,
    -- The host CUTS a script row at the width it draws at, so the block follows the window (Victor
    -- 22/11): the row is written whole, with the band's fill in its marker, and transcript.rs cuts it
    -- per frame. Only where there is a transcript to cut it - a log keeps the rows Lua cut.
    reflow = self:transcript(),
    summarise = function(name, args) return M.call_line(name, args, 32) end,
    elapsed = function(ms) return M.elapsed(ms) end,
    encode = function(value) return json.encode(value) end,
    syntax = markdown.scan_code,
    -- The host can fold a long result to one row that opens on a click (host.transcript_expand).
    expandable = self:transcript() and host and type(host.transcript_expand) == "function" or false,
  }
end

-- The running block, made to match its model: the heading (the tools it has called so far, and its
-- clock once it has one) and one row per inner call, each rewritten in place as the call starts and
-- settles. Rows only ever grow - a call appears once - so nothing is ever removed, and that is what
-- lets the block stream instead of being redrawn.
function METHODS:codemode_sync()
  local model = self.code
  if not model then return end
  -- THE LIVE ROW IS TAKEN DOWN BEFORE THE BLOCK GROWS (Victor 21/11: the scrollbar split in two
  -- while a call waited, one bar for the block and a stub of it beside the waiting row). The host
  -- keeps a live row of its own UNDER the transcript for the call in flight and rewrites it in
  -- place; a block that gains a row (a call's output, a second call) moves that row without telling
  -- the host, and the live row's next redraw lands on a row of the block - the row it lands on loses
  -- its last column, which is where the bar is drawn. Cleared here, the rows this writes are the
  -- newest rows of the transcript and the bar is drawn on every one of them, which is what a reader
  -- scrolling during the wait is looking at.
  if self.pending and self.pending.block then self:tool_live("") end
  local o = self:codemode_opts()
  local rows = codemode_block.call_lines(model, self.limit, o)
  local old = self.code_rows or 0
  if self:transcript() and host.transcript_rewrite then
    -- A settled call's row opens on a click to what the call said (`rows.expand`): the marker is
    -- handed to the host just before the row it belongs to, written or rewritten.
    local function mark(index)
      local full = rows.expand and rows.expand[index]
      if full and host.transcript_expand then
        pcall(host.transcript_expand, json.encode({ { at = 0, text = full } }))
      end
    end
    for index = 1, math.min(old, #rows) do
      mark(index)
      pcall(host.transcript_rewrite, index - old - 1, rows[index])
    end
    for index = old + 1, #rows do mark(index); self:write(rows[index] .. "\n") end
  end
  self.code_rows = #rows
end

-- A code-mode call starting. The block before it collapses to its summary line - the one that is
-- running is the one that is open (operator, 13/11) - and this one opens expanded, with its script.
-- In the plain layout (a captured run) nothing is drawn until the answer is in: a log cannot take a
-- row back, and a `⏳` that never flips is worse than no row.
function METHODS:codemode_start(event)
  -- The block before it stays open, whole (operator 17/11: "each step shows its output completely,
  -- no more eliding"); it used to fold to its one-row summary here.
  self.code_done = nil
  self.code = codemode_block.new(event.arguments, self.now())
  self.code_rows = 0
  if not self:transcript() then return end
  -- A code-mode block, not an ordinary topic: it is drawn expanded while it is the newest one and
  -- folds to the summary a newer block leaves it with.
  -- No topic row either: the block has no title, so the plain path starts with the code. The host's
  -- block marker is still asked for (it is what lets a newer block fold this one).
  -- One blank line above the block, written into the block before it (a code block is a topic, and a
  -- topic's own trailing blank rows are not drawn).
  self.pending.block, self.pending.shown = true, true
  local o = self:codemode_opts()
  if self.code_streamed then
    -- The script streamed into its block already (code_stream, or run_code_piece for the native `run`
    -- tool): only the call rows follow, after the last line the model finished writing.
    self.code_streamed = nil
    self:run_code_flush()
    -- What streamed may be less than the script (or not the script at all): the call's own arguments
    -- are the truth, and the block's rows are made to be exactly them.
    self:run_code_settle_block(event.arguments and event.arguments.code)
  else
    self:flow_end()
    self:gap(1)
    if host.transcript_block then pcall(host.transcript_block, true, true) end
    for _, row in ipairs(codemode_block.rows(self.code, self.limit, o)) do self:write(row .. "\n") end
  end
  -- No live progress row inside a code block (operator 17/11: "it wages up and down all the cli content ...
  -- and breaks the right scroll"): that row was taken away and put back around every inner call's row,
  -- moving everything under it. The block's own call rows already say ⏳/✓/✗ in place.
end

-- The script's answer: the value under the calls, the heading rewritten with the call's whole time,
-- and the block remembered as the one a newer block collapses.
function METHODS:codemode_settle(event)
  local pending = self.pending
  local ms = pending and ((self.now() - pending.started) * 1000) or nil
  local model = self.code or codemode_block.new(pending and pending.arguments or {}, self.now())
  codemode_block.finish(model, event.result, ms and (ms / 1000) or nil)
  self.code, self.code_done = model, model
  local o = self:codemode_opts()
  if self:transcript() then
    self:codemode_sync()
    -- The copy icon on the block's first row (operator 17/11 "a copy icon on its top"): the script is
    -- whole only now, so the marker is set here, on the block's first line, never on a later write.
    local a = model.args or {}
    local script = (type(a.code) == "string" and a.code) or (type(a.script) == "string" and a.script) or nil
    if script and script ~= "" and host.transcript_copy_first then pcall(host.transcript_copy_first, script) end
    local tail = codemode_block.tail_rows(model, self.limit, o)
    for index, row in ipairs(tail) do
      local full = tail.expand and tail.expand[index]
      if full then pcall(host.transcript_expand, json.encode({ { at = 0, text = full } })) end
      self:write(row .. "\n")
    end
    -- No heading row on settle either: the block has no title, so there is nothing above the code for
    -- the host to rewrite (this was the last place the modality word reached the transcript).
    self:topic(false)
    self:write("\n")
  else
    for _, row in ipairs(codemode_block.lines(model, self.limit, o)) do self:line(row) end
  end
  self.pending = nil
  if event.quiet then return end
  self.phase = "Thinking"
  self:paint(true)
end

-- Markdown rendered into the transcript, with the copy affordance on each of its fenced blocks
-- (#114). The markers have to reach the host immediately before the write that draws them: the host
-- marks lines of the NEXT write, so a marker that met another write would land on the wrong row.
function METHODS:markdown(text, options)
  local rendered, copies = markdown.render(text, options)
  if rendered ~= "" and copies and #copies > 0 and self:transcript() and host.transcript_copy then
    pcall(host.transcript_copy, json.encode(copies))
  end
  return rendered
end

-- The call's heading rewritten once its result is in, so that row's dot can say how it went.
function METHODS:tool_head(text)
  if not (self:transcript() and host and host.transcript_head) then return end
  pcall(host.transcript_head, tostring(text or ""))
end

-- A call whose result never arrived (a second call started, or the run ended) still gets its
-- heading, with a neutral dot: what was asked must not vanish from the transcript. A call whose block
-- was opened when it started already has that heading; its live line is taken down here, because the
-- facts behind it are gone.
function METHODS:flush_call()
  local pending = self.pending
  if not pending then return end
  -- Its block was opened when it started: the heading is already there, and what has to go is the
  -- live row under it - the facts behind it belong to a call that is no longer in flight.
  if pending.block then self:tool_live("") return end
  if pending.shown then return end
  pending.shown = true
  self:topic(true)
  self:line(paint(DOT, "muted", self.live) .. " " .. self:call_heading(pending.label, pending.inside))
  self:topic(false)
end

function METHODS:call_heading(label, inside)
  return paint(label or "?", "bold", self.live) .. ((inside and inside ~= "") and ("(" .. inside .. ")") or "")
end

-- `⏺ ` in front of the first line of a block: the answer's bullet.
local function bulletize(text, mark)
  local lead = text:match("^[\r\n]*") or ""
  local rest = text:sub(#lead + 1)
  local codes = ""
  while true do
    local code = rest:match("^\27%[[%d;]*m")
    if not code then break end
    codes = codes .. code
    rest = rest:sub(#code + 1)
  end
  return lead .. codes .. mark .. " " .. rest
end
M.bulletize = bulletize

-- The answer, then the numbers for the run that produced it. A reply that already
-- streamed (a peer or a window run reaching this printer) is not printed twice.
function METHODS:answered(reply)
  -- When the last answer arrived: the one clock that says whether the next request starts from a
  -- provider's warm cache or from a cold one (change/esc-stops-now, item 5).
  self.last_answer_at = self.now()
  self:model_spoke()
  self:delta_reset(true)
  self:flow_end()
  self:commentary_flush()
  self:clear()
  if self.deltas == 0 and reply and tostring(reply) ~= "" then
    -- After a page of tool lines the answer has to be findable, and the reader's eye is
    -- what has to find it.
    self:flush_call()
    self:topic(false)
    if self.turn and (self.turn.tools or 0) > 0 then self:write("\n") end
    local text = tostring(reply)
    -- Markdown, because that is what the model wrote: a heading is a heading, a fence is a
    -- block, and the width is the terminal's rather than the line's.
    local rendered = self:markdown(text, {
      paint = function(plain, style) return paint(plain, style, self.live) end,
      width = self.limit - 2,
      indent = "", reflow = self:transcript(),
    })
    -- The renderer is the nicer rendering, never the only one: a reply it produces nothing
    -- for is printed raw. A view that swallowed an answer because its parser did not
    -- recognise it would be the worst bug in this file.
    if rendered ~= "" then text = rendered end
    text = bulletize(text, paint(DOT, "text", self.live))
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    self:write(text .. "\n")
  end
  -- The run ended WELL, so the row it leaves behind carries the check and the time it ended (item
  -- B). The moment is taken here, once, and not inside run_numbers, which is also called every
  -- frame while the run is in flight and has no end to name.
  self:run_finished({ ok = true, at = self.now() })
end

function METHODS:failed(problem, opts)
  opts = opts or {}
  local cancelled = tostring(problem or ""):find("run_cancelled", 1, true) ~= nil
  if cancelled then
    -- WHAT ALREADY STREAMED STAYS (change/esc-stops-now, item 2). A stop used to run straight into
    -- clear(), which throws the half-written answer away: a reader who interrupted a long reply lost
    -- the words they had already read on screen. The text is written as it arrived, and the one line
    -- that says why it ended follows it.
    self:delta_reset()
    self:flow_end()
    self:commentary_flush()
  end
  self:clear()
  self:flush_call()
  -- An interrupt (Esc, Ctrl+C) is the reader's own choice, not an error: say so plainly, in ONE line, and
  -- name the wake when the run was one (a self-wake is a promise the session made itself, and a reader who
  -- stops it should see which promise they stopped). No `run_failed`, and `run_cancelled` never appears:
  -- the code is the harness's word, and this line is the reader's.
  if tostring(problem or ""):find("run_cancelled", 1, true) then
    self:topic(false)
    local text = RESULT .. " Interrupted by user" .. (opts.self_wake and " (self-wake)" or "")
    self:line(paint(text, "warning", self.live))
    self:run_finished()
    return
  end
  self:line(paint(DOT .. " Error: " .. tostring(problem or "error"), "red", self.live))
  -- A failed run keeps the same row WITHOUT the check: the absence is the failure, and a second
  -- shape for it would be a second row to read (item B).
  self:run_finished({ ok = false })
end

-- A bug in this renderer must not kill the run it is describing: the transcript belongs
-- to the node, not to the view. Say so once, visibly, and let the run continue - a view
-- that silently swallowed its own failure would be the same defect it exists to remove.
function METHODS:warn(problem)
  if self.warned then return end
  self.warned = true
  self:clear()
  self:line(paint("! the run view failed: " .. tostring(problem), "red", self.live))
end

-- What the model thought before it acted. A CLI run has no SSE sink, so nothing else in this
-- process can show it: the reasoning is in the transcript, and until now it was only there.
-- pi gives it its own colour and so does this.
--
-- It is not folded. The reason to show reasoning is to read it, and a view that summarised it
-- would be the thing it exists to fix; `WASM_AGENT_CLI_THINKING=off` is how a reader who does
-- not want it turns it off. Nothing else hides it, and nothing here shortens it.
-- The heading is grey like commentary's (a label, not content) and italic; the body is blue.
function METHODS:reasoning_block(text)
  if (host.getenv("WASM_AGENT_CLI_THINKING") or ""):lower() == "off" then return end
  self:flow("think", text)
  self:flow_end()
end

-- What the model told the reader on the way, before or between tool calls ("I'll read the config
-- first"). The UI draws it as its own topic, `✦ commentary`, beside thinking (ui/components.js,
-- TOPIC_KINDS): the same block with another glyph and label. Here too: same block as thinking, but
-- it is said *to* the reader, so it is printed in white (`commentaryText`), not thinking's blue.
-- It is not the answer and is never counted as one.
function METHODS:commentary_block(text)
  self:topic_block(SPARKLE .. " Commentary", { "bold", "muted" }, text, "commentaryText")
end

-- Commentary streamed in chunks (a host that streams) is gathered per item and printed once, when
-- its item closes - a block drawn chunk by chunk would interleave with the status line.
function METHODS:commentary_piece(event)
  local id = tostring(event.pending_id or event.message_id or "")
  self.commentary_open = self.commentary_open or {}
  self.commentary_open[id] = (self.commentary_open[id] or "") .. tostring(event.text or "")
end

function METHODS:commentary_flush()
  local open = self.commentary_open
  self.commentary_open = nil
  if not open then return end
  local ids = {}
  for id in pairs(open) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do self:commentary_block(open[id]) end
end

-- One block for thinking and commentary: a heading, the Markdown body, an empty line after.
function METHODS:topic_block(heading, heading_style, text, body_style)
  local body = tostring(text or "")
  if body:gsub("%s", "") == "" then return end
  self:clear()
  self:topic(true)
  self:write(paint(heading, heading_style, self.live) .. "\n")
  self:write(self:markdown(body, {
    paint = function(plain, style) return paint(plain, style, self.live) end,
    -- Two columns narrower: a focused topic is drawn inside a border, and text wrapped here must
    -- not be wrapped a second time there.
    width = self:transcript() and (self.limit - 2) or self.limit,
    indent = "", reflow = self:transcript(),
    style = body_style,
  }) .. "\n")
  self:topic(false)
  self:write("\n")
  self:paint(true)
end

-- ---- the console ------------------------------------------------------------------

-- Every event as it arrived, and a tool's output as it came back. The formatted view answers
-- "what is it doing"; this answers "what actually happened", which is the question a one-line
-- summary cannot. It is a toggle (`/console`) rather than the default because it is a
-- firehose: nothing here is clipped, folded or summarised.
function METHODS:set_console(on)
  self.console = on and true or false
  if self.console then self:unanimate() end
  return self.console
end

function METHODS:console_on()
  return self.console and true or false
end

function METHODS:console_event(event)
  local kind = tostring(event.type or "?")
  local since = self.turn and self.turn.started or self.now()
  local head = paint(M.duration(math.max(0, self.now() - since)), "dim", self.live)
    .. " " .. paint(kind, "accent", self.live)
  self:clear()
  if kind == "tool_result" then
    local result = type(event.result) == "table" and event.result or { value = event.result }
    self:write(head .. " " .. tostring(event.name or "?") .. "\n")
    local shown = false
    -- The tool's own words, whole: this is the view a reader turns on precisely because the
    -- two-line summary cut something off.
    for _, key in ipairs({ "stdout", "stderr", "error" }) do
      local text = result[key]
      if type(text) == "string" and text ~= "" then
        shown = true
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          self:write(line .. "\n")
        end
      end
    end
    if not shown then
      for line in (json.encode(result) .. "\n"):gmatch("([^\n]*)\n") do
        self:write(line .. "\n")
      end
    end
  else
    self:write(head .. " " .. json.encode(event) .. "\n")
  end
end

function METHODS:event(event)
  local kind = event.type
  if self.console then
    -- The console is what draws, but the numbers are still kept: switching it off mid-run
    -- must not leave the footer counting a run it never saw.
    if kind == "usage" then
      self.totals = event.total or self.totals
      self.context = tonumber(event.prompt) or self.context
    end
    return self:console_event(event)
  end
  if kind == "status" then
    local text = tostring(event.text or "")
    if text == "thinking" or text == "model" then
      self:model_waiting()
      self.phase = "Thinking"
      self.pending = nil
      self:paint()
    elseif text ~= "" then
      -- Compaction, recovery, a guard, a storage failure: not a phase, and worth a line
      -- of its own - these are exactly the events that used to be invisible here.
      --
      -- Item 8: a notice is never GLUED onto other text. A done-gate notice arrives at a
      -- turn end, while the candidate answer is still a partial line held in the stream
      -- buffer (say_buf): drawn where it arrived, the notice came out ABOVE the sentence it
      -- was interrupting and with that sentence reordered after it (measured 19/11: the
      -- answer row held "and more" while the notice and the rest of the sentence followed).
      -- So the text the notice interrupted is written first, as it stands, and the notice
      -- then takes a row of its own - after the text, never inside it.
      local saying = self.flow_kind == "say"
      self:flow_end()
      self:line(paint("! " .. M.clip(text, self.limit), "yellow", self.live))
      -- The answer the notice interrupted is not over: the rest of it continues on the next
      -- row, as the same paragraph rather than a new one (no blank line, no second gap).
      if saying then self.flow_kind, self.flow_held = "say", 0 end
    end
  elseif kind == "round" then
    local previous = self.round
    self.round = tonumber(event.n) or (self.round + 1)
    self.total_rounds = self.total_rounds + math.max(0, self.round - previous)
    if self.turn then self.turn.rounds = self.round; self.turn.step_started = self.now() end
    -- A round boundary is a new model call: the wait starts again.
    self:model_waiting()
    self:paint()
  elseif kind == "run_code_delta" then
    -- The model writing the `run` tool's script, as it writes it (lua/core/run_stream.lua decodes the
    -- argument fragments; this one draws them). The old raw channel drew the model's own code in real
    -- time and the operator wants that back: the script opens its block on the first piece and each
    -- complete line lands on the band as it arrives, so the call event that follows finds the block on
    -- screen and adds only its rows.
    self:run_code_piece(event)
  elseif kind == "tool" then
    self:model_spoke()
    self:delta_reset()
    self:flow_end()
    -- The heading is printed when the result arrives, so its dot can say how it went (green or
    -- red, as Claude Code does); until then the status line names the call.
    self:commentary_flush()
    self:flush_call()
    local label, inside = M.tool_title(event.name, event.arguments, self.limit - 4)
    self.pending = { name = event.name or "?", started = self.now(), label = label, inside = inside,
      arguments = event.arguments }
    -- A call that outlasts a couple of seconds says what it is doing **inside its own block**: the
    -- heading now, and the progress line under it, rewritten in place while the call runs
    -- (docs/TOOL-PROGRESS.md, Victor 2026-11-10). The block has to exist while the call is in flight,
    -- which is why the heading is printed here and not with the result; only the host's transcript can
    -- hold a row its ticker rewrites while this process is blocked, so the plain layout keeps the old
    -- order (heading with the result) and prints no live line.
    -- A code-mode call opens with its code, not with a heading row: `progress("begin")` prints the
    -- label, which is what put a title above the block.
    if not is_codemode(event.name, event.arguments) then self:progress("begin", event.name or "tool") end
    if is_codemode(event.name, event.arguments) then
      -- The heading is `⏺ CodeAct · <the tools it calls>`: the modality is named (CodeAct: the model
      -- acts by writing code), the tools say what the script did, and the script itself is never the
      -- heading (#121 put its first line in
      -- the parentheses, so the heading was a second copy of the body).
      self.pending.label, self.pending.inside = "CodeAct", ""
      -- A run block is dispatched as a codemode call (one pathway), and the status line used to say
      -- "Working: codemode" for both. `call_raw_...` is the id the raw channel mints, so the reader is
      -- told what is happening: the model's own script is running.
      -- ONE transport (Victor 21/11): the model's own script is the `run` call, and the status row says
      -- so ("Running your script") instead of naming a tool.
      self.pending.raw = event.name == "run"
      self:codemode_start(event)
    elseif self:transcript() then
      self:topic(true)
      self.pending.block, self.pending.shown = true, true
      self:line(paint(DOT, "muted", self.live) .. " " .. self:call_heading(label, inside))
      -- A code-mode call's script, under its heading: three rows, the rest folded (#121).
      self:code_block(self.pending.name, event.arguments, 3, false)
      local live = self:tool_line()
      if live then self:tool_live(live.text) end
    end
    if event.timeout_ms then self.pending.bound = tonumber(event.timeout_ms) / 1000 end
    -- `quiet`: a `!command` the reader ran outside any run (lua/core/bash_mode.lua) - drawn like a
    -- tool, but with no run there is no status line to name it on, and none must be started.
    if event.quiet then return end
    -- A routed call is phrased as the tool that runs (`Running bash`), not as `tool_call`.
    self.phase = self.pending.raw and "Running your script"
      or M.phase((M.target(self.pending.name, event.arguments)))
    if self.turn then self.turn.tools = self.turn.tools + 1 end
    self.session_tools = (self.session_tools or 0) + 1
    self:paint(true)
    self:live_footer()
-- A recorded file change, drawn as its own block (Victor 20/11). It arrives as an event of its
-- own, after the call's result: the change is the run's record (lua/core/changeset.lua), not part
-- of what the tool returned, so the model's context never carries a line of it.
  elseif kind == "bash_changes" then
    -- What the command changed, as its own block: the result above it is the tool's own output.
    local lines = M.bash_changes_block(event, self.limit, self.live)
    if lines then
      self:topic(true)
      for _, text in ipairs(lines) do self:write(text .. "\n") end
      self:write("\n")
      self:topic(false)
    end
    return  elseif kind == "change" then
    local lines, why = M.diff_block(event, self.limit, self.live)
    if lines then
      self:topic(true)
      for _, text in ipairs(lines) do self:write(text .. "\n") end
      self:write("\n")
      self:topic(false)
    elseif why ~= "no_change" then
      self:line(paint("\226\142\191 no diff shown: " .. tostring(why), "dim", self.live))
    end
    return  elseif kind == "remote_change" then
    -- A create/edit that ran on ANOTHER node (lua/core/tools.lua, the remote branch). When the peer's
    -- answer carried the two texts (mission remote-edit-first-class puts them on the wire), this is the
    -- SAME card a local write draws - path, counts, numbered rows - from the peer's own before/after.
    -- When it did not, the reader gets one honest row saying what ran where, never silence.
    if type(event.before_text) == "string" and type(event.after_text) == "string" and event.ok ~= false then
      local lines = M.diff_block({ path = event.path, before_text = event.before_text,
        after_text = event.after_text }, self.limit, self.live)
      if lines then
        self:topic(true)
        for _, row in ipairs(lines) do self:write(row .. "\n") end
        self:write("on " .. tostring(event.node) .. "\n\n")
        self:topic(false)
        return
      end
    end
    local wrote = event.ok == false and "could not write " or "wrote "
    local text = wrote .. tostring(event.path) .. " on " .. tostring(event.node)
    if event.ok == false then text = text .. ": " .. tostring(event.error or "refused") end
    self:topic(true)
    self:line(paint(text, event.ok == false and "error" or "dim", self.live))
    self:write("\n")
    self:topic(false)
    return  elseif kind == "tool_result" then
    self:progress("finish")
    local name = event.name or (self.pending and self.pending.name) or "?"
    -- A code-mode block owns its whole result: the value the script returned, the call rows flipped
    -- in place, and the heading's clock. Nothing of the generic result path applies to it.
    if is_codemode(name, self.pending and self.pending.arguments) then return self:codemode_settle(event) end
    local ms = self.pending and ((self.now() - self.pending.started) * 1000) or nil
    local pending = self.pending
    -- A call whose block was opened when it started keeps its own heading, its arguments and its
    -- block: only an announcement that was never printed (or one for another tool) is rebuilt here.
    if not pending or (pending.shown and not pending.block) or pending.name ~= name then
      local label = M.tool_title(name, nil, self.limit - 4)
      pending = { label = label, inside = "" }
    end
    local ok, note = M.outcome(name, event.result, pending.arguments)
    -- The heading is already on screen when the block was opened as the call started: rewrite it in
    -- place (its dot says how it went, green or red as Claude Code does) instead of printing a second
    -- one, and let the first real write take the live progress line down - the result is what the row
    -- under the heading says now.
    if pending.block then
      self:tool_head(paint(DOT, ok and "success" or "error", self.live) .. " " .. self:call_heading(pending.label, pending.inside))
    else
      self:topic(true)
      self:line(paint(DOT, ok and "success" or "error", self.live) .. " " .. self:call_heading(pending.label, pending.inside))
    end
    -- The script of a code-mode call, where the block was not opened when the call started (the plain
    -- layout, and a transcript with no live row): the heading is on screen now, the script goes under
    -- it, and the result follows (#121).
    if not pending.block then self:code_block(name, pending.arguments, 3, true) end
    -- In the transcript a tool call is a topic that folds to three rows, so it keeps more of the
    -- output for when it is expanded.
    local preview, hidden = M.preview(name, event.result, self:transcript() and 200 or 3, pending.arguments)
    local facts = {}
    if note ~= "" then facts[#facts + 1] = note end
    if ms then facts[#facts + 1] = M.elapsed(ms) end
    local summary = table.concat(facts, " \194\183 ")
    local lead = paint(RESULT, "muted", self.live) .. " "
    if #preview == 0 then
      self:write(lead .. paint(summary ~= "" and summary or (ok and "done" or "failed"), ok and "dim" or "error", self.live) .. "\n")
    else
      for index, text in ipairs(preview) do
        -- A diff line reads as a diff: added, removed, context.
        local style = ok and "dim" or "error"
        if text:sub(1, 1) == "+" then style = "toolDiffAdded"
        elseif text:sub(1, 1) == "-" then style = "toolDiffRemoved"
        elseif text:sub(1, 2) == "@@" then style = "toolDiffContext" end
        self:write((index == 1 and lead or "") .. paint(M.clip(text, self.limit - 2), style, self.live) .. "\n")
      end
      if hidden > 0 then
        self:write(paint("\226\128\166 +" .. hidden .. " lines (/console shows all)", "dim", self.live) .. "\n")
      end
      if summary ~= "" then self:write(paint(summary, ok and "dim" or "error", self.live) .. "\n") end
    end
    self:topic(false)
    -- One empty line after the call, as after a thinking block, so steps do not run together.
    self:write("\n")
    self.pending = nil
    if event.quiet then return end
    self.phase = "Thinking"
    self:paint(true)
  elseif kind == "codemode_call" then
    -- One inner call of the script that is running: it appears as it starts (`⏳`), and its own row
    -- is rewritten in place when it settles (`✓`/`✗`) - inside the block that is already open.
    -- The native transport also announces the run CALL ITSELF this way, and that row is the
    -- collapsed presentation this change removes: the script block already IS that call, so the
    -- wrapper is not drawn (a fenced run block emits no such row; the two must look the same).
    if event.name == "run" then return end
    local model = self.code
    if model then
      local id = event.id or event.call_id
      if event.state == "running" then
        codemode_block.begin_call(model, id, event.name, event.arguments)
      elseif event.state == "pending" then
        codemode_block.pending(model, id, event.op)
      else
        codemode_block.settle(model, id, { ok = event.ok ~= false, ms = event.ms, error = event.error,
          code = event.code, output = event.output })
      end
      self:codemode_sync()
      if self.pending then self:paint() end
    end
  elseif kind == "reasoning" then
    -- Settled thinking: already on screen if it streamed; otherwise written now, the same way.
    -- It also closes the step's text: what is still held (a last line with no newline) is written now.
    if self.reasoning_streamed then self.reasoning_streamed = nil
    else self:reasoning_block(event.text) end
    self:flow_flush()
  elseif kind == "commentary" then
    self:commentary_flush()
    self:commentary_block(event.text)
  elseif kind == "commentary_delta" then
    self:commentary_piece(event)
  elseif kind == "commentary_end" then
    self:commentary_flush()
  elseif kind == "step_phase" then
    self:flow_flush()
    -- A chat-completions provider (DeepSeek, OpenCode) carries the step's commentary as the
    -- `content` beside its tool calls; agent.lua classifies it and sends it here as `step_phase`,
    -- not as `commentary`. A CLI run has no delta sink, so unless a peer already streamed it
    -- (`deltas`), this is the only place that sentence can reach the reader.
    if event.phase == "commentary" and self.deltas == 0 then
      self:commentary_flush()
      self:commentary_block(event.text)
    end
  elseif kind == "usage" then
    self:model_spoke()
    self.totals = event.total or self.totals
    -- The context in use is the last model call's prompt, measured by the provider;
    -- `total.prompt` is the session's running sum and would grow without bound.
    self.context = tonumber(event.prompt) or self.context
    self:paint()
    self:live_footer()
  elseif kind == "compact" then
    self:line(paint("! compacted through seq " .. tostring(event.through or "?"), "dim", self.live))
  elseif kind == "delta" then
    -- The answer, as it arrives. A CLI run used to have no sink, so this never fired and the text
    -- appeared whole when the step settled; the host now forwards the provider's deltas here.
    -- The provider spoke: the wait for its first byte is over.
    self:model_spoke()
    self.deltas = self.deltas + 1
    self:delta_piece(event.text or "")
  elseif kind == "reasoning_delta" then
    -- Thinking, as it arrives: `✻ ` and the thought in gray on the same line, no title (operator 17/11).
    -- A thought is the provider speaking too, which ends the wait for its first byte.
    self:model_spoke()
    self.reasoning_streamed = true
    if (host.getenv("WASM_AGENT_CLI_THINKING") or ""):lower() ~= "off" then self:flow("think", event.text) end
  elseif kind == "error" then
    self:clear()
    self:line(paint("! " .. tostring(event.error or "error"), "red", self.live))
  end
end

-- `wa --continue` / `wa --resume <id>`: the stored transcript drawn again, through the same
-- methods a live run uses, so a continued thread looks the way it did when the window was closed:
-- the reader's turns, thinking, commentary, each tool call with its result, and the answers.
-- `rows` are `memory.session_messages` rows in seq order. Tool results were redacted before they
-- were stored; user text and reasoning go through `redact` here, as the live printer does.
-- Nothing is sent anywhere and nothing is written: this only draws.
function METHODS:replay(rows, opts)
  opts = opts or {}
  local json = dofile("lua/vendor/json.lua")
  local redact = dofile("lua/core/redact.lua")
  local function text_of(value) return redact.text(tostring(value or "")) end
  if opts.skipped and opts.skipped > 0 then
    self:line(paint("\226\128\166 " .. opts.skipped .. " earlier messages not shown (wa conversation / the window has them)", "dim", self.live))
    self:line("")
  end
  local names = {}
  for _, row in ipairs(rows or {}) do
    local role = row.role
    if role == "summary" then
      self:topic_block(STAR .. " Summary of earlier turns", { "italic", "muted" }, text_of(row.content), "dim")
    elseif role == "user" and row.phase == "bash" and dofile("lua/core/bash_mode.lua").parse(row.content) then
      -- A `!command` the reader ran: drawn as it was, the line and then its output.
      local command, stdout, stderr = dofile("lua/core/bash_mode.lua").parse(text_of(row.content))
      if self.screen then self:accepted("!" .. command) else self:line("!" .. command) end
      self:flush_call()
      local label, inside = M.tool_title("bash", { command = command }, self.limit - 4)
      self.pending = { name = "bash", started = self.now(), label = label, inside = inside, arguments = { command = command } }
      self:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = stdout, stderr = stderr }, quiet = true })
    elseif role == "user" then
      local text = text_of(row.content)
      if self.screen then self:accepted(text)
      else self:line(PROMPT .. text); self:line("") end
    elseif role == "assistant" then
      if (row.reasoning or "") ~= "" then self:reasoning_block(text_of(row.reasoning)) end
      local ok, calls = pcall(json.decode, row.tool_calls or "[]")
      calls = (ok and type(calls) == "table") and calls or {}
      local content = tostring(row.content or "")
      if #calls > 0 or row.phase == "commentary" then
        if content ~= "" then self:commentary_block(text_of(content)) end
      elseif content ~= "" then
        local rendered = self:markdown(text_of(content), {
          paint = function(plain, style) return paint(plain, style, self.live) end,
          width = self.limit - 2, indent = "", reflow = self:transcript(),
        })
        if rendered == "" then rendered = text_of(content) end
        rendered = bulletize(rendered, paint(DOT, "text", self.live))
        if rendered:sub(-1) ~= "\n" then rendered = rendered .. "\n" end
        self:topic(false)
        self:write(rendered .. "\n")
      end
      for _, call in ipairs(calls) do
        local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or {}
        local decoded, args = pcall(json.decode, fn.arguments or "{}")
        args = (decoded and type(args) == "table") and args or {}
        names[tostring(call.id or "")] = fn.name
        self:flush_call()
        local label, inside = M.tool_title(fn.name, args, self.limit - 4)
        self.pending = { name = fn.name or "?", started = self.now(), label = label, inside = inside, arguments = args }
      end
    elseif role == "tool" then
      local name = (row.tool_name ~= "" and row.tool_name) or names[tostring(row.tool_call_id or "")] or "?"
      -- The heading belongs to this result's own call, which may not be the last one announced.
      local pending = self.pending
      if not pending or pending.name ~= name then
        self:flush_call()
        local label = M.tool_title(name, nil, self.limit - 4)
        self.pending = { name = name, label = label, inside = "" }
      end
      self.pending.started = self.now() - (tonumber(row.ms) or 0) / 1000
      local decoded, result = pcall(json.decode, row.content or "")
      if not decoded or result == nil then result = tostring(row.content or "") end
      if row.ok == 0 and type(result) == "table" and result.ok == nil and result.error == nil then result.ok = false end
      -- The live path, quiet: a replay is not a run, so no status line is started for it.
      self:event({ type = "tool_result", name = name, result = result, quiet = true })
    end
  end
  self:flush_call()
  self.pending, self.phase = nil, ""
  if opts.rule == false then return end
  self:line(paint(string.rep("\226\148\128", 3) .. " continued here " .. string.rep("\226\148\128", 3), "dim", self.live))
  self:line("")
end

-- The model line of the welcome box: the model, its endpoint, and - when the provider states one - the
-- reasoning level, separated by a dot with ONE space on each side (Victor, 22/11: it had two). Composed
-- here, beside the box that draws it, so the one separator has one spelling and a test can say so.
function M.model_line(mode, reasoning)
  local text = tostring(mode or "")
  if reasoning and reasoning ~= "" then text = text .. " \194\183 reasoning " .. tostring(reasoning) end
  return text
end

-- The welcome box: where this is running and what it is running with, the way Claude Code opens.
-- The workspace and branch come first after the greeting - a chat in the wrong worktree is a
-- mistake that costs an hour to notice otherwise.
--
-- `opts.marker` leaves the rule as M.RULE for a writer that knows the width at DRAW time - the host's
-- transcript expands it per frame (rust/wa-term/src/transcript.rs `expand_rule`), which is what lets a
-- resized window draw the banner again at its own width instead of re-wrapping the row the old width
-- left behind (item 1 of tui-fit, Victor 21/11). Without it the rule is expanded here, which is right
-- for a writer that writes once (a pipe, a captured transcript).
function M.banner(opts)
  opts = opts or {}
  local live = opts.live
  local limit = math.max(24, tonumber(opts.limit) or 80)
  local function fit(text) return columns(text) <= limit and text or clip(text, limit) end
  local function fact(label, value)
    if value and value ~= "" then return paint(fit(label .. ": " .. value), "muted", live) end
  end
  -- The rule, expanded from the marker at the width this banner is drawn at (M.expand_rules), or kept
  -- as the marker: no component here spells the rule character itself, so a width fixed at composition
  -- time cannot hide in the banner (round 4, item 1).
  local divider = paint(opts.marker and M.RULE or M.expand_rules(M.RULE, limit), "border", live)
  -- THE TWO FACTS ON ONE LINE (Victor, 22/11: "make v0.1.0 be reflected into the entrance; v1.0 is wrong ...
  -- the welcome line shows it: 'x Welcome to wasm-agent! v0.1.0 - v<sha>'"). The product version says which
  -- release a person is running; the label beside it says WHICH BYTES, because a version alone was the 18/11
  -- lie. Each half is printed only when it is known - `unknown` and `unknown build` are left out rather than
  -- shown as a word - so an older binary reads `Welcome to wasm-agent! v<sha>` and never `vunknown`.
  local product = (opts.product and opts.product ~= "" and opts.product ~= "unknown") and opts.product or nil
  local label = (opts.version and opts.version ~= "" and opts.version ~= "unknown build") and opts.version or nil
  local welcome = paint(STAR, "matrix", live) .. " Welcome to " .. paint("wasm-agent", "bold", live) .. "!"
  if product then welcome = welcome .. paint(" v" .. product, "muted", live) end
  -- A commit label is prefixed with `v` (`v6a7f613d`); a release tag (`node-<sha12>`) and a pin already carry
  -- their own word and are printed as they are.
  local function with_v(word)
    if word:sub(1, 1) == "v" or word:sub(1, 5) == "node-" then return word end
    return "v" .. word
  end
  if label then welcome = welcome .. paint((product and " \194\183 " or " ") .. with_v(label), "muted", live) end
  local lines = { divider, welcome,
    "",
    paint(fit("/help for help, /login to sign in to a provider"), "muted", live),
    "" }
  local function add(line) if line then lines[#lines + 1] = line end end
  add(fact("cwd", (opts.workspace or "") .. ((opts.branch and opts.branch ~= "") and (" (" .. opts.branch .. ")") or "")))
  add(fact("model", opts.model or "local mode (no model configured)"))
  add(fact("session", (opts.session or "") .. (opts.continued and " (continued)" or "")))
  add(fact("memory", opts.database))
  if opts.unfinished then
    add("")
    add(paint(fit("! unfinished " .. opts.unfinished), "warning", live))
    add(paint(fit("recovering: wa resume --session " .. tostring(opts.session or "")), "warning", live))
  end
  -- No closing divider: the input's own top divider sits right under the block.
  return table.concat(lines, "\n")
end

-- ---- frames ----------------------------------------------------------------------
--
-- The writes that make one frame: each composes a transcript write with the redraws that belong to
-- it, and each is what the chat's event loop calls. `clear`, `status_draw`, `session_draw` and
-- `write` are parts of a frame rather than frames of their own, and are reached from inside these.
-- Nested calls are harmless (`METHODS:with_frame` is a no-op inside a frame), so this list is "where a
-- frame may begin", not an ordering.
local FRAMED = { "paint", "line", "accepted", "answered", "failed", "warn", "event",
  "console_event", "topic_block", "run_started", "run_finished", "footer_draw", "session_draw",
  "status_draw", "status_blank", "welcome", "note" }
for _, name in ipairs(FRAMED) do
  local inner = METHODS[name]
  assert(inner, "cli view: no method to frame: " .. name)
  -- The frame boundary is also where a reloaded module takes over (docs/HOTRELOAD.md). The order is the
  -- whole of it: the tick runs BEFORE the frame, so the bytes this call draws are the new module's, and
  -- the one line a change or a refusal produces is drawn AFTER it, through the writer this view already
  -- had - a failure's line therefore never lands in the middle of the frame it interrupted.
  METHODS[name] = function(self, ...)
    -- THE FRAME BOUNDARY IS WHERE THE WIDTH IS READ (round 4, item 1). refresh_limit existed and was
    -- called by nothing but its own test, so every component still laid itself out from the width the
    -- view was built with: maximising the terminal left the welcome rule, the code-mode box and the
    -- status bar at the old width (Victor, 18/11). Each framed call is a render, so each reads the
    -- console first and the bytes it writes are laid out for the terminal that exists now.
    self:refresh_limit()
    -- A width change is ACTED ON here, once, rather than wherever the console happened to be read: what
    -- the terminal already holds is at the old width, and only a clear and a redraw from state can put
    -- it right (METHODS:resized). The probe recorded the width it replaced; every later frame sees them
    -- equal and does nothing.
    if self.width_from then
      local previous = self.width_from
      self.width_from = nil
      self:resized(previous)
    end
    local notices = reload.tick(self.now())
    local results = table.pack(self:with_frame(inner, ...))
    for _, notice in ipairs(notices) do
      self:line(paint("  " .. tostring(notice.text), notice.ok and "dim" or "warning", self.live))
    end
    return table.unpack(results, 1, results.n)
  end
end

return M
