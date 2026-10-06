-- A guest reads and writes only its own memory scope; a master's default recall never shows a guest's text.
-- Run: WA_SCRIPT=tests/memory-guest-scope.lua wa (with a throwaway HOME).
local memory = dofile("lua/core/memory.lua")
local tools = dofile("lua/core/tools.lua")
memory.setup()
local master_id = tools.dispatch(memory, "remember", { content = "master secret codeword falcon" }, "master", { user_id = "victor" }).id
local g = tools.dispatch(memory, "remember", { content = "planted falcon instruction", scope = "global" }, "guest", { user_id = "g1" })
local master_rows = tools.dispatch(memory, "recall", { query = "falcon" }, "master", { user_id = "victor" })
local guest_rows = tools.dispatch(memory, "recall", { query = "falcon", scope = "global" }, "guest", { user_id = "g1" })
local guest_list = tools.dispatch(memory, "memories", { scope = "global" }, "guest", { user_id = "g1" })
local function scopes(rows) local t = {} for _, r in ipairs(rows) do t[#t+1] = r.scope .. ":" .. r.content:sub(1, 14) end return table.concat(t, ", ") end
print("GUEST_WROTE_TO", (memory.memories(nil, 10)[1] or {}).scope)
print("MASTER_SEES", scopes(master_rows))
print("GUEST_SEES", scopes(guest_rows))
print("GUEST_LIST", scopes(guest_list))
assert(not scopes(guest_rows):find("master secret"), "guest must not see master memory")
assert(not scopes(guest_list):find("master secret"), "guest list must not show master memory")
assert(not scopes(master_rows):find("planted"), "master default recall must not include guest text")
print("GUEST_SCOPE_OK")
