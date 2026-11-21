-- The ICON SETS, each one rendered through the view that draws them (item 4 of the wa-fonts mission,
-- Victor 19/11).
--
-- The brief asks for a proof a table lookup cannot give: render each set into the SAME fixture and
-- compare CELL WIDTHS. The wa set is A2 - every icon fills one cell of JetBrains Mono and the value is
-- GLUED - so its row must be exactly as many cells narrower than the nerd row as it has icons, while
-- carrying the same glyphs and the same numbers.
--
-- It fails on the base by construction: the base has no set to choose.
local view_lib = dofile("lua/core/cli_view.lua")
local icons = dofile("lua/core/icons.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end

-- A row measured in CELLS, which is what a terminal charges for it: the icons are the reason this test
-- exists, and counting bytes would hide exactly the defect it looks for.
local function cells(text) return view_lib.columns(tostring(text or "")) end

-- ---- the sets themselves ---------------------------------------------------------
eq(#icons.SETS, 4, "there are four sets: wa, nerd, unicode, ascii")
for _, name in ipairs({ "wa", "nerd", "unicode", "ascii" }) do
  ok(icons.valid(name) == name, name .. " is a set")
end
eq(icons.valid("Wobbly"), nil, "a set nobody offers is refused, not quietly defaulted")
local no_set, unknown_why = icons.set("nope")
ok(no_set == nil and tostring(unknown_why):find("icons_unknown_set", 1, true) ~= nil,
  "an unknown set is refused BY NAME: " .. tostring(unknown_why))

-- Every set draws every icon wa has. A missing cell is a row that cannot compose at all.
local NAMES = { "steps", "clock", "turns", "cache", "check", "ballEmpty", "ballEighth", "ballQuarter",
  "ballThreeEighths", "ballHalf", "ballFiveEighths", "ballThreeQuarters", "ballSevenEighths", "ballFull" }
for _, set_name in ipairs(icons.SETS) do
  local set = icons.set(set_name)
  for _, icon in ipairs(NAMES) do
    ok(type(set[icon]) == "string" and #set[icon] > 0, set_name .. " draws " .. icon)
  end
end

-- THE A2 DECISION, as a test: wa Icons is GLUED (no gap); every other set keeps the one space.
eq(icons.set("wa").gap, "", "wa is glued: the value starts in the icon's own cell")
for _, set_name in ipairs({ "nerd", "unicode", "ascii" }) do
  eq(icons.set(set_name).gap, " ", set_name .. " keeps the one space Victor chose for plain fonts")
end

-- Nine states in every set that has a ball (the brief keeps all nine in wa/nerd/unicode).
for _, set_name in ipairs({ "wa", "nerd", "unicode" }) do
  local drawn = icons.balls(set_name)
  ok(type(drawn) == "table" and #drawn == 9, set_name .. " keeps NINE context states")
end
-- The ladder only goes up as the window fills: a coarser set may repeat a picture (unicode has five
-- circle shapes for nine slots) but it may never step DOWN, which would say the window emptied while
-- it filled.
for _, set_name in ipairs(icons.SETS) do
  local previous = -1
  for index = 1, 9 do
    local fill = icons.fill_of(index)
    ok(fill ~= nil, set_name .. " has a fill for slot " .. index)
    ok((fill or 0) >= previous, set_name .. " slot " .. index .. " is never emptier than the one before it")
    previous = fill or previous
  end
end

-- ---- rendered: the run row, set by set --------------------------------------------
-- ONE fixture, drawn through the view the operator sees, so this is the row and not a table lookup.
local function run_row_at(set_name)
  local used, why = view_lib.use_icons(set_name)
  assert(used, why)
  local view = view_lib.new({ live = true, limit = 120 })
  view.turn = { rounds = 3, context = 7000, started = 0, step_started = 1 }
  view.context = 5300 + 7000
  view.totals = { prompt = 9500, completion = 851 }
  return view:run_numbers("3s", "0:25", { ok = true, at = 1795083600 })
end

for _, set_name in ipairs(icons.SETS) do
  local set = icons.set(set_name)
  local row = run_row_at(set_name)
  ok(row:find(set.steps, 1, true) == 1, set_name .. ": the row OPENS with its own step icon: " .. row)
  ok(row:find(set.clock, 1, true) ~= nil, set_name .. ": the clock is its own: " .. row)
  ok(row:find(set.check, 1, true) ~= nil, set_name .. ": the finish stamp is its own: " .. row)
  -- The value sits where the set says: glued for wa, one space for the rest.
  ok(row:find(set.steps .. set.gap .. "3", 1, true) ~= nil,
    set_name .. ": the step count follows its icon with the set's own gap: " .. row)
end

-- THE WIDTH PROOF. The wa row is the nerd row with each icon's trailing space removed - the same
-- glyphs, the same numbers - so it must be exactly its icon count narrower in CELLS, and strictly
-- narrower (so the measurement is not two zeros agreeing).
local nerd_row, wa_row = run_row_at("nerd"), run_row_at("wa")
-- HOW MANY GAPS THE SPACED ROW ACTUALLY HAS, counted from the row: not every icon is followed by one
-- (the finish stamp is glued to its hour, "mid dot CHECK 18:47"), and a hard-coded 3 would be wrong.
local icons_with_gap = 0
do
  local spaced = icons.set("nerd")
  for _, icon in ipairs({ "steps", "clock", "turns", "cache", "check" }) do
    if nerd_row:find(spaced[icon] .. spaced.gap, 1, true) then icons_with_gap = icons_with_gap + 1 end
  end
end
ok(icons_with_gap > 0, "the spaced row has at least one icon followed by a gap")
eq(cells(wa_row) + icons_with_gap, cells(nerd_row),
  "the glued row is exactly its gapped icons narrower than the spaced one")
ok(cells(wa_row) < cells(nerd_row), "and strictly narrower")
eq(cells(wa_row), view_lib.visible_columns(wa_row), "a plain row's cells are its visible cells")
eq((wa_row:gsub(" ", "")), (nerd_row:gsub(" ", "")), "the two rows differ ONLY by the gaps")

-- ascii spells its rows, so the same facts survive with no glyph font at all.
local ascii_row = run_row_at("ascii")
ok(ascii_row:find("steps", 1, true) ~= nil and ascii_row:find("done", 1, true) ~= nil,
  "the ascii row says what the icons said, in words: " .. ascii_row)
-- unicode survives in a font with no Nerd glyphs at all: every character it draws is Latin-1/BMP
-- punctuation, so a stock terminal shows it.
for _, icon in ipairs(NAMES) do
  for _, char in utf8.codes(icons.set("unicode")[icon]) do
    ok(char <= 0xFFFF, "unicode." .. icon .. " is a BMP character (U+" .. string.format("%04X", char) .. ")")
  end
end

-- ---- rendered: the footer, set by set ---------------------------------------------
for _, set_name in ipairs(icons.SETS) do
  view_lib.use_icons(set_name)
  local set = icons.set(set_name)
  local text = view_lib.session_summary({ runs = 3, prompt = 120400, completion = 1000,
    context = 24400, budget = 200000, cached = 90000 })
  ok(text:find(set.turns, 1, true) ~= nil, set_name .. ": the footer carries its own turns icon")
  ok(text:find(set.cache, 1, true) ~= nil, set_name .. ": and its own cache icon")
  ok(text:find(view_lib.context_ball(12.2), 1, true) ~= nil,
    set_name .. ": and its own context ball at 12.2%: " .. text)
end

-- ---- where the set comes from -----------------------------------------------------
-- An unknown WA_ICONS is NOT adopted: a typo in an environment or a config file must not look like it
-- worked. resolve() reads both, so this drives it the way a node does.
-- THE CONFIG PATH IS RESOLVED BEFORE THE STUB GOES IN, and that is not tidiness: this runtime's dofile
-- reads the file THROUGH host.read_file, so a stub that calls dofile on the way to answering recurses
-- into itself - measured on 21/11 as 399,982 calls and a resolve() that fell through to the default,
-- which looked exactly like "the config file is ignored".
local CONFIG_FILE_PATH = dofile("lua/core/paths.lua").config_file()
local function resolved_with(env_value, config_text)
  local real_getenv, real_read = host.getenv, host.read_file
  host.getenv = function(name)
    if name == "WA_ICONS" then return env_value or "" end
    return real_getenv(name)
  end
  if config_text then
    host.read_file = function(path)
      if tostring(path) == CONFIG_FILE_PATH then return config_text end
      return real_read(path)
    end
  end
  local answer = icons.resolve()
  host.getenv, host.read_file = real_getenv, real_read
  return answer
end
eq(resolved_with("nerd").set, "nerd", "WA_ICONS=nerd is honoured")
eq(resolved_with("nerd").source, "environment WA_ICONS", "and says the environment chose it")
ok(resolved_with("wobbly").set ~= "wobbly", "an unknown WA_ICONS is not adopted as a set")
eq(resolved_with("", "icons = ascii\n").set, "ascii", "the config file's icons = ascii is honoured")
eq(resolved_with("wa", "icons = ascii\n").set, "wa", "the environment beats the config file")
-- The default: the glyphs a stock font has, unless the font setup recorded that it installed ours.
eq(icons.resolve().set == "wa", icons.installed(),
  "wa is the default only when the setup recorded it installed wa Icons")

-- Two readers of one question agree: chat.lua asks icons.resolve, cli_view renders it.
view_lib.use_icons("unicode")
eq(select(1, view_lib.icon_set()), "unicode", "cli_view reports the set it is drawing")

-- Put the process back the way it was found, so a later row in the same interpreter is unaffected.
view_lib.use_icons("nerd")

print(string.format("icons: %s (%d checks, %d failed, 0 skipped)",
  failed == 0 and "ok" or "FAILED", checks, failed))
os.exit(failed == 0 and 0 or 1)
