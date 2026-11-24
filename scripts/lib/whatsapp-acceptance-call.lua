-- The WhatsApp acceptance driver: one step of the ONE table, inside the node.
--
-- Run by scripts/whatsapp-acceptance.mjs in a scratch node's own home
-- (`WA_SCRIPT=<this file>`), so every call takes the path a model's call takes: the real Lua
-- surface (lua/core/whatsapp.lua), the real host capability, the real queue, and - when the step is
-- asked from a peer - the real signed hop to the node that holds the account.
--
-- WHAT IT PRINTS IS A MEASUREMENT, NEVER CONTENT. One line per step, "ACCEPTANCE " followed by one
-- JSON object: the verdict, the milliseconds, the bytes of the answer the MODEL receives, the shape
-- of that answer (keys and types, arrays summarised), and a short set of scalar fields from an
-- allow-list. Message text, chat JIDs, phone numbers, message ids and names never leave this file:
-- every string in a shape is reduced to its length, and every allow-listed value is redacted first
-- (`redact`). That is why the same driver can run at G against the operator's own chat.
--
-- The plan (WA_ACCEPTANCE_PLAN) is JSON:
--   { "own_chat": "<jid>" | "",          -- live mode: the ONLY chat this run may touch
--     "site": "account|laptop|work",
--     "steps": [ { "id": "read", "tool": "mcp_whatsapp_read", "args": {...},
--                  "reuse": {"id": "<earlier step>", "key": "id"} } ] }
-- A step whose `reuse` names an earlier step takes that step's answer key as one of its own
-- arguments (the send-then-resume row: a wait re-reads the job the send answered).
local json = dofile("lua/vendor/json.lua")

local plan_path = host.getenv("WA_ACCEPTANCE_PLAN") or ""
local raw_plan = plan_path ~= "" and host.read_file(plan_path) or nil
if not raw_plan then
  print("ACCEPTANCE " .. json.encode({ id = "plan", ok = false, error = "plan_unreadable", path = plan_path }))
  os.exit(2)
end
local ok_plan, plan = pcall(json.decode, raw_plan)
if not ok_plan or type(plan) ~= "table" or type(plan.steps) ~= "table" then
  print("ACCEPTANCE " .. json.encode({ id = "plan", ok = false, error = "plan_invalid" }))
  os.exit(2)
end
local own_chat = type(plan.own_chat) == "string" and plan.own_chat or ""
local site = type(plan.site) == "string" and plan.site or "account"

-- ---- redaction ----------------------------------------------------------------------------------
-- One rule for every string this file prints: an email/JID, a run of five or more digits, and a long
-- message id all become an opaque mark. A node name (served_by) has no such shape and survives.
local MARKS = {
  { "([%w%.%+%-_]+)@([%w%.%-]+)", "<at>" },
  { ("%d"):rep(5) .. "+", "<digits>" },
  { ("%x"):rep(12) .. "+", "<hex>" },
  { "3EB0[%w]+", "<msgid>" },
}
local function redact(value)
  if type(value) ~= "string" then return value end
  for _, rule in ipairs(MARKS) do value = (value:gsub(rule[1], rule[2])) end
  if #value > 120 then value = value:sub(1, 117) .. "..." end
  return value
end

-- The scalar fields the table reports by name: verdict-shaped, never content.
local FIELDS = { "ok", "error", "state", "status", "served_by", "asked_owner", "attempts", "reads",
  "waited_s", "count", "matched", "truncated", "has_more", "retry", "op", "capability", "use",
  "queue_state", "approval", "resolved", "outcome", "tier", "effect" }

