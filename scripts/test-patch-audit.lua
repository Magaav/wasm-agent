-- The patch audit must anchor changed lines and never turn leads into a safety verdict.
local json = dofile("lua/vendor/json.lua")
local changeset = dofile("lua/core/changeset.lua")
local audit = dofile("lua/core/patch_audit.lua")
local paths = dofile("lua/core/paths.lua")
local path = paths.temp() .. "/wa-patch-audit-" .. tostring(host.now()) .. ".lua"
local before = "function M.one()\n  return 1\nend\nfunction M.two()\n  return 2\nend\n"
local after = "function M.one()\n  return 3\nend\nfunction M.two()\n  return 2\nend\n"
assert(host.write_file(path, after))
local changes = changeset.new()
changeset.record(changes, path, before, after)
local lines = assert(changeset.changed_lines(changes.files[1]))
assert(#lines == 1 and lines[1] == 2, json.encode(lines))

local received
local native_audit = host.graph_patch_audit
host.graph_patch_audit = function(raw)
  received=json.decode(raw)
  return json.encode({verdict="leads",lead_count=1,mapped_lines=1,changed_lines=1,
    leads={{path="caller.lua",line=7}},gaps={}})
end
local result = audit.run(changes,{[path]=true},{session_id="patch-audit-test",run_id="patch-audit-run"})
assert(result.worthy == "unproven")
assert(result.lead_count == 1)
assert(received.changes[1].lines[1] == 2)
assert(received.reviewed[1] == path)
local before_feedback = audit.report(48)
assert(before_feedback.audits >= 1 and before_feedback.worthy == "unproven")
assert(before_feedback.examples[1].session_id == "patch-audit-test")
assert(audit.feedback("missing-run","confirmed_catch").error == "run_has_no_graph_lead")
assert(audit.feedback("patch-audit-run","confirmed_catch",nil,
  {session_id="patch-audit-test"}).ok)
local after_feedback = audit.report(48)
assert(after_feedback.confirmed_catches == 1 and after_feedback.worthy == "confirmed_catch")

assert(host.write_file(path, after .. "-- later\n"))
local stale, reason = changeset.changed_lines(changes.files[1])
assert(stale == nil and reason == "file_changed_since_record")

host.graph_patch_audit = native_audit
local root = paths.temp() .. "/wa-patch-audit-native-" .. tostring(host.now())
assert(host.write_file(root .. "/source.lua",
  "function M.changed()\n  return 2\nend\n"))
assert(host.write_file(root .. "/caller.lua",
  "local M = require('source')\nfunction use_changed() return M.changed() end\n"))
local native = json.decode(host.graph_patch_audit(json.encode({root=root,
  db=root .. "/graph.db",changes={{path="source.lua",lines={2}}},reviewed={}})))
assert(not native.error, tostring(native.error))
assert(native.lead_count == 1, json.encode(native))
assert(native.leads[1].path == "caller.lua")

-- A standard git commit receives the lead *before* the command runs, once per
-- patch fingerprint. A repeated attempt can acknowledge a false positive.
local original_exec, original_getenv, original_audit = host.exec, host.getenv, host.graph_patch_audit
local committed = 0
host.getenv = function(name)
  if name == "WA_GRAPH_PATCH_AUDIT" then return "1" end
  return original_getenv(name)
end
host.exec = function(command)
  if command:find("diff HEAD",1,true) then
    return json.encode({code=0,stdout="diff --git a/source.lua b/source.lua\n--- a/source.lua\n+++ b/source.lua\n@@ -1,3 +1,3 @@\n"})
  elseif command:find("ls-files",1,true) then
    return json.encode({code=0,stdout=""})
  end
  committed=committed+1
  return json.encode({code=0,stdout="committed"})
end
host.graph_patch_audit = function()
  return json.encode({verdict="leads",lead_count=1,mapped_lines=1,changed_lines=3,
    leads={{path="caller.lua",line=2}},gaps={}})
end
local tools = dofile("lua/core/tools.lua")
local context={commit_audits={},reviewed_paths={},session_id="patch-audit-test",run_id="precommit-run"}
local first=tools.dispatch({},"bash",{command="git commit -m test"},"master",context)
assert(first.error=="graph_patch_review_required" and committed==0)
local second=tools.dispatch({},"bash",{command="git commit -m test"},"master",context)
assert(second.code==0 and committed==1)
host.exec,host.getenv,host.graph_patch_audit=original_exec,original_getenv,original_audit
print("patch audit ok")
