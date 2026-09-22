-- Spells that only the sentinel can perform.
--
-- A spell normally runs on the node's Lua worker. That works until the plan is *about* the node:
-- an upgrade stops the worker, so a turn running on it cannot survive its own plan, and its `post`
-- assertions - the effect settlement that makes a spell a spell - never run. The `sentinel` step
-- kind exists for that: it declares what the sentinel should do, and `export` writes the plan for
-- `wa-sentinel request spell --file ...`, which runs it outside the node and settles it from there.
--
-- What is asserted here is mostly *refusal*, because the interesting property is what a plan cannot
-- do. A spell file is written by the agent and is therefore untrusted input to the sentinel, so the
-- whitelist is the safety boundary, not a formality.
--
-- The sentinel enforces the same list independently (rust/wa-sentinel/src/spell.rs). It is asserted
-- here that the two agree on which verbs exist, since they are two implementations of one rule.
local json = dofile("lua/vendor/json.lua")
local spells = dofile("lua/core/spells.lua")

local failed = 0
local function ok(condition, label)
  if not condition then
    print("FAIL " .. label)
    failed = failed + 1
  end
end
local function reason_of(result) return select(2, pcall(function() return result.error end)) end

-- A `sentinel` step is legal and saves.
local saved = spells.save({
  name = "t-self-update",
  description = "replace this node's binary from outside",
  params = { binary = { type = "string" } },
  steps = {
    { kind = "sentinel", verb = "wait-idle" },
    { kind = "sentinel", verb = "upgrade", binary = "{{binary}}" },
  },
  post = { { script = "/health ok:true" } },
})
ok(saved.ok == true, "a spell with sentinel steps must be saveable, got " .. json.encode(saved))

-- It cannot run here: the run must say so, not skip the steps and report success.
local run = spells.run("t-self-update", { binary = "C:/x/wa.exe" })
ok(run.error == "needs_sentinel",
  "running a sentinel spell must refuse with needs_sentinel, got " .. json.encode(run.error))
ok(type(run.detail) == "string" and run.detail:find("spell_export") ~= nil,
  "the refusal must name the way to run it (spell_export), got " .. tostring(run.detail))

-- An ordinary spell is unaffected: it still runs, and does not claim to need the sentinel.
spells.save({
  name = "t-plain",
  steps = { { kind = "wait", ms = 1 } },
  post = { { script = "1", equals = 1 } },
})
ok(spells.needs_sentinel(spells.get("t-plain")) == false,
  "a spell with no sentinel step must not report as needing the sentinel")
ok(spells.needs_sentinel(spells.get("t-self-update")) == true,
  "a spell with a sentinel step must report as needing the sentinel")

