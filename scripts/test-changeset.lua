-- The turn's file changes, and the way back: record, undo, redo, and the refusals.
--
-- This runs in the smoke suite because the failure it guards is the expensive one: an
-- undo that silently reverts *someone else's* newer edit, or one that half-applies and
-- leaves the tree in a state nobody chose. Both look like success from the outside, so
-- only an assertion can tell them apart from a working undo.
local changeset = dofile("lua/core/changeset.lua")

local dir = host.paths().tmp or "."
local function path_of(name) return dir .. "/wa-changeset-" .. name end

-- A tiny stand-in for the host's file calls, so the test is about the record's logic and
-- not about the filesystem. `files` is the whole world.
local files = {}
local real_read, real_write = host.read_file, host.write_file
function host.read_file(p) return files[p] end
function host.write_file(p, text) files[p] = text; return true end

local ok, err = pcall(function()
  -- A plain edit: one line replaced. The header numbers must be the *change*, not the
  -- file: a shared prefix and suffix are what make this +1 -1 on a long file.
  files[path_of("a.txt")] = "one\ntwo\nthree\n"
  local entry = changeset.new()
  changeset.record(entry, path_of("a.txt"), "one\ntwo\nthree\n", "one\nTWO\nthree\n")
  assert(entry.added == 1 and entry.removed == 1,
    "a one-line edit must count +1 -1, got +" .. entry.added .. " -" .. entry.removed)

  local summary = changeset.summary(entry)
  assert(summary and summary.added == 1 and summary.removed == 1, "the summary must carry the counts")
  assert(#summary.files == 1 and summary.files[1].path == path_of("a.txt"), "the file must be named")

  -- Undo puts the file back, redo puts the change back. Both are the real thing: the
  -- assertion is on the *file*, not on a flag.
  files[path_of("a.txt")] = "one\nTWO\nthree\n"          -- as the turn left it
  local done, why = changeset.undo(entry)
  assert(done == true, "undo must succeed, got " .. tostring(why))
  assert(files[path_of("a.txt")] == "one\ntwo\nthree\n",
    "undo must restore the previous text, got " .. tostring(files[path_of("a.txt")]))

  local again, why2 = changeset.redo(entry)
  assert(again == true, "redo must succeed, got " .. tostring(why2))
  assert(files[path_of("a.txt")] == "one\nTWO\nthree\n", "redo must reapply the change")

  -- The guard that matters most: a file that moved on since the turn is REFUSED, and
  -- nothing is written. This is the case where a naive undo eats newer work.
  files[path_of("a.txt")] = "one\nSOMEONE ELSE\nthree\n"
  local refused, reason = changeset.undo(entry)
  assert(refused == nil and reason == "changed_since_turn:" .. path_of("a.txt"),
    "an edited-since file must be refused, got " .. tostring(refused) .. " / " .. tostring(reason))
  assert(files[path_of("a.txt")] == "one\nSOMEONE ELSE\nthree\n",
    "a refused undo must not touch the file")

  -- All-or-nothing: two files, the second one changed. Nothing may be written at all.
  files[path_of("b1.txt")] = "b"
  files[path_of("b2.txt")] = "b"
  local pair = changeset.new()
  changeset.record(pair, path_of("b1.txt"), "b", "B")
  changeset.record(pair, path_of("b2.txt"), "b", "B")
  files[path_of("b1.txt")] = "B"          -- as the turn left it
  files[path_of("b2.txt")] = "MOVED ON"   -- someone else got here first
  local pair_ok, pair_why = changeset.undo(pair)
  assert(pair_ok == nil and pair_why == "changed_since_turn:" .. path_of("b2.txt"),
    "the second file must refuse, got " .. tostring(pair_why))
  assert(files[path_of("b1.txt")] == "B",
    "an all-or-nothing undo must not have written the first file, got " .. tostring(files[path_of("b1.txt")]))

  -- A new file is a content change from empty, and undoing it restores empty rather than
  -- deleting it: the host has no remove_file, so the record says "created" and the text
  -- goes back to "".
  files[path_of("c.txt")] = nil
  local create = changeset.new()
  changeset.record(create, path_of("c.txt"), "", "new file\n")
  files[path_of("c.txt")] = "new file\n"
  assert(changeset.undo(create) == true, "undoing a created file must succeed")
  assert(files[path_of("c.txt")] == "", "the created file goes back to empty, not away")
  assert(changeset.summary(create).files[1].created == true, "the summary must mark it created")

  -- Nothing to undo is a refusal with a reason, not a crash.
  assert(changeset.undo(changeset.new()) == nil, "an empty entry cannot be undone")
  local _, none = changeset.undo(changeset.new())
  assert(none == "nothing_to_undo", "the reason must say nothing_to_undo, got " .. tostring(none))

  print("changeset ok")
end)

host.read_file, host.write_file = real_read, real_write
for _, name in ipairs({ "a.txt", "b1.txt", "b2.txt", "c.txt" }) do files[path_of(name)] = nil end
if not ok then error(err) end
