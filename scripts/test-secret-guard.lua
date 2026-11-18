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
-- 18/11: two more kinds of path are not the agent's to write. The node's own store `memory.db` (and its
-- -wal/-shm) holds the MCP registry, so a sqlite3 write set a connector's approval by hand; and the
-- connector SCRIPT directories hold the code an approved connector runs, so a rewritten
-- <scripts>/mcp-client.mjs replaced the program behind an approval.
for _, c in ipairs({
  {'bash', {command='sqlite3 ~/.wasm-agent/memory.db "update meta set value=1"'}},
  {'bash', {command='sqlite3 $HOME/.wasm-agent/memory.db-wal .dump'}},
  {'read', {path='~/.wasm-agent/memory.db'}},
  {'write', {path='~/.wasm-agent/memory.db-shm', content='x'}},
  {'write', {path='~/.wasm-agent/scripts/mcp-client.mjs', content='x'}},
  {'edit', {path='~/.local/bin/scripts/mcp-client.mjs'}},
  {'ls', {path='~/.local/bin/scripts'}},
}) do
  local r = call(c[1], c[2])
  check(r.error == 'secret_path_denied' and r.root ~= nil,
    'refused: ' .. c[1] .. ' ' .. json.encode(c[2]) .. ' -> ' .. json.encode(r))
end
-- The node's data directory is RESOLVED at load, not assumed: a node whose store lives elsewhere is
-- covered by the same rule.
-- 19/11: the request and seed files a launch is spawned from decide WHICH program gets the vault
-- values, so they are a root of the same kind as the store and the scripts.
for _, c in ipairs({
  {'read', {path = '~/.wasm-agent/mcp/'..'requests/r1.json'}},
  {'bash', {command = 'cat ~/.wasm-agent/mcp/'..'requests/r1.json'}},
  {'write', {path = data .. '/mcp/'..'requests/r1.seed.json', content = 'x'}},
}) do
  local r = call(c[1], c[2])
  check(r.error == 'secret_path_denied' and r.root ~= nil,
    'refused: ' .. c[1] .. ' ' .. json.encode(c[2]) .. ' -> ' .. json.encode(r))
end
-- Each root is refused with the reason it is a root: the credentials sentence is the truth about a key
-- file and the wrong fact about the store, a script directory or a launch request.
local function note(kind, args)
  local r = call(kind, args)
  check(r.error == 'secret_path_denied' and type(r.note) == 'string', 'refused with a note: ' .. kind)
  return r.note
end
local store_note = note('read', {path = '~/.wasm-agent/memory.db'})
local code_note = note('write', {path = '~/.wasm-agent/scripts/mcp-client.mjs', content = 'x'})
local request_note = note('read', {path = '~/.wasm-agent/mcp/'..'requests/r1.json'})
check(store_note ~= sg.NOTE and store_note:find('store') ~= nil, 'the node store has its own note: ' .. store_note)
check(code_note ~= sg.NOTE and code_note:find('code') ~= nil, 'the connector code has its own note: ' .. code_note)
check(request_note ~= sg.NOTE and request_note:find('launch') ~= nil,
  'and the launch request its own: ' .. request_note)
check(sg.NOTE:find('credentials are reachable only through their connectors', 1, true) ~= nil,
  'the credentials note itself is unchanged')

local data = dofile('lua/core/paths.lua').data()
check(sg.check('write', {path = data .. '/memory.db'}) ~= nil, 'the resolved data directory is covered: ' .. data)
check(sg.check('read', {path = data .. '/scripts/mcp-client.mjs'}) ~= nil, 'and its script directory')
check(sg.check('write', {path = '/tmp/an-ordinary-note.txt', content='x'}) == nil,
  'an ordinary file outside every root is still allowed')

print(json.encode({ok=true,checks=checks}))
