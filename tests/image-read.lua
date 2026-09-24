-- Pi-style read: an image path becomes a referenced visual result, while text
-- keeps the existing exact-page contract. Host and storage are stubbed so the
-- test pins the Lua seam without needing a provider.
local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label)
  else print("FAIL " .. label); failures = failures + 1 end
end

local real_host = host
local json = dofile("lua/vendor/json.lua")
local probe_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
local files = { ["plain.txt"] = "alpha\nbeta\n" }
local text_reads = {}

host = setmetatable({
  sha256 = function(text)
    local h = 0
    for i = 1, #text do h = (h * 31 + text:byte(i)) % 4294967296 end
    return string.format("%064x", h)
  end,
  read_image_base64 = function(path, maximum)
    if path == "renamed.bin" then
      return json.encode({path=path,mime="image/png",bytes=70,base64=probe_b64})
    elseif path == "large.png" then
      return json.encode({error="image_too_large",path=path,bytes=maximum+1,max_bytes=maximum})
    elseif path == "old.bmp" then
      return json.encode({error="unsupported_image_type",path=path,mime="image/bmp"})
    elseif path == "missing.png" then
      return json.encode({error="not_found",path=path})
    end
    return json.encode({error="not_image",path=path})
  end,
  read_file = function(path)
    text_reads[path] = (text_reads[path] or 0) + 1
    if files[path] ~= nil then return files[path] end
    return real_host.read_file(path)
  end,
  write_file = function(path, text) files[path] = text; return true end,
  getenv = function(name) return real_host.getenv(name) end,
  paths = function() return real_host.paths() end,
  sql_exec = function() return '{"ok":true}' end,
  sql_query = function() return "[]" end,
  now = function() return 0 end,
  uuid = function() return "00000000-0000-4000-8000-000000000000" end,
}, { __index = real_host })

local memory = dofile("lua/core/memory.lua")
local file_tools = dofile("lua/core/file_tools.lua")
local function store(entry) return memory.store_image(entry) end

local image = file_tools.read({path="renamed.bin"}, store)
check(image.error == nil and image.type == "image", "read detects an image from bytes, not its extension")
check(image.mime == "image/png" and image.bytes == 70, "image result reports mime and exact byte count")
check(type(image._images) == "table" and #image._images == 1, "image result carries one private attachment reference")
check(image._images and image._images[1].name == "renamed.bin", "stored reference keeps the source file name")
check(not json.encode(image):find(probe_b64, 1, true), "tool result contains no base64 payload")
check(text_reads["renamed.bin"] == nil, "an image never falls through to the UTF-8 reader")

local same = file_tools.read({path="renamed.bin",version=image.version}, store)
check(same.error == nil and same.version == image.version, "image version can be replayed")
local changed = file_tools.read({path="renamed.bin",version=string.rep("f",64)}, store)
check(changed.error == "file_changed" and changed.version == image.version, "stale image version is refused visibly")

local text = file_tools.read({path="plain.txt",offset=2,limit=1}, store)
check(text.error == nil and text.content == "beta\n", "non-images keep the exact text reader")
check(text_reads["plain.txt"] == 1, "text falls through after the image probe")

local large = file_tools.read({path="large.png"}, store)
check(large.error == "image_too_large" and large.max_bytes == 4000000, "oversized images fail with the enforced limit")
local bitmap = file_tools.read({path="old.bmp"}, store)
check(bitmap.error == "unsupported_image_type" and bitmap.mime == "image/bmp", "unsupported image types are named")
local missing = file_tools.read({path="missing.png"}, store)
check(missing.error == "not_found", "a missing path remains not_found")

-- A content-addressed reference points at this node's attachment store. Until
-- node calls have bounded binary transport, `remote read` must refuse instead
-- of returning apparent success with a path on the wrong machine.
local tools = dofile("lua/core/tools.lua")
local identity = json.decode(host.node_identity())
local remote = tools.dispatch(memory,"remote",{
  node=identity.node_id,capability="read",args={path="renamed.bin"},
},"master")
check(remote.error == "remote_image_transport_unsupported", "remote image reads fail visibly instead of leaking a local reference")

print("---")
print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
