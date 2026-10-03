-- Explicit PRIVATE fixture only; no human/production approval or global admission.
local json=dofile('lua/vendor/json.lua')
local resources=dofile('lua/core/resources.lua')
local root=assert(host.getenv('WA_CURRENT_FIXTURE'))
local ctx={user_id='private-current-executor',session_id='private-current-session-'..host.uuid(),run_id=host.uuid()}
assert(resources.begin(ctx).ok)
local refused=json.decode(host.resource('target_registered_inspect',json.encode({resource_root=root..'/legacy-resources',git_common_dir=root..'/canonical/.git',ref='refs/heads/main'})))
assert(refused.admissible==false and refused.effect_authorized==false)
assert(host.write_file(root..'/legacy-inspection.json',json.encode(refused)))
local driver=dofile('scripts/wave-current-ref-driver.lua')
local packet={repo=root..'/canonical',source_file=root..'/source.json',grant_file=root..'/grant-envelope.json'}
packet.observe=function(phase,facts)
  if phase=='context' then
    assert(host.write_file(root..'/context-observed.json',json.encode(facts)))
    while not host.read_file(root..'/context-continue') do host.sleep(10) end
  elseif phase=='check' and facts.sequence==tonumber(host.getenv('WA_CURRENT_PAUSE_SEQUENCE')) then
    assert(host.write_file(root..'/prepared-paused.json',json.encode(facts)))
    while not host.read_file(root..'/prepared-continue') do host.sleep(10) end
  end
end
local result=driver.run(packet)
if result.ok then assert(resources.finish(ctx).ok) else resources.uncertain(ctx) end
assert(host.write_file(root..'/result.json',json.encode(result)))
print(json.encode(result))
