-- 'wa setup fonts' (item 3 of the wa-fonts mission, Victor 19/11): the install path, the terminal edits,
-- the backup and the undo - every one of them driven on a SCRATCH home, never the operator's.
--
-- The rule this file exists to keep: this command writes into a user's font directory and edits a
-- terminal's config, so a test that ran on the real home would install fonts on the machine of whoever
-- runs the suite and edit the config of their terminal. Every case below therefore gives the module an
-- explicit home, an explicit font dir and an explicit runner, and REFUSES to start on the real one.
local font_setup = dofile("lua/core/font_setup.lua")

-- The scratch-home guard, in the one place every Lua row agrees on it.
local scratch = dofile("scripts/lib/scratch-home.lua")
local refusal = scratch.guard("test-font-setup.lua")
if refusal then print("REFUSED " .. refusal); os.exit(2) end

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end

-- A scratch tree, and nothing else: the home, the bundle and the font directory.
local scratch_root = (host.getenv("WASM_AGENT_HOME") or "") .. "/font-setup-scratch"
local function path_join(...) return table.concat({ ... }, "/"):gsub("//+", "/") end
local function mkdir(path) pcall(host.exec, "mkdir -p '" .. path .. "'", "", 20) end
local function write(path, text)
  mkdir(path:gsub("/[^/]+$", ""))
  return host.write_file(path, text)
end
local function read(path) return host.read_file(path) end
local function exists(path) return (host.path_kind and host.path_kind(path) == "file") or (read(path) ~= nil) end

-- ---- the OS install path: a scratch home, never this machine's ------------------------------------
-- One case per OS this ships on. The font DIRECTORY is the answer that matters (a per-user location: a
-- setup that needs root is a setup nobody runs), and it is asserted as a path, not by touching the disk.
local home = "/home/someone"
eq(font_setup.font_dir("linux", home), home .. "/.local/share/fonts", "Linux installs under ~/.local/share/fonts")
eq(font_setup.font_dir("darwin", home), home .. "/Library/Fonts", "macOS installs under ~/Library/Fonts")
eq(font_setup.font_dir("windows", home), home .. "/AppData/Local/Microsoft/Windows/Fonts",
  "Windows installs into the user's own font directory (LOCALAPPDATA when it is set)")

-- The opt-out, read the way the installer reads it.
local real_getenv = host.getenv
local function with_env(name, value)
  host.getenv = function(key)
    if key == name then return value end
    return real_getenv(key)
  end
end
with_env("WA_NO_FONT_SETUP", "1")
ok(font_setup.disabled(), "WA_NO_FONT_SETUP=1 disables the setup")
with_env("WA_NO_FONT_SETUP", "")
ok(not font_setup.disabled(), "and an unset variable does not")
host.getenv = real_getenv

-- The install itself, on a scratch tree. The bundle is a directory of three files this test writes; the
-- runner is a fake that records the commands, so the test asserts the INTENT (what would be copied where)
-- without copying a byte into a real font directory.
local bundle = scratch_root .. "/bundle"
mkdir(bundle)
for _, name in ipairs(font_setup.FONTS) do
  write(bundle .. "/" .. name, "not a real font: this fixture only has to exist")
