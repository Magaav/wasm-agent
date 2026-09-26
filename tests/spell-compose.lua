local json = dofile("lua/vendor/json.lua")
local spells = dofile("lua/core/spells.lua")
local exec, write = host.exec, host.write_file
local first, second, fail_boundary = false, false, false
local calls, timeouts = {}, {}
host.exec = function(command, cwd, timeout)
  calls[#calls+1] = command; timeouts[command] = timeout
  local result
  if command == "first A" then first = true; result = {stage="first"}
  elseif command == "second B" then assert(first); second = true; result = {stage="second"}
  elseif command == "observe-first" then result = {first=first and not fail_boundary}
  elseif command == "observe-both" then result = {first=first,second=second}
  else error("unexpected command: " .. command) end
  return json.encode({code=0,ok=true,settled=true,stdout=json.encode(result)})
end
local function check(command, expect) return {kind="run",script=command,expect=expect} end
local a = {name="t-compose-a",target={node="local"},params={x={type="string"}},
  steps={{kind="run",script="first {{x}}",expect={stage="first"},timeout_seconds=12}},
  post={check("observe-first",{first=true})}}
local b = {name="t-compose-b",target={node="local"},params={y={type="string"}},
  pre={check("observe-first",{first=true})},
  steps={{kind="run",script="second {{y}}",expect={stage="second"}}},
  post={check("observe-both",{first=true,second=true})}}
assert(spells.save(a).ok and spells.save(b).ok)
assert(spells.run(a.name,{x="A"}).settled and spells.run(b.name,{y="B"}).settled)
local versions = {spells.get(a.name).version,spells.get(b.name).version}
local composed = spells.compose({name="t-compose-ab",parts={{name=a.name},{name=b.name}}})
assert(composed.ok and composed.params.p1_x and composed.params.p2_y,json.encode(composed))
first, second, calls = false, false, {}
local done = spells.run("t-compose-ab",{p1_x="A",p2_y="B"})
assert(done.settled and first and second,json.encode(done))
assert(timeouts["first A"]==12,"component timeout must survive composition")
assert(table.concat(calls,",")=="first A,observe-first,observe-first,second B,observe-both,observe-both",
  "all intermediate and terminal observations must run")
assert(done.trace[2].origin.spell==a.name and done.trace[2].origin.phase=="post")
assert(done.trace[4].origin.spell==b.name and done.trace[4].value.stage=="second")
local saved = spells.get("t-compose-ab")
assert(saved.composed_from[1].version==versions[1] and saved.composed_from[2].version==versions[2])
-- Editing a source must not silently mutate the already verified snapshot.
a.steps[1].script="changed"
assert(spells.save(a).ok)
first, second = false, false
assert(spells.run("t-compose-ab",{p1_x="A",p2_y="B"}).settled)
-- A failed boundary stops before the second effect and retains observations for inference.
first, second, fail_boundary = false, false, true
local failed = spells.run("t-compose-ab",{p1_x="A",p2_y="B"})
assert(failed.error=="step_failed" and failed.step==2 and first and not second,json.encode(failed))
assert(failed.trace[2].value.first==false and failed.trace[2].origin.phase=="post")
fail_boundary = false
assert(spells.compose({name="bad",parts={{name="no-such-spell"},{name=b.name}}}).error)
b.target={node="other"}; assert(spells.save(b).ok)
assert(spells.compose({name="bad",parts={{name=a.name},{name=b.name}}}).error=="composition_target_mismatch")
assert(spells.validate({name="bad",steps={{kind="inference"}},post={{script="x"}}})=="step_1_unknown_kind")
assert(spells.validate({name="bad",steps={{kind="wait",ms=1}},post={{kind="run",script="echo"}}})=="post_1_expect_required")
host.exec=function() return json.encode({code=0,ok=true,settled=false,stdout='{"ready":true}'}) end
assert(select(2,spells.run_step(check("stub",{ready=true})))=="run_step_unsettled")
host.write_file=function() return false end
assert(spells.save({name="t-store-failure",steps={{kind="wait",ms=1}},post={{script="x"}}}).error=="spell_store_failed")
host.exec, host.write_file = exec, write
print("spell composition ok")
