-- The settlement evaluation packet, and who is woken at all.
--
-- Every claim here is about what a coordinator is handed when a child settles: the packet must carry
-- the artifact facts of a REAL git worktree (branch, pushed, head against origin/main, dirty and
-- untracked counts), a failure must be classified as a recovery decision, a child whose own profile
-- recorded its decision must be skipped WITH its reason written down, an interrupted wake must stay
-- `unknown` and never be replayed, and a skipped settlement must dispatch no model turn.
--
-- No model, no provider, no network: `host.enqueue_completion` is stubbed so the decisions are
-- counted, and the real scheduler path is exercised separately by scripts/test-completion-wake.cjs.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local paths=dofile('lua/core/paths.lua')
local platform=dofile('lua/core/platform.lua')
local workspaces=dofile('lua/core/workspaces.lua')
local subagents=dofile('lua/core/subagents.lua')
local completions=dofile('lua/core/completions.lua')
local checks=0
local function check(value,label)
  checks=checks+1
  if not value then error(label,2) end
end
local function check_eq(actual,expected,label)
  checks=checks+1
  if actual~=expected then
    error(label..': expected '..tostring(expected)..', got '..tostring(actual),2)
  end
end

-- The fixture repository is built here, inside this run's own home, so the artifact facts are read
-- from a real checkout instead of a table written by the test.
local function quote(value)
  value=tostring(value or "")
  local shell=tostring(platform.shell_name() or ""):lower()
  if shell:find("cmd",1,true) then return '"'..value:gsub("/","\\")..'"' end
  if shell:find("powershell",1,true) then return "'"..value:gsub("'","''").."'" end
  return "'"..value:gsub("'","'\\''").."'"
end
local function git_raw(args,cwd)
  local ok,raw=pcall(host.exec,'git '..args,cwd or "",120)
  check(ok and type(raw)=="string","git is runnable through host.exec: "..tostring(raw))
  return json.decode(raw)
end
local function git(args,cwd,label)
  local result=git_raw(args,cwd)
  if tonumber(result.code)~=0 then
    error((label or ('git '..args))..' exited '..tostring(result.code)..': '
      ..tostring(result.stderr or result.stdout),2)
  end
  return result
end

local root=paths.data().."/completion-packet"
local source=root.."/source"
local origin=root.."/origin.git"
git("init "..quote(source))
git("init --bare "..quote(origin))
git("config user.name completion-packet-fixture",source)
git("config user.email completion-packet-fixture@invalid",source)
-- The fixture's own line endings are stated, never inherited: this machine's global autocrlf is true,
-- which would rewrite every checked-out file and make a tracked file read as modified forever.
git("config core.autocrlf false",source)
host.write_file(source.."/seed.txt","clean baseline\n")
git("add seed.txt",source)
git("commit --allow-empty -m baseline",source)
git("branch -M main",source)
if tonumber(git_raw("remote add origin "..quote(origin),source).code)~=0 then
  git("remote set-url origin "..quote(origin),source)
end
git("push -u origin main",source)
git("fetch origin",source)

local parent=memory.start_session("local","packet-parent",{id="packet-parent",user_id="master",node_id="test-node",title="packet parent"})
memory.set_session_worktree(parent,source)
local child=memory.start_session("local","subagent",{id="packet-child",user_id="master",node_id="test-node",parent_session_id=parent,workspace_required=true})
local workspace,ensure_error=workspaces.ensure(memory,child,parent)
check(workspace~=nil,"a real worktree is allocated for the child session: "..tostring(ensure_error))
check(workspace.state=="allocated" and host.read_file(workspace.worktree.."/seed.txt")=="clean baseline\n",
  "the child's checkout is its own worktree at the source's clean HEAD")
local responder_session=memory.start_session("local","subagent",{id="packet-responder-session",user_id="master",node_id="test-node",parent_session_id=parent})
local ctx={user_id="master",role="master",session_id=parent}

