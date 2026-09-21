-- The diff route: check, undo, redo, through the handler the UI actually calls.
--
-- The unit tests cover the record; this covers the *route* - that a turn's changes can be
-- found by turn id, that "check" refuses the same things "undo" refuses, and that undo and
-- redo really move the file. That last part is the whole feature: a toggle that reports
-- "undone" while the file is unchanged is the failure this exists to prevent.
local memory = dofile("lua/core/memory.lua")
local changeset = dofile("lua/core/changeset.lua")
local json = dofile("lua/vendor/json.lua")
-- server.lua defines its routes as globals (that is how the host calls them: it loads the
-- chunk and then looks up wa_diff), so it is sourced rather than returned. dofile discards
-- its value, which is why the call below reads the global.
dofile("lua/core/server.lua")
memory.setup()

-- The scratch file goes under the node's own data directory, not the checkout: `paths.tmp`
-- is nil on Windows (there is no such key), and `nil or "."` silently made the repo root the
-- scratch directory - a test that writes into the working tree is a test that dirties it.
local dir = dofile("lua/core/paths.lua").data() .. "/scratch"
local target = dir .. "/wa-diff-route.txt"

local session = memory.start_session("", "diff route", { title = "diff route" })

local function call(payload)
  -- No credential means the trusted local account. A table is not a credential
  -- and must no longer accidentally fall back to master on another interpreter.
  return json.decode(wa_diff(json.encode(payload), ""))
end

-- A real change to a real file, recorded the way a turn records it.
host.write_file(target, "before\n")
local entry = changeset.new()
changeset.record(entry, target, "before\n", "after\n")
host.write_file(target, "after\n")
local message_id = host.uuid()
memory.append_turn(session, {
  id = message_id, role = "assistant", content = "changed it", changes = entry,
})

-- check: undoable, and it wrote nothing.
local checked = call({ message_id = message_id, action = "check" })
assert(checked.can_undo == true, "a fresh change must be undoable, got " .. tostring(checked.reason))
assert(host.read_file(target) == "after\n", "a check must not touch the file")

-- undo: the file goes back. This is the assertion the whole feature rests on.
local undone = call({ message_id = message_id, action = "undo" })
assert(undone.ok == true, "undo must succeed, got " .. tostring(undone.reason))
assert(host.read_file(target) == "before\n",
  "undo must restore the previous text, got " .. tostring(host.read_file(target)))

-- redo: and forward again.
local redone = call({ message_id = message_id, action = "redo" })
assert(redone.ok == true, "redo must succeed, got " .. tostring(redone.reason))
assert(host.read_file(target) == "after\n",
  "redo must reapply the change, got " .. tostring(host.read_file(target)))

-- The refusals, and that they are the *same* refusals "check" would report: a file that
-- moved on is refused, and nothing is written. This is the guard against eating newer work.
host.write_file(target, "someone else was here\n")
local refused = call({ message_id = message_id, action = "undo" })
assert(refused.ok == false and refused.reason:find("changed_since_turn") == 1,
  "a moved-on file must be refused, got " .. tostring(refused.reason))
assert(host.read_file(target) == "someone else was here\n", "a refused undo must not write")

local also_refused = call({ message_id = message_id, action = "check" })
assert(also_refused.can_undo == false and also_refused.reason == refused.reason,
  "check must report the same reason undo would: got " .. tostring(also_refused.reason)
  .. " against " .. tostring(refused.reason))

-- A turn that changed nothing has no topic to undo, and an unknown turn is not a crash.
local plain = host.uuid()
memory.append_turn(session, { id = plain, role = "assistant", content = "no changes" })
local none = call({ message_id = plain, action = "undo" })
assert(none.error == "no_changes", "a plain answer has nothing to undo, got " .. tostring(none.error))
local unknown = call({ message_id = "not-a-message", action = "undo" })
assert(unknown.error == "unknown_turn", "an unknown turn must say so, got " .. tostring(unknown.error))

-- The reasons are reported in words the reader can act on, not as a bare false.
assert(refused.reason and #refused.reason > 0, "a refusal must carry a reason")

print("diff route ok")
