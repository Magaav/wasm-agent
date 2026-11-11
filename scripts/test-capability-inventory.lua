-- The sandbox half of the capability inventory, over the real QuickJS artifact: `capabilities()` and
-- `describe(name)` have to answer with the exact registry `wa capabilities --json` prints and
-- `/health` digests, because all three read one list (`rust/wa-capabilities/src/capabilities.rs`).
-- Model-free: no provider is called, and neither global admits an effect.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return 'native' end;return getenv(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end

-- The registry itself, through the one capability that publishes it.
check(type(host.capability_inventory)=='function','the inventory is a registered host capability')
local raw=host.capability_inventory()
check(type(raw)=='string' and #raw>0,'the inventory is the registry JSON text')
local list=json.decode(raw)
check(type(list)=='table' and #list>0,'the inventory decodes to a JSON array')
local by_name={}
for _,entry in ipairs(list)do
  check(type(entry.name)=='string' and type(entry.description)=='string' and type(entry.effect)=='string','every entry carries name, description and effect')
  check(by_name[entry.name]==nil,'no capability is listed twice: '..tostring(entry.name))
  by_name[entry.name]=entry
end
check(by_name.exec~=nil and by_name.capability_inventory~=nil,'known capabilities are present')

local sid=memory.start_session('','capability inventory fixture',{user_id='master'})
local ctx={session_id=sid,user_id='master',role='master'}
local function call(code)return tools.dispatch(memory,'codemode',{code=code},'master',ctx)end

-- `capabilities()` is the tool grant list: the outer `capabilities` tool dispatched, so the guest and
-- the facade cannot answer differently (11/11). Its entries are tool names, not registry capabilities.
local r=call('const all=await capabilities(); return JSON.stringify(all);')
check(r.ok and type(r.value)=='string','the sandbox answered capabilities()')
local grant_text=json.decode(r.value)
local granted=json.decode(grant_text)
local outer=tools.dispatch(memory,'capabilities',{},'master',ctx)
check(type(granted)=='table' and type(granted.capabilities)=='table',
 'capabilities() is the grant document: '..tostring(grant_text):sub(1,160))
check(json.encode(granted)==json.encode(outer),
 'sandbox capabilities() is the outer tool grant list ('..#json.encode(granted)..' vs '..#json.encode(outer)..' bytes)')
check(#r.attempts==1,'one capability read, one attempt')
check(r.attempts[1].target=='global' and r.attempts[1].admitted~=true,'the inventory call goes through no tool envelope and admits no effect')

-- `describe()` with no name is the registry document, byte for byte: the same bytes
-- `wa capabilities --json` prints, which is exactly what `capabilities()` used to return.
local doc=call('const all=await describe(); return JSON.stringify(all);')
check(doc.ok and type(doc.value)=='string','the sandbox answered describe() with no name')
local sandbox_text=json.decode(doc.value)
check(type(sandbox_text)=='string','the guest return value is the JSON text it produced')
check(sandbox_text==raw,'describe() returns the registry document unchanged ('..#sandbox_text..' vs '..#raw..' bytes)')
check(host.sha256(sandbox_text)==host.sha256(raw),'describe() hashes to the registry digest')
local seen=json.decode(sandbox_text)
check(#seen==#list,'describe() lists every registry entry ('..#seen..' vs '..#list..')')
for i,entry in ipairs(seen)do
  local expected=list[i]
  check(entry.name==expected.name and entry.description==expected.description and entry.effect==expected.effect,
   'sandbox entry '..i..' is the registry entry ('..tostring(entry.name)..')')
end
check(#doc.attempts==1 and doc.attempts[1].admitted~=true,'describe() admits no effect')

-- One row by exact name.
local one=call('const row=await describe("exec"); return JSON.stringify(row);')
check(one.ok and type(one.value)=='string','the sandbox answered describe("exec")')
local row=json.decode(json.decode(one.value))
check(row.name=='exec' and row.description==by_name.exec.description and row.effect==by_name.exec.effect,
 'describe("exec") is the registry row')
check(#one.attempts==1 and one.attempts[1].admitted~=true,'describe() admits no effect')

-- An unknown name is a visible refusal, never a silent nil.
local missing=call('const row=await describe("no_such_capability"); return JSON.stringify(row);')
check(missing.ok==false,'describe() of an unknown name does not succeed')
check(tostring(missing.error or missing.value):find('unknown_capability',1,true)~=nil,
 'describe() refuses an unknown name: '..tostring(missing.error or missing.value))

print(json.encode({ok=true,checks=checks,count=#list,bytes=#raw,sha256=host.sha256(raw),backend=r.backend,paid_calls=0}))
