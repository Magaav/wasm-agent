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

-- ONE TEXT, ONE FRAME (mission project-instructions-once, 23/11). The walk above is right for a
-- monorepo and wrong for the shapes that copy one file into two ancestors: a worktree placed inside its
-- parent checkout, a copied tree, a symlink. Before the change both copies were injected - measured on
-- this node, a 27,540-byte prompt carried two byte-identical 6,924-byte copies. Now a file whose content
-- is byte-identical to one already read is carried once, the copy nearest the workdir is the one kept,
-- and the skipped path is named in the frame's attribute (never in prose the model reads).
local same_root, same_work = base .. "/dup/repo", base .. "/dup/repo/pkg/app"
sh("mkdir -p '" .. same_work .. "'")
assert(host.write_file(same_root .. "/AGENTS.md", "# Same rules\nSAME_TEXT\n"))
assert(host.write_file(same_work .. "/AGENTS.md", "# Same rules\nSAME_TEXT\n"))
local same_text = agent.project_instructions("master", same_work)
local copies, kept = 0, nil
for _, file in ipairs(same_text) do
  if file.text:find("SAME_TEXT", 1, true) then copies = copies + 1; kept = file end
end
ok(copies == 1, "two byte-identical ancestor files are one frame, got " .. copies)
ok(kept and kept.path == same_work .. "/AGENTS.md", "the copy nearest the workdir is the one kept")
ok(kept and table.concat(kept.same_text_as or {}, ",") == same_root .. "/AGENTS.md",
  "the skipped path is named on the kept file")
local same_sections = agent.system_sections("master", same_text, same_text[#same_text].path, {}, "full", { workdir = same_work })
ok(select(2, same_sections.project:gsub("<project_instructions ", "")) == #same_text, "one frame per kept file")
ok(same_sections.project:find('<project_instructions path="' .. same_work .. '/AGENTS.md" same_text_as="'
  .. same_root .. '/AGENTS.md">', 1, true), "the skipped path rides the frame attribute the model reads")
ok(select(2, same_sections.project:gsub("SAME_TEXT", "")) == 1, "the same text reaches the prompt once")

-- Two DIFFERENT files at the same depths are both kept, root-first: the rule is about bytes, not depth.
ok(select(2, sections.project:gsub("OUTER_KEEP", "")) == 1 and select(2, sections.project:gsub("INNER_KEEP", "")) == 1,
  "two different files are both carried, once each")

-- Two paths that resolve to one real file (a symlink) are one frame too: the loader compares what it
-- read, so it does not need the paths to look alike.
local link_root = base .. "/link"
sh("mkdir -p '" .. link_root .. "/pkg'")
assert(host.write_file(link_root .. "/AGENTS.md", "# Linked\nLINK_TEXT\n"))
sh("ln -s '../AGENTS.md' '" .. link_root .. "/pkg/AGENTS.md'")
local linked = 0
for _, file in ipairs(agent.project_instructions("master", link_root .. "/pkg")) do
  if file.text:find("LINK_TEXT", 1, true) then linked = linked + 1 end
end
ok(linked == 1, "a symlinked instruction file is read once, got " .. linked)

-- A git worktree placed INSIDE its parent checkout: the worktree carries the same AGENTS.md as the repo
-- above it, which is the shape measured on this node (checkout/ inside wasm-agent/).
local parent = base .. "/parent"
sh("mkdir -p '" .. parent .. "' && cd '" .. parent .. "' && git init -q ."
  .. " && printf '# Rules\nWT_TEXT\n' > AGENTS.md && git add -A"
  .. " && git -c user.email=t@example.invalid -c user.name=t commit -qm init"
  .. " && git worktree add -q '" .. parent .. "/wt' HEAD")
local in_worktree = agent.project_instructions("master", parent .. "/wt")
local wt_copies, wt_kept = 0, nil
for _, file in ipairs(in_worktree) do
  if file.text:find("WT_TEXT", 1, true) then wt_copies = wt_copies + 1; wt_kept = file end
end
ok(wt_copies == 1, "a worktree inside its parent checkout reads one copy, got " .. wt_copies)
ok(wt_kept and wt_kept.path == parent .. "/wt/AGENTS.md", "the worktree's own file is the one kept")
ok(wt_kept and table.concat(wt_kept.same_text_as or {}, ",") == parent .. "/AGENTS.md",
  "the parent checkout's copy is named as the skipped one")

sh("rm -rf '" .. base .. "'")
print("project instructions ok (" .. checks .. " checks, 0 skipped)")
