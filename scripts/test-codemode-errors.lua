-- A failed script reads as ONE sentence the model can act on (14/11, operator: "the real JS error, line
-- and cause"): the error, the line of the model's own script with its text, what already ran, and for a
-- tool's refusal the tool, its code and its own fix - never a host sentence or quoted JSON.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua');local policy=dofile('lua/core/codemode_policy.lua')
local sid=memory.start_session('','codemode errors',{user_id='master'})
local ctx={session_id=sid,user_id='master'};policy.pin(memory,'master',ctx)
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local function run(code)return tools.dispatch(memory,'codemode',{code=code},'master',ctx)end
local function shown(r)return json.encode({error=r.error,message=r.message,fix=r.fix,line=r.line,code=r.code}):sub(1,400)end

local r=run('const a = 1;\nconst b = ;\nreturn a;')
check(r.ok==false and tostring(r.error):find('^SyntaxError') and r.line==2,'a syntax error names itself and line 2: '..shown(r))
check(tostring(r.message):find('line 2:%d+ | const b = ;') and tostring(r.fix):find('did not compile',1,true),'and shows the line, and says nothing ran: '..shown(r))

r=run('const x = 1;\nconst y = undefinedThing.foo;\nreturn y;')
check(tostring(r.error)=='ReferenceError: undefinedThing is not defined' and r.line==2 and r.code=='ReferenceError','a runtime error is the JS error at the script line: '..shown(r))
check(not tostring(r.message):find('enter',1,true) and not tostring(r.message):find('{"name"',1,true),'with no harness frames and no quoted JSON: '..shown(r))

r=run('const t = await tools.time({});\nconst r = await tools.read({path:"/nonexistent/zz"});\nreturn r;')
check(tostring(r.error):find('^tools%.read failed: ') and r.code=='read_file_missing','a tool refusal names the tool and its code: '..shown(r))
check(tostring(r.fix):find('Already done, not undone: time',1,true),'and what already ran before it: '..shown(r))

r=run('return await tools.no_such_tool({});')
check(tostring(r.error):find('tools.no_such_tool is not a tool here',1,true) and tostring(r.error):find('searchTools',1,true),'an unknown tool says so and how to find one: '..shown(r))
local absent=run('return String("no_such_tool" in tools);');check(tostring(absent.value):find('false',1,true),'`in` still answers false for an absent name: '..shown(absent)..tostring(absent.value))

r=run('const r = tools.time({});\nreturn r.now;')
check(r.line==2 and tostring(r.error):find('has not resolved yet',1,true),'a missing await points at its line: '..shown(r))
-- a script past its budget says so, with the budget and the way on
r=tools.dispatch(memory,'codemode',{code='while (true) {}',timeout_ms=300},'master',ctx)
check(tostring(r.error):find('^TimeoutError: the script was stopped while computing') and not tostring(r.error):find('backtrace',1,true),'an endless loop is named, without the wasm backtrace: '..shown(r))
print(json.encode({ok=true,checks=checks}))
