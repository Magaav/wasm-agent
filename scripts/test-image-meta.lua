-- The pixel size of a stored picture, read from its own header (lua/core/image_meta.lua).
--
-- WHY. Session 6a89dcbc (23/11) was handed a 4x1086 strip of wallpaper as the screenshot it asked for and
-- reasoned about "a thin strip" instead of the page: nothing in the pipeline said how big the picture was.
-- The size now rides with the one honest sentence a text-only model is given (mission
-- run-block-images-reach-model, item 4) and with the paste notice (rust/wa-capabilities/src/host.rs),
-- so the reader must be right about all four formats and must say UNKNOWN rather than guess.
--
-- The JPEG case is the one that was wrong first: segment lengths and frame sizes are BIG-endian there,
-- little-endian in GIF and WebP, and reading them the wrong way round turns a 16-byte segment header into
-- 4096 and walks off the file. The Rust reader had the same defect and this row pins the Lua half of it.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local image_meta = dofile('lua/core/image_meta.lua')

local ROOT = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
local checks = 0
local function ok(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function eq(actual, expected, label)
  checks = checks + 1
  if tostring(actual) ~= tostring(expected) then
    error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end
local function size_of(bytes)
  local width, height = image_meta.size(bytes)
  if not width then return nil end
  return width .. 'x' .. height
end

-- A real PNG this tree ships: the same files the run-block row reads.
local function file_bytes(path)
  local ok_read, raw = pcall(host.read_image_base64, path, 4000000)
  local value = ok_read and json.decode(raw) or nil
  if type(value) ~= 'table' or type(value.base64) ~= 'string' then return nil end
  return memory.base64_decode(value.base64)
end
local RED = file_bytes(ROOT .. '/fixtures/run-images/red-64x48.png')
ok(type(RED) == 'string' and #RED == 125, 'the PNG fixture is readable')
eq(size_of(RED), '64x48', 'a real PNG is measured from its IHDR chunk')

-- PNG built here, so the reader is judged on its own arithmetic rather than on one file.
do
  local function be32(value)
    return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
      math.floor(value / 256) % 256, value % 256)
  end
  local png = '\137PNG\r\n\26\n' .. be32(13) .. 'IHDR' .. be32(800) .. be32(600) .. string.char(8, 2, 0, 0, 0)
  eq(size_of(png), '800x600', 'an 800x600 PNG header is read exactly')
  local strip = '\137PNG\r\n\26\n' .. be32(13) .. 'IHDR' .. be32(4) .. be32(1086) .. string.char(8, 6, 0, 0, 0)
  eq(size_of(strip), '4x1086', 'the 4x1086 strip of session 6a89dcbc reads exactly as itself')
  local bad = '\137PNG\r\n\26\n' .. be32(13) .. 'IHDR' .. be32(0) .. be32(0) .. string.char(8, 2, 0, 0, 0)
  eq(size_of(bad), nil, 'a zero-sized PNG claims no size')
end

-- GIF, WebP and JPEG: each with its own byte order, pinned here so a future rewrite cannot swap them.
do
  local gif = 'GIF89a' .. string.char(4, 0, 62, 4)
  eq(size_of(gif), '4x1086', 'GIF sizes are little-endian')
  local function le16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
  local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local webp = 'RIFF' .. le32(100) .. 'WEBP' .. 'VP8 ' .. le32(50) .. string.char(0, 0, 0)
    .. '\157\001\042' .. le16(320) .. le16(240) .. string.rep('\0', 8)
  eq(size_of(webp), '320x240', 'WebP lossy sizes are 14-bit little-endian')
  local function be16(v) return string.char(math.floor(v / 256) % 256, v % 256) end
  local jpeg = '\255\216' .. '\255\224' .. be16(16) .. string.rep('\0', 14)
    .. '\255\192' .. be16(17) .. '\8' .. be16(480) .. be16(640) .. string.char(3, 1, 34, 0, 2, 17, 1, 3, 17, 1)
  eq(size_of(jpeg), '640x480', 'JPEG segment lengths and frame sizes are BIG-endian')
end

-- Unknown is unknown: no guess from bytes this reader does not know.
eq(size_of('not an image at all'), nil, 'bytes that are no picture claim no size')
eq(size_of(''), nil, 'an empty payload claims no size')
eq(size_of(nil), nil, 'no payload at all claims no size')

print('image meta ok (' .. checks .. ' checks; PNG, GIF, WebP and JPEG headers)')
