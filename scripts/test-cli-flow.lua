-- The transcript's flow for one recorded codeact turn (fixtures/events-codeact-turn.json: a real run on work,
-- 17/11 - thinking, commentary, a run block, its result, thinking, the answer), replayed through the view on a
-- transcript that keeps the host's rules (scripts/replay-events.lua). No model, no terminal, ~0.1 s.
--
-- What the operator asked for (17/11 screenshots), one assertion each:
--   - one blank line between the reader's line and the first thought, never two;
--   - thinking has no "Thinking…" title: `✻ ` and the thought on the same row;
--   - thinking and commentary are never glued ("Let me send.Enviando"): one blank line between them;
--   - exactly one blank line above a code block, and one under it;
--   - the code starts at the band's left edge (no inset);
--   - nowhere two blank rows in a row.
WA_SCRIPT_LIBRARY = true
local replay = dofile("scripts/replay-events.lua")
WA_SCRIPT_LIBRARY = nil
local json = dofile("lua/vendor/json.lua")
local events = json.decode(assert(host.read_file("fixtures/events-codeact-turn.json"), "fixture missing"))

local checks, failed = 0, 0
local function ok(value, label)
  checks = checks + 1
  if not value then failed = failed + 1; print("FAIL " .. label) end
end

local blocks = replay.rows(events, { prompt = "the reader's line", width = 100 })
local rows = replay.flat(blocks)
local function blank(row) return row ~= nil and row:match("^%s*$") ~= nil end
local function find(pattern, from)
  for index = from or 1, #rows do if rows[index]:find(pattern) then return index end end
end
local shown = table.concat(rows, "\n")

local reader = find("^\226\157\175 the reader's line")
ok(reader and blank(rows[reader + 1]) and rows[reader + 2]:find("^\226\156\187 ") ~= nil,
  "one blank line, then the first thought on its ✻ row:\n" .. shown)
ok(not shown:find("Thinking\226\128\166", 1, true), "no Thinking… title")
local say = find("^I'll run a tiny script")
ok(say and blank(rows[say - 1]) and not blank(rows[say - 2]), "commentary starts its own row after one blank line")
local code = find("^return 6 %* 7;")
ok(code ~= nil, "the code starts at the band's left edge (no inset): " .. tostring(code and rows[code]))
ok(code and blank(rows[code - 1]) and not blank(rows[code - 2]), "exactly one blank line above the code block")
local result = find("^\226\142\191 42")
ok(result and blank(rows[result + 1]) and not blank(rows[result + 2]), "exactly one blank line under it")
local second = find("^\226\156\187 ", (result or 1))
ok(second ~= nil, "the next thought is a ✻ row")
local doubled
for index = 2, #rows do if blank(rows[index]) and blank(rows[index - 1]) and index < #rows then doubled = index break end end
ok(doubled == nil, "never two blank rows in a row (row " .. tostring(doubled) .. ")")
ok(find("^42$") ~= nil, "the answer is its own row")

if failed > 0 then
  print(string.format("cli flow: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("cli flow ok (%d checks)", checks))
