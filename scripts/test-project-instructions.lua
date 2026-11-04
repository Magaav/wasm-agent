-- Project instructions follow the work, pi-style: <config>/AGENTS.md, then every AGENTS.md from the
-- filesystem root down to the session's workdir (nearest last). A session bound to a worktree reads
-- that worktree's files; a guest reads AGENTS.guest.md only; a config snapshot of a project file is
-- not injected twice.
local memory = dofile("lua/core/memory.lua"); memory.setup()
local agent = dofile("lua/core/agent.lua")
local paths = dofile("lua/core/paths.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function sh(command) local r = host.exec(command, "", 30); return r end

local base = (host.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/wa-project-instructions-" .. host.uuid()
local outer, inner = base .. "/repo", base .. "/repo/pkg/app"
sh("mkdir -p '" .. inner .. "'")
assert(host.write_file(outer .. "/AGENTS.md", "# Outer rules\nOUTER_KEEP\n"))
assert(host.write_file(inner .. "/AGENTS.md", "# Inner rules\nINNER_KEEP\n"))

local files = agent.project_instructions("master", inner)
local order = {}
for _, file in ipairs(files) do
  if file.text:find("OUTER_KEEP", 1, true) then order[#order + 1] = "outer" end
  if file.text:find("INNER_KEEP", 1, true) then order[#order + 1] = "inner" end
end
ok(table.concat(order, ",") == "outer,inner", "walk-up reads root-first, nearest last: " .. table.concat(order, ","))
ok(files[#files].path == inner .. "/AGENTS.md", "nearest file is last and named by its path")

local sections = agent.system_sections("master", files, files[#files].path, {}, "full", { workdir = inner })
ok(select(2, sections.project:gsub("<project_instructions ", "")) == #files, "one frame per file")
ok(sections.session:find('<workdir path="' .. inner .. '"/>', 1, true), "session names the real workdir")

-- A session bound to its own worktree reads that tree, not the node checkout.
local sid = memory.start_session("", "worktree", { user_id = "master" })
memory.set_session_worktree(sid, inner)
ok(agent.workdir(sid) == inner, "bound session works in its worktree")
local unbound = memory.start_session("", "plain", { user_id = "master" })
ok(agent.workdir(unbound) == dofile("lua/core/platform.lua").cwd(), "unbound session uses the node cwd")

-- A guest never reads operator files, wherever it works.
for _, file in ipairs(agent.project_instructions("guest", inner)) do
  ok(not file.text:find("INNER_KEEP", 1, true) and not file.text:find("OUTER_KEEP", 1, true), "guest never reads operator files")
end

-- The global file is the user's own: injected first, as is, whatever its title (installers no
-- longer seed it; scripts/test-seeded-agents-md.sh covers retiring an old seed).
local config = paths.config()
sh("mkdir -p '" .. config .. "'")
local global_path = config .. "/AGENTS.md"
local had = host.read_file(global_path)
assert(host.write_file(global_path, "# Global rules\nGLOBAL_KEEP\n"))
local with_global = agent.project_instructions("master", inner)
ok(with_global[1].text:find("GLOBAL_KEEP", 1, true), "global file comes first")
assert(host.write_file(global_path, "# Inner rules\nSAME_TITLE_GLOBAL\n"))
local same_title = agent.project_instructions("master", inner)
ok(same_title[1].path == global_path and same_title[1].text:find("SAME_TITLE_GLOBAL", 1, true),
  "a global file sharing a project file's title is still the user's and is injected first")
if had then host.write_file(global_path, had) else sh("rm -f '" .. global_path .. "'") end

sh("rm -rf '" .. base .. "'")
print("project instructions ok (" .. checks .. " checks, 0 skipped)")
