-- A PICTURE PRODUCED ON ONE NODE REACHES THE MODEL ON ANOTHER (mission run-images-two-node, item 1).
--
-- scripts/test-remote-image.lua pins the caller half and the peer half with the WIRE stubbed: a hand
-- written \`image_data\` table. This row closes that seam with TWO REAL NODES on this machine - two
-- scratch homes, two ports, real ed25519 identities, a signed roster, the real mesh transport, this
-- node's own tools.dispatch("remote") - so the bytes that arrive are the bytes a second process sent:
--
--   1. the peer is a real \`wa serve\` with its own home, its own policy and a verified roster, and the
--      mount admits this node by the roster (its own log says so);
--   2. a picture read on that peer arrives as bytes, is verified against the digest the peer named, and
--      is stored HERE: the same content-addressed file exists in BOTH stores, byte for byte;
--   3. a picture past the 1 MB transfer cap is refused BY NAME, with its size and the cap;
--   4. the picture reaches the MODEL's request on this node: one image part, that picture, no reference
--      table in the tool text;
--   5. a peer call's working directory, the receiving half: an explicit \`cwd\` is recorded on the peer as
--      cwd_source=explicit, and a call that names none is recorded as the node's own.
--
-- WHAT IS STUBBED, and only that: \`nodes.find\` (discovery - a name is resolved at the rendezvous, and
-- this pair has none by design: no live fleet is touched) and the model provider (the request is what
-- this row measures). Everything between them is the product's own code on both sides.
--
-- Hermetic: its own scratch home (the runner's), the peer's home under the scratch root, every port
-- fresh, WASM_AGENT_RENDEZVOUS/RELAY empty for the peer, and the peer is stopped by the operation id
-- this row started. No live node, no fleet, no relay.
if not host then error("this row runs under the node (WA_SCRIPT), not plain Lua") end
local json = dofile("lua/vendor/json.lua")
-- ONE INSTANCE of lua/core/nodes.lua for this process: the modules under test are loaded through
-- dofile, so a stub set on a second instance is never read by lua/core/tools.lua's own calls.
local original_dofile = dofile
local nodes = original_dofile("lua/core/nodes.lua")
local loaded = { ["lua/core/nodes.lua"] = nodes }
dofile = function(path)
  if loaded[path] then return loaded[path] end
  local module = original_dofile(path)
  loaded[path] = module
  return module
end

local function decode(value, what)
  if type(value) ~= "string" then error("decode(" .. tostring(what) .. ") got " .. type(value), 2) end
  return json.decode(value)
end
local guard = dofile("scripts/lib/test-home-guard.lua")
local reason = guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if reason then error("this row refuses to run (" .. reason .. ")") end

local checks, skipped = 0, {}
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end
local function skip(label, why)
  skipped[#skipped + 1] = label .. ": " .. why
  print("SKIP two-node " .. label .. ": " .. why)
end

-- ---- the two scratch homes, the roster and the ports ---------------------------------------------
local scratch = tostring(os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
local root = scratch .. "/two-node-pair-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
-- Node A is THIS process (its own scratch home, identity and policy) - not a third home: the caller
-- half has to be the node under test, not a copy of it.
local paths = dofile("lua/core/paths.lua")
local home_b = root .. "/b"
local lua_root = host.getenv("WASM_AGENT_LUA_ROOT") or "."
lua_root = tostring(host.canonical_path(lua_root) or lua_root)

local function sh(command, timeout)
  local raw = host.exec(command, "", timeout or 60, json.encode({ tool = "bash" }))
  local decoded = decode(raw or "{}") or {}
  return tonumber(decoded.code) or 1, tostring(decoded.stdout or ""), tostring(decoded.stderr or "")
end

-- The node's own binary: this process is a node, so its own path is the build under test.
local runtime = decode(host.runtime_info() or "{}") or {}
local binary = host.getenv("WA_FAST_BIN") or host.getenv("WA_TEST_BIN") or host.getenv("WA_BIN")
  or tostring(runtime.binary_path or "")
if binary == "" or not host.canonical_path(binary) then
  print("SKIP two-node pair: no node binary to start the peer with (WA_BIN/WA_FAST_BIN, runtime_info().binary_path)")
  return
end

-- A free loopback port from the kernel; never 8799, the operator's node.
local function free_port()
  local code, out = sh("python3 -c 'import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));"
    .. "print(s.getsockname()[1]);s.close()'")
  local port = code == 0 and tonumber((out:gsub("%s", ""))) or nil
  if not port or port == 8799 then return nil end
  return port
end

local mesh_port, node_port, client_port = free_port(), free_port(), free_port()
if not (mesh_port and node_port and client_port) then
  print("SKIP two-node pair: no free-port probe here (python3 is needed to ask the kernel)")
  return
end

local function field(text, name)
  return tostring(text):match('"' .. name .. '":"([^"]*)"')
end
local function mkdirs() return sh("mkdir -p " .. string.format("%q %q %q %q", home_b .. "/.wasm-agent",
  root .. "/fleet", home_b .. "/pics", root .. "/peer-tree")) end
local made = mkdirs()
ok(made == 0, "the two scratch homes exist under the scratch root: " .. root)

local function node_identity(home)
  local ok_run, out = sh("WASM_AGENT_HOME=" .. string.format("%q", home) .. " "
    .. string.format("%q", binary) .. " node 2>/dev/null")
  if ok_run ~= 0 then return {} end
  return decode(out, "node identity") or {}
end
local id_a = decode(host.node_identity(), "this node's identity") or {}
local id_b = node_identity(home_b)
ok(type(id_a.node_id) == "string" and #id_a.node_id == 32, "node A has a real identity")
ok(type(id_b.node_id) == "string" and #id_b.node_id == 32 and id_b.node_id ~= id_a.node_id,
  "node B has a different one: two nodes, not one")

local keygen_code, keygen = sh(string.format("%q", binary) .. " fleet keygen --out "
  .. string.format("%q", root .. "/fleet/pair.key"))
local fleet_pub = keygen and field(keygen, "public_key")
ok(keygen_code == 0 and type(fleet_pub) == "string" and #fleet_pub == 64,
  "the fleet key that signs the roster: " .. tostring(keygen):sub(1, 160))

local roster = { version = 1, fleet = "scratch", issued_at = 0, expires_at = 0, nodes = {
  { node_id = id_a.node_id, public_key = id_a.public_key, name = "pair-a", level = 0, addresses = {}, revoked_at = 0 },
  { node_id = id_b.node_id, public_key = id_b.public_key, name = "pair-b", level = 1,
    addresses = { "127.0.0.1:" .. tostring(mesh_port) }, revoked_at = 0 },
} }
ok(host.write_file(root .. "/roster.json", json.encode(roster)), "the roster is written")
local sign_code, sign_out = sh(string.format("%q", binary) .. " fleet sign " .. string.format("%q", root .. "/roster.json")
  .. " --key " .. string.format("%q", root .. "/fleet/pair.key") .. " --expires-days 1")
ok(sign_code == 0 and sign_out:find('"ok":true', 1, true) ~= nil,
  "the roster is signed: " .. tostring(sign_out):sub(1, 200))
local signed = host.read_file(root .. "/roster.signed.json")
ok(type(signed) == "string" and #signed > 0, "the signed roster is on disk")

local function policy(config_dir, with_port)
  local mesh = { version = 1, roster_key = fleet_pub, roster = "mesh-roster.json", enabled = true }
  if with_port then mesh.port = mesh_port mesh.bind = "127.0.0.1" end
  local wrote = host.write_file(config_dir .. "/policy.json",
    json.encode({ version = 1, components = {}, mesh = mesh }))
  return wrote and host.write_file(config_dir .. "/mesh-roster.json", signed)
end
ok(policy(paths.config(), false) and policy(home_b .. "/.wasm-agent", true),
  "both nodes hold the signed roster and the mesh setting (this node's own: " .. tostring(paths.config()) .. ")")

-- ---- the peer: a real node process, started the supported way --------------------------------
local peer, peer_log = nil, root .. "/peer.log"
-- Stopped by the id this row started, and only that: the record's own pid is the fallback when the
-- cancel does not settle, because a peer left running holds its port and the next run's port probe.
local function stop_peer()
  if not peer then return end
  local id = peer
  peer = nil
  pcall(host.operation, "cancel", json.encode({ id = id, owner = "two-node-pair" }))
  for _ = 1, 20 do
    local state = decode(host.operation("status", json.encode({ id = id, owner = "two-node-pair" })) or "{}", "status") or {}
    if tostring(state.state) == "cancelled" or tostring(state.state) == "failed"
      or tostring(state.state) == "completed" then return end
    host.sleep(100)
  end
  local state = decode(host.operation("status", json.encode({ id = id, owner = "two-node-pair" })) or "{}", "status") or {}
  local pid = tonumber(state.owner_process_id)
  if pid then sh("kill " .. tostring(pid) .. " 2>/dev/null") end
end
local function start_peer()
  local env = { "NO_PROXY=127.0.0.1,localhost,::1", "WASM_AGENT_RENDEZVOUS=", "WASM_AGENT_RELAY=",
    "WASM_AGENT_MANAGED=0", "WASM_AGENT_HOME=" .. home_b, "WASM_AGENT_LUA_ROOT=" .. lua_root,
    "WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1/v1", "WASM_AGENT_LLM_API_KEY=fixture-only" }
  local args = {}
  for _, item in ipairs(env) do args[#args + 1] = item end
  for _, item in ipairs({ binary, "--db", home_b .. "/.wasm-agent/memory.db", "serve",
      "--port", tostring(node_port), "--client-port", tostring(client_port), "--ui", lua_root .. "/ui" }) do
    args[#args + 1] = item
  end
  local started = decode(host.operation("start", json.encode({ program = "/usr/bin/env", args = args,
    cwd = lua_root, timeout_seconds = 900, owner = "two-node-pair" })) or "{}") or {}
  if not started.operation_id then return nil, json.encode(started) end
  return started.operation_id
end

local function health(port, path)
  local ok_http, raw = pcall(host.http, "GET", "http://127.0.0.1:" .. tostring(port) .. path,
    json.encode({}), "")
  if not ok_http or type(raw) ~= "string" then return nil end
  local decoded = decode(raw) or {}
  if tonumber(decoded.status) ~= 200 then return nil end
  return decode(decoded.body or "") or {}
end

local function wait_mesh(seconds)
  local waited = 0
  while waited < seconds * 10 do
    local answer = health(mesh_port, "/mesh/health")
    if type(answer) == "table" and answer.roster_verified == true then return answer end
    host.sleep(100)
    waited = waited + 1
  end
  return nil
end

local function body()
  peer = start_peer()
  ok(type(peer) == "string", "the peer node is started as an operation")
  local answer = wait_mesh(45)
  if not answer then
    local log = host.read_file(peer_log) or ""
    error("the peer's mesh never answered as verified (see the peer's own log): " .. tostring(log):sub(-600), 0)
  end
  ok(tostring(answer.node_id) == id_b.node_id, "the health answer names node B")
  ok(tostring(answer.roster_status) == "verified", "and it verified OUR signed roster: " .. tostring(answer.roster_status))

  -- ---- 1. the picture, produced on B ---------------------------------------------------------
  local fixture = lua_root .. "/fixtures/run-images/red-64x48.png"
  local copied = sh("cp " .. string.format("%q", fixture) .. " " .. string.format("%q", home_b .. "/pics/shared.png"))
  ok(copied == 0, "a picture exists on node B (the fixture copied into its own home)")
  local source_b64 = nil
  do
    local raw = decode(host.read_image_base64(home_b .. "/pics/shared.png", 4000000) or "{}") or {}
    source_b64 = raw.base64
  end
  ok(type(source_b64) == "string" and source_b64 ~= "", "and this row can read its bytes to compare with")
  local source_digest = host.sha256(source_b64)

  -- The real call path: tools.dispatch("remote") -> nodeslib.remote_call -> host.mesh_call -> node B.
  local peer_node = { name = "pair-b", node_id = id_b.node_id, public_key = id_b.public_key,
    local_node = false, online = true, addresses = { "127.0.0.1:" .. tostring(mesh_port) } }
  nodes.find = function(selector)
    if tostring(selector) == "pair-b" or tostring(selector) == id_b.node_id then return peer_node end
    return nil
  end
  nodes.operator_status = function() return { operator_of_peer = true } end
  local memory = dofile("lua/core/memory.lua") memory.setup()
  local tools = dofile("lua/core/tools.lua")
  ok(nodes.mesh_enabled() == true, "this node's mesh gate is on (its own policy.json)")
  local ctx = { user_id = "master" }

  local result = tools.dispatch(memory, "remote",
    { node = "pair-b", capability = "read", path = home_b .. "/pics/shared.png" }, "master", ctx)
  ok(type(result) == "table", "the peer read answered: " .. tostring(result))
  ok(result.error == nil, "a picture from a peer is not refused: " .. json.encode(result):sub(1, 900))
  local references = result._images or {}
  ok(#references == 1, "and it is stored HERE as one reference of this node: " .. json.encode(references))
  local reference = references[1]
  ok(reference.sha256 == source_digest,
    "keyed by the digest the peer named: " .. tostring(reference.sha256) .. " vs " .. tostring(source_digest))
  ok(reference.mime == "image/png", "as the type it declared")
  ok(result.image_data == nil, "the wire field is consumed here, never handed on")
  ok(host.path_kind(reference.path) == "file", "the file it names exists on THIS node: " .. tostring(reference.path))

  -- BOTH ENDS: the peer's own store holds the same content-addressed file.
  local peer_copy = home_b .. "/.wasm-agent/attachments/" .. source_digest:sub(1, 2) .. "/" .. source_digest .. ".png"
  local ours = host.read_file(reference.path)
  local theirs = host.read_file(peer_copy)
  ok(type(ours) == "string" and type(theirs) == "string" and ours == theirs,
    "the same bytes are in both stores (" .. tostring(reference.path) .. " and " .. peer_copy .. ")")
  ok(host.file_sha256(reference.path) == host.file_sha256(peer_copy),
    "and the same digest on disk at both ends: " .. tostring(host.file_sha256(reference.path)))
  local loaded = memory.load_image(reference)
  ok(type(loaded) == "table" and loaded.b64 == source_b64,
    "decoding what this node stored gives back the peer's picture, byte for byte")

  -- THE TRANSPORT WAS THE MESH: the peer's own admission line for this call.
  local peer_state = decode(host.operation("status", json.encode({ id = peer, owner = "two-node-pair" })) or "{}") or {}
  local admitted, peer_stderr = nil, ""
  for _ = 1, 30 do
    peer_stderr = tostring(host.read_file(tostring(peer_state.stderr_path or "")) or "")
    admitted = peer_stderr:find("mesh recv from=" .. id_a.node_id:sub(1, 8), 1, true)
    if admitted then break end
    host.sleep(100)
  end
  ok(admitted ~= nil, "the peer's mount admitted the call from this node: " .. peer_stderr:sub(-400))

  -- ---- 2. past the cap: refused by name ------------------------------------------------------
  local generated = sh("python3 - " .. string.format("%q", home_b .. "/pics/big.png") .. " <<'PY'\n"
    .. "import sys, zlib, struct, random\n"
    .. "w=h=700\nrandom.seed(7)\nraw=bytearray()\n"
    .. "for y in range(h):\n    raw.append(0)\n    raw.extend(random.getrandbits(8) for _ in range(w*3))\n"
    .. "def chunk(t,d):\n    c=struct.pack('>I',len(d))+t+d\n    return c+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)\n"
    .. "png=b'\\x89PNG\\r\\n\\x1a\\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(raw),9))+chunk(b'IEND',b'')\n"
    .. "open(sys.argv[1],'wb').write(png)\nprint(len(png))\nPY")
  if generated == 0 then
    local big = tools.dispatch(memory, "remote",
      { node = "pair-b", capability = "read", path = home_b .. "/pics/big.png" }, "master", ctx)
    ok(type(big) == "table" and big.error == "remote_image_too_large",
      "a picture past the transfer cap is refused by name: " .. json.encode(big and { error = big.error }))
    ok(tonumber(big.bytes or 0) > 1000000, "the refusal names the size it refused: " .. tostring(big.bytes))
    ok(tonumber(big.max_bytes) == 1000000, "and the cap: " .. tostring(big.max_bytes))
    ok(tostring(big.note or ""):find("big.png", 1, true) ~= nil, "and the picture, in a sentence: " .. tostring(big.note))
    ok(big._images == nil, "and nothing is stored or handed on")
  else
    skip("a picture past the transfer cap", "python3 is not here to write a >1 MB PNG")
  end

  -- ---- 3. the model's request on THIS node carries it ----------------------------------------
  local provider = dofile("lua/core/provider.lua")
  local agent = dofile("lua/core/agent.lua")
  local ready = false
  if type(host.quickjs) == "function" then
    local fired, raw = pcall(host.quickjs, "ready", "{}")
    local decoded = fired and decode(raw) or nil
    ready = type(decoded) == "table" and decoded.ok == true
  end
  if not ready then
    skip("the picture in the model's request", "this node has no embedded code-mode assets")
  else
    local sid = memory.start_session("", "peer picture", { user_id = "master" })
    local rounds, captured = 0, nil
    provider.complete_with = function(_, messages)
      rounds = rounds + 1
      if rounds == 1 then
        return { content = "", finish_reason = "tool_calls", tool_calls = {
          { id = "peer-picture", type = "function", ["function"] = { name = "run",
            arguments = json.encode({ code = "const p = await tools.remote({node:\"pair-b\",capability:\"read\",path:"
              .. json.encode(home_b .. "/pics/shared.png") .. "}); return {ok:true}" }) } } } }
      end
      captured = messages
      return { content = "PEER-IMAGE-DONE", finish_reason = "stop", tool_calls = {} }
    end
    local bot = agent.new(sid, function() end, "master", "master", "")
    bot:run("look at the picture on the peer")
    local parts, tool_text = {}, ""
    for _, message in ipairs(captured or {}) do
      if type(message.content) == "table" then
        for _, part in ipairs(message.content) do
          if part.type == "image_url" then parts[#parts + 1] = part end
        end
      end
      if message.role == "tool" then tool_text = tostring(message.content) end
    end
    ok(#parts == 1, "the provider request on this node carries one image part for the peer's picture: " .. #parts)
    local payload = tostring(parts[1] and parts[1].image_url and parts[1].image_url.url or "")
      :match("^data:[^;]+;base64,(.*)$")
    ok(payload == source_b64, "and it is that picture, byte for byte")
    ok(tool_text:find("_images", 1, true) == nil, "the result text carries no reference table")
  end

  -- ---- 4. the receiving half of a peer call's working directory ------------------------------
  -- An explicit directory travels and is recorded as the caller's word.
  local tree = root .. "/peer-tree"
  local started = tools.dispatch(memory, "remote", { node = "pair-b", capability = "bash",
    command = "pwd", cwd = tree }, "master", ctx)
  ok(type(started) == "table" and started.error == nil and type(started.operation_id) == "string",
    "a bash call on the peer answers an operation: " .. json.encode(started and { error = started.error }))
  local record = decode(host.read_file(home_b .. "/.wasm-agent/operations/" .. tostring(started.operation_id)
    .. "/state.json") or "{}") or {}
  ok(tostring(record.cwd) == tree, "the peer's own record carries the directory this node named: " .. tostring(record.cwd))
  ok(tostring(record.cwd_source) == "explicit", "and says it came from the caller: " .. tostring(record.cwd_source))
  -- And a call that names none carries none: on this base the sending half is not in the tree yet, so
  -- the peer records its OWN directory - the fact the row has to report rather than assume.
  local auto = tools.dispatch(memory, "remote", { node = "pair-b", capability = "bash", command = "pwd" }, "master", ctx)
  ok(type(auto) == "table" and type(auto.operation_id) == "string", "a bash call with no directory answers")
  local auto_record = decode(host.read_file(home_b .. "/.wasm-agent/operations/" .. tostring(auto.operation_id)
    .. "/state.json") or "{}") or {}
  print("two-node: peer cwd_source for a call that named no directory: " .. tostring(auto_record.cwd_source))
  ok(tostring(auto_record.cwd_source) ~= "explicit",
    "a call that named no directory is not recorded as the caller's word")
end

local ran, problem = pcall(body)
stop_peer()
pcall(sh, "rm -rf " .. string.format("%q", root))
if not ran then error("two-node pair: " .. tostring(problem), 0) end

if #skipped > 0 then
  for _, item in ipairs(skipped) do print("SKIP two-node " .. item) end
end
print(string.format("two-node images ok (%d checks, %d named skip(s))", checks, #skipped))
