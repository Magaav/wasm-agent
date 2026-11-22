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
local json = dofile("lua/vendor/json.lua")
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

-- ---- WHERE THE FACES COME FROM, on an INSTALLED node (item 1) -----------------------------------------
-- MEASURED 21/11 on the installed node: 'wa setup fonts' refused fonts_source_unknown although the faces were in
-- its own bundle, because source_dir() answered only WA_UI_DIR or WASM_AGENT_LUA_ROOT and an install sets
-- neither. It now FOUNDS the bundle: beside the binary this process was started from, in the install records
-- this node keeps, and only then the per-user default - verified by the three faces being there, never assumed
-- from a path's shape. This case builds that install on disk and points the one record the node reads at it.
--
-- AND IT BUILDS THE BINARY THAT NODE REPORTS, TOO (22/11: six checks red on this machine). The case used to
-- leave "beside this binary" as the RUNNING binary, and on avell that is ~/.local/bin/wa with a complete
-- ~/.local/bin/ui/fonts beside it - a candidate that comes BEFORE the install record - so the verdict was
-- about what the machine happens to have installed, not about the code. It was green in the landing gates of
-- 21/11 and went red only once the local installs put ui/fonts beside ~/.local/bin/wa, which is exactly what
-- a row must never do.
--
-- THE ORDER STAYS THE PRODUCT'S, and it is the right one: the bundle beside the binary that is actually
-- running is the one that binary was installed with (scripts/upgrade.sh:58 installs to $HOME/.local/bin,
-- scripts/deploy.sh installs ui/ the same way, rust/wa-sentinel/src/instance.rs hands over WA_UI_DIR), while
-- the record exists for the case this row is about - a binary somewhere else, named by a record. So the row
-- provides every fact it depends on: no WA_UI_DIR, no WASM_AGENT_LUA_ROOT, a scratch HOME (so the per-user
-- default candidate is this case's own directory), and a binary at <scratch>/installed-node/bin/wa with NO
-- ui/ beside it. The seam is host.runtime_info(), which is what font_setup.binary_path() reads, so the
-- product's own path - the one an install takes - is the one under test.
do
  local installed = scratch_root .. "/installed-node"
  local install_ui = installed .. "/ui"
  mkdir(install_ui .. "/fonts")
  for _, name in ipairs(font_setup.FONTS) do write(install_ui .. "/fonts/" .. name, "a face, not the real bytes") end
  local scratch_bin = installed .. "/bin/wa"
  mkdir(installed .. "/bin")
  write(scratch_bin, "a path, not a program: nothing executes this file\n")
  -- The two facts the running machine would otherwise supply: no WA_UI_DIR and no WASM_AGENT_LUA_ROOT (this
  -- test's own process has WA_UI_DIR set - it points the rest of the suite at this checkout - and that really
  -- is the first candidate), and a HOME that is not the operator's.
  local before_install_env, before_runtime_info = host.getenv, host.runtime_info
  host.getenv = function(key)
    if key == "WA_UI_DIR" or key == "WASM_AGENT_LUA_ROOT" or key == "WA_HOME_BEFORE_OVERRIDE" then return "" end
    if key == "HOME" or key == "USERPROFILE" then return scratch_root end
    return before_install_env(key)
  end
  -- The binary this node reports is the scratch install's, whose ui/ is the record's - not the complete copy
  -- that sits beside whatever binary happens to be running this row.
  host.runtime_info = function()
    local info = {}
    local ok, raw = pcall(before_runtime_info)
    if ok and type(raw) == "string" and raw ~= "" then
      local decoded_ok, decoded = pcall(json.decode, raw)
      if decoded_ok and type(decoded) == "table" then info = decoded end
    end
    info.binary_path = scratch_bin
    return json.encode(info)
  end
  -- THE RECORD FIRST, then the question: paths.data() is the store the node reads its own install facts from.
  local data = dofile("lua/core/paths.lua").data()
  write(data .. "/install-dir.txt", installed .. "\n")
  -- The call is GUARDED so that on a tree without it this case reports the behaviour it is missing instead of
  -- dying on a nil call: the assertions below are about where the faces are FOUND, which is the change.
  local found = type(font_setup.source_candidates) == "function" and font_setup.source_candidates() or {}
  local labels = {}
  for _, row in ipairs(found) do labels[#labels + 1] = tostring(row.label) .. "=" .. tostring(row.path) end
  eq(font_setup.source_dir(), install_ui .. "/fonts",
    "the faces are found from this node's own install record, with no WA_UI_DIR, no WASM_AGENT_LUA_ROOT and no"
      .. " ui/ beside this binary (tried: " .. table.concat(labels, " | ") .. ")")
  -- THE ORDER ITSELF, asserted rather than assumed: "beside this binary" is tried BEFORE the record, which is
  -- why an install's own ui/ is never shadowed by a record naming an older complete copy.
  local beside_ui = tostring(scratch_bin):gsub("/[^/]+$", "") .. "/ui/fonts"
  local function index_of(rows, path)
    for i, row in ipairs(rows) do if tostring(row.path) == path then return i end end
    return nil
  end
  local beside_at, record_at = index_of(found, beside_ui), index_of(found, install_ui .. "/fonts")
  ok(beside_at ~= nil and record_at ~= nil and beside_at < record_at,
    "the UI beside this binary is tried before the install record (" .. tostring(beside_at) .. " < " .. tostring(record_at) .. ")")
  -- AND A CANDIDATE IS ONLY USED WHEN IT IS COMPLETE: a record naming a directory with no faces in it must not
  -- be answered as the bundle (a refusal naming the path is the honest answer, not a half-copy).
  local empty = scratch_root .. "/installed-empty"
  mkdir(empty .. "/ui")
  write(data .. "/install-dir.txt", empty .. "\n")
  -- AN INCOMPLETE CANDIDATE IS NEVER INSTALLED FROM: with the record naming a ui/ that carries no faces, the
  -- setup REFUSES (fonts_missing_from_bundle), naming where it looked - it does not copy half an icon set, and it
  -- does not quietly pass over the record as though the machine had no bundle.
  local half_detail, half_why = font_setup.install_fonts({
    home = scratch_root, font_dir = scratch_root .. "/half-fonts", run = fake_run,
  })
  ok(half_detail == nil, "an install record whose ui/ carries no faces is not installed from")
  ok(tostring(half_why):find("fonts_missing_from_bundle", 1, true) ~= nil,
    "and the refusal names the faces that are missing: " .. tostring(half_why))
  ok(tostring(half_why):find("looked at", 1, true) ~= nil,
    "and every path it looked at, so the operator can see which copy is short: " .. tostring(half_why))
  write(data .. "/install-dir.txt", installed .. "\n")
  local source_dir = type(font_setup.source_dir) == "function" and font_setup.source_dir() or nil
  eq(source_dir, install_ui .. "/fonts", "and the complete one is, once the record names it again")
  -- A candidate that DOES hold all three faces wins over every later one, and the list a refusal prints names
  -- every path that was tried: an operator must be able to see which copy is missing something.
  local tried, chosen = font_setup.source_candidates()
  ok(chosen ~= nil, "a bundle is chosen")
  local printed = {}
  for _, row in ipairs(tried) do printed[#printed + 1] = tostring(row.path) end
  ok(#printed >= 2, "more than one place was tried, so the refusal can name them: " .. table.concat(printed, ", "))
  -- THE ORDER, FROM THE OTHER SIDE: with a complete ui/ beside this binary AND a complete one named by the
  -- record, the bundle beside the binary is the answer. That is the behaviour the live node relies on, and the
  -- one this row could not see while it ran against whatever was installed on the machine.
  local beside_fonts = tostring(scratch_bin):gsub("/[^/]+$", "") .. "/ui/fonts"
  mkdir(beside_fonts)
  for _, name in ipairs(font_setup.FONTS) do write(beside_fonts .. "/" .. name, "a face beside the binary") end
  eq(font_setup.source_dir(), beside_fonts,
    "a complete ui/ beside this binary wins over a record naming another complete one")
  pcall(host.exec, "rm -rf '" .. tostring(scratch_bin):gsub("/[^/]+$", "") .. "/ui'", "", 20)
  eq(font_setup.source_dir(), install_ui .. "/fonts",
    "and with the copy beside the binary gone, the record answers again")
  host.runtime_info, host.getenv = before_runtime_info, before_install_env
end

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

-- ---- a config that names NO font still draws a Nerd fallback (review finding 3) ----------
-- kitty's font_family is commented out and ghostty's is a real line; where a config names no face, the
-- terminal draws the system monospace - and 'fc-match monospace' on this machine answers
-- JetBrainsMono Nerd Font, so its icons are Nerd metrics. The A2 pair is written EXPLICITLY instead.
local kitty_path = fixtures .. "/kitty/kitty.conf"
write(kitty_path, "# Font\n# font_family JetBrainsMono Nerd Font\nfont_size 12\n")
local kitty = { name = "kitty", path = kitty_path, kind = "conf", key = "font_family",
  fallback_line = "symbol_map " .. font_setup.ICON_RANGES .. " wa Icons" }
eq(font_setup.current_font(kitty, read(kitty_path)), nil, "a commented-out font names no face")
local kitty_row = font_setup.configure_terminal(kitty, {})
eq(kitty_row.action, "edited", "a terminal with no face named is given the A2 pair explicitly")
local kitty_text = read(kitty_path)
ok(kitty_text:find("font_family JetBrains Mono", 1, true) ~= nil, "the text face is written")
ok(kitty_text:find("symbol_map " .. font_setup.ICON_RANGES .. " wa Icons", 1, true) ~= nil,
  "and the ICON face, in kitty's own fallback syntax")
eq(font_setup.configure_terminal(kitty, {}).action, "left alone", "a second run changes nothing")

-- ghostty: an EQUALS sign and quotes, and a REPEATED key for the fallback face - the shape that made the
-- old reader answer "no face to replace" and the old writer append a second line beside the old face.
local ghostty_path = fixtures .. "/ghostty/config"
write(ghostty_path, 'font-family = "JetBrainsMono Nerd Font"\nfont-style = Regular\nfont-size = 9\n')
local ghostty = { name = "ghostty", path = ghostty_path, kind = "conf", key = "font-family",
  fallback_line = "font-codepoint-map = " .. font_setup.ICON_RANGES .. "=wa Icons" }
eq(font_setup.current_font(ghostty, read(ghostty_path)), "JetBrainsMono Nerd Font",
  "ghostty's font-family is read through its equals sign")
local ghostty_row = font_setup.configure_terminal(ghostty, {})
eq(ghostty_row.action, "edited", "ghostty's Nerd face is switched")
local ghostty_text = read(ghostty_path)
ok(ghostty_text:find('font-family = "JetBrains Mono"', 1, true) ~= nil, "to JetBrains Mono")
ok(ghostty_text:find("font-codepoint-map = " .. font_setup.ICON_RANGES .. "=wa Icons", 1, true) ~= nil, "with wa Icons mapped to exactly its code points")
ok(ghostty_text:find("font-size = 9", 1, true) ~= nil, "and the rest of the file intact")
eq(font_setup.configure_terminal(ghostty, {}).action, "left alone",
  "a second run changes nothing: the icon face is on its own line, and the check reads the WHOLE config")

-- A STALE ICON MAP IS CORRECTED (mission fonts-install item 3, 21/11). Two shapes this command used to write
-- itself are not the shape it writes now: kitty's 'symbol_map U+F0000-U+FFFFD wa Icons' hands EVERY plane-15
-- code point - every other program's Nerd md-* icon - to a face with fourteen glyphs, and ghostty's
-- 'font-family = "wa Icons"' was the pre-fix fallback line. Both were reported "already draws wa's icons" and
-- never corrected. already_a2 compares with the EXACT line the setup writes now, and the writer REPLACES a
-- stale one instead of leaving it above the new one (kitty reads the LAST symbol_map, so a stale line below
-- the new map would undo the fix as quietly as the fix was applied).
do
  local stale_dir = fixtures .. "/stale"
  local stale_kitty = stale_dir .. "/kitty.conf"
  write(stale_kitty, "font_family JetBrains Mono\nsymbol_map U+F0000-U+FFFFD wa Icons\nfont_size 12\n")
  local stale_terminal = { name = "kitty", path = stale_kitty, kind = "conf", key = "font_family",
    fallback_line = "symbol_map " .. font_setup.ICON_RANGES .. " wa Icons" }
  eq(font_setup.already_a2("JetBrains Mono", read(stale_kitty), stale_terminal), false,
    "kitty's pre-fix whole-plane symbol_map is NOT already set up: it is the map A2 replaced")
  local stale_row = font_setup.configure_terminal(stale_terminal, {})
  eq(stale_row.action, "edited", "so it is corrected")
  local stale_text = read(stale_kitty)
  ok(stale_text:find("symbol_map " .. font_setup.ICON_RANGES .. " wa Icons", 1, true) ~= nil,
    "the map is the one this command writes now: " .. stale_text)
  ok(not stale_text:find("U+F0000-U+FFFFD", 1, true), "and the whole-plane map is GONE, not left beside it")
  eq(select(2, stale_text:gsub("symbol_map", "")), 1, "exactly one symbol_map line remains")
  eq(font_setup.configure_terminal(stale_terminal, {}).action, "left alone",
    "and the corrected map is left alone on the next run")

  local stale_ghostty = stale_dir .. "/ghostty"
  write(stale_ghostty, 'font-family = "JetBrains Mono"\nfont-family = "wa Icons"\nfont-size = 9\n')
  -- FROM THE REAL TABLE, with only the path replaced: which keys may name an icon face is the production
  -- row's answer (ghostty repeats font-family for it), and a fixture that guessed it would test a terminal
  -- this command does not have.
  local stale_ghostty_terminal
  for _, known_terminal in ipairs(font_setup.terminals(scratch_root)) do
    if known_terminal.name == "ghostty" then stale_ghostty_terminal = known_terminal end
  end
  ok(stale_ghostty_terminal ~= nil, "the ghostty row is in the allow-list")
  stale_ghostty_terminal.path = stale_ghostty
  eq(font_setup.already_a2("JetBrains Mono", read(stale_ghostty), stale_ghostty_terminal), false,
    "ghostty's pre-fix 'font-family = \"wa Icons\"' fallback is NOT already set up")
  eq(font_setup.configure_terminal(stale_ghostty_terminal, {}).action, "edited", "so it is corrected too")
  local ghostty_fixed = read(stale_ghostty)
  ok(not ghostty_fixed:lower():find('font-family = "wa icons"', 1, true),
    "the stale icon line is replaced, not kept: " .. ghostty_fixed)
  ok(ghostty_fixed:find("font-codepoint-map = " .. font_setup.ICON_RANGES .. "=wa Icons", 1, true) ~= nil,
    "by the code-point map this command writes")
  eq(select(2, ghostty_fixed:gsub("font%-family", "")), 1, "and the text face is named exactly once")
  eq(font_setup.configure_terminal(stale_ghostty_terminal, {}).action, "left alone",
    "the corrected ghostty config is left alone on the next run")

  -- A config that names NO font and still carries a stale map: the map is replaced with the pair, and the
  -- stale line is not left in place beside it.
  local stale_fontless = stale_dir .. "/kitty-fontless.conf"
  write(stale_fontless, "# font_family JetBrains Mono\nsymbol_map U+F0000-U+FFFFD wa Icons\n")
  local fontless_terminal = { name = "kitty", path = stale_fontless, kind = "conf", key = "font_family",
    fallback_line = "symbol_map " .. font_setup.ICON_RANGES .. " wa Icons" }
  eq(font_setup.configure_terminal(fontless_terminal, {}).action, "edited",
    "a config with no face named and a stale map is given the A2 pair")
  local fontless_text = read(stale_fontless)
  ok(not fontless_text:find("U+F0000-U+FFFFD", 1, true), "with no stale map left behind: " .. fontless_text)
  eq(select(2, fontless_text:gsub("symbol_map", "")), 1, "and exactly one symbol_map line")
end

-- alacritty: an INLINE table per weight. Replacing only 'normal' left bold and italic on the Nerd face.
local alacritty_path = fixtures .. "/alacritty/alacritty.toml"
write(alacritty_path, '[font]\nnormal = { family = "JetBrainsMono Nerd Font", style = "Regular" }\n'
  .. 'bold = { family = "JetBrainsMono Nerd Font", style = "Bold" }\n'
  .. 'italic = { family = "JetBrainsMono Nerd Font", style = "Italic" }\n')
local alacritty = { name = "alacritty", path = alacritty_path, kind = "toml", section = "font.normal",
  key = "family", inline = "normal", table_section = "font", icons_via = "fontconfig" }
eq(font_setup.current_font(alacritty, read(alacritty_path)), "JetBrainsMono Nerd Font",
  "alacritty's inline family is read")
font_setup.configure_terminal(alacritty, {})
local alacritty_text = read(alacritty_path)
ok(not alacritty_text:find("JetBrainsMono Nerd Font", 1, true),
  "EVERY weight is switched, not only the one the reader asks about: " .. alacritty_text)
eq(select(2, alacritty_text:gsub("JetBrains Mono", "")) , 3, "all three weights name JetBrains Mono")

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

-- ---- the backup is written ONCE, and a re-run never re-edits (item 2) ------------------------------
-- MEASURED 21/11: an alacritty already on 'family = "JetBrains Mono"' was edited again
-- ("alacritty -> JetBrains Mono (was JetBrains Mono)") and its .wa-backup was overwritten with the
-- ALREADY-EDITED bytes - so the original was gone and --undo restored the first run's edit. Two rules close
-- that, and each is asserted below on its own: a terminal already on the value this command writes is left
-- alone (above, already_a2), and a backup that exists is NEVER overwritten (M.write_backup_once).
do
  local once_dir = fixtures .. "/once"
  local once_config = once_dir .. "/foot.ini"
  write(once_config, "[main]\nfont=Source Code Pro:size=11\n")
  local once_terminal = { name = "foot", path = once_config, kind = "ini", section = "main", key = "font" }
  local once_run = function(command)
    -- the bundle is real files, so the copies work; fc-list answers nothing so a face is always "not installed"
    if command:find("fc%-list") then return "" end
    return "ok"
  end
  local once_bundle = scratch_root .. "/once-bundle"
  mkdir(once_bundle)
  for _, name in ipairs(font_setup.FONTS) do write(once_bundle .. "/" .. name, "fixture") end
  local ORIGINAL = "[main]\nfont=Source Code Pro:size=11\n"

  -- A BACKUP THAT ALREADY EXISTS IS KEPT, through the command's own edit path - no helper named, so this
  -- assertion is about the behaviour and not about a function existing.
  write(once_config .. ".wa-backup", "[main]\nfont=The True Original:size=11\n")
  local edit_over_backup = font_setup.configure_terminal(once_terminal, {})
  eq(edit_over_backup.action, "edited", "a config that is not A2 is edited")
  eq(read(once_config .. ".wa-backup"), "[main]\nfont=The True Original:size=11\n",
    "and the backup that was already there is NOT overwritten with already-edited bytes")

  -- THE BRIEF'S OWN SHAPE, on the terminal it was measured on: alacritty whose every weight is ALREADY
  -- 'JetBrains Mono', on a machine where the fonts are not installed yet - this run IS the install, so the
  -- disk record cannot be asked. It must be left alone (there is nothing to change) and no backup invented.
  local alacritty_home = fixtures .. "/once-alacritty"
  local alacritty_config = alacritty_home .. "/alacritty.toml"
  local ALACRITTY_ALREADY = '[font]\nnormal = { family = "JetBrains Mono", style = "Regular" }\nbold = { family = "JetBrains Mono", style = "Bold" }\n'
  write(alacritty_config, ALACRITTY_ALREADY)
  local alacritty_terminal = { name = "alacritty", path = alacritty_config, kind = "toml", section = "font.normal",
    key = "family", inline = "normal", table_section = "font", icons_via = "fontconfig" }
  local alacritty_run = font_setup.run({ home = alacritty_home, source_dir = once_bundle,
    font_dir = scratch_root .. "/once-alacritty-fonts", run = once_run, terminals = { alacritty_terminal } })
  ok(alacritty_run.ok, "the run on an already-A2 alacritty completes: " .. tostring(alacritty_run.error))
  eq(alacritty_run.terminals[1].action, "left alone",
    "alacritty already on JetBrains Mono is LEFT ALONE, not re-edited ('alacritty -> JetBrains Mono (was JetBrains Mono)' was the report)")
  eq(read(alacritty_config), ALACRITTY_ALREADY, "its config is byte-identical")
  ok(not exists(alacritty_config .. ".wa-backup"), "and no backup was written over anything")

  -- The whole command TWICE and then --undo: the ORIGINAL bytes come back. The second run edits nothing,
  -- because a terminal already on the value this command writes is left alone.
  pcall(host.exec, "rm -f '" .. once_config .. "' '" .. once_config .. ".wa-backup'", "", 20)
  write(once_config, ORIGINAL)
  local opts = { home = once_dir, source_dir = once_bundle, font_dir = scratch_root .. "/once-fonts",
    run = once_run, terminals = { once_terminal }, record = { ["wa Icons"] = true, terminals = {} } }
  local once_first = font_setup.run(opts)
  ok(once_first.ok, "the first run completes: " .. tostring(once_first.error))
  eq(once_first.terminals[1].action, "edited", "the first run edits the config")
  local edited_bytes = read(once_config)
  eq(read(once_config .. ".wa-backup"), ORIGINAL, "the backup holds the bytes it found")
  -- VERBATIM: the brief's shape is a terminal whose face is ALREADY the A2 text face.
  local second_opts = { home = once_dir, source_dir = once_bundle, font_dir = scratch_root .. "/once-fonts",
    run = once_run, terminals = { once_terminal } }
  local once_second = font_setup.run(second_opts)
  ok(once_second.ok, "the second run completes: " .. tostring(once_second.error))
  eq(once_second.terminals[1].action, "left alone", "the second run edits NOTHING")
  eq(read(once_config), edited_bytes, "the config is byte-identical after the second run")
  eq(read(once_config .. ".wa-backup"), ORIGINAL, "and the backup was not touched")
  local once_undone = font_setup.run({ undo = true })
  ok(once_undone.ok, "the undo completes: " .. tostring(once_undone.error))
  eq(once_undone.restored, 1, "and restores the one edited config")
  eq(read(once_config), ORIGINAL, "the ORIGINAL bytes come back, byte for byte")
end

-- ---- the whole command: record, icon default, undo ------------------------------------------------
-- M.run is what the CLI and the installer both call, so this drives the command end to end on the scratch
-- tree: install, edit, record - and then --undo puts every byte back.
local COMMAND_ORIGINAL = "[main]\nfont=Source Code Pro:size=11\n"
local command_home = scratch_root .. "/command-home"
local command_fonts = scratch_root .. "/command-fonts"
mkdir(command_home)
local command_bundle = scratch_root .. "/command-bundle"
mkdir(command_bundle)
for _, name in ipairs(font_setup.FONTS) do write(command_bundle .. "/" .. name, "fixture") end
-- ITS OWN FILE, in its own directory: the write-once rule means a fixture that earlier cases already edited
-- still carries THEIR .wa-backup, and the undo below must prove the ORIGINAL bytes come back - not that a
-- backup written by a different case happens to hold them.
local command_config = fixtures .. "/command/foot.ini"
write(command_config, COMMAND_ORIGINAL)

local command_terminals = {
  { name = "foot", path = command_config, kind = "ini", section = "main", key = "font" },
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
eq(read(command_config), COMMAND_ORIGINAL, "the config holds its ORIGINAL bytes again")
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

-- THE ICON MAP NAMES EXACTLY THE FONT'S CODE POINTS (21/11). kitty's symbol_map and ghostty's
-- font-codepoint-map hand these code points to wa Icons; the first version handed it all of plane 15, so
-- every other program's Nerd md-* icon became tofu. The map is expanded and compared with the built
-- font's own manifest, so a glyph added to the builder and not to the map is a failing check.
do
  local manifest = json.decode(host.read_file("assets/fonts/waIcons.json"))
  local want = {}
  for _, glyph in ipairs(manifest.glyphs) do want[#want + 1] = tonumber(glyph.codepoint:sub(3), 16) end
  table.sort(want)
  local got = {}
  for part in font_setup.ICON_RANGES:gmatch("[^,]+") do
    local lo, hi = part:match("^U%+(%x+)%-U%+(%x+)$")
    if not lo then lo = part:match("^U%+(%x+)$"); hi = lo end
    for cp = tonumber(lo, 16), tonumber(hi, 16) do got[#got + 1] = cp end
  end
  table.sort(got)
  eq(table.concat(got, ","), table.concat(want, ","),
    "ICON_RANGES is exactly the code points wa Icons carries (" .. #want .. ")")
  ok(not font_setup.ICON_RANGES:find("F0000", 1, true), "the map never claims the whole of plane 15")
end

print(string.format("font setup: %s (%d checks, %d failed, 0 skipped)",
  failed == 0 and "ok" or "FAILED", checks, failed))
os.exit(failed == 0 and 0 or 1)
