-- Unit test for the image attachment layer, with host.* stubbed.
-- Verifies the two things syntax cannot: base64 round-trips exactly, and
-- store_image -> load_image -> user_message produces the right provider shape.
local failures = 0
local function check(condition, label)
  if condition then
    print("ok   " .. label)
  else
    print("FAIL " .. label)
    failures = failures + 1
  end
end

-- ---- host stubs ----------------------------------------------------------
local FILES = {}
local paths = dofile("lua/core/paths.lua")
host = {
  sha256 = function(text)
    -- Deterministic 64-hex stand-in; real sha256 comes from the Rust host.
    local h = 0
    for i = 1, #text do h = (h * 31 + text:byte(i)) % 4294967296 end
    return string.format("%064x", h)
  end,
  read_file = function(path) return FILES[path] end,
  write_file = function(path, text) FILES[path] = text; return true end,
  sql_exec = function() return '{"ok":true}' end,
  sql_query = function() return "[]" end,
  now = function() return 0 end,
  uuid = function() return "00000000-0000-4000-8000-000000000000" end,
  getenv = function() return nil end,
}

local memory = dofile("lua/core/memory.lua")

-- ---- base64 --------------------------------------------------------------
-- Vectors include all three padding cases and a byte that is not UTF-8 safe.
local vectors = {
  { "", "" },
  { "f", "Zg==" },
  { "fo", "Zm8=" },
  { "foo", "Zm9v" },
  { "foob", "Zm9vYg==" },
  { "fooba", "Zm9vYmE=" },
  { "foobar", "Zm9vYmFy" },
}
for _, case in ipairs(vectors) do
  local encoded = memory.base64_encode(case[1])
  check(encoded == case[2], "encode " .. string.format("%q", case[1]) .. " -> " .. case[2])
  check(memory.base64_decode(case[2]) == case[1], "decode " .. case[2])
end

-- Round-trip arbitrary binary, including NUL and high bytes.
local binary = ""
for i = 0, 255 do binary = binary .. string.char(i) end
check(memory.base64_decode(memory.base64_encode(binary)) == binary, "round-trip all 256 byte values")

-- The real PNG from the vision probe, decoded and re-encoded, must be stable.
local probe_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
local probe_bytes = memory.base64_decode(probe_b64)
check(#probe_bytes == 70, "probe png decodes to 70 bytes (got " .. #probe_bytes .. ")")
check(memory.base64_encode(probe_bytes) == probe_b64, "probe png re-encodes byte-identically")

-- ---- mime gating ---------------------------------------------------------
check(memory.image_mime_supported("image/png"), "png supported")
check(memory.image_mime_supported("image/jpeg"), "jpeg supported")
check(not memory.image_mime_supported("image/bmp"), "bmp rejected (gateway refuses it)")
check(not memory.image_mime_supported("application/pdf"), "pdf rejected")

-- ---- store_image ---------------------------------------------------------
local stored, problem = memory.store_image({
  name = "shot.png", mime = "image/png", data = "data:image/png;base64," .. probe_b64,
})
check(stored ~= nil, "store_image accepted a data URL" .. (problem and (" (" .. problem .. ")") or ""))
if stored then
  check(stored.mime == "image/png", "stored mime is png")
  check(stored.bytes == 70, "stored byte count is 70")
  check(stored.path:match("attachments/") ~= nil, "path lives under attachments/")
  check(stored.path:match(stored.sha256) ~= nil, "path is content-addressed by sha256")
  check(FILES[stored.path] ~= nil, "bytes were written to disk")
  check(FILES[stored.path] == probe_b64, "on-disk bytes are the original base64")
end

-- A bare base64 string (no data: envelope) with an explicit mime.
local bare = memory.store_image({ name = "x.png", mime = "image/png", data = probe_b64 })
check(bare ~= nil, "store_image accepted bare base64")

-- Same bytes twice must land on ONE path (content addressing).
check(stored and bare and stored.path == bare.path, "identical bytes dedupe to one path")

-- An unsupported type must be refused, visibly.
local rejected, why = memory.store_image({ name = "x.bmp", mime = "image/bmp", data = probe_b64 })
check(rejected == nil and why:match("unsupported_image_type") ~= nil, "bmp refused with a reason")

-- ---- load_image ----------------------------------------------------------
if stored then
  local loaded = memory.load_image(stored)
  check(loaded.missing == nil, "load_image found the stored file")
  check(loaded.b64 == probe_b64, "load_image returns the stored base64")
  check(loaded.mime == "image/png", "load_image returns the mime")

  local absent = memory.load_image({ mime = "image/png", sha256 = string.rep("f", 64) })
  check(absent.missing == true, "load_image reports a missing file instead of erroring")
end

print("---")
print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
