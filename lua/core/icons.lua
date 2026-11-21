-- wa's ICONS as a SET, chosen once and rendered everywhere (item 4 of the wa-fonts mission,
-- Victor 19/11).
--
-- WHY A SET AND NOT ONE TABLE. wa draws its status and footer icons as Nerd Font (Material Design)
-- glyphs, and a terminal only shows them if its font HAS them. Victor's decision names four sets:
--
--   wa       wa Icons (assets/fonts/waIcons-Regular.ttf): our own A2 glyphs, each filling its cell with
--            a 1 px right margin and centred on the capitals, and the value GLUED - the gap is "".
--   nerd     the same Nerd Font glyphs drawn today, with the ONE space Victor kept - the gap is " ".
--   unicode  glyphs a stock font has (a clock, a refresh arrow, the circle ladder), which need no font
--            installed at all.
--   ascii    plain text: a short word or a bracket, for a terminal with no glyph font and no fallback.
--
-- ONE TABLE, four columns, so a row never picks its own character: the layout asks for an icon BY NAME
-- and the set answers. The alternative - a character literal written into the row - is how the sets
-- come to disagree, and how one set ends up missing a ball.
--
-- WHERE THE SET COMES FROM, in this order: the session's /icons <set>, WA_ICONS, the config file's
--   icons = <set>
-- line, then the default - wa when wa setup fonts has installed wa Icons on this machine, else unicode,
-- because a set whose font is absent is a row of tofu boxes.
local json = dofile("lua/vendor/json.lua")
local M = {}

M.SETS = { "wa", "nerd", "unicode", "ascii" }

-- The nine context balls, in the order M.context_ball indexes them (empty first, full last).
local BALL_NAMES = { "ballEmpty", "ballEighth", "ballQuarter", "ballThreeEighths", "ballHalf",
  "ballFiveEighths", "ballThreeQuarters", "ballSevenEighths", "ballFull" }

-- How full each ball LOOKS, for the one property the four sets must agree on: it never goes down as
-- the window fills. wa and nerd use the real Material Design slices; unicode has only five distinct
-- circle pictures in a stock font, so its nine slots repeat them; ascii spells the fraction out.
M.FILL = {
  ballEmpty = 0, ballEighth = 1, ballQuarter = 2, ballThreeEighths = 3, ballHalf = 4,
  ballFiveEighths = 5, ballThreeQuarters = 6, ballSevenEighths = 7, ballFull = 8,
}

M.TABLE = {
  wa = {
    gap = "",
    steps = "\243\176\183\186",   -- U+F0DFA
    clock = "\243\176\148\155",   -- U+F051B
    turns = "\243\176\145\144",   -- U+F0450
    cache = "\243\176\134\188",   -- U+F01BC
    check = "\243\176\132\172",   -- U+F012C
    ballEmpty = "\243\176\157\166",           -- U+F0766
    ballEighth = "\243\176\170\158",          -- U+F0A9E
    ballQuarter = "\243\176\170\159",         -- U+F0A9F
    ballThreeEighths = "\243\176\170\160",    -- U+F0AA0
    ballHalf = "\243\176\170\161",            -- U+F0AA1
    ballFiveEighths = "\243\176\170\162",     -- U+F0AA2
    ballThreeQuarters = "\243\176\170\163",   -- U+F0AA3
    ballSevenEighths = "\243\176\170\164",    -- U+F0AA4
    ballFull = "\243\176\170\165",            -- U+F0AA5
  },
  -- The same glyphs wa draws today, with the one space (Victor, 19/11: in the non-Mono Nerd Font a
  -- glyph is drawn WIDER than its cell and touches the character after it).
  nerd = {
    gap = " ",
    steps = "\243\176\183\186",
    clock = "\243\176\148\155",
    turns = "\243\176\145\144",
    cache = "\243\176\134\188",
    check = "\243\176\132\172",
    ballEmpty = "\243\176\157\166",
    ballEighth = "\243\176\170\158",
    ballQuarter = "\243\176\170\159",
    ballThreeEighths = "\243\176\170\160",
    ballHalf = "\243\176\170\161",
    ballFiveEighths = "\243\176\170\162",
    ballThreeQuarters = "\243\176\170\163",
    ballSevenEighths = "\243\176\170\164",
    ballFull = "\243\176\170\165",
  },
  -- Glyphs a stock terminal font has, so this set needs nothing installed. The ball keeps NINE slots
  -- but a stock font has five distinct circle pictures (U+25CB, U+25D4, U+25D1, U+25D5, U+25CF), so the
  -- ladder repeats them - a coarser reading of the same number, never a different number. M.FILL is the
  -- promise that makes the repetition honest: it never goes DOWN as the window fills.
  unicode = {
    gap = " ",
    steps = "\226\150\184",                     -- U+25B8, a step forward
    clock = "\226\151\183",                     -- U+25F7
    turns = "\226\134\187",                     -- U+21BB
    cache = "\226\150\164",                     -- U+25A4, a store
    check = "\226\156\147",                     -- U+2713
    ballEmpty = "\226\151\139",                 -- U+25CB
    ballEighth = "\226\151\148",                -- U+25D4
    ballQuarter = "\226\151\148",               -- U+25D4
    ballThreeEighths = "\226\151\145",          -- U+25D1
    ballHalf = "\226\151\145",                  -- U+25D1
    ballFiveEighths = "\226\151\149",           -- U+25D5
    ballThreeQuarters = "\226\151\149",         -- U+25D5
    ballSevenEighths = "\226\151\143",          -- U+25CF
    ballFull = "\226\151\143",                  -- U+25CF
  },
  -- Words and brackets, for a terminal with nothing: no glyph can be missing, and the row still says
  -- the same thing.
  ascii = {
    gap = " ",
    steps = "steps",
    clock = "time",
    turns = "turns",
    cache = "cache",
    check = "done",
    ballEmpty = "[    ]",
    ballEighth = "[.   ]",
    ballQuarter = "[:   ]",
    ballThreeEighths = "[::  ]",
    ballHalf = "[==  ]",
    ballFiveEighths = "[=== ]",
    ballThreeQuarters = "[====]",
    ballSevenEighths = "[::::]",
    ballFull = "[####]",
  },
}

