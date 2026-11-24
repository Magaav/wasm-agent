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
-- line, then the default: WHAT THIS TERMINAL IS ACTUALLY DRAWING. wa (glued) only when
-- lua/core/icon_face.lua measures wa Icons to be the face drawing the icon code points in this process's
-- terminal; otherwise the spaced nerd set (a face that has the glyphs, drawn wider than its cell) or the
-- spaced unicode set (glyphs a stock font has). A set whose font is absent is a row of tofu boxes, and a
-- window older than its config is a row of glued icons over its numbers - neither is a default worth
-- having.
local json = dofile("lua/vendor/json.lua")
local faces = dofile("lua/core/icon_face.lua")
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
  -- THE STOCK-FONT SET, REBUILT FROM MEASUREMENT (item 7, Victor 23/11: "that is horrible ... our
  -- quality should be the same everywhere"). The set this replaces drew U+25B8, U+25F7, U+21BB, U+25A4,
  -- U+25D1, U+25CB and U+25CF: the first four are not in JetBrains Mono or Liberation Mono at all (the
  -- terminal took them from a fallback face), U+25D1 is missing from JetBrains Mono, and every one of
  -- them is East-Asian-Ambiguous - a CJK-locale terminal may spend two cells on one. It was also the one
  -- set that kept a space after each icon, so the no-font row was WIDER than ours; it is GLUED like wa.
  --
  -- MEASURED (scripts/test-unicode-icons.py is the row that keeps this honest): every glyph below is
  -- East-Asian Width Narrow or Neutral - never Ambiguous, never an emoji - is present in the stock
  -- monospace faces installed on this node, and advances EXACTLY one cell in each: JetBrains Mono
  -- 600/1000, Liberation Mono 1229/2048, Noto Sans Mono 600/1000, Adwaita Mono 600/1000. DejaVu Sans
  -- Mono, Menlo, Consolas and Cascadia Code are NOT installed here; that row names them as unmeasured
  -- rather than claiming them, and every glyph used here is ASCII, Latin-1 or a square/circle those
  -- faces all carry. The nine slots use FIVE pictures, and M.FILL is the promise that makes the
  -- repetition honest: it never goes DOWN as the window fills.
  unicode = {
    gap = "",
    steps = "\226\128\186",                     -- U+203A, a step forward
    clock = "~",                                -- ASCII: elapsed
    turns = "#",                                -- ASCII: a count of runs
    cache = "=",                                -- ASCII: served from cache, the same as before
    check = "+",                                -- ASCII: U+2713 is NOT in Liberation Mono or Noto
    ballEmpty = "\226\150\171",                 -- U+25AB, white small square
    ballEighth = "\226\151\166",                -- U+25E6, a ring
    ballQuarter = "\226\151\166",               -- U+25E6
    ballThreeEighths = "\226\151\148",          -- U+25D4, a quarter black
    ballHalf = "\226\151\148",                  -- U+25D4
    ballFiveEighths = "\226\151\149",           -- U+25D5, all but the upper-left quadrant
    ballThreeQuarters = "\226\151\149",         -- U+25D5
    ballSevenEighths = "\226\150\170",          -- U+25AA, black small square
    ballFull = "\226\150\170",                  -- U+25AA
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

-- The record 'wa setup fonts' wrote, decoded, or nil when this user has none: <data>/setup/fonts.json,
-- whose "wa Icons" key is what --undo and the icon default both ask about.
function M.record()
  local path = M.marker_path()
  if not path then return nil end
  local raw = host.read_file(path)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, record = pcall(json.decode, raw)
  if not ok or type(record) ~= "table" then return nil end
  return record
end

-- Did this user's setup install wa Icons? Reads the record the setup wrote (/setup/fonts.json).
function M.installed()
  local record = M.record()
  return record ~= nil and record["wa Icons"] == true
end

-- The set in force, and WHY - the same shape features.resolve answers with, so a reader that asks
-- "which icons is this node drawing, and who said so" gets one answer.
--
-- THE DEFAULT IS NOT "THE RECORD SAYS wa Icons WAS INSTALLED". The record names the CONFIG FILES the
-- setup edited, and a terminal reads its config when it STARTS: a window opened before that edit is still
-- drawing the face it loaded, so gluing its icons is the overlap Victor photographed on 21/11. This asks
-- lua/core/icon_face.lua which face draws the icon code points in THIS terminal; that module answers
-- "cannot tell" when it cannot, and the answer carries its reason, which is what /icons prints.
--
-- opts (both optional, both for a test): record = a decoded record to use instead of the one on disk,
-- face = the opts handed to icon_face.face (an observation, a font query, a reader).
function M.resolve(session_choice, opts)
  opts = opts or {}
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
  local record = opts.record or M.record()
  -- THE FACE IS ASKED EVEN WHEN NOTHING SAYS wa Icons WAS INSTALLED (item 6, Victor 23/11). Measured on
  -- the work node: on a container (and on an ssh session) there is no setup record at all -
  -- <data>/setup/fonts.json is missing, because `wa setup fonts` never ran inside it - and this returned
  -- "unicode" here without ever asking WHICH FACE draws the icon code points in this terminal. A window
  -- that HAS a Nerd Font, or our own wa Icons, therefore drew the stock glyphs and nobody was told why.
  -- The record is only where the setup wrote down what it did; the face is the measurement, and it is
  -- asked whatever the record says.
  local face = faces.face(opts.face or { record = record })
  -- glued == nil is the face's own "cannot tell": the terminal could not be measured, or the font
  -- question could not be answered on this machine. That is the one state the reader is told about
  -- (`M.notice_line`), because it is the one state a config line fixes.
  return { set = face.set, source = face.why, unknown = face.glued == nil }
end

-- REMEMBER THE CHOICE (item 6, Victor 23/11): `icons = <set>` in this node's config file, the line
-- `M.from_config` already reads - so the reader who types `/icons wa` once is not asked again at the next
-- restart. The file is <config>/env (paths.config_file); this line is lowercase and is read by this module
-- alone, which is why it cannot collide with a KEY=VALUE setting.
function M.remember(set_name)
  local set = M.valid(set_name)
  if not set then return nil, "icons_unknown_set:" .. tostring(set_name) .. " (wa|nerd|unicode|ascii)" end
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok or type(paths) ~= "table" then return nil, "icons_no_config: lua/core/paths.lua could not be read" end
  local file = paths.config_file()
  local text = (host and host.read_file and host.read_file(file)) or ""
  if type(text) ~= "string" then text = "" end
  local lines, found = {}, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*icons%s*=") then
      lines[#lines + 1] = "icons = " .. set
      found = true
    elseif not (line == "" and #lines == 0 and text == "") then
      lines[#lines + 1] = line
    end
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  if not found then lines[#lines + 1] = "icons = " .. set end
  local written = table.concat(lines, "\n") .. "\n"
  local wrote, problem = pcall(host.write_file, file, written)
  if not wrote then return nil, "icons_cannot_write: " .. file .. ": " .. tostring(problem) end
  return file
end

-- THE ONE LINE a reader is told when the set was chosen BY DEFAULT and the font could not be measured,
-- and nil in every other case: an explicit choice (a config line, WA_ICONS, /icons) is a choice, and a
-- face that WAS measured needs no advice. `unknown` is the resolver's own flag, never a guess here.
M.NOTICE = "icons: %s (font unknown here). If your terminal has wa Icons: /icons wa"
function M.notice_line(set_name, unknown)
  if not unknown then return nil end
  return string.format(M.NOTICE, tostring(set_name or "unicode"))
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

-- ---- the ONE line that puts the font on the DRAWING machine (item 7, Victor 23/11) ---------------
--
-- A container cannot install a font for the terminal that DRAWS its output: the font has to land on the
-- machine with the window, which may have no wa at all. So the release carries the font itself
-- (waIcons-Regular.ttf, an asset of every node release - scripts/publish-node-binaries.sh), the same
-- bytes as assets/fonts/waIcons-Regular.ttf, and it is covered by that release SIGNED SHA256SUMS (the
-- vault release-signing key signs that list, and a release without a valid signature is never published).
--
-- AND ONLY WHEN THE ASSET EXISTS (Fable, 24/11): the running build knows from `release_fonts`, embedded by
-- rust/wa-capabilities/build.rs from the presence of this tree's own assets/fonts/waIcons-Regular.ttf - the
-- file the publisher refuses a release without - and from its own label, which names the tag the assets live
-- under. A build that cannot stand behind the URL prints the REASON instead (M.FONT_ABSENT / M.NO_RELEASE),
-- never a dead link.
M.FONT_ASSET = "waIcons-Regular.ttf"
M.FONT_REPO = "Magaav/wasm-agent"

-- The tag a release's assets live under, from the label of the bytes that are running - or nil when that
-- label is not a release. THREE SHAPES, and each exists in this tree's own words:
--   * `node-<sha12>` - every node release (`scripts/lib/node-binaries.sh`, wa_node_release_tag); `installed.txt`
--     records it as binary_release, so an installed node's label IS its release tag;
--   * `vX.Y.Z[-pre]` - a product release tag (`wa release cut`). A TAGGED RELEASE'S ASSETS LIVE UNDER ITS OWN
--     TAG, NOT under `node-<sha>`: the link must name the tag the release was published with, which is why this
--     reads the label instead of re-deriving it;
--   * `<sha>` / `<sha> (pinned)` - a dev build, or a commit an operator pinned. Neither was published, so
--     there is no release to name and no link to print.
function M.release_tag(label)
  local text = tostring(label or "")
  if text:match("%s+%([^%)]*%)") then return nil end
  local sha = text:match("^node%-(%x%x%x%x%x%x%x%x%x%x%x%x)$")
  if sha then return "node-" .. sha end
  if text:match("^v%d+%.%d+%.%d+[%w%.%-]*$") then return text end
  return nil
end

-- WHAT THE LINE DOWNLOADS, and from where: this build's own release - under its own tag, `node-<sha12>` or a
-- product tag - at https://github.com/<repo>/releases/download/<tag>/waIcons-Regular.ttf, one font file, no
-- installer, no shell pipeline and no token, listed in that release's SIGNED SHA256SUMS.
--
-- AND NOTHING WHEN IT CANNOT STAND: a link is printed only when the build's tree carries the font
-- (`release_fonts`, embedded at build time - the publisher refuses a set without that file, so the two agree)
-- AND the label names a release. Otherwise the reason is returned instead, never a dead URL.
M.FONT_ABSENT = "font_absent: this build's tree has no %s, so its release ships no icon font and there is no link to print (a build cut before item 7 has none)"
M.NO_RELEASE = "no_release: these bytes are not a release (label %s), so there is no release asset to name - install a node release, or copy assets/fonts/%s by hand"
function M.fetch_line(label, opts)
  opts = opts or {}
  if opts.fonts ~= true then return nil, string.format(M.FONT_ABSENT, M.FONT_ASSET) end
  local tag = M.release_tag(label)
  if not tag then return nil, string.format(M.NO_RELEASE, tostring(label or ""), M.FONT_ASSET) end
  return string.format(
    "curl -fsSL https://github.com/%s/releases/download/%s/%s -o ~/.local/share/fonts/%s && fc-cache -f ~/.local/share/fonts",
    M.FONT_REPO, tag, M.FONT_ASSET, M.FONT_ASSET), nil
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
