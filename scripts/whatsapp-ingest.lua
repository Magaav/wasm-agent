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
  local skipped_ineligible = 0
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
  if (emit_on or json_events) and cursor > 0 and (message.sent_at or 0) > cursor and message.direction == "incoming" then
      local media_kind = (message.media and message.media[1] and message.media[1].type) or "chat"
      if json_events and eligible and media_kind ~= "chat" then
        unanswerable[#unanswerable + 1] = {
          message_id = message.message_id,
          conversation_id = message.conversation_id,
          media = media_kind,
          sent_at = message.sent_at,
        }
      -- Eligibility first: a pipeline step must be handed only what the rule accepted, or the token rule
      -- (a group message that does not name the operator) is bypassed by the very mode that saves tokens.
      if json_events and eligible then
        events[#events + 1] = {
          message_id = message.message_id,
          conversation_id = message.conversation_id,
          sender_id = message.sender_id,
          sent_at = message.sent_at,
          direction = message.direction,
          body = message.body,
          eligibility = verdict,
        }
      elseif not eligible then
        skipped_ineligible = skipped_ineligible + 1
      elseif sentinel then
        local ok, why = emit_event(sentinel, "whatsapp.message", message.message_id, {
          conversation_id = message.conversation_id,
          message_id = message.message_id,
          sender_id = message.sender_id,
          sent_at = message.sent_at,
          direction = message.direction,
          body = message.body,
          eligibility = verdict,
        })
        if ok then emitted = emitted + 1 else emit_error = emit_error or why end
      end
    end
  end
  local after = memory.stats().ledger_messages or 0
  local newest = tonumber(payload.newest) or 0
  if newest > cursor then
    memory.meta_set("whatsapp_cursor", math.floor(newest))
  end
  -- The dump has done its job; leaving it would leave a copy of the inbox in the temp directory.
  if host.exec then pcall(host.exec, "rm -f " .. quote(dump), "") end
  local elapsed = host.monotonic_ms and (host.monotonic_ms() - started) or 0
  -- One line, greppable, with the numbers that say whether the diff is working: `read` is what the
  -- reader returned (the rescan window), `new` is what the ledger did not already have.
  if json_events then
    -- One JSON object and nothing else on stdout: a pipeline step succeeds on exit 0 *and* a JSON
    -- object, and a stray report line would make the whole result unparseable.
    print(json.encode({ events = events, unanswerable = unanswerable,
      cursor = math.floor(math.max(cursor, newest)) }))
    return
  end
  report(string.format(
    "whatsapp ingest ok db=%s read=%d new=%d conversations=%d eligible=%d ineligible=%d cursor=%d events=%d skipped=%d%s ms=%d",
    paths.data(), math.floor(#(payload.messages or {})), math.floor(after - before),
    math.floor(#(payload.conversations or {})), math.floor(tonumber(payload.eligible) or 0),
    math.floor(tonumber(payload.ineligible) or 0), math.floor(math.max(cursor, newest)),
    math.floor(emitted), math.floor(skipped_ineligible),
    emit_error and (" event_error=" .. tostring(emit_error)) or "",
    math.floor(elapsed)))
end

main()
