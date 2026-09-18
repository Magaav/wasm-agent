-- The turn's changed files survive the ledger: written with the turn, read back with it.
--
-- The half-wiring this catches: the `changes` column existed, the agent filled the field,
-- and the INSERT did not carry it - so every turn reported its diff and the database kept
-- none of them, silently. A test of the changeset alone cannot see that; only a round trip
-- through append_turn and session_turns can.
local memory = dofile("lua/core/memory.lua")
local json = dofile("lua/vendor/json.lua")
memory.setup()

local session = memory.start_session("", "changes round trip", { title = "changes round trip" })
assert(session, "a session must be creatable")

-- One turn with a change, one without: the second must read back as *no topic*, not as an
-- empty one, or every plain answer would grow a diff header.
local with = { files = { { path = "lua/core/agent.lua", added = 3, removed = 1, recorded = true } },
  added = 3, removed = 1 }
memory.append_turn(session, {
  role = "assistant", content = "did the thing", changes = with,
})
memory.append_turn(session, { role = "assistant", content = "and nothing else" })

local turns = memory.session_turns(session, { limit = 10 })
assert(#turns == 2, "both turns must come back, got " .. #turns)

local first, second = turns[1], turns[2]
assert(type(first.changes) == "table", "the first turn's changes must survive the ledger, got "
  .. tostring(first.changes))
assert(first.changes.added == 3 and first.changes.removed == 1,
  "the counts must survive, got +" .. tostring(first.changes.added)
  .. " -" .. tostring(first.changes.removed))
assert(first.changes.files and #first.changes.files == 1, "the file list must survive")
assert(first.changes.files[1].path == "lua/core/agent.lua", "the path must survive")

assert(second.changes == nil,
  "a turn with no changes must read back as no topic, got " .. tostring(second.changes))

-- The model's view of the transcript must not carry file bodies: `changes` is a summary,
-- and this is the assertion that keeps it one.
local summary = json.encode(first.changes)
assert(summary:find("before") == nil and summary:find("after") == nil,
  "the persisted summary must not carry before/after text: " .. summary)

print("changes round trip ok")
