-- Full round-trip against the REAL host (sqlite, sha256, file IO), driven by
-- the real binary: store an image, append it to a real turn, read it back out
-- of sqlite, and rebuild the provider context.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()

local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label)
  else print("FAIL " .. label); failures = failures + 1 end
end

local probe_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

-- The sha256 of the base64 *text* of the probe PNG. Computed externally with
-- coreutils (`printf %s '<b64>' | sha256sum`), not by the code under test.
--
-- This is asserted against a fixed constant on purpose: host.sha256() reaches
-- Lua through CStr::from_ptr, which truncates at the first NUL. Hashing the
-- decoded PNG therefore hashed 8 bytes of 70 and produced a plausible-looking
-- but wrong digest. Only an external reference catches that class of bug.
local EXPECTED_SHA256 = "e427046b9065448356fbf74a566c314d2538a7245140c8d042054420675db8f6"

-- Headline check: the real host sha256 must match an externally computed value.
local ref, problem = memory.store_image({
  name = "probe.png", mime = "image/png", data = "data:image/png;base64," .. probe_b64,
})
check(ref ~= nil, "store_image on the real host" .. (problem and (" (" .. problem .. ")") or ""))
check(ref.sha256 ~= nil and #ref.sha256 == 64, "sha256 is 64 hex chars")
print("     sha256 = " .. tostring(ref.sha256))
print("     path   = " .. tostring(ref.path))
check(ref.sha256 == EXPECTED_SHA256, "sha256 matches the externally computed digest")
check(ref.path:find(EXPECTED_SHA256, 1, true) ~= nil, "the path is keyed by that digest")
check(ref.bytes == 70, "byte count is 70")

-- The file must be readable back, byte-identical.
local loaded = memory.load_image(ref)
check(loaded.b64 == probe_b64, "load_image returns the exact stored base64")

-- A real turn, in a real sqlite row, must carry the reference.
local sid = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "image round-trip" })
memory.append_turn(sid, { role = "user", content = "what is in this picture?", images = { ref } })
local rows = memory.session_messages(sid, {})
check(#rows == 1, "one turn was stored")
check(type(rows[1].images) == "table" and #rows[1].images == 1, "the images column survives sqlite as an array")
check(rows[1].images[1].sha256 == ref.sha256, "the stored reference keeps its sha256")
check(rows[1].content == "what is in this picture?", "the text content is untouched")

-- FTS must not have been polluted by base64.
local hits = memory.search_messages("picture", "master", 20)
local found = false
for _, hit in ipairs(hits) do
  if hit.content and hit.content:find("picture", 1, true) then found = true end
  if hit.content and hit.content:find("iVBORw0", 1, true) then
    print("FAIL base64 leaked into the FTS index")
    failures = failures + 1
  end
end
check(found, "text search still finds the turn by its words")

-- build_context must produce the vision shape from the real database.
local bot = agentlib.new(sid, function() end, "master", "master", "")
local messages = bot:build_context()
local user
for _, message in ipairs(messages) do
  if message.role == "user" then user = message end
end
check(user ~= nil, "the user turn appears in the rebuilt context")
check(type(user.content) == "table", "the image turn becomes a parts array")
if type(user.content) == "table" then
  local has_text, has_image = false, false
  for _, part in ipairs(user.content) do
    if part.type == "text" and part.text:find("picture", 1, true) then has_text = true end
    if part.type == "image_url" then
      has_image = true
      check(part.image_url.url:sub(1, 22) == "data:image/png;base64,", "image part is a png data url")
      check(part.image_url.url:sub(-#probe_b64) == probe_b64, "image part carries the exact bytes")
    end
  end
  check(has_text, "the text part is present")
  check(has_image, "the image part is present")
end

-- A read tool result keeps its image reference on the tool row, but the provider
-- gets the image in a following user-role parts message because Chat Completions
-- tool messages accept text, not image_url parts.
local call_id, sibling_id = "read-image-fixture", "grep-sibling-fixture"
memory.append_turn(sid, { role = "assistant", content = "", tool_calls = {
  { id = call_id, type = "function", ["function"] = { name = "read", arguments = '{"path":"probe.png"}' } },
  { id = sibling_id, type = "function", ["function"] = { name = "grep", arguments = '{"pattern":"probe"}' } },
} })
memory.append_turn(sid, { role = "tool", tool_call_id = call_id, tool_name = "read",
  content = json.encode({path="probe.png",type="image",mime="image/png",bytes=70,sha256=ref.sha256}),
  images = { ref } })
memory.append_turn(sid, { role = "tool", tool_call_id = sibling_id, tool_name = "grep",
  content = json.encode({count=0,matches={}}) })
local replay = bot:build_context()
local tool_index,private_reference_leaked = nil,false
for index, message in ipairs(replay) do
  if message.role == "tool" and message.tool_call_id == call_id then tool_index = index end
  if message._images ~= nil then private_reference_leaked = true end
end
check(not private_reference_leaked, "private image references do not cross the provider boundary")
check(tool_index ~= nil, "the image read's textual tool result is replayed")
if tool_index then
  check(replay[tool_index - 1] and replay[tool_index - 1].role == "assistant", "tool result remains adjacent to its tool call")
  check(replay[tool_index + 1] and replay[tool_index + 1].tool_call_id == sibling_id,
    "all sibling tool results remain contiguous before the image")
  local visual = replay[tool_index + 2]
  check(visual and visual.role == "user" and type(visual.content) == "table", "provider receives a visual message after the complete tool block")
  local saw_label, saw_tool_image = false, false
  for _, part in ipairs((visual and visual.content) or {}) do
    if part.type == "text" and part.text:find("probe.png", 1, true) then saw_label = true end
    if part.type == "image_url" and part.image_url.url:sub(-#probe_b64) == probe_b64 then saw_tool_image = true end
  end
  check(saw_label, "the visual message names the image returned by read")
  check(saw_tool_image, "the visual message carries the read image bytes")
end

-- Same bytes a second time must reuse the stored file (content addressing).
local again = memory.store_image({ name = "dup.png", mime = "image/png", data = probe_b64 })
check(again and again.path == ref.path, "identical bytes reuse one file")

print("---")
print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
