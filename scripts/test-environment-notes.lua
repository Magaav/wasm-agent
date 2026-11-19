-- Environment notes: which of \`AGENTS.<environment>.md\` a node is given, and that exactly one applies.
--
-- Hermetic by construction: every case injects the environment (a table), the filesystem (a reader
-- over a table) and the config directory (this test's own scratch dir). Nothing here reads the real
-- host, so the result does not depend on the machine the gate runs on - which is the point, because a
-- detection that can only be observed where it runs has not been tested. The scratch dir is created
-- under TMPDIR and the test refuses to run if it is not under it.
local memory = dofile("lua/core/memory.lua"); memory.setup()
local agent = dofile("lua/core/agent.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function sh(command) return host.exec(command, "", 30) end

local tmp_base = (host.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/wa-env-notes-"
local config_dir = tmp_base .. host.uuid()
ok(config_dir:sub(1, #tmp_base) == tmp_base, "the scratch config dir is under TMPDIR, never the real ~/.wasm-agent")
ok(config_dir ~= dofile("lua/core/paths.lua").config(), "the scratch config dir is not this node's config dir")
sh("mkdir -p '" .. config_dir .. "'")
ok(host.read_file(config_dir) == nil, "a directory is not readable as a file, so the fixture reader is the only source")

-- A reader over a table: a value is a file, \`DIR\` is a directory, absent is missing.
local DIR = {}
local function fs(files)
  return function(path)
    local value = files[path]
    if value == DIR then return nil, "read_file_is_a_directory:" .. path end
    if type(value) == "string" then return value end
    return nil, "read_file_missing:" .. path
  end
end

local both_notes = {
  ["AGENTS.sandbox.md"] = "SANDBOX_CWD\n",
  ["AGENTS.omarchy.md"] = "OMARCHY_CWD\n",
  [config_dir .. "/AGENTS.sandbox.md"] = "SANDBOX_CONFIG\n",
  [config_dir .. "/AGENTS.omarchy.md"] = "OMARCHY_CONFIG\n",
}
-- The note bodies are always present unless a case says otherwise: a probe file on its own tests the
-- detection, and a detection that selects a note that does not exist is a separate case below.
local function merged(files)
  local out = {}
  for path, value in pairs(both_notes) do out[path] = value end
  for path, value in pairs(files or {}) do out[path] = value end
  return out
end
local function note(role, env, files, exact)
  return agent.environment_note(role, { env = env, read = fs(exact and files or merged(files)), config_dir = config_dir })
end

-- Detection path 1: WASM_AGENT_SANDBOX=1.
local by_env = note("master", { WASM_AGENT_SANDBOX = "1" })
ok(by_env and by_env.path:match("AGENTS%.sandbox%.md$"), "WASM_AGENT_SANDBOX=1 selects AGENTS.sandbox.md")
ok(by_env.text == "SANDBOX_CWD\n", "the nearest sandbox note is the one read")

-- Detection path 2: /.dockerenv, when the variable is absent. Docker creates it EMPTY, so the fixture
-- is "" and not "x": with "x" this case passed while the real file did not (review r1, MUST 2).
local by_file = note("master", {}, { ["/.dockerenv"] = "" })
ok(by_file and by_file.path:match("AGENTS%.sandbox%.md$"), "an empty /.dockerenv selects AGENTS.sandbox.md with no variable")
ok(note("master", { WASM_AGENT_SANDBOX = "0" }, { ["/.dockerenv"] = "" }).path:match("AGENTS%.sandbox%.md$"),
  "a value other than 1 does not select it by itself, and the file still can")

-- Podman writes /run/.containerenv instead of /.dockerenv, also empty.
local by_podman = note("master", {}, { ["/run/.containerenv"] = "" })
ok(by_podman and by_podman.path:match("AGENTS%.sandbox%.md$"), "/run/.containerenv selects AGENTS.sandbox.md")
ok(note("master", {}, { ["/.dockerenv"] = nil, ["/run/.containerenv"] = nil }) == nil,
  "neither container marker and no variable is not a sandbox")

-- Detection path 3: OMARCHY_PATH.
local om_env = note("master", { OMARCHY_PATH = "/usr/share/omarchy" })
ok(om_env and om_env.path:match("AGENTS%.omarchy%.md$"), "OMARCHY_PATH selects AGENTS.omarchy.md")

-- Detection path 4: /usr/share/omarchy existing as a directory, with no variable.
local om_dir = note("master", {}, { ["/usr/share/omarchy"] = DIR })
ok(om_dir and om_dir.path:match("AGENTS%.omarchy%.md$"), "an /usr/share/omarchy directory selects AGENTS.omarchy.md")

-- A directory is not a missing file: treating the two alike would answer no where the machine says yes.
ok(note("master", {}, { ["/usr/share/omarchy"] = "not a directory" }) == nil,
  "a plain file at /usr/share/omarchy is not the Omarchy install")

-- Neither matches: no note at all.
ok(note("master", {}, {}) == nil, "no environment matches, so there is no note")
local read = fs({})
local none = agent.environment_note("master", { env = {}, read = read, config_dir = config_dir })
ok(none == nil, "an empty environment picks nothing")

-- Sandbox wins when both apply, in either detection order.
local function sandbox_wins(env, files)
  local chosen = note("master", env, files)
  ok(chosen and chosen.path:match("AGENTS%.sandbox%.md$"), "sandbox wins over Omarchy when both apply")
end
sandbox_wins({ WASM_AGENT_SANDBOX = "1", OMARCHY_PATH = "/usr/share/omarchy" }, both_notes)
sandbox_wins({ WASM_AGENT_SANDBOX = "1" }, { ["/.dockerenv"] = "x", ["/usr/share/omarchy"] = DIR })
sandbox_wins({}, { ["/.dockerenv"] = "x", ["/usr/share/omarchy"] = DIR })

-- An unreadable probe is unknown, and unknown is never yes.
local unknown = function() return nil, "read_file_unreadable:permission denied" end
ok(agent.environment_note("master", { env = {}, read = unknown, config_dir = config_dir }) == nil,
  "a probe that cannot tell selects no note")

-- Resolution order matches the role file: the environment's own override, then the working
-- directory, then the config directory.
local override = { OMARCHY_PATH = "x", WASM_AGENT_AGENTS_MD_OMARCHY = "/override.md" }
local files = { ["/override.md"] = "OVERRIDE\n", ["AGENTS.omarchy.md"] = "CWD\n", [config_dir .. "/AGENTS.omarchy.md"] = "CONFIG\n" }
ok(note("master", override, files).text == "OVERRIDE\n", "an explicit override is read first")
override.WASM_AGENT_AGENTS_MD_OMARCHY = ""
ok(note("master", override, { ["AGENTS.omarchy.md"] = "CWD\n", [config_dir .. "/AGENTS.omarchy.md"] = "CONFIG\n" }, true).text == "CWD\n",
  "the working directory comes before the config directory")
local from_config = note("master", override, { [config_dir .. "/AGENTS.omarchy.md"] = "CONFIG\n" }, true)
ok(from_config and from_config.path == config_dir .. "/AGENTS.omarchy.md" and from_config.text == "CONFIG\n",
  "the config directory is the last place it is looked for")
-- Nowhere on disk is not nil any more: since delivery, the binary's own copy is the last candidate.
-- What must never happen is an EMPTY instruction, so this asserts the fall-through and its text.
local absent = note("master", override, {}, true)
ok(absent and absent.path == "embedded:AGENTS.omarchy.md" and absent.text ~= "",
  "nowhere on disk falls through to the embedded copy, never an empty instruction")
local no_embedded = EMBEDDED and EMBEDDED["AGENTS.omarchy.md"]
if EMBEDDED then EMBEDDED["AGENTS.omarchy.md"] = nil end
local truly_absent = note("master", override, {}, true)
if EMBEDDED then EMBEDDED["AGENTS.omarchy.md"] = no_embedded end
ok(truly_absent == nil, "with no file and no embedded copy the answer is nil, not an empty instruction")

-- A guest never receives an operator note about the operator's machine.
for _, role in ipairs({ "guest" }) do
  ok(agent.environment_note(role, { env = { WASM_AGENT_SANDBOX = "1" }, read = fs(both_notes), config_dir = config_dir }) == nil,
    "a guest gets no environment note")
end

-- The note rides the project frames in the one place both ordering contracts allow: the user's own
-- <config>/AGENTS.md is first and the nearest project file is last, so the note sits between them.
assert(host.write_file(config_dir .. "/AGENTS.md", "# Project rules\nPROJECT_KEEP\n"))
local saved = agent.environment_note
agent.environment_note = function(role) return role == "guest" and nil or { path = "ENV_NOTE.md", text = "ENV_KEEP" } end
local master_files = agent.project_instructions("master", config_dir)
agent.environment_note = saved
local note_at, project_at
for i, file in ipairs(master_files) do
  if file.path == "ENV_NOTE.md" then note_at = i end
  if file.text:find("PROJECT_KEEP", 1, true) then project_at = i end
end
ok(note_at == 1, "the environment note is the first frame when there is no global file")
ok(project_at and project_at > note_at, "the project's own nearest file is read after the environment note")
ok(master_files[#master_files].path ~= "ENV_NOTE.md", "the environment note never displaces the nearest project file")
local frame = agent.system_sections("master", master_files, master_files[#master_files].path, {}, "full")
ok(frame.project:find("<project_instructions", 1, true) and frame.project:find("ENV_KEEP", 1, true),
  "the environment note is rendered inside the project instructions frame")
ok(frame.project:find("ENV_KEEP", 1, true) < frame.project:find("PROJECT_KEEP", 1, true),
  "the environment note is rendered before the nearest project file")

-- Delivery, which is what makes the note reach a node at all (review r1, MUST 1). A note that is only
-- in the checkout is read by whoever works in the checkout and by nobody else: the deployed node runs
-- from <install>/lua-core or from the binary's own copy, and its config directory holds neither.
--
-- 1. The runtime path: when neither the working directory nor <config> has it, the copy the binary
--    carries is used. Driven through a fixture EMBEDDED so this test does not depend on what the
--    installed binary happens to carry.
local real_embedded = EMBEDDED
local saved_embedded = { sandbox = real_embedded and real_embedded["AGENTS.sandbox.md"],
                         omarchy = real_embedded and real_embedded["AGENTS.omarchy.md"] }
-- The gate runs this worktree's own binary with a scratch home (scripts/test.sh), so this asserts the
-- delivery itself: the binary was built from a tree whose build.rs embeds both notes. Without it, the
-- fixture below could pass while the shipped binary carries neither.
ok(type(saved_embedded.sandbox) == "string" and saved_embedded.sandbox ~= "",
  "the binary under test embeds AGENTS.sandbox.md (rust/wa-host/build.rs)")
ok(type(saved_embedded.omarchy) == "string" and saved_embedded.omarchy ~= "",
  "the binary under test embeds AGENTS.omarchy.md (rust/wa-host/build.rs)")
EMBEDDED = EMBEDDED or {}
EMBEDDED["AGENTS.sandbox.md"] = "EMBEDDED_SANDBOX\n"
EMBEDDED["AGENTS.omarchy.md"] = "EMBEDDED_OMARCHY\n"
local from_embedded = agent.environment_note("master", { env = { WASM_AGENT_SANDBOX = "1" }, read = fs({}), config_dir = config_dir })
ok(from_embedded and from_embedded.path == "embedded:AGENTS.sandbox.md" and from_embedded.text == "EMBEDDED_SANDBOX\n",
  "with no file on disk the note comes from the binary's own copy")
local file_beats_embedded = agent.environment_note("master",
  { env = { OMARCHY_PATH = "x" }, read = fs({ [config_dir .. "/AGENTS.omarchy.md"] = "ON_DISK\n" }), config_dir = config_dir })
ok(file_beats_embedded and file_beats_embedded.text == "ON_DISK\n", "a file on disk beats the embedded copy")
EMBEDDED["AGENTS.sandbox.md"] = saved_embedded.sandbox
EMBEDDED["AGENTS.omarchy.md"] = saved_embedded.omarchy
if EMBEDDED ~= real_embedded then EMBEDDED = real_embedded end
-- Strict on purpose: with the real EMBEDDED table restored and nothing on disk, the note must come from
-- the binary. "nil or embedded" accepted both answers and so checked nothing.
local nothing_on_disk = agent.environment_note("master", { env = { WASM_AGENT_SANDBOX = "1" }, read = fs({}), config_dir = config_dir })
ok(nothing_on_disk and nothing_on_disk.path == "embedded:AGENTS.sandbox.md" and nothing_on_disk.text ~= "",
  "with nothing on disk the note is the binary's own copy, never nil and never an empty instruction")

-- 2. The two lists that ship it, asserted where they live, because a runtime check cannot see this
--    worktree's build.rs from an installed binary. One embed (rust/wa-host/build.rs) and one stage
--    (scripts/lib/lua-tree.sh); a note missing from either ships to nobody.
local lua_root = (host.getenv("WASM_AGENT_LUA_ROOT") or ""):gsub("/+$", "")
ok(lua_root ~= "", "the test runs with a Lua root, so the shipping lists can be read")
local build_rs = host.read_file(lua_root .. "/rust/wa-host/build.rs")
local tree_sh = host.read_file(lua_root .. "/scripts/lib/lua-tree.sh")
ok(type(build_rs) == "string" and build_rs ~= "", "rust/wa-host/build.rs is readable")
ok(type(tree_sh) == "string" and tree_sh ~= "", "scripts/lib/lua-tree.sh is readable")
for _, name in ipairs({ "AGENTS.omarchy.md", "AGENTS.sandbox.md" }) do
  ok(build_rs:find(name, 1, true) ~= nil, "the binary embeds " .. name .. " (rust/wa-host/build.rs)")
  ok(tree_sh:find(name, 1, true) ~= nil, "the deployed Lua tree stages " .. name .. " (scripts/lib/lua-tree.sh)")
end

-- The two notes ship in the repository, and the Omarchy one stays short: it points at the skill
-- instead of copying it, so a line budget is the mechanism that keeps it that way.
local sandbox_note = host.read_file(lua_root .. "/AGENTS.sandbox.md")
local omarchy_note = host.read_file(lua_root .. "/AGENTS.omarchy.md")
ok(type(sandbox_note) == "string" and sandbox_note ~= "", "AGENTS.sandbox.md ships")
ok(type(omarchy_note) == "string" and omarchy_note ~= "", "AGENTS.omarchy.md ships")
local lines = 0
for _ in omarchy_note:gmatch("[^\r\n]+") do lines = lines + 1 end
ok(lines <= 40, "AGENTS.omarchy.md stays at or under 40 lines, got " .. lines)
ok(omarchy_note:find("skill", 1, true) and omarchy_note:find("omarchy", 1, true),
  "the Omarchy note points at the omarchy skill rather than restating it")
ok(sandbox_note:find("findmnt", 1, true) and sandbox_note:find("container", 1, true),
  "the sandbox note names how to list mounts and says it is a container")
ok(sandbox_note:find("/.dockerenv", 1, true) and sandbox_note:find("/run/.containerenv", 1, true),
  "the sandbox note names both container markers the detector accepts")
ok(not sandbox_note:find("fleet roster names the one", 1, true),
  "the sandbox note claims no host-identifying field the roster does not carry")

sh("rm -rf '" .. config_dir .. "'")
print("environment notes ok (" .. checks .. " checks, 0 skipped)")
