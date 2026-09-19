-- One file written twice in a turn is one change, and its patch is built from the blobs.
--
-- Both halves of this were wrong in the same way: the topic listed the file twice, and the second line
-- described the second edit rather than the turn. That is not a cosmetic problem - undo restores
-- `before`, so a second entry carrying the intermediate text would put the file back to a state the turn
-- itself had created, and the reader would be told their file was restored while looking at the turn's
-- own output.
--
-- Run from the repo root:
--   WA_SCRIPT=scripts/test-changeset.lua wa --db /tmp/changeset.db
local changeset = dofile("lua/core/changeset.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

local function write(path, text)
  ok(host.write_file(path, text), "the test can write " .. path)
end

local root = (os.getenv("WASM_AGENT_TEST_DIR") or "/tmp") .. "/wa-changeset-" .. tostring(host.now())
local one = root .. "/one.txt"
local two = root .. "/two.txt"

-- 1. The same path, twice, in one turn.
local entry = changeset.new()
write(one, "alpha\n")
changeset.record(entry, one, "alpha\n", "alpha\nbeta\n")
changeset.record(entry, one, "alpha\nbeta\n", "alpha\nbeta\ngamma\n")
ok(#entry.files == 1, "one file written twice must be one change, not two lines", #entry.files)
local file = entry.files[1]
ok(file.created == false, "a file that existed when the turn started is not 'created' by a later write")
ok(file.added == 2, "and the counts describe the whole turn, not the last edit", file.added)
ok(file.removed == 0, "with nothing removed", file.removed)
ok(entry.added == 2 and entry.removed == 0, "and the totals are the sum, counted once",
  entry.added .. "/" .. entry.removed)

-- 2. The consequence that matters: undo goes back to where the turn started, not to the
--    intermediate text the turn itself wrote.
write(one, "alpha\nbeta\ngamma\n")
local undone, why = changeset.undo(entry)
ok(undone == true, "undo must succeed on an untouched change", tostring(why))
ok(host.read_file(one) == "alpha\n", "and restore the turn's starting text",
  string.format("%q", tostring(host.read_file(one))))

-- 3. A create, written twice, is still a create - and redo lands on the last text.
local made = root .. "/made.txt"
local entry2 = changeset.new()
changeset.record(entry2, made, "", "one\n")
changeset.record(entry2, made, "one\n", "one\ntwo\n")
ok(#entry2.files == 1, "a created file written twice is still one line", #entry2.files)
ok(entry2.files[1].created == true, "and is still reported as created")
ok(entry2.files[1].added == 2, "with the turn's whole delta", entry2.files[1].added)
write(made, "one\ntwo\n")
ok(changeset.undo(entry2) == true, "undo of a create restores the empty text")
ok(host.read_file(made) == "", "which is what 'created' means here: the host has no remove_file",
  string.format("%q", tostring(host.read_file(made))))
ok(changeset.redo(entry2) == true, "redo applies the change again")
ok(host.read_file(made) == "one\ntwo\n", "landing on the last text the turn wrote, not the first",
  string.format("%q", tostring(host.read_file(made))))

-- 4. A second file is a second line, and the totals count both.
write(two, "x\ny\n")
changeset.record(entry, two, "x\ny\n", "x\n")
ok(#entry.files == 2, "a different path is its own line", #entry.files)
ok(entry.added == 2 and entry.removed == 1, "and the header counts every file once",
  entry.added .. "/" .. entry.removed)

-- 5. The patch: a unified diff built from the two blobs, with counts a parser can trust.
local patched = changeset.patch(entry, one)
ok(patched ~= nil, "a recorded file must be patchable")
ok(patched.patch:find("--- before/", 1, true) == 1, "the patch names the before side",
  patched.patch:sub(1, 40))
ok(patched.patch:find("+++ after/", 1, true) ~= nil, "and the after side")
ok(patched.patch:find("@@ -1,1 +1,3 @@", 1, true) ~= nil,
  "with a hunk header whose counts are real", patched.patch:sub(1, 120))
ok(patched.patch:find("\n+beta", 1, true) ~= nil, "and the added lines marked as added")
ok(patched.truncated == false, "and not truncated for a small file")

-- 6. A file whose text was too large to record cannot be patched, and says which.
local big = root .. "/big.txt"
local entry3 = changeset.new()
local huge = string.rep("line\n", 90000)
changeset.record(entry3, big, "", huge)
ok(entry3.files[1].recorded == false, "text past the cap is recorded as unrecordable")
local none, why3 = changeset.patch(entry3, big)
ok(none == nil, "and cannot be patched")
ok(why3 == "not_recorded", "with a reason, not an empty patch", tostring(why3))

-- 7. Asking for a file this turn did not change is refused by name.
local missing, why4 = changeset.patch(entry, root .. "/never-touched.txt")
ok(missing == nil and why4 == "unknown_path", "an unknown path is refused by name", tostring(why4))

-- 8. A turn recorded before repeats were merged. The entry is built by hand, exactly as the old recorder
--    would have written it: one entry per write, and the second entry's `before` is text the turn itself
--    wrote. Undo restores `before`, so without the merge this restores an intermediate state and reports
--    success - the failure the merge exists to prevent, and worse than a refusal because nothing says so.
local old = root .. "/old.txt"
write(old, "one\ntwo\nthree\n")
local legacy = { files = {
  { path = old, before = changeset.store("one\n"), after = changeset.store("one\ntwo\n"),
    added = 1, removed = 0, recorded = true, created = false },
  { path = old, before = changeset.store("one\ntwo\n"), after = changeset.store("one\ntwo\nthree\n"),
    added = 1, removed = 0, recorded = true, created = false },
}, added = 2, removed = 0 }
local normalized = changeset.normalize(legacy)
ok(#normalized.files == 1, "an entry recorded per write must normalize to one file", #normalized.files)
ok(normalized.files[1].writes == 2, "and say how many writes it was", normalized.files[1].writes)
ok(normalized.added == 2, "with the turn's whole delta", normalized.added)
ok(changeset.undo(normalized) == true, "and undo must succeed")
ok(host.read_file(old) == "one\n", "restoring where the turn started, not the intermediate text",
  string.format("%q", tostring(host.read_file(old))))
-- And what the unmerged entry does instead: it refuses. The first entry's `after` is the intermediate
-- text and the file no longer matches it, so the guard stops the whole thing - which is the right
-- failure, and better than what I first assumed (a silent restore of the wrong text). But it does mean
-- those turns cannot be undone at all, and that is why they are merged as they are read.
write(old, "one\ntwo\nthree\n")
local refused, why5 = changeset.undo(legacy)
ok(refused == nil, "an unmerged entry cannot be undone at all")
ok(why5 == "changed_since_turn:" .. old, "and says which file stopped it", tostring(why5))
ok(host.read_file(old) == "one\ntwo\nthree\n", "leaving the file exactly as it was",
  string.format("%q", tostring(host.read_file(old))))

print("changeset ok (" .. checks .. " checks)")
