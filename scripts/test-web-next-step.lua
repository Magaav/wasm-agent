-- A refused fetch is not a dead end.
--
-- Measured 13/11 (session b393f280 on node `work`): the run's last tool result was `web_http_429`, the
-- model had nothing to do with it, and the run stopped there - "stopped after a tool result with no
-- next step" (`lua/core/memory.lua`, `detail_of`), with no message to the user. `web_read` and
-- `web_search` answer through an MCP adapter (`scripts/mcp-web.mjs`, `scripts/web-http-outcomes.mjs`),
-- and a transient HTTP refusal must carry what to do next instead of ending the turn.
--
-- Model-free and hermetic: the adapter is a stub, so this file touches no network at all.
local json = dofile("lua/vendor/json.lua")
local web = dofile("lua/core/web.lua")
local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

-- The adapter, as the node calls it: one structured answer, no child process.
local function adapter(answer)
  return {
    script_dir = function() return "/fixture/mcp" end,
    node_program = function() return "node" end,
    scripts_missing = function() return { ok = false, searched = {} } end,
    invoke = function() return { outcome = "call", ok = false, evidence = { response_ref = "ref-1" },
      result_json = json.encode({ structuredContent = answer }) } end,
    project = function(value) return value end,
  }
end
local ctx = { user_id = "master", session_id = "web-next-step" }

-- ---- 1. A 429 says what to do next, once ------------------------------------------------------
local limited = web.call(adapter({ ok = false, state = "failed", error = "web_http_429", status = 429,
  url = "https://www.youtube.com/watch?v=x" }), "read", { url = "https://www.youtube.com/watch?v=x" }, ctx)
ok(limited.error == "web_http_429", "the refusal keeps its own word: " .. json.encode(limited))
ok(limited.retryable == true, "a 429 is marked retryable: " .. json.encode(limited))
ok(type(limited.next_step) == "string" and #limited.next_step > 0,
  "a 429 carries the next step, so the run does not end on it: " .. json.encode(limited))
ok(tostring(limited.next_step):find("HTTP 429", 1, true) ~= nil
  and tostring(limited.next_step):find("not the end of the task", 1, true) ~= nil,
  "the next step names the status and says it is not the end: " .. tostring(limited.next_step))
ok(tostring(limited.next_step):find("answer from what you already have", 1, true) ~= nil,
  "the next step offers the honest alternative: " .. tostring(limited.next_step))
-- Evidence is kept: the refusal is still the adapter's answer, with its retained bytes.
ok(limited.evidence and limited.evidence.response_ref == "ref-1", "the retained evidence travels with it")
ok(limited.status == 429 and limited.url ~= nil, "the status and url are unchanged")

-- ---- 2. The wait the server named is repeated, and only when it named one ---------------------
local with_wait = web.call(adapter({ ok = false, error = "web_http_429", status = 429,
  url = "https://example.test/x", retry_after = "2026-11-13T09:00:00.000Z" }), "read", { url = "https://example.test/x" }, ctx)
ok(tostring(with_wait.next_step):find("2026-11-13T09:00:00.000Z", 1, true) ~= nil,
  "a named retry-after is in the next step: " .. tostring(with_wait.next_step))
local without = web.call(adapter({ ok = false, error = "web_http_429", status = 429, url = "https://example.test/y" }),
  "read", { url = "https://example.test/y" }, ctx)
ok(tostring(without.next_step):find("retry-after", 1, true) == nil,
  "no retry-after is invented when the server named none: " .. tostring(without.next_step))

-- ---- 3. Only a transient refusal gets the sentence: a 404 is a fact, not a wait ----------------
for _, status in ipairs({ 500, 502, 503, 408, 425 }) do
  local answer = web.call(adapter({ ok = false, error = "web_http_" .. status, status = status, url = "https://example.test/z" }),
    "read", { url = "https://example.test/z" }, ctx)
  ok(answer.retryable == true and answer.next_step ~= nil, "HTTP " .. status .. " is transient: " .. json.encode(answer))
end
local missing = web.call(adapter({ ok = false, state = "failed", error = "web_http_404", status = 404,
  url = "https://example.test/gone" }), "read", { url = "https://example.test/gone" }, ctx)
ok(missing.next_step == nil and missing.retryable == nil,
  "a 404 is answered as the fact it is: " .. json.encode(missing))
local challenge = web.call(adapter({ ok = false, state = "needs_user_action", error = "web_challenge_requires_user",
  status = 403, url = "https://example.test/c" }), "read", { url = "https://example.test/c" }, ctx)
ok(challenge.next_step == nil and challenge.error == "web_challenge_requires_user",
  "a challenge keeps its own handoff, and gains nothing: " .. json.encode(challenge))

print("web next step ok (" .. checks .. " checks)")
