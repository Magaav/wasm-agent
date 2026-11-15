-- The agent's tools refuse the secret roots; everything else is untouched (15/11).
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local sg=dofile('lua/core/secret_guard.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local ctx={user_id='master',role='master'}
local function call(name,args)return tools.dispatch(memory,name,args,'master',ctx)end
for _,c in ipairs({{'read',{path='~/.wasm-agent/secrets/mail-x.env'}},{'ls',{path='/home/agent/.wasm-agent/secrets'}},
  {'grep',{pattern='PASS',path='$HOME/.wasm-agent/secrets'}},{'bash',{command='cat ~/.wasm-agent/secrets/mail-x.env'}},
  {'bash',{command='python3 -c "open(\'/home/agent/.wasm-agent/secrets/x\')"'}},{'read',{path='~/.config/wasm-agent-sandbox/vault.env'}},
  {'write',{path='~/.wasm-agent/keys/a',content='x'}},{'bash',{command='ls',cwd='/home/agent/.wasm-agent/secrets'}}}) do
  local r=call(c[1],c[2])
  check(r.error=='secret_path_denied' and r.status==403 and r.effect=='none','refused: '..c[1]..' '..json.encode(c[2]))
end
check(sg.check('read',{path='/tmp/notes.txt'})==nil and sg.check('bash',{command='ls ~/.wasm-agent/tool-results'})==nil,'other paths stay allowed')
check(sg.check('read',{path='AGENTS.md'})==nil,'a relative project path stays allowed')
local inside=dofile('lua/core/codemode_policy.lua')
local sid=memory.start_session('','guard',{user_id='master'})
local cctx={session_id=sid,user_id='master'};inside.pin(memory,'master',cctx)
local r=tools.dispatch(memory,'codemode',{code='const r = await tools.read({path:"~/.wasm-agent/secrets/x"});\nreturn r;'},'master',cctx)
check(r.ok==false and tostring(r.error):find('secret_path_denied',1,true),'a script cannot read them either: '..json.encode(r):sub(1,200))
print(json.encode({ok=true,checks=checks}))
