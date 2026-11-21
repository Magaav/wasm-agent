-- The native run tool's raw blocks reach the script as the variables the tool description names.
--
-- run({code, raw}) is described to the model as "raw ... as an object keyed by the variable name the
-- script should read". Only `__raw` was bound, so a script that read `body` died with
-- `ReferenceError: body is not defined` (reported by the seam-audit mission, 20/11: four patch
-- scripts were rewritten through shell heredocs instead). Each row below runs the code native_run
-- builds in the REAL sandbox, because the defect is what JavaScript does with that code, which a
-- string match cannot show.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local raw_code=dofile('lua/core/raw_code.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,answer=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(answer);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no JavaScript ran and nothing here was measured')
local sid=memory.start_session('','native raw vars',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local function dispatch(name,params) return tools.dispatch(memory,name,params,'master',ctx) end
local function run(args)
 local call,refusal=raw_code.native_run(args)
 if not call then return nil,nil,refusal end
 local result=codemode.run(memory,{code=call.code},'master',ctx,catalog,function()return catalog end,dispatch,execution)
 return result,result and result.ok and result.value and json.decode(result.value) or nil
end

-- 1. The block is the variable the description names: `body` is defined, byte for byte.
local tricky='a\\b"c\nd\te\r\0f'
local result,value=run({code='return {len: body.length, same: body === __raw.body, text: body};',raw={body=tricky}})
check(result and result.ok,'a script reading the raw block by its name runs: '..tostring(result and (result.error or result.message)))
check(type(value)=='table' and value.len==#tricky,'the variable carries every byte ('..tostring(value and value.len)..' of '..#tricky..')')
check(value.same==true and value.text==tricky,'it is the same string as __raw.body, exactly')

-- 2. Two blocks are two variables.
result,value=run({code='return a + "|" + b;',raw={a='one',b='two'}})
check(result and result.ok and value=='one|two','two raw blocks are two variables: '..tostring(value))

-- 3. The older style still runs: a script that declares its own `const body = __raw.body` is not a
-- redeclaration of the bound name (it would be a SyntaxError at the top level).
result,value=run({code='const body = __raw.body; return body.length;',raw={body='xyz'}})
check(result and result.ok and value==3,'a script that declares the name itself still runs: '..tostring(result and (result.error or result.message)))

-- 4. A script without raw is untouched (no wrapper, no binding).
local plain=assert(raw_code.native_run({code='return 1'}))
check(plain.code=='return 1','a run without raw is the code as written')

-- 5. A name that cannot be a safe variable is refused by name, before anything runs. raw is one of
-- them now: it is bound by native_run to the whole object (row 6), so a block of that name would
-- collide with the binding.
for _,name in ipairs({'tools','class','JSON','__raw','Promise','raw'}) do
 local call,why=raw_code.native_run({code='return 1',raw={[name]='x'}})
 check(call==nil and why and why.error=='run_raw_name' and why.name==name,'raw block '..name..' is refused as run_raw_name')
end

-- 6. raw IS the whole object, under the name the tool description uses: a model wrote raw.patch in a
-- run script and died with ReferenceError: raw is not defined (20/11 and 21/11). raw.patch and patch
-- are the same bytes, and raw is __raw.
local patch='--- a/x\n+++ b/x\n'
result,value=run({code='return {byName: patch === raw.patch, whole: raw === __raw, len: raw.patch.length, text: raw.patch};',raw={patch=patch}})
check(result and result.ok,'a script reading raw.<name> runs: '..tostring(result and (result.error or result.message)))
check(type(value)=='table' and value.byName==true and value.whole==true,
  'raw.patch and patch are the same bytes, and raw IS __raw: '..json.encode(value or {}))
check(type(value)=='table' and value.len==#patch and value.text==patch,'raw.<name> carries every byte')

-- 7. A block named raw is refused by name, and says why, instead of colliding with the binding.
local callraw,whraw=raw_code.native_run({code='return 1',raw={raw='x'}})
check(callraw==nil and whraw and whraw.error=='run_raw_name' and whraw.name=='raw',
  'a raw block named raw is refused as run_raw_name: '..json.encode(whraw or {}))

print('native raw vars ok ('..checks..' checks)')
