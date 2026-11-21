-- WHICH FACE DRAWS wa's ICONS IN THIS TERMINAL (item 5 of the wa-fonts mission, Victor 21/11).
--
-- lua/core/icon_face.lua answers one question - is wa Icons the face drawing the icon code points in the
-- terminal THIS process runs in - and every way of not knowing is a named refusal that lands on a SPACED
-- set. This file proves the parts a table lookup cannot: the /proc walk (across two REAL processes, which
-- is where the bug lives), the parse of that script's words, the window-against-config rule, and the
-- fontconfig fallback.
--
-- It fails on the base by construction: the base has no lua/core/icon_face.lua.
local faces = dofile("lua/core/icon_face.lua")
local font_setup = dofile("lua/core/font_setup.lua")

local failed, checks, skipped = 0, 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end
local function skip(why)
  skipped = skipped + 1
  print("skip " .. why)
end

-- ---- the guard: never probe the operator's own state ------------------------------------------------
-- This file runs a real terminal-shaped process and reads this machine's /proc and fontconfig, so it asks
-- WHERE it is first: inside the operator's own state directory it refuses by name (the 21/11 rule - a
-- fixture that reached ~/.config/foot/foot.ini once already).
local before = host.getenv("WA_HOME_BEFORE_OVERRIDE")
local state = host.getenv("WASM_AGENT_HOME")
if before and before ~= "" and state and state ~= "" then
  if (state:gsub("/+$", "")) == (before:gsub("/+$", "") .. "/.wasm-agent") then
    print("FAIL icon face: this test refuses to run inside the operator's own state directory (" .. state .. ")")
    print("icon face: FAILED (1 checks, 1 failed, 0 skipped)")
    os.exit(1)
  end
end

-- ---- the script this module runs ----------------------------------------------------------------
local script = faces.walk_script({ { key = "foot", path = "/home/someone/.config/foot/foot.ini" } })
ok(script:find("foot) name=foot", 1, true) ~= nil, "the walk knows a foot process by its comm")
ok(script:find("alacritty) name=alacritty", 1, true) ~= nil, "and an alacritty")
ok(script:find("wezterm-gui) name=wezterm", 1, true) ~= nil, "and wezterm's GUI process, under the name the setup uses")
ok(script:find("'foot=/home/someone/.config/foot/foot.ini'", 1, true) ~= nil,
  "the config path is handed to the script, quoted")
ok(script:find("/proc/$pid/comm", 1, true) ~= nil, "the walk reads each ancestor's comm")
ok(script:find("stat -c %Y /proc/$pid", 1, true) ~= nil,
  "a process's start time is the mtime of its /proc directory (measured 21/11: btime + starttime/HZ)")
-- A path with a quote in it is a path, not the end of a shell word.
local quoted = faces.walk_script({ { key = "foot", path = "/tmp/it's here/foot.ini" } })
ok(quoted:find("'foot=/tmp/it'\\''s here/foot.ini'", 1, true) ~= nil,
  "a quote in a path is escaped, not glued to the shell: " .. tostring(quoted:match("for pair in ([^;]+)")))
-- No candidates at all is still a script the shell accepts: an empty word, never 'for pair in ; do'.
local bare = faces.walk_script({})
ok(bare:find("for pair in ''; do", 1, true) ~= nil, "no candidate files is an empty pair list, not a syntax error")

