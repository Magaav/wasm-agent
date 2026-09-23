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
--   2. every row goes through `memory.record_message`, the same path any other observer uses, so the
--      full-text index and the body hash are maintained by the code that owns them;
--   3. the cursor moves to the newest message seen, in the database, beside the rows it describes.
--
-- It always exits 0 and prints one line. A closed browser is a *reported* condition, not a failure:
-- a scheduled job that shouts when the window is shut is a job whose history means nothing.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local paths = dofile("lua/core/paths.lua")

-- One hour of overlap. A cursor alone is brittle: a message whose clock is behind the newest one we
-- have already seen would fall below it and never be read. Overlap plus the ledger's identity is the
-- cheapest way to be sure, and a rescan of an hour costs one query.
local RESCAN_SECONDS = 3600

local function trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function quote(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end

-- `host.exec` hands back a JSON *string* (the host pushes one value), so everything below reads it
-- through here. Comparing fields on the raw string is how a working `node --version` reported itself
-- as `node_missing`.
local function shell(command)
  local ok, raw = pcall(host.exec, command, "")
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
  local candidates = {
    "node",
    "C:/Program Files/nodejs/node.exe",
    "/c/Program Files/nodejs/node.exe",
  }
  for _, candidate in ipairs(candidates) do
    local result = shell(quote(candidate) .. " --version 2>/dev/null")
    if result and (result.code or 1) == 0 and trim(result.stdout) ~= "" then return candidate end
  end
  return nil
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
  local since = math.max(0, cursor - RESCAN_SECONDS)

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
  -- New eligible messages whose media is not text: an image, a voice note, a video. Nothing can read
  -- them here, so they are reported to the operator instead of being handed to a child that would have
  -- to invent an answer - and no token is spent on them.
  local unanswerable = {}
  -- Messages that were handed on as often as this reader is willing to try and are still undecided.
  -- Reported to the operator once, then let go: a bounded attempt count is what stops one permanently
  -- failing message from pinning the cursor for everything behind it.
  local exhausted = {}
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
  for _, message in ipairs(payload.messages or {}) do
    memory.record_message({
      conversation_id = message.conversation_id,
      message_id = message.message_id,
      sender_id = message.sender_id,
      direction = message.direction,
      sent_at = message.sent_at,
      body = message.body,
      media = message.media,
      source = "whatsapp-cdp",
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
    if (emit_on or json_events) and message.direction == "incoming" and (at > cursor or pending) then
      local media_kind = (message.media and message.media[1] and message.media[1].type) or "chat"
      local answered_by_operator = (newest_outgoing[message.conversation_id] or 0) > at
      if answered_by_operator then
        -- The operator took the lead in this conversation; standing down is a decision, and it costs no
        -- token to make it here.
        skipped_answered = skipped_answered + 1
        handled = math.max(handled, at)
        if handoffs[message_id] then handoffs[message_id] = nil; handoffs_changed = true end
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
      elseif media_kind ~= "chat" then
        -- Nothing here can read an image or a voice note, so it is reported to the operator's own inbox and
        -- never handed to a child that would have to invent an answer. Deliberately *not* also appended to
        -- `events`, which is what the old code did on its way past: an eligible voice note was both reported
        -- and handed to a child.
        handled = math.max(handled, at)
        if handoffs[message_id] then handoffs[message_id] = nil; handoffs_changed = true end
        unanswerable[#unanswerable + 1] = {
          message_id = message.message_id,
          conversation_id = message.conversation_id,
          media = media_kind,
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
  -- One line, greppable, with the numbers that say whether the diff is working: `read` is what the
  -- reader returned (the rescan window), `new` is what the ledger did not already have.
  if json_events then
    -- One JSON object and nothing else on stdout: a pipeline step succeeds on exit 0 *and* a JSON
    -- object, and a stray report line would make the whole result unparseable.
    local owed = 0
    for _ in pairs(handoffs) do owed = owed + 1 end
    print(json.encode({ events = events, unanswerable = unanswerable, exhausted = exhausted,
      operator_answered = skipped_answered, already_decided = skipped_decided,
      still_owed = owed, decisions_error = decisions_error,
      cursor = math.floor(cursor) }))
    return
  end
  local owed = 0
  for _ in pairs(handoffs) do owed = owed + 1 end
  report(string.format(
    "whatsapp ingest ok db=%s read=%d new=%d conversations=%d eligible=%d ineligible=%d cursor=%d newest=%d events=%d skipped=%d decided=%d owed=%d unanswerable=%d exhausted=%d%s ms=%d",
    paths.data(), math.floor(#(payload.messages or {})), math.floor(after - before),
    math.floor(#(payload.conversations or {})), math.floor(tonumber(payload.eligible) or 0),
    math.floor(tonumber(payload.ineligible) or 0), math.floor(cursor), math.floor(newest),
    math.floor(emitted), math.floor(skipped_ineligible), math.floor(skipped_decided), math.floor(owed),
    math.floor(#unanswerable), math.floor(#exhausted),
    emit_error and (" event_error=" .. tostring(emit_error)) or "",
    math.floor(elapsed)))
end

main()
