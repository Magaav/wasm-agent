-- A slow read is a HANDLE, not a throw (whatsapp-read-slow-is-not-an-error, item 4 a-c).
--
-- What went wrong, in one line: `host.whatsapp_read` answers `ok = false, error = ..._slow` when its wait
-- runs out, a script saw a throw, and a sibling call in the same `Promise.all` lost its answer with it. The
-- fix is `lua/core/codemode_pending.lua`'s query executor: the job id the host names IS the handle, and a
-- call that outlives the shared budget becomes `{state = "pending", op, waited_ms}` that `wait(op)`
-- continues. This row holds the component slow with a stub dispatch - no queue, no component, no account.
--
-- Hermetic: `pending.invoke`/`pending.wait` are called directly with a fake dispatch, exactly the seam the
-- codemode loop uses.
local json = dofile("lua/vendor/json.lua")
local pending = dofile("lua/core/codemode_pending.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end

local scope = string.rep("a", 64)
local opts = { scope = scope, session = "read-slow-row" }
local asks = {}
local job_asks = 0

-- The node's own capability, held slow: the read puts job 42 on the queue and says so; a call that names
-- that job gets the settled answer. The search is decided at once, like any other call.
local function dispatch(name, params, raw)
  asks[#asks + 1] = { name = name, raw = raw }
  local wire = json.decode(raw or "{}")
  if type(wire) ~= "table" then wire = {} end
  -- The job takes one round to finish, like a real one: an ask that arrives before it settled says so
  -- again. A stub that settles on the first re-ask would make `wait_s: 0` look patient.
  if wire.__job ~= nil then job_asks = job_asks + 1 end
  if wire.__job ~= nil and job_asks > 1 then
    return { header = { chat = "fixture", name = "Fixture" },
      messages = { { id = "m1", at = 1700000000, from = { name = "A" }, text = "one" } }, count = 1 }
  end
  if name == "mcp_whatsapp_search" then
    return { hits = { { id = "m9", chat = "fixture" } }, count = 1, matched = 1 }
  end
  return { ok = false, error = "whatsapp_read_slow", id = 42, state = "queued", retry = true }
end

-- (a) a slow read is a pending handle with waited_ms, never an error the script has to catch
local handle = pending.invoke(dispatch, opts, "mcp_whatsapp_read",
  { chat = "fixture", limit = 5 }, json.encode({ chat = "fixture", limit = 5 }), 0)
ok(type(handle) == "table", "a slow read answers a table: " .. tostring(handle))
ok(type(handle) == "table" and handle.state == "pending",
  "and its state is pending, not an error: " .. json.encode(handle))
ok(type(handle) == "table" and handle.error == nil, "no error field rides on it")
ok(type(handle) == "table" and handle.op == "waq-42",
  "the handle names the job the host queued: " .. tostring(type(handle) == "table" and handle.op))
ok(type(handle) == "table" and tonumber(handle.waited_ms) ~= nil,
  "and says how long it already waited, in ms")

-- (b) waiting on it yields the messages
local settled = pending.wait(dispatch, opts, type(handle) == "table" and handle.op or "waq-42", { wait_s = 5 })
ok(type(settled) == "table" and type(settled.messages) == "table" and #settled.messages == 1,
  "waiting on the handle yields the messages: " .. json.encode(settled))
ok(type(settled) == "table" and type(settled.header) == "table", "with the header a read always carries")

-- (c) one slow read never takes a sibling down: the search call answers on its own
local search = pending.invoke(dispatch, opts, "mcp_whatsapp_search", { q = "x" },
  json.encode({ q = "x" }), 0)
ok(type(search) == "table" and type(search.hits) == "table" and #search.hits == 1,
  "the sibling search keeps its own answer: " .. json.encode(search))
ok(type(search) == "table" and search.error == nil, "and carries no error from the read beside it")

-- (d) an audio needs no second call: `text: "full"` reaches the wire, so the read answers the whole
-- transcript and nothing has to ask `whatsapp_media` for the rest.
local before = #asks
local full = pending.invoke(dispatch, opts, "mcp_whatsapp_read",
  { chat = "fixture", id = "m1", text = "full" }, json.encode({ chat = "fixture", id = "m1", text = "full" }), 0)
ok(type(full) == "table", "a full-text read answers: " .. tostring(full))
local carried = nil
for i = before + 1, #asks do
  local wire = json.decode(asks[i].raw or "{}")
  if type(wire) == "table" and wire.text ~= nil then carried = wire.text end
end
ok(carried == "full", "the request carries text = full to the component: " .. tostring(carried))
local media_asks = 0
for _, ask in ipairs(asks) do
  if ask.name == "mcp_whatsapp_media" then media_asks = media_asks + 1 end
end
ok(media_asks == 0, "and no whatsapp_media call was made for the transcript (" .. media_asks .. ")")

-- The budget was the CALL's, and nothing kept a constant of its own: every ask carried __wait_ms.
local missing = 0
for _, ask in ipairs(asks) do
  local wire = json.decode(ask.raw or "{}")
  if type(wire) ~= "table" or wire.__wait_ms == nil then missing = missing + 1 end
end
ok(#asks > 0 and missing == 0, "every ask carried the call's own budget (" .. #asks .. " asks, " .. missing .. " without)")

-- ITEM 5's MEASURABLE HALF, counted rather than assumed: the SAME task - "what was said in this audio" -
-- costs one tool call with `text: "full"` and two without it (the read, then the media call that holds the
-- rest of the transcript). The tool calls a script makes are counted here, at the seam every call crosses.
local function calls_for(ask_full)
  local made = {}
  local function counting(name, params, raw)
    made[#made + 1] = name
    local wire = json.decode(raw or "{}")
    if type(wire) ~= "table" then wire = {} end
    if name == "mcp_whatsapp_read" then
      -- A snippet is cut, so the transcript is not in the answer; `full` carries it.
      local text = ask_full and string.rep("a", 2000) or string.rep("a", 280)
      return { header = { chat = "fixture" }, messages = { { id = "m1", text = text } }, count = 1 }
    end
    if name == "mcp_whatsapp_media" then
      return { transcript = string.rep("a", 2000) }
    end
    return { error = "unexpected" }
  end
  if ask_full then
    pending.invoke(counting, opts, "mcp_whatsapp_read", { chat = "fixture", id = "m1", text = "full" },
      json.encode({ chat = "fixture", id = "m1", text = "full" }), 5)
  else
    -- The old shape: a snippet read, then a media call because the snippet was cut.
    pending.invoke(counting, opts, "mcp_whatsapp_read", { chat = "fixture", id = "m1" },
      json.encode({ chat = "fixture", id = "m1" }), 5)
    pending.invoke(counting, opts, "mcp_whatsapp_media", { chat = "fixture", id = "m1" },
      json.encode({ chat = "fixture", id = "m1" }), 5)
  end
  return #made, table.concat(made, " + ")
end
local before_calls, before_what = calls_for(false)
local after_calls, after_what = calls_for(true)
print("tool calls for one audio: before " .. before_calls .. " (" .. before_what .. ") -> after "
  .. after_calls .. " (" .. after_what .. ")")
ok(after_calls == 1, "the whole transcript costs ONE call: " .. after_what)
ok(before_calls == 2, "and it cost two before: " .. before_what)

if failed > 0 then
  print("whatsapp read slow: " .. failed .. " failed of " .. checks .. " checks")
  os.exit(1)
end
print("whatsapp read slow ok (" .. checks .. " checks)")
