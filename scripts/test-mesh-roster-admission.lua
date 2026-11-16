-- The pins are one door and a verified roster is another. This proves the second one is reachable
-- from the CLI: measured 16/11 on `avell` (roster level 0, mesh mount up, health 200) which refused its
-- own outbound call with `not_peer_operator` before anything was sent, because `tools.lua` asked only
-- the registry pins. Docs/MESH.md §2 says the roster's hierarchy decides what executes once it
-- verifies; a client that never dials cannot be decided for.
--
-- No network, no rendezvous, no model: the transport is a counter.
local json=dofile('lua/vendor/json.lua')
local original_dofile=dofile
local nodes=dofile('lua/core/nodes.lua')
dofile=function(p) if p=='lua/core/nodes.lua' then return nodes end return original_dofile(p) end
local memory=original_dofile('lua/core/memory.lua');memory.setup()
local tools=original_dofile('lua/core/tools.lua')

local checks=0
local function check(v,why) assert(v,why);checks=checks+1 end
local function has(text,needle) return tostring(text):find(needle,1,true)~=nil end

local PEER=string.rep('4f',16)
local peer={node_id=PEER,name='openclaw',online=true,local_node=false,public_key=('ab'):rep(32)}
nodes.find=function(sel) if sel==PEER or sel=='openclaw' then return peer end return nil end

-- The registry says this node is not pinned in the peer's accepted binding.
nodes.operator_status=function() return {operator_of_peer=false,peer_binding='accepted',
  peer_operators={'work'},operator_basis='not_pinned'} end

local sent,last={},nil
nodes.remote_call=function(node_id,capability,args)
  sent[#sent+1]={node_id=node_id,capability=capability}
  if capability=='batch' then return {batch=1,results={{ok=true,via='stub'}}} end
  return {ok=true,via='stub',capability=capability}
end

-- 1. Mesh off: the old behaviour, byte for byte. A call costs nothing when the pins already refuse it.
nodes.mesh_enabled=function() return false end
local refused=tools.dispatch(memory,'remote',{node=PEER,capability='ls',args={path='/'}},'master')
check(type(refused)=='table' and refused.error=='not_peer_operator','mesh off -> the pins still refuse locally')
check(#sent==0,'mesh off -> nothing was sent to the peer')
check(has(refused.source,'nothing was sent'),'mesh off -> the refusal still says nothing was sent')

-- 2. Mesh on: the roster is the second door. The client tries, and the target's own admission answers.
nodes.mesh_enabled=function() return true end
local answered=tools.dispatch(memory,'remote',{node=PEER,capability='ls',args={path='/'}},'master')
check(#sent==1,'mesh on -> the call is attempted, not refused on the pins')
check(type(answered)=='table' and answered.ok==true and answered.via=='stub','mesh on -> the peer answer is returned')
check(sent[1].capability=='ls','mesh on -> the same capability travels')

-- 3. The batch path has the same rule, one line apart from the other, so it is proved separately.
sent={}
local batched=tools.dispatch(memory,'remote',{node=PEER,calls={{capability='ls',args={path='/'}}}},'master')
check(#sent==1 and type(batched)=='table' and not batched.error,'mesh on -> the batch path attempts too')
local refused_batch
nodes.mesh_enabled=function() return false end
sent={}
refused_batch=tools.dispatch(memory,'remote',{node=PEER,calls={{capability='ls',args={path='/'}}}},'master')
check(type(refused_batch)=='table' and refused_batch.error=='not_peer_operator' and #sent==0,
  'mesh off -> the batch path still refuses on the pins')

print(('mesh roster admission ok (%d checks)'):format(checks))
