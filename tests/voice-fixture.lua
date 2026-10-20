-- Voice pipeline fixture: a generated WAV (silence, burst, silence) in, utterance events out.
--
-- No microphone and no network. The WAV is written by the file-backed sink (`host.audio("play")`),
-- read back through the file-backed ear (`host.audio("capture")`), pushed chunk by chunk into
-- `voice.wasm`, and the boundaries are asserted by *sample offset* - the test never listens to it.
--
-- Expected shape at 16 kHz: 8000 samples of silence, 6400 samples of a 200 Hz burst, 8000 of
-- silence. One utterance: start at sample 8000, end at sample 14400. Nothing during either silence.
local json = dofile("lua/vendor/json.lua")
local voice = dofile("lua/core/voice.lua")

local RATE, CHANNELS = 16000, 1
local FIRST_SILENCE, BURST, SECOND_SILENCE = 8000, 6400, 8000
local EXPECTED_START = FIRST_SILENCE
local EXPECTED_END = FIRST_SILENCE + BURST

local root = host.getenv("WASM_AGENT_AUDIO_ROOT")
assert(type(root) == "string" and root ~= "", "the harness must declare WASM_AGENT_AUDIO_ROOT")

local function decode(raw, what)
  assert(type(raw) == "string", what .. " returned no value: " .. tostring(raw))
  local value = json.decode(raw)
  assert(type(value) == "table", what .. " did not return a JSON object: " .. tostring(raw))
  return value
end

local function write_fixture(name, samples)
  local path = root .. "/" .. name
  local written = decode(host.audio("play", json.encode({
    path = path,
    rate = RATE,
    channels = CHANNELS,
    samples = samples,
    final = true,
  })), "audio.play")
  assert(written.ok == true, "audio.play failed: " .. tostring(written.error))
  assert(written.samples == #samples, "audio.play reported the wrong sample count")
  return path
end

-- 1. Generate the fixture with the mirror call: silence, burst, silence.
local samples = {}
local function silence(count)
  for _ = 1, count do samples[#samples + 1] = 0 end
end
silence(FIRST_SILENCE)
for index = 1, BURST do
  samples[#samples + 1] = math.floor(0.5 + 12000 * math.sin(2 * math.pi * 200 * index / RATE))
end
silence(SECOND_SILENCE)
assert(#samples == FIRST_SILENCE + BURST + SECOND_SILENCE, "the fixture is not the expected length")
local fixture = write_fixture("voice-fixture.wav", samples)

-- 2. Frames in, events out.
local result = voice.start({ source = fixture, rate = RATE, channels = CHANNELS, chunk_ms = 100 })
assert(result.ok == true, "the pipeline failed at " .. tostring(result.stage) .. ": " .. tostring(result.error))
assert(#result.events == 2,
  "expected exactly one utterance start and one end, got " .. #result.events .. " event(s)")
local started, ended = result.events[1], result.events[2]
assert(started.type == "utterance_start", "the first event is not a start: " .. tostring(started.type))
assert(ended.type == "utterance_end", "the second event is not an end: " .. tostring(ended.type))
assert(started.sample == EXPECTED_START,
  string.format("utterance start is at sample %s, expected %d", tostring(started.sample), EXPECTED_START))
assert(ended.sample == EXPECTED_END,
  string.format("utterance end is at sample %s, expected %d", tostring(ended.sample), EXPECTED_END))
assert(started.time_ms == EXPECTED_START * 1000 / RATE, "the start timestamp disagrees with the sample offset")
assert(ended.time_ms == EXPECTED_END * 1000 / RATE, "the end timestamp disagrees with the sample offset")
for _, event in ipairs(result.events) do
  assert(event.sample >= EXPECTED_START and event.sample <= EXPECTED_END,
    "an event was reported outside the burst: sample " .. tostring(event.sample))
end
assert(result.state.open == false, "the utterance must be closed at the end of the source")

-- 3. Silence alone must produce no event at all.
local quiet_samples = {}
for index = 1, 16000 do quiet_samples[index] = 0 end
local quiet = write_fixture("voice-silence.wav", quiet_samples)
local silent = voice.start({ source = quiet, rate = RATE, chunk_ms = 200 })
assert(silent.ok == true, "the quiet run failed: " .. tostring(silent.error))
assert(#silent.events == 0, "silence produced " .. #silent.events .. " event(s)")

-- 4. No source is `nil`; an escaped path is a named refusal, not `nil`.
assert(host.audio("capture", json.encode({ path = root .. "/absent.wav" })) == nil,
  "a missing source must be nil, never an error value")
local escaped = decode(host.audio("capture", json.encode({ path = root .. "/../escape.wav" })), "escaped capture")
assert(escaped.ok == false and type(escaped.error) == "string"
  and escaped.error:find("audio_path_outside_root:", 1, true),
  "an escaped capture must be refused by name: " .. tostring(escaped.error))
local escaped_sink = decode(host.audio("play", json.encode({ path = root .. "/../escape.wav", samples = { 1 } })), "escaped play")
assert(escaped_sink.ok == false and type(escaped_sink.error) == "string"
  and escaped_sink.error:find("audio_path_outside_root:", 1, true),
  "an escaped sink must be refused by name: " .. tostring(escaped_sink.error))

-- 5. The plugin refuses a malformed chunk by name instead of guessing at its length.
local malformed = decode(host.invoke("voice", json.encode({ op = "push", pcm_base64 = "!!not base64!!" })), "malformed push")
assert(malformed.ok == false and malformed.error == "invalid_pcm_base64",
  "a malformed chunk must be refused as invalid_pcm_base64: " .. tostring(malformed.error))
local misaligned = decode(host.invoke("voice", json.encode({ op = "push", pcm_base64 = "AAAA" })), "misaligned push")
assert(misaligned.ok == false and misaligned.error == "invalid_pcm_length",
  "three bytes of PCM must be refused as invalid_pcm_length: " .. tostring(misaligned.error))

-- 6. The wake-word seam answers with a named absence, never a fabricated confidence.
local wake = voice.wake_match({ 0.1, 0.2, 0.3 })
assert(wake.ok == false and wake.error == "model_absent",
  "the wake-word stub must report model_absent: " .. tostring(wake.error))
assert(wake.confidence == nil, "the wake-word stub must not return a confidence")

print(string.format("voice fixture: %d chunks, %d events, start=%d end=%d",
  result.chunks, #result.events, started.sample, ended.sample))
print(string.format("voice refusals: %s, %s, wake=%s", malformed.error, misaligned.error, wake.error))
print("voice ok")
