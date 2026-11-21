-- 'wa setup fonts': install wa's two faces for this user, and give the terminal that draws wa's
-- status rows the face that has wa's icons (item 3 of the wa-fonts mission, Victor 19/11).
--
-- WHAT IT DOES, in this order:
--   1. copies waIcons-Regular.ttf and the two JetBrains Mono weights into the USER font directory
--      (Linux ~/.local/share/fonts, macOS ~/Library/Fonts, Windows %LOCALAPPDATA%\\Microsoft\\Windows\\Fonts)
--      and refreshes the font cache where the OS has one (fc-cache on Linux);
--   2. for a KNOWN terminal whose config already exists, adds wa Icons as the FALLBACK face - and only
--      when the face it draws today cannot draw wa's icons, measured, never assumed;
--   3. writes a record of what it did (/setup/fonts.json), which is what makes the wa icon set the
--      default for the rows (lua/core/icons.lua reads it) and what 'wa setup fonts --undo' reverses.
--
-- NO PROMPT (Victor, 19/11 09:45: consent is friction). Every edit is backed up first, leaves ONE line
-- behind after the fact, and is reversed by --undo. An unknown terminal, or a known one whose coverage
-- cannot be measured on this OS, is NOT edited: a config edited on a guess is a terminal that renders
-- worse than before, and 'unknown is not yes' applies to a font as much as to a check.
--
-- WHY THE COPY GOES THROUGH host.exec AND NOT host.write_file: a font is binary, and host.write_file
-- takes a UTF-8 TEXT string (rust/wa-capabilities/src/host.rs). Reading the font with host.read_file is
-- refused for the same reason (read_file_not_text). So the bytes are moved by the OS's own copy, which
-- is also the only path that can SET the permissions a font directory wants.
local json = dofile("lua/vendor/json.lua")

local M = {}

-- The faces this command installs, in the order the record lists them.
M.FONTS = { "waIcons-Regular.ttf", "JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf" }

