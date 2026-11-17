-- The transcript's flow for one recorded codeact turn (fixtures/events-codeact-turn.json: a real run on work,
-- 17/11 - thinking, commentary, a run block, its result, thinking, the answer), replayed through the view on a
-- transcript that keeps the host's rules (scripts/replay-events.lua). No model, no terminal, ~0.1 s.
--
-- What the operator asked for (17/11 screenshots), one assertion each:
--   - one blank line between the reader's line and the first thought, never two;
--   - thinking has no title and no mark, gray;
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
ok(reader and blank(rows[reader + 1]) and rows[reader + 2]:find("^The user wants") ~= nil,
  "one blank line, then the first thought (no mark):\n" .. shown)
ok(not shown:find("\226\156\187", 1, true), "thinking carries no mark")
ok(not shown:find("Thinking\226\128\166", 1, true), "no Thinking… title")
local say = find("^I'll run a tiny script")
ok(say and blank(rows[say - 1]) and not blank(rows[say - 2]), "commentary starts its own row after one blank line")
local code = find("^return 6 %* 7;")
ok(code ~= nil, "the code starts at the band's left edge (no inset): " .. tostring(code and rows[code]))
ok(code and blank(rows[code - 1]) and not blank(rows[code - 2]), "exactly one blank line above the code block")
local result = find("^\226\142\191 42")
ok(result and blank(rows[result + 1]) and not blank(rows[result + 2]), "exactly one blank line under it")
local second = find("^The user wanted", (result or 1))
ok(second and blank(rows[second - 1]), "the next thought follows one blank line")
local doubled
for index = 2, #rows do if blank(rows[index]) and blank(rows[index - 1]) and index < #rows then doubled = index break end end
ok(doubled == nil, "never two blank rows in a row (row " .. tostring(doubled) .. ")")
ok(find("^42$") ~= nil, "the answer is its own row")

-- Commentary and the answer are markdown, rendered as they stream (17/11: `**What I verified**` printed raw).
do
  local md = replay.flat(replay.rows({
    { type = "delta", text = "**What I verified**\n\n- one `ma" },
    { type = "delta", text = "il` account\n" },
    { type = "reply", text = "" },
  }, { width = 100 }))
  local text = table.concat(md, "\n")
  ok(text:find("What I verified", 1, true) and not text:find("**", 1, true), "bold is rendered, not printed raw: " .. text)
  ok(text:find("mail", 1, true) and not text:find("`", 1, true), "inline code across two deltas is rendered: " .. text)
end

if failed > 0 then
  print(string.format("cli flow: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("cli flow ok (%d checks)", checks))
