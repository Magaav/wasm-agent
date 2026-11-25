-- THE SENTENCE A HELD TURN IS TOLD, BEFORE AND AFTER THE DEPLOY KNOWS ITS COMMIT (25/11).
--
-- MEASURED during the rc-cover install: the alive record is written as the deploy's first act, before COMMIT is
-- resolved, and a held worker turn was told "deploy_waiting: waiting for the install of unknown (a deploy has been
-- running 2m ago)". The record now names the commit as soon as there is one (scripts/deploy.sh, same pid, same start
-- time), and until then the sentence says an install is starting - the word "unknown" never reaches a person.
--
--   WA_SCRIPT=scripts/test-deploy-wait-commit.lua WASM_AGENT_LUA_ROOT=$PWD wa --db /tmp/wa-wait.db
--
-- Every assertion is the whole sentence, verbatim: a sentence is what a person reads, and a substring check would pass
-- on the very word this row exists to keep out.

local wait_module = dofile("lua/core/deploy_wait.lua")
local pause = dofile("lua/core/deploy_pause.lua")

local checks = 0
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    error("FAIL " .. label .. "\n    got:  " .. tostring(actual) .. "\n    want: " .. expected, 2)
  end
  print("  ok   " .. label)
end
local function has(text, needle, label)
  checks = checks + 1
  if not tostring(text):find(needle, 1, true) then
    error("FAIL " .. label .. "\n    got:  " .. tostring(text), 2)
  end
  print("  ok   " .. label)
end
local function has_not(text, needle, label)
  checks = checks + 1
  if tostring(text):find(needle, 1, true) then
    error("FAIL " .. label .. "\n    got:  " .. tostring(text), 2)
  end
  print("  ok   " .. label)
end

local now = 1800000000
local since = now - 120

-- ---- 1. BEFORE the commit is known: the record says "unknown" (alive-first writes it before COMMIT) ----
eq(wait_module.say({ source = "deploy", to = "unknown", since = since }, now),
  "waiting for an install that is starting (a deploy has been running 2m ago)",
  "before the commit is known: the sentence says an install is starting, not 'unknown'")
eq(wait_module.say({ source = "deploy", to = "", since = since }, now),
  "waiting for an install that is starting (a deploy has been running 2m ago)",
  "and an empty commit reads the same way")
eq(wait_module.say({ source = "request", id = "req-42", to = "unknown", since = since }, now),
  "waiting for an install that is starting (deploy request req-42, asked 2m ago)",
  "and a request that names no commit says the same, with its id")

-- ---- 2. AFTER the commit is known: it is named, to the digit ----
eq(wait_module.say({ source = "deploy", to = "abc123def4567890", since = since }, now),
  "waiting for the install of abc123def456 (a deploy has been running 2m ago)",
  "after the commit is known: the sentence names it")

-- ---- 3. the PAUSED sentence, both states ----
local before = pause.say_wait({ source = "request", to = "unknown", since = since, bound_seconds = 1800 }, now)
has(before, "waiting for an install that is starting", "a paused turn, before the commit, is told an install is starting")
has_not(before, "unknown", "and the word 'unknown' is nowhere in what the person reads")
local after = pause.say_wait({ source = "request", to = "abc123def4567890", since = since, bound_seconds = 1800 }, now)
has(after, "abc123def456", "a paused turn, after the commit, is told which commit is coming")

-- ---- 4. the refusal text a turn that did NOT start gets ----
local refusal_before = wait_module.refusal({ source = "deploy", to = "unknown", since = since }, now)
has_not(refusal_before, "unknown", "the refusal a turn that did not start gets never says 'unknown'")
has(refusal_before, "an install that is starting", "and says an install is starting")

-- ---- 5. the PAUSED RECORD itself (pauses.jsonl): no commit is an empty "to", never the word unknown ----
-- The paused event used to write marker.to straight through, so a deploy that had not resolved its commit yet wrote
--  "to":"unknown" into pauses.jsonl and every reader repeated it. The record leaves the field empty.
local captured = nil
local wrote = pause.record_pause({ source = "request", id = "req-pause" }, now, "sess-pause", "op", {
  dir = host.paths().home .. "/pause-fixture",
  installed = { commit = "", branch = "main" },
  write = function(_path, body) captured = body; return true end,
})
has(tostring(wrote ~= nil and captured ~= nil), "true", "a paused record was written through the module own writer")
has(captured, [=["to":""]=], "the record leaves to EMPTY when the deploy has not resolved a commit")
has_not(captured, "unknown", "and the word unknown is nowhere in the record")
local paused_again = pause.say_wait({ source = "request", to = "", since = since, bound_seconds = 1800 }, now)
has(paused_again, "an install that is starting", "and the reader of that record says an install is starting")
print(string.format("deploy wait names the commit ok (%d checks)", checks))
