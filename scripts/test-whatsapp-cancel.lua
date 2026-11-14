-- A queued send can be cancelled, a resume asks the node that queued it, and a wait that ends with the
-- job never taken says so (14/11: a send sat `queued` for ever on a node with no sender).
local json=dofile('lua/vendor/json.lua')
local wa=dofile('lua/core/whatsapp.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local seen={}
local real_status=host.whatsapp_send_status
host.whatsapp_send_status=function(raw) local req=json.decode(raw);seen[#seen+1]={where='local',req=req}
 return json.encode({ok=true,id=req.id,state=req.cancel and 'dead' or 'queued',attempts=0,cancelled=req.cancel or nil,reason=req.cancel and 'cancelled: test' or nil}) end
local real_route,real_forward=wa.route,wa.forward
wa.forward=function(owner,name,req) seen[#seen+1]={where=owner,name=name,req=req}; return {ok=true,id=req.id,state='done',message_id='X',served_by=owner} end

wa.route=function() return nil end
local r=wa.send({cancel=7},{})
check(r.cancelled==true and seen[#seen].where=='local' and seen[#seen].req.cancel==true,'a holder of the account cancels on its own queue: '..json.encode(r))
check(wa.send({cancel=7,text='x'},{}).error=='whatsapp_send_bad_cancel','cancel is alone')

wa.route=function() return 'openclaw' end
r=wa.send({cancel=9},{})
check(seen[#seen].where=='openclaw' and seen[#seen].req.cancel==true and seen[#seen].name=='mcp_whatsapp_send_status','a node without the account cancels on the account node: '..json.encode(seen[#seen]))
r=wa.send({id=127,wait_s=0},{})
check(seen[#seen].where=='openclaw' and seen[#seen].req.id==127,'a resume asks the account node, not this queue: '..json.encode(seen[#seen]))

-- a job left in THIS node's queue (before sends were routed) is still reachable: the owner holds no
-- such id, so the resume and the cancel ask this node's own queue (job 7, 14/11)
wa.forward=function(owner,name,req) seen[#seen+1]={where=owner,name=name,req=req}; return {ok=false,error='whatsapp_send_unknown_id',id=req.id} end
r=wa.send({id=7,wait_s=0},{})
check(r.served_by==wa.self_name() and r.state~=nil and r.error==nil,'a resume falls back to this node for a local job: '..json.encode(r))
r=wa.send({cancel=7},{})
check(r.cancelled==true,'a cancel falls back to this node for a local job: '..json.encode(r))
wa.forward=function(owner,name,req) seen[#seen+1]={where=owner,name=name,req=req}; return {ok=true,id=req.id,state='done',message_id='X',served_by=owner} end
r=wa.send({id=127,wait_s=0},{})
check(r.status==200 and r.message_id=='X','a sent message answers status 200 and its message_id: '..json.encode(r))

-- the stuck hint
local clock=0;local real_now=host.now;host.now=function() return clock end
local answer=wa.settle(5,30,function() return {ok=true,id=5,state='queued',attempts=0} end,{sleep=function(s) clock=clock+s;return true end})
host.now=real_now
check(answer.state=='pending' and tostring(answer.stuck):find('cancel: 5',1,true) and tostring(answer.stuck):find('twice',1,true),'a send never taken says so and how to stop it: '..json.encode(answer))
host.whatsapp_send_status=real_status;wa.route=real_route;wa.forward=real_forward
print(json.encode({ok=true,checks=checks}))
