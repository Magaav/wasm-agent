-- Ingest WhatsApp into the ledger, incrementally, with no model in the loop.
--
--   WA_SCRIPT=scripts/whatsapp-ingest.lua wa            (the job runs the .sh beside this file)
--
-- This is the deterministic half of the whatsapp job, and it exists because of a rule: *if a step can
-- be decided without judgement, it must not cost a token*. Reading the inbox, mapping it to ledger
-- rows, and noticing what is new are all mechanical - only "should this be answered, and how" needs a
-- model. So the waking job never scrapes: it wakes to a ledger that is already current.
--
-- What it does:
--   1. `scripts/whatsapp-read.mjs` returns the conversations and the messages newer than a cursor
--      (plus a one-hour rescan, so a message that arrives with an odd timestamp is not lost; the
--      ledger's own `(conversation_id, message_id)` identity makes a rescan free of duplicates);
--   2. incoming audio is transcribed locally before eligible events are emitted; every row then goes
--      through `memory.record_message`, which maintains the full-text index and body hash;
--   3. the cursor moves to the newest message seen, in the database, beside the rows it describes.
--
-- A temporary audio transcription failure exits nonzero so the job retries before inference. A closed
-- browser is a *reported* condition, not a failure:
-- a scheduled job that shouts when the window is shut is a job whose history means nothing.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local paths = dofile("lua/core/paths.lua")

-- One hour of overlap. A cursor alone is brittle: a message whose clock is behind the newest one we
-- have already seen would fall below it and never be read. Overlap plus the ledger's identity is the
-- cheapest way to be sure, and a rescan of an hour costs one query.
local RESCAN_SECONDS = 3600

local function trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- The oldest message this reader still owes a decision for, asked of the ledger rather than carried in the
-- map: the map names the messages, and every one of them was recorded here when it was read, so one query
-- answers "how far back must the window reach" - including for entries written before this existed.
local function oldest_owed(handoffs)
  local ids = {}
  for id in pairs(handoffs) do ids[#ids + 1] = id end
  if #ids == 0 then return nil end
  local marks = {}
  for index = 1, #ids do marks[index] = "?" end
  local rows = json.decode(host.sql_query(
    "SELECT MIN(sent_at) AS oldest FROM ledger_messages WHERE message_id IN (" ..
    table.concat(marks, ",") .. ")", json.encode(ids)) or "")
  if type(rows) == "table" and rows[1] then return tonumber(rows[1].oldest) end
  return nil
end

local function quote(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end

-- `host.exec` hands back a JSON *string* (the host pushes one value), so everything below reads it
-- through here. Comparing fields on the raw string is how a working `node --version` reported itself
-- as `node_missing`.
local function shell(command, timeout)
  local ok, raw = pcall(host.exec, command, "", timeout or 120)
  if not ok then return nil end
  local ok2, decoded = pcall(json.decode, raw)
  if not ok2 or type(decoded) ~= "table" then return nil end
  return decoded
end

local function here()
  local script = host.getenv and host.getenv("WA_SCRIPT") or nil
  if not script or script == "" then return nil end
  return (script:gsub("\\", "/"):match("^(.*)/") or ".")
end

-- The reader is JavaScript because the DevTools Protocol needs a websocket, which this host does not
-- speak. Node is therefore a dependency of the *ingest*, and its absence is reported as such rather
-- than as an empty inbox.
local function node_binary()
  local explicit = host.getenv and host.getenv("WA_WHATSAPP_NODE") or nil
  local candidates = {}
  if explicit and explicit ~= "" then candidates[#candidates + 1] = explicit end
  candidates[#candidates + 1] = "node"
  candidates[#candidates + 1] = "C:/Program Files/nodejs/node.exe"
  candidates[#candidates + 1] = "/c/Program Files/nodejs/node.exe"
  for _, candidate in ipairs(candidates) do
    local result = shell(quote(candidate) .. " --version 2>/dev/null")
    if result and (result.code or 1) == 0 and trim(result.stdout) ~= "" then return candidate end
  end
  return nil
end

local function audio_kind(message)
  local media = message.media and message.media[1]
  local kind = media and media.type or ""
  return kind == "voice" or kind == "ptt" or kind == "audio"
end

local function process_json(command, timeout)
  local result = shell(command, timeout)
  if not result then return nil, "process_result_unreadable" end
  local ok, answer = pcall(json.decode, result.stdout or "")
  if not ok or type(answer) ~= "table" then
    return nil, "process_output_unreadable:" .. trim(result.stderr):sub(1, 100)
  end
  if result.code ~= 0 or answer.ok ~= true then return nil, tostring(answer.error or "process_failed") end
  return answer
end

local function transcribe_audio(directory, node, message)
  local audio = paths.temp() .. "/wa-copilot-audio-" .. tostring(host.uuid()) .. ".ogg"
  local fetch = host.getenv("WA_WHATSAPP_AUDIO_SCRIPT") or (directory .. "/whatsapp-audio.mjs")
  local fetched, fetch_error = process_json(table.concat({quote(node), quote(fetch),
    "--message-id", quote(message.message_id), "--chat", quote(message.conversation_id),
    "--out", quote(audio)}, " "), 100)
  if not fetched then
    pcall(host.exec, "rm -f " .. quote(audio), "")
    return nil, "download", fetch_error
  end
  local python = host.getenv("WA_WHATSAPP_STT_PYTHON") or "python3"
  local script = host.getenv("WA_WHATSAPP_STT_SCRIPT") or (directory .. "/whatsapp-stt-local.py")
  local models = host.getenv("WA_WHATSAPP_STT_MODELS") or (paths.cache() .. "/whisper")
  local answer, stt_error = process_json("HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 " ..
    "WA_WHATSAPP_STT_MODELS=" .. quote(models) .. " " .. quote(python) .. " " ..
    quote(script) .. " --input " .. quote(audio), 120)
  pcall(host.exec, "rm -f " .. quote(audio), "")
  if not answer then return nil, "transcribe", stt_error end
  local transcript = trim(answer.transcript)
  if transcript == "" or #transcript > 12000 or answer.local_only ~= true then
    return nil, "transcribe", "invalid_local_transcript"
  end
  return "[Voice message transcript: " .. transcript .. "]"
end

local function report(line)
  print(line)
end

local function unavailable(reason, detail)
  report(string.format("whatsapp ingest unavailable reason=%s%s", reason,
    detail and (" detail=" .. detail) or ""))
end

-- Emitting, not waking: the ingest knows exactly which messages are new, so it is the only thing that
-- has to *say* so. An event per new incoming message (topic `whatsapp.message`, the message id as the
-- stable event id) means the job store dedupes a repeated emission by itself - `UNIQUE(job_id,
-- revision, event_id)` - so a re-run cannot wake anyone twice for one message. That is the whole
-- reason the emit lives here instead of in a browser listener: nothing to reload, nothing to miss,
-- and a missed emit is recovered by the next pass because the store still holds the message.
local function emit_event(sentinel, topic, event_id, payload)
  if not sentinel then return false, "sentinel_missing" end
  local target = paths.temp() .. "/wa-event-" .. tostring(host.uuid()) .. ".json"
  if not host.write_file(target, json.encode(payload)) then return false, "payload_not_written" end
  local result = shell(table.concat({
    quote(sentinel), "job", "emit", topic, quote(event_id), quote(target),
  }, " "))
  pcall(host.exec, "rm -f " .. quote(target), "")
  if not result or (result.code or 1) ~= 0 then
    return false, trim((result and (result.stderr or result.stdout)) or "no answer"):sub(1, 80)
  end
  return true, nil
end

-- Where the sentinel is, by the same candidate order the shell script uses for `wa`: an explicit
-- override, then beside the install, then the install directory itself.
local function sentinel_binary()
  local explicit = host.getenv and host.getenv("WA_SENTINEL") or nil
  local install = host.getenv and host.getenv("WA_INSTALL_DIR") or nil
  local local_app = host.getenv and host.getenv("LOCALAPPDATA") or nil
  -- Built by appending, not as a table constructor: a nil in the first position makes `ipairs` stop
  -- before it starts, and "the sentinel is missing" was the answer to a sentinel that was there.
  local candidates = {}
  if explicit and explicit ~= "" then candidates[#candidates + 1] = explicit end
  if install and install ~= "" then
    candidates[#candidates + 1] = tostring(install):gsub("\\", "/") .. "/wa-sentinel.exe"
  end
  if local_app and local_app ~= "" then
    candidates[#candidates + 1] = tostring(local_app):gsub("\\", "/") .. "/wasm-agent/wa-sentinel.exe"
  end
  candidates[#candidates + 1] = "/usr/local/bin/wa-sentinel"
  for _, candidate in ipairs(candidates) do
    local result = shell("test -x " .. quote(candidate) .. " && echo yes")
    if result and trim(result.stdout) == "yes" then return candidate end
  end
  return nil
end

local function main()
  local started = host.monotonic_ms and host.monotonic_ms() or 0
  local directory = here()
  if not directory then
    unavailable("no_script_directory")
    return
  end
  local node = node_binary()
  if not node then
    unavailable("node_missing", "the reader needs node for the DevTools websocket")
    return
  end

  memory.setup()
  local cursor = tonumber(memory.meta_get("whatsapp_cursor") or 0) or 0
  local had_cursor = cursor > 0
  local since = math.max(0, cursor - RESCAN_SECONDS)
  -- Messages this reader has handed on, and how many times, keyed by message id. Durable, because the
  -- process that hands a message on is not the one that gets to see it decided: a restart in between would
  -- otherwise forget that anything is owed. This is also what lets a message *below* the cursor be handed
  -- on again - the child's idempotency key makes that a reconcile, not a second child.
  local handoffs = {}
  do
    local ok, stored = pcall(json.decode, memory.meta_get("whatsapp_handoffs") or "")
    if ok and type(stored) == "table" then
      for key, value in pairs(stored) do
        local count = tonumber(value)
        if count and count > 0 then handoffs[tostring(key)] = count end
      end
    end
  end
  -- The window must reach every message that is still owed a decision. The cursor moves past *settled*
  -- messages, so a newer settled one can leave an owed message far below it - outside the ordinary window
  -- above - and then the reader never returns that message again: it is neither re-handed nor pruned, and
  -- this map holds it forever (measured live: the map still held a message whose decision had arrived
  -- twenty minutes earlier). The floor is the oldest owed message, whatever the cursor says.
  local oldest = oldest_owed(handoffs)
  if oldest and (oldest - 1) < since then since = math.max(0, oldest - 1) end

  -- The reader writes its payload to a file because it does not fit in a pipe; this reads it back and
  -- removes it. A failure keeps it, because the one useful thing about a failed read is the bytes
  -- that made it fail.
  local dump = paths.temp() .. "/wa-whatsapp-" .. tostring(host.uuid()) .. ".json"
  -- The operator's own ids are a local binding used to verify a group mention; they are not part of the
  -- reader's output and never leave this machine. Absent, group mentions cannot be verified and every
  -- group message fails closed in the reader's eligibility pass.
  local operator = host.getenv and host.getenv("WA_WHATSAPP_OPERATOR") or nil
  local command = table.concat({
    quote(node),
    quote(directory .. "/whatsapp-read.mjs"),
    "--since", tostring(since),
    "--out", quote(dump),
    (operator and operator ~= "") and ("--operator " .. quote(operator)) or "",
  }, " ")
  local result = shell(command)
  if not result then
    unavailable("reader_not_run")
    return
  end
  local ok_summary, summary = pcall(json.decode, result.stdout or "")
  if not ok_summary or type(summary) ~= "table" or summary.ok ~= true then
    local detail = type(summary) == "table" and (summary.error or "reader_refused") or trim((result.stdout or ""))
    unavailable(tostring(detail):sub(1, 80), tostring(result.stderr or ""):sub(1, 160))
    return
  end
  local raw = host.read_file and host.read_file(dump)
  local ok, payload = pcall(json.decode, raw or "")
  if not ok or type(payload) ~= "table" or payload.ok ~= true then
    unavailable("payload_unreadable", "kept " .. dump)
    return
  end
  -- The first pass has nothing to compare against: adopt the newest message as the cursor and answer
  -- nothing, which is the documented behaviour after a long outage. In the pipeline mode it is also the
  -- only thing that ever moved the cursor off zero - `cursor > 0` was a precondition for acting at all, so
  -- a fresh install handed on nothing and never advanced, and the reader job was the one that set this.
  local newest = tonumber(payload.newest) or 0
  for _, message in ipairs(payload.messages or {}) do
    local at = tonumber(message.sent_at) or 0
    if at > newest then newest = at end
  end
  if cursor <= 0 and newest > 0 then
    cursor = newest
    memory.meta_set("whatsapp_cursor", math.floor(cursor))
  end

  local before = memory.stats().ledger_messages or 0
  for _, conversation in ipairs(payload.conversations or {}) do
    memory.record_conversation({
      id = conversation.id,
      kind = conversation.kind,
      title = conversation.title,
      updated_at = conversation.updated_at,
    })
  end
  -- Emissions are opt-in (`--emit-events` on the shell script), because a wake is a turn and this run
  -- is not the one that decides when the reply job is allowed to cost anything.
  local emit_on = (host.getenv and host.getenv("WA_WHATSAPP_EMIT") or "") ~= ""
  -- The pipeline mode: print the new eligible messages as JSON and let the job's own foreach step
  -- start the children. Emitting here as well would start each one twice - once by event, once by the
  -- loop - so the two modes are exclusive and this flag says which one this run is.
  local json_events = (host.getenv and host.getenv("WA_WHATSAPP_JSON_EVENTS") or "") ~= ""
  local sentinel = emit_on and sentinel_binary() or nil
  if emit_on and not sentinel then
    report("whatsapp ingest note=emit_requested_but_no_sentinel")
  end
  local emitted, emit_error = 0, nil
  local events = {}
  -- Unsupported media and terminal audio refusals are reported instead of being handed to a child.
  local unanswerable = {}
  -- Messages that were handed on as often as this reader is willing to try and are still undecided.
  -- Reported to the operator once, then let go: a bounded attempt count is what stops one permanently
  -- failing message from pinning the cursor for everything behind it.
  local exhausted = {}
  -- Eligible messages the copilot did NOT answer because the operator took the conversation over
  -- themselves. Standing down is the right call and it costs no token, but it is invisible: the operator
  -- sees no reply and has no way to tell "the copilot decided not to" from "the copilot never saw it".
  -- Reported to the operator's own inbox, once per message (the stand-down clears the owed entry, so a
  -- later pass cannot report it again).
  local stood_down = {}
  -- The newest message this run actually *decided* about - decided meaning a durable decision exists for
  -- it (a child's `effect_decisions` row, an eligibility refusal, the operator having answered, a media
  -- report). The cursor moves to this and no further, so a message nobody acted on stays newer than the
  -- cursor and is picked up by the next run. Advancing to `newest` consumed messages silently - twice,
  -- before this rule existed - and advancing when a message had merely been *handed on* consumed them
  -- once more: a child that failed to decide left a message the cursor had already passed.
  local handled = 0
  local skipped_ineligible = 0
  local skipped_answered = 0
  local skipped_decided = 0
  -- How many times one message may be handed on before the reader stops trying.
  local MAX_HANDOFFS = 3
  -- (The owed map itself is loaded before the read, because the read window depends on it.)
  local handoffs_changed = false
  -- Every message that already has a durable decision, in one query: a lookup per message would be one
  -- sqlite round trip per message per pass, and the whole point of this pass is that it is cheap. If the
  -- query fails the reader says so and treats nothing as decided, which re-hands what it can (bounded)
  -- rather than silently skipping a message nobody decided.
  local decided, decisions_error = {}, nil
  do
    local ok, rows = pcall(json.decode, host.sql_query("SELECT message_id FROM effect_decisions", "[]") or "")
    if not ok or type(rows) ~= "table" or rows.error then
      decisions_error = tostring(ok and type(rows) == "table" and rows.error or "decisions_unreadable")
    else
      for _, row in ipairs(rows) do
        if type(row) == "table" and row.message_id then decided[tostring(row.message_id)] = true end
      end
    end
  end
  -- Who spoke last in each conversation. An incoming message the operator has already answered is not the
  -- copilot's to answer: they took the lead, and a second reply would be an interruption. Deterministic,
  -- so standing down costs no token at all - and the operator's own reply is the newest message in the
  -- store by the time the next tick reads it, which is exactly why this can be decided here.
  local newest_outgoing = {}
  for _, message in ipairs(payload.messages or {}) do
    if message.direction == "outgoing" then
      local conversation = message.conversation_id
      local at = message.sent_at or 0
      if (newest_outgoing[conversation] or 0) < at then newest_outgoing[conversation] = at end
    end
  end
  -- An audio event may wake the responder only after its transcript is in the ledger. Do this before
  -- recording or emitting *any* event, so a retryable recognition failure cannot let a later text
  -- message infer against an incomplete conversation. A rescan reuses the durable transcript.
  for _, message in ipairs(payload.messages or {}) do
    local at = tonumber(message.sent_at) or 0
    local id = tostring(message.message_id or "")
    if audio_kind(message) then
      local query_ok, rows = pcall(function()
        return json.decode(host.sql_query(
          "SELECT body, source FROM ledger_messages WHERE conversation_id=? AND message_id=?",
          json.encode({message.conversation_id, id})) or "")
      end)
      if not query_ok or type(rows) ~= "table" or rows.error then
        error("audio_transcript_cache_unreadable:" .. id)
      end
      -- The cursor is seconds, while two messages can arrive in the same second. A previously unseen
      -- audio id is new even when its timestamp equals (or slightly trails) the cursor.
      message.new_audio = had_cursor and rows[1] == nil
      local verdict = message.eligibility
      local eligible = type(verdict) == "table" and verdict.eligible == true
      local candidate = (emit_on or json_events) and message.direction == "incoming" and
        eligible and (at > cursor or handoffs[id] ~= nil or message.new_audio) and
        (newest_outgoing[message.conversation_id] or 0) <= at and not decided[id]
      if rows[1] and rows[1].source == "whatsapp-cdp-stt" then
        message.body = rows[1].body
        message.source = "whatsapp-cdp-stt"
      elseif candidate then
        local body, step, problem = transcribe_audio(directory, node, message)
        if body then
          message.body = body
        else
          local terminal = {view_once_refused=true, audio_too_large=true,
            audio_size_invalid=true, audio_mime_invalid=true, not_audio=true,
            message_identity_mismatch=true, no_speech_detected=true,
            transcript_too_long=true}
          if terminal[problem] then
            message.transcription_refusal = problem
          else
            pcall(host.exec, "rm -f " .. quote(dump), "")
            local failure = {events={}, error="audio_transcription_failed", step=step,
              reason=problem, message_id=id, conversation_id=message.conversation_id,
              retryable=true}
            if json_events then print(json.encode(failure))
            else report("whatsapp ingest failed " .. json.encode(failure)) end
            os.exit(1)
          end
        end
      end
      if candidate and not message.transcription_refusal then message.source = "whatsapp-cdp-stt" end
    end
  end
  for _, message in ipairs(payload.messages or {}) do
    memory.record_message({
      conversation_id = message.conversation_id,
      message_id = message.message_id,
      sender_id = message.sender_id,
      direction = message.direction,
      sent_at = message.sent_at,
      body = message.body,
      media = message.media,
      source = message.source or "whatsapp-cdp",
      observed_at = host.now(),
    })
    -- Only what arrived after the previous read, only what somebody else sent, and only what the
    -- deterministic eligibility rule accepts: a group mention, archived, left and unknown metadata are
    -- all decided without a model, here. The reply job never wakes for a message a rule already excludes.
    local verdict = message.eligibility
    local eligible = type(verdict) == "table" and verdict.eligible == true
    -- Either mode acts on a new message: `emit_on` hands it to an event consumer, `json_events` hands it to
    -- the pipeline step that asked for the list. Requiring `emit_on` here meant the pipeline mode collected
    -- nothing at all - every run completed having handed on no messages, which is how a private message went
    -- unanswered while the job looked healthy.
    local at = tonumber(message.sent_at) or 0
    local message_id = tostring(message.message_id or "")
    -- A candidate is a message that is new, or one this reader handed on before and that no decision has
    -- been recorded for since. The second half is what makes a message below the cursor recoverable.
    local pending = handoffs[message_id] ~= nil
    if (emit_on or json_events) and message.direction == "incoming" and
        (at > cursor or pending or message.new_audio) then
      local media_kind = (message.media and message.media[1] and message.media[1].type) or "chat"
      local answered_by_operator = (newest_outgoing[message.conversation_id] or 0) > at
      if answered_by_operator then
        -- The operator took the lead in this conversation; standing down is a decision, and it costs no
        -- token to make it here. Said out loud rather than done quietly: a message nobody answered must
        -- never be indistinguishable from a message the copilot chose not to answer.
        skipped_answered = skipped_answered + 1
        handled = math.max(handled, at)
        if handoffs[message_id] then handoffs[message_id] = nil; handoffs_changed = true end
        if json_events then
          stood_down[#stood_down + 1] = {
            message_id = message_id,
            conversation_id = message.conversation_id,
            sent_at = at,
            took_over_at = newest_outgoing[message.conversation_id] or 0,
          }
        end
      elseif not eligible then
        -- A rule already excludes it: a group message that does not name the operator, an archived or left
        -- chat, metadata that cannot be verified. The reply job never wakes for one of these.
        skipped_ineligible = skipped_ineligible + 1
        handled = math.max(handled, at)
        if handoffs[message_id] then handoffs[message_id] = nil; handoffs_changed = true end
      elseif decided[message_id] then
        -- Somebody decided it durably. Only now may the cursor pass it - this is the whole fix: the cursor
        -- used to move when the message was handed on, so a child that never decided lost it.
        skipped_decided = skipped_decided + 1
        handled = math.max(handled, at)
        if handoffs[message_id] then handoffs[message_id] = nil; handoffs_changed = true end
      elseif media_kind ~= "chat" and not (audio_kind(message) and message.source == "whatsapp-cdp-stt") then
        -- Unsupported media and terminal audio refusals are reported without waking a responder.
        handled = math.max(handled, at)
        if handoffs[message_id] then handoffs[message_id] = nil; handoffs_changed = true end
        unanswerable[#unanswerable + 1] = {
          message_id = message.message_id,
          conversation_id = message.conversation_id,
          media = media_kind,
          reason = message.transcription_refusal,
          sent_at = at,
        }
      elseif (handoffs[message_id] or 0) >= MAX_HANDOFFS then
        -- Handed on as often as this reader is willing to try, and still undecided. Bounded rather than
        -- retried forever, and said out loud rather than dropped: the operator gets one line, and the
        -- cursor is allowed to move past it.
        exhausted[#exhausted + 1] = {
          message_id = message.message_id,
          conversation_id = message.conversation_id,
          attempts = handoffs[message_id] or 0,
          sent_at = at,
        }
        handled = math.max(handled, at)
        handoffs[message_id] = nil
        handoffs_changed = true
      else
        -- Hand it on, and remember that we did. The cursor is deliberately NOT advanced: this message is
        -- owed a decision, and the next pass hands it on again until one exists (the child's idempotency
        -- key makes that a reconcile, not a second child) or the attempts run out.
        handoffs[message_id] = (handoffs[message_id] or 0) + 1
        handoffs_changed = true
        if json_events then
          events[#events + 1] = {
            message_id = message.message_id,
            conversation_id = message.conversation_id,
            sender_id = message.sender_id,
            sent_at = at,
            direction = message.direction,
            body = message.body,
            eligibility = verdict,
          }
        elseif sentinel then
          local ok, why = emit_event(sentinel, "whatsapp.message", message.message_id, {
            conversation_id = message.conversation_id,
            message_id = message.message_id,
            sender_id = message.sender_id,
            sent_at = at,
            direction = message.direction,
            body = message.body,
            eligibility = verdict,
          })
          if ok then
            emitted = emitted + 1
          else
            -- The event never reached the job store, so nothing is owed for it: forget the attempt and
            -- leave the cursor where it is, so the next pass tries again.
            emit_error = emit_error or why
            handoffs[message_id] = nil
            handoffs_changed = true
          end
        end
      end
    end
  end
  local after = memory.stats().ledger_messages or 0
  -- Only what was decided about. `newest` would consume a message whose emission failed, one a read-only
  -- pass merely looked at, or one a pipeline step never acted on - the silent loss this rule prevents.
  if handled > cursor then
    cursor = handled
    memory.meta_set("whatsapp_cursor", math.floor(cursor))
  end
  -- What is still owed a decision, durably, so a restart between hand-on and decision does not forget it.
  if handoffs_changed then
    memory.meta_set("whatsapp_handoffs", json.encode(handoffs))
  end
  -- The dump has done its job; leaving it would leave a copy of the inbox in the temp directory.
  if host.exec then pcall(host.exec, "rm -f " .. quote(dump), "") end
  local elapsed = host.monotonic_ms and (host.monotonic_ms() - started) or 0
  -- What the copilot did *as the operator* since the last pass. A reply that went out to somebody else is an
  -- effect on their conversation, and the operator has to see it in their own inbox: the ledger and the job
  -- history are not where they read, and "the copilot answered someone for you" is the one thing they must
  -- not have to go looking for. Deterministic (a query, no model), bounded, and one line per send: a reply
  -- that did NOT confirm is reported as not sent rather than not at all.
  --
  -- It runs in the pipeline mode only, because the pipeline's shell script is what sends the notes; the
  -- cursor advances with the notices, so the same send is never reported twice.
  local REPORT_LIMIT = 3
  local notices = {}
  if json_events then
    local reported_at = tonumber(memory.meta_get("whatsapp_reported_at") or 0) or 0
    local reported_upto = reported_at
    -- The first pass with this feature announces nothing and adopts "now": the alternative is a burst of
    -- notices about sends that were already in the ledger before anybody asked to be told about them. Being
    -- told starts with the next send, which is the one nobody has seen yet.
    local rows = {}
    if reported_at <= 0 then
      memory.meta_set("whatsapp_reported_at", tostring(host.now()))
    else
      rows = json.decode(host.sql_query(
        "SELECT s.message_id, s.conversation_id, s.state, s.body, s.updated_at, c.title " ..
        "FROM effect_sends s LEFT JOIN conversations c ON c.id = s.conversation_id " ..
        "WHERE s.updated_at > ? ORDER BY s.updated_at LIMIT ?",
        json.encode({ reported_at, REPORT_LIMIT })) or "")
    end
    if type(rows) == "table" and not rows.error then
      for _, row in ipairs(rows) do
        local who = tostring(row.title or "")
        if who == "" then who = tostring(row.conversation_id or "?") end
        -- One line, one field: the shell parses these as `|`-separated, so a pipe or a newline in a reply
        -- body would silently become another notice or another field.
        local said = trim((tostring(row.body or ""):gsub("%s+", " ")):gsub("|", "/")):sub(1, 200)
        local state = tostring(row.state or "")
        local detail
        if state == "sent" then
          detail = string.format("replied for you to %s (id %s): \"%s\"", who, tostring(row.message_id), said)
        else
          detail = string.format("a reply for you to %s (id %s) is NOT confirmed as sent (state %s) - check it",
            who, tostring(row.message_id), state)
        end
        notices[#notices + 1] = {
          message_id = tostring(row.message_id),
          conversation_id = tostring(row.conversation_id or ""),
          state = state,
          detail = detail,
        }
        local at = tonumber(row.updated_at) or 0
        if at > reported_upto then reported_upto = at end
      end
    end
    if reported_upto > reported_at then
      memory.meta_set("whatsapp_reported_at", tostring(reported_upto))
    end
  end
  -- One line, greppable, with the numbers that say whether the diff is working: `read` is what the
  -- reader returned (the rescan window), `new` is what the ledger did not already have.
  if json_events then
    -- One JSON object and nothing else on stdout: a pipeline step succeeds on exit 0 *and* a JSON
    -- object, and a stray report line would make the whole result unparseable.
    local owed = 0
    for _ in pairs(handoffs) do owed = owed + 1 end
    print(json.encode({ events = events, unanswerable = unanswerable, exhausted = exhausted,
      stood_down = stood_down, notices = notices,
      operator_answered = skipped_answered, already_decided = skipped_decided,
      still_owed = owed, decisions_error = decisions_error,
      cursor = math.floor(cursor) }))
    return
  end
  local owed = 0
  for _ in pairs(handoffs) do owed = owed + 1 end
  local first_media = unanswerable[1]
  local media_detail = first_media and (" media_detail=" ..
    tostring(first_media.message_id) .. ":" .. tostring(first_media.media) .. ":" ..
    tostring(first_media.reason or "unsupported")) or ""
  report(string.format(
    "whatsapp ingest ok db=%s read=%d new=%d conversations=%d eligible=%d ineligible=%d cursor=%d newest=%d events=%d skipped=%d decided=%d owed=%d unanswerable=%d exhausted=%d%s%s ms=%d",
    paths.data(), math.floor(#(payload.messages or {})), math.floor(after - before),
    math.floor(#(payload.conversations or {})), math.floor(tonumber(payload.eligible) or 0),
    math.floor(tonumber(payload.ineligible) or 0), math.floor(cursor), math.floor(newest),
    math.floor(emitted), math.floor(skipped_ineligible), math.floor(skipped_decided), math.floor(owed),
    math.floor(#unanswerable), math.floor(#exhausted),
    media_detail,
    emit_error and (" event_error=" .. tostring(emit_error)) or "",
    math.floor(elapsed)))
end

main()
