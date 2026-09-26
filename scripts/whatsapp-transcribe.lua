-- A deterministic, local-only voice-note lane. It never asks a model to decide
-- what audio says and never sends an unverified transcript.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local effects = dofile("lua/core/effects.lua")
local paths = dofile("lua/core/paths.lua")

local function quote(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end
local function decode(raw)
  local ok, value = pcall(json.decode, raw or "")
  if ok and type(value) == "table" then return value end
  return nil
end
local function run(command, timeout)
  local result = decode(host.exec(command, "", timeout or 120))
  if not result then return nil, "process_result_unreadable" end
  local answer = decode(result.stdout)
  if not answer then return nil, "process_output_unreadable:" .. tostring(result.stderr or ""):sub(1, 120) end
  if result.code ~= 0 or answer.ok ~= true then return nil, tostring(answer.error or "process_failed") end
  return answer
end
local function script_dir()
  local script = tostring(host.getenv("WA_SCRIPT") or ""):gsub("\\", "/")
  return script:match("^(.*)/") or "."
end
local function audio_kind(message)
  local media = message.media and message.media[1]
  local kind = tostring(media and media.type or "")
  return kind == "ptt" or kind == "audio" or kind == "voice"
end
local function clean(path)
  pcall(host.exec, "rm -f " .. quote(path), "", 10)
end
local function prepare_bodies(id, detail, dir, node)
  local audio = paths.temp() .. "/wa-audio-" .. host.uuid() .. ".ogg"
  local audio_script = host.getenv("WA_WHATSAPP_AUDIO_SCRIPT") or (dir .. "/whatsapp-audio.mjs")
  local fetched, problem = run(table.concat({quote(node),quote(audio_script),"--message-id",quote(id),
    "--chat",quote(detail.conversation_id),"--out",quote(audio)}," "),100)
  if not fetched then clean(audio); return nil,"download",problem end
  local python = host.getenv("WA_WHATSAPP_STT_PYTHON") or "python3"
  local stt_script = host.getenv("WA_WHATSAPP_STT_SCRIPT") or (dir .. "/whatsapp-stt-local.py")
  local models = host.getenv("WA_WHATSAPP_STT_MODELS") or (paths.cache() .. "/whisper")
  local recognized, stt_error = run("HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 WA_WHATSAPP_STT_MODELS=" .. quote(models) .. " " ..
    quote(python) .. " " .. quote(stt_script) .. " --input " .. quote(audio), 120)
  clean(audio)
  if not recognized then return nil,"transcribe",stt_error end
  local formatted = decode(host.invoke("whatsapp_transcript",json.encode({transcript=recognized.transcript})))
  if not formatted or type(formatted.bodies) ~= "table" or #formatted.bodies == 0 then
    return nil,"plugin",tostring(formatted and formatted.error or "plugin_missing")
  end
  for _, body in ipairs(formatted.bodies) do
    if type(body) ~= "string" or body == "" or #body > 15000 then return nil,"plugin","invalid_body" end
  end
  return formatted.bodies
end
local function part_id(id, index) return id .. ":transcript:" .. tostring(index) end

memory.setup()
-- The window, on this process's own clock. `os.time()` is epoch seconds - the same unit the store's
-- `sent_at` is in - so no time zone can shift this, and it is the same bound the reader applies to a
-- reply: audio older than this is not transcribed, and not answered either.
local now = os.time()
local MAX_AGE = tonumber(host.getenv("WA_WHATSAPP_TRANSCRIBE_MAX_AGE_SECONDS") or "") or 600
local cursor = tonumber(memory.meta_get("whatsapp_transcribe_cursor") or 0) or 0
local primed = memory.meta_get("whatsapp_transcribe_primed") == "true"
local cursor_ids = decode(memory.meta_get("whatsapp_transcribe_cursor_ids")) or {}
local pending = decode(memory.meta_get("whatsapp_transcribe_pending")) or {}
-- A note queued in an earlier pass can have gone stale since - the node was busy, the source was down,
-- the job was off. Refused and dropped here rather than transcribed late, and the durable refusal is
-- what settles it so a later pass does not queue it again.
local stale_pending = {}
for id, value in pairs(pending) do
  local at = type(value) == "table" and tonumber(value.sent_at) or nil
  if at and at < now - MAX_AGE then stale_pending[#stale_pending + 1] = tostring(id) end
end
for _, id in ipairs(stale_pending) do
  local detail = pending[id] or {}
  pending[id] = nil
  effects.new("wa-transcript:" .. id).record({message_id=id, conversation_id=tostring(detail.conversation_id or ""),
    decision="transcription_refused", reason="stale_audio"})
end
if #stale_pending > 0 then memory.meta_set("whatsapp_transcribe_pending", json.encode(pending)) end
local floor = math.max(0, cursor - 3600)
for _, value in pairs(pending) do
  if type(value) == "table" and tonumber(value.sent_at) then
    floor = math.min(floor, math.max(0, tonumber(value.sent_at) - 1))
  end
end
local dir = script_dir()
local node = host.getenv("WA_WHATSAPP_NODE") or "node"
local dump = paths.temp() .. "/wa-audio-read-" .. host.uuid() .. ".json"
local read, read_error = run(table.concat({quote(node), quote(dir .. "/whatsapp-read.mjs"),
  "--since", tostring(floor), "--limit", "10000", "--out", quote(dump)}, " "), 90)
if not read then
  print(json.encode({ok=false,step="read",error=read_error,pending=pending}))
  os.exit(1)
end
local payload = decode(host.read_file(dump))
clean(dump)
if not payload or payload.ok ~= true then
  print(json.encode({ok=false,step="read_payload",error="payload_unreadable"}))
  os.exit(1)
end
if tonumber(payload.dropped_over_limit or 0) > 0 then
  print(json.encode({ok=false,step="read",error="browser_store_over_limit",
    dropped=payload.dropped_over_limit}))
  os.exit(1)
end
local newest = tonumber(payload.newest) or cursor
-- The first run adopts the current store. Older notes require an explicit
-- backfill; installing this job must not auto-reply to a historical inbox.
if not primed then
  memory.meta_set("whatsapp_transcribe_cursor", math.floor(newest))
  local primed_ids = {}
  for _, message in ipairs(payload.messages or {}) do
    if tonumber(message.sent_at) == newest then primed_ids[tostring(message.message_id)] = true end
  end
  memory.meta_set("whatsapp_transcribe_cursor_ids", json.encode(primed_ids))
  memory.meta_set("whatsapp_transcribe_primed", "true")
  print(json.encode({ok=true,primed=true,cursor=math.floor(newest),processed=0}))
  return
end
local chats = {}
for _, conversation in ipairs(payload.conversations or {}) do chats[tostring(conversation.id)] = conversation end
local present = {}
local refused = {}
local newest_ids = {}
if newest == cursor then
  for id in pairs(cursor_ids) do newest_ids[id] = true end
end
for _, message in ipairs(payload.messages or {}) do
  local id = tostring(message.message_id or "")
  present[id] = message
  local at = tonumber(message.sent_at) or 0
  if at > newest then newest = at; newest_ids = {} end
  if at == newest then newest_ids[id] = true end
  local chat = chats[tostring(message.conversation_id or "")]
  if (at > cursor or (at == cursor and not cursor_ids[id]))
      and message.direction == "incoming" and audio_kind(message) then
    local reason
    if not chat then reason = "conversation_not_found"
    elseif chat.kind ~= "direct" and chat.kind ~= "group" then reason = "unsupported_chat"
    elseif chat.left ~= false then reason = "membership_unverified" end
    -- The window, after the structural reasons and before anything is queued: audio past the bound is
    -- refused here, so it is never downloaded, never sent to the recognizer, and never sent into the chat.
    -- A missing timestamp fails closed, like every other unverifiable thing in this lane.
    if not reason and (at <= 0 or at < now - MAX_AGE) then
      reason = at <= 0 and "stale_unknown" or "stale_audio"
    end
    if reason then
      local effect = effects.new("wa-transcript:" .. id)
      effect.record({message_id=id,conversation_id=tostring(message.conversation_id),
        decision="transcription_refused",reason=reason})
      refused[#refused + 1] = {message_id=id,reason=reason}
    else
      pending[id] = {conversation_id=tostring(message.conversation_id),sent_at=at}
    end
  end
end
memory.meta_set("whatsapp_transcribe_cursor", math.floor(newest))
memory.meta_set("whatsapp_transcribe_cursor_ids", json.encode(newest_ids))
memory.meta_set("whatsapp_transcribe_pending", json.encode(pending))

local ids = {}
for id in pairs(pending) do ids[#ids + 1] = id end
table.sort(ids, function(a,b)
  return (tonumber(pending[a].sent_at) or 0) < (tonumber(pending[b].sent_at) or 0)
end)
local result = {ok=true,processed=0,pending=#ids,cursor=math.floor(newest),refused=refused}
for _, id in ipairs(ids) do
  local message = present[id]
  local detail = pending[id]
  if message and tostring(message.conversation_id) == detail.conversation_id then
    local effect = effects.new("wa-transcript:" .. id)
    local bodies = detail.bodies
    if type(bodies) ~= "table" or #bodies == 0 then
      local step, problem
      bodies, step, problem = prepare_bodies(id,detail,dir,node)
      if not bodies then
        local terminal = {view_once_refused=true,audio_too_large=true,audio_size_invalid=true,
          audio_mime_invalid=true,not_audio=true,message_identity_mismatch=true,
          no_speech_detected=true,transcript_too_long=true}
        if terminal[problem] then
          effect.record({message_id=id,conversation_id=detail.conversation_id,
            decision="transcription_refused",reason=problem})
          pending[id] = nil
        end
        result = {ok=false,step=step,error=problem,message_id=id,
          state=terminal[problem] and "refused" or "retryable"}
        break
      end
      detail.bodies = bodies
      memory.meta_set("whatsapp_transcribe_pending",json.encode(pending))
    end
    local all_sent = true
    for index, body in ipairs(bodies) do
      local key = part_id(id,index)
      local prior = effect.find(key)
      if prior and prior.state == "sent" then goto next_part end
      if prior then
        if prior.state == "pending" then effect.unknown({message_id=key,detail="prior reservation without confirmation"}) end
        pending[id] = nil
        result = {ok=false,step="reconcile",error="prior_send_ambiguous",message_id=id,part=index,state="unknown"}
        all_sent = false
        break
      end
      local store_send_script = host.getenv("WA_WHATSAPP_STORE_SEND_SCRIPT") or (dir .. "/whatsapp-store-send.mjs")
      local account = tostring(host.getenv("WA_WHATSAPP_ACCOUNT") or "")
      local endpoint = tostring(host.getenv("WA_WHATSAPP_BROWSER_ENDPOINT") or "")
      if account == "" or endpoint == "" then
        result = {ok=false,step="send_config",error="store_identity_unbound",message_id=id,part=index,state="retryable"}
        all_sent = false
        break
      end
      local body_file = paths.temp() .. "/wa-audio-body-" .. host.uuid() .. ".txt"
      if not host.write_file(body_file,body) then
        result = {ok=false,step="body_file",error="body_not_written",message_id=id,part=index}
        all_sent = false
        break
      end
      local reservation = effect.reserve({message_id=key,conversation_id=detail.conversation_id,body=body,limit=#bodies})
      if reservation.status ~= "reserved" then
        clean(body_file)
        result = {ok=false,step="reserve",error=reservation.status,message_id=id,part=index}
        all_sent = false
        break
      end
      local sent, send_error = run(table.concat({quote(node),quote(store_send_script),"--chat",quote(detail.conversation_id),
        "--expect-account",quote(account),"--expect-browser-endpoint",quote(endpoint),
        "--body-file",quote(body_file),"--send"}," "),120)
      clean(body_file)
      if sent and sent.sent == true and sent.verified == true then
        if not effect.confirm({message_id=key,conversation_id=detail.conversation_id,message=sent.message or {}}) then
          result = {ok=false,step="confirm",error="sent_but_confirmation_failed",message_id=id,part=index}
          all_sent = false
          break
        end
      else
        local definitely_unsent = {
          send_resource_busy=true, target_draft_present=true, draft_unknown=true, link_preview_present=true,
          target_composing=true, target_read_only=true, target_archived=true, target_kind_unverified=true,
          unsupported_chat_kind=true, target_identity_unverified=true, chat_not_found=true,
          account_unbound=true, account_unproven=true, account_mismatch=true,
          endpoint_unbound=true, endpoint_unproven=true, endpoint_mismatch=true, endpoint_not_loopback=true,
        }
        if definitely_unsent[send_error] and effect.release({message_id=key}) then
          result = {ok=false,step="send_precheck",error=send_error,message_id=id,part=index,state="retryable"}
        else
          -- An unverified dispatch may have reached WhatsApp; never replay it.
          effect.unknown({message_id=key,detail=send_error or "send_unverified"})
          effect.record({message_id=id,conversation_id=detail.conversation_id,decision="transcription_unknown",reason=send_error or "send_unverified"})
          pending[id] = nil
          result = {ok=false,step="send",error=send_error or "send_unverified",message_id=id,part=index,state="unknown"}
        end
        all_sent = false
        break
      end
    ::next_part::
    end
    if all_sent then
      effect.record({message_id=id,conversation_id=detail.conversation_id,decision="transcribed_sent",reason="local_stt"})
      pending[id] = nil
      result.processed = 1
      result.message_id = id
      result.state = "sent"
    end
    break
  end
end
if result.ok and #ids > 0 and result.processed == 0 then
  result = {ok=false,step="source",error="pending_audio_not_in_browser_store",pending=#ids,cursor=math.floor(newest)}
end
memory.meta_set("whatsapp_transcribe_pending", json.encode(pending))
result.refused = refused
result.pending = 0
for _ in pairs(pending) do result.pending = result.pending + 1 end
print(json.encode(result))
if not result.ok then os.exit(1) end
