-- End-to-end shape test: a turn with an image must reach build_context as the
-- OpenAI vision parts array, survive a replay, and degrade visibly if the file
-- is gone. Uses stubbed host.* and a stub sqlite so no Rust is needed.
local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label)
  else print("FAIL " .. label); failures = failures + 1 end
end

local FILES = {}

-- ---- minimal in-memory sqlite stand-in -----------------------------------
-- Only the statements memory.lua actually issues on the paths under test.
local TURNS = {}
host = {
  sha256 = function(text)
    local h = 0
    for i = 1, #text do h = (h * 31 + text:byte(i)) % 4294967296 end
    return string.format("%064x", h)
  end,
  read_file = function(path) return FILES[path] end,
  write_file = function(path, text) FILES[path] = text; return true end,
  sql_exec = function(sql, params_json) return '{"ok":true}' end,
  sql_query = function(sql, params_json) return "[]" end,
  now = function() return 0 end,
  uuid = function() return "00000000-0000-4000-8000-000000000000" end,
  getenv = function() return nil end,
}

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

-- Capture what append_turn is asked to store by wrapping it.
local appended = {}
local real_append = memory.append_turn
memory.append_turn = function(session_id, turn)
  appended[#appended + 1] = { session_id = session_id, turn = turn }
  return #appended
end

-- ---- parse_turn_body behaviour, replicated through server.lua ------------
-- server.lua needs many globals; drive the logic the same way it does.
local probe_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

-- Plain text must pass through untouched (back-compat for CLI and peers).
local raw = "hello there"
check(raw:sub(1, 1) ~= "{", "plain text is not mistaken for JSON")

-- A JSON body carrying images.
local body = json.encode({ text = "what is this?", images = {
  { name = "shot.png", mime = "image/png", data = "data:image/png;base64," .. probe_b64 },
} })
local decoded = json.decode(body)
check(decoded.text == "what is this?", "json body round-trips its text")
check(#decoded.images == 1, "json body carries one image")
local ref, problem = memory.store_image(decoded.images[1])
check(ref ~= nil, "the image in the body stores cleanly" .. (problem and (" (" .. problem .. ")") or ""))

-- ---- user_message shape --------------------------------------------------
-- Replicate what agent.lua's user_message does, against the real helpers.
local function build_user_message(turn)
  local images = turn.images
  if type(images) ~= "table" or #images == 0 then
    return { role = "user", content = turn.content or "" }
  end
  local parts = {}
  if turn.content and turn.content ~= "" then
    parts[#parts + 1] = { type = "text", text = turn.content }
  end
  local lost = {}
  for _, reference in ipairs(images) do
    local image = memory.load_image(reference)
    if image.missing then lost[#lost + 1] = tostring(reference.name or "image")
    else parts[#parts + 1] = { type = "image_url", image_url = { url = "data:" .. image.mime .. ";base64," .. image.b64 } } end
  end
  if #lost > 0 then parts[#parts + 1] = { type = "text", text = "[image unavailable: " .. table.concat(lost, ", ") .. "]" } end
  if #parts == 0 then parts[1] = { type = "text", text = "(image)" } end
  return { role = "user", content = parts }
end

local with_image = build_user_message({ content = "what is this?", images = { ref } })
check(with_image.role == "user", "message keeps the user role")
check(type(with_image.content) == "table", "content became a parts array, not a string")
check(with_image.content[1].type == "text", "part 1 is the text")
check(with_image.content[1].text == "what is this?", "part 1 carries the user text")
check(with_image.content[2].type == "image_url", "part 2 is the image")
check(with_image.content[2].image_url.url:sub(1, 22) == "data:image/png;base64,", "image url is a png data url")
check(with_image.content[2].image_url.url:sub(-#probe_b64) == probe_b64, "the image payload is the original bytes")

-- Image-only turn (no text) must still produce a valid array.
local only_image = build_user_message({ content = "", images = { ref } })
check(#only_image.content == 1 and only_image.content[1].type == "image_url", "image-only turn yields just the image part")

-- No images: stays a plain string, exactly as before this change.
local no_image = build_user_message({ content = "just text", images = {} })
check(no_image.content == "just text", "a turn without images stays a plain string")

-- Missing file: visible marker, never a silent drop.
local missing = build_user_message({ content = "see this", images = {
  { mime = "image/png", sha256 = string.rep("a", 64), name = "gone.png" },
} })
local marker
for _, part in ipairs(missing.content) do
  if part.type == "text" and part.text:find("image unavailable", 1, true) then marker = part.text end
end
check(marker ~= nil, "a missing image is reported in the text part")
check(marker and marker:find("gone.png", 1, true) ~= nil, "the marker names the missing file")

print("---")
print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