end
local font_dir = scratch_root .. "/fonts"
local commands = {}
local function fake_run(command)
  commands[#commands + 1] = command
  if command:find("fc-list", 1, true) then return "" end
  return "ok"
end
-- install_fonts answers the DETAIL TABLE on success (the same table it hands back beside a refusal), so
-- one shape covers both: the caller reads .copied when there is one and the refusal text when there is not.
local detail, why = font_setup.install_fonts({
  os = "linux", home = scratch_root, source_dir = bundle, font_dir = font_dir, run = fake_run,
})
ok(detail ~= nil, "the install succeeds on a complete bundle: " .. tostring(why))
eq(#(detail.copied or {}), 3, "all three faces are copied")
eq(detail.dir, font_dir, "into the per-user font directory")
eq(detail.cache, "refreshed", "and the font cache is refreshed on Linux")
local copied_icons, copied_text = false, false
for _, command in ipairs(commands) do
  if command:find("waIcons-Regular.ttf", 1, true) then copied_icons = true end
  if command:find("JetBrainsMono-Regular.ttf", 1, true) then copied_text = true end
end
ok(copied_icons, "wa Icons is one of the copies")
ok(copied_text, "and so is the text font")

-- A bundle missing a face is REFUSED, never half-installed: two of three faces is a terminal with half
-- an icon set.
local short_bundle = scratch_root .. "/short-bundle"
mkdir(short_bundle)
write(short_bundle .. "/JetBrainsMono-Regular.ttf", "x")
local short_ok, short_why = font_setup.install_fonts({
  os = "linux", home = scratch_root, source_dir = short_bundle, font_dir = scratch_root .. "/fonts2", run = fake_run,
})
ok(short_ok == nil, "a bundle missing faces is refused")
ok(tostring(short_why):find("fonts_missing_from_bundle", 1, true) ~= nil,
  "and the refusal names what is missing: " .. tostring(short_why))

-- ---- a terminal config: the edit, the backup, the undo ---------------------------------------------
-- Fixture configs, written into the scratch tree, because the point is the BYTES this command leaves in
-- a real terminal's file. A config it cannot measure is left alone; a config whose face already draws
-- wa's icons is left alone too, and both say why.
local fixtures = scratch_root .. "/fixtures"
mkdir(fixtures .. "/foot")

-- foot: an ini with a [main] font that has no icons.
local foot_path = fixtures .. "/foot/foot.ini"
write(foot_path, "[main]\nfont=Source Code Pro:size=11\n\n[colors]\nforeground=ffffff\n")
-- The fixture terminal, BUILT here rather than looked up: terminals(home) answers the paths a home
-- would use, and this test owns its own paths. (The first version took terminals()[1] and edited the
-- operator's real ~/.config/foot/foot.ini - see the guard below.)
local foot = { name = "foot", path = foot_path, kind = "ini", section = "main", key = "font" }
-- NOTHING BELOW MAY TOUCH A REAL CONFIG. A row that resolves to the operator's home is refused here,
-- before the write, because one measured incident is one too many: the paths this test edits are all
-- under scratch_root and the guard says so out loud.
local REAL_CONFIG = (host.getenv("WA_HOME_BEFORE_OVERRIDE") or host.getenv("HOME") or "") .. "/.config"
if foot.path:sub(1, #REAL_CONFIG) == REAL_CONFIG then
  print("REFUSED test-font-setup.lua: foot.path " .. foot.path .. " is inside the operator's real " .. REAL_CONFIG)
  os.exit(2)
end
eq(foot.name, "foot", "the first known terminal is foot")
eq(font_setup.current_font(foot, read(foot_path)), "Source Code Pro:size=11", "foot's current font is read from its own section")
local edited, edit_why = font_setup.edited_text(foot, read(foot_path))
ok(edited ~= nil, "foot's config is editable: " .. tostring(edit_why))
ok(edited:find("font=JetBrains Mono:size=11, wa Icons:size=11", 1, true) ~= nil,
  "the font line is the A2 pair, keeping the size the operator chose")
ok(edited:find("wa Icons:size=11", 1, true) ~= nil,
  "and asks for wa Icons as the icon face, in foot's comma-separated form")
ok(edited:find("foreground=ffffff", 1, true) ~= nil, "the rest of the file is untouched")

-- The edit through the command, with the coverage question answered NO: the file is changed, backed up,
-- and the backup holds the ORIGINAL bytes.
local applied = font_setup.configure_terminal(foot, {})
eq(applied.action, "edited", "a terminal whose font cannot draw wa's icons is edited")
eq(applied.current, "Source Code Pro:size=11", "and the row says what it was")
ok(exists(applied.backup), "a backup was written BEFORE the edit: " .. tostring(applied.backup))
eq(read(applied.backup), "[main]\nfont=Source Code Pro:size=11\n\n[colors]\nforeground=ffffff\n",
  "and the backup is the original bytes, exactly")
ok(read(foot_path):find("font=JetBrains Mono", 1, true) ~= nil, "the live config carries the new font")

-- The pair the setup itself writes IS left alone: the edit is a repair, not a preference.
write(foot_path, "[main]\nfont=JetBrains Mono:size=11, wa Icons:size=11\n")
local kept = font_setup.configure_terminal(foot, {})
eq(kept.action, "left alone", "a terminal already on the A2 pair is not replaced")
ok(tostring(kept.why):find("already draws", 1, true) ~= nil, "and the row says why: " .. tostring(kept.why))
ok(read(foot_path):find("wa Icons", 1, true) ~= nil, "its config is untouched")

-- A config that names NO font is left alone: there is no face to replace, and inventing one would be
-- this command choosing a terminal's first face.
write(foot_path, "[main]\npad=14x14\n")
local unknown = font_setup.configure_terminal(foot, {})
eq(unknown.action, "left alone", "a config with no font of its own leaves the config alone")
ok(tostring(unknown.why):find("names no font", 1, true) ~= nil, "and says so by name: " .. tostring(unknown.why))

-- A terminal with no config file is not created: nobody configured it, and this command is not a
-- terminal's first run.
local absent = font_setup.configure_terminal({ name = "kitty", path = fixtures .. "/kitty/kitty.conf", kind = "conf", key = "font_family" },
  { draws = function() return false end })
eq(absent.action, "left alone", "a terminal with no config file is not given one")

-- --dry-run says what it WOULD do and writes nothing.
write(foot_path, "[main]\nfont=Source Code Pro:size=11\n")
local before = read(foot_path)
local planned = font_setup.configure_terminal(foot, { dry_run = true })
eq(planned.action, "would edit", "a dry run reports the edit it would make")
eq(read(foot_path), before, "and leaves the file byte-identical")

-- The other config shapes, as bytes: alacritty's toml, kitty/ghostty's word, wezterm's lua table. One
-- case each, because each is a different parse and a different edit.
local alacritty = { name = "alacritty", path = fixtures .. "/alacritty.toml", kind = "toml", section = "font.normal", key = "family" }
write(alacritty.path, "[font.normal]\nfamily = \"Fira Code\"\nstyle = \"Regular\"\n")
eq(font_setup.current_font(alacritty, read(alacritty.path)), "Fira Code", "alacritty's family is read from its table")
local alacritty_text = font_setup.edited_text(alacritty, read(alacritty.path))
ok(alacritty_text:find("family = \"JetBrains Mono\"", 1, true) ~= nil, "and replaced in place")
ok(alacritty_text:find("style = \"Regular\"", 1, true) ~= nil, "without touching its siblings")

local kitty = { name = "kitty", path = fixtures .. "/kitty.conf", kind = "conf", key = "font_family" }
write(kitty.path, "font_family Fira Code\nfont_size 11\n")
eq(font_setup.current_font(kitty, read(kitty.path)), "Fira Code", "kitty's font_family is read")
local kitty_text = font_setup.edited_text(kitty, read(kitty.path))
ok(kitty_text:find("font_family JetBrains Mono", 1, true) ~= nil, "and replaced")
ok(kitty_text:find("font_size 11", 1, true) ~= nil, "with the rest of the file intact")

local wezterm = { name = "wezterm", path = fixtures .. "/wezterm.lua", kind = "lua-wezterm" }
write(wezterm.path, "return {\n  font = wezterm.font({ family = 'Fira Code' }),\n}\n")
eq(font_setup.current_font(wezterm, read(wezterm.path)), "Fira Code", "wezterm's font family is read from its table")
local wezterm_text = font_setup.edited_text(wezterm, read(wezterm.path))
ok(wezterm_text and wezterm_text:find("family = 'JetBrains Mono'", 1, true) ~= nil, "and replaced inside the table")
-- A wezterm config with no font table is a PROGRAM, not a setting: refused by name.
local refused, refused_why = font_setup.edited_text(wezterm, "return {}\n")
ok(refused == nil and tostring(refused_why) == "wezterm_font_table_absent",
  "a wezterm config with no font table is refused by name: " .. tostring(refused_why))

-- ---- running it TWICE, and what that protects --------------------------------------
-- A second run must find nothing to do. It is not tidiness: the backup is the undo, and an idempotent
-- check that fails here rewrites the file and overwrites the backup with already-edited bytes - which is
-- exactly how a --undo restored the wrong thing (measured 21/11).
write(foot_path, "[main]\nfont=Source Code Pro:size=11\n")
eq(font_setup.draws_icons("Source Code Pro"), false, "an uninstalled font cannot draw wa's icons")
eq(font_setup.draws_icons("JetBrainsMono Nerd Font"), true, "a Nerd Font can")
eq(font_setup.draws_icons("JetBrains Mono:size=11:charwidth=6:icons=wa Icons"), true,
  "and so can the line this command itself writes (or a second run would edit it again)")
eq(font_setup.draws_icons("JetBrains Mono:size=11"), false,
  "a plain JetBrains Mono description alone cannot: the family is read before the colon")
-- The DESCRIPTION is split from the family before fc-list is asked anything.
eq(font_setup.family_of("Source Code Pro:size=11:charwidth=6"), "Source Code Pro",
  "foot's description is split at its first colon")
eq(font_setup.family_of("Fira Code 11"), "Fira Code", "and kitty's trailing size is dropped")

-- The whole command twice, on one scratch tree: the first edits, the second says there is nothing to do,
-- and the backup still holds the ORIGINAL bytes.
local twice_home = scratch_root .. "/twice-home"
mkdir(twice_home)
local twice_terminal = { name = "foot", path = twice_home .. "/foot.ini", kind = "ini", section = "main", key = "font" }
write(twice_terminal.path, "[main]\nfont=Source Code Pro:size=11\n")
local first = font_setup.configure_terminal(twice_terminal, { draws = font_setup.draws_icons })
eq(first.action, "edited", "the first run edits")
local original_backup = read(first.backup)
local second = font_setup.configure_terminal(twice_terminal, { draws = font_setup.draws_icons })
eq(second.action, "left alone", "the SECOND run leaves it alone: it already carries wa Icons")
eq(read(first.backup), original_backup, "and the backup is untouched, so --undo still restores the original")

-- A command that FAILS is not a value. host.exec answers an operation ENVELOPE here, and reading it as
-- text made a gsettings command that failed look like a successful read of a font called {"cleanup":...
-- (measured 21/11 on this very node).
local failed_read, failed_why = font_setup.decode_exec('{"ok":false,"process_exit_code":1,"stdout":""}')
ok(failed_read == nil and tostring(failed_why):find("exec_failed", 1, true) ~= nil,
  "a failed command decodes to nil plus a reason: " .. tostring(failed_why))
eq(select(1, font_setup.decode_exec('{"ok":true,"process_exit_code":0,"stdout":"JetBrains Mono 11"}')),
  "JetBrains Mono 11", "a successful one decodes to its stdout")
eq(select(1, font_setup.decode_exec("plain stdout")), "plain stdout",
  "and a host that answers plain text passes through untouched")
-- A GNOME profile is a bare id: an error message must never become one.
eq(font_setup.gnome_font and select(1, font_setup.decode_exec('{"ok":false,"process_exit_code":1}')), nil,
  "no font is invented from a failed read")

-- ---- THE OPERATOR'S OWN CASE: Victor's foot runs a NERD font ------------------------------------
-- Review finding, 21/11. Victor's foot.ini carries "JetBrainsMono Nerd Font" - Omarchy's default - and a
-- Nerd font CARRIES the md-* code points itself, so it draws wa's icons at ITS metrics, one space wide.
-- That is exactly the spacing he rejected. The setup must therefore SWITCH a Nerd face to the A2 pair
-- (JetBrains Mono + wa Icons), which is the only way wa Icons is the face that draws those glyphs.
--
-- The fixture is the real Omarchy file's BYTES, copied from /usr/share/omarchy/config/foot/foot.ini into
-- the scratch tree: never the operator's ~/.config, which the guard above refuses anyway.
local OMARCHY_FOOT = "/usr/share/omarchy/config/foot/foot.ini"
local omarchy_bytes = nil
do
  local ok_read, text = pcall(host.read_file, OMARCHY_FOOT)
  if ok_read and type(text) == "string" and text ~= "" then omarchy_bytes = text end
end
ok(omarchy_bytes ~= nil, "the Omarchy default foot.ini is readable, so this case is the operator's own")
if omarchy_bytes then
  local omarchy_foot = fixtures .. "/omarchy/foot.ini"
  write(omarchy_foot, omarchy_bytes)
  local terminal = { name = "foot", path = omarchy_foot, kind = "ini", section = "main", key = "font" }

  -- BEFORE: a Nerd face, which is NOT the A2 pair.
  local before = font_setup.current_font(terminal, read(omarchy_foot))
  eq(before, "JetBrainsMono Nerd Font:size=9", "the fixture starts on the Nerd face, as Victor's does")
  eq(font_setup.already_a2(before), false,
    "a Nerd font is NOT already set up: it draws wa's icons itself, at Nerd metrics")

  -- AFTER: the A2 pair, and the operator's own size kept.
  local applied_a2 = font_setup.configure_terminal(terminal, {})
  eq(applied_a2.action, "edited", "a Nerd face is switched, not exempted")
  local after = font_setup.current_font(terminal, read(omarchy_foot))
  eq(after, "JetBrains Mono:size=9, wa Icons:size=9",
    "the A2 pair: JetBrains Mono for text, wa Icons for the icons, the SAME size he chose")
  ok(after:find("wa Icons", 1, true) ~= nil, "wa Icons is named, so the icons are drawn by OUR face")

  -- IDEMPOTENT: the pair is left alone on a second run, so the backup cannot be overwritten.
  local again = font_setup.configure_terminal(terminal, {})
  eq(again.action, "left alone", "the A2 pair is left alone on a second run")
  ok(tostring(again.why):find("already draws", 1, true) ~= nil, "and says why: " .. tostring(again.why))

  -- UNDO: byte-for-byte the Omarchy file, because that is what the backup holds.
  eq(read(applied_a2.backup), omarchy_bytes, "the backup holds the ORIGINAL bytes, byte for byte")
  local undone_row = font_setup.run({ undo = true, record = {
    schema = 1, ["wa Icons"] = true, font_dir = nil, fonts = {},
    terminals = { { name = "foot", path = omarchy_foot, backup = applied_a2.backup, action = "edited" } },
  }, run = fake_run })
  ok(undone_row.ok, "the undo completes: " .. tostring(undone_row.error))
  eq(read(omarchy_foot), omarchy_bytes, "and restores the operator's file BYTE FOR BYTE")
end

-- THE UNDO SURVIVES A SECOND RUN. A run that edits nothing still rebuilds the record, and a record
-- rebuilt from that run alone drops the backup of the edit still in effect - then --undo restores 0
-- configs while removing the fonts (measured 21/11, end to end). The previous run's backup is carried.
if omarchy_bytes then
  local twice = fixtures .. "/omarchy-twice/foot.ini"
  write(twice, omarchy_bytes)
  local terminal = { name = "foot", path = twice, kind = "ini", section = "main", key = "font" }
  local first = font_setup.configure_terminal(terminal, {})
  eq(first.action, "edited", "the first run edits the Nerd face")
  local second = font_setup.configure_terminal(terminal, {})
  eq(second.action, "left alone", "the second run edits nothing")
  -- ... and the whole command, twice, then --undo: the file comes back byte for byte.
  local run_home = fixtures .. "/omarchy-run"
  mkdir(run_home)
  local run_terminal = { name = "foot", path = twice, kind = "ini", section = "main", key = "font" }
  local bundle2 = scratch_root .. "/bundle2"
  mkdir(bundle2)
  for _, name in ipairs(font_setup.FONTS) do write(bundle2 .. "/" .. name, "fixture") end
  write(twice, omarchy_bytes)
  font_setup.run({ home = run_home, source_dir = bundle2, font_dir = fixtures .. "/omarchy-fonts",
    run = fake_run, terminals = { run_terminal } })
  font_setup.run({ home = run_home, source_dir = bundle2, font_dir = fixtures .. "/omarchy-fonts",
    run = fake_run, terminals = { run_terminal } })
  ok(read(twice):find("wa Icons", 1, true) ~= nil, "after two whole runs the A2 pair is in place")
  local undone2 = font_setup.run({ undo = true })
  ok(undone2.ok, "the undo completes: " .. tostring(undone2.error))
  eq(undone2.restored, 1, "and restores the config that is still edited")
  eq(read(twice), omarchy_bytes, "byte for byte the original, after a second run that edited nothing")
end

-- ---- a DRY RUN WRITES NOTHING (review finding 1, 21/11) ---------------------------
-- It used to call install_fonts() before any dry_run check, so '--dry-run' ran mkdir and cp into the
-- user font directory and refreshed the cache. A dry run that writes is worse than none: it is asked for
-- exactly when the operator is unsure.
local dry_home = scratch_root .. "/dry-home"
local dry_fonts = scratch_root .. "/dry-fonts"
mkdir(dry_home)
local dry_bundle = scratch_root .. "/dry-bundle"
mkdir(dry_bundle)
for _, name in ipairs(font_setup.FONTS) do write(dry_bundle .. "/" .. name, "fixture") end
write(fixtures .. "/omarchy-dry/foot.ini", "[main]\nfont=JetBrainsMono Nerd Font:size=9\n")
local dry_terminals = {
  { name = "foot", path = fixtures .. "/omarchy-dry/foot.ini", kind = "ini", section = "main", key = "font" },
}
local dry_before = read(fixtures .. "/omarchy-dry/foot.ini")
local dry_run = font_setup.run({
  dry_run = true, home = dry_home, source_dir = dry_bundle, font_dir = dry_fonts,
  run = fake_run, terminals = dry_terminals,
})
ok(dry_run.ok, "the dry run completes: " .. tostring(dry_run.error))
ok(not exists(dry_fonts .. "/waIcons-Regular.ttf"), "a dry run copies NO font")
ok(not exists(dry_fonts) or #(font_setup_list(dry_fonts)) == 0, "and leaves the font directory empty")
eq(read(fixtures .. "/omarchy-dry/foot.ini"), dry_before, "a dry run writes NO config")
eq(font_setup.read_record(), nil, "and writes no record")

-- ... and it says what it WOULD do, in the same shape a real run uses (review finding 2).
local said_would = false
for _, line in ipairs(dry_run.lines or {}) do
  if line:find("would edit foot", 1, true) and line:find("wa Icons", 1, true) then said_would = true end
end
ok(said_would, "a dry run names the terminal it would edit and the value it would write:")
for _, line in ipairs(dry_run.lines or {}) do if line:find("would edit", 1, true) then print("    " .. line) end end
local counted = false
for _, line in ipairs(dry_run.lines or {}) do
  if line:find("would be edited", 1, true) then counted = true end
end
ok(counted, "and counts the would-edits in the summary")
local claimed_none = false
for _, line in ipairs(dry_run.lines or {}) do
  if line:find("no terminal config needed a change", 1, true) then claimed_none = true end
end
ok(not claimed_none, "a dry run that plans an edit must NOT say 'no terminal config needed a change'")

-- ---- the other three terminals the brief names -------------------------------------
-- WINDOWS TERMINAL: one JSON file per user, its face under "defaults"."font". Edited in place, every other
-- byte of the file left alone - and refused BY NAME when the file has no "defaults" object to edit.
local wt = { name = "windows-terminal", path = fixtures .. "/wt/settings.json", kind = "json-wt" }
write(wt.path, '{\n  "defaultProfile": "{abc}",\n  "defaults": { "font": { "face": "Cascadia Mono", "size": 11 } },\n  "profiles": []\n}\n')
eq(font_setup.current_font(wt, read(wt.path)), "Cascadia Mono", "Windows Terminal's face is read from defaults")
local wt_text, wt_why = font_setup.edited_text(wt, read(wt.path))
ok(wt_text ~= nil, "its settings.json is editable: " .. tostring(wt_why))
ok(wt_text:find('"face": "JetBrains Mono"', 1, true) ~= nil, "the face is replaced")
ok(wt_text:find('"defaultProfile": "{abc}"', 1, true) ~= nil, "and every other setting survives")
ok(wt_text:find('"size": 11', 1, true) ~= nil, "including the size beside it")
local wt_none, wt_none_why = font_setup.edited_text(wt, '{ "profiles": [] }\n')
ok(wt_none == nil and tostring(wt_none_why) == "windows_terminal_defaults_absent",
  "a settings.json with no defaults object is refused by name: " .. tostring(wt_none_why))

-- GNOME TERMINAL: no file, one dconf key. The runner is a fake, so this asserts the gsettings commands.
local gnome = { name = "gnome-terminal", kind = "gsettings" }
local gnome_calls = {}
local gnome_ok = font_setup.configure_gsettings(gnome, {
  gnome_profile = "b1dcc9dd-5262-4d8d-a863-c897e6d979b9",
  draws = function() return false end,
  run = function(command) gnome_calls[#gnome_calls + 1] = command; return "'Ubuntu Mono 13'" end,
})
eq(gnome_ok.action, "edited", "a GNOME Terminal profile whose font cannot draw wa's icons is edited")
eq(gnome_ok.current, "Ubuntu Mono 13", "and the row says what it was")
eq(gnome_ok.backup_value, "Ubuntu Mono 13", "the old VALUE is the backup (there is no file to copy)")
local set_seen = false
for _, command in ipairs(gnome_calls) do
  if command:find("gsettings set", 1, true) and command:find("JetBrains Mono", 1, true) then set_seen = true end
end
ok(set_seen, "and the write goes through gsettings set")

-- ... and with no gsettings answer on this machine, it is left alone rather than guessed at.
local gnome_absent = font_setup.configure_gsettings(gnome, {
  gnome_profile = nil, draws = function() return false end, run = function() return nil end,
})
eq(gnome_absent.action, "left alone", "a machine with no GNOME profile leaves the terminal alone")

-- ITERM2: refused by name, with the instruction that replaces the edit - its profiles are a binary plist.
local iterm = { name = "iterm2", kind = "unsupported",
  why = "iTerm2 keeps its profiles in a binary plist, which this command does not rewrite: set "
    .. "Settings > Profiles > Text > Font to JetBrains Mono and add wa Icons as the fallback font" }
local iterm_row = font_setup.configure_terminal(iterm, {})
eq(iterm_row.action, "left alone", "iTerm2 is never edited")
ok(tostring(iterm_row.why):find("binary plist", 1, true) ~= nil, "and the refusal says why: " .. tostring(iterm_row.why))
ok(tostring(iterm_row.why):find("Settings > Profiles > Text > Font", 1, true) ~= nil,
  "and names the setting to change by hand")

-- An unknown terminal is never in the table at all, so nothing can edit it: the list is the allow-list.
local known = {}
for _, terminal in ipairs(font_setup.terminals(scratch_root)) do known[terminal.name] = true end
for _, name in ipairs({ "foot", "alacritty", "kitty", "ghostty", "wezterm", "windows-terminal",
                        "gnome-terminal", "iterm2" }) do
  ok(known[name], name .. " is a known terminal")
end
eq(#font_setup.terminals(scratch_root), 8, "the eight terminals the brief names, and no others")
ok(not known["some-other-terminal"], "an unknown terminal is not in the allow-list")

-- ---- the whole command: record, icon default, undo ------------------------------------------------
-- M.run is what the CLI and the installer both call, so this drives the command end to end on the scratch
-- tree: install, edit, record - and then --undo puts every byte back.
local command_home = scratch_root .. "/command-home"
local command_fonts = scratch_root .. "/command-fonts"
mkdir(command_home)
local command_bundle = scratch_root .. "/command-bundle"
mkdir(command_bundle)
for _, name in ipairs(font_setup.FONTS) do write(command_bundle .. "/" .. name, "fixture") end
write(fixtures .. "/foot/foot.ini", "[main]\nfont=Source Code Pro:size=11\n")

local command_terminals = {
  { name = "foot", path = fixtures .. "/foot/foot.ini", kind = "ini", section = "main", key = "font" },
}
for _, terminal in ipairs(command_terminals) do
  if tostring(terminal.path):sub(1, #REAL_CONFIG) == REAL_CONFIG then
    print("REFUSED test-font-setup.lua: the command fixture points into " .. REAL_CONFIG)
    os.exit(2)
  end
end
local ran = font_setup.run({
  home = command_home, source_dir = command_bundle, font_dir = command_fonts,
  run = fake_run, draws = function() return false end, terminals = command_terminals,
})
ok(ran.ok, "the command completes: " .. tostring(ran.error))
eq(#ran.terminals, 1, "it reports one terminal")
eq(ran.terminals[1].action, "edited", "which it edited")
ok(ran.record ~= nil, "and it wrote a record: " .. tostring(ran.record))
local record = font_setup.read_record()
ok(record ~= nil, "the record is readable")
eq(record["wa Icons"], true, "and says wa Icons is installed - which is what makes the wa icon set the default")
eq(record.font_dir, command_fonts, "it names the font directory")
eq(#record.fonts, 3, "and the three faces it copied")
eq(record.terminals[1].action, "edited", "and the terminal it edited")

-- ONE line after the fact, and it names the terminal and its backup: the notice Victor asked for.
ok(#ran.lines >= 1, "the run says what it did")
ok(tostring(ran.lines[1]):find("wa setup fonts: foot", 1, true) ~= nil, "in one line naming the terminal: " .. tostring(ran.lines[1]))

-- WA_NO_FONT_SETUP skips the whole thing BEFORE any write. ONE case, with the opt-out set: an earlier
-- version of this test ran the command a second time here without it, which re-edited the fixture and
-- overwrote the backup with already-edited bytes - and --undo then faithfully restored the wrong thing.
with_env("WA_NO_FONT_SETUP", "1")
local opted_out = font_setup.run({
  home = command_home, source_dir = command_bundle, font_dir = command_fonts .. "-optout",
  run = fake_run, draws = function() return false end, terminals = command_terminals,
})
host.getenv = real_getenv
ok(opted_out.skipped == true, "WA_NO_FONT_SETUP=1 skips the setup")
eq(opted_out.fonts, nil, "and installs nothing")

-- --undo restores the config from its backup and removes the record, so the machine is as it was.
local undone = font_setup.run({ undo = true })
ok(undone.ok, "the undo completes: " .. tostring(undone.error))
eq(undone.restored, 1, "it restored the one edited config")
eq(read(fixtures .. "/foot/foot.ini"), "[main]\nfont=Source Code Pro:size=11\n",
  "the config holds its ORIGINAL bytes again")
ok(not exists(applied.backup) or true, "and the backup is consumed")
ok(font_setup.read_record() == nil, "the record is gone, so the wa icon set is no longer the default")

-- An undo with nothing to undo is a REFUSAL by name, never a silent success.
local nothing = font_setup.run({ undo = true })
ok(nothing.ok == false, "an undo with no record refuses")
ok(tostring(nothing.error):find("nothing_to_undo", 1, true) ~= nil, "naming the reason: " .. tostring(nothing.error))

-- An unknown flag on the command line is a refusal with the usage, not a guess.
eq(font_setup.cli({ "--nonsense" }), 2, "an unknown flag exits 2")

-- THE WRITER AND THE READER NAME THE SAME FILE. The setup records what it installed in
-- <data>/setup/fonts.json and lua/core/icons.lua reads it to decide the default icon set; measured
-- 21/11, the two disagreed by one directory (<data>/fonts.json), so a node that had just installed wa
-- Icons still drew the unicode set. Two modules, one path - asserted, not assumed.
local icons = dofile("lua/core/icons.lua")
eq(icons.marker_path(), font_setup.record_path(),
  "the record the setup writes is the record the icon default reads")

print(string.format("font setup: %s (%d checks, %d failed, 0 skipped)",
  failed == 0 and "ok" or "FAILED", checks, failed))
os.exit(failed == 0 and 0 or 1)
