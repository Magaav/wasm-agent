-- Actual native provider serialization/tool loop through the common socket route.
local json=dofile('lua/vendor/json.lua')
local entry=assert(load(assert(host.read_file(host.getenv('WA_BENCHMARK_RUNTIME_ENTRY'))),'benchmark-runtime'))()
local events={}
local final,sid=entry.run('Model-free fixture: read the designated private file; do not perform other work.',function(e)events[#events+1]=e end)
assert(final=='mock verified final','actual native agent completes the two-round mock')
local memory=dofile('lua/core/memory.lua')
local row=memory.session_messages(sid,{limit=1})[1];local counts
for _,span in ipairs(row.trace or {})do if span.kind=='run_counts' then counts=span end end
assert(counts and counts.model_calls==2 and counts.tool_calls==1,'two model requests and one outer tool dispatch in the real native loop')
print(json.encode({ok=true,checks=2,paid_solver_calls=0,session_id=sid,arm=host.getenv('WA_BENCHMARK_ARM')}))