-- The status view the runtime hands back for a settled child: what served it, what the provider said
-- it cost, and how long it ran. The usage block is the measured shape from this node (a partly
-- unmeasured run: 53 calls, two of them with nothing reported).
local function usage_view()
  return {available=false,partial=true,reason="some_calls_unmeasured",source="harness_events",
    calls=53,unmeasured_calls=2,prompt=3500000,completion=1200,total_tokens=3501200,
    cache_known=false,cost_known=true,cost_usd=0.42}
end
local function view(id,session_id,profile,extra)
  local status={subagent_id=id,state="completed",settled=true,session_id=session_id,profile=profile,
    model="fixture-model",reasoning="provider",started_at=1700000000,settled_at=1700000042.5,
    accounting={provider="fixture-provider",model="fixture-model",usage=usage_view()}}
  for key,value in pairs(extra or {}) do status[key]=value end
  return status
end

local statuses={}
local function tick()
  completions.tick({settlement=subagents.settlement,control=function(args,caller)
    check(caller.session_id==parent,"the child's status is asked for in its parent's session context")
    return statuses[args.id] or {error="unknown_subagent"}
  end})
end
local deliveries={}
local refused=false
host.enqueue_completion=function(raw)
  local payload=json.decode(raw)
  deliveries[#deliveries+1]=payload
  if refused then return json.encode({error="background_queue_full",not_started=true}) end
  return json.encode({accepted=true,run_id=1000+#deliveries})
end

-- 1. A completed delivery with a real checkout: the packet carries the artifact facts.
completions.watch("packet-child",ctx)
statuses["packet-child"]=view("packet-child",child,"explore")
tick()
local row=completions.status("packet-child","master")
check_eq(row.state,"accepted","a settled delivery is claimed once and dispatched")
check_eq(#deliveries,1,"a completed delivery wakes a coordinator judgement")
local packet=json.decode(row.packet)
check_eq(packet.child.id,"packet-child","the packet names the child")
check_eq(packet.child.profile,"explore","the packet names the profile")
check_eq(packet.child.state,"completed","the packet carries the reported state")
check_eq(packet.child.model,"fixture-model","the packet carries the requested model")
check_eq(packet.child.served_model,"fixture-model","the packet carries the model the provider answered with")
check_eq(packet.child.provider,"fixture-provider","the packet carries the provider that served it")
check_eq(packet.session.id,child,"the packet names the child's session")
check_eq(packet.session.parent,parent,"the packet names the coordinator session")
check_eq(packet.session.duration_s,42.5,"the packet carries the measured duration")
check_eq(packet.usage.calls,53,"the packet carries the measured call count")
check_eq(packet.usage.unmeasured_calls,2,"the packet keeps the unmeasured calls unmeasured")
check_eq(packet.usage.prompt,3500000,"the packet carries the provider's prompt tokens")
check_eq(packet.usage.cost_usd,0.42,"the packet carries the provider's cost")
check_eq(packet.artifacts.worktree,workspace.worktree,"the packet names the session's worktree path")
check_eq(packet.artifacts.branch,workspace.branch,"the packet names the worktree's branch")
check_eq(packet.artifacts.pushed,false,"a branch nobody published is reported as not pushed")
check_eq(packet.artifacts.ahead,0,"a fresh worktree stands on origin/main")
check_eq(packet.artifacts.behind,0,"a fresh worktree is not behind origin/main")
check_eq(packet.artifacts.dirty,0,"a fresh worktree has nothing modified")
check_eq(packet.artifacts.untracked,0,"a fresh worktree has nothing untracked")
check(packet.artifacts.head~=nil and #packet.artifacts.head==40,"the packet carries the checkout's head")
check_eq(packet.review.needs_wake,true,"the delivery still needs judgement")
check_eq(packet.review.kind,"evaluation","a completed delivery is an evaluation")
check_eq(deliveries[1].packet,row.packet,"the packet travels with the wake, not behind a fetch")
check_eq(deliveries[1].id,"packet-child","the wake names the child it is about")
tick()
check_eq(#deliveries,1,"an accepted wake is never dispatched twice")
print("packet: "..row.packet)

-- 2. Work left in the checkout: a commit nobody pushed, plus uncommitted and untracked files. The
-- same session settling under a different child id is how a follow-up arrival is modelled.
host.write_file(workspace.worktree.."/work.txt","child work\n")
git("add work.txt",workspace.worktree)
git("-c user.name=fixture -c user.email=fixture@invalid commit -m child-work",workspace.worktree)
host.write_file(workspace.worktree.."/work.txt","child work, edited\n")
host.write_file(workspace.worktree.."/untracked.txt","half a thought\n")
completions.watch("packet-child-2",ctx)
statuses["packet-child-2"]=view("packet-child-2",child,"explore",{settled_at=1700000120.0})
tick()
packet=json.decode(completions.status("packet-child-2","master").packet)
check_eq(packet.artifacts.ahead,1,"a commit origin/main does not have is counted")
check_eq(packet.artifacts.pushed,false,"an unpushed commit leaves the branch unpushed")
check_eq(packet.artifacts.dirty,1,"a modified tracked file is counted")
check_eq(packet.artifacts.untracked,1,"an untracked file is counted")
check_eq(packet.review.needs_wake,true,"unfinished work still needs judgement")

-- 3. The same checkout published: the branch is pushed and the tree is clean, and the commit is
-- still absent from origin/main - the distinction a reviewer decides on.
git("push -u origin "..workspace.branch,workspace.worktree)
git("fetch origin",workspace.worktree)
git("checkout -- work.txt",workspace.worktree)
check(os.remove(workspace.worktree.."/untracked.txt"),"fixture cleanup removes the untracked file")
completions.watch("packet-child-3",ctx)
statuses["packet-child-3"]=view("packet-child-3",child,"explore",{settled_at=1700000200.0})
tick()
packet=json.decode(completions.status("packet-child-3","master").packet)
check_eq(packet.artifacts.pushed,true,"a published branch is reported as pushed")
check_eq(packet.artifacts.ahead,1,"a pushed branch can still be ahead of origin/main")
check_eq(packet.artifacts.dirty,0,"a clean checkout reports nothing modified")
check_eq(packet.artifacts.untracked,0,"a clean checkout reports nothing untracked")

-- 4. A child whose own profile decided: no worktree, nothing to review, no model turn - and the
-- reason is written down where a reader will find it.
check_eq(subagents.settlement("whatsapp-responder"),"self_reported","the scoped responder profile reports its own settlement")
check_eq(subagents.settlement("explore"),"coordinator","a read-only investigator still answers to its coordinator")
completions.watch("responder-child",ctx)
statuses["responder-child"]=view("responder-child",responder_session,"whatsapp-responder")
local before=#deliveries
tick()
row=completions.status("responder-child","master")
check_eq(row.state,"skipped","a self-reported settlement is skipped")
check(row.detail:find("profile_self_reported:whatsapp-responder",1,true)~=nil,
  "the skip records which profile decided: "..tostring(row.detail))
check_eq(#deliveries,before,"a skipped settlement dispatches no model turn")
packet=json.decode(row.packet)
check_eq(packet.review.needs_wake,false,"the skipped packet says no judgement is owed")
check_eq(packet.review.kind,"none","the skipped packet names the kind of judgement as none")
check_eq(packet.artifacts.managed,false,"a session with no worktree says so instead of reporting zero changes")
tick()
check_eq(#deliveries,before,"a skipped settlement is not dispatched on a later tick")

-- 5. A failure needs a recovery decision, whatever the profile says.
completions.watch("failed-child",ctx)
statuses["failed-child"]=view("failed-child",child,"whatsapp-responder",
  {state="failed",error="runaway_guard",settled_at=1700000300.0})
tick()
row=completions.status("failed-child","master")
check_eq(row.state,"accepted","a failed child wakes its coordinator")
packet=json.decode(row.packet)
check_eq(packet.review.kind,"recovery","a failure is classified as a recovery decision")
check(packet.review.reason:find("needs_recovery_decision",1,true)~=nil,
  "the failure's reason names the decision it needs: "..tostring(packet.review.reason))
check_eq(packet.child.error,"runaway_guard","the packet carries the child's error")

-- 6. Cancellation that won: the wake is recorded cancelled and never replayed.
completions.watch("cancelled-wake",ctx)
statuses["cancelled-wake"]=view("cancelled-wake",child,"explore",{settled_at=1700000400.0})
tick()
row=completions.status("cancelled-wake","master")
check_eq(row.state,"accepted","the wake is admitted before it can be cancelled")
local cancelled=json.decode(wa_completion_run(json.encode({id="cancelled-wake",owner="master",session_id=parent,cancelled=true})))
check_eq(cancelled.cancelled,true,"a cancelled wake reports cancellation")
row=completions.status("cancelled-wake","master")
check_eq(row.state,"cancelled","cancellation is recorded on the wake")
check(row.detail:find("cancelled",1,true)~=nil,"the cancellation says what it was")
before=#deliveries
tick()
check_eq(#deliveries,before,"a cancelled wake is never replayed")

-- 7. A child cancelled on request, with nothing left behind: skipped, with the reason recorded.
completions.watch("cancelled-child",ctx)
statuses["cancelled-child"]=view("cancelled-child",responder_session,"explore",
  {state="cancelled",settled_at=1700000500.0})
tick()
row=completions.status("cancelled-child","master")
check_eq(row.state,"skipped","a cancellation with nothing left to review is skipped")
check(row.detail:find("cancelled_by_request",1,true)~=nil,"the skip records why: "..tostring(row.detail))

-- 8. Promotion, not starvation. A wake that proved it never started goes back to `ready`, and a
-- page of unrelated watched children must not be able to hold it behind the scan cursor.
completions.watch("deferred-child",ctx)
statuses["deferred-child"]=view("deferred-child",child,"explore",{settled_at=1700000600.0})
refused=true
tick()
row=completions.status("deferred-child","master")
check_eq(row.state,"ready","a wake that provably never started can retry")
check(row.detail:find("wake not started: background_queue_full",1,true)~=nil,
  "the refused wake keeps the refusal beside the reported state: "..tostring(row.detail))
check(row.detail:find('"state":"completed"',1,true)~=nil,
  "the refused wake still carries the child's reported state: "..tostring(row.detail))
local deferred_rowid=tonumber(json.decode(host.sql_query(
  "SELECT rowid AS id FROM child_completions WHERE child_id='deferred-child'","[]"))[1].id)
for index=1,40 do
  local id="slow-"..index
  completions.watch(id,ctx)
  statuses[id]={subagent_id=id,state="running",settled=false,session_id=child,profile="explore"}
end
tick()
check_eq(completions.status("slow-40","master").state,"watching","an unfinished child stays watched")
local last_rowid=tonumber(json.decode(host.sql_query("SELECT max(rowid) AS id FROM child_completions","[]"))[1].id)
check(deferred_rowid<=32 and last_rowid>40,
  "the deferred wake's row sits behind a full page of unrelated watched children (rowid "
    ..deferred_rowid.." of "..last_rowid..")")
refused=false
before=#deliveries
tick()
check_eq(completions.status("deferred-child","master").state,"accepted",
  "a ready wake is claimed in its own pass instead of waiting for the scan cursor")
check_eq(#deliveries,before+1,"the promoted wake is dispatched exactly once")

-- 9. An interrupted wake stays ambiguous: `unknown`, no replay, and the row says what to do.
host.sql_exec("UPDATE child_completions SET boot='previous-boot' WHERE child_id='deferred-child'","[]")
before=#deliveries
tick()
row=completions.status("deferred-child","master")
check_eq(row.state,"unknown","a wake left by another boot is ambiguous, never presumed delivered")
check(row.detail:find("interrupted wake; inspect parent transcript before continuing",1,true)~=nil,
  "the ambiguous wake says what to inspect: "..tostring(row.detail))
tick()
check_eq(#deliveries,before,"an ambiguous wake is never replayed")

print("completion packet ok ("..checks.." checks; real worktrees, no model)")
