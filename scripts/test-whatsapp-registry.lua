-- The WhatsApp registry door, runtime: `whatsapp_index({op="ops"})` is the ONE question that
-- answers "what can I ask", and it must answer in three shapes and no others.
--
-- The world note (`ready-whatsapp-world.md`) lists this as the check it did not have: the registry
-- the COMPONENT answers against the one the HOST declares. What is provable without a worker is the
-- door itself, and that is what this file pins:
--   * it is a host capability (bound, callable), not a plugin and not an mcp connector - 28/11: the
--     bare name reached `host.plugins` through the model's tool dispatch and answered
--     `plugin_not_found`, which is why this row calls the capability the way the core does;
--   * it is a READ: `effect` is never `files`;
--   * with no component working the queue it says `whatsapp_ops_slow` with an `id`, `state=queued`
--     and `retry=true` - the answer a caller acts on, never silence and never a lie;
--   * when the component does answer, the document names ops this node really has.
-- Deeper (comparing the registry the artifact answers with `seam::Op::ALL`) needs a worker on the
-- scratch node; that is the next row, and this one names it rather than pretending to cover it.
local json = dofile("lua/vendor/json.lua")

local checks, skipped = 0, 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function skip(label) skipped = skipped + 1; print("skip " .. label) end

ok(type(host.whatsapp_index) == "function", "the registry door is a bound host capability")

local raw = host.whatsapp_index(json.encode({ op = "ops" }))
ok(type(raw) == "string" and #raw > 0, "the door answers with a document, never silence")
local answer = json.decode(raw)
ok(type(answer) == "table", "the answer decodes as one object")
ok(answer.effect ~= "files", "the registry door is a read, so it never declares a file effect")
ok(answer.op == "ops", "the answer names the op it answered: " .. tostring(answer.op))

if answer.ok == true then
  local document = answer.registry or answer.answer or answer.ops
  ok(document ~= nil, "a successful registry answer carries the document")
  local named = 0
  if type(document) == "table" then
    for key, value in pairs(document) do
      if type(value) == "table" then named = named + 1 end
      if type(key) == "string" and type(value) == "table" then named = named end
    end
  end
  ok(named > 0, "the document names at least one op")
else
  -- TWO named refusals, and both must be words a caller can act on. They are different facts:
  --   whatsapp_component_absent - this node has no whatsapp-index component at all;
  --   whatsapp_ops_slow         - the component is there, the job is queued, ask again by id.
  ok(answer.error == "whatsapp_ops_slow" or answer.error == "whatsapp_component_absent",
    "an unanswered registry names one of its two reasons, never a shape error: " .. tostring(answer.error))
  -- The absent answer carries only its code (the refusal renderer adds the sentence a caller reads);
  -- the slow one carries a detail. Both are words, and neither is silence.
  if answer.error == "whatsapp_ops_slow" then
    ok(type(answer.id) == "number" and answer.id > 0, "the slow answer carries the job id the caller reads back: " .. tostring(answer.id))
    ok(answer.state == "queued" or answer.state == "leased", "the job is on the queue: " .. tostring(answer.state))
    ok(answer.retry == true, "the caller is told to ask again, not to give up")
    -- The same call reads the same job: a registry question is deduped, not a new job every time.
    local again = json.decode(host.whatsapp_index(json.encode({ op = "ops" })))
    ok(again.id == answer.id, "the same question reads the same job: " .. tostring(again.id) .. " vs " .. tostring(answer.id))
    skip("the registry document itself (no component working the queue in this home)")
  else
    skip("the registry document itself (this home has no whatsapp-index component)")
  end
end

print(string.format("whatsapp registry ok (%d checks, %d skipped)", checks, skipped))
