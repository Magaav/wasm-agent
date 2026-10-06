-- Real registry/two private nodes, driven by scripts/test-peer-sync.cjs.
local json=dofile('lua/vendor/json.lua')
local mode=assert(host.getenv('WA_SYNC_FIXTURE_MODE'))
local nodes=dofile('lua/core/nodes.lua')
local original=dofile
dofile=function(p) if p=='lua/core/nodes.lua' then return nodes end return original(p) end
original('lua/core/server.lua');dofile=original
local memory=original('lua/core/memory.lua')
if mode=='receiver' then
  assert(#memory.recall('signed sync fact')==1)
  assert(#memory.recall('corrupt ack fact')==1)
  print('peer sync receiver ok (2 checks, 0 skipped)');return
end
local peer=assert(host.getenv('WASM_AGENT_SYNC_TO'))
memory.remember('signed sync fact','global')
local first=json.decode(wa_sync_tick());assert(first.ok and first.pushed>0)
local cursor=memory.cursor(peer);assert(cursor>0)
assert(json.decode(wa_sync_tick()).pushed==0)
memory.remember('corrupt ack fact','global')
local request=nodes.request
nodes.request=function(...)
  local r=request(...);assert(r.status==200)
  local envelope=json.decode(r.body);assert(envelope.reply_sig)
  envelope.reply='{"ok":true,"applied":99}';r.body=json.encode(envelope);return r
end
local rejected=json.decode(wa_sync_tick());assert(not rejected.ok and rejected.failed==1)
assert(memory.cursor(peer)==cursor,'forged ack must not advance cursor')
nodes.request=request
-- The first legitimate application happened despite the lost/altered ack. The replay
-- refusal leaves the sender cursor held for explicit reconciliation, never false success.
print('peer sync sender ok (5 checks, 0 skipped)')
