-- Voice pipeline glue: host-pushed audio chunks in, utterance events out as data.
--
-- This wave proves the pipeline and nothing else. The *decisions* belong to the portable plugin
-- (`voice.wasm`, `rust/plugins/voice`): frame segmentation, energy/ZCR voice-activity detection,
-- utterance boundaries and the wake-word match interface. This module owns only the pumping - it
-- asks `host.audio("capture", ...)` for the next chunk of a file-backed source and forwards it to
-- `host.invoke("voice", ...)` unchanged, so the PCM stays opaque base64 across the Lua seam.
--
-- Nothing here blocks on audio and nothing here talks: no network, no chat write, no model call.
-- The host pushes chunks in; a source that ends is `nil` (the documented spelling of a missing
-- value), so the loop stops on a value rather than on an exception.
--
-- `voice.start{source=<wav path>, rate=, channels=, chunk_ms=, ...}` walks the source to its end and
-- returns what happened as data:
--
--   {ok=true, events={<utterance_start|utterance_end>, ...}, chunks=<n>, state=<plugin counters>}
--
-- An event carries `sample` (absolute sample offset) and `time_ms`. A refusal names its stage and
-- its reason: `{ok=false, stage="capture"|"configure"|"push", error="<name>"}`.
local json = dofile("lua/vendor/json.lua")

local M = {}

local DEFAULT_RATE = 16000
local DEFAULT_CHANNELS = 1
local DEFAULT_CHUNK_MS = 100

local session = { running = false, source = nil, rate = DEFAULT_RATE, channels = DEFAULT_CHANNELS, chunks = 0, events = 0 }

-- One JSON round trip to the plugin. `host.invoke` answers a JSON string (the loader reports a
-- missing plugin as `{"error":"plugin_not_found:voice"}`), so a table without `ok` is a failure.
local function plugin(request)
  if type(host.invoke) ~= "function" then
    return { ok = false, error = "voice_plugin_unavailable" }
  end
  local raw = host.invoke("voice", json.encode(request))
  if type(raw) ~= "string" then
    return { ok = false, error = "voice_plugin_unavailable" }
  end
  local decoded, value = pcall(json.decode, raw)
  if not decoded or type(value) ~= "table" then
    return { ok = false, error = "voice_plugin_bad_reply" }
  end
  return value
end

--- Configure the plugin for a rate/window without touching a source. Returns the plugin's reply.
function M.configure(config)
  config = config or {}
  return plugin({
    op = "configure",
    rate = config.rate,
    channels = config.channels,
    frame_ms = config.frame_ms,
    energy = config.energy,
    zcr_max = config.zcr_max,
    start_frames = config.start_frames,
    end_frames = config.end_frames,
  })
end

--- Pump one file-backed source through the plugin and return its events as data.
function M.start(config)
  config = config or {}
  local source = config.source or config.path
  if type(source) ~= "string" or source == "" then
    return { ok = false, stage = "configure", error = "voice_source_required" }
  end
  local rate = tonumber(config.rate) or DEFAULT_RATE
  local channels = tonumber(config.channels) or DEFAULT_CHANNELS
  local configured = M.configure({
    rate = rate,
    channels = channels,
    frame_ms = config.frame_ms,
    energy = config.energy,
    zcr_max = config.zcr_max,
    start_frames = config.start_frames,
    end_frames = config.end_frames,
  })
  if configured.ok ~= true then
    return { ok = false, stage = "configure", error = configured.error or "voice_configure_failed" }
  end
  session = { running = true, source = source, rate = rate, channels = channels, chunks = 0, events = 0 }
  local events, chunks = {}, 0
  local function fail(stage, error)
    session.running = false
    return { ok = false, stage = stage, error = error, events = events, chunks = chunks }
  end
  local chunk_ms = tonumber(config.chunk_ms) or DEFAULT_CHUNK_MS
  while true do
    -- `nil` means there is no source (missing, or read to its end); an escaped or malformed path
    -- comes back as a JSON refusal instead, so the two cannot be confused.
    local raw = host.audio("capture", json.encode({
      path = source,
      rate = rate,
      channels = channels,
      chunk_ms = chunk_ms,
    }))
    if raw == nil then
      break
    end
    local decoded, chunk = pcall(json.decode, raw)
    if not decoded or type(chunk) ~= "table" then
      return fail("capture", "voice_capture_bad_reply")
    end
    if chunk.ok == false then
      return fail("capture", chunk.error or "voice_capture_failed")
    end
    local pushed = plugin({ op = "push", pcm_base64 = chunk.pcm_base64 })
    if pushed.ok ~= true then
      return fail("push", pushed.error or "voice_push_failed")
    end
    for _, event in ipairs(pushed.events or {}) do
      events[#events + 1] = event
    end
    chunks = chunks + 1
    if chunk.eof then
      break
    end
  end
  -- A recording may end inside a burst; the flush closes that utterance at its last voiced sample.
  local flushed = plugin({ op = "flush" })
  if flushed.ok == true then
    for _, event in ipairs(flushed.events or {}) do
      events[#events + 1] = event
    end
  end
  session.running = false
  session.chunks, session.events = chunks, #events
  return { ok = true, events = events, chunks = chunks, state = flushed }
end

--- Reset the plugin and the session. The configured rate/window survives (see the plugin).
function M.stop()
  local reply = plugin({ op = "reset" })
  session = { running = false, source = nil, rate = DEFAULT_RATE, channels = DEFAULT_CHANNELS, chunks = 0, events = 0 }
  if reply.ok ~= true then
    return { ok = false, error = reply.error or "voice_reset_failed" }
  end
  return { ok = true }
end

--- The plugin's counters, plus what this glue knows about the last run.
function M.state()
  local reply = plugin({ op = "state" })
  reply.glue = {
    running = session.running,
    source = session.source,
    rate = session.rate,
    channels = session.channels,
    chunks = session.chunks,
    events = session.events,
  }
  return reply
end

--- The wake-word match interface: a feature vector in, a confidence out - except that the model is
--- a later wave, so this returns the plugin's named `model_absent` refusal and never a fake score.
function M.wake_match(features)
  return plugin({ op = "match_wake", features = features })
end

return M
