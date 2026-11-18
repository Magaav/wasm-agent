-- /keybindings: the list is generated from the table the console dispatches on.
--
-- What can only be tested here (no terminal, no binary): that the command's rows come from
-- host.keybindings and not from a list written in Lua, that a surface and its groups are printed as
-- the capability names them, that a pipe gets the whole list, and that /help says where the keys are.
-- The other direction - that the table the capability answers from is the one the editor, the menu,
-- the transcript, a panel, the pointer and the reader thread dispatch on - is Rust's, in
-- rust/wa-term/src/keymap.rs (every_act_has_a_row, every_row_is_dispatched) and in
-- terminal_editor's no_key_outside_the_table_does_anything.
--
-- Hermetic: a stub host, no node, no terminal.
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end
local function has(text, needle) return type(text) == "string" and text:find(needle, 1, true) ~= nil end
-- A sentence wraps under its key column, so the comparison is on the words, not on where the line
-- broke: whitespace runs are one space in both.
local function flat(text) return (tostring(text or ""):gsub("%s+", " ")) end
local function read(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

-- The rows the capability answers, in the shape host.rs builds them (one object per binding).
local fixture = {
  { surface = "draft", title = "Text area (the draft)", group = "Undo and redo", key = "Ctrl+X",
    does = "redo as well - by design (operator 18/11); Ctrl+Y does the same, and a test asserts it" },
  { surface = "draft", title = "Text area (the draft)", group = "Moving", key = "Home",
    does = "the start of the line the cursor is on (not of the whole draft)" },
  { surface = "draft", title = "Text area (the draft)", group = "Paste and images", key = "Ctrl+V",
    does = "attach an image from the system clipboard as [Image #n], sent with this message" },
  { surface = "fullscreen", title = "Fullscreen console (WA_TUI_KEYS)", group = "Scroll", key = "Ctrl+Home",
    does = "the start of the session" },
  { surface = "fullscreen", title = "Fullscreen console (WA_TUI_KEYS)", group = "Not bound on this node", key = "",
    does = "scroll a page up (WA_TUI_KEYS=<key>=page-up)" },
  { surface = "mouse", title = "Mouse", group = "Pointer", key = "Press",
    does = "press a link: copy that URL to the clipboard" },
}

local function with_host(answer)
  local previous = host
  host = {
    now = function() return 0 end,
    keybindings = function() return answer end,
  }
  return function() host = previous end
end

local keys = dofile("lua/core/keybindings.lua")

-- Absent capability: a reason, never an empty list (an empty list reads as "this console handles
-- no keys", which is a different and untrue fact).
do
  local previous = host
  host = {}
  local rows, problem = keys.rows()
  ok(rows == nil, "no host.keybindings: no rows")
  ok(has(problem, "host.keybindings"), "and the reason names the capability: " .. tostring(problem))
  host = previous
end

-- The rows come from the capability, and the text is the capability's rows.
local restore = with_host(json.encode(fixture))
local rows, problem = keys.rows()
restore()
ok(type(rows) == "table" and #rows == #fixture, "every row the capability answers is read: " .. tostring(problem))
ok(rows and rows[1] and rows[1].key == "Ctrl+X", "in the capability's order, not a sorted or filtered one")

local lines = keys.lines(rows)
local text = keys.text(rows)
for _, row in ipairs(fixture) do
  ok(has(flat(text), flat(row.does)), "the list carries what the capability says for " .. (row.key ~= "" and row.key or row.group))
end
ok(has(text, "Text area (the draft)"), "the surface heading is the capability's own title")
ok(has(text, "Undo and redo"), "the groups are the capability's")
ok(has(text, "Fullscreen console (WA_TUI_KEYS)"), "and the fullscreen console's rows are listed too")
ok(has(text, "(unbound)"), "an action this node has not bound is shown as unbound, not hidden")
ok(has(text, "WA_TUI_KEYS=<key>=page-up"), "with the knob that binds it")
-- The key column is a column: the same description starts at the same offset for every key.
local seen = {}
for _, line in ipairs(lines) do
  local key, does = line:match("^    ([^ ]+) +(.+)$")
  if key then
    local at = #line - #does + 1
    seen[#seen + 1] = at
  end
end
ok(#seen >= 3, "the key rows are laid out as a column: " .. #seen .. " rows")
local column = seen[1]
local aligned = true
for _, at in ipairs(seen) do if at ~= column then aligned = false end end
ok(aligned, "and one column offset for all of them")

-- A page of the balloon: the list is long, so the page size is the column size and not one screen
-- that clips the rest.
local pages = keys.view(rows)
ok(type(pages) == "table" and #pages >= 1, "the list is a page stack a reader moves through")
ok(has(tostring(pages[1].title), "Keys"), "with the command's own title: " .. tostring(pages[1].title))

-- THE RULE: this module knows no key. It lays out what it is given, so no binding can be true here
-- and false in the console. A literal key name in this file is the drift this command exists to end.
local source = read("lua/core/keybindings.lua") or ""
for _, name in ipairs({ "Ctrl+", "Shift+", "PageUp", "PageDown", "Arrow", "Ctrl+X", "Home", "End" }) do
  ok(not has(source, '"' .. name) and not has(source, name .. '"'), "lua/core/keybindings.lua names no key: " .. name)
end

-- With the real binary the rows are the console's own table (rust/wa-term/src/keymap.rs). Asserted
-- here: the list is long enough to be that table, and the keys this mission had to have are in it -
-- Ctrl+X as redo (by design, operator 18/11), Home/End, Ctrl+Home/End, Ctrl+A, Shift+arrows, the
-- three kills, Ctrl+V's image, Ctrl+C/Ctrl+Insert, the pointer's drag, Ctrl+O and Esc.
if type(host) == "table" and type(host.keybindings) == "function" then
  local real = keys.rows()
  ok(type(real) == "table" and #real > 40, "the binary answers the console's rows: " .. tostring(real and #real))
  local real_text = keys.text(real or {})
  for _, needle in ipairs({
    "Ctrl+X", "redo as well - by design (operator 18/11)", "Home", "End", "Ctrl+Home", "Ctrl+End",
    "Ctrl+A", "Shift+Left", "Ctrl+K", "Ctrl+U", "Ctrl+W", "Ctrl+V", "[Image #n]",
    "Ctrl+C", "Ctrl+Insert", "drag: select from where the press landed", "Ctrl+O", "Esc",
  }) do
    ok(has(real_text, needle), "the list the binary answers has " .. needle)
  end
else
  print("note: no host.keybindings in this interpreter - the binary's own rows are asserted in Rust")
end

-- /help mentions it, and the registry row exists (the parity check also requires the REPL's arm).
-- commands.lua loads the memory layer, which asks the host for its clock and paths; this file is not
-- testing that layer, so the host answers everything with an empty no-op and is put back after.
local real_host = host
host = setmetatable({}, { __index = function() return function() return nil end end })
host.now = function() return 0 end
local commands = dofile("lua/core/commands.lua")
host = real_host
local help = commands.help()
ok(has(help, "/keybindings"), "/help names /keybindings")
ok(has(help, "every special key"), "and says what it is for")
local listed = false
for _, row in ipairs(commands.commands) do
  if row.name == "/keybindings" then listed = true; ok(has(row.hint, "key"), "the row promises the keys: " .. row.hint) end
end
ok(listed, "the command registry has the /keybindings row")
ok(has(read("lua/core/chat.lua") or "", 'line == "/keybindings"'), "and the REPL has its arm")
ok(has(read("lua/core/local_views.lua") or "", '["/keybindings"]'), "and the window can open it while a run is in flight")
ok(has(read("lua/core/server.lua") or "", "wa_keybindings"), "and the node serves it to the window")

print(string.format("%d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
