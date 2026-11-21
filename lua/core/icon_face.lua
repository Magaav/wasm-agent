-- WHICH FACE DRAWS wa's ICONS IN *THIS* TERMINAL (item 5 of the wa-fonts mission, Victor 21/11).
--
-- THE BUG THIS REPLACES. lua/core/icons.lua made wa Icons the default set whenever the setup's RECORD
-- (<data>/setup/fonts.json) said it was installed. The record describes a CONFIG FILE, and a terminal
-- reads that file when the terminal STARTS: a foot window opened before 'wa setup fonts' rewrote
-- foot.ini went on drawing the icon code points with the Nerd Font it had already loaded - glyphs wider
-- than their cell - while wa chose the glued set (gap ""), so every icon spilled into its digit
-- ("bottom is glued", Victor's screenshot 21/11 ~10:50).
--
-- THE QUESTION, asked per process and answered from measurements: is wa Icons the face drawing the icon
-- code points in the terminal THIS process runs in? Three steps, each able to answer "cannot tell", and
-- "cannot tell" is never "yes" - it is one of the SPACED sets, never the glued one:
--
--   1. WHICH TERMINAL, AND WHEN IT STARTED. One /proc walk from this process up through its ancestors to
--      the first whose comm is a terminal emulator. A process's start time is the mtime of its
--      /proc/<pid> directory: measured 21/11 on this node as exactly btime + starttime/HZ, so the walk
--      does not have to parse /proc/stat and the HZ.
--   2. WHICH FACE DRAWS THE ICON CODE POINTS. When the terminal's config names the icon face itself
--      (foot's font list "JetBrains Mono:size=9, wa Icons:size=9", kitty's symbol_map, ghostty's
--      font-codepoint-map) the config says so, and the font is then confirmed resolvable by fontconfig.
--      The terminals that take their fallback face from fontconfig (alacritty, wezterm, GNOME Terminal,
--      Windows Terminal) are asked fontconfig's own question instead: 'fc-match -f %{family}
--      "<family>:charset=f0766"' answers the family that draws U+F0766. MEASURED 21/11 on this node:
--      that answer for alacritty's "JetBrains Mono" is "JetBrains Mono Nerd Font", NOT wa Icons -
--      fontconfig prefers the Nerd face - so alacritty's icons are the spaced nerd set, not the glued
--      one, however the record reads.
--   3. WHETHER THE RUNNING WINDOW LOADED THAT CONFIG. A window that started BEFORE the config file was
--      written is still drawing the face it read at start-up, whatever the file says now. The same
--      second cannot be ordered, and counts as "cannot tell".
--
-- The spaced set that replaces the glued one is decided by the SAME fontconfig question: a face that
-- HAS U+F0766 draws its own Nerd-shaped glyph (wider than its cell -> nerd, with the one space Victor
-- kept); a face that does not leaves the code point to a fallback this node cannot name -> the unicode
-- glyphs a stock font has. Never the glued set.
local font_setup = dofile("lua/core/font_setup.lua")

local M = {}

M.FAMILY = font_setup.ICON_FAMILY            -- "wa Icons", the face this module looks for
M.CODE_POINT = 0xF0766                       -- U+F0766 (ballEmpty): the first glyph wa Icons carries
M.HEX = string.format("%x", M.CODE_POINT)    -- "f0766", the form fontconfig's charset= takes

-- The terminal emulators this module can reason about, keyed by the NAME OF THEIR PROCESS (comm) and
-- answering the name the setup's record and lua/core/font_setup.lua use. An emulator that is not here
-- is "cannot tell", never a guess: wa does not know which file that terminal loads, so it cannot name
-- the face drawing its icons.
M.PROCESSES = {
  foot = "foot", footclient = "footclient", alacritty = "alacritty", kitty = "kitty",
  ghostty = "ghostty", wezterm = "wezterm", ["wezterm-gui"] = "wezterm",
}

-- ---- one shell script: the walk and the stat of every candidate file ------------------------------
--
-- ONE exec, not one per question: resolving the set happens at start-up, and three round trips to a
-- shell would be paid on every 'wa chat'. The script prints a line per fact and Lua decides, so the
-- policy stays testable without a shell.
function M.shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local WALK_HEAD = [[
if [ ! -d /proc ] || [ ! -r /proc/self/stat ]; then printf 'unavailable\n'; exit 0; fi
pid=$PPID
[ -n "$pid" ] || pid=$(awk '{sub(/.*\) /,""); print $2}' < /proc/self/stat)
steps=0
name=
while [ -n "$pid" ] && [ "$pid" -gt 0 ] && [ "$steps" -lt 64 ]; do
  comm=$(cat /proc/$pid/comm 2>/dev/null)
  case "$comm" in
]]

local WALK_TAIL = [[
    *) name= ;;
  esac
  if [ -n "$name" ]; then
    started=$(stat -c %Y /proc/$pid 2>/dev/null)
    printf 'terminal\t%s\t%s\t%s\n' "$name" "$pid" "$started"
    break
  fi
  printf 'seen\t%s\n' "$comm"
  pid=$(awk '{sub(/.*\) /,""); print $2}' < /proc/$pid/stat 2>/dev/null)
  steps=$((steps+1))
done
for pair in @PAIRS@; do
  key=${pair%%=*}
  file=${pair#*=}
  mtime=$(stat -c %Y "$file" 2>/dev/null)
  printf 'stat\t%s\t%s\n' "$key" "$mtime"
done
]]

-- files: array of { key = "<terminal name>", path = "<its config file>" }.
function M.walk_script(files)
  local arms = {}
  for process, name in pairs(M.PROCESSES) do
    arms[#arms + 1] = "    " .. process .. ") name=" .. name .. " ;;"
  end
  table.sort(arms)
  local list = {}
  for _, file in ipairs(files or {}) do
    if type(file) == "table" and tostring(file.key or "") ~= "" and tostring(file.path or "") ~= "" then
      list[#list + 1] = M.shell_quote(tostring(file.key) .. "=" .. tostring(file.path))
    end
  end
  local pairs_text = #list > 0 and table.concat(list, " ") or "''"
  return table.concat({ WALK_HEAD, table.concat(arms, "\n"), (WALK_TAIL:gsub("@PAIRS@", pairs_text)) }, "\n")
end

-- The script's own words, back into a table: { terminal = {name, pid, started_at}, stats = {...},
-- seen = {...}, unavailable = true }. Anything else is ignored rather than guessed at.
function M.parse(text)
  local observation = { seen = {}, stats = {} }
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line == "unavailable" then
      observation.unavailable = true
    elseif line:sub(1, 9) == "terminal\t" then
      local name, pid, started = line:match("^terminal\t([^\t]+)\t(%d+)\t(%d+)$")
      if name then
        observation.terminal = { name = name, pid = tonumber(pid), started_at = tonumber(started) }
        observation.terminal.started_at = observation.terminal.started_at or nil
      end
    elseif line:sub(1, 5) == "seen\t" then
      local comm = line:match("^seen\t([^\t]*)$")
      if comm and comm ~= "" then observation.seen[#observation.seen + 1] = comm end
    elseif line:sub(1, 5) == "stat\t" then
      local key, mtime = line:match("^stat\t([^\t]*)\t(%d*)$")
      if key and key ~= "" then observation.stats[key] = (mtime ~= "" and tonumber(mtime)) or nil end
    end
  end
  return observation
end

-- ONE observation per process: this process draws in one terminal, and asking the shell again would
-- only give the same answer for more milliseconds. A test asks with { fresh = true }.
local OBSERVATION = nil

function M.forget()
  OBSERVATION = nil
end

function M.observe(opts)
  opts = opts or {}
  if OBSERVATION and not opts.fresh then return OBSERVATION end
  local out, why = font_setup.run_shell(M.walk_script(opts.files))
  if not out then return nil, "the walk could not run (" .. tostring(why) .. ")" end
  local observation = M.parse(out)
  if observation.unavailable then
    return nil, "this host has no readable /proc, so a process's start time cannot be read here"
  end
  OBSERVATION = observation
  return observation
end

-- ---- fontconfig: which family draws a code point --------------------------------------------------

-- 'fc-match -f %{family} <pattern>' answers the family fontconfig would use. Cached per pattern: a
-- resolve asks two or three of them and every later caller asks the same.
local FAMILIES = {}

function M.font_query(pattern)
  local key = tostring(pattern or "")
  local cached = FAMILIES[key]
  if cached ~= nil then return cached or nil end
  local answer = nil
  local out = font_setup.run_shell("fc-match -f '%{family}\\n' " .. M.shell_quote(key) .. " 2>/dev/null")
  if type(out) == "string" then
    for line in out:gmatch("[^\r\n]+") do
      local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
      if trimmed ~= "" then answer = trimmed; break end
    end
  end
  FAMILIES[key] = answer or false
  return answer
end

-- Is one of the names in a fontconfig family answer this module's family? fontconfig answers a list
-- ("JetBrainsMono Nerd Font,JetBrainsMono NF"), which is why this compares each name and not the whole
-- string.
function M.names_family(answer, wanted)
  wanted = tostring(wanted or M.FAMILY):lower()
  for name in tostring(answer or ""):gmatch("[^,]+") do
    if name:gsub("^%s+", ""):gsub("%s+$", ""):lower() == wanted then return true end
  end
  return false
end

-- The FIRST name of a fontconfig family answer ("A,B" -> "A"): the name to print, and the one whose
-- coverage the fallback question asks about. Any other name in the list is an alias of the same face.
function M.first_family(answer)
  for name in tostring(answer or ""):gmatch("[^,]+") do
    local clean = name:gsub("^%s+", ""):gsub("%s+$", "")
    if clean ~= "" then return clean end
  end
  return ""
end

-- The family fontconfig answers for the icon code point, given the font the config names.
function M.glyph_family(description, query)
  local family = font_setup.family_of(description)
  if family == "" then family = "monospace" end
  return (query or M.font_query)(family .. ":charset=" .. M.HEX)
end

-- ---- the config's own statement --------------------------------------------------------------------

-- Does the CONFIG hand the icon code points to wa Icons? foot names it in the font list, kitty in a
-- symbol_map and ghostty in a font-codepoint-map, and font_setup.already_a2 is the single reader of that
-- shape (it compares against exactly what the setup writes, so a pre-fix whole-plane symbol_map does not
-- count). For the terminals that let fontconfig pick their fallback there is no line to read: the answer
-- is nil, and the fontconfig measurement answers for them.
function M.config_names_icon_face(terminal, text, description, record)
  if not terminal then return nil end
  if terminal.fallback_line or terminal.kind == "ini" then
    return font_setup.already_a2(description, text, terminal, record) and true or false
  end
  return nil
end

-- ---- the window against the config ----------------------------------------------------------------

-- Did the running window load the config as it stands now? Measured in whole seconds, both from the
-- kernel: > is "the file was already written when this window started", < is "the window is older than
-- the file" and = cannot be ordered at all.
function M.loaded_by_this_window(started_at, written_at)
  started_at, written_at = tonumber(started_at), tonumber(written_at)
  if not started_at then return nil, nil, "the terminal's start time could not be read" end
  if not written_at then return nil, nil, "the config file's write time could not be read" end
  if started_at > written_at then
    return true, M.duration(started_at - written_at) .. " after "
  end
  if started_at < written_at then
    return false, M.duration(written_at - started_at) .. " before "
  end
  return nil, "in the same second as "
end

function M.duration(seconds)
  seconds = math.floor(tonumber(seconds) or 0)
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then
    local hours, minutes = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    return hours .. "h" .. (minutes > 0 and (" " .. minutes .. "m") or "")
  end
  return math.floor(seconds / 86400) .. "d"
end

-- ---- the spaced set, when the glued one is not the truth -------------------------------------------

-- Which set draws the icons when it is NOT wa Icons: the family fontconfig answers for U+F0766, and
-- whether that family HAS the glyph. A face that has it draws its own Nerd-shaped glyph, wider than its
-- cell, which is exactly the set that keeps Victor's one space; a face that does not leaves the code
-- point to something this node cannot name, and the unicode glyphs a stock font carries always draw.
function M.spaced_set(description, query, draws)
  query = query or M.font_query
  draws = draws or font_setup.draws_icons
  local answer = M.glyph_family(description, query)
  local family = M.first_family(answer)
  if family == "" then
    return "unicode", "this machine's fontconfig could not say which face draws U+F0766"
  end
  local has = draws(family)
  if has == true then
    return "nerd", "'" .. family .. "' draws the icon code points, and its glyphs are wider than their cell"
  end
  if has == false then
    return "unicode", "no installed face has U+F0766 ('" .. family .. "' does not), so its stock glyphs are the ones that draw"
  end
  return "unicode", "whether '" .. family .. "' draws the icon code points could not be measured on this machine"
end

-- ---- the answer ------------------------------------------------------------------------------------

-- The config files whose write time matters, one per terminal the setup knows: the path each terminal
-- actually loads (font_setup resolves XDG_CONFIG_HOME for the real home, and a scratch home for a test
-- that hands one over).
function M.candidates()
  local list = {}
  local ok, terminals = pcall(function() return font_setup.terminals() end)
  if ok and type(terminals) == "table" then
    for _, terminal in ipairs(terminals) do
      if terminal.name and terminal.path then
        list[#list + 1] = { key = terminal.name, path = terminal.path }
      end
    end
  end
  return list
end

function M.terminal(name)
  local ok, terminals = pcall(function() return font_setup.terminals() end)
  if not ok or type(terminals) ~= "table" then return nil end
  for _, terminal in ipairs(terminals) do
    if terminal.name == name then return terminal end
  end
  return nil
end

-- The whole decision. Answers { glued = true|false|nil, set = "wa"|"nerd"|"unicode", why = "<sentence>" },
-- where glued is true ONLY when wa Icons was measured to be the face drawing the icon code points in this
-- process's terminal; every other outcome - an older window, an unknown terminal, a fontconfig that
-- prefers another face, a file that cannot be read - names its reason and picks a SPACED set.
--
-- opts (all optional, and every one of them exists so a test can answer without a terminal or a shell):
--   record        the setup record table (its terminals are the files the setup edited)
--   observation   a parsed observation (see M.parse) instead of a real walk
--   files         the candidates to stat (default M.candidates())
--   read          function(path) -> text (default host.read_file)
--   query         function(pattern) -> family (default M.font_query)
--   draws         function(family) -> true|false|nil (default font_setup.draws_icons)
function M.face(opts)
  opts = opts or {}
  local record = opts.record
  local read = opts.read or function(path) return host.read_file(path) end
  local query = opts.query or M.font_query
  local draws = opts.draws or font_setup.draws_icons
  local function unknown(why) return { glued = nil, set = "unicode", why = why } end

  local observation, observe_why = opts.observation, opts.observe_why
  if not observation then observation, observe_why = M.observe({ files = opts.files or M.candidates() }) end
  if not observation then
    return unknown("the terminal this process draws in could not be measured (" .. tostring(observe_why) .. ")")
  end
  local process = observation.terminal
  if not process then
    local chain = #observation.seen > 0 and table.concat(observation.seen, " <- ") or "nothing readable"
    return unknown("no terminal emulator is in this process's ancestry (" .. chain .. ")")
  end
  local name = process.name
  if name == "footclient" then
    return unknown("this is a footclient window: the foot server draws it, and it read its config when the SERVER started, which this window does not date")
  end
  local terminal = M.terminal(name)
  if not terminal or not terminal.path then
    return unknown("wa setup fonts has no config path for a " .. name .. " window")
  end
  local text = read(terminal.path)
  if type(text) ~= "string" then
    return unknown("the config this " .. name .. " window loads could not be read (" .. terminal.path .. ")")
  end

  local description = font_setup.current_font(terminal, text)
  local declared = M.config_names_icon_face(terminal, text, description, record)
  local family = declared and M.FAMILY or M.glyph_family(description, query)
  local loaded, relative, time_why = M.loaded_by_this_window(process.started_at, observation.stats[name])

  -- The two clocks, in the words a reader needs: which window, how far from the edit, and which file.
  local window
  if relative then
    window = "this " .. name .. " window started " .. relative .. "wa setup fonts wrote " .. terminal.path
  else
    window = "this " .. name .. " window's start time and the write time of " .. terminal.path
      .. " could not be compared (" .. tostring(time_why) .. ")"
  end

  if M.names_family(family) then
    local installed = query(M.FAMILY)
    if not M.names_family(installed) then
      local set, why = M.spaced_set(description, query, draws)
      return { glued = false, set = set, why = "'" .. M.FAMILY .. "' is not installed for this user: fontconfig answers '"
        .. tostring(installed or "nothing") .. "' for it, so this " .. name .. " window cannot be drawing it; " .. why }
    end
    if loaded == true then
      return { glued = true, set = "wa", why = "wa Icons draws the icon code points in this " .. name .. " window, which started "
        .. relative .. "wa setup fonts wrote " .. terminal.path }
    end
    local set, why = M.spaced_set(description, query, draws)
    local lead
    if loaded == false then
      lead = window .. ", so it is still drawing the face it loaded then"
    elseif relative then
      lead = window .. ", so which face it loaded cannot be told"
    else
      lead = window .. ", so whether it loaded the edit at all cannot be told"
    end
    return { glued = false, set = set, why = lead .. "; " .. why }
  end
  local set, why = M.spaced_set(description, query, draws)
  return { glued = false, set = set, why = "the config this " .. name .. " window loads does not give the icon code points to "
    .. M.FAMILY .. " (fontconfig answers '" .. (M.first_family(family) ~= "" and M.first_family(family) or "nothing") .. "'), and " .. why }
end

return M
