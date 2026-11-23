-- A picture that lives on ANOTHER node, brought here (mission run-block-images-reach-model, item 3).
--
-- WHAT WAS WRONG. `tools.remote({node, capability:"read", path:"x.png"})` answered
-- `remote_image_transport_unsupported`: the peer's read stored the picture in ITS attachment store and
-- answered a reference whose `path` is a file on the wrong machine, and nothing on the wire could carry
-- the bytes, so lua/core/tools.lua refused rather than hand over a path that does not exist here.
--
-- WHAT TRAVELS NOW, and why it is safe:
--   * the caller asks for the bytes on a read (`image_bytes`), and a peer that does not know the field
--     ignores it - an old peer answers exactly what it answered before, and this node keeps the refusal;
--   * the peer sends `image_data` ONLY for the built-in read's own picture, ONLY below MAX_BYTES, and
--     sends it INSTEAD of the reference (no path from the wrong machine ever reaches this node);
--   * the caller verifies before it stores anything: a supported mime, a base64 whose sha256 is the digest
--     the peer named, and the byte count the peer named (content addressing is the check, so a peer cannot
--     make this node store a picture other than the one it claimed);
--   * then it stores it HERE with memory.store_image - the same store, the same digest, the same
--     content-addressed path a local read uses - and hands the pipeline its own reference, so the picture
--     reaches the model through the mechanism a local read already uses.
--
-- THE CAP is 1,000,000 source bytes, not the read tool's 4 MB: a signed answer crosses wa-mesh, whose own
-- ceiling is MAX_BODY = 4 MiB (rust/wa-mesh/src/http.rs:24), and 4 MB of picture is 5.3 MB of base64 -
-- bigger than the answer allowed to carry it. 1 MB of picture is 1.34 MB of base64, which fits with the rest
-- of the answer. A bigger picture is refused BY NAME with its size and this cap, never silently dropped.
local M = {}

M.MAX_BYTES = 1000000

local function b64_len(bytes) return math.floor((bytes + 2) / 3) * 4 end

-- The message a caller reads when a picture did not travel: the file, the size, the cap. Never silence.
local function refusal(name,bytes,reason)
  return { error = 'remote_image_too_large', capability = 'read', name = name, bytes = bytes,
    max_bytes = M.MAX_BYTES, reason = reason,
    note = 'The picture (' .. tostring(name) .. ', ' .. tostring(bytes) .. ' bytes) was not sent from that '
      .. 'node: a peer transfer carries at most ' .. M.MAX_BYTES .. ' bytes (the signed answer has a 4 MiB '
      .. 'ceiling of its own). Read it on the node that holds it, or copy it here first.' }
end

-- CALLER HALF of the request: the arguments a read travels with. A copy, never the model's own table.
function M.request(args)
  local sent = {}
  if type(args) == 'table' then for key, value in pairs(args) do sent[key] = value end end
  sent.image_bytes = true
  return sent
end

-- PEER HALF: a reference this node holds becomes bytes for the caller, or a named refusal.
-- `load` is memory.load_image. The reference is REMOVED when the bytes travel: a path on this machine
-- means nothing on the caller's, and sending both would invite it to be used.
function M.offer(result, load)
  if type(result) ~= 'table' then return result end
  local references = result._images
  if type(references) ~= 'table' or #references == 0 then return result end
  local reference = references[1]
  local bytes = tonumber(reference.bytes) or 0
  local name = tostring(reference.name or reference.sha256 or 'image')
  if bytes <= 0 then return refusal(name, bytes, 'its size is unknown') end
  if bytes > M.MAX_BYTES then return refusal(name, bytes, 'it is larger than the transfer cap') end
  local image = type(load) == 'function' and load(reference) or nil
  if type(image) ~= 'table' or image.missing or type(image.b64) ~= 'string' or image.b64 == '' then
    return { error = 'remote_image_unavailable', capability = 'read', name = name, bytes = bytes,
      note = 'the stored copy of ' .. name .. ' could not be read on the node that holds it' }
  end
  if #image.b64 > b64_len(M.MAX_BYTES) then
    return refusal(name, bytes, 'its encoded form is larger than the transfer cap')
  end
  local data = { name = name, mime = tostring(reference.mime or image.mime or ''), sha256 = tostring(reference.sha256 or ''),
    bytes = bytes, base64 = image.b64 }
  local answer = {}
  for key, value in pairs(result) do if key ~= '_images' then answer[key] = value end end
  answer.image_data = data
  return answer
end

-- CALLER HALF: verify what the peer said and store it HERE. Answers a reference of this node's own, or
-- nil and a named refusal - never a half-adopted picture.
function M.adopt(memory, result)
  local data = type(result) == 'table' and result.image_data or nil
  if type(data) ~= 'table' then return nil end
  result.image_data = nil
  local name = tostring(data.name or 'image')
  local b64 = data.base64
  if type(b64) ~= 'string' or b64 == '' then
    return nil, { error = 'remote_image_invalid', capability = 'read', name = name,
      note = 'the peer said it sent ' .. name .. ' but sent no picture data' }
  end
  if #b64 > b64_len(M.MAX_BYTES) then
    return nil, refusal(name, tonumber(data.bytes) or 0, 'its encoded form is larger than the transfer cap')
  end
  local mime = tostring(data.mime or '')
  if type(memory.image_mime_supported) ~= 'function' or not memory.image_mime_supported(mime) then
    return nil, { error = 'remote_image_type_unsupported', capability = 'read', name = name, mime = mime,
      note = 'the peer sent ' .. name .. ' as ' .. (mime ~= '' and mime or 'an unnamed type')
        .. ', which this node does not store' }
  end
  local claimed = tostring(data.sha256 or '')
  local actual = host.sha256(b64)
  if claimed == '' or claimed ~= actual then
    return nil, { error = 'remote_image_digest_mismatch', capability = 'read', name = name,
      sha256 = claimed, actual = actual,
      note = 'the picture the peer sent is not the one it named (' .. name .. '): nothing was stored, and '
        .. 'the refusal is the whole answer' }
  end
  local reference, problem = memory.store_image({ name = name, mime = mime, data = b64 })
  if not reference then
    return nil, { error = 'remote_image_store_failed', capability = 'read', name = name, detail = tostring(problem) }
  end
  if reference.sha256 ~= claimed then
    return nil, { error = 'remote_image_digest_mismatch', capability = 'read', name = name,
      sha256 = claimed, actual = tostring(reference.sha256),
      note = 'the picture was stored under a different digest than the one the peer named' }
  end
  return reference
end

return M
