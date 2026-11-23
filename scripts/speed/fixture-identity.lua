-- The node identity of whatever home this runs in, for the remote-round-trip fixture.
--
--   WASM_AGENT_HOME=<scratch> WASM_AGENT_LUA_ROOT=<tree> WA_SCRIPT=scripts/speed/fixture-identity.lua wa
--
-- The fixture needs both node ids BEFORE the rendezvous starts, because a local rendezvous makes a master
-- only of the ids its operator names (WASM_AGENT_NETWORK_ADMINS); with none, every node is a guest and a
-- guest may not call a peer (forbidden_role). One line, no ledger, no network.
local json = dofile('lua/vendor/json.lua')
print(json.encode({ node_id = (json.decode(host.node_identity()) or {}).node_id }))
