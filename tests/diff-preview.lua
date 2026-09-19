-- The line text a diff topic can show, and the counts it shows with it.
--
-- Two things are asserted, and both were wrong before this test existed:
--
--  1. The stored counts and the preview's counts come from the *same* definition of
--     "changed". They used to differ - the header counted a shared prefix and suffix and
--     called everything between them changed, so a one-line edit near the top of a file
--     reported every later line as changed. The hover balloon then painted those untouched
--     lines green and red. Two numbers about one change, disagreeing in the same topic.
--
--  2. A trailing newline is not a line. `(text .. "\n"):gmatch("(.-)\n")` appended a newline
--     to text that already ended in one, so every created file reported one line more than
--     it had.
--
-- Fails loudly rather than printing a soft summary: the gate reads the verdict line.
local changeset = dofile("lua/core/changeset.lua")

local failed = 0
local function check(label, before, after, want_add, want_del, want_lines)
  local M = changeset.new()
  changeset.record(M, "/tmp/preview.txt", before, after)
  local file = M.files[1]
  local preview = changeset.preview_file(file)
  if not preview then
    print("FAIL " .. label .. ": no preview")
    failed = failed + 1
    return
  end
  local problems = {}
  if file.added ~= want_add then problems[#problems + 1] = "header added=" .. file.added .. " wanted " .. want_add end
  if file.removed ~= want_del then problems[#problems + 1] = "header removed=" .. file.removed .. " wanted " .. want_del end
  -- The two must agree: this is the invariant that was broken.
  if preview.added ~= file.added or preview.removed ~= file.removed then
    problems[#problems + 1] = "preview +" .. preview.added .. "-" .. preview.removed
      .. " disagrees with header +" .. file.added .. "-" .. file.removed
  end
  if want_lines and #preview.lines ~= want_lines then
    problems[#problems + 1] = "lines=" .. #preview.lines .. " wanted " .. want_lines
  end
  if #problems > 0 then
    print("FAIL " .. label .. ": " .. table.concat(problems, "; "))
    failed = failed + 1
  end
end

-- Creates and deletes, where the trailing newline used to add a phantom line.
check("create, trailing newline", "", "one\ntwo\n", 2, 0, 2)
check("create, no trailing newline", "", "one\ntwo", 2, 0, 2)
check("create, three lines", "", "a\nb\nc\n", 3, 0, 3)
check("delete", "one\ntwo\n", "", 0, 2, 2)

-- A change in the middle must not claim the untouched lines after it changed: the old
-- prefix/suffix count said +4 -3 for this, and it is +1 -1.
check("one line changed in the middle", "alpha\nbeta\ngamma\ndelta\n", "alpha\nBETA\ngamma\ndelta\n", 1, 1, 2)
check("one line added", "one\ntwo\n", "one\ntwo\nthree\n", 1, 0, 1)
check("one line removed", "one\ntwo\nthree\n", "one\nthree\n", 0, 1, 1)
check("a blank line inside is significant", "a\n\nb\n", "a\n\n\nb\n", 1, 0, 1)

-- The splitting rule itself, against fixed expectations. This is the part a diff rests on, and
-- it cannot be checked through `record`: both sides of that comparison go through the same
-- function, so a consistently wrong count cancels out. The old implementation produced a
-- phantom trailing empty line for "a\n\nb\n" - 4 lines instead of 3 - and every assertion above
-- still passed with that bug present.
local splits = {
  { "", 0, "" },
  { "one", 1, "one" },
  { "one\ntwo\n", 2, "one|two" },
  { "one\ntwo", 2, "one|two" },
  { "a\n\nb\n", 3, "a||b" },
  { "\n", 1, "" },
  { "\na\n", 2, "|a" },
  { "a\n\n", 2, "a|" },
}
for _, case in ipairs(splits) do
  local lines = changeset.split_lines(case[1])
  local got = table.concat(lines, "|")
  if #lines ~= case[2] or got ~= case[3] then
    print("FAIL split_lines(" .. case[1]:gsub("\n", "\\n") .. "): " .. #lines .. " lines ["
      .. got .. "], wanted " .. case[2] .. " [" .. case[3] .. "]")
    failed = failed + 1
  end
end
check("no change at all", "same\n", "same\n", 0, 0, 0)
check("empty to empty", "", "", 0, 0, 0)

-- The preview's lines must be readable text, not addresses: a preview that showed a sha
-- would be worse than none.
local M2 = changeset.new()
changeset.record(M2, "/tmp/text.txt", "old\n", "new\n")
local p2 = changeset.preview_file(M2.files[1])
local kinds = {}
for _, line in ipairs(p2.lines) do kinds[#kinds + 1] = line.kind .. ":" .. line.text end
if table.concat(kinds, ",") ~= "del:old,add:new" then
  print("FAIL preview text: " .. table.concat(kinds, ","))
  failed = failed + 1
end

-- An unrecorded change (too large) must say so rather than pretend to preview.
local M3 = changeset.new()
local huge = string.rep("x\n", 200000)
changeset.record(M3, "/tmp/huge.txt", "", huge)
local p3, why = changeset.preview_file(M3.files[1])
if p3 ~= nil or why ~= "not_recorded" then
  print("FAIL unrecorded change should say not_recorded, got " .. tostring(why))
  failed = failed + 1
end

if failed > 0 then
  print("FAILED " .. failed)
  os.exit(1)
end
print("ALL PASS")
