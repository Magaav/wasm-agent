-- Editing a file on a PEER is the edit you know here (mission remote-edit-first-class).
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-remote-edit.lua \\
--     wa --db <scratch>/t.db
--
-- TWO SCRATCH NODES IN ONE PROCESS, and never the real fleet: the PEER half is the real
-- wa_peer_dispatch this node runs for a verified peer, and the CALLER half is the real tools.remote
-- handler. What stands in between is the transport - nodes.remote_call, the exact seam tools.remote
-- uses to reach a node - and it carries what that function carries and nothing more: the caller's own
-- page record (read_pages) and its request for the change text (record_change), as fields of the
-- signed body, which section 9 checks on the real nodes.remote_call. What this fixture does NOT prove,
-- and the report says so: the relay itself, the peer's signature check (scripts/test-remote-refusals.lua
-- and scripts/test-mesh-*.lua cover those), and two machines - the peer's files here are this
-- filesystem, so "it happened on the peer" is proven by the capability calls the stand-in recorded,
-- never by a different disk.
--
-- What it pins, each of which fails on c6f890e3:
--   * the read-before-edit fence is judged by what THIS SESSION read on THAT node: another session on
--     the same caller node is not fenced by this one's page (on the base it is - the peer's own record
--     is keyed by the caller NODE, and a second caller id measured 22/11 was let through);
--   * a remote edit's change is recorded in THIS session, with the node it happened on, so /undo
--     restores the file there - through the real wa_diff route, and the restore is a write capability
--     call to that node;
--   * an older peer that sends no before/after text leaves ONE honest row that cannot be undone,
--     never a crash and never a silent gap;
--   * a caller's page record the peer cannot read is refused by name, not read as "no record";
--   * the tools.remote description names the edit, with an example.
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\\\\\\\]+", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\\\\\\\]%%.wasm%%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

local json = dofile("lua/vendor/json.lua")
-- One module instance for this script, tools.lua and server.lua, so the stand-in below is the one they
-- call (the pattern scripts/test-remote-refusals.lua uses). The first loads of file_tools and changeset
-- are tools.lua's, and those are the instances whose state this file asserts on.
local original_dofile = dofile
local nodes = original_dofile("lua/core/nodes.lua")
local shared = {}
dofile = function(path)
  if path == "lua/core/nodes.lua" then return nodes end
  local module = original_dofile(path)
  if path == "lua/core/file_tools.lua" and not shared.file_tools then shared.file_tools = module end
  if path == "lua/core/changeset.lua" and not shared.changeset then shared.changeset = module end
  return module
end
local memory = original_dofile("lua/core/memory.lua"); memory.setup()
local tools = original_dofile("lua/core/tools.lua")
local paths = original_dofile("lua/core/paths.lua")
local file_tools, changeset = shared.file_tools, shared.changeset
assert(file_tools and changeset, "tools.lua must have loaded file_tools and changeset")
original_dofile("lua/core/server.lua")   -- defines wa_peer_dispatch and wa_diff, and installs the changeset transport
assert(type(wa_peer_dispatch) == "function" and type(wa_diff) == "function", "server.lua must define its routes")

host.http = function() error("network forbidden in this fixture") end
host.http_stream = host.http

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

