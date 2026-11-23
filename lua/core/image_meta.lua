-- The pixel size of a picture this node holds, for the ONE case that needs it: a model that
-- declares it takes no image input is told where the file is and what size it is, instead of being
-- handed an image part it cannot read or a base64 blob it cannot parse (mission
-- run-block-images-reach-model, item 4).
--
-- Nothing here decides whether a picture is shown - that is memory.image_mime_supported and the read
-- tool's own 4 MB bound. This is a HEADER reader over bytes already stored: PNG, GIF, JPEG and WebP,
-- the four the node stores. A format it does not understand answers nil, and the caller says "pixel
-- size not read" rather than guessing a number.
local M = {}

local function be32(text,at)
  local a,b,c,d = text:byte(at,at+3)
  if not d then return nil end
  return ((a*256+b)*256+c)*256+d
end

local function be24(text,at)
  local a,b,c = text:byte(at,at+2)
  if not c then return nil end
  return (a*256+b)*256+c
end

local function le16(text,at)
  local a,b = text:byte(at,at+1)
  if not b then return nil end
  return a+b*256
end

local function le32(text,at)
  local a,b,c,d = text:byte(at,at+3)
  if not d then return nil end
  return a+b*256+c*65536+d*16777216
end

local function png(text)
  -- Signature, then the IHDR chunk, which must be first: 8 signature + 4 length + 4 type, then
  -- width and height as big-endian 32-bit values.
  if #text < 24 or text:sub(1,8) ~= "\137PNG\r\n\26\n" then return nil end
  if text:sub(13,16) ~= "IHDR" then return nil end
  local width, height = be32(text,17), be32(text,21)
  if not width or not height or width == 0 or height == 0 then return nil end
  return width, height
end

local function gif(text)
  local version = text:sub(1,6)
  if version ~= "GIF87a" and version ~= "GIF89a" then return nil end
  local width, height = le16(text,7), le16(text,9)
  if not width or not height or width == 0 or height == 0 then return nil end
  return width, height
end

local function jpeg(text)
  if text:sub(1,2) ~= "\255\216" then return nil end
  local at = 3
  while at + 8 <= #text do
    local marker = text:byte(at)
    -- Markers are 0xFF then a type byte; padding 0xFF bytes are legal between segments.
    if marker ~= 0xFF then at = at + 1
    else
      local kind = text:byte(at + 1)
      if kind == nil then return nil end
      if kind == 0xFF then at = at + 1
      elseif kind == 0xD8 or kind == 0x01 or (kind >= 0xD0 and kind <= 0xD7) then at = at + 2
      else
        local length = le16(text, at + 3)
        if not length or length < 2 then return nil end
        -- SOF0..SOF15 hold the frame size; C4 (DHT), C8 (JPG) and CC (DAC) are not frames.
        if kind >= 0xC0 and kind <= 0xCF and kind ~= 0xC4 and kind ~= 0xC8 and kind ~= 0xCC then
          local height, width = le16(text, at + 5), le16(text, at + 7)
          if not width or not height or width == 0 or height == 0 then return nil end
          return width, height
        end
        if kind == 0xDA then return nil end -- start of scan: no frame header after this point
        at = at + 2 + length
      end
    end
  end
  return nil
end

local function webp(text)
  if #text < 30 or text:sub(1,4) ~= "RIFF" or text:sub(9,12) ~= "WEBP" then return nil end
  local chunk = text:sub(13,16)
  if chunk == "VP8X" then
    -- Extended: a 24-bit canvas width and height, each stored MINUS one.
    local width, height = be24(text, 25), be24(text, 28)
    if not width or not height then return nil end
    return width + 1, height + 1
  elseif chunk == "VP8 " then
    -- Lossy: a 3-byte frame tag, then the 3-byte start code, then two 14-bit sizes.
    if text:sub(24,26) ~= "\157\001\042" then return nil end
    local width, height = le16(text, 27), le16(text, 29)
    if not width or not height then return nil end
    return width % 16384, height % 16384
  elseif chunk == "VP8L" then
    if text:byte(21) ~= 0x2F then return nil end
    local bits = le32(text, 22)
    if not bits then return nil end
    return bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
  end
  return nil
end

-- <bytes> is the picture's decoded content. Answers width, height, or nil when the header is not one
-- this reader knows: an unknown answer, never a guess.
function M.size(bytes)
  if type(bytes) ~= "string" or bytes == "" then return nil end
  local width, height = png(bytes)
  if not width then width, height = gif(bytes) end
  if not width then width, height = jpeg(bytes) end
  if not width then width, height = webp(bytes) end
  if not width or not height then return nil end
  return width, height
end

M.png, M.gif, M.jpeg, M.webp = png, gif, jpeg, webp
return M
