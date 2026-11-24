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

-- THE WHY SURVIVES START-UP. cli_view adopts the resolved set through use_icons(), and until 21/11 that
-- replaced the reason with the placeholder "use_icons": /icons could say WHICH set but never WHY, which is
-- half the answer this mission is about. Asserted here, before anything in this file moves the set, so it
-- reads the source the process really starts with.
local started_with = select(2, view_lib.icon_set())
ok(type(started_with) == "string" and started_with ~= "" and started_with ~= "use_icons",
  "cli_view keeps the reason the set was resolved, not the placeholder: " .. tostring(started_with))

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

-- THE LAYOUT, set by set (item 7, Victor 23/11): wa Icons is GLUED, and so is the unicode set now - "a
-- terminal without our font looks the same except for the glyph shapes". nerd keeps its one space (19/11:
-- that face draws its glyphs WIDER than their cell, so gluing them collides with the value), and ascii's
-- glyphs are words, which carry their own separator.
eq(icons.set("wa").gap, "", "wa is glued: the value starts in the icon's own cell")
eq(icons.set("unicode").gap, "", "unicode is glued too: the no-font row has the SAME layout as ours")
for _, set_name in ipairs({ "nerd", "ascii" }) do
  eq(icons.set(set_name).gap, " ", set_name .. " keeps the space its own glyphs need")
end

-- EVERY GLYPH OF THE STOCK SET IS ONE OF THE MEASURED ONES (item 7). The characters below are what
-- scripts/test-unicode-icons.py measured one cell wide in this node's stock monospace faces, and what the
-- Unicode East-Asian-Width table calls Narrow or Neutral; a glyph swapped in without that measurement
-- fails here, by name - this row cannot open a font file from Lua.
local MEASURED_NARROW = { ["~"] = true, ["#"] = true, ["="] = true, ["+"] = true,
  ["\226\128\186"] = true,  -- U+203A
  ["\226\150\171"] = true,  -- U+25AB
  ["\226\151\166"] = true,  -- U+25E6
  ["\226\151\148"] = true,  -- U+25D4
  ["\226\151\149"] = true,  -- U+25D5
  ["\226\150\170"] = true,  -- U+25AA
}
for _, icon in ipairs(NAMES) do
  local glyph = icons.set("unicode")[icon]
  ok(MEASURED_NARROW[glyph] == true,
    "unicode." .. icon .. " is a glyph measured one cell wide in the stock faces (" .. tostring(glyph) .. ")")
end

