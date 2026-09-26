-- The `run` step: a spell's node-side deterministic half.
--
-- A spell's deterministic part is often a script, not a click. This step makes that expressible, so a
-- skill can be prose for the judgement and a spell for the part that never needed a model.
--
-- The outcome contract is deliberately the same as the `run` job action's - exit 0 *and* a JSON object
-- on stdout - because two shapes for "a deterministic step succeeded" would be one shape too many.
-- `host.exec` is stubbed here: the assertion is about the contract, not about a particular command.
local json = dofile("lua/vendor/json.lua")
local spells = dofile("lua/core/spells.lua")

local failed = 0
local function ok(condition, label)
  if not condition then
    print("FAIL " .. label)
    failed = failed + 1
  end
end

-- Stub the host's exec so the test says what the contract is, with no command and no platform.
local real_exec = host.exec
local function stub_exec(wrapper)
  host.exec = function() return json.encode(wrapper) end
end
local function wrapper(code, stdout)
  return { code = code, stdout = stdout, state = "completed", settled = true, ok = code == 0 }
end

-- A successful step: exit 0, JSON on stdout, expectations met.
stub_exec(wrapper(0, '{"status":"ok","sent":2}'))
local passed, failure, result = spells.run_step({ kind = "run", script = "stub", expect = { status = "ok", sent = 2 } })
ok(passed == true, "a run step with matching expectations must pass, got " .. tostring(failure))
ok(type(result) == "table" and result.sent == 2, "the step must hand back its decoded result")

-- A foreground command result can complete its deterministic step while adopted
-- descendants remain supervised. The spell's required postconditions still settle
-- the effect before the spell itself reports success.
stub_exec({ code = 0, command_code = 0, command_completed = true, promoted = true,
  settled = false, ok = true, stdout = '{"status":"ok"}' })
local adopted_pass, adopted_failure = spells.run_step({ kind = "run", script = "stub" })
ok(adopted_pass == true,
  "a completed foreground command is usable by a spell with postconditions: " .. tostring(adopted_failure))
stub_exec({ code = 0, promoted = true, settled = false, ok = true, stdout = '{"status":"ok"}' })
local _, incomplete_command = spells.run_step({ kind = "run", script = "stub" })
ok(incomplete_command == "run_step_unsettled",
  "an adopted launch receipt without command completion is not spell evidence")

-- No expectations is legal: the exit code and the JSON object are the contract, not the fields.
stub_exec(wrapper(0, '{"anything":true}'))
ok(spells.run_step({ kind = "run", script = "stub" }) == true, "a run step needs no expect")

-- A non-zero exit is a failure even with perfect JSON: the command said it failed.
stub_exec(wrapper(3, '{"status":"ok"}'))
local _, exit_failure = spells.run_step({ kind = "run", script = "stub" })
ok(type(exit_failure) == "string" and exit_failure:find("run_step_exit_3", 1, true) ~= nil,
  "a non-zero exit must fail the step, got " .. tostring(exit_failure))

-- Stdout that is not a JSON object is not evidence.
stub_exec(wrapper(0, "not json at all"))
local _, unparsed = spells.run_step({ kind = "run", script = "stub" })
ok(unparsed == "run_step_stdout_not_json", "stdout that is not JSON must fail, got " .. tostring(unparsed))
stub_exec(wrapper(0, '[1,2,3]'))
local _, array = spells.run_step({ kind = "run", script = "stub" })
ok(array == "run_step_stdout_not_json", "a JSON array is not a result object, got " .. tostring(array))

-- An expectation that does not hold is a failed step, never a warning.
stub_exec(wrapper(0, '{"status":"failed"}'))
local _, mismatch = spells.run_step({ kind = "run", script = "stub", expect = { status = "ok" } })
ok(type(mismatch) == "string" and mismatch:find("run_step_expect_status", 1, true) ~= nil,
  "a mismatched expectation must fail the step, got " .. tostring(mismatch))

-- A step with no script, and a result the host could not hand back, are both refusals.
ok(select(2, spells.run_step({ kind = "run" })) == "run_step_script_required", "a run step needs a script")
host.exec = function() return "not an operation wrapper" end
ok(select(2, spells.run_step({ kind = "run", script = "stub" })) == "run_step_unreadable_result",
  "an unreadable host result is a failure, not a pass")

-- Validation: the step must be saveable only when it is well-formed.
ok(spells.validate({ name = "t", steps = { { kind = "run" } }, post = { { script = "x" } } }) == "step_1_script_required",
  "validate must refuse a run step with no script")
ok(spells.validate({ name = "t", steps = { { kind = "run", script = "s", expect = "not a table" } }, post = { { script = "x" } } })
  == "step_1_expect_must_be_a_table", "validate must refuse a non-table expect")
ok(spells.validate({ name = "t", steps = { { kind = "run", script = "s" } }, post = { { script = "x" } } }) == nil,
  "a well-formed run step must validate")

-- A run step can never be a sentinel plan: the process that can restart this node must not be able to
-- run a command. Asserted here as well as in tests/spell-sentinel.lua, because this is the step kind
-- that made the boundary worth restating.
local saved = spells.save({
  name = "t-run-not-sentinel",
  steps = { { kind = "run", script = "echo hello" } },
  post = { { script = "document.title" } },
})
ok(saved.ok == true, "a spell with a run step must be saveable, got " .. json.encode(saved))
local _, why = spells.export("t-run-not-sentinel", {}, nil)
ok(type(why) == "string" and why:find("step_kind_not_exportable", 1, true) ~= nil,
  "a run step must not export as a sentinel plan, got " .. tostring(why))

host.exec = real_exec
if failed == 0 then print("spell run ok") end
