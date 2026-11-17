-- Session variables (docs/CODEMODE.md, "Session variables"). Each `codemode` script runs in a fresh
-- sandbox, so a long run re-fetched what it already had: `vars.<name>` keeps plain data for the session,
-- explicitly (a script assigns it) and visibly (every observation lists the names and sizes).
--
-- What is asserted, on the real sandbox:
--   1. `vars.x = v` in one script is `vars.x` in the next, and in a fresh module instance (the row is
--      the session store in `meta`, the one persistence path `store`/`load` already use);
--   2. `delete vars.x` (or null/undefined) removes it, leaving nothing in the row; a value changed in place (`vars.list.push`) is written back;
--   3. a value JSON cannot encode is a TypeError naming the key; a non-identifier key is refused;
--   4. one variable over 64 KB, or a session over 256 KB, is a RangeError naming the limit;
--   5. a script that throws keeps none of its writes (the store's rule: writes commit on success);
--   6. a pending call assigned without `await` is settled and kept;
--   7. the observation carries `vars: name (size) ...` - names and sizes, never values - right after the
--      header, absent when there are none, capped at 10 names, and tool_output.parse_view reads it back;
--   8. the script's own line numbers do not move (the index rides on harness line 1).
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local output=dofile('lua/core/tool_output.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
local root=dofile('lua/core/paths.lua').data()..'/vars'
assert(host.write_file(root..'/note.txt','hello'))
local sid=memory.start_session('','codemode session vars',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local function dispatch(name,params) return tools.dispatch(memory,name,params,'master',ctx) end
local function run_with(module,code,c)
 local result=module.run(memory,{code=code},'master',c or ctx,catalog,function()return catalog end,dispatch,execution)
 local value=nil
 if result and result.ok and type(result.value)=='string' then value=json.decode(result.value) end
 return result,value
end
local function run(code,c) return run_with(codemode,code,c) end
local function err(result) return tostring(result.message or result.error) end

-- 1. Set in one script, read in the next.
local r,v=run('vars.laura={phone:"+55 11 98888-7777",name:"Laura"}; vars.plan="draft one"; return 1;')
check(r.ok and v==1,'a script sets two variables: '..err(r))
r,v=run('return [vars.laura.name, vars.plan, Object.keys(vars), "plan" in vars, vars.missing===undefined];')
check(r.ok and v[1]=='Laura' and v[2]=='draft one','the next script reads them back: '..tostring(r.value))
check(v[3][1]=='laura' and v[3][2]=='plan' and #v[3]==2 and v[4]==true and v[5]==true,'Object.keys/in/missing answer the session index: '..tostring(r.value))
-- One persistence path: the variables are the session store's `vars.<name>` keys.
r,v=run('return load("vars.plan");')
check(r.ok and v=='draft one','vars.<name> is the store key "vars.<name>": '..tostring(r.value))
-- A fresh module instance (what a process restart re-reads) sees the same row.
local fresh=dofile('lua/core/codemode.lua')
r,v=run_with(fresh,'return vars.laura.phone;')
check(r.ok and v=='+55 11 98888-7777','a fresh codemode instance reads the persisted variable: '..err(r))
-- Another session does not see them.
local other_sid=memory.start_session('','codemode session vars other',{user_id='master'})
r,v=run('return Object.keys(vars).length;',{session_id=other_sid,user_id='master'})
check(r.ok and v==0 and r.vars==nil,'another session has no variables and no vars field: '..tostring(r.value))

-- 2. delete, and write-back of a value changed in place.
r,v=run('delete vars.plan; return ["plan" in vars, Object.keys(vars)];')
check(r.ok and v[1]==false and #v[2]==1,'delete removes the variable in the script: '..err(r))
r,v=run('return [vars.plan===undefined, Object.keys(vars)];')
check(r.ok and v[1]==true and #v[2]==1 and v[2][1]=='laura','and in the next script: '..tostring(r.value))
r=run('vars.list=[1]; return 1;');check(r.ok,'list set: '..err(r))
r=run('vars.list.push(2); vars.laura.seen=true; return 1;');check(r.ok,'list changed in place: '..err(r))
r,v=run('return [vars.list, vars.laura.seen];')
check(r.ok and #v[1]==2 and v[1][2]==2 and v[2]==true,'a value changed in place is written back when the script ends: '..tostring(r.value))
r=run('vars.list=undefined; vars.laura2=1; return 1;')
r,v=run('return "list" in vars;')
check(r.ok and v==false,'assigning undefined deletes')
r=run('vars.laura2=null; return 1;')
r,v=run('return ["laura2" in vars, load("vars.laura2")===undefined, load("vars.plan")===undefined];')
check(r.ok and v[1]==false and v[2]==true and v[3]==true,'null deletes too, and a deleted variable leaves nothing in the store row: '..tostring(r.value))

-- 3. Values JSON cannot encode, and names that are not identifiers.
-- A function is kept as its source and revived in the next script with that script's tools in scope.
r=run('vars.fn=function(x){ return x*2; }; vars.ask=async (q)=>{ const s=await searchTools(q); return typeof s; }; return 1;')
check(r.ok,'a function is kept: '..err(r))
r,v=run('return [vars.fn(21), typeof vars.ask, await vars.ask("read")];')
check(r.ok and v and v[1]==42 and v[2]=='function' and (v[3]=='string' or v[3]=='object'),'a kept function runs in the next script, with searchTools in scope: '..err(r)..' '..json.encode(v))
r=run('vars.bad=Math.max; return 1;')
check(not r.ok and err(r):find('vars.bad',1,true) and err(r):find('no source',1,true),'a built-in function is refused, naming the key: '..err(r))
r=run('delete vars.fn; delete vars.ask; return 1;')
check(r.ok,'functions are deleted like any variable')
r=run('vars.big=10n; return 1;')
check(not r.ok and err(r):find('vars.big',1,true) and err(r):find('JSON-encodable',1,true),'a BigInt is a TypeError naming the key: '..err(r))
r=run('const a={}; a.self=a; vars.loop=a; return 1;')
check(not r.ok and err(r):find('vars.loop',1,true),'a cycle is a TypeError naming the key: '..err(r))
r=run('vars["two words"]=1; return 1;')
check(not r.ok and err(r):find('not a variable name',1,true),'a key that is not an identifier is refused: '..err(r))

-- 4. Size caps.
r=run('vars.huge="x".repeat(70000); return 1;')
check(not r.ok and err(r):find('RangeError',1,true) and err(r):find('vars.huge',1,true) and err(r):find('65536',1,true),'one variable over 64 KB is a RangeError: '..err(r))
r=run('for(let i=0;i<5;i++){ vars["b"+i]="y".repeat(60000); } return 1;')
check(not r.ok and err(r):find('vars are full',1,true) and err(r):find('262144',1,true),'a session over 256 KB is a RangeError: '..err(r))
r,v=run('return Object.keys(vars);')
check(r.ok and #v==1 and v[1]=='laura','the failed script kept none of the four that fit: '..tostring(r.value))
r=run('for(let i=0;i<4;i++){ vars["b"+i]="y".repeat(60000); } return 1;')
check(r.ok,'four variables of 60 KB fit: '..err(r))
r=run('delete vars.b0; delete vars.b1; delete vars.b2; delete vars.b3; vars.after=1; return 1;')
r,v=run('return Object.keys(vars);')
check(r.ok and #v==2,'deleting frees the room: '..tostring(r.value))

-- 5. A script that throws keeps none of its writes.
r=run('vars.plan="v2"; delete vars.after; throw new Error("boom");')
check(not r.ok and err(r):find('boom',1,true),'the failing script fails: '..err(r))
r,v=run('return [vars.plan===undefined, vars.after];')
check(r.ok and v[1]==true and v[2]==1,'its write and its delete were both discarded: '..tostring(r.value))

-- 6. A pending call assigned without await is settled and kept.
r=run('vars.note=tools.read({path:'..json.encode(root..'/note.txt')..'}); return 1;')
check(r.ok,'a pending call can be assigned: '..err(r))
r,v=run('return vars.note.content;')
check(r.ok and v=='hello','the settled result was kept: '..tostring(r.value))
r=run('delete vars.note; return 1;')

-- 7. The observation line: after line 1 and the calls: line, before the blank line.
r,v=run('vars.plan="the plan"; await tools.read({path:'..json.encode(root..'/note.txt')..'}); return "done";')
check(r.ok and type(r.vars)=='table','the result carries the session index: '..err(r))
local view=output.project('codemode',r)
check(view:match('^status [^\n]*\ncalls: [^\n]*\nvars: [^\n]*\n\ndone$')~=nil,'status, calls:, vars:, a blank line, the text: '..view)
check(view:match('\nvars: ([^\n]*)')=='after (1 B) \194\183 laura (56 B) \194\183 plan (10 B)','the vars: line lists names and JSON sizes: '..view)
check(not view:find('Laura',1,true) and not view:find('the plan',1,true),'the line never shows a value: '..view)
local parsed=output.parse_view(view)
check(parsed and parsed.returned=='done' and #parsed.calls==1 and type(parsed.vars)=='table' and #parsed.vars==3,'parse_view reads calls and vars back: '..json.encode(parsed))
check(parsed.vars[2].name=='laura' and parsed.vars[2].size=='56 B' and parsed.vars_more==nil,'with each name and size: '..json.encode(parsed.vars))
-- Without a calls: line, vars: is line 2.
view=output.project('codemode',{ok=true,status=200,summary='search 200',value='"x"',attempts={},calls={},vars=r.vars})
check(view:match('^status [^\n]*\nvars: after %(1 B%)[^\n]*\n\nx$')~=nil,'vars: right after line 1 when no call left evidence: '..view)
parsed=output.parse_view(view)
check(parsed.returned=='x' and #parsed.vars==3 and #parsed.calls==0,'and parse_view reads it')
-- A script with no tool call (only helpers, or none) gets the lean view too: header, vars:, what it returned -
-- never the attempts/backend envelope (17/11, b01db30e: a searchTools-only script answered with 8 KB of it).
r=run('return 7;')
view=output.project('codemode',r)
check(view:match('^status 200 [^\n]*\nvars: after %(1 B%)[^\n]*\n\n7$')~=nil and not view:find('attempts',1,true) and not view:find('backend',1,true),'a no-call script is lean: '..view:sub(1,300))
r=run('const s=await searchTools("read"); return typeof s;')
view=output.project('codemode',r)
check(r.ok and not view:find('"attempts"',1,true) and not view:find('rust-wasmtime',1,true),'a helper-only script is lean: '..view:sub(1,300))
-- A failed script's view (the JSON form) carries the same index as a field.
r=run('throw new Error("nope");')
view=output.project('codemode',r)
local decoded=json.decode(view)
check(decoded.vars=='after (1 B) \194\183 laura (56 B) \194\183 plan (10 B)','a failure lists the variables it left untouched: '..view:sub(1,300))
parsed=output.parse_view(view)
check(type(parsed.vars)=='table' and #parsed.vars==3,'and parse_view reads that form too')
-- No variables, no line.
r=run('return 7;',{session_id=other_sid,user_id='master'})
view=output.project('codemode',r)
check(not view:find('vars',1,true),'no variables, no line: '..view)
-- Ten names, then +N more; sizes in KB.
local many={}
for i=1,12 do many[i]={name=string.format('v%02d',i),bytes=i==1 and 12*1024+300 or (i==2 and 1536 or 4)} end
local line=output.vars_line(many)
check(line:find('^v01 %(12 KB%) \194\183 v02 %(1%.5 KB%) \194\183 v03 %(4 B%)') and line:find(' \194\183 %+2 more$') and not line:find('v11',1,true),'ten names, then +N more: '..line)
local list,more=output.parse_vars(line)
check(#list==10 and more==2 and list[1].size=='12 KB','parse_vars reads the cap back')
-- The tool path (what the model's turn records) carries the same field.
local dispatched=tools.dispatch(memory,'codemode',{code='return vars.plan;'},'master',ctx)
check(type(dispatched)=='table' and type(dispatched.vars)=='table' and #dispatched.vars==3,'tools.dispatch keeps the index: '..tostring(dispatched and dispatched.error))

-- Sizes are UTF-8 bytes of the JSON, as the store row holds them.
local usid=memory.start_session('','codemode session vars utf8',{user_id='master'})
r=run('vars.u="\\u00e9\\ud83d\\ude00a"; return vars.u.length;',{session_id=usid,user_id='master'})
check(r.ok and r.vars and r.vars[1].name=='u' and r.vars[1].bytes==9,'"\195\169\240\159\152\128a" is 9 bytes of JSON: '..json.encode(r.vars))
r,v=run('return vars.u;',{session_id=usid,user_id='master'})
check(r.ok and v=='\195\169\240\159\152\128a','and reads back intact: '..tostring(r.value))

-- 8. Line numbers are the script's own.
r=run('const a=1;\nnull.x;')
check(not r.ok and r.line==2,'a TypeError on script line 2 says line 2: '..err(r))

print('session vars ok ('..checks..' checks; real sandbox)')
