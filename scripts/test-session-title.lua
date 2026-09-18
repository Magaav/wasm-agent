-- A thread is named after the first thing asked in it, once.
--
-- The name is what makes a list of threads usable: "chat" for every row, or an id, is a list you
-- have to open one by one. It is also the only part of a thread that is *stable* - the conversation
-- drifts, and a name that drifts with it cannot be used to find the thread you remember.
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-session-title.lua wa --db /tmp/x.db
local memory = dofile("lua/core/memory.lua")
memory.setup()

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

local function title_of(id)
  for _, session in ipairs(memory.list_sessions(nil, 200)) do
    if session.id == id then return tostring(session.title or "") end
  end
  return nil
end

local user = "title-test"

-- 1. A new session has no name: "chat" is the placeholder, not a name.
local id = memory.ensure_session(user, "local", "chat")
ok(title_of(id) == "chat", "a new session starts with the placeholder", title_of(id))

-- 2. The first user turn names it, with the markdown furniture taken out.
memory.append_turn(id, { role = "user", content = "## Why is the **status balloon** showing `chat`?\n\nMore detail follows here." })
local named = title_of(id)
ok(named ~= "chat" and named ~= "", "the first user turn names the thread", named)
ok(named:find("Why is the status balloon showing chat?", 1, true) ~= nil,
  "and the name is the message, without markdown", named)
ok(named:find("##", 1, true) == nil and named:find("**", 1, true) == nil,
  "no markdown furniture survives into the name", named)

-- 3. Later turns do not rename it. This is the one that matters: a name that follows the
-- conversation is a name you cannot search for.
memory.append_turn(id, { role = "assistant", content = "Because it is the placeholder." })
memory.append_turn(id, { role = "user", content = "Completely different subject: the bridge retry" })
ok(title_of(id) == named, "a later turn must not rename the thread", title_of(id))

-- 4. A long opening message is cut, and says so.
-- Each case gets its own (user, node) pair, because `ensure_session` deliberately reuses the open
-- session for a pair - which is the behaviour that made the first three cases share one thread.
local long = memory.ensure_session(user, "long", "chat")
memory.append_turn(long, { role = "user", content = string.rep("word ", 40) })
local cut = title_of(long)
ok(#cut <= 62, "a long name is cut to something readable", #cut)
ok(cut:sub(-3) == "\u{2026}", "and the cut is visible, not silent", cut:sub(-6))

-- 5. A turn with no text - an image on its own - does not invent a name.
local image_only = memory.ensure_session(user, "image", "chat")
memory.append_turn(image_only, { role = "user", content = "", images = { { name = "shot.png" } } })
ok(title_of(image_only) == "chat", "an image-only turn leaves the thread unnamed", title_of(image_only))
memory.append_turn(image_only, { role = "user", content = "what is in this screenshot?" })
ok(title_of(image_only) == "what is in this screenshot?", "and the next real message names it", title_of(image_only))

-- 6. A name someone set is not overwritten by a turn.
local chosen = memory.start_session("chosen", "chat", { user_id = user, node_id = "chosen", title = "hand-picked" })
memory.append_turn(chosen, { role = "user", content = "this must not become the name" })
ok(title_of(chosen) == "hand-picked", "a name that was chosen stays", title_of(chosen))

print("session title ok (" .. checks .. " checks)")
