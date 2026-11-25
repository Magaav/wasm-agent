-- THE FOLLOW DOES NOT END ON THE FIRST UNREADABLE STATUS (mission release-node-updates, D3, 25/11).
--
-- MEASURED (ready-1, scratch pair): `wa update peer011 --release --commit <sha>` accepted the request, and then
-- the follow printed
--
--   omarchy: unknown \226\128\148 node_no_answer \194\183 0s
--
-- and returned - while the request was running on that node and settled a second later. The answer it gave up
-- on is nodes.remote_call's relay-deadline shape (lua/core/nodes.lua:1786-1800):
-- {error="remote_error", detail="node_no_answer", not_known_yet=true, state="unknown"} - NOT the node's word,
-- and the one answer that means "keep watching". Two things were wrong: the loop treated it as terminal, and it
-- had no bound at all (the CLI passed neither o.polls nor o.seconds), so a node that went quiet could hold a
-- terminal open for ever.
--
-- WHAT IS DRIVEN HERE: the real lua/core/remote_update.lua M.follow_remote, through its own seams (call, clock,
-- out, sleep) - the same function `wa update <node>` runs. The answers are the HOST's shapes, copied from
-- nodes.remote_call, not tables this test decoded itself. Nothing reaches a node, a port or the relay: the
-- follow's bug is in one process, and the process-crossing half (the relay answering a deadline) is covered by
-- scripts/test-remote-refusals.lua.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-remote-follow.lua wa --db <scratch>
--
-- Prints "remote follow ok"; a failed check raises.
local remote = dofile("lua/core/remote_update.lua")

local failed, checks = 0, 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""))
  end
end
local function has(text, needle) return tostring(text or ""):find(needle, 1, true) ~= nil end
local function joined(lines) return table.concat(lines or {}, " | ") end

-- ---- the answers, in the shapes nodes.remote_call and the peer's own status action produce ----------------
local function deadline(detail)
  return { error = "remote_error", detail = detail or "node_no_answer", node = "peer011", retryable = true,
    rid = "relay-rid", not_known_yet = true, state = "unknown", deadline_seconds = 42, attempts = 3,
    message = "NOT KNOWN YET - the relay's deadline passed before peer011 answered" }
end
local function status(state, extra)
  local reply = { ok = true, node = "peer011", state = state, record = "rec-1" }
  for key, value in pairs(extra or {}) do reply[key] = value end
  return reply
end
local function refusal(code, extra)
  local reply = { error = code, node = "peer011" }
  for key, value in pairs(extra or {}) do reply[key] = value end
  return reply
end

-- A follow over a scripted list of answers. The clock advances by `step` seconds per poll, so the bound is
-- exercised without waiting, and every line the loop prints is captured.
local function follow(answers, options)
  local o = options or {}
  local index, now, lines = 0, 0, {}
  local reply_at = function() return answers[#answers] end
  local result = remote.follow_remote(function()
    index = index + 1
    now = now + (o.step or 10)
    local answer = answers[index]
    if type(answer) == "function" then answer = answer() end
    return answer or reply_at()
  end, "peer011", "rec-1", {
    out = function(line) lines[#lines + 1] = line end,
    clock = function() return now end,
    sleep = function() end,
    poll = 10,
    polls = o.polls,
    seconds = o.seconds,
  })
  result.lines = lines
  return result
end

-- ---- (a) a relay deadline is "no answer yet", and the follow keeps going ---------------------------------
local a = follow({ deadline(), status("running", { detail = "installing" }), status("installed", { installed_commit = "abcdef1234567890" }) })
ok(a.state == "installed", "a follow that met a relay deadline still reaches the node's own answer", a.state)
ok(a.ok == true, "and reports it as installed", tostring(a.ok))
ok(has(joined(a.lines), "no answer yet"), "the deadline is printed as 'no answer yet'", joined(a.lines))
ok(has(joined(a.lines), "node_no_answer"), "and it names what the relay said, so a reader can look it up", joined(a.lines))
ok(not has(joined(a.lines), "refused"), "the deadline is NEVER reported as a refusal", joined(a.lines))
ok(has(joined(a.lines), "installed abcdef123456"), "and the answer line still says what was installed", joined(a.lines))
ok(#a.lines == 3, "one line per state change: no answer yet, running, installed", joined(a.lines))

-- ---- (b) the dry run's exact shape: the deadline first, at 0 s, and nothing else -------------------------
local b = follow({ deadline() }, { polls = 3 })
ok(b.timed_out == true and b.unknown == true, "a node that only ever says nothing leaves the follow UNKNOWN, not settled",
  "state=" .. tostring(b.state) .. " timed_out=" .. tostring(b.timed_out))
ok(b.ok == false, "unknown is not yes: ok is false", tostring(b.ok))
ok(has(joined(b.lines), "no answer yet"), "it said 'no answer yet', the thing that is true", joined(b.lines))
ok(not has(joined(b.lines), "refused") and not has(joined(b.lines), "FAILED") and not has(joined(b.lines), "installed"),
  "and it never claimed a state the node never gave", joined(b.lines))
ok(b.rounds >= 3, "it kept polling to its bound instead of returning on the first unreadable answer", tostring(b.rounds))

-- ---- (c) the bound is the module's own when a caller names none (a follow cannot run for ever) ------------
ok(type(remote.REMOTE_FOLLOW_BOUND) == "number" and remote.REMOTE_FOLLOW_BOUND > 0,
  "the follow has a stated bound", tostring(remote.REMOTE_FOLLOW_BOUND))
local c = follow({ deadline() }, { step = 600 })  -- no polls, no seconds: the module's bound is what stops it
ok(c.timed_out == true, "with no bound from the caller, the module's own bound ends the follow",
  "state=" .. tostring(c.state) .. " rounds=" .. tostring(c.rounds))
ok((c.seconds or 0) >= remote.REMOTE_FOLLOW_BOUND, "and it was that bound, not an accident", tostring(c.seconds))
ok(c.rounds <= math.ceil(remote.REMOTE_FOLLOW_BOUND / 600) + 1, "it stopped at the bound instead of polling on", tostring(c.rounds))

-- ---- (d) a refusal is the node's own word, and still ends the follow at once ------------------------------
local d = follow({ refusal("no_watcher", { observed = "no verified watcher ownership on this node" }) })
ok(d.state == "refused" and d.ok == false, "a real refusal still ends the follow, unchanged", d.state)
ok(d.rounds == 0, "at once, without polling again", tostring(d.rounds))

-- ---- (e) the shapes, stated once so the branch above cannot drift ----------------------------------------
ok(remote.not_an_answer(deadline()) == true, "the relay's deadline is not an answer")
ok(remote.not_an_answer({ ok = false, error = "remote_answer_unreadable", node = "peer011" }) == true,
  "an unreadable answer is not an answer either")
ok(remote.not_an_answer(refusal("no_watcher")) == false, "a refusal IS an answer")
ok(remote.not_an_answer(status("running")) == false, "and so is a state")
ok(remote.not_an_answer("not a table") == true, "and neither is a non-table")

-- ---- (f) the duration a person reads ----------------------------------------------------------------
ok(remote.elapsed(0) == "0s" and remote.elapsed(65) == "1m05s" and remote.elapsed(3660) == "1h01m",
  "durations read as 0s / 1m05s / 1h01m", remote.elapsed(0) .. "/" .. remote.elapsed(65) .. "/" .. remote.elapsed(3660))

if failed > 0 then error(checks .. " checks, " .. failed .. " FAILED") end
print("remote follow ok (" .. checks .. " checks)")
