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

-- The directory the bundle's faces are served from. WA_UI_DIR is what a deployed node's sentinel binds
-- (rust/wa-sentinel/src/instance.rs); a checkout answers from its own ui/fonts through the Lua root.
function M.source_dir()
  local ui = host.getenv("WA_UI_DIR")
  if ui and ui ~= "" then return (ui:gsub("\\", "/"):gsub("/+$", "")) .. "/fonts" end
  local root = host.getenv("WASM_AGENT_LUA_ROOT")
  if root and root ~= "" then return (root:gsub("\\", "/"):gsub("/+$", "")) .. "/ui/fonts" end
  return nil
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
    { name = "alacritty", path = config_home .. "/alacritty/alacritty.toml", kind = "toml", section = "font.normal", key = "family" },
    { name = "kitty", path = config_home .. "/kitty/kitty.conf", kind = "conf", key = "font_family" },
    { name = "ghostty", path = config_home .. "/ghostty/config", kind = "conf", key = "font-family" },
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

-- A font NAME as a shell word: letters, digits, dot, dash, underscore and space only. An allow-list,
-- not an escape: these names come from a config file, and a config file is not to be trusted with a
-- shell. Anything else is dropped, so no quoting rule has to be right.
function M.safe_name(name)
  return (tostring(name or ""):gsub("[^%w%.%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function run_shell(command)
  local ok, out = pcall(host.exec, command, "", 20)
  if ok and type(out) == "string" then return out end
  return nil
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
        local value = line:match("^%s*" .. terminal.key .. "%s*=%s*(.-)%s*$")
        if value and value ~= "" then found = value end
      end
    end
    return found
  elseif terminal.kind == "toml" then
    local section, found = nil, nil
    for line in text:gmatch("[^\n]+") do
      local header = line:match("^%s*%[([^%]]+)%]")
      if header then section = header end
      if section == terminal.section then
        local value = line:match('^%s*' .. terminal.key .. '%s*=%s*"([^"]*)"')
        if value and value ~= "" then found = value end
      end
    end
    return found
  elseif terminal.kind == "conf" then
    local found = nil
    for line in text:gmatch("[^\n]+") do
      local value = line:match("^%s*" .. terminal.key .. "%s+([^#]+)")
      if value and value ~= "" then found = value:gsub("%s+$", "") end
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
  local out = run_shell("gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null")
  if type(out) ~= "string" then return nil end
  return out:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^'", ""):gsub("'$", "")
end

function M.gnome_key(profile)
  return "org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:" .. tostring(profile) .. "/"
end

function M.gnome_font(profile)
  local out = run_shell("gsettings get " .. M.gnome_key(profile) .. " font 2>/dev/null")
  if type(out) ~= "string" or out == "" then return nil end
  return out:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^'", ""):gsub("'$", "")
end

-- Can the font this terminal draws TODAY show wa's icons? true / false, or nil when nobody could ask -
-- and nil never becomes "yes".
function M.draws_icons(font_name)
  if not font_name or font_name == "" then return nil end
  if tostring(font_name):lower():find("nerd", 1, true) then return true end
  local name = M.safe_name(font_name)
  if name == "" then return nil end
  local listed = run_shell("fc-list '" .. name .. "' 2>/dev/null")
  if type(listed) ~= "string" or listed == "" then return nil end
  local charset = run_shell("fc-list --format '%{charset}\n' '" .. name .. "' 2>/dev/null")
  if type(charset) ~= "string" or charset == "" then return nil end
  -- The empty context ball, U+F0766: one of the nine every set draws, so a face with it has the family.
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

-- The value that gives a terminal JetBrains Mono with wa Icons as its fallback, in that terminal's own
-- syntax. Kept in one function so the shapes cannot drift apart.
function M.font_value(terminal)
  if terminal.kind == "ini" then
    return M.TEXT_FAMILY .. ":size=11:charwidth=6:icons=" .. M.ICON_FAMILY
  elseif terminal.kind == "toml" then
    return M.TEXT_FAMILY
  elseif terminal.kind == "conf" then
    return M.TEXT_FAMILY
  elseif terminal.kind == "json-wt" then
    return M.TEXT_FAMILY
  elseif terminal.kind == "lua-wezterm" then
    return M.TEXT_FAMILY
  end
  return M.TEXT_FAMILY
end

-- The edited text: the font line replaced (or added) so the terminal opens JetBrains Mono and falls back
-- to wa Icons for the glyphs JetBrains Mono does not carry. Pure - the caller writes it - so a test can
-- assert the exact bytes without touching a home.
function M.edited_text(terminal, text)
  text = tostring(text or "")
  local value = M.font_value(terminal)
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
      if section == terminal.section and line:match("^%s*" .. terminal.key .. "%s*=") then
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
    local section, out = nil, {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      local header = line:match("^%s*%[([^%]]+)%]")
      if header then section = header end
      if section == terminal.section and line:match("^%s*" .. terminal.key .. "%s*=") then
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
    local out, replaced = {}, false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^%s*" .. terminal.key .. "%s+") then
        out[#out + 1] = terminal.key .. " " .. value
        replaced = true
      else
        out[#out + 1] = line
      end
    end
    if not replaced then out[#out + 1] = terminal.key .. " " .. value end
    return (table.concat(out, "\n"):gsub("\n+$", "\n"))
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
function M.install_fonts(opts)
  opts = opts or {}
  local os_name = opts.os or M.os()
  local home = opts.home or M.user_home()
  local source = opts.source_dir or M.source_dir()
  local target = opts.font_dir or M.font_dir(os_name, home)
  local run = opts.run or function(command) return host.exec(command, "", 60) end
  local done = { dir = target, copied = {}, missing = {} }

  if not source then
    return nil, "fonts_source_unknown: this node cannot say where its own fonts live (WA_UI_DIR, or WASM_AGENT_LUA_ROOT for a checkout)", done
  end
  for _, name in ipairs(M.FONTS) do
    local path = source .. "/" .. name
    local kind = host.path_kind and host.path_kind(path) or (host.read_file(path) and "file" or "missing")
    if kind ~= "file" then done.missing[#done.missing + 1] = path end
  end
  if #done.missing > 0 then
    return nil, "fonts_missing_from_bundle: " .. table.concat(done.missing, ", "), done
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
  local draws = (opts.draws or M.draws_icons)(row.current)
  if draws == nil then
    row.why = "cannot measure whether '" .. tostring(row.current) .. "' draws wa's icons on this machine"
    return row
  end
  if draws then
    row.why = "'" .. tostring(row.current) .. "' already draws wa's icons"
    return row
  end
  local edited, why = M.edited_text(terminal, text)
  if not edited then
    row.why = tostring(why)
    return row
  end
  if opts.dry_run then
    row.action = "would edit"
    row.why = "'" .. tostring(row.current) .. "' cannot draw wa's icons"
    return row
  end
  -- BACKUP BEFORE THE WRITE, always: the backup is the undo, and an undo that was written afterwards is
  -- the one that is missing when the write fails.
  if not host.write_file(M.backup_path(terminal.path), text) then
    row.why = "backup_failed: " .. M.backup_path(terminal.path)
    return row
  end
  if not host.write_file(terminal.path, edited) then
    row.why = "write_failed: " .. terminal.path
    return row
  end
  row.action = "edited"
  row.why = "'" .. tostring(row.current) .. "' cannot draw wa's icons; now " .. M.TEXT_FAMILY
  row.backup = M.backup_path(terminal.path)
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
  local current = opts.gnome_font or run("gsettings get " .. key .. " font 2>/dev/null")
  if type(current) ~= "string" or current == "" then
    row.why = "cannot read the GNOME Terminal profile's font on this machine"
    return row
  end
  current = current:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^'", ""):gsub("'$", "")
  row.current = current
  local draws = (opts.draws or M.draws_icons)(current)
  if draws == nil then
    row.why = "cannot measure whether '" .. tostring(current) .. "' draws wa's icons on this machine"
    return row
  end
  if draws then
    row.why = "'" .. tostring(current) .. "' already draws wa's icons"
    return row
  end
  local value = M.TEXT_FAMILY .. " 11"
  if opts.dry_run then
    row.action = "would edit"
    row.why = "'" .. tostring(current) .. "' cannot draw wa's icons"
    return row
  end
  local out = run("gsettings set " .. key .. " font '" .. value .. "' 2>&1")
  if type(out) == "string" and out:find("error", 1, true) then
    row.why = "gsettings_write_failed: " .. out
    return row
  end
  row.action = "edited"
  row.why = "'" .. tostring(current) .. "' cannot draw wa's icons; now " .. M.TEXT_FAMILY
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

  local detail, why = M.install_fonts(opts)
  if not detail then
    result.ok = false
    result.error = why
    say("wa setup fonts: refused: " .. tostring(why))
    return result
  end
  result.fonts = detail

  local terminals, rows = opts.terminals or M.terminals(opts.home), {}
  for _, terminal in ipairs(terminals) do
    local row = M.configure_terminal(terminal, opts)
    row.path = terminal.path
    rows[#rows + 1] = row
    if row.action == "edited" then
      say(string.format("wa setup fonts: %s -> %s (was %s; backup %s)",
        terminal.name, M.TEXT_FAMILY, tostring(row.current), row.backup))
    elseif opts.verbose then
      say(string.format("wa setup fonts: %s left alone: %s", terminal.name, tostring(row.why)))
    end
  end
  result.terminals = rows

  local edited = 0
  for _, row in ipairs(rows) do if row.action == "edited" then edited = edited + 1 end end
  if edited == 0 then
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
