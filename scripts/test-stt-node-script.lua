-- The submitter/reader half of `scripts/test-stt-two-nodes.sh`: one JSON answer on stdout, no model,
-- no network of its own. It runs as a `wa --script` process sharing the producer's home, which is
-- the only way an operator (or a test) submits a note with the chat/message ids and the *send time*
-- that the freshness window belongs to - `wa:kernel/speech` carries neither.
--
--   WA_STT_ACTION=submit  WA_STT_AUDIO=<path> [WA_STT_SENT_AT=<ms>] [WA_STT_CHAT=] [WA_STT_MSG=]
--   WA_STT_ACTION=job     WA_STT_JOB=<id>
--   WA_STT_ACTION=status
--   WA_STT_ACTION=identity
--   WA_STT_ACTION=peers
--
-- The audio is a text file in this test (the recognizer is the fake one); a real caller passes bytes
-- that it read through its own capability.
local json = dofile('lua/vendor/json.lua')

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64(text)
  local out = {}
  local i = 1
  while i <= #text do
    local a, b, c = text:byte(i), text:byte(i + 1), text:byte(i + 2)
    local n = (a or 0) * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = ALPHABET:sub(c1 + 1, c1 + 1) .. ALPHABET:sub(c2 + 1, c2 + 1)
    out[#out + 1] = b and ALPHABET:sub(c3 + 1, c3 + 1) or '='
    out[#out + 1] = c and ALPHABET:sub(c4 + 1, c4 + 1) or '='
    i = i + 3
  end
  return table.concat(out)
end

local action = tostring(host.getenv('WA_STT_ACTION') or 'status')
local answer

if action == 'submit' then
  local path = tostring(host.getenv('WA_STT_AUDIO') or '')
  local audio = host.read_file(path)
  if type(audio) ~= 'string' then
    answer = { error = 'audio_unreadable' }
  else
    local request = {
      audio_b64 = base64(audio),
      mime = tostring(host.getenv('WA_STT_MIME') or 'audio/ogg'),
      language = tostring(host.getenv('WA_STT_LANGUAGE') or 'pt'),
      chat = tostring(host.getenv('WA_STT_CHAT') or 'chat'),
      msg = tostring(host.getenv('WA_STT_MSG') or 'note'),
      account = 'test',
      generation = 1,
    }
    local sent = tonumber(host.getenv('WA_STT_SENT_AT') or '')
    if sent then request.sent_at_ms = math.floor(sent) end
    -- The queue is one sqlite file shared with the serving process; a busy writer is retried rather
    -- than reported as a refusal, because a refusal here would read as "the note was stale".
    for attempt = 1, 5 do
      local ok, raw = pcall(host.stt_submit, json.encode(request))
      if ok and raw then
        answer = json.decode(raw)
        if type(answer) ~= 'table' or not answer.error then break end
      else
        answer = { error = 'stt_submit_failed' }
      end
      host.sleep(100)
    end
  end
elseif action == 'job' then
  answer = json.decode(host.stt_admin(json.encode({ action = 'job', job = tonumber(host.getenv('WA_STT_JOB') or '0') })))
elseif action == 'status' then
  answer = json.decode(host.stt_admin(json.encode({ action = 'status' })))
elseif action == 'identity' then
  answer = { ok = { node_id = (json.decode(host.node_identity()) or {}).node_id } }
elseif action == 'peers' then
  local nodes = dofile('lua/core/nodes.lua')
  local list = {}
  for _, node in ipairs(nodes.list()) do
    list[#list + 1] = { node_id = node.node_id, name = node.name, role = node.role, online = node.online }
  end
  answer = { ok = { peers = list } }
else
  answer = { error = 'unknown_action' }
end

print(json.encode(answer or { error = 'no_answer' }))
