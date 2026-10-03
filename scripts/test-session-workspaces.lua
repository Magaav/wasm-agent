local json=dofile("lua/vendor/json.lua")
local memory=dofile("lua/core/memory.lua")
local tools=dofile("lua/core/tools.lua")
local workspaces=dofile("lua/core/workspaces.lua")
local checks=0
local function ok(value,label) checks=checks+1; if not value then error(label) end end
local function norm(path) return tostring(path or ""):gsub("\\","/"):gsub("/$",""):lower() end
memory.setup()
local source_path=host.getenv("WASM_AGENT_TEST_SOURCE")
ok(type(source_path)=="string" and source_path~="","test source repository required")
local source=memory.start_session("local","chat",{id="workspace-source",user_id="owner",node_id="test-node",title="source"})
memory.set_session_worktree(source,source_path)
-- Exercise the authenticated server fork entrypoint as well as the allocator seam.
dofile("lua/core/server.lua")
local http_source=memory.start_session("local","chat",{id="workspace-http-source",user_id="master",node_id="test-node",title="http source"})
memory.set_session_worktree(http_source,source_path)
memory.append_turn(http_source,{role="user",content="fork request"})
memory.append_turn(http_source,{role="assistant",content="fork answer"})
local http_fork=json.decode(wa_session_fork(json.encode({session_id=http_source,before_seq=2}),nil))
ok(http_fork.ok==true and memory.session_workspace(http_fork.session_id).state=="allocated","authenticated fork endpoint binds a new worktree")
memory.append_turn(source,{role="user",content="branch point"})
memory.append_turn(source,{role="assistant",content="answer"})
local fork=memory.fork_session(source,2,"owner")
local fork_workspace,fork_error=workspaces.ensure(memory,fork,source)
ok(fork_workspace and memory.session(fork).workspace_required==1,"conversational fork automatically receives isolated workspace: "..tostring(fork_error))
local a=memory.start_session("local","subagent",{id="workspace-a",user_id="owner",node_id="test-node",parent_session_id=source,workspace_required=true})
local b=memory.start_session("local","subagent",{id="workspace-b",user_id="owner",node_id="test-node",parent_session_id=source,workspace_required=true})
local wa,ea=workspaces.ensure(memory,a,source)
local wb,eb=workspaces.ensure(memory,b,source)
ok(wa and wb,"two automatic worktrees allocate: "..tostring(ea).." / "..tostring(eb))
ok(wa.worktree~=wb.worktree and wa.branch~=wb.branch,"sessions have independent paths and branches")
ok(wa.base_commit==wb.base_commit and wa.start_state.source_dirty==false,"starting git state is persisted at clean shared HEAD")
ok(fork_workspace.worktree~=wa.worktree,"fork and delegated coding session do not share a checkout")
ok(memory.session(a).workspace_required==1 and memory.session(a).workspace_state=="allocated","durable session binding")
local ca={session_id=a,user_id="owner",changes={files={}}}
local cb={session_id=b,user_id="owner",changes={files={}}}
local write_a=tools.dispatch(memory,"write",{path="same.txt",content="from-a"},"master",ca)
local write_b=tools.dispatch(memory,"write",{path="same.txt",content="from-b"},"master",cb)
ok(write_a.ok and write_b.ok,"both sessions write through their bound worktrees")
ok(host.read_file(wa.worktree.."/same.txt")=="from-a" and host.read_file(wb.worktree.."/same.txt")=="from-b","same relative path resolves to distinct contents")
local escaped=tools.dispatch(memory,"write",{path=source_path.."/not-allowed.txt",content="bad"},"master",ca)
ok(escaped.error=="workspace_path_outside_binding","absolute write outside the binding is refused")
local scratch=workspaces.scratch_root(a)
ok(scratch~=workspaces.scratch_root('workspace:a'), 'scratch identities do not collide')
local staged=tools.dispatch(memory,'write',{path=scratch..'/evidence.txt',content='before'},'master',ca)
ok(staged.ok and host.read_file(scratch..'/evidence.txt')=='before','own scratch write')
local edited=tools.dispatch(memory,'edit',{path=scratch..'/evidence.txt',edits={{old_text='before',new_text='after'}}},'master',ca)
ok(edited.ok and host.read_file(scratch..'/evidence.txt')=='after','own scratch edit')
for _,target in ipairs({workspaces.scratch_root(b)..'/bad.txt',scratch..'/../bad.txt',wb.worktree..'/bad.txt'}) do
 ok(tools.dispatch(memory,'write',{path=target,content='bad'},'master',ca).error=='workspace_path_outside_binding','scratch escape refuses '..target)
