-- The diff block a reader follows a file change by (change/tui-diff-view, Victor 20/11).
--
-- What is asserted is the DISPLAY decision, which is the part that can be wrong without a model: the
-- path and the +N -M counts, real line numbers on each row, a removed row showing the number it HAD
-- (and no number in the new column), a created file, the fold that states what it hid, the frame a
-- fence draws (so rust/wa-term keeps it whole at any width), the plain rendering with no escape at
-- all, and a change the run could not record saying so instead of drawing an empty diff.
--
-- It goes through the view's own event path (cli_view:event), not the renderer directly, because that
-- is how real use reaches it: lua/core/chat.lua hands the view a change event, and the view draws it.
-- A test of diff_view.rows alone would pass with the event unwired.
--
-- It writes into the change store, so it refuses unless its home is a scratch one.
local paths = dofile("lua/core/paths.lua")
local home = paths.home()
local env_home = host.getenv("WASM_AGENT_HOME") or ""
local scratch = env_home:match("^/tmp/") ~= nil or env_home:match("^/var/folders/") ~= nil
  or (host.getenv("TMPDIR") or ""):match("^/tmp/") ~= nil
if not scratch or env_home == "" then
  print("FAIL diff-view needs a scratch WASM_AGENT_HOME, home is " .. tostring(home))
  os.exit(1)
end

local changeset = dofile("lua/core/changeset.lua")
local diff_view = dofile("lua/core/diff_view.lua")
local markdown = dofile("lua/core/markdown.lua")
local view_lib = dofile("lua/core/cli_view.lua")

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label) failed = failed + 1 end
end
local function has(text, needle, label)
  checks = checks + 1
  if not tostring(text):find(needle, 1, true) then
    print("FAIL " .. label .. ": missing " .. string.format("%q", needle) .. " in:\n" .. tostring(text))
    failed = failed + 1
  end
end
local function visible(text) return (tostring(text):gsub("\27%[[%d;]*m", "")) end
local function cells(text)
  local n, i, s = 0, 1, visible(text)
  while i <= #s do
    local size, width = markdown.char_at(s, i)
    n, i = n + width, i + size
  end
  return n
end

-- A recorder, as scripts/test-cli-view.lua uses: the view writes through out, and the test reads it.
local function recorder()
  local buf = {}
  return {
    out = function(text) buf[#buf + 1] = text end,
    text = function() return table.concat(buf) end,
  }
end

-- One recorded change, exactly as the agent hands it over: the summary entry, which carries the two
-- content addresses. The texts reach the store through changeset.record, the real path.
local function record(before, after, path)
  local M = changeset.new()
  changeset.record(M, path or "/tmp/diff-view-target.lua", before, after)
  local file = M.files[1]
  return { type = "change", name = "edit", path = file.path, before = file.before,
    after = file.after, recorded = file.recorded, added = file.added, removed = file.removed }
end

local before = "local a = 1\nlocal b = 2\nlocal c = 3\n"
local after = "local a = 1\nlocal b = 20\nlocal d = 4\nlocal c = 3\n"

-- ---- a real change, drawn by the view ------------------------------------------
local rec = record(before, after)
local plain = recorder()
local view = view_lib.new({ out = plain.out, live = false, now = function() return 0 end, limit = 80 })
view:event(rec)
local text = plain.text()
has(text, "diff-view-target.lua", "the path is on the block")
has(text, "+2 -1", "the counts are on the block, from the stored record")
-- Real line numbers: the removed line was line 2 of the file it came from, and the two added lines are
-- lines 2 and 3 of the file that replaced it. A diff that numbered its own rows would say 3 and 4.
has(visible(text), string.format("\226\148\130 %2d %2s - ", 2, ""),
  "a removed row carries the old line number and no new one")
has(visible(text), string.format("\226\148\130 %2s %2d + ", "", 2),
  "an added row carries the new line number and no old one")
has(text, "convenience view, not a review", "the footnote says what this is")
has(text, "\226\148\140\226\148\128", "the block opens as a card, the way a fence does")
has(text, "\226\148\148\226\148\128", "and closes as one")
ok(not text:find("\27%[", 1), "a plain view writes no escape sequence at all (the NO_COLOR path)")
ok(view_lib.diff_block ~= nil, "the view exposes the block renderer")

-- The card's own opening row must be exactly the corner and its bar: rust/wa-term only opens a frame
-- on that shape, and a header on it would be read as prose and wrapped outside the border.
local first_row = plain.text():match("[^\n]*")
ok(visible(first_row) == "\226\148\140\226\148\128",
  "the opening row is the bare card corner, got " .. string.format("%q", visible(first_row)))

-- ---- context rows, and an ellipsis between hunks -------------------------------
local big_before = {}
for i = 1, 40 do big_before[i] = "line " .. i end
local big_after = { table.unpack(big_before) }
big_after[2], big_after[38] = "line two", "line thirty-eight"
local big = record(table.concat(big_before, "\n") .. "\n", table.concat(big_after, "\n") .. "\n",
  "/tmp/diff-view-hunks.lua")
local joined = table.concat(view_lib.diff_block({ path = big.path, before = big.before,
  after = big.after }, 80, false) or {}, "\n")
has(joined, "line 3", "context rows are shown around a change")
has(joined, "...", "two distant changes are separated by an ellipsis, not glued together")

-- ---- a big change folds, and says how much it hid ------------------------------
local huge_before, huge_after = {}, {}
for i = 1, 200 do huge_before[i] = "old " .. i; huge_after[i] = "new " .. i end
local huge = record(table.concat(huge_before, "\n") .. "\n", table.concat(huge_after, "\n") .. "\n",
  "/tmp/diff-view-huge.lua")
local huge_rows = table.concat(view_lib.diff_block({ path = huge.path, before = huge.before,
  after = huge.after }, 80, false) or {}, "\n")
local folded = huge_rows:match("%.%.%. %+(%d+) more lines: /console shows all")
ok(folded ~= nil, "a big diff states how many rows it hid and how to see them")
ok(tonumber(folded or "0") > 0, "and the number is not zero")

-- ---- a change the run could not record ---------------------------------------
local plain2 = recorder()
view_lib.new({ out = plain2.out, live = false, now = function() return 0 end, limit = 80 })
  :event({ type = "change", name = "edit", path = "/tmp/unrecorded.lua", recorded = false,
    before = "none", after = "none" })
has(plain2.text(), "no diff shown: not_recorded", "an unrecorded change says so instead of an empty diff")

-- ---- narrow widths ------------------------------------------------------------
local narrow = record(before, after, "/tmp/diff-view-narrow.lua")
local narrow_rows = view_lib.diff_block({ path = narrow.path, before = narrow.before,
  after = narrow.after }, 32, false)
ok(narrow_rows ~= nil and #narrow_rows > 0, "a narrow view still renders the block")
local widest = 0
for _, row in ipairs(narrow_rows or {}) do widest = math.max(widest, cells(row)) end
ok(widest <= 32, "every row fits the width a narrow view has (widest " .. widest .. " of 32)")

-- ---- a created file -----------------------------------------------------------
local created = record("", "one\ntwo\n", "/tmp/diff-view-new.lua")
local created_rows = table.concat(view_lib.diff_block({ path = created.path,
  before = created.before, after = created.after }, 80, false) or {}, "\n")
has(created_rows, "+2 -0", "a created file counts two added lines and no removal")

if failed > 0 then
  print("FAILED " .. failed)
  os.exit(1)
end
print("diff view ok (" .. checks .. " checks)")
