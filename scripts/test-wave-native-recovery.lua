-- Fixed private trusted callback, explicitly separate from production admission.
local json=dofile('lua/vendor/json.lua')
local resources=dofile('lua/core/resources.lua')
local ctx={user_id='fixture-native-user',session_id='fixture-native-session',run_id=host.uuid()}
local root=host.getenv('WA_RECOVERY_FIXTURE')
local begun=resources.begin(ctx)
if not begun.ok then print(json.encode({ok=false,error=begun.error}));return end
local driver=dofile('scripts/wave-recovery-driver.lua')
local packet={repo=host.getenv('WA_RECOVERY_REPO'),source_file=root..'/source.json',context_file=root..'/context.json'}
local pause=tonumber(host.getenv('WA_RECOVERY_PAUSE_SEQUENCE'))
packet.observe=function(phase,facts)
  if phase=='held' then host.write_file(root..'/held.json',json.encode(facts)) end
  if phase=='check' and facts.sequence==pause then
    host.write_file(root..'/paused.json',json.encode(facts))
    while not host.read_file(root..'/continue') do host.sleep(10) end
  end
end
local ok,result=pcall(driver.run,packet)
if not ok then resources.uncertain(ctx);result={ok=false,error=tostring(result),uncertain=true} end
if result.ok then assert(resources.finish(ctx).ok) end
host.write_file(root..'/native-result.json',json.encode(result))
print(json.encode(result))