end
local original_canonical=host.canonical_path
local junction=json.decode(host.exec('MSYS2_ARG_CONV_EXCL="*" cmd.exe /c mklink /J "'..(scratch..'/junction'):gsub('/','\\')..'" "'..source_path:gsub('/','\\')..'"'))
assert(junction.code==0, 'real junction creation: '..json.encode(junction))
local actual=tools.dispatch(memory,'write',{path=scratch..'/junction/bad.txt',content='bad'},'master',ca)
ok(actual.error=='workspace_path_outside_binding','junction target outside scratch refuses: '..json.encode({result=actual,junction=junction,scratch=scratch,canonical=host.canonical_path(scratch..'/junction')}))
host.canonical_path=original_canonical
assert(not host.read_file(source_path..'/bad.txt'), 'real junction escaped write absent')
host.exec('MSYS2_ARG_CONV_EXCL="*" cmd.exe /c rmdir "'..(scratch..'/junction'):gsub('/','\\')..'"')
local staged_shell=tools.dispatch(memory,'bash',{command='echo staged',cwd=scratch},'master',ca)
ok(staged_shell.code==0,'scratch shell cwd')
local cwd_escape=tools.dispatch(memory,"bash",{command="echo bad",cwd=source_path},"master",ca)
ok(cwd_escape.error=="workspace_cwd_outside_binding","explicit shell cwd outside the binding is refused")
local unsupported=tools.dispatch(memory,"shell",{command="echo bad"},"master",ca)
ok(unsupported.error=="workspace_execution_context_unsupported","unbound desktop shell execution is refused")

local other=memory.start_session("local","chat",{id="workspace-other-owner",user_id="other",node_id="test-node"})
local denied,denial=workspaces.ensure(memory,other,source)
ok(not denied and denial=="workspace_owner_mismatch","cross-owner allocation is denied")

-- A dirty parent is not copied or ignored. The failed binding persists the exact policy/status,
-- and write-capable calls cannot fall back to the shared source checkout.
host.write_file(source_path.."/dirty-uncommitted.txt","must not be inherited\n")
local dirty=memory.start_session("local","subagent",{id="workspace-dirty",user_id="owner",node_id="test-node",parent_session_id=source,workspace_required=true})
local no_workspace,dirty_error=workspaces.ensure(memory,dirty,source)
local dirty_record=memory.session_workspace(dirty)
ok(not no_workspace and dirty_error:find("workspace_source_dirty",1,true)~=nil,"dirty source allocation fails visibly")
ok(dirty_record.required and dirty_record.state=="failed" and dirty_record.start_state.source_dirty==true and dirty_record.start_state.source_status:find("dirty%-uncommitted"),"dirty state and refusal policy persist")
local blocked=tools.dispatch(memory,"write",{path="blocked.txt",content="shared checkout must stay untouched"},"master",{session_id=dirty,user_id="owner",changes={}})
ok(blocked.error=="session_workspace_unavailable" and not host.read_file(source_path.."/blocked.txt"),"failed required binding never falls back to source cwd")
host.exec("git clean -fd",source_path)
local retried,retry_error=workspaces.ensure(memory,dirty,source)
ok(retried~=nil,"cleaned source permits explicit retry: "..tostring(retry_error))
local bad_source=memory.start_session("local","chat",{id="workspace-bad-source",user_id="owner",node_id="test-node"})
memory.set_session_worktree(bad_source,source_path.."/missing-repository")
-- A source path that names nothing on this machine is not a source: a path one machine's session
-- recorded says nothing about another machine (that is what a placed child arrives with), so the
-- child forks from this node's own checkout - here the tree `runtime-worktree.txt` records - and the
-- record says both what was asked for and why it was not used.
local relocated=memory.start_session("local","subagent",{id="workspace-unavailable",user_id="owner",node_id="test-node",parent_session_id=bad_source,workspace_required=true})
local relocated_ws,relocated_error=workspaces.ensure(memory,relocated,bad_source)
ok(relocated_ws and norm(relocated_ws.start_state.source_root)==norm(source_path)
  and relocated_ws.start_state.source_origin=="runtime-worktree.txt"
  and norm(relocated_ws.start_state.source_requested)==norm(source_path.."/missing-repository")
  and tostring(relocated_ws.start_state.source_fallback):find("workspace_source_path_missing",1,true)~=nil,
  "a source path that is gone falls back to this node's checkout and records why: "..tostring(relocated_error))
ok(tools.dispatch(memory,"write",{path="relocated.txt",content="here"},"master",{session_id=relocated,user_id="owner",changes={files={}}}).ok
  and host.read_file(source_path.."/relocated.txt")==nil,
  "the fallback checkout is bound, and the absent path the source named is never written through")

-- Cancelling/settling one child retains its own evidence and cannot detach the sibling.
memory.finish_session(a)
ok(memory.session_workspace(a).state=="allocated" and memory.session_workspace(b).state=="allocated","settling one child leaves both independent bindings durable")
local after=tools.dispatch(memory,"write",{path="after-cancel.txt",content="still alive"},"master",cb)
ok(after.ok,"sibling workspace remains writable after other session settles")

-- Owner-scoped manual worktree controls cannot inspect/redirect another principal's session.
local denied_tool=tools.dispatch(memory,"session_worktree",{action="status",session_id=a},"master",{session_id=other,user_id="other"})
ok(denied_tool.error=="forbidden","cross-owner worktree inspection/control is denied")
print("session workspaces ok ("..checks.." checks)")
