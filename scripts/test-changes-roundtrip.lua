-- The turn's changed files survive the ledger: written with the turn, read back with it.
--
-- The half-wiring this catches: the `changes` column existed, the agent filled the field,
-- and the INSERT did not carry it - so every turn reported its diff and the database kept
-- none of them, silently. A test of the changeset alone cannot see that; only a round trip
-- through append_turn and session_turns can.
local memory = dofile("lua/core/memory.lua")
local changeset = dofile("lua/core/changeset.lua")
local json = dofile("lua/vendor/json.lua")
memory.setup()

local session = memory.start_session("", "changes round trip", { title = "changes round trip" })
assert(session, "a session must be creatable")

-- The summary is built the way the agent builds it - record through the changeset, then
-- summarise the entry - rather than hand-written. A hand-written fixture drifts from what
-- the server actually produces, which is how the first version of this test asserted a
-- summary missing the very addresses undo needs.
local entry = changeset.new()
changeset.record(entry, "lua/core/agent.lua", "the old text\n", "the new text\n")
local with = changeset.summary(entry)
assert(with, "recording a change must produce a summary")
assert(with.files[1].before and with.files[1].after,
  "the live summary must carry the addresses, or undo has nothing to load")

-- One turn with a change, one without: the second must read back as *no topic*, not as an
-- empty one, or every plain answer would grow a diff header.
memory.append_turn(session, {
  role = "assistant", content = "did the thing", changes = with,
})
memory.append_turn(session, { role = "assistant", content = "and nothing else" })

local turns = memory.session_turns(session, { limit = 10 })
assert(#turns == 2, "both turns must come back, got " .. #turns)

local first, second = turns[1], turns[2]
assert(type(first.changes) == "table", "the first turn's changes must survive the ledger, got "
  .. tostring(first.changes))
assert(first.changes.added == with.added and first.changes.removed == with.removed,
  "the counts must survive as recorded, got +" .. tostring(first.changes.added)
  .. " -" .. tostring(first.changes.removed)
  .. " against +" .. with.added .. " -" .. with.removed)
assert(first.changes.files and #first.changes.files == 1, "the file list must survive")
assert(first.changes.files[1].path == "lua/core/agent.lua", "the path must survive")

assert(second.changes == nil,
  "a turn with no changes must read back as no topic, got " .. tostring(second.changes))

-- The model's view of the transcript must not carry file *bodies*. `changes` names the
-- reversible text by content address (a sha256), which is the whole reason bodies live in
-- the store: a transcript that carried them would be a second copy of the working tree,
-- indexed for search, in every view. So assert the text is absent, not the keys.
local summary = json.encode(first.changes)
assert(summary:find("the new text") == nil and summary:find("the old text") == nil,
  "the persisted summary must not carry file bodies: " .. summary)
-- And assert the addresses ARE there, or undo would have nothing to load.
assert(first.changes.files[1].before and first.changes.files[1].after,
  "the summary must carry the addresses undo loads: " .. summary)
assert(first.changes.files[1].before:match("^%x+$") and #first.changes.files[1].before == 64,
  "an address must be a sha256, got " .. tostring(first.changes.files[1].before))

print("changes round trip ok")