-- THE FONT ON THE DRAWING MACHINE (item 7): ONE line, from THIS build's own release - and it is printed only
-- when the release asset can stand behind it (Fable, 24/11): the build embeds whether its tree carries the font
-- (rust/wa-capabilities/build.rs RELEASE_FONTS, which the publisher's own font_missing refusal mirrors), and the
-- label names the tag the assets live under.
local function fetch_box(label, fonts) return icons.fetch_line(label, { fonts = fonts }) end

local node_link, node_why = fetch_box("node-0123456789ab", true)
ok(type(node_link) == "string" and node_link:find(
  "https://github.com/Magaav/wasm-agent/releases/download/node-0123456789ab/waIcons-Regular.ttf", 1, true) ~= nil,
  "a node release's link names that release's tag: " .. tostring(node_link))
ok(node_why == nil, "and needs no reason")
ok(type(node_link) == "string" and node_link:find("curl -fsSL", 1, true) == 1 and node_link:find("fc-cache", 1, true) ~= nil,
  "with curl and the font cache rebuild, and nothing else: " .. tostring(node_link))

-- A TAGGED RELEASE uses ITS OWN tag - its assets live under it, not under node-<sha> (Fable, 24/11).
local tagged = fetch_box("v0.1.2", true)
ok(type(tagged) == "string" and tagged:find(
  "https://github.com/Magaav/wasm-agent/releases/download/v0.1.2/waIcons-Regular.ttf", 1, true) ~= nil,
  "a product release's link uses its own tag: " .. tostring(tagged))
ok(type(fetch_box("v0.1.3-rc.1", true)) == "string", "and so does a pre-release tag")
eq(icons.release_tag("node-0123456789ab"), "node-0123456789ab", "a node tag is read back as itself")
eq(icons.release_tag("v0.1.2"), "v0.1.2", "a product tag is read back as itself")
eq(icons.release_tag("d0e345a1"), nil, "a commit label is not a release")
eq(icons.release_tag("d0e345a1 (pinned)"), nil, "and a pinned commit is not one either")

-- A BUILD WHOSE RELEASE HAS NO FONT prints the reason, never a dead link (Fable, 24/11: text 5's reason).
local absent, absent_why = fetch_box("node-0123456789ab", false)
eq(absent, nil, "no link when the tree carries no font, however release-like the label is")
ok(type(absent_why) == "string" and absent_why:find("font_absent:", 1, true) == 1,
  "the reason is said instead: " .. tostring(absent_why))
eq(fetch_box("node-0123456789ab", nil), nil, "and an unknown answer is not a yes")
local dev, dev_why = fetch_box("d0e345a1", true)
eq(dev, nil, "a dev commit names no release")
ok(type(dev_why) == "string" and dev_why:find("no_release:", 1, true) == 1,
  "and says so: " .. tostring(dev_why))

-- THIS TREE REALLY CARRIES THE FONT, and its build says so: the two facts that make the link stand on a
-- release. The row reads the file itself, so deleting it fails here rather than in a 404 months later.
local wanted = ((type(host) == "table") and host.getenv and host.getenv("WASM_AGENT_LUA_ROOT")) or "."
-- `host.read_file` answers TEXT only (a font is refused as read_file_not_text), so the file is asked about the
-- way a shell asks: `test -s`. A row that cannot ask refuses, never passes.
local jlib = dofile("lua/vendor/json.lua")
local asked, raw = pcall(host.exec, "test -s " .. wanted .. "/assets/fonts/waIcons-Regular.ttf", "", 10)
local font_code
do
  local decoded = nil
  if asked and type(raw) == "string" then local d, value = pcall(jlib.decode, raw); if d then decoded = value end end
  font_code = type(decoded) == "table" and tonumber(decoded.code) or nil
end
ok(font_code == 0, "this tree carries assets/fonts/waIcons-Regular.ttf (test -s answered " .. tostring(font_code) .. ")")
local identity = dofile("lua/core/build_identity.lua").identity()
ok(identity.fonts == true, "and the running binary's build says its tree carries it (release_fonts)")

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
-- The default is ASKED, not recorded: wa only when the setup recorded it AND the face drawing this
-- process's terminal was measured to be wa Icons (the fixtures below pin each of the three cases). This
-- asserted the other way round until 21/11 - resolve()==wa if and only if the record said installed -
-- which is the glue-over-the-numbers bug itself, written down as a test.
local home_default = icons.resolve()
ok(home_default.set ~= "wa" or icons.installed(), "wa is never chosen when nothing was installed")
ok(type(home_default.source) == "string" and home_default.source ~= "",
  "and the default always carries its reason: " .. tostring(home_default.source))
if not icons.installed() then
  eq(home_default.set, "unicode", "with no record at all, the default is the glyphs a stock font has")
end


-- ---- WHICH FACE DRAWS THEM: the glued set only where wa Icons really is the face (item 5) ---------
--
-- The three cases the brief names, put through resolve() - the path a node really takes - with the
-- terminal observation INJECTED, because a test must not depend on the terminal it happens to run in.
-- The walk itself is proven across two real processes by scripts/test-icon-face.lua.
local faces = dofile("lua/core/icon_face.lua")
local FOOT_INI = "[main]\nfont=JetBrains Mono:size=9, wa Icons:size=9\n"
local RECORD = { ["wa Icons"] = true, font_dir = "/scratch/fonts",
  terminals = { { name = "foot", path = "/scratch/.config/foot/foot.ini", action = "edited" } } }
-- fontconfig's own answers on a node where both faces exist. MEASURED 21/11: asked for a "JetBrains
-- Mono" stack and U+F0766, fontconfig answers the NERD face, not wa Icons - which is exactly why an
-- alacritty window is not the glued one, however the record reads.
local ANSWERS = {
  ["wa Icons"] = "wa Icons",
  ["JetBrains Mono:charset=f0766"] = "JetBrains Mono Nerd Font,JetBrains Mono NF",
  ["JetBrainsMono Nerd Font:charset=f0766"] = "JetBrains Mono Nerd Font",
}
local function nerd_or_not(family) return tostring(family):lower():find("nerd", 1, true) ~= nil end
local function resolved_face(observation, config_text, tweaks)
  tweaks = tweaks or {}
  return icons.resolve(nil, {
    record = RECORD,
    face = {
      observation = observation,
      read = function() return config_text end,
      query = function(pattern) return (tweaks.answers or ANSWERS)[pattern] end,
      draws = tweaks.draws or nerd_or_not,
    },
  })
end
local NEW_WINDOW = { terminal = { name = "foot", pid = 4242, started_at = 2000 }, stats = { foot = 1000 }, seen = {} }
local OLD_WINDOW = { terminal = { name = "foot", pid = 4242, started_at = 1000 }, stats = { foot = 2000 }, seen = {} }
local SAME_SECOND = { terminal = { name = "foot", pid = 4242, started_at = 1000 }, stats = { foot = 1000 }, seen = {} }
local NO_TERMINAL = { seen = { "bash", "systemd" }, stats = {} }

-- (a) a NEW window: wa Icons is the face, so the glued set, and /icons says what it measured.
local fresh = resolved_face(NEW_WINDOW, FOOT_INI)
eq(fresh.set, "wa", "a foot window started AFTER the setup wrote its config draws the GLUED wa set")
eq(icons.set(fresh.set).gap, "", "and that set really is glued")
ok(tostring(fresh.source):find("after wa setup fonts wrote", 1, true) ~= nil,
  "and /icons says why: " .. tostring(fresh.source))

-- (b) a window OLDER than the setup: it still draws the face it loaded, so the SPACED nerd set - the
-- same glyphs, one space before each value, no overlap.
local older = resolved_face(OLD_WINDOW, FOOT_INI)
eq(older.set, "nerd", "a foot window that started BEFORE the setup wrote its config gets the SPACED nerd set")
eq(icons.set(older.set).gap, " ", "and that set really has the space")
ok(tostring(older.source):find("before wa setup fonts wrote", 1, true) ~= nil,
  "and /icons says why: " .. tostring(older.source))
ok(tostring(older.source):find("NERD", 1, true) == nil and tostring(older.source):find("wa Icons", 1, true) == nil,
  "without claiming the glued face it is not drawing")

-- (c) a terminal nobody can identify: the unicode set, never the glued one.
local blind = resolved_face(NO_TERMINAL, FOOT_INI)
eq(blind.set, "unicode", "a terminal that cannot be identified gets the stock-font unicode set")
eq(icons.set(blind.set).gap, "", "and it is GLUED like wa (item 7): one layout, so the no-font row looks the same")
ok(tostring(blind.source):find("ancestry", 1, true) ~= nil,
  "and says what it could not see: " .. tostring(blind.source))

-- The same second cannot be ordered: not a yes either, and the spaced set again.
local ambiguous = resolved_face(SAME_SECOND, FOOT_INI)
eq(ambiguous.set, "nerd", "a window started in the same second as the write is not glued")
ok(tostring(ambiguous.source):find("same second", 1, true) ~= nil, "and says so: " .. tostring(ambiguous.source))

-- The font itself gone: the config may still name it, and then it draws tofu, not wa Icons.
local missing_font = resolved_face(NEW_WINDOW, FOOT_INI, { answers = {
  ["wa Icons"] = "Some Other Font",
  ["JetBrains Mono:charset=f0766"] = "JetBrains Mono Nerd Font",
} })
eq(missing_font.set, "nerd", "a node where fontconfig cannot resolve wa Icons does not get the glued set")
ok(tostring(missing_font.source):find("is not installed for this user", 1, true) ~= nil,
  "and names the missing face: " .. tostring(missing_font.source))

-- A fontconfig terminal in a NEW window: fontconfig answers the Nerd face for the icon code points, so
-- the icons are wide Nerd glyphs even though the setup edited that config (measured 21/11 on this node).
local ALA_INI = "[font.normal]\nfamily = \"JetBrains Mono\"\n"
local alacritty = resolved_face({ terminal = { name = "alacritty", pid = 7, started_at = 2000 }, stats = { alacritty = 1000 }, seen = {} }, ALA_INI)
eq(alacritty.set, "nerd", "an alacritty window is the spaced nerd set: fontconfig gives its icons to the Nerd face")
eq(icons.set(alacritty.set).gap, " ", "and it is spaced")

-- kitty names the icon face on a symbol_map line, which is the config's own statement (foot names it in
-- the font list); a new kitty window is therefore glued, and the reader that decides it is the one the
-- setup writes against - a whole-plane symbol_map would not count.
local KITTY_CONF = "font_family JetBrains Mono\nsymbol_map U+F012C,U+F01BC,U+F0450,U+F051B,U+F0766,U+F0A9E-U+F0AA5,U+F0DFA wa Icons\n"
local kitty = resolved_face({ terminal = { name = "kitty", pid = 9, started_at = 2000 }, stats = { kitty = 1000 }, seen = {} }, KITTY_CONF)
eq(kitty.set, "wa", "a new kitty window whose symbol_map names wa Icons gets the glued set")
local stale_kitty = resolved_face({ terminal = { name = "kitty", pid = 9, started_at = 2000 }, stats = { kitty = 1000 }, seen = {} },
  "font_family JetBrains Mono\nsymbol_map U+F0000-U+FFFFD wa Icons\n")
eq(stale_kitty.set, "nerd", "a whole-plane symbol_map is not the map the setup writes, so that window is not glued")

-- A footclient window is drawn by the foot SERVER, which read its config when the server started: this
-- window does not date that.
local client = resolved_face({ terminal = { name = "footclient", pid = 8, started_at = 2000 }, stats = {}, seen = {} }, FOOT_INI)
eq(client.set, "unicode", "a footclient window is not glued: the face is the server's, not this window's")
ok(tostring(client.source):find("footclient", 1, true) ~= nil, "and says so: " .. tostring(client.source))

-- A config that cannot be read is not a config that names wa Icons.
local unreadable = resolved_face(NEW_WINDOW, nil)
eq(unreadable.set, "unicode", "a config that cannot be read is not glued")
ok(tostring(unreadable.source):find("could not be read", 1, true) ~= nil, "and names the file: " .. tostring(unreadable.source))

-- No record at all: nothing to measure, and the stock glyphs.
eq(icons.resolve(nil, { record = {} }).set, "unicode", "without a record the default is still unicode")
eq(icons.resolve(nil, { record = { ["wa Icons"] = false } }).set, "unicode", "and a record that says wa Icons is absent is not a yes")

-- Two readers of one question agree: chat.lua asks icons.resolve, cli_view renders it.
view_lib.use_icons("unicode")
eq(select(1, view_lib.icon_set()), "unicode", "cli_view reports the set it is drawing")

-- Put the process back the way it was found, so a later row in the same interpreter is unaffected.
view_lib.use_icons("nerd")

-- ---- item 6: the unknown font, the one line, and the remembered choice -------------------
--
-- Victor, 23/11: on a tty where the font cannot be known (a container, an ssh session) wa says so ONCE and
-- names the command that fixes it, and `/icons wa` is remembered for this node's user, so it is typed once.
-- The measured premise (lua/core/icons.lua:183 resolve, :198): with no setup record the resolver answered
-- "unicode" and the terminal-face check was never reached. Both halves are held here - the face IS asked,
-- and its answer says whether it could tell.

-- (a) A machine with no terminal in its ancestry: the face cannot be measured, so the set is the stock
-- glyphs AND the resolver says it could not tell - which is exactly what the start-up line is for.
local blind = icons.resolve(nil, { record = {},
  face = { observation = { terminal = nil, seen = { "bash", "sshd" }, stats = {} } } })
eq(blind.set, "unicode", "an unmeasurable terminal still gets the stock glyphs")
eq(blind.unknown, true, "and the resolver says the font could not be known here")
eq(icons.notice_line(blind.set, blind.unknown),
  "icons: unicode (font unknown here). If your terminal has wa Icons: /icons wa",
  "the ONE line the start says: which set draws, why, and the command that makes it ours")
-- (b) A face that WAS measured says nothing: advice about an unknown font would be false there.
eq(icons.notice_line("nerd", false), nil, "a measured face gets no notice")
eq(icons.notice_line("unicode", false), nil, "and neither does a set the reader chose")
-- (c) An explicit /icons is not an unknown font.
view_lib.use_icons("unicode")
eq(view_lib.icons_notice(), "", "an explicit set silences the line")
-- (d) The choice is REMEMBERED: `icons = <set>` in this node's config file, read back by the same reader that
-- decides the default. The row refuses the operator's own home, like every row that writes.
do
  local home = (host.getenv("WASM_AGENT_HOME") or ""):gsub("\\\\", "/"):gsub("/+$", "")
  local operator = ((host.getenv("HOME") or "") .. "/.wasm-agent"):gsub("\\\\", "/"):gsub("/+$", "")
  if home == "" or home:lower() == operator:lower() then
    ok(false, "refusing to write a config line in the operator's own home (" .. home .. ")")
  else
    local file, why = icons.remember("wa")
    ok(file ~= nil, "the choice is written to a config file: " .. tostring(file or why))
    eq(icons.from_config(host.read_file(file or "")), "wa",
      "and the reader that decides the default reads it back")
    -- A restart: no session choice, no record, no measurable font - the config line alone decides.
    local env_choice = (host.getenv("WA_ICONS") or ""):gsub("%s", "")
    local resumed = icons.resolve(nil, { record = {},
      face = { observation = { terminal = nil, seen = {}, stats = {} } } })
    if env_choice == "" then
      eq(resumed.set, "wa", "a restart draws wa: the config line decides before the font is asked")
      ok(tostring(resumed.source):find("config", 1, true) ~= nil,
        "and says where that came from: " .. tostring(resumed.source))
    else
      ok(false, "WA_ICONS is set in this environment, so this row cannot say the config line decided (" .. env_choice .. ")")
    end
    ok(not resumed.unknown, "a remembered choice is not an unknown font, so no notice is due")
    -- Written twice, the line is REPLACED rather than repeated: a config that grows a line per /icons is a
    -- file nobody can read in a month.
    icons.remember("nerd")
    local text = host.read_file(file or "") or ""
    local seen = 0
    for line in text:gmatch("[^\n]+") do if line:match("^%s*icons%s*=") then seen = seen + 1 end end
    eq(seen, 1, "the config file holds ONE icons line however many times it was set")
    eq(icons.from_config(text), "nerd", "and it is the last one chosen")
    icons.remember("wa")
  end
end

print(string.format("icons: %s (%d checks, %d failed, 0 skipped)",
  failed == 0 and "ok" or "FAILED", checks, failed))
os.exit(failed == 0 and 0 or 1)
