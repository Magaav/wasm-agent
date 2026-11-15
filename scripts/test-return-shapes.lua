-- Return shapes in the connector index (15/11): a model that knows what a tool answers before calling
-- it never spends a call on `Object.keys(r)` (real runs: imap get_message nests under `message`,
-- search_messages answers `messages` at the top, a WhatsApp read answers `header` + `messages`).
--
-- What is asserted (lua/core/return_shapes.lua):
--   1. a declared MCP `outputSchema` renders, with the same `data` unwrap the script sees, and is
--      printed after the arguments in the index;
--   2. a shape is LEARNED where a nested script call settles (codemode `settle_call`, after
--      `script_value`): keys and types only - no value is ever stored, and data-like keys (an e-mail
--      address, more than 12 keys) collapse to `{…}`;
--   3. a long shape is capped at about 120 characters;
--   4. an unchanged answer (or one with an empty list / a missing field) changes nothing: the stored
--      row and the index are byte-identical, so the prompt does not churn; a new key is added once;
--   5. a pending handle is not a shape, and a changed argument schema starts afresh;
--   6. our WhatsApp read has its static shape; a connector with no shape yet keeps the plain line.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local policy=dofile('lua/core/codemode_policy.lua')
local shapes=dofile('lua/core/return_shapes.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end

-- 1. Declared.
local declared={type='object',properties={
 data={type='object',properties={
  messages={type='array',items={type='object',properties={id={type='string'},subject={type='string'},
   from={type='object',properties={name={type='string'},address={type='string'}}}}}},
  total={type='integer'}}},
 meta={type='object'}}}
check(shapes.render(shapes.from_schema(declared))=='{messages:[{from:{address,name},id,subject}],total}',
 'a declared outputSchema renders its data: '..tostring(shapes.render(shapes.from_schema(declared))))
check(shapes.render(shapes.from_schema({type={'object','null'},properties={ok={type='boolean'}}}))=='{ok}','a nullable object is its object')
local mail={type='function',['function']={name='mcp_mail_search_deadbeef',description='MCP mail / search: Search mail',
 parameters={type='object',properties={q={type='string'}},required={'q'}}}}
local fresh={type='function',['function']={name='mcp_mail_list_labels_deadbeef',description='MCP mail / list_labels: Labels',
 parameters={type='object',properties={}}}}
local real_dofile=dofile
local function with_declared(map,fn)
 dofile=function(path)
  if path=='lua/core/mcp.lua' then return {output_schemas=function() return map end} end
  return real_dofile(path)
 end
 local ok,value=pcall(fn);dofile=real_dofile
 assert(ok,value);return value
end
local index=with_declared({mcp_mail_search_deadbeef=declared},function() return policy.connector_index({mail,fresh}) end)
check(index:find('- mail: mcp_mail_list_labels_deadbeef({}); mcp_mail_search_deadbeef({q}) → {messages:[{from:{address,name},id,subject}],total}',1,true),
 'the declared shape is printed after the arguments, and a tool with no shape keeps its plain signature: '..index)
check(index:find('→ what the script receives, keys only',1,true),'the header says what the arrow means')
local plain=with_declared({},function() return policy.connector_index({fresh}) end)
check(plain:find('- mail: mcp_mail_list_labels_deadbeef({})\n',1,true) or plain:sub(-40):find('mcp_mail_list_labels_deadbeef({})',1,true),
 'no shape anywhere: the line is the signature alone: '..plain)
check(not plain:find('→',1,true),'and the header does not mention shapes: '..plain)

-- 2. Learned, from a real settled call.
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
local FAKE='mcp_mail_get_message_deadbeef'
local fake={type='function',['function']={name=FAKE,description='MCP mail / get_message: One message',
 parameters={type='object',properties={id={type='string'}},required={'id'}}}}
local sid=memory.start_session('','return shapes',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory);catalog[#catalog+1]=fake
local base_execution=tools.discovery_execution(memory,ctx)
local function execution(name) if name==FAKE then return base_execution('read') end return base_execution(name) end
local answer
local function dispatch(name,params,raw)
 if name==FAKE then return {ok=true,tool_call_issued=true,result={content={{type='text',text='{}'}},structuredContent={data=answer}}} end
 return tools.dispatch(memory,name,params,'master',ctx)
end
local function run(code)
 local result=codemode.run(memory,{code=code},'master',ctx,catalog,function()return catalog end,dispatch,execution)
 return result,result and result.value and json.decode(result.value) or nil
end
local function row()
 local rows=json.decode(host.sql_query('SELECT value FROM meta WHERE key=?',json.encode({shapes.KEY})))
 return rows[1] and rows[1].value or nil
end
answer={message={id='m-1',subject='TOPSECRET subject',from={name='Alice Example',address='alice@example.com'},labels={'INBOX-PRIVATE'}},
 by_sender={['alice@example.com']=3,['bob@example.com']=1},
 counts={k1=1,k2=2,k3=3,k4=4,k5=5,k6=6,k7=7,k8=8,k9=9,k10=10,k11=11,k12=12,k13=13},
 note='TOPSECRET value'}
local result,value=run('const r = await tools.'..FAKE..'({id:"m-1"});\nreturn r.message.id;')
check(result.ok and value=='m-1','the script read the answer it was given: '..json.encode(result):sub(1,300))
local stored=row()
check(stored and stored:find(FAKE,1,true),'the settled call recorded a shape: '..tostring(stored))
for _,secret in ipairs({'TOPSECRET','alice@example.com','bob@example.com','INBOX-PRIVATE','Alice','m-1','"k13"'}) do
 check(not stored:find(secret,1,true),'the stored shape carries no value and no data-like key ('..secret..'): '..stored)
end
local learned_line=policy.connector_index({fake})
local want='mcp_mail_get_message_deadbeef({id}) → {by_sender:{…},counts:{…},message:{from:{address,name},id,labels:[string],subject},note}'
check(learned_line:find(want,1,true),'the learned shape shows in the index, data-like maps collapsed: '..learned_line)

-- 4. No churn: the same answer, an empty list, a missing field - the row and the index stay the bytes they were.
local before_row,before_index=row(),policy.connector_index({fake})
run('return (await tools.'..FAKE..'({id:"m-1"})).note;')
check(row()==before_row and policy.connector_index({fake})==before_index,'an unchanged answer rewrites nothing')
check(shapes.learn(FAKE,fake['function'].parameters,{message={labels={}},note='x'})==false and row()==before_row,
 'an empty list and missing fields add nothing')
-- A new key is added once, then it is stable again.
answer.message.thread_id='t-9'
run('return (await tools.'..FAKE..'({id:"m-1"})).note;')
local grown=policy.connector_index({fake})
check(grown:find('message:{from:{address,name},id,labels:[string],subject,thread_id}',1,true),'a new key is added: '..grown)
local grown_row=row()
run('return (await tools.'..FAKE..'({id:"m-1"})).note;')
check(row()==grown_row,'and then nothing changes again')

-- 5. A pending handle is not a shape; a new argument schema starts afresh.
check(shapes.learn(FAKE,fake['function'].parameters,{state='pending',op='op-1'})==false and row()==grown_row,'a pending handle is not recorded')
local changed={type='function',['function']={name=FAKE,description=fake['function'].description,
 parameters={type='object',properties={id={type='string'},format={type='string'}},required={'id'}}}}
check(not policy.connector_index({changed}):find('→',1,true),'a changed argument schema does not show the old shape')
check(shapes.learn(FAKE,changed['function'].parameters,{raw='x'})==true and policy.connector_index({changed}):find('({id, format?}) → {raw}',1,true),
 'and learns its own: '..policy.connector_index({changed}))

-- 3. The cap.
local wide={}
for i=1,12 do wide['a_rather_long_field_'..i]={inner_value_one=1,inner_value_two={deeper=1}} end
local capped=shapes.render(shapes.tree(wide))
check(#capped<=shapes.CAP+3 and capped:sub(-4)=='…}','a wide shape is capped at about 120 characters: '..#capped..' '..capped)
check(shapes.render(shapes.tree({list={{a={b={c={d=1}}}}}}))=='{list:[{a:{b:{…}}}]}','three object levels at most (an array is not one): '..shapes.render(shapes.tree({list={{a={b={c={d=1}}}}}})))
check(shapes.render(shapes.tree('text'))=='string' and shapes.render(shapes.tree({1,2}))=='[number]','scalars and scalar arrays')

-- 6. Ours: the WhatsApp read has its static shape and it is not learned over.
local whatsapp=dofile('lua/core/whatsapp.lua')
local wa_index=policy.connector_index(whatsapp.schemas())
check(wa_index:find('- mcp_whatsapp_read({chat, limit?, before?}) → {header:{chat,name,type},messages:[{id,at_local,from:{own,name},text,reply_to:{id,quote}}],has_more,next_before}',1,true),
 'the WhatsApp read line carries its shape: '..wa_index)
for _,tool in ipairs(whatsapp.TOOLS) do
 check(tool.returns==nil or #tool.returns<=shapes.CAP,'a static shape stays within the cap: '..tool.name)
end
check(shapes.learn('mcp_whatsapp_read',whatsapp.tool('mcp_whatsapp_read').parameters,{x=1})==false,'a static shape is never learned over')
-- Deterministic: the same catalogue and store give the same bytes.
check(policy.connector_index(whatsapp.schemas())==wa_index,'the index is deterministic')
print(json.encode({ok=true,checks=checks}))