-- ---- the script's words, back into a table ------------------------------------------------------
local parsed = faces.parse(table.concat({
  "seen\tbash",
  "terminal\tfoot\t4242\t1795259917",
  "stat\tfoot\t1795265182",
  "stat\talacritty\t",
}, "\n"))
eq(parsed.terminal.name, "foot", "the terminal line names the emulator")
eq(parsed.terminal.pid, 4242, "and its pid")
eq(parsed.terminal.started_at, 1795259917, "and when it started")
eq(parsed.stats.foot, 1795265182, "the stat line carries the config's write time")
eq(parsed.stats.alacritty, nil, "a file that could not be stat'ed is unknown, not zero")
eq(#parsed.seen, 1, "the ancestors it walked past are kept, so a refusal can name them")
eq(faces.parse("unavailable").unavailable, true, "a host without /proc says so")
eq(faces.parse("garbage\nterminal\tfoot\tnot-a-pid\t1").terminal, nil, "a line it cannot read is not a terminal")

-- ---- the window against the config --------------------------------------------------------------
eq(select(1, faces.loaded_by_this_window(2000, 1000)), true, "a window started after the write loaded it")
eq(select(1, faces.loaded_by_this_window(1000, 2000)), false, "a window started before the write did not")
eq(select(1, faces.loaded_by_this_window(1000, 1000)), nil, "the same second cannot be ordered, and is not a yes")
eq(select(1, faces.loaded_by_this_window(nil, 1000)), nil, "an unreadable start time is not a yes")
eq(select(1, faces.loaded_by_this_window(1000, nil)), nil, "an unreadable config time is not a yes")
local _, older = faces.loaded_by_this_window(1000, 4600)
eq(older, "started 1h before the config was written", "and the reason says how much older, in words: " .. tostring(older))

-- ---- the spaced set, when the glued one is not the truth ----------------------------------------
local function query_of(answers) return function(pattern) return answers[pattern] end end
local NERD_ANSWERS = {
  ["wa Icons"] = "wa Icons",
  ["JetBrains Mono:charset=f0766"] = "JetBrains Mono Nerd Font,JetBrains Mono NF",
  ["monospace:charset=f0766"] = "JetBrains Mono Nerd Font",
}
local function draws_nerd(family) return tostring(family):lower():find("nerd", 1, true) ~= nil end
local set, why = faces.spaced_set("JetBrains Mono:size=9", query_of(NERD_ANSWERS), draws_nerd)
eq(set, "nerd", "a face that HAS the icon code points draws its own wide glyphs: the spaced nerd set")
ok(tostring(why):find("wider than their cell", 1, true) ~= nil, "and says why the space is needed: " .. tostring(why))
eq(select(1, faces.spaced_set("JetBrains Mono:size=9", query_of(NERD_ANSWERS), function() return false end)),
  "unicode", "a face with no icon glyph at all leaves the unicode set")
eq(select(1, faces.spaced_set("JetBrains Mono:size=9", query_of({}), draws_nerd)),
  "unicode", "a fontconfig that cannot be asked leaves the unicode set")
eq(select(1, faces.spaced_set("JetBrains Mono:size=9", query_of(NERD_ANSWERS), function() return nil end)),
  "unicode", "and so does a coverage nobody could measure")
eq(select(1, faces.spaced_set(nil, query_of(NERD_ANSWERS), draws_nerd)), "nerd",
  "a config that names no font falls back to fontconfig's own monospace answer")
eq(select(1, faces.spaced_set("JetBrains Mono:size=9", query_of(NERD_ANSWERS), draws_nerd)) == "wa", false,
  "the spaced fallback is never the glued set")
eq(faces.names_family("JetBrains Mono Nerd Font,JetBrains Mono NF", "wa Icons"), false,
  "a fontconfig answer is read name by name, so a list is not an accident")
eq(faces.names_family("waIcons,wa Icons", "wa Icons"), true, "and the family is found inside a list")

-- ---- the walk, across two real processes --------------------------------------------------------
-- The bug lives between two processes (the terminal and wa), so the walk is proven the same way: a real
-- process whose comm is "foot" - a COPY of this machine's shell, because comm IS the executable's name -
-- with the walk running as ITS child. Everything happens inside one scratch directory this test creates
-- and removes; no real emulator, no real config, no operator file.
local scratch = os.tmpname()
local ran_any = false
local function run(command)
  local ok_run, out = pcall(host.exec, command, "", 20)
  if not ok_run then return nil, tostring(out) end
  return font_setup.decode_exec(out)
end
run("rm -f " .. scratch)
local made = run("mkdir -p " .. scratch .. " && command -v bash")
if not made or made == "" then
  skip("the cross-process walk: no shell to copy on this machine")
else
  local shell = made:gsub("%s+$", "")
  run("cp '" .. shell .. "' " .. scratch .. "/foot")
  local ready = run("chmod +x " .. scratch .. "/foot && echo ready")
  -- A second candidate that does not exist: a file the script cannot stat must come back unknown.
  local walk = faces.walk_script({
    { key = "foot", path = scratch .. "/foot.ini" },
    { key = "missing", path = scratch .. "/nope.ini" },
  })
  local wrote = host.write_file(scratch .. "/walk.sh", walk)
  run("printf 'font=JetBrains Mono:size=9, wa Icons:size=9\\n' > " .. scratch .. "/foot.ini")
  local out, out_why = run("'" .. scratch .. "/foot' -c 'sh " .. scratch .. "/walk.sh foot=" .. scratch .. "/foot.ini missing=" .. scratch .. "/nope.ini; :'")
  if (ready or ""):gsub("%s+$", "") ~= "ready" or not wrote or not out or out == "" then
    -- A host without /proc (or without a shell to copy) is named, never counted as a pass.
    skip("the cross-process walk: this machine could not run it (" .. tostring(copied or out_why or "no answer") .. ")")
  else
    ran_any = true
    local observation = faces.parse(out)
    ok(observation.terminal ~= nil, "the walk finds the emulator in the ancestry: " .. tostring(out):gsub("%s+", " "))
    if observation.terminal then
      eq(observation.terminal.name, "foot", "and names it by the comm it read")
      ok((observation.terminal.pid or 0) > 0, "with the pid it found")
      ok((observation.terminal.started_at or 0) > 0, "and the start time it read from that pid's /proc directory")
      local mtime = run("stat -c %Y " .. scratch .. "/foot.ini")
      eq(observation.stats.foot, tonumber(((mtime or ""):gsub("%s+$", ""))),
        "and the config's write time is the file's own, measured by the same script")
      ok(observation.stats.no_such_file == nil, "a file that is not there is unknown, never zero")
    end
    -- The same script run where no emulator is in the ancestry answers "no terminal", not a wrong one.
    local plain = run("sh " .. scratch .. "/walk.sh foot=" .. scratch .. "/foot.ini")
    local bare_observation = faces.parse(plain or "")
    if bare_observation.terminal and bare_observation.terminal.name == "foot" then
      skip("the no-terminal case: this test is itself running inside a foot window (" .. tostring(observation.terminal and observation.terminal.pid) .. ")")
    else
      ok(#bare_observation.seen >= 1, "run where no emulator is in the ancestry, the walk names what it did see")
    end
  end
  run("rm -rf " .. scratch)
end

-- The module's own observation of THIS process is answered once and kept: a resolve that asked the shell
-- again for every glyph would pay for the walk on every row.
local first_observation = faces.observe({ files = {} })
local second_observation = faces.observe({ files = {} })
ok(first_observation ~= nil, "this process can be observed")
eq(second_observation, first_observation, "and the observation is the same table the second time: asked once per process")
faces.forget()
ok(faces.observe({ files = {} }) ~= first_observation, "and forget() asks again")

-- A real face() run on THIS machine's own state: whatever it answers, it may not answer "glued" without
-- having measured a terminal.
local real = faces.face({})
ok(real.set == "wa" or real.set == "nerd" or real.set == "unicode", "a real run answers one of the sets: " .. tostring(real.set))
if real.glued == true then
  ok(real.why:find("wa Icons draws the icon code points", 1, true) ~= nil, "and a glued answer says what it measured: " .. real.why)
end
ok(real.glued ~= true or real.set == "wa", "the glued answer and the set never disagree")

print(string.format("icon face: %s (%d checks, %d failed, %d skipped)",
  failed == 0 and "ok" or "FAILED", checks, failed, skipped))
os.exit(failed == 0 and 0 or 1)
