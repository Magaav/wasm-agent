-- An empty assistant message is not an answer.
--
-- A reasoning model that spends its whole output budget thinking returns content
-- "", reasoning of some length, and finish_reason=length. Kimi, DeepSeek-R1 and
-- friends all do it. The loop used to record that as a finished turn, so the model
-- looked like it had nothing to say rather than like it had failed - and with no
-- max_tokens sent at all, nothing bounded how far the reasoning could run.
--
-- The dangerous half of this is the opposite case: a tool call with no prose is
-- completely normal and must keep working. That is the positive control below.
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-empty-reply.lua wa --db /tmp/x.db
local provider = dofile("lua/core/provider.lua")

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s: got %q, want %q", what, tostring(got), tostring(want)))
  end
end
local function has(haystack, needle, what)
  checks = checks + 1
  if not string.find(haystack, needle, 1, true) then
    error(string.format("%s: %q does not contain %q", what, haystack, needle))
  end
end

-- The reasoning field has three spellings in the wild, and pi reads all three.
eq(provider.reasoning_of({ reasoning_content = "a" }), "a", "reasoning_content")
eq(provider.reasoning_of({ reasoning = "b" }), "b", "reasoning")
eq(provider.reasoning_of({ reasoning_text = "c" }), "c", "reasoning_text")
eq(provider.reasoning_of({ reasoning_content = "", reasoning = "d" }), "d",
  "an empty field does not shadow a populated one")
eq(provider.reasoning_of({ content = "x" }), "", "no reasoning field at all")
eq(provider.reasoning_of(nil), "", "a missing message is not an error")

-- What a reader would see: reasoning is not an answer.
eq(provider.visible_text("hello"), "hello", "plain text is visible")
eq(provider.visible_text("   \n\t "), "", "whitespace alone is not an answer")
eq(provider.visible_text("<think>a\nb</think>"), "",
  "a think block inside content is not an answer")
eq(provider.visible_text("<think>a</think>the answer"), "the answer",
  "the text after a think block is the answer")
eq(provider.visible_text("<think>never closed"), "",
  "an unclosed think block swallows the rest")

-- The reason has to be actionable: name the stop reason and the knob.
local spent = provider.empty_reply_reason({ reasoning = string.rep("x", 40), finish_reason = "length" })
has(spent, "finish_reason=length", "the reason names the stop")
has(spent, "40 chars", "the reason quantifies the reasoning")
has(spent, "WASM_AGENT_LLM_MAX_OUTPUT", "the reason names the knob that sets the cap")
local bare = provider.empty_reply_reason({})
has(bare, "no finish_reason", "an unknown stop is said out loud")

-- POSITIVE CONTROL: a decision with tool calls and no prose is normal, and the
-- answer path must not be reachable for it. The check in agent.lua is guarded by
-- `#calls == 0`, and this is why.
local with_calls = { content = "", tool_calls = { { id = "1", ["function"] = { name = "read" } } } }
checks = checks + 1
if provider.visible_text(with_calls.content) ~= "" then
  error("a tool call with no prose must still be an empty visible reply")
end
checks = checks + 1
if #with_calls.tool_calls == 0 then
  error("the positive control needs a tool call")
end

print(string.format("empty reply ok (%d checks)", checks))
