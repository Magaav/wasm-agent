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
-- A command that ran and exited non-zero is a result the script reads, not an exception (a pgrep that
-- found nothing killed its script, 14/11).
r=run('const r = await tools.bash({command:"exit 3"});\nreturn [r.ok, r.status, r.code].join(",");')
check(r.ok and tostring(r.value):find('true,200,3',1,true),'a non-zero exit is a result: '..json.encode(r):sub(1,300))
-- A connector read is its data, not the MCP envelope (every email script guessed the path, 14/11).
local codemode=dofile('lua/core/codemode.lua')
local env={ok=true,tool_call_issued=true,evidence={sha256='x'},result={content={{type='text',text='{}'}},structuredContent={data={account_id='a',count=2},summary='s'},isError=false}}
local v,ok=codemode.script_value(env,true)
check(ok and v.account_id=='a' and v.count==2 and v.result==nil,'an MCP read arrives as structuredContent.data')
v,ok=codemode.script_value({ok=true,tool_call_issued=true,result={content={{type='text',text='{"n":1}'}}}},true)
check(ok and v.n==1,'without structured content the text is parsed')
v,ok=codemode.script_value({ok=true,tool_call_issued=true,result={content={{type='text',text='{"data":{"messages":[1,2]},"meta":{"x":1}}'}}}},true)
check(ok and type(v.messages)=='table' and #v.messages==2,'a text answer shaped {data, meta} is its data, like structured content')
v,ok=codemode.script_value({ok=false,error='mcp_rpc_error:-32602:bad'},false)
check(not ok,'a refusal stays a refusal')
-- A connector named without its hash suffix is that tool when the stem is unique (a typed hash was wrong, 14/11).
local stem_name
for _,t in ipairs(tools.all('master',ctx)) do local n=t['function'].name if n:match('^read$') then stem_name=n end end
r=run('const s = await searchTools("files read");\nreturn s.length > 0 && s.every(x => x.schema === undefined && typeof x.parameters === "object" && typeof x.name === "string");')
check(r.ok and tostring(r.value)=='true','a word search is compact: name, parameters, no schema: '..tostring(r.value):sub(1,200))
-- select: and the script's tools.<name> both resolve a connector named without its hash suffix (unique stem only)
local cat={{type='function',['function']={name='mcp_google_imap_list_accounts_828ac338',description='List accounts',parameters={type='object',properties={}}}},
 {type='function',['function']={name='mcp_x_get_aaaa1111',description='a',parameters={type='object',properties={}}}},
 {type='function',['function']={name='mcp_x_get_bbbb2222',description='b',parameters={type='object',properties={}}}}}
local lk=codemode.lookup(cat,function() return {status='ok'} end,nil)
local hit=lk.discover({'select:mcp_google_imap_list_accounts'})
check(hit[1] and hit[1].name=='mcp_google_imap_list_accounts_828ac338' and hit[1].found~=false,'a unique stem resolves in select: '..json.encode(hit[1]):sub(1,160))
local two=lk.discover({'select:mcp_x_get'})
check(two[1] and two[1].found==false,'two tools with one stem stay unresolved')
print(json.encode({ok=true,checks=checks}))
