-- The failures a real run met on 14/11, each closed where it happened: a script may name its own
-- `text`/`store`; `tools.searchTools` is the helper; an argument a model spells the common way reaches
-- the schema's name; and the line a failure points at is still the script's own line.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua');local policy=dofile('lua/core/codemode_policy.lua')
local contract=dofile('lua/core/json_contract.lua')
local sid=memory.start_session('','friction',{user_id='master'})
local ctx={session_id=sid,user_id='master'};policy.pin(memory,'master',ctx)
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local function run(code)return tools.dispatch(memory,'codemode',{code=code},'master',ctx)end
local r=run('const text = "hi";\nconst store = 1, load = 2, image = 3, exit = 4, results = 5, parallel = 6;\nreturn text + store + parallel;')
check(r.ok and tostring(r.value):find('hi16',1,true),'a script may declare text/store/load/image/exit/results/parallel: '..json.encode(r):sub(1,200))
r=run('const a = await tools.searchTools("select:read");\nreturn a[0].name;')
check(r.ok and tostring(r.value):find('read',1,true),'tools.searchTools is the helper: '..json.encode(r):sub(1,200))
r=run('const r = await tools.read({file:"AGENTS.md", limit:1});\nreturn typeof r.content;')
check(r.ok and tostring(r.value):find('string',1,true),'{file} reaches read as path: '..json.encode(r):sub(1,200))
local schema={type='object',properties={q={type='string'},limit={type='integer'}},additionalProperties=false}
local text,renamed=contract.normalize_names(schema,'{"query":"Laura","limit":3}')
check(json.decode(text).q=='Laura' and renamed[1]=='query->q','query reaches a schema that names it q')
text,renamed=contract.normalize_names(schema,'{"q":"a","query":"b"}')
check(renamed==nil,'a call that passed both keeps both: nothing declared is reinterpreted')
text,renamed=contract.normalize_names({type='object',properties={query={type='string'}}},'{"query":"x"}')
check(renamed==nil,'a declared name is never renamed')
r=run('const a = 1;\nconst b = ;')
check(r.line==2,'the line is still the script line: '..tostring(r.line))
print(json.encode({ok=true,checks=checks}))
