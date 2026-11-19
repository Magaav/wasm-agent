-- The adapter contract (docs/AGENT-SEAT.md, principles 2 and 3): a recorded provider stream becomes
-- ONE normalized message, and every field of it is what the fixture says it is.
--
-- Each case replays a recorded shape from fixtures/adapters/ through the adapter that serves it, so a
-- provider quirk is proven to be handled in its own adapter instead of in the core. The fixtures are
-- the providers' own bytes (SSE data payloads in order); no live call is made here.
--
--   WA_SCRIPT=scripts/test-adapters.lua wa ...   prints "adapters ok"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")") end


local json = dofile("lua/vendor/json.lua")
local normalize = dofile("lua/core/adapters/normalize.lua")
local registry = dofile("lua/core/adapters/init.lua")

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s\n  got:  %s\n  want: %s", what, tostring(got), tostring(want)))
  end
end

local function has(haystack, needle, what)
  checks = checks + 1
  if not string.find(tostring(haystack), needle, 1, true) then
    error(string.format("%s: %q does not contain %q", what, tostring(haystack), needle))
  end
end

local function fixture(name)
  local text = host.read_file("fixtures/adapters/" .. name)
  assert(text, "fixture missing: fixtures/adapters/" .. name)
  local ok, decoded = pcall(json.decode, text)
  assert(ok and type(decoded) == "table", "fixture is not JSON: " .. name)
  return decoded
end

-- One recorded stream, through the adapter of its provider, checked against the fixture's own
-- expectations - so a shape the fixture declares is the shape the adapter must produce.
local function replay(name, transport)
  local recorded = fixture(name)
  local adapter, problem = registry.for_transport(transport)
  assert(adapter, "no adapter for " .. transport .. ": " .. tostring(problem))
  local record, why = adapter.from_stream(recorded.payloads)
  assert(record, "adapter failed on " .. name .. ": " .. tostring(why))
  local expect = recorded.expect or {}
  eq(record.answer_text, expect.answer_text or "", name .. ": answer text")
  eq(record.reasoning, expect.reasoning or "", name .. ": reasoning")
  eq(#(record.tool_calls or {}), expect.tool_calls or 0, name .. ": tool call count")
  eq(record.finish_reason, expect.finish_reason, name .. ": finish reason")
  if expect.cut ~= nil then eq(record.cut, expect.cut, name .. ": cut") end
  if expect.tool_calls and expect.tool_calls > 0 then
    local first = record.tool_calls[1]
    eq(first["function"].name, expect.tool_name, name .. ": tool name")
    eq(first["function"].arguments, expect.tool_arguments, name .. ": tool arguments assembled")
  end
  return record
end

-- --------------------------------------------------------------- the two provider shapes
replay("openai-stream.json", "openai-completions")
replay("openai-tool-call-stream.json", "openai-completions")
replay("openai-cut-stream.json", "openai-completions")
replay("anthropic-stream.json", "anthropic-messages")
replay("anthropic-tool-use-stream.json", "anthropic-messages")

-- The usage counters land in the record's names, not the provider's.
local openai = replay("openai-stream.json", "openai-completions")
eq(openai.usage.input_tokens, 12, "usage: input")
eq(openai.usage.output_tokens, 7, "usage: output")
eq(openai.usage.reasoning_tokens, 5, "usage: reasoning")
eq(openai.usage.cache_read_tokens, 8, "usage: cache read")

local anthropic = replay("anthropic-stream.json", "anthropic-messages")
eq(anthropic.usage.input_tokens, 10, "anthropic usage: input")
eq(anthropic.usage.cache_read_tokens, 4, "anthropic usage: cache read")
eq(anthropic.usage.output_tokens, 9, "anthropic usage: output from message_delta")

-- A cut stream is flagged, never passed off as a finished one.
local cut = replay("openai-cut-stream.json", "openai-completions")
eq(cut.cut, true, "a stream with no finish reason and no [DONE] is a cut")

-- ------------------------------------------------------------------- the record's own rules
local none, why = registry.for_transport("gemini-messages")
eq(none, nil, "an unserved transport has no adapter")
has(why, "unknown_transport", "the refusal says unknown_transport")
has(why, "openai-completions", "the refusal lists what this build serves")

local empty, empty_why = registry.for_transport("")
eq(empty, nil, "a route with no transport has no adapter")
has(empty_why, "declares no transport", "the refusal names the missing transport")

-- A record that invents a field is refused, not carried into the core.
local bad, bad_why = normalize.normalize({ answer_text = "x", answer = "x" })
eq(bad, nil, "an unknown field is refused")
has(bad_why, "adapter_unknown_field", "the refusal says adapter_unknown_field")

-- An unknown finish reason is named; the record keeps the provider's own word.
local odd, odd_why = normalize.normalize({ answer_text = "x", finish_reason = "pause" })
eq(odd_why, "unknown_finish_reason", "an unmapped finish reason is not silently stop")
eq(odd.finish_reason, "pause", "the record keeps the provider's own word")

-- The reasoning spellings, in one place, so the core reads one field.
eq(normalize.reasoning_of({ reasoning_content = "a" }), "a", "reasoning_content")
eq(normalize.reasoning_of({ reasoning = "b" }), "b", "reasoning")
eq(normalize.reasoning_of({ reasoning_text = "c" }), "c", "reasoning_text")
eq(normalize.reasoning_of({ reasoning_content = "", reasoning = "d" }), "d",
  "an empty field does not shadow a populated one")
eq(normalize.reasoning_of(nil), "", "a missing message is not an error")

-- A think block inside content is not an answer; the text after it is.
eq(normalize.visible_text("hello"), "hello", "plain text is visible")
eq(normalize.visible_text("   \n\t "), "", "whitespace alone is not an answer")
print("adapters ok (" .. checks .. " checks)")
