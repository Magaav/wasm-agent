-- `/undo` in the chat is a DOOR to the undo that already exists (mission remote-undo-works).
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-undo-command.lua \
--     wa --db <scratch>/t.db
--
-- The premise this mission measured: `lua/core/tools.lua` told the model "the change is recorded here, so
-- /undo restores that file there", `changeset` recorded the change, the window's /diff route could undo
-- it - and a chat had no /undo at all (typing it answered "unknown or incomplete command"). The fix is a
-- door, not a second undo, so what this file pins is that the door calls the SAME `changeset.check` and
-- `changeset.undo` the route calls, on the newest change THIS session recorded, and that it says what it
-- restored or refuses by name.
--
-- The peer half is `scripts/test-remote-edit.lua`'s fixture, for its reason: the peer side is the real
-- `wa_peer_dispatch` this node runs for an admitted peer, and the transport seam is replaced by a
-- stand-in that carries what the real one carries. The files are this filesystem, so "it happened on the
-- peer" is proven by the capability calls the stand-in recorded, never by a different disk - and never
-- by the live fleet (no rendezvous, no relay, no `wa call`, nothing outside this scratch home).
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\\\]+", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\\\]%%.wasm%%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

local json = dofile("lua/vendor/json.lua")
-- One module instance for this script, tools.lua and server.lua, so the stand-in below is the one they call
-- (scripts/test-remote-edit.lua's pattern).
local original_dofile = dofile
local nodes = original_dofile("lua/core/nodes.lua")
local shared = {}
dofile = function(path)
  if path == "lua/core/nodes.lua" then return nodes end
  local module = original_dofile(path)
  if path == "lua/core/changeset.lua" and not shared.changeset then shared.changeset = module end
  return module
end
local memory = original_dofile("lua/core/memory.lua"); memory.setup()
local tools = original_dofile("lua/core/tools.lua")
local paths = original_dofile("lua/core/paths.lua")
local changeset = shared.changeset
assert(changeset, "tools.lua must have loaded changeset")
original_dofile("lua/core/server.lua")   -- wa_peer_dispatch, and its own install of the transport
assert(type(wa_peer_dispatch) == "function", "server.lua must define the peer capability route")

host.http = function() error("network forbidden in this fixture") end
host.http_stream = host.http

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local function contains(text, part) return tostring(text):find(part, 1, true) ~= nil end

-- 1. THE PROMISE THE HELP MAKES. This is the first failure on the base commit: there is no row, so
--    /help lists no /undo and typing it is "unknown or incomplete command". Asserted before the door is
--    loaded, so the base fails on a value rather than on a missing file.
local commands = original_dofile("lua/core/commands.lua")
local listed, hint = nil, nil
for _, row in ipairs(commands.commands) do
  if row.name == "/undo" then listed, hint = row, tostring(row.hint or "") end
end
check(listed ~= nil, "/help lists /undo: " .. json.encode(commands.names()))
check(contains(hint, "last file change"), "and its hint says what it puts back: " .. hint)
check(commands.menu and #commands.names() > 0, "the slash menu is built from the same rows")

local undo = original_dofile("lua/core/undo_command.lua")

-- 2. A local change, undone from the session that made it.
local sid = memory.start_session("", "undo command", { user_id = "master" })
local root = paths.data() .. "/undo-command"
local demo = root .. "/demo.txt"
assert(host.write_file(demo, "one\ntwo\nthree\n"))
local ctx = { session_id = sid, user_id = "master", changes = changeset.new() }
local written = tools.dispatch(memory, "write", { path = demo, content = "one\nTWO\nthree\n" }, "master", ctx)
check(written.ok == true, "a write is applied: " .. json.encode({ error = written.error }))
memory.append_turn(sid, { id = host.uuid(), role = "assistant", content = "changed the second line",
  changes = changeset.summary(ctx.changes) })

local report = undo.run({ session_id = sid, memory = memory, changeset = changeset, nodes = nodes })
check(report.ok == true, "the last recorded change is undone: " .. json.encode(report))
check(host.read_file(demo) == "one\ntwo\nthree\n", "and the file holds its previous text again")
check(contains(report.lines[1], "undo: " .. demo), "the answer names the file it put back: " .. tostring(report.lines[1]))
check(contains(report.lines[1], "this node"), "and where it put it back: " .. tostring(report.lines[1]))
check(contains(report.lines[1], host.sha256("one\ntwo\nthree\n"):sub(1, 12)),
  "and the version it now holds, from the record's own address: " .. tostring(report.lines[1]))

-- 3. The same change again: the file is already what that turn left behind, so the door refuses by name
--    and writes nothing. A second undo must never quietly eat a newer file.
local again = undo.run({ session_id = sid, memory = memory, changeset = changeset, nodes = nodes })
check(again.ok == false and again.category == "version_moved",
  "a second /undo refuses by name instead of restoring over the reader's own state: " .. json.encode(again))
check(host.read_file(demo) == "one\ntwo\nthree\n", "and nothing was written")

-- 4. A session that recorded nothing says so, with the name the brief asks for.
local empty = memory.start_session("", "undo nothing", { user_id = "master" })
local none = undo.run({ session_id = empty, memory = memory, changeset = changeset, nodes = nodes })
check(none.ok == false and none.category == "nothing_to_undo", "an untouched session refuses nothing_to_undo: " .. json.encode(none))
check(contains(none.lines[1], "nothing"), "and says it in words: " .. tostring(none.lines[1]))

-- 5. A file the turn CREATED: undo restores text and never deletes, so the answer says so rather than
--    claiming the file is gone (changeset.lua's stated limit).
local fresh = root .. "/created.txt"
local making = memory.start_session("", "undo created", { user_id = "master" })
local make_ctx = { session_id = making, user_id = "master", changes = changeset.new() }
local made = tools.dispatch(memory, "write", { path = fresh, content = "new\n" }, "master", make_ctx)
check(made.ok == true, "a create is applied: " .. json.encode({ error = made.error }))
memory.append_turn(making, { id = host.uuid(), role = "assistant", content = "created it",
  changes = changeset.summary(make_ctx.changes) })
local emptied = undo.run({ session_id = making, memory = memory, changeset = changeset, nodes = nodes })
check(emptied.ok == true, "undoing a create succeeds: " .. json.encode(emptied))
check(host.read_file(fresh) == "", "and leaves an emptied file, because the host has no remove_file")
check(contains(emptied.lines[1], "emptied"), "the answer says emptied, not deleted: " .. tostring(emptied.lines[1]))

-- 6. THE REMOTE HALF. A change made on a peer is undone on the peer, through the same transport the
--    /diff route installs (lua/core/remote_files.lua), and the door reports which node it reached.
local PEER, PEER_ID = "fixture-peer", "fixture-peer-id"
local peer_caller = { node_id = PEER_ID, role = "master", name = PEER }
local node_table = { name = PEER, node_id = PEER_ID, online = true, endpoints = { "http://127.0.0.1:9" } }
local sent, peer_unreadable = {}, false
local real_remote_call = nodes.remote_call
nodes.find = function() return node_table end
nodes.operator_status = function() return nil end
nodes.mesh_enabled = function() return false end
nodes.remote_call = function(selector, capability, args, options)
  sent[#sent + 1] = { selector = selector, capability = capability, args = args, options = options }
  if peer_unreadable and capability == "read" then return { error = "node_no_answer", node = PEER } end
  return wa_peer_dispatch(capability, args, peer_caller, "master", {
    read_pages = options and options.read_pages or nil,
    record_change = options and options.record_change or nil,
  })
end

local here = root .. "/here.txt"
assert(host.write_file(here, "alpha\nbeta\ngamma\n"))
local remote_sid = memory.start_session("", "undo remote", { user_id = "master" })
local remote_ctx = { session_id = remote_sid, user_id = "master", changes = changeset.new() }
local read_page = tools.dispatch(memory, "remote", { node = PEER, capability = "read", path = here, offset = 1, limit = 10 },
  "master", remote_ctx)
check(type(read_page.version) == "string", "the peer answers a page: " .. json.encode({ error = read_page.error }))
local edited = tools.dispatch(memory, "remote", { node = PEER, capability = "edit", path = here,
  edits = { { old_text = "beta", new_text = "BETA" } } }, "master", remote_ctx)
check(edited.applied == true, "an edit on the peer is applied: " .. json.encode({ error = edited.error }))
local entry = changeset.normalize(remote_ctx.changes)
check(#entry.files == 1 and entry.files[1].node == PEER, "this session's record names the peer it happened on")
memory.append_turn(remote_sid, { id = host.uuid(), role = "assistant", content = "edited it there",
  changes = changeset.summary(remote_ctx.changes) })

sent = {}
local crossed = undo.run({ session_id = remote_sid, memory = memory, changeset = changeset, nodes = nodes })
check(crossed.ok == true, "the change made on the peer is undone from here: " .. json.encode(crossed))
check(host.read_file(here) == "alpha\nbeta\ngamma\n", "and the peer's file holds its previous text")
local wrote = nil
for _, call in ipairs(sent) do
  if call.capability == "write" and call.args and call.args.path == here then wrote = call end
end
check(wrote ~= nil, "the restore was a write capability call to that node, not a local write")
check(wrote and wrote.args.content == "alpha\nbeta\ngamma\n", "carrying the previous text")
check(contains(crossed.lines[1], "on " .. PEER), "and the answer names that node: " .. tostring(crossed.lines[1]))
check(contains(crossed.lines[1], host.sha256("alpha\nbeta\ngamma\n"):sub(1, 12)),
  "with the version the peer now holds: " .. tostring(crossed.lines[1]))

-- 7. A peer that cannot be read is a refusal by name, and nothing is written here either: unknown is not
--    yes, and the local file of the same path must not become the thing that gets overwritten.
local twice = memory.start_session("", "undo unreachable", { user_id = "master" })
local twice_ctx = { session_id = twice, user_id = "master", changes = changeset.new() }
local again_read = tools.dispatch(memory, "remote", { node = PEER, capability = "read", path = here, offset = 1, limit = 10 },
  "master", twice_ctx)
check(type(again_read.version) == "string", "the peer answers before it goes quiet")
local again_edit = tools.dispatch(memory, "remote", { node = PEER, capability = "edit", path = here,
  edits = { { old_text = "gamma", new_text = "GAMMA" } } }, "master", twice_ctx)
check(again_edit.applied == true, "a second edit is applied: " .. json.encode({ error = again_edit.error }))
memory.append_turn(twice, { id = host.uuid(), role = "assistant", content = "edited again",
  changes = changeset.summary(twice_ctx.changes) })
peer_unreadable = true
local blind = undo.run({ session_id = twice, memory = memory, changeset = changeset, nodes = nodes })
check(blind.ok == false and blind.category == "node_unreachable",
  "an unreadable peer refuses node_unreachable: " .. json.encode(blind))
check(contains(table.concat(blind.lines, " "), "node_unreadable"),
  "with the reason it was given: " .. table.concat(blind.lines, " "))
check(host.read_file(here) == "alpha\nbeta\nGAMMA\n", "and neither machine's file moved")
peer_unreadable = false

-- 8. The classification, which is the one place a reason becomes a name: a reason nobody has classified
--    stays `refused` with its own text rather than being folded into a category that would sound like an
--    answer.
check(undo.category("nothing_to_undo") == "nothing_to_undo")
check(undo.category("changed_since_turn:/x") == "version_moved")
check(undo.category("missing_since_turn:/x") == "version_moved")
check(undo.category("node_unreadable:node_no_answer:/x") == "node_unreachable")
check(undo.category("no_node_transport:/x") == "node_unreachable")
check(undo.category("peer_sent_no_change_text:/x") == "not_recorded")
check(undo.category("write_failed:/x") == "write_failed")
check(undo.category("something_nobody_classified:/x") == "refused")
check(undo.category("") == "refused")

nodes.remote_call = real_remote_call
print("undo command ok (" .. checks .. " checks)")