-- A set that is not one of the four is refused by name: an unknown value must not silently become the
-- default, or a typo in the config file would look like it worked.
function M.valid(name)
  name = tostring(name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  for _, known in ipairs(M.SETS) do if known == name then return name end end
  return nil
end

-- The config file's own "icons = <set>" line, read the way every other config key is read.
function M.from_config(text)
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local key, value = line:match("^%s*([%w_.-]+)%s*=%s*(.-)%s*$")
    if key and key:lower() == "icons" then return M.valid(value) end
  end
  return nil
end

-- wa setup fonts records what it installed, and THAT RECORD - not a guess from the terminal - is what
-- makes the wa set the default. A set whose font is missing draws tofu, which is worse than the glyphs
-- a stock font already has.
M.MARKER = "fonts.json"

-- The record lives under setup/, beside the other things 'wa setup' writes - and the two readers must
-- name the SAME path: measured 21/11, the setup wrote <data>/setup/fonts.json while this looked at
-- <data>/fonts.json, so a node that had just installed wa Icons still drew the unicode set.
function M.marker_path()
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok or type(paths) ~= "table" then return nil end
  return paths.data() .. "/setup/" .. M.MARKER
end

-- Did this user's setup install wa Icons? Reads the record the setup wrote (/setup/fonts.json).
function M.installed()
  local path = M.marker_path()
  if not path then return false end
  local raw = host.read_file(path)
  if type(raw) ~= "string" or raw == "" then return false end
  local ok, record = pcall(json.decode, raw)
  if not ok or type(record) ~= "table" then return false end
  return record["wa Icons"] == true
end

-- The set in force, and WHY - the same shape features.resolve answers with, so a reader that asks
-- "which icons is this node drawing, and who said so" gets one answer.
function M.resolve(session_choice)
  local chosen = M.valid(session_choice)
  if chosen then return { set = chosen, source = "/icons " .. chosen } end
  local seen = {}
  local from_env = M.valid(host.getenv("WA_ICONS"))
  if from_env then seen[#seen + 1] = { set = from_env, source = "environment WA_ICONS" } end
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if ok and type(paths) == "table" then
    local from_file = M.from_config(host.read_file(paths.config_file()))
    if from_file then seen[#seen + 1] = { set = from_file, source = "config " .. paths.config_file() } end
  end
  if #seen > 0 then return seen[1] end
  if M.installed() then
    return { set = "wa", source = "default (wa setup fonts installed wa Icons)" }
  end
  return { set = "unicode", source = "default (wa Icons is not installed, so the glyphs a stock font has)" }
end

-- The set's own table. An unknown set is a named refusal here rather than a table of nils.
function M.set(name)
  local set = M.valid(name)
  if not set then return nil, "icons_unknown_set:" .. tostring(name) .. " (wa|nerd|unicode|ascii)" end
  return M.TABLE[set]
end

-- ONE icon: the row says WHICH, the set says WHAT. Returns the glyph and the gap that follows it.
function M.glyph(name, set_name)
  local set, why = M.set(set_name or M.resolve().set)
  if not set then return nil, why end
  local glyph = set[name]
  if glyph == nil then return nil, "icons_no_such_icon:" .. tostring(name) end
  return glyph, set.gap
end

-- The nine balls, in context_ball's order.
function M.balls(set_name)
  local set, why = M.set(set_name)
  if not set then return nil, why end
  local out = {}
  for index, name in ipairs(BALL_NAMES) do out[index] = set[name] end
  return out
end

-- How full ball number k looks, 0..8. The render tests compare two sets through THIS, never through
-- the characters, so "the ladder only goes up" is asserted for every set at once.
function M.fill_of(index)
  local name = BALL_NAMES[index]
  if not name then return nil end
  return M.FILL[name]
end

return M