-- Exporting produces the portable plan: the resolved steps, no model, no node.
local binary = "C:/Users/Victor/orca/workspaces/wasm-agent/node/foundation/rust/target/release/wa.exe"
local plan, why = spells.export("t-self-update", nil, binary)
ok(plan ~= nil, "export must produce a plan, got " .. tostring(why))
if plan then
  ok(plan.name == "t-self-update", "the plan must carry the spell name")
  ok(#plan.steps == 2, "the plan must carry both steps, got " .. #plan.steps)
  ok(plan.steps[1].verb == "wait-idle", "step kinds and verbs must survive the export")
  -- The binary is filled from the export argument, so one plan is re-exported per build rather than
  -- the spell hardcoding a path that goes stale.
  ok(plan.steps[2].binary == binary,
    "the export argument must fill the binary step, got " .. tostring(plan.steps[2].binary))
  -- post travels with the plan: a plan that cannot state its own success condition is the v8 failure
  -- mode in file form, so an export without one would be worse than no export.
  ok(#plan.post == 1, "the plan must carry its postconditions, got " .. #plan.post)
end

-- A plan may only contain what the sentinel can perform. A client step belongs to the node, and
-- dropping it silently would produce a plan that looks complete and does less than the spell says.
spells.save({
  name = "t-mixed",
  steps = {
    { kind = "client", action = "click", x = 1, y = 2 },
    { kind = "sentinel", verb = "restart" },
  },
  post = { { script = "1" } },
})
local mixed, mixed_why = spells.export("t-mixed", nil)
ok(mixed == nil, "a spell with a client step must not export as a sentinel plan")
ok(type(mixed_why) == "string" and mixed_why:find("step_kind_not_exportable") ~= nil,
  "the refusal must name the reason, got " .. tostring(mixed_why))

-- The whitelist, at save time. An unknown verb is refused here and again in the sentinel, so a plan
-- edited on disk cannot reach a verb the two did not agree on.
local escapes = {
  { name = "t-sh", steps = { { kind = "sentinel", verb = "shell" } } },
  { name = "t-arbitrary", steps = { { kind = "sentinel", verb = "delete-everything" } } },
}
for _, spec in ipairs(escapes) do
  spec.post = { { script = "1" } }
  local result = spells.save(spec)
  ok(result.error == "step_1_sentinel_verb_unknown",
    "verb for " .. spec.name .. " must be refused, got " .. json.encode(result.error))
end

-- `run` is allowed, and it is the one verb that reaches a script - so it must name one. The sentinel
-- additionally executes it only from a directory the operator named in WA_SENTINEL_SCRIPTS
-- (rust/wa-sentinel/src/spell.rs): the plan chooses which script, never how it runs.
local run_no_script = spells.save({
  name = "t-run-noscript",
  steps = { { kind = "sentinel", verb = "run" } },
  post = { { script = "1" } },
})
ok(run_no_script.error == "step_1_sentinel_run_needs_script",
  "a run step must require a script, got " .. json.encode(run_no_script.error))

local run_script = spells.save({
  name = "t-run-script",
  steps = { { kind = "sentinel", verb = "run", script = "{{script}}" } },
  params = { script = { type = "string", default = "scripts/restart-watcher.sh" } },
  post = { { script = "1" } },
})
ok(run_script.ok == true, "a run step with a script must save, got " .. json.encode(run_script))
if run_script.ok then
  local exported = spells.export("t-run-script")
  ok(exported ~= nil, "a run step must export as a sentinel plan")
  if exported then
    ok(exported.steps[1].verb == "run", "the run verb must survive export")
    ok(exported.steps[1].script == "scripts/restart-watcher.sh",
      "the run script must survive export, got " .. tostring(exported.steps[1].script))
  end
  spells.remove("t-run-script")
end
spells.remove("t-run-noscript")

-- `upgrade` names a binary, and a step that ignores an argument must be refused rather than accept it.
local no_binary = spells.save({
  name = "t-nobinary",
  steps = { { kind = "sentinel", verb = "upgrade" } },
  post = { { script = "1" } },
})
ok(no_binary.error == "step_1_sentinel_upgrade_needs_binary",
  "an upgrade step must require a binary, got " .. json.encode(no_binary.error))

-- A plan with nothing to do always "succeeds", so exporting one is refused.
local empty = spells.export_to_file("t-does-not-exist", nil, nil, nil)
ok(empty.error == "unknown_spell:t-does-not-exist",
  "exporting an unknown spell must say so, got " .. json.encode(empty.error))

-- Export writes a file that is readable JSON, and reads it back before claiming success: the
-- sentinel meets this file at the worst possible moment, so a plan that cannot be re-read is not a
-- plan.
local written = spells.export_to_file("t-self-update", nil, binary, nil)
ok(written.ok == true, "export_to_file must succeed, got " .. json.encode(written))
if written.ok then
  ok(type(written.path) == "string" and written.path ~= "", "the export must return a path")
  local text = host.read_file and host.read_file(written.path)
  ok(text ~= nil and text ~= "", "the written plan must be readable at " .. tostring(written.path))
  local decoded = text and json.decode(text)
  ok(decoded ~= nil and decoded.name == "t-self-update",
    "the written plan must be valid JSON carrying the spell name")
  -- The command in the reply is the whole point of the artifact: one line, no model in the loop.
  ok(type(written.command) == "string" and written.command:find("wa%-sentinel request spell") ~= nil,
    "the export must tell the caller how to run it, got " .. tostring(written.command))
  os.remove(written.path)
end

spells.remove("t-self-update")
spells.remove("t-plain")
spells.remove("t-mixed")

if failed > 0 then
  print("FAILED " .. failed)
  os.exit(1)
end
print("ALL PASS")
