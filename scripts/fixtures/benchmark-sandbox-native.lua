-- Actual native file tools over a blind tool box. No provider/client effects.
local json=dofile('lua/vendor/json.lua')
local adapter=assert(load(assert(host.read_file(host.getenv('WA_BENCHMARK_SANDBOX_CLIENT')))))().install(host.getenv('WA_BENCHMARK_SANDBOX_URL'))
local memory=dofile('lua/core/memory.lua');memory.setup();local sid=memory.start_session('','sandbox-proof',{user_id='master'})
memory.session_worktree=function()return '/tmp/work'end
memory.session_workspace=function()return {required=true,state='allocated',worktree='/tmp/work'}end
local ctx={session_id=sid,user_id='master'};local t=adapter.tools;local checks=0
local function check(ok,msg)assert(ok,msg);checks=checks+1 end
local r=t.dispatch(memory,'read',{path='input.txt'},'master',ctx);check(r.content=='private-alpha\n','sandbox read')
check(t.dispatch(memory,'write',{path='second.txt',content='bravo\n'},'master',ctx).ok,'relative write')
check(t.dispatch(memory,'edit',{path='second.txt',edits={{old_text='bravo',new_text='charlie'}}},'master',ctx).ok,'receipt-compatible edit')
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
