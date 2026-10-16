-- Actual native file tools over a blind tool box. No provider/client effects.
local json=dofile('lua/vendor/json.lua')
local raw_write=host.write_file;local inject_failure=false
host.write_file=function(p,text)if inject_failure and tostring(p):find('/changes/',1,true)then return false end;return raw_write(p,text)end
local adapter=assert(load(assert(host.read_file(host.getenv('WA_BENCHMARK_SANDBOX_CLIENT')))))().install(host.getenv('WA_BENCHMARK_SANDBOX_URL'))
local memory=dofile('lua/core/memory.lua');memory.setup();local sid=memory.start_session('','sandbox-proof',{user_id='master'})
memory.session_worktree=function()return '/tmp/work'end
memory.session_workspace=function()return {required=true,state='allocated',worktree='/tmp/work'}end
local changes=dofile('lua/core/changeset.lua');assert(changes==dofile('lua/core/changeset.lua'),'singleton changeset module')
local ctx={session_id=sid,user_id='master',changes=changes.new()};local t=adapter.tools;local checks=0
local function check(ok,msg)assert(ok,msg);checks=checks+1 end
local r=t.dispatch(memory,'read',{path='input.txt'},'master',ctx);check(r.content=='private-alpha\n','sandbox read')
check(t.dispatch(memory,'write',{path='second.txt',content='bravo\n'},'master',ctx).ok,'relative write')
check(t.dispatch(memory,'edit',{path='second.txt',edits={{old_text='bravo',new_text='charlie'}}},'master',ctx).ok,'receipt-compatible edit')
local entry=ctx.changes.files[1];check(entry.path=='/tmp/work/second.txt' and changes.load(entry.before)=='' and changes.load(entry.after)=='charlie\n','reversible write/edit blobs')
check(entry.before==host.sha256('') and entry.after==host.sha256('charlie\n'),'content addresses match bytes')
for _,address in ipairs({'../foreign','/etc/passwd',string.rep('a',63),string.rep('G',64),string.rep('e',64),string.rep('f',64)})do check(not pcall(changes.load,address),'malformed or linked changeset address refused')end
local private=host.getenv('WASM_AGENT_HOME')..'/.wasm-agent/changes/'..entry.after:sub(1,2)..'/'..entry.after
for _,operation in ipairs({'read','write'})do local args=operation=='read' and {path=private} or {path=private,content='corrupt'};local called,value=pcall(t.dispatch,memory,operation,args,'master',ctx);check(not called or value.error~=nil,'ordinary model file API cannot use private changeset path')end
check(changes.load(entry.after)=='charlie\n','model refusals did not corrupt blob')
for _,operation in ipairs({'read','write'})do local foreign=host.getenv('WASM_AGENT_HOME')..'/../foreign/.wasm-agent/changes/'..entry.after;local args=operation=='read' and {path=foreign} or {path=foreign,content='bad'};local called,value=pcall(t.dispatch,memory,operation,args,'master',ctx);check(not called or value.error~=nil,'foreign-home model paths refused')end
local hp=host.paths;host.paths=function()return {data=host.getenv('WASM_AGENT_HOME')..'/../foreign'}end
check(not pcall(changes.store,'foreign-controller-attempt'),'trusted changeset data root cannot change homes');host.paths=hp
inject_failure=true;check(not pcall(changes.store,'deliberate unique store write failure'),'changeset logging failure is surfaced');inject_failure=false
check(changes.load(entry.after)=='charlie\n','scope restored after storage failure')
local b=t.dispatch(memory,'bash',{command='cat second.txt',timeout_seconds=10},'master',ctx);check(b.code==0 and b.stdout=='charlie\n','actual shell')
check(t.dispatch(memory,'client',{action='status'},'master',ctx).effect=='none','client not permitted')
check(t.dispatch(memory,'write',{path='guest.txt',content='denied'},'guest',ctx).error~=nil,'role ceiling')
check(t.dispatch(memory,'read',{path='missing.txt'},'master',ctx).error=='not_found','missing stays missing')
local text=string.rep('alpha-',7000)..'\n';check(t.dispatch(memory,'write',{path='big.txt',content=text},'master',ctx).ok,'large source seed')
local first=t.dispatch(memory,'read_many',{requests={{path='big.txt',column=1,limit=1},{path='big.txt',column=1,limit=1}}},'master',ctx)
check(first.next_cursor and first.full_result and #json.encode(first)<=51200,'whole-result cache page')
check(t.dispatch(memory,'write',{path='big.txt',content='changed'},'master',ctx).ok,'later source mutation')
local second=t.dispatch(memory,'read_many',{cursor=first.next_cursor},'master',ctx)
check(second.results and second.results[1].content==text,'cursor reuses original, not refetch')
local raw=t.dispatch(memory,'tool_result',{sha256=first.full_result.sha256,offset=1,limit=1024},'master',ctx)
check(raw.content and raw.content:find('alpha-',1,true),'hash-addressed original readable')
local called,blocked=pcall(t.dispatch,memory,'read',{path=first.full_result.path},'master',ctx);check(not called or type(blocked)=='table' and blocked.error and not blocked.content,'host artifact path never grants file authority')
local png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7l8AAAAASUVORK5CYII='
local image_seed=t.dispatch(memory,'bash',{command="printf '%s' '"..png.."' | base64 -d > one.png",timeout_seconds=10},'master',ctx);check(image_seed.code==0,'image seed stays in tool box')
local image=t.dispatch(memory,'read',{path='one.png'},'master',ctx);check(image.type=='image' and image.mime=='image/png','private image storage preserves read contract')
print(json.encode({ok=true,checks=checks,provider_calls=0}))
