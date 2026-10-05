-- Private native Lua/SQLite route test; no transcript derivation may occur.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local users = dofile("lua/core/users.lua")
dofile("lua/core/server.lua")
local checks = 0
local function ok(value, label) checks=checks+1; assert(value, label) end
local sid = memory.start_session("local", "chat", {id="owner-private", user_id="guest"})
memory.append_turn(sid, {role="user", content=string.rep("large private transcript ", 10000)})
local other = memory.start_session("local", "chat", {id="foreign-private", user_id="master"})
-- Every server module instance uses this shared native capability. Reject transcript SQL,
-- not just a replaced Lua function that the server's separate module could bypass.
local query = host.sql_query
host.sql_query = function(sql, params)
  assert(not sql:lower():find("from messages", 1, true), "owner endpoint loaded transcript")
  assert(not sql:lower():find("select * from sessions", 1, true), "owner endpoint loaded stored summary")
  return query(sql, params)
end
local master = users.login("master")
local guest = users.login("guest")
local function view(token, id) return json.decode(wa_session_owner(id or sid, token)) end
local v = view(master)
ok(v.session.id==sid and v.session.user_id=="guest", "master reads exact owner")
ok(v.messages==nil and v.state==nil, "no transcript or derived state")
local fields=0; for _ in pairs(v.session) do fields=fields+1 end
ok(fields==2, "only id and user_id returned")
ok(#json.encode(v)<150, "bounded metadata regardless of transcript size")
ok(view(guest).session.user_id=="guest", "owner authorized")
ok(view(guest,other).error=="forbidden", "foreign owner refused")
ok(view(master,"missing-private").error=="unknown_session", "missing parent refused")
ok(view("invalid-private-token").error=="invalid_session", "invalid credential cannot fall back")
users.logout(guest)
ok(view(guest).error=="invalid_session", "revoked credential refused")
ok(view(nil).session.id==sid, "trusted local default preserved")
print("session owner ok ("..checks.." checks, 0 skipped)")