-- ---- the shape of an answer ----------------------------------------------------------------------
-- What the model receives, as a shape rather than as bytes of text: keys, types, array sizes and the
-- shape of the first element (an array of messages is one shape, not thirty). Depth is bounded so an
-- adversarial answer cannot flood the table.
local MAX_DEPTH = 4
local MAX_KEYS = 40
local function shape(value, depth)
  local kind = type(value)
  if kind ~= "table" then
    if kind == "string" then return "string(" .. #value .. ")" end
    if kind == "userdata" then return "userdata" end
    return kind
  end
  if depth >= MAX_DEPTH then return "{...}" end
  local n = 0
  for _ in pairs(value) do n = n + 1 end
  if n == 0 then return "{}" end
  if value[1] ~= nil then
    return "[" .. n .. " x " .. shape(value[1], depth + 1) .. "]"
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  local parts = {}
  for index, key in ipairs(keys) do
    if index > MAX_KEYS then parts[#parts + 1] = "..." break end
    parts[#parts + 1] = key .. ":" .. shape(value[key], depth + 1)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- ---- one step ------------------------------------------------------------------------------------
local memory = dofile("lua/core/memory.lua")
memory.setup()
local tools = dofile("lua/core/tools.lua")
local ctx = { user_id = "master", role = "master", codemode_nested = true, site = site }

local answered = {}
local function clock_ms() return math.floor((tonumber(host.now()) or 0) * 1000) end

for _, step in ipairs(plan.steps) do
  local record = { id = tostring(step.id or "?"), tool = tostring(step.tool or "?"), site = site }
  local args = {}
  for key, value in pairs(type(step.args) == "table" and step.args or {}) do args[key] = value end
  if type(step.reuse) == "table" then
    local earlier = answered[tostring(step.reuse.id or "")]
    local value = type(earlier) == "table" and earlier[step.reuse.key or "id"] or nil
    if value == nil then
      record.ok = false
      record.error = "reuse_unavailable:" .. tostring(step.reuse.id)
      print("ACCEPTANCE " .. json.encode(record))
      goto continue
    end
    -- `as` names the argument the value travels in, when it is not the key it came from (`cancel` is
    -- the same job id under a different name).
    args[step.reuse["as"] or step.reuse.key or "id"] = value
  end
  -- THE OWN-CHAT GUARD (live mode). One allow-list, checked before anything is called: with an own
  -- chat configured, a step that names any other chat is refused here, by name, and nothing runs.
  -- A "synthetic" step targets a shape no account can own (a validation probe: a malformed chat the
  -- seam must refuse by name). The guard still applies to every WELL-FORMED chat, so the one bypass is the
  -- one that cannot name a person: the seam refuses the shape before anything is queued (the cell proves it).
  local WELL_FORMED = "^%d+@(s%.whatsapp%.net|lid|g%.us)$"
  local synthetic = step.synthetic == true and type(args.chat) == "string" and not args.chat:match(WELL_FORMED)
  if own_chat ~= "" and type(args.chat) == "string" and args.chat ~= own_chat and not synthetic then
    record.ok = false
    record.error = "refused_not_own_chat"
    record.state = "refused"
    print("ACCEPTANCE " .. json.encode(record))
    goto continue
  end
  local started = clock_ms()
  local ran, answer = pcall(tools.dispatch, memory, record.tool, args, "master", ctx)
  record.ms = clock_ms() - started
  if not ran then
    record.ok = false
    record.error = "dispatch_threw"
  elseif type(answer) ~= "table" then
    record.ok = false
    record.error = "answer_not_a_table"
    record.shape = shape(answer, 0)
  else
    record.ok = answer.ok ~= false and answer.error == nil
    record.bytes = #json.encode(answer)
    record.shape = shape(answer, 0)
    record.fields = {}
    for _, key in ipairs(FIELDS) do
      local value = answer[key]
      if value ~= nil then record.fields[key] = redact(value) end
    end
    -- A slow answer names the JOB it queued. That id is the queue's own integer, never a message id,
    -- so it is reported: without it the table cannot say which question was left unsettled.
    if type(answer.error) == "string" and answer.error:find("_slow$") and type(answer.id) == "number" then
      record.fields.job = answer.id
    end
    answered[record.id] = answer
  end
  print("ACCEPTANCE " .. json.encode(record))
  ::continue::
end
print("ACCEPTANCE " .. json.encode({ id = "done", ok = true, site = site, steps = #plan.steps }))