-- The two nodes. The caller is this node's own session; the peer is a caller table the real
-- wa_peer_dispatch accepts (server.lua wa_peer_dispatch; scripts/test-remote-pending.lua).
local PEER = "fixture-peer"
local PEER_ID = "fixture-peer-id"
local peer_caller = { node_id = PEER_ID, role = "master", name = PEER }
local node_table = { name = PEER, node_id = PEER_ID, online = true, endpoints = { "http://127.0.0.1:9" } }
local sent = {}
local peer_ignores_change = false   -- an OLD peer: it knows no record_change and sends no texts
local real_remote_call = nodes.remote_call
nodes.find = function() return node_table end
nodes.operator_status = function() return nil end
-- The mesh is a second admission path with its own tests (scripts/test-mesh-gate.lua,
-- scripts/test-mesh-verb-admission.lua, scripts/test-mesh-trust.lua). Here it is off: what this file
-- pins is the signed body and the two halves, and a component present on the machine must not decide
-- what the fixture measures (measured: it answered enabled in a scratch home and took the section 9
-- call away from the transport).
nodes.mesh_enabled = function() return false end
local function transport(selector, capability, args, options)
  sent[#sent + 1] = { selector = selector, capability = capability, args = args, options = options }
  local request = {
    capability = capability,
    args = args,
    read_pages = options and options.read_pages or nil,
    record_change = (not peer_ignores_change) and options and options.record_change or nil,
  }
  return wa_peer_dispatch(capability, args, peer_caller, "master", request)
end
nodes.remote_call = transport

local sid = memory.start_session("", "remote edit", { user_id = "master" })
local ctx = { session_id = sid, user_id = "master", changes = changeset.new() }
local function remote(args) return tools.dispatch(memory, "remote", args, "master", ctx) end

local root = paths.data() .. "/remote-edit"
local big = root .. "/big.txt"
local small = root .. "/demo.txt"
local lines = {}
for i = 1, 3000 do lines[i] = "line " .. i end
assert(host.write_file(big, table.concat(lines, "\n") .. "\n"))
local original_small = "alpha\nbeta\ngamma\n"
assert(host.write_file(small, original_small))

-- 1. A read on the peer says what it served. The page is recorded on THIS node, for THIS session and
--    THAT node, which is section 4: the sections before it are the behaviour a reader can see.
local read = remote({ node = PEER, capability = "read", path = big, offset = 1, limit = 10 })
check(read.truncated == true and type(read.version) == "string", "the peer page says what it served")

-- 2. Another session on the SAME caller node is not fenced by this session's page: the guard is about
--    what a session was shown, and this one was shown nothing. Measured 22/11 on the base, where the
--    peer's record is keyed by the caller node and refused exactly this edit.
local other = { session_id = memory.start_session("", "remote edit two", { user_id = "master" }),
  user_id = "master", changes = changeset.new() }
local stranger = tools.dispatch(memory, "remote",
  { node = PEER, capability = "edit", path = big,
    edits = { { old_text = "line 2500", new_text = "line 2500 TWO" } } }, "master", other)
check(stranger.applied == true,
  "a session that read nothing is not fenced by another session's page: " .. json.encode({ error = stranger.error }))
check(tostring(host.read_file(big)):find("line 2500 TWO", 1, true) ~= nil, "and the edit landed on the peer")

-- 3. The fence, for the session that DID read a page. The version moved with the edit above, so read
--    again to bind the record to the version the next edits are judged against.
read = remote({ node = PEER, capability = "read", path = big, offset = 1, limit = 10 })
local outside = remote({ node = PEER, capability = "edit", path = big,
  edits = { { old_text = "line 2000", new_text = "line 2000 EDITED" } } })
check(outside.error == "edit_anchor_outside_read_page",
  "an anchor outside every page read on that node is refused by name, got " .. json.encode({ error = outside.error }))
check(outside.pages and outside.pages[1] and outside.pages[1].first_line == 1,
  "and the refusal says which page this session was served")
check(tostring(host.read_file(big)):find("line 2000 EDITED", 1, true) == nil, "nothing was written")
-- Two whole lines, so the anchor cannot match "line 5" inside "line 50": the point of this case is the
-- fence, not the exactly-once rule another test owns.
local inside = remote({ node = PEER, capability = "edit", path = big,
  edits = { { old_text = "line 5\nline 6", new_text = "line 5 EDITED\nline 6" } } })
check(inside.applied == true, "an anchor inside the page this session read is applied: " .. json.encode({ error = inside.error }))
check(tostring(host.read_file(big)):find("line 5 EDITED", 1, true) ~= nil, "and it landed on the peer")

-- 3b. A page read in a BATCH is also a page this session was served. Without the record, the edit
--     below would state "this session was served nothing" and the fence would have a hole exactly
--     where the cheapest read is (measured while building this change).
local deep = root .. "/deep.txt"
assert(host.write_file(deep, table.concat(lines, "\n") .. "\n"))
local batch = remote({ node = PEER, capability = "batch",
  calls = { { capability = "read", path = deep, offset = 1, limit = 10 } } })
check(batch.ok == true and type(batch.results[1]) == "table" and batch.results[1].truncated == true,
  "a batch read answers its page")
local outside_batch = remote({ node = PEER, capability = "edit", path = deep,
  edits = { { old_text = "line 2800", new_text = "line 2800 BATCH" } } })
check(outside_batch.error == "edit_anchor_outside_read_page",
  "an anchor outside a page a BATCH served is refused by name, got " .. json.encode({ error = outside_batch.error }))
check(tostring(host.read_file(deep)):find("line 2800 BATCH", 1, true) == nil, "and nothing was written")

-- 4. This node's own record of what that session was served there: the new symbol (page_snapshot) is
--    checked here rather than first, so that on the base this file fails on an assertion about
--    behaviour instead of on a missing function (scripts/test-discriminates.sh counts a missing symbol
--    as evidence of nothing).
local snapshot = file_tools.page_snapshot(sid, big, PEER)
check(snapshot and snapshot.version == read.version and #snapshot.ranges == 1,
  "this session's record of the page it was served on that node")
check(snapshot.ranges[1].first_byte == read.range.first_byte and snapshot.ranges[1].last_byte == read.range.last_byte,
  "and the range is the one the answer named, byte for byte")
check(file_tools.page_snapshot(sid, big, "another-node") == nil,
  "a page served on one node is not a page on another")

-- 5. The change is recorded HERE, with the node it happened on, and the two texts are not left in
--    the answer the model reads.
-- A turn's own record: the edits above belong to the previous turn, and one change record per turn is
-- what the run builds (agent.lua changeset.new()).
ctx.changes = changeset.new()
local before_change = host.read_file(small)
local edited = remote({ node = PEER, capability = "edit", path = small,
  edits = { { old_text = "beta", new_text = "BETA" } } })
check(edited.applied == true, "an edit of a small file is applied: " .. json.encode({ error = edited.error }))
check(edited.change == nil, "the before/after texts are not left in the model's answer")
check(ctx.changes.files[1] and ctx.changes.files[1].node == PEER,
  "this session's change record names the node the change happened on")
local entry = changeset.normalize(ctx.changes)
check(#entry.files == 1 and entry.files[1].node == PEER, "one file, on the peer")
check(changeset.load(entry.files[1].before) == before_change, "the previous text is the peer's own file")
check(changeset.load(entry.files[1].after) == "alpha\nBETA\ngamma\n", "and the new text is what landed there")

-- 6. Undo through the REAL route (wa_diff), from this node, restoring the file on the peer.
local message_id = host.uuid()
memory.append_turn(sid, { id = message_id, role = "assistant", content = "edited it on the peer",
  changes = changeset.summary(ctx.changes) })
local function diff(payload) return json.decode(wa_diff(json.encode(payload), "")) end
local can = diff({ message_id = message_id, action = "check" })
check(can.can_undo == true, "the change made on the peer is undoable from here: " .. tostring(can.reason))
sent = {}
local undone = diff({ message_id = message_id, action = "undo" })
check(undone.ok == true, "undo succeeds: " .. tostring(undone.reason))
check(host.read_file(small) == original_small, "and the file on the peer holds its previous text again")
local wrote = nil
for _, call in ipairs(sent) do
  if call.capability == "write" and call.args and call.args.path == small then wrote = call end
end
check(wrote ~= nil, "the restore was a write capability call to that node, not a local write")
check(wrote and wrote.args.content == original_small, "carrying the previous text")
local redone = diff({ message_id = message_id, action = "redo" })
check(redone.ok == true and host.read_file(small) == "alpha\nBETA\ngamma\n", "and redo puts it back on the peer")

-- 7. A remote WRITE is recorded the same way.
ctx.changes = changeset.new()
assert(host.write_file(small, "one\ntwo\n"))
local written = remote({ node = PEER, capability = "write", path = small, content = "one\nTWO\n" })
check(written.ok == true, "a remote write is applied: " .. json.encode({ error = written.error }))
local write_file_entry
for _, file in ipairs(changeset.normalize(ctx.changes).files) do
  if file.path == small and file.node == PEER then write_file_entry = file end
end
check(write_file_entry and write_file_entry.node == PEER, "the write is recorded against the peer")
check(changeset.load(write_file_entry.after) == "one\nTWO\n", "with the text it wrote")
local write_message = host.uuid()
memory.append_turn(sid, { id = write_message, role = "assistant", content = "wrote it on the peer",
  changes = changeset.summary(ctx.changes) })
check(diff({ message_id = write_message, action = "check" }).can_undo == true, "and it is undoable from here")

-- 8. An OLDER peer: it knows neither the page record nor the request for the texts. Nothing it did
--    before is refused, and the change leaves one honest row that says why it cannot be undone.
ctx.changes = changeset.new()
peer_ignores_change = true
assert(host.write_file(small, "old\npeer\n"))
local by_old_peer = remote({ node = PEER, capability = "edit", path = small,
  edits = { { old_text = "peer", new_text = "PEER" } } })
check(by_old_peer.applied == true, "an older peer still applies the edit: " .. json.encode({ error = by_old_peer.error }))
local legacy
for _, file in ipairs(changeset.normalize(ctx.changes).files) do
  if file.path == small and file.reason then legacy = file end
end
check(legacy ~= nil, "one row for what an older peer did")
check(legacy and legacy.reason == "peer_sent_no_change_text", "and it says why: " .. tostring(legacy and legacy.reason))
check(legacy and legacy.recorded == false and legacy.created == false,
  "not recorded, and not called a file the run created")
local legacy_message = host.uuid()
memory.append_turn(sid, { id = legacy_message, role = "assistant", content = "old peer",
  changes = changeset.summary(ctx.changes) })
local legacy_check = diff({ message_id = legacy_message, action = "check" })
check(legacy_check.can_undo == false and tostring(legacy_check.reason):find("peer_sent_no_change_text", 1, true) == 1,
  "undo refuses it by that name rather than crashing: " .. tostring(legacy_check.reason))
peer_ignores_change = false

-- 9. A caller's page record the peer cannot read is refused by name: unknown is not yes, and "no
--    record" is the one reading that would turn the fence off.
assert(host.write_file(small, "alpha\nbeta\ngamma\n"))
local unreadable = wa_peer_dispatch("edit", { path = small, edits = { { old_text = "beta", new_text = "x" } } },
  peer_caller, "master", { read_pages = { record = { version = 42 } } })
check(unreadable.error == "edit_read_page_invalid",
  "a page record this node cannot read is refused by name, got " .. json.encode({ error = unreadable.error }))
check(host.read_file(small) == "alpha\nbeta\ngamma\n", "and nothing was written")
local no_record = wa_peer_dispatch("edit", { path = small, edits = { { old_text = "beta", new_text = "x" } } },
  peer_caller, "master", { read_pages = { record = false } })
check(no_record.applied == true, "a caller that states it was served nothing is not fenced: " .. json.encode({ error = no_record.error }))

-- 10. The wire: the real nodes.remote_call puts both fields in the SIGNED BODY, never in args, which is
--    what the model writes.
nodes.remote_call = real_remote_call
local posted = {}
host.http = function(method, url, headers, body)
  posted[#posted + 1] = { url = url, body = body }
  -- A 200 with an unverifiable body: the point of this section is the bytes the caller SENDS, and the
  -- reply is never parsed as a result (a forged answer is refused by verified_reply, tested elsewhere).
  return json.encode({ status = 200, body = json.encode({ reply = json.encode({ ok = true }), reply_sig = "" }) })
end
local wire_call = real_remote_call(PEER, "edit", { path = big, edits = {} },
  { read_pages = { record = false }, record_change = true })
host.http = function() error("network forbidden in this fixture") end
nodes.remote_call = transport
-- The signed body is what the caller posts, directly or wrapped by the relay: read it at either depth,
-- because which transport answers depends on this machine's rendezvous settings.
local envelope
for _, request in ipairs(posted) do
  local decoded = type(request.body) == "string" and (pcall(json.decode, request.body)) and json.decode(request.body) or nil
  if type(decoded) == "table" then
    if decoded.capability then envelope = decoded break end
    if type(decoded.body) == "string" then
      local inner = pcall(json.decode, decoded.body) and json.decode(decoded.body) or nil
      if type(inner) == "table" and inner.capability then envelope = inner break end
    end
  end
end
check(envelope ~= nil, "the call reached the transport: " .. json.encode({ error = wire_call.error, detail = wire_call.detail }))
check(type(envelope.read_pages) == "table" and envelope.read_pages.record == false,
  "the page record travels in the signed body")
check(envelope.record_change == true, "and so does the request for the change text")
check(envelope.args and envelope.args.read_pages == nil and envelope.args.record_change == nil,
  "neither of them travels inside args, which is the model's own text")

-- 11. The description names the edit, with one example beside the two that exist.
local remote_schema
for _, schema in ipairs(tools.all("master")) do
  if schema["function"].name == "remote" then remote_schema = schema["function"] end
end
check(remote_schema ~= nil, "the remote tool has a schema")
check(remote_schema.description:find('"capability":"edit"', 1, true) ~= nil,
  "the remote description shows an edit on a peer")
check(remote_schema.description:find('"edits":[{', 1, true) ~= nil, "with the edits shape in it")
check(remote_schema.description:find('"capability":"bash"', 1, true) ~= nil
  and remote_schema.description:find('"capability":"read"', 1, true) ~= nil, "beside the two that were there")

print("remote edit ok (" .. checks .. " checks)")