-- THE CODE POINTS wa Icons ACTUALLY CARRIES, as ranges - NOT the whole of plane 15.
-- Review finding 1, 21/11: the setup wrote 'symbol_map U+F0000-U+FFFFD wa Icons' for kitty, which hands
-- EVERY plane-15 code point - every Nerd md-* icon any other program uses - to a face that has fourteen
-- glyphs, so those other icons turned into tofu. The map names only what the font has.
--
-- Derived from assets/fonts/waIcons.json (the built font's own cmap), and asserted equal to it by
-- scripts/test-font-setup.lua: a glyph added to the builder and not to this line is a failing test, not a
-- silent half-map.
M.ICON_RANGES = "U+F012C,U+F01BC,U+F0450,U+F051B,U+F0766,U+F0A9E-U+F0AA5,U+F0DFA"
M.ICON_FAMILY = "wa Icons"
M.TEXT_FAMILY = "JetBrains Mono"

-- The opt-out (WA_NO_FONT_SETUP=1, or the installer's flag). Read here so the installer and the command
-- ask the same question.
function M.disabled()
  local value = tostring(host.getenv("WA_NO_FONT_SETUP") or ""):lower():gsub("%s", "")
  return value == "1" or value == "true" or value == "yes" or value == "on"
end

-- The operator's OWN home, which is not this node's state directory: the host rewrites HOME to
-- WASM_AGENT_HOME at startup, and a font installed under a node's state dir is a font no terminal loads.
function M.user_home()
  local before = host.getenv("WA_HOME_BEFORE_OVERRIDE")
  if before and before ~= "" then return (before:gsub("\\", "/"):gsub("/+$", "")) end
  local home = host.getenv("HOME") or host.getenv("USERPROFILE") or ""
  return (tostring(home):gsub("\\", "/"):gsub("/+$", ""))
end

function M.os()
  local ok, platform = pcall(dofile, "lua/core/platform.lua")
  if ok and type(platform) == "table" and type(platform.os) == "function" then
    local read_ok, value = pcall(platform.os)
    if read_ok and type(value) == "string" and value ~= "" then return value:lower() end
  end
  return "unknown"
end

-- Where this OS keeps a USER font. A per-user location is the whole point: installing into
-- /usr/share/fonts needs root, and a setup that needs root is a setup nobody runs.
function M.font_dir(os, home)
  os, home = tostring(os or M.os()):lower(), tostring(home or M.user_home())
  if os:find("windows", 1, true) then
    local local_app = host.getenv("LOCALAPPDATA")
    if local_app and local_app ~= "" then return (local_app:gsub("\\", "/"):gsub("/+$", "")) .. "/Microsoft/Windows/Fonts" end
    return home .. "/AppData/Local/Microsoft/Windows/Fonts"
  end
  if os:find("darwin", 1, true) or os:find("mac", 1, true) then return home .. "/Library/Fonts" end
  return home .. "/.local/share/fonts"
end

-- THE PATH OF THIS BINARY, as the kernel reports it, or nil.
--
-- host.runtime_info() answers the running process's own executable (rust/wa-capabilities/src/host.rs) - the
-- one fact an installed node has about where its bundle lives that no environment variable can take away.
-- Reading it is what makes 'wa setup fonts' work on an install, where neither WA_UI_DIR nor
-- WASM_AGENT_LUA_ROOT is set (measured 21/11 on the installed node: the command refused
-- fonts_source_unknown while the faces sat in the bundle).
function M.binary_path()
  if not (host and host.runtime_info) then return nil end
  local ok, raw = pcall(host.runtime_info)
  if not ok or type(raw) ~= "string" or raw == "" then return nil end
  local decoded_ok, info = pcall(json.decode, raw)
  if not decoded_ok or type(info) ~= "table" then return nil end
  local path = info.binary_path
  if type(path) ~= "string" or path == "" then return nil end
  return (path:gsub("\\", "/"))
end

-- One path with no trailing separator, so two spellings of one directory compare equal.
local function clean_dir(value)
  local text = tostring(value or ""):gsub("\\", "/"):gsub("/+$", "")
  return text
end
M.clean_dir = clean_dir

-- The directory holding the install record this node's supervisor writes (installed.txt), asked for by the
-- one place that decides it: paths.data()/<...>, then the install dirs a record names.
--
-- Every candidate below is a DIR to try, never a claim that it is the bundle: the caller keeps the one that
-- actually holds the faces. 'label' is what a refusal prints, so an operator sees the exact path that failed
-- instead of a sentence about a variable they may not have set.
function M.ui_candidates(opts)
  opts = opts or {}
  local out = {}
  local seen = {}
  local function add(label, dir)
    local cleaned = clean_dir(dir)
    if cleaned == "" or seen[cleaned] then return end
    seen[cleaned] = true
    out[#out + 1] = { label = label, dir = cleaned }
  end
  -- 1. THE SUPERVISOR'S OWN ANSWER (rust/wa-sentinel/src/instance.rs sets WA_UI_DIR for the node it starts).
  add("WA_UI_DIR", host.getenv("WA_UI_DIR"))
  -- 2. A CHECKOUT: its Lua root carries ui/fonts.
  local root = clean_dir(host.getenv("WASM_AGENT_LUA_ROOT"))
  if root ~= "" then add("WASM_AGENT_LUA_ROOT/ui", root .. "/ui") end
  -- 3. THE INSTALL THIS BINARY LIVES IN: <dir of wa>/ui, which is what scripts/deploy.sh and
  --    scripts/upgrade.sh install beside the binary.
  local binary = M.binary_path()
  local install
  if binary and binary:find("/[^/]+$") then
    install = binary:gsub("/[^/]+$", "")
    add("the UI beside this binary (" .. binary .. ")", install .. "/ui")
  end
  -- 4. THE RECORD: install-dir.txt in this node's state, and the installed.txt records a deploy writes.
  --    These are where an install says where it put things when the unit or the supervisor runs a binary
  --    somewhere else (measured 21/11 on this machine: the node is ~/.local/bin/wa serving the UI from
  --    ~/.local/share/wasm-agent/ui, named by its unit's --ui and by both records).
  local ok_paths, paths = pcall(dofile, "lua/core/paths.lua")
  if ok_paths and type(paths) == "table" then
    local data = clean_dir(paths.data())
    if data ~= "" then
      for _, name in ipairs({ "/install-dir.txt" }) do
        local recorded = host.read_file(data .. name)
        if type(recorded) == "string" then
          local first = recorded:gsub("^%s+", ""):match("^[^\r\n]+")
          if first and clean_dir(first) ~= "" then add("the install record " .. data .. name, clean_dir(first) .. "/ui") end
        end
      end
      for _, name in ipairs({ "/installed.txt", "/startup/installed.txt" }) do
        local record = host.read_file(data .. name)
        if type(record) == "string" then
          for line in record:gmatch("[^\n]+") do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.+)$")
            if key == "install_dir" or key == "service_install_dir" then
              add("the install record " .. data .. name .. " (" .. key .. ")", clean_dir(value) .. "/ui")
            end
          end
        end
      end
    end
  end
  -- 5. WHERE A DEPLOY ON THIS OS INSTALLS WHEN NOTHING ELSE ANSWERS, still verified before it is used.
  if install then add("the install's parent beside this binary", clean_dir(install) .. "/../share/wasm-agent/ui") end
  add("the per-user install default", M.user_home() .. "/.local/share/wasm-agent/ui")
  return out
end

-- The directory the bundle's faces are served from, FOUND rather than assumed.
--
-- WHAT WAS WRONG (mission fonts-install item 1, measured 21/11): this answered only WA_UI_DIR or
-- WASM_AGENT_LUA_ROOT and nil otherwise, so an INSTALLED node - where neither is set and the bundle lives
-- beside the binary - refused fonts_source_unknown although it had the faces. The candidates above are tried
-- in order and the first one that actually holds ALL THREE faces wins; nothing is assumed from a path's
-- shape. Returns the fonts directory, or nil plus the list of paths that were tried (so the refusal can
-- print them).
function M.source_candidates(opts)
  opts = opts or {}
  if opts.source_dir then
    local direct = clean_dir(opts.source_dir)
    -- An explicit source_dir is the caller's answer, honoured as given: a test hands it a bundle directly.
    return { { label = "source_dir", dir = direct } }, direct
  end
  local tried, first_fonts = {}, nil
  for _, candidate in ipairs(M.ui_candidates(opts)) do
    local fonts = candidate.dir:gsub("/fonts$", "") .. "/fonts"
    tried[#tried + 1] = { label = candidate.label, path = fonts }
    local complete = true
    for _, name in ipairs(M.FONTS) do
      local kind = host.path_kind and host.path_kind(fonts .. "/" .. name) or (host.read_file(fonts .. "/" .. name) and "file" or "missing")
      if kind ~= "file" then complete = false end
    end
    if complete then return tried, fonts end
    if not first_fonts then first_fonts = fonts end
  end
  -- Nothing complete: answer the FIRST path tried, so the caller's own 'fonts_missing_from_bundle' names a
  -- real place instead of nothing - and the refusal list says every place that was looked at.
  return tried, first_fonts
end

function M.source_dir(opts)
  local _, fonts = M.source_candidates(opts)
  return fonts
end

-- ---- the terminals --------------------------------------------------------------------------------
--
-- ONE row per terminal: its config path and the key that names its font. A terminal NOT in this table
-- is never edited - this command touches what it can measure and nothing else.
function M.terminals(home)
  -- AN EXPLICIT HOME DECIDES EVERY PATH, and XDG_CONFIG_HOME is only consulted for the REAL home.
  --
  -- MEASURED 21/11, and it cost the operator's own file: this environment sets XDG_CONFIG_HOME to
  -- /home/victor/.config, so a caller that handed over a scratch home still got the operator's real
  -- config paths - the test edited ~/.config/foot/foot.ini. A home argument that is not allowed to
  -- decide the whole path is not a home argument; the caller passing one is asking "what would this
  -- machine do for THAT home", and a test asking that must never reach the operator's files.
  local explicit = home ~= nil
  home = tostring(home or M.user_home())
  local config_home
  if explicit then
    config_home = home .. "/.config"
  else
    config_home = host.getenv("XDG_CONFIG_HOME")
    if not config_home or config_home == "" then config_home = home .. "/.config" end
  end
  config_home = tostring(config_home):gsub("\\", "/"):gsub("/+$", "")
  return {
    { name = "foot", path = config_home .. "/foot/foot.ini", kind = "ini", section = "main", key = "font" },
    { name = "alacritty", path = config_home .. "/alacritty/alacritty.toml", kind = "toml", section = "font.normal", key = "family",
      inline = "normal", table_section = "font", icons_via = "fontconfig" },
    { name = "kitty", path = config_home .. "/kitty/kitty.conf", kind = "conf", key = "font_family",
      fallback_line = "symbol_map " .. M.ICON_RANGES .. " wa Icons",
      -- the keys a line may use to name the ICON face (see M.names_icon_face): kitty maps code points on a
      -- symbol_map line, never on the font_family line itself.
      icon_keys = { "symbol_map" } },
    -- ghostty names the mapping itself: font-codepoint-map = <ranges>=<family> (review finding 2). It ALSO
    -- repeats font-family to name a fallback face, which is why that key is an icon key here too: a writer
    -- that read such a line as the text face wrote the text face twice (measured 21/11).
    { name = "ghostty", path = config_home .. "/ghostty/config", kind = "conf", key = "font-family",
      fallback_line = "font-codepoint-map = " .. M.ICON_RANGES .. "=wa Icons",
      icon_keys = { "font-codepoint-map", "font-family" } },
    { name = "wezterm", path = config_home .. "/wezterm/wezterm.lua", kind = "lua-wezterm" },
    -- Windows Terminal keeps one JSON file per user, and its default profile font is a key in it.
    { name = "windows-terminal", path = M.windows_terminal_path(home), kind = "json-wt" },
    -- GNOME Terminal has no config file: its profiles live in dconf, so the font is one key, read and
    -- written through gsettings. The backup is the old VALUE, recorded in the record --undo reads.
    { name = "gnome-terminal", path = nil, kind = "gsettings" },
    -- iTerm2's settings are a BINARY plist. Rewriting it wholesale to change one font is the kind of
    -- edit that cannot be backed up as text and cannot be verified after the write, so this command
    -- refuses it BY NAME and prints what to do instead: "unknown is not yes" applies to a GUI profile
    -- as much as to a coverage question.
    { name = "iterm2", path = nil, kind = "unsupported",
      why = "iTerm2 keeps its profiles in a binary plist, which this command does not rewrite: set "
        .. "Settings > Profiles > Text > Font to JetBrains Mono and add wa Icons as the fallback font" },
  }
end

-- Windows Terminal's settings.json, per user. Named here so a test can drive the path without a Windows
-- install (the directory is %LOCALAPPDATA%, or the home's AppData\Local on a node that does not set it).
function M.windows_terminal_path(home)
  home = tostring(home or M.user_home())
  local local_app = host.getenv("LOCALAPPDATA")
  local base
  if local_app and local_app ~= "" then
    base = tostring(local_app):gsub("\\", "/"):gsub("/+$", "")
  else
    base = home .. "/AppData/Local"
  end
  return base .. "/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
end

-- A terminal's KEY, escaped for use inside a Lua pattern: '-' is a quantifier and '%' starts an escape,
-- so 'font-family' used raw never matches itself (measured 21/11: ghostty read as having no font).
function M.key_pattern(key)
  return (tostring(key or ""):gsub("[%p]", function(char) return "%" .. char end))
end

-- A font NAME as a shell word: letters, digits, dot, dash, underscore and space only. An allow-list,
-- not an escape: these names come from a config file, and a config file is not to be trusted with a
-- shell. Anything else is dropped, so no quoting rule has to be right.
function M.safe_name(name)
  return (tostring(name or ""):gsub("[^%w%.%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ONE answer shape for a command, on every host.
--
-- MEASURED 21/11 on this node: host.exec does NOT answer the command's stdout, it answers a JSON
-- OPERATION ENVELOPE - {"ok":true,"stdout":"...","stderr":"...","process_exit_code":0} - and a command
-- that failed answers ok:false with an EMPTY stdout. Treating that envelope as text made
-- 'gsettings get ...' look like a successful read whose value was the whole envelope, so a GNOME profile
-- that does not exist on this machine was "read", "measured" and then written to. A command that failed
-- is not a value: this decodes the envelope, and answers nil plus a named reason for anything that is
-- not ok. A host that returns plain stdout (older binaries, a test's own stub) passes through untouched.
local function decode_exec(answer)
  if type(answer) ~= "string" then return nil, "exec_no_answer" end
  local trimmed = answer:gsub("^%s+", "")
  if trimmed:sub(1, 1) == "{" then
    local decoded_ok, value = pcall(json.decode, trimmed)
    if decoded_ok and type(value) == "table" and value.ok ~= nil then
      if value.ok == true then return tostring(value.stdout or ""), nil end
      return nil, "exec_failed:" .. tostring(value.process_exit_code or "no_exit")
    end
  end
  return answer, nil
end
M.decode_exec = decode_exec

local function run_shell(command)
  local ok, out = pcall(host.exec, command, "", 20)
  if not ok then return nil, "exec_unavailable" end
  return decode_exec(out)
end
M.run_shell = run_shell

-- wezterm's family, read from the CONSTRUCTOR as well as from a plain table: both
--   font = wezterm.font({ family = "X" })
--   font = { family = "X" }
-- are configs an operator writes, and both name the same face.
function M.wezterm_family(text)
  text = tostring(text or "")
  local double = text:match('font%s*=%s*[^{]*{[^}]-family%s*=%s*"([^"]*)"')
  local single = text:match("font%s*=%s*[^{]*{[^}]-family%s*=%s*'([^']*)'")
  return double or single
end

-- What the config currently names as its text font, or nil when it names none (the terminal's own
-- default - and a default is not a decision this command overrides).
function M.current_font(terminal, text)
  if not text then return nil end
  text = tostring(text)
  if terminal.kind == "ini" then
    local section, found = nil, nil
    for line in text:gmatch("[^\n]+") do
      local header = line:match("^%s*%[([^%]]+)%]")
      if header then section = header end
      if section == terminal.section then
        local value = line:match("^%s*" .. M.key_pattern(terminal.key) .. "%s*=%s*(.-)%s*$")
        if value and value ~= "" then found = value end
      end
    end
    return found
  elseif terminal.kind == "toml" then
    -- TWO SHAPES, both real (this machine's alacritty.toml, 21/11):
    --   [font.normal]   family = "X"
    --   [font]          normal = { family = "X", style = "Regular" }
    local section, found = nil, nil
    for line in text:gmatch("[^\n]+") do
      local header = line:match("^%s*%[([^%]]+)%]")
      if header then section = header end
      if section == terminal.section then
        local value = line:match('^%s*' .. M.key_pattern(terminal.key) .. '%s*=%s*"([^"]*)"')
        if value and value ~= "" then found = value end
      end
      local parent, rest = line:match("^%s*([%w_%-]+)%s*=%s*{(.*)$")
      if parent and parent == (terminal.inline or "normal") and section == (terminal.table_section or "font") then
        local value = rest:match('family%s*=%s*"([^"]*)"')
        if value and value ~= "" then found = value end
      end
    end
    return found
  elseif terminal.kind == "conf" then
    -- BOTH separators these files use: 'font_family X' (kitty) and 'font-family = "X"' (ghostty).
    local found = nil
    for line in text:gmatch("[^\n]+") do
      if not line:match("^%s*#") then
        local value = line:match("^%s*" .. M.key_pattern(terminal.key) .. "%s*=%s*(.-)%s*$")
          or line:match("^%s*" .. M.key_pattern(terminal.key) .. "%s+([^#]+)")
        if value and value ~= "" then
          value = value:gsub('^"', ""):gsub('"$', ""):gsub("%s+$", "")
          -- FIRST wins: a terminal names its TEXT face first and its fallbacks after (ghostty repeats
          -- font-family for exactly that), so the last match is a fallback, not the face.
          if value ~= "" and found == nil then found = value end
        end
      end
    end
    return found
  elseif terminal.kind == "lua-wezterm" then
    return M.wezterm_family(text)
  elseif terminal.kind == "json-wt" then
    return M.wt_font(text)
  end
  return nil
end

-- Windows Terminal: the default profile's font face, read from the settings.json an operator already has.
function M.wt_font(text)
  text = tostring(text or "")
  local at = text:find('"defaults"')
  if not at then return nil end
  local block = text:sub(at, math.min(#text, at + 2000))
  local font_at = block:find('"font"')
  if not font_at then return nil end
  local face = block:sub(font_at):match('"face"%s*:%s*"([^"]*)"')
  return face
end

-- ... and written back into the same defaults object, leaving every other setting byte-for-byte alone.
function M.wt_edited(text, value)
  text = tostring(text or "")
  local out, count = text:gsub('("defaults"%s*:%s*{.-"font"%s*:%s*{.-"face"%s*:%s*")([^"]*)(")',
    "%1" .. value .. "%3", 1)
  if count > 0 then return out end
  -- No font.face under defaults yet: add one, so a fresh install gets the face too.
  local with_font, added = text:gsub('("defaults"%s*:%s*{)', '%1"font":{"face":"' .. value .. '"},', 1)
  if added > 0 then return with_font end
  return nil, "windows_terminal_defaults_absent"
end

-- GNOME Terminal through gsettings: the default profile's id, then that profile's font.
function M.gnome_profile()
  -- THE READ MUST FAIL CLOSED. A machine with no GNOME Terminal (this one) fails the command; that is
  -- nil, and a nil profile means the terminal is left alone - never a profile name invented from an
  -- error message (measured 21/11: the whole JSON envelope was taken as the profile id).
  local out = run_shell("gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null")
  if type(out) ~= "string" or out == "" then return nil end
  local profile = out:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^'", ""):gsub("'$", "")
  -- A profile id is a bare UUID or a short name. Anything with a brace, a quote or whitespace in it is
  -- not one, and a value that is not one is refused rather than pasted into a command.
  if profile == "" or #profile > 64 or profile:find("[%s{}%[%]]") then return nil end
  return profile
end

function M.gnome_key(profile)
  return "org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:" .. tostring(profile) .. "/"
end

function M.gnome_font(profile)
  local out = run_shell("gsettings get " .. M.gnome_key(profile) .. " font 2>/dev/null")
  if type(out) ~= "string" or out == "" then return nil end
  local font = out:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^'", ""):gsub("'$", "")
  -- A font DESCRIPTION, not whatever came back: a value with a brace is a message, not a font.
  if font == "" or font:find("[{}]") then return nil end
  return font
end

-- A terminal's font DESCRIPTION is not a family name: foot writes "Family:size=11:charwidth=6",
-- kitty "Family 11", and fc-list only answers about the FAMILY. Asking it the whole description is
-- how this check came to answer "cannot measure" for every configured terminal (measured 21/11).
function M.family_of(description)
  local text = tostring(description or "")
  local family = text:match("^([^:]+)") or text
  family = family:gsub("%s+%d+%.?%d*$", "")
  return (family:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- DOES THIS TERMINAL ALREADY DRAW THE APPROVED A2 ICONS?
--
-- This is the question the setup asks, and it is NOT 'can the current font draw the md-* code points'.
-- Every Nerd font carries them, so that question answers YES for exactly the case Victor rejected
-- (19/11 ~10:20): a Nerd font draws wa's icons ITSELF, in its own outlines, one space wide - not with
-- wa Icons filling a JetBrains Mono cell with the value glued. Review finding, 21/11: treating 'has Nerd
-- glyphs' as 'already set up' left foot on JetBrainsMono Nerd Font, which is the spacing complaint
-- itself. A terminal is set up when its PRIMARY face is JetBrains Mono AND its icon fallback is wa
-- Icons; anything else is switched, the Nerd fonts included.
-- Was wa Icons installed for this user by this command? The record it writes is the answer.
function M.installed_by_setup(record)
  -- A RECORD THE CALLER ALREADY HOLDS is the same answer as the one on disk, and asking the disk instead made a
  -- second run inside one command (or a test with a scratch record) edit a terminal that was already set up -
  -- and overwrite its backup (measured 21/11).
  record = record or M.read_record()
  return record ~= nil and record["wa Icons"] == true
end

-- A line with no leading or trailing whitespace, for comparing it with the one this command writes.
function M.trim_line(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The keys a terminal uses for its ICON face, beside the key it uses for its text face. An explicit list on
-- the terminal wins; otherwise it is the first word of the fallback line the setup writes (kitty's
-- symbol_map, ghostty's font-codepoint-map).
function M.icon_line_keys(terminal)
  if not terminal then return {} end
  if terminal.icon_keys then return terminal.icon_keys end
  local keys = {}
  local first = tostring(terminal.fallback_line or ""):match("^(%S+)")
  if first and first ~= "" then keys[#keys + 1] = (first:gsub("[=%.]+$", "")) end
  return keys
end

-- Does this line name the ICON face - the one this command writes now, or one an earlier run wrote? A line
-- whose key is one of the terminal's icon keys AND that names "wa Icons". It is the single reader of that
-- shape, so the check (already_a2) and the writer (edited_text) cannot disagree about what one is.
function M.names_icon_face(terminal, line)
  local text = tostring(line or "")
  if text:match("^%s*#") then return false end
  if not text:lower():find("wa icons", 1, true) then return false end
  for _, key in ipairs(M.icon_line_keys(terminal)) do
    if text:match("^%s*" .. M.key_pattern(key) .. "%s*[= ]") then return true end
  end
  return false
end

function M.already_a2(description, config_text, terminal, record)
  local text = tostring(description or ""):lower()
  -- The primary face: the text before the first comma (foot) or the whole description (the others).
  local primary = text:match("^([^,]+)") or text
  local is_text_face = primary:find("jetbrains mono", 1, true) ~= nil
  if not terminal then
    -- NO TERMINAL: the coarse shape this function had before a caller passed one (a font DESCRIPTION and
    -- nothing else). Every path that edits a config passes the terminal, so this is only the fallback for a
    -- caller that cannot say which terminal it is asking about, and it is not a licence to edit.
    return is_text_face and text:find("wa icons", 1, true) ~= nil
  end
  -- A terminal whose syntax has no icon-face line (alacritty and wezterm take fallbacks from fontconfig, and
  -- Windows Terminal has no per-code-point key) is set up when its TEXT face is JetBrains Mono and wa Icons
  -- is installed for this user: there is no line to look for, and demanding one made it edit on every run
  -- (measured 21/11).
  if terminal.icons_via == "fontconfig" or terminal.kind == "lua-wezterm" or terminal.kind == "json-wt" then
    return is_text_face and M.installed_by_setup(record)
  end
  -- GNOME Terminal holds one font DESCRIPTION and no icon line at all: it is set up when that value is
  -- exactly what this command would set it to.
  if terminal.kind == "gsettings" then
    return tostring(description or "") == M.font_value(terminal, description)
  end
  -- THE ICON FACE MUST BE EXACTLY THE LINE THIS COMMAND WRITES NOW - not merely a line that mentions
  -- "wa Icons". MEASURED 21/11: kitty carrying the pre-fix 'symbol_map U+F0000-U+FFFFD wa Icons' and ghostty
  -- carrying 'font-family = "wa Icons"' were both reported "already draws wa's icons" and never corrected,
  -- although the first hands EVERY plane-15 code point (every other program's Nerd icon) to a face with
  -- fourteen glyphs. A map that is not the map the command writes is a map to replace.
  if terminal.fallback_line then
    local config = tostring(config_text or "")
    for line in (config .. "\n"):gmatch("([^\n]*)\n") do
      if M.trim_line(line) == terminal.fallback_line then return is_text_face end
    end
    return false
  end
  -- THE ICON FACE RIDES ON THE FONT LINE ITSELF (foot: "JetBrains Mono:size=11, wa Icons:size=11"), so the
  -- whole line has to be what font_value writes - which is also what makes the answer change when the pair
  -- changes, instead of the terminal staying "set up" for a line this command no longer writes.
  return tostring(description or "") == M.font_value(terminal, description)
end

-- Can the font this terminal draws TODAY show wa's icons? true / false, or nil when nobody could ask -
-- and nil never becomes "yes".
function M.draws_icons(font_name)
  if not font_name or font_name == "" then return nil end
  -- ALREADY SET UP IS "YES". foot names its fallback in the same line this command writes
  -- ("JetBrains Mono:size=11:charwidth=6:icons=wa Icons"), and re-reading only the family made a second
  -- run edit the file again - which is not merely wasteful: it overwrites the backup with already-edited
  -- bytes, and that is how a --undo came to restore the wrong thing on 21/11.
  if tostring(font_name):lower():find("wa icons", 1, true) then return true end
  if tostring(font_name):lower():find("nerd", 1, true) then return true end
  local name = M.safe_name(M.family_of(font_name))
  if name == "" then return nil end
  -- THREE ANSWERS, and the difference is the whole rule:
  --   the command FAILED           -> nil   (nobody can ask on this machine)     -> no edit
  --   it ran and matched no font  -> false (a font that is not installed draws nothing) -> edit
  --   it ran and matched a font   -> ask that font's charset
  -- fc-list exits 0 even when it matches nothing (measured 21/11), so the tool's own answer is the
  -- envelope's ok, never the exit code: a failed command must not read as 'no such font'.
  local listed, listed_why = run_shell("fc-list '" .. name .. "' 2>/dev/null")
  if listed == nil then return nil, listed_why end
  if listed == "" then return false end
  local charset = run_shell("fc-list --format '%{charset}\n' '" .. name .. "' 2>/dev/null")
  if type(charset) ~= "string" or charset == "" then return nil end
  local want = 0xF0766
  for token in charset:gmatch("[^%s]+") do
    local low, high = token:match("^(%x+)%-(%x+)$")
    if low then
      if want >= tonumber(low, 16) and want <= tonumber(high, 16) then return true end
    elseif token:match("^%x+$") and tonumber(token, 16) == want then
      return true
    end
  end
  return false
end

-- ---- editing a config, safely ---------------------------------------------------------------
--
-- Every edit is the same three steps, in this order: a BACKUP beside the file, the WRITE, and a line
-- only after the file is written. A write that cannot happen leaves the backup in place and says so,
-- because a backup with no edit is harmless and an edit with no backup is not.

function M.backup_path(path)
  return path .. ".wa-backup"
end

-- Write the undo ONCE, and never over a backup that already exists.
--
-- MEASURED 21/11 (mission fonts-install item 2): a second run re-edited a config and wrote the already-edited
-- bytes over alacritty.toml.wa-backup, so the ORIGINAL bytes were gone and --undo could only restore the first
-- run's edit. The backup is the undo, and an undo that can be overwritten is not one: the first bytes a run
-- found are the only bytes worth keeping.
--
--   * no backup yet            -> write the text the caller is about to replace;
--   * a backup already there   -> LEAVE IT (true), because it holds an earlier - and therefore more original -
--                                 state, and the row says so through 'carried';
--   * cannot tell (unreadable) -> false, so the caller edits nothing: "unknown is not yes" applies to an undo.
function M.write_backup_once(path, text)
  local backup = M.backup_path(path)
  local existing = host.read_file(backup)
  if type(existing) == "string" then return true, backup, true end
  if host.path_kind then
    local kind = host.path_kind(backup)
    -- 'dir' or 'other' is a path this command must not write through; anything unreadable but present is not
    -- a missing file, and inventing "no backup" would overwrite it.
    if kind == "dir" or kind == "other" then return false, backup, false end
    if kind == "missing" then
      if not host.write_file(backup, text) then return false, backup, false end
      return true, backup, false
    end
    return false, backup, false
  end
  -- No path_kind on this host: a read is the only probe, and nil there means either missing or unreadable -
  -- an answer that cannot tell them apart is a refusal, not a licence.
  return false, backup, false
end

-- THE A2 PAIR FOR A CONFIG THAT NAMES NO FONT, in each terminal's own syntax. Not an edit of somebody's
-- value: an addition, in the form that terminal documents for a fallback face.
--   kitty     font_family JetBrains Mono  +  symbol_map <ICON_RANGES> wa Icons
--   alacritty [font.normal] family = "JetBrains Mono"  (alacritty takes icon fallbacks from fontconfig,
--             where wa Icons is installed; there is no per-code-point key in its config)
--   ghostty   font-family = "JetBrains Mono" + font-codepoint-map = <ICON_RANGES>=wa Icons (ghostty maps the code points itself;
--             documented way to add a fallback face)
-- The config with every stale ICON line removed, so the pair can be added without leaving a second map
-- beside it (kitty reads the LAST symbol_map, so a pre-fix whole-plane map left in place would win).
function M.without_icon_lines(terminal, text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    if not M.names_icon_face(terminal, line) then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

function M.pair_for_fontless(terminal, text)
  text = M.without_icon_lines(terminal, text)
  local function add(lines)
    local out = (text:gsub("\n+$", ""))
    if out ~= "" then out = out .. "\n" end
    return out .. lines .. "\n"
  end
  if terminal.kind == "conf" and terminal.key == "font_family" then
    return add("font_family JetBrains Mono\nsymbol_map " .. M.ICON_RANGES .. " wa Icons")
  elseif terminal.kind == "conf" and terminal.key == "font-family" then
    return add('font-family = "JetBrains Mono"\nfont-codepoint-map = ' .. M.ICON_RANGES .. '=wa Icons')
  elseif terminal.kind == "toml" then
    return add('[font.normal]\nfamily = "JetBrains Mono"')
  end
  return nil, "this terminal's syntax has no font key this command can add"
end

-- One phrase per terminal for the dry-run line, so a plan reads as clearly as an edit.
function M.pair_summary(terminal)
  if terminal.kind == "conf" and terminal.key == "font_family" then
    return "font_family JetBrains Mono + symbol_map " .. M.ICON_RANGES .. " wa Icons"
  elseif terminal.kind == "conf" and terminal.key == "font-family" then
    return 'font-family = "JetBrains Mono" + font-codepoint-map = ' .. M.ICON_RANGES .. '=wa Icons'
  elseif terminal.kind == "toml" then
    return '[font.normal] family = "JetBrains Mono"'
  end
  return "the A2 pair"
end

-- The value that gives a terminal JetBrains Mono with wa Icons as its fallback, in that terminal's own
-- syntax. Kept in one function so the shapes cannot drift apart.
-- The point size the operator chose, kept when the face changes: a setup that also silently resized
-- the terminal would be two decisions, and only one of them was approved.
function M.size_of(description)
  return tostring(description or ""):match("size=(%d+%.?%d*)")
end

function M.font_value(terminal, current)
  -- THE A2 PAIR, in the terminal's own syntax. Victor 19/11 ~10:20: JetBrains Mono for text with
  -- wa Icons for the glyphs wa draws. Not "JetBrains Mono" alone: a face that carries the md-* code
  -- points ITSELF (every Nerd font does) shadows wa Icons and draws them at Nerd metrics, which is the
  -- spacing Victor rejected. The pair is what makes wa Icons the face that draws them.
  local size = M.size_of(current)
  local text = M.TEXT_FAMILY .. (size and (":size=" .. size) or "")
  local icons = M.ICON_FAMILY .. (size and (":size=" .. size) or "")
  if terminal.kind == "ini" then
    -- foot takes a COMMA-SEPARATED list (foot.ini(5), 'font'): the text face, then the icon face.
    return text .. ", " .. icons
  elseif terminal.kind == "gsettings" then
    -- GNOME Terminal names a family and a point size, nothing else.
    return M.TEXT_FAMILY .. (size and (" " .. size) or "")
  end
  return M.TEXT_FAMILY
end

-- The edited text: the font line replaced (or added) so the terminal opens JetBrains Mono and falls back
-- to wa Icons for the glyphs JetBrains Mono does not carry. Pure - the caller writes it - so a test can
-- assert the exact bytes without touching a home.
function M.edited_text(terminal, text)
  text = tostring(text or "")
  local value = M.font_value(terminal, M.current_font(terminal, text))
  if terminal.kind == "ini" then
    local section, inserted, out = nil, false, {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      local header = line:match("^%s*%[([^%]]+)%]")
      if header then
        if section == terminal.section and not inserted then
          out[#out + 1] = terminal.key .. "=" .. value
          inserted = true
        end
        section = header
      end
      if section == terminal.section and line:match("^%s*" .. M.key_pattern(terminal.key) .. "%s*=") then
        out[#out + 1] = terminal.key .. "=" .. value
        inserted = true
      else
        out[#out + 1] = line
      end
    end
    if not inserted then
      if not section then out[#out + 1] = "[main]" end
      out[#out + 1] = terminal.key .. "=" .. value
    end
    return (table.concat(out, "\n"):gsub("\n+$", "\n"))
  elseif terminal.kind == "toml" then
    -- EVERY WEIGHT AT ONCE, in one pass. alacritty writes
    --   normal = { family = "X", style = "Regular" }
    --   bold   = { family = "X", ... }   italic = { ... }
    -- and replacing only 'normal' left bold and italic on the Nerd face, so bold text still drew Nerd
    -- icons - half a fix that reads as a whole one (measured 21/11: 1 of 3 replaced).
    -- EVERY WEIGHT: alacritty names normal, bold and italic separately, and leaving two of them on the
    -- Nerd face means bold text still draws Nerd icons - half a fix that reads as a whole one (21/11).
    local replaced_all, all_count = text:gsub(
      "([\n]%s*[%w_%-]+%s*=%s*{[^}]-family%s*=%s*)([\"'])(.-)([\"'])",
      "%1%2" .. value .. "%4")
    if all_count > 0 then return (replaced_all:gsub("\n+$", "\n")) end
    -- Nothing matched, so fall back to the section form below.
    local section, out = nil, {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      local header = line:match("^%s*%[([^%]]+)%]")
      if header then section = header end
      if section == terminal.section and line:match("^%s*" .. M.key_pattern(terminal.key) .. "%s*=") then
        out[#out + 1] = terminal.key .. ' = "' .. value .. '"'
      else
        out[#out + 1] = line
      end
    end
    local joined = table.concat(out, "\n")
    if not joined:find("%[" .. terminal.section:gsub("%.", "%%.") .. "%]") then
      joined = joined .. "\n[" .. terminal.section .. "]\n" .. terminal.key .. ' = "' .. value .. '"\n'
    end
    return (joined:gsub("\n+$", "\n"))
  elseif terminal.kind == "conf" then
    -- BOTH WRITTEN FORMS, matched the way the READER matches them. ghostty writes 'font-family = "X"';
    -- a writer that only knew 'font_family X' appended a second line beside the old one, so the reader saw
    -- the old face, the next run edited again, and each run overwrote the backup (measured 21/11).
    local out, replaced, wrote_icons = {}, false, false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      local key_at = line:match("^(%s*" .. M.key_pattern(terminal.key) .. "%s*[= ])")
      -- AN ICON LINE IS NOT A TEXT LINE. ghostty repeats font-family to name its fallback face, and a writer
      -- that replaced EVERY line under that key turned 'font-family = "wa Icons"' into a second copy of the
      -- text face: the icon face disappeared and the config looked set up.
      if M.names_icon_face(terminal, line) then
        -- A STALE ICON LINE IS REPLACED IN PLACE, never left beside the new one. kitty reads its LAST
        -- symbol_map, so a pre-fix whole-plane map left above the new line (or a stale line below it) would
        -- undo the fix as quietly as it was applied.
        if terminal.fallback_line and not wrote_icons then
          out[#out + 1] = terminal.fallback_line
          wrote_icons = true
        end
      elseif key_at and not line:match("^%s*#") then
        if key_at:find("=", 1, true) then
          out[#out + 1] = terminal.key .. ' = "' .. value .. '"'
        else
          out[#out + 1] = terminal.key .. " " .. value
        end
        replaced = true
      else
        out[#out + 1] = line
      end
    end
    if not replaced then
      if terminal.key:find("%-") then out[#out + 1] = terminal.key .. ' = "' .. value .. '"'
      else out[#out + 1] = terminal.key .. " " .. value end
    end
    local joined = table.concat(out, "\n")
    -- AND THE ICON FACE, on the line that terminal documents for a fallback (kitty: symbol_map; ghostty:
    -- a repeated font-family). Without it the config names a text face and no icon face, the reader is
    -- right to call that not-A2, and every run edited again and overwrote the backup (measured 21/11).
    if terminal.fallback_line and not wrote_icons then
      joined = joined:gsub("\n+$", "\n") .. terminal.fallback_line .. "\n"
    end
    return (joined:gsub("\n+$", "\n"))
  elseif terminal.kind == "json-wt" then
    return M.wt_edited(text, value)
  elseif terminal.kind == "lua-wezterm" then
    -- wezterm's config is Lua, and a generated line is not a rewrite of somebody's program: the family
    -- inside the existing font table is the only thing replaced, and a config with no font table is
    -- left alone (that is a program, not a setting).
    local replaced, count = text:gsub('(font%s*=%s*[^{]*{[^}]-family%s*=%s*)([\'"])(.-)([\'"])',
      "%1%2" .. value .. "%4", 1)
    if count == 0 then return nil, "wezterm_font_table_absent" end
    return (replaced:gsub("\n+$", "\n"))
  end
  return nil, "terminal_kind_unknown"
end

-- ---- the run ---------------------------------------------------------------------------------
--
-- install() is the whole command, and every step reports what it did in ONE line: this runs from an
-- installer too, where a wall of text hides the failure that matters.

local function shell_quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

-- Copy the three faces into the user font directory. Refuses when a face is missing from the bundle
-- (a setup that installs two of three faces is a terminal with half an icon set) and when the
-- destination cannot be created.
-- WHAT install_fonts WOULD DO, without doing any of it: the same source check, the same missing-face
-- refusal, and the list it would copy. A dry run asks THIS, so the two cannot drift.
function M.font_plan(opts)
  opts = opts or {}
  local os_name = opts.os or M.os()
  local home = opts.home or M.user_home()
  local tried, source = M.source_candidates(opts)
  local target = opts.font_dir or M.font_dir(os_name, home)
  local plan = { dir = target, copied = {}, missing = {}, tried = tried }
  if not source then return nil, plan end
  for _, name in ipairs(M.FONTS) do
    local path = source .. "/" .. name
    local kind = host.path_kind and host.path_kind(path) or (host.read_file(path) and "file" or "missing")
    if kind ~= "file" then plan.missing[#plan.missing + 1] = path
    else plan.copied[#plan.copied + 1] = name end
  end
  return plan
end

function M.install_fonts(opts)
  opts = opts or {}
  local os_name = opts.os or M.os()
  local home = opts.home or M.user_home()
  local tried, source = M.source_candidates(opts)
  local target = opts.font_dir or M.font_dir(os_name, home)
  local run = opts.run or function(command) return host.exec(command, "", 60) end
  local done = { dir = target, copied = {}, missing = {}, tried = tried }
  -- EVERY PLACE THAT WAS LOOKED AT, printed with the refusal. 'I cannot find the faces' is only actionable
  -- when it names what it looked for and where: an operator can then see the one path that is missing a copy.
  local function looked_at()
    local names = {}
    for _, row in ipairs(tried or {}) do
      names[#names + 1] = tostring(row.path) .. " [" .. tostring(row.label) .. "]"
    end
    if #names == 0 then return "none" end
    return table.concat(names, ", ")
  end

  if not source then
    return nil, "fonts_source_unknown: this node cannot say where its own fonts live (WA_UI_DIR, or WASM_AGENT_LUA_ROOT for a checkout); tried: " .. looked_at(), done
  end
  for _, name in ipairs(M.FONTS) do
    local path = source .. "/" .. name
    local kind = host.path_kind and host.path_kind(path) or (host.read_file(path) and "file" or "missing")
    if kind ~= "file" then done.missing[#done.missing + 1] = path end
  end
  if #done.missing > 0 then
    return nil, "fonts_missing_from_bundle: " .. table.concat(done.missing, ", ") .. " (looked at: " .. looked_at() .. ")", done
  end
  local made = run("mkdir -p " .. shell_quote(target) .. " && echo ok 2>/dev/null")
  if not (type(made) == "string" and made:find("ok", 1, true)) then
    return nil, "fonts_dir_unwritable: " .. target, done
  end
  for _, name in ipairs(M.FONTS) do
    local out = run("cp -f " .. shell_quote(source .. "/" .. name) .. " " .. shell_quote(target .. "/" .. name)
      .. " && echo ok")
    if not (type(out) == "string" and out:find("ok", 1, true)) then
      return nil, "fonts_copy_failed: " .. name, done
    end
    done.copied[#done.copied + 1] = name
  end
  -- The font cache: Linux has one and a new file is invisible without it; macOS and Windows find a font
  -- in a user directory on their own, so the command is only run where it exists.
  done.cache = "none"
  if tostring(os_name):find("linux", 1, true) then
    local out = run("fc-cache -f " .. shell_quote(target) .. " 2>/dev/null && echo ok")
    done.cache = (type(out) == "string" and out:find("ok", 1, true)) and "refreshed" or "failed"
  end
  return done
end

-- One terminal: read its config, decide, edit, back up. Returns a row saying what happened and why -
-- including "left alone", which is an answer and not a failure.
function M.configure_terminal(terminal, opts)
  opts = opts or {}
  local row = { name = terminal.name, action = "left alone" }
  -- A terminal this command KNOWS it cannot edit safely says so, with the instruction that replaces the
  -- edit: a GUI profile is not a file, and "left alone" with no reason is the answer that gets ignored.
  if terminal.kind == "unsupported" then
    row.why = tostring(terminal.why or "this terminal's settings are not a file this command can edit")
    return row
  end
  if terminal.kind == "gsettings" then
    return M.configure_gsettings(terminal, opts)
  end
  if not terminal.path then
    row.why = "no user config file this command can safely edit"
    return row
  end
  local kind = host.path_kind and host.path_kind(terminal.path) or (host.read_file(terminal.path) and "file" or "missing")
  if kind ~= "file" then
    row.why = "no config file at " .. terminal.path .. " (a terminal nobody configured is not edited)"
    return row
  end
  local text = host.read_file(terminal.path)
  if type(text) ~= "string" then
    row.why = "config unreadable: " .. terminal.path
    return row
  end
  row.current = M.current_font(terminal, text)
  if row.current == nil then
    -- NO FACE NAMED IS NOT NO PROBLEM (review finding 3, 21/11). The terminal then draws the system
    -- monospace, and on this machine 'fc-match monospace' answers JetBrainsMono Nerd Font - so its icons
    -- are Nerd metrics, exactly what A2 replaced. The A2 pair is written EXPLICITLY instead of skipped.
    local explicit, why_not = M.pair_for_fontless(terminal, text)
    if not explicit then
      row.why = "its config names no font, and this terminal's syntax has no place to add one: " .. tostring(why_not)
      return row
    end
    if opts.dry_run then
      row.action = "would edit"
      row.planned = M.pair_summary(terminal)
      row.why = "its config names no font, so it draws the system monospace"
      return row
    end
    local backed, backup_path, carried = M.write_backup_once(terminal.path, text)
    if not backed then
      row.why = "backup_failed: this command could not secure an undo at " .. tostring(backup_path)
      return row
    end
    if not host.write_file(terminal.path, explicit) then
      row.why = "write_failed: " .. terminal.path
      return row
    end
    row.action = "edited"
    row.current = "(no font named: the system monospace)"
    row.backup = backup_path
    if carried then row.carried = true end
    row.why = "named no font; the A2 pair is now written explicitly"
    return row
  end
  local ready = (opts.already or M.already_a2)(row.current, text, terminal, opts.record)
  if ready then
    row.why = "'" .. tostring(row.current) .. "' already draws wa's icons with wa Icons: nothing to do"
    return row
  end
  local edited, why = M.edited_text(terminal, text)
  if not edited then
    row.why = tostring(why)
    return row
  end
  if opts.dry_run then
    row.action = "would edit"
    row.planned = edited:match("font=([^\n]+)") or M.font_value(terminal, row.current)
    row.why = "'" .. tostring(row.current) .. "' is not the A2 pair (JetBrains Mono + wa Icons)"
    return row
  end
  -- BACKUP BEFORE THE WRITE, always: the backup is the undo, and an undo that was written afterwards is
  -- the one that is missing when the write fails.
  local backed, backup_path, carried = M.write_backup_once(terminal.path, text)
  if not backed then
    row.why = "backup_failed: this command could not secure an undo at " .. tostring(backup_path)
    return row
  end
  if not host.write_file(terminal.path, edited) then
    row.why = "write_failed: " .. terminal.path
    return row
  end
  row.action = "edited"
  row.why = "'" .. tostring(row.current) .. "' replaced by JetBrains Mono + wa Icons"
  row.backup = backup_path
  if carried then
    -- AN EXISTING BACKUP IS KEPT, and the row says so: the undo restores the bytes an EARLIER run found, which
    -- is the most original state this command has a copy of.
    row.carried = true
    row.why = row.why .. " (keeping the undo already at " .. tostring(backup_path) .. ")"
  end
  return row
end

-- GNOME Terminal: no file, one dconf key. Read through gsettings, decided like every other terminal, and
-- written with 'gsettings set'. The BACKUP is the old value, kept in the record (there is no file to copy);
-- --undo sets it back. Where gsettings is absent - which is every node that is not a GNOME desktop - the
-- reader answers nil and the terminal is left alone, which is the same rule as a coverage question nobody
-- can answer.
function M.configure_gsettings(terminal, opts)
  local row = { name = terminal.name, action = "left alone" }
  local run = opts.run or run_shell
  local profile = opts.gnome_profile or M.gnome_profile()
  if not profile or profile == "" then
    row.why = "no GNOME Terminal profile to read on this machine"
    return row
  end
  row.profile = profile
  local key = M.gnome_key(profile)
  local current, read_why = opts.gnome_font or run("gsettings get " .. key .. " font 2>/dev/null")
  if opts.gnome_font then current, read_why = opts.gnome_font, nil end
  if type(current) ~= "string" or current == "" then
    row.why = "cannot read the GNOME Terminal profile's font on this machine (" .. tostring(read_why or "no answer") .. ")"
    return row
  end
  current = current:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^'", ""):gsub("'$", "")
  if current:find("[{}]") then
    -- Belt and braces: an envelope that reached here would be written as a font name.
    row.why = "cannot read the GNOME Terminal profile's font on this machine (answer is not a font)"
    return row
  end
  row.current = current
  local ready = (opts.already or M.already_a2)(current, nil, terminal, opts.record)
  if ready then
    row.why = "'" .. tostring(current) .. "' already draws wa's icons with wa Icons: nothing to do"
    return row
  end
  local value = M.font_value(terminal, current)
  if opts.dry_run then
    row.action = "would edit"
    row.planned = M.font_value(terminal, current)
    row.why = "'" .. tostring(current) .. "' is not the A2 pair (JetBrains Mono + wa Icons)"
    return row
  end
  local out = run("gsettings set " .. key .. " font '" .. value .. "' 2>&1")
  if type(out) == "string" and out:find("error", 1, true) then
    row.why = "gsettings_write_failed: " .. out
    return row
  end
  row.action = "edited"
  row.why = "'" .. tostring(current) .. "' replaced by JetBrains Mono + wa Icons"
  -- No file to copy: the old VALUE is the backup, and the undo puts it back.
  row.backup_value = current
  return row
end

function M.record_path()
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok or type(paths) ~= "table" then return nil end
  return paths.data() .. "/setup/fonts.json"
end

-- What the setup did, on disk: the record the icon default and --undo both read.
function M.read_record()
  local path = M.record_path()
  if not path then return nil end
  local raw = host.read_file(path)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, record = pcall(json.decode, raw)
  if ok and type(record) == "table" then return record end
  return nil
end

function M.write_record(record)
  local path = M.record_path()
  if not path then return nil, "record_path_unknown" end
  local dir = path:gsub("/[^/]+$", "")
  if host.path_kind and host.path_kind(dir) ~= "dir" then
    pcall(host.exec, "mkdir -p " .. shell_quote(dir), "", 20)
  end
  if not host.write_file(path, json.encode(record)) then return nil, "record_write_failed: " .. path end
  return path
end

-- The whole command. opts: { dry_run, undo, os, home, source_dir, font_dir, run, draws, terminals }.
function M.run(opts)
  opts = opts or {}
  local result = { ok = true, lines = {} }
  local function say(line) result.lines[#result.lines + 1] = line end

  if opts.undo then
    local record = opts.record or M.read_record()
    if not record then
      result.ok = false
      result.error = "nothing_to_undo: no record at " .. tostring(M.record_path())
      say(result.error)
      return result
    end
    local restored = 0
    for _, row in ipairs(record.terminals or {}) do
      -- A FILE edit is undone from its backup.
      if row.backup and row.path and host.read_file(row.backup) then
        if host.write_file(row.path, host.read_file(row.backup)) then
          pcall(host.exec, "rm -f " .. shell_quote(row.backup), "", 20)
          restored = restored + 1
        end
      end
      -- A dconf edit has no file: the old VALUE recorded beside it is what goes back.
      if row.backup_value and row.profile and M.run_shell then
        local key = M.gnome_key(row.profile)
        M.run_shell("gsettings set " .. key .. " font '" .. tostring(row.backup_value) .. "' 2>/dev/null")
        restored = restored + 1
      end
    end
    -- The installed fonts go too: --undo puts the machine back, not half of it.
    local dir = record.font_dir
    if dir and dir ~= "" and not opts.dry_run then
      for _, name in ipairs(record.fonts or {}) do pcall(host.exec, "rm -f " .. shell_quote(dir .. "/" .. name), "", 20) end
      pcall(host.exec, "fc-cache -f " .. shell_quote(dir) .. " 2>/dev/null", "", 20)
    end
    if not opts.dry_run then
      local path = M.record_path()
      if path then pcall(host.exec, "rm -f " .. shell_quote(path), "", 20) end
    end
    say(string.format("wa setup fonts --undo: %d terminal config(s) restored, %d font file(s) removed",
      restored, #(record.fonts or {})))
    result.restored = restored
    return result
  end

  if M.disabled() and not opts.force then
    result.skipped = true
    say("wa setup fonts: skipped (WA_NO_FONT_SETUP is set)")
    return result
  end

  -- A DRY RUN INSTALLS NOTHING (review finding 1, 21/11). It used to call install_fonts() before any
  -- dry_run check, so 'wa setup fonts --dry-run' really ran mkdir and cp into the user font directory
  -- and refreshed the cache - a dry run that writes is worse than no dry run, because it is asked for
  -- precisely when the operator is unsure. It now only ASKS: the same plan, no bytes.
  local detail, why
  if opts.dry_run then
    detail = M.font_plan(opts)
    if not detail then
      result.ok = false
      result.error = "fonts_source_unknown: this node cannot say where its own fonts live (WA_UI_DIR, or WASM_AGENT_LUA_ROOT for a checkout)"
      say("wa setup fonts: refused: " .. result.error)
      return result
    end
    if #detail.missing > 0 then
      -- A DRY RUN NAMES WHAT IS MISSING AND WHERE IT LOOKED, exactly like the real run: the two answer the
      -- same question and this command's whole value is that its plan is what it does.
      local where = {}
      for _, row in ipairs(detail.tried or {}) do where[#where + 1] = tostring(row.path) .. " [" .. tostring(row.label) .. "]" end
      result.ok = false
      result.error = "fonts_missing_from_bundle: " .. table.concat(detail.missing, ", ")
        .. " (looked at: " .. (#where > 0 and table.concat(where, ", ") or "none") .. ")"
      say("wa setup fonts: refused: " .. result.error)
      return result
    end
    say(string.format("wa setup fonts: would install %d font(s) in %s (dry run: nothing written)",
      #detail.copied, tostring(detail.dir)))
  else
    detail, why = M.install_fonts(opts)
    if not detail then
      result.ok = false
      result.error = why
      say("wa setup fonts: refused: " .. tostring(why))
      return result
    end
  end
  result.fonts = detail

  -- WHAT THIS RUN KNOWS ABOUT ITS OWN FONTS. A fontconfig terminal (alacritty, wezterm, Windows Terminal) is
  -- set up when its text face is JetBrains Mono and wa Icons is installed for this user - and on a machine
  -- where this run is the install, the record that says so is written at the END of the run. Reading only the
  -- disk record here made the FIRST run edit such a terminal again ("alacritty -> JetBrains Mono (was JetBrains
  -- Mono)", measured 21/11), replace its backup, and give an operator who was already set up a new undo.
  local run_opts = opts
  if not opts.record and detail and type(detail.copied) == "table" and #detail.copied == #M.FONTS then
    run_opts = {}
    for key, value in pairs(opts) do run_opts[key] = value end
    run_opts.record = { ["wa Icons"] = true, fonts = detail.copied, font_dir = detail.dir }
  end
  local terminals, rows = opts.terminals or M.terminals(opts.home), {}
  for _, terminal in ipairs(terminals) do
    local row = M.configure_terminal(terminal, run_opts)
    row.path = terminal.path
    rows[#rows + 1] = row
    if row.action == "edited" then
      say(string.format("wa setup fonts: %s -> %s (was %s; backup %s)",
        terminal.name, M.TEXT_FAMILY, tostring(row.current), row.backup))
    elseif row.action == "would edit" then
      -- A dry run names the terminal it WOULD edit and the exact value it would write. It used to fall
      -- through to "left alone", which is the opposite of what it plans (review finding 2, 21/11).
      say(string.format("wa setup fonts: would edit %s: %s -> %s%s",
        terminal.name, tostring(row.current), tostring(row.planned), opts.dry_run and " (dry run)" or ""))
    elseif opts.verbose then
      say(string.format("wa setup fonts: %s left alone: %s", terminal.name, tostring(row.why)))
    end
  end
  result.terminals = rows

  -- KEEP THE PREVIOUS RUN'S BACKUPS IN THE RECORD. A second run correctly edits nothing, and a record
  -- rebuilt from that run alone would DROP the backup pointer of the edit that is still in effect - so
  -- --undo would have nothing to restore and would leave the terminal edited (measured 21/11, end to
  -- end: the second run said "no terminal config needed a change" and --undo then restored 0 configs
  -- while still removing the fonts, a half undo).
  local previous = opts.record or M.read_record()
  if previous then
    local by_name = {}
    for _, row in ipairs(previous.terminals or {}) do by_name[row.name] = row end
    for _, row in ipairs(rows) do
      local before = by_name[row.name]
      if before and before.backup and row.action == "left alone" then
        row.backup = before.backup
        row.backup_value = row.backup_value or before.backup_value
        row.profile = row.profile or before.profile
        row.path = row.path or before.path
        row.carried = true
      end
    end
  end

  local edited, would = 0, 0
  for _, row in ipairs(rows) do
    if row.action == "edited" then edited = edited + 1
    elseif row.action == "would edit" then would = would + 1 end
  end
  if would > 0 then
    -- A dry run says what it would DO, in the same words a real run uses, and counts it: a summary that
    -- reports "no terminal config needed a change" over a plan to change one is the report lying about
    -- the plan (review finding 2, 21/11).
    say(string.format("wa setup fonts: dry run: %d terminal config(s) would be edited", would))
  end
  if edited == 0 and would == 0 then
    say("wa setup fonts: installed " .. tostring(#(detail.copied or {})) .. " font(s) in " .. tostring(detail.dir)
      .. "; no terminal config needed a change")
  end

  if not opts.dry_run then
    local record = {
      schema = 1,
      at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      ["wa Icons"] = true,
      family = M.ICON_FAMILY,
      text_family = M.TEXT_FAMILY,
      font_dir = detail.dir,
      fonts = detail.copied,
      terminals = rows,
    }
    local path, write_why = M.write_record(record)
    if not path then
      result.ok = false
      result.error = write_why
      say("wa setup fonts: " .. tostring(write_why))
    else
      result.record = path
    end
  end
  return result
end

-- The command-line face: 'wa setup fonts [--undo] [--dry-run] [--verbose]'. An unknown flag is refused by
-- name, and every line the run produces is printed once.
function M.cli(args)
  local opts = {}
  for _, arg in ipairs(args or {}) do
    local word = tostring(arg)
    if word == "--undo" then opts.undo = true
    elseif word == "--dry-run" then opts.dry_run = true
    elseif word == "--verbose" then opts.verbose = true
    elseif word == "--force" then opts.force = true
    elseif word == "fonts" then
      -- 'wa setup fonts': the subcommand name, when the caller hands over the whole tail.
    else
      print("wa setup fonts: unknown flag: " .. word)
      print("usage: wa setup fonts [--undo] [--dry-run] [--verbose]")
      return 2
    end
  end
  local result = M.run(opts)
  local printed = false
  for _, line in ipairs(result.lines or {}) do print(line); printed = true end
  if not printed then print("wa setup fonts: nothing to do") end
  return result.ok and 0 or 1
end

return M
