local memory=dofile("lua/core/memory.lua")
local json=dofile("lua/vendor/json.lua")
memory.setup()
for id,expected in pairs({["workspace-a"]="concurrent-a",["workspace-b"]="concurrent-b"}) do
  local workspace=memory.session_workspace(id)
  assert(workspace and workspace.state=="allocated" and workspace.worktree~="","workspace binding did not survive process restart: "..id)
  assert(host.read_file(workspace.worktree.."/concurrent.txt")==expected,"restarted process resolved the wrong worktree: "..id)
end
print("session workspace restart ok (4 checks)")
