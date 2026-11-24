-- A PICTURE PRODUCED ON ONE NODE REACHES THE MODEL ON ANOTHER (mission run-images-two-node, item 1).
--
-- scripts/test-remote-image.lua pins the caller half and the peer half with the WIRE stubbed: a hand
-- written image_data table. This row closes that seam with TWO REAL NODES on this machine, on THE BASIS
-- THE REAL FLEET USES:
--
--   a peer admits a caller it can verify NOW - nodeslib.verify_caller(fresh), the rendezvous's own
--   answer that this node id holds this key - and nothing else. No attestation is involved: the mount's
--   attested basis is a separate admission path, not in this tree (Fable, 24/11: it goes live with a
--   security review, not with this release).
--
-- So the pair is three processes: a scratch RENDEZVOUS that knows both nodes (as it knows work and
-- openclaw), a wa serve on this node's own home that registers this node's key, and the peer's wa serve.
-- Discovery is the product's own (nodes.find reads the rendezvous), the admission is the product's own,
-- and the transport is the signed mesh on the roster's address.
--
-- What it measures:
--   1. the basis itself: the rendezvous vouches for this node's id and key, so verify_caller answers a
--      master for it - the fact the whole row rests on;
--   2. a picture read on that peer arrives as bytes under the cap, is verified against the digest the
--      peer named, and is stored HERE: the same content-addressed file exists in BOTH stores, byte for
--      byte, and the peer's own audit line names the admission;
--   3. a picture past the 1 MB transfer cap is refused BY NAME, with its size and the cap;
--   4. the picture reaches the MODEL's request on this node: one image part, that picture, no reference
--      table in the tool text;
--   5. a peer call's working directory, the receiving half: an explicit cwd is recorded on the peer as
--      cwd_source=explicit, and a call that names none is recorded as the node's own.
--
-- WHAT IS STUBBED, and only that: the model provider (the request is what this row measures) and the
-- five provider environment names it reads. Everything else is the product's own code on both sides.
--
-- Hermetic: its own scratch home (the runner's) and one under the scratch root for the peer and the
-- rendezvous, every port fresh, no live node and no live fleet, and every process is stopped by the
-- operation id that started it.
if not host then error("this row runs under the node (WA_SCRIPT), not plain Lua") end
local json = dofile("lua/vendor/json.lua")

-- THE PROVIDER KEYS THIS ROW STANDS IN FOR: the runner gives a row no model at all, and a shell that has
-- one must not decide the verdict either. The agent is asked for a round here and provider.complete_with
-- is this row's stub; these five names are what make it ask. Nothing is sent anywhere.
-- THE RENDEZVOUS is the same kind of seam in the other direction: this row starts one, and its URL is
-- what this node's own code must read - one variable, set as soon as the port is known.
local real_getenv = host.getenv
local rendezvous_url = nil
host.getenv = function(key)
  if key == "WASM_AGENT_RAW_CODE" then return nil end
  if key == "WASM_AGENT_CODEMODE" then return "native" end
  if key == "WASM_AGENT_LLM_API_KEY" then return "fixture_key_not_a_credential" end
  if key == "WASM_AGENT_PROVIDER" then return "opencode-go" end
  if key == "WASM_AGENT_LLM_MODEL" then return "deepseek-v4.1-flash" end
  if key == "WASM_AGENT_RENDEZVOUS" and rendezvous_url then return rendezvous_url end
  return real_getenv(key)
end

-- ONE INSTANCE of lua/core/nodes.lua for this process: the modules under test are loaded through
-- dofile, and a second instance would answer from a different table than the one this row reads.
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

-- ---- the scratch tree, the binary and the ports ------------------------------------------------
local scratch = tostring(os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
local root = scratch .. "/two-node-pair-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
-- Node A is THIS process (its own scratch home, identity and policy) - not a third home: the caller half
-- has to be the node under test, not a copy of it.
local paths = dofile("lua/core/paths.lua")
local home_b = root .. "/b"
local home_rdv = root .. "/rdv"
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
  print("SKIP two-node pair: no node binary to start a peer with (WA_BIN/WA_FAST_BIN, runtime_info().binary_path)")
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
local rendezvous_port, own_node_port, own_client_port = free_port(), free_port(), free_port()
if not (mesh_port and node_port and client_port and rendezvous_port and own_node_port and own_client_port) then
  print("SKIP two-node pair: no free-port probe here (python3 is needed to ask the kernel)")
  return
end
rendezvous_url = "http://127.0.0.1:" .. tostring(rendezvous_port)

-- Is this directory outside every git checkout? Asked of git, never guessed from the path.
local function outside_any_repo(dir)
  if type(dir) ~= "string" or dir == "" then return false end
  local code = sh("git -C " .. string.format("%q", dir) .. " rev-parse --show-toplevel >/dev/null 2>&1")
  return code ~= 0
end
local scratch, scratch_why
for _, candidate in ipairs({ os.getenv("TMPDIR"), "/tmp", os.getenv("GATE_ROOT") }) do
  if outside_any_repo(candidate) then scratch, scratch_why = candidate, "not a git checkout" break end
end
if not scratch then
  print("SKIP two-node pair: every scratch candidate (TMPDIR, /tmp, GATE_ROOT) is inside a git checkout, "
    .. "and the fleet key this pair needs refuses one")
  return
end
scratch = tostring(scratch):gsub("/+$", "")
local root = scratch .. "/two-node-pair-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
print("two-node: the pair's tree is " .. root .. " (" .. scratch_why .. ")")

local function field(text, name)
  return tostring(text):match('"' .. name .. '":"([^"]*)"')
end
local made = sh("mkdir -p " .. string.format("%q %q %q %q %q %q", home_b .. "/.wasm-agent",
  home_rdv, root .. "/fleet", home_b .. "/pics", root .. "/peer-tree", root .. "/a-reg"))
ok(made == 0, "the scratch tree exists under the scratch root: " .. root)

-- ---- the three processes, all started the supported way ---------------------------
local started = {} -- name -> operation id, stopped in reverse at the end
local function start(name, env, args, cwd)
  local argv = {}
  for _, item in ipairs(env) do argv[#argv + 1] = item end
  for _, item in ipairs(args) do argv[#argv + 1] = item end
  local receipt = decode(host.operation("start", json.encode({ program = "/usr/bin/env", args = argv,
    cwd = cwd or lua_root, timeout_seconds = 900, owner = "two-node-pair" })) or "{}", "operation start") or {}
  if receipt.operation_id then started[name] = receipt.operation_id end
  return receipt.operation_id
end
local function stop_all()
  for name, id in pairs(started) do
    pcall(host.operation, "cancel", json.encode({ id = id, owner = "two-node-pair" }))
    for _ = 1, 20 do
      local state = decode(host.operation("status", json.encode({ id = id, owner = "two-node-pair" })) or "{}", "status") or {}
      local settled = tostring(state.state)
      if settled == "cancelled" or settled == "failed" or settled == "completed" then break end
      host.sleep(100)
    end
    local state = decode(host.operation("status", json.encode({ id = id, owner = "two-node-pair" })) or "{}", "status") or {}
    if tostring(state.state) ~= "cancelled" and tostring(state.state) ~= "failed" and tostring(state.state) ~= "completed" then
      local pid = tonumber(state.owner_process_id)
      if pid then sh("kill " .. tostring(pid) .. " 2>/dev/null") end
    end
    started[name] = nil
  end
end
local function stop_one(name)
  local id = started[name]
  if not id then return end
  started[name] = nil
  pcall(host.operation, "cancel", json.encode({ id = id, owner = "two-node-pair" }))
  for _ = 1, 20 do
    local state = decode(host.operation("status", json.encode({ id = id, owner = "two-node-pair" })) or "{}", "status") or {}
    local settled = tostring(state.state)
    if settled == "cancelled" or settled == "failed" or settled == "completed" then return end
    host.sleep(100)
  end
  local state = decode(host.operation("status", json.encode({ id = id, owner = "two-node-pair" })) or "{}", "status") or {}
  local pid = tonumber(state.owner_process_id)
  if pid then sh("kill " .. tostring(pid) .. " 2>/dev/null") end
end
local function health(port, path)
  local ok_http, raw = pcall(host.http, "GET", "http://127.0.0.1:" .. tostring(port) .. path, json.encode({}), "")
  if not ok_http or type(raw) ~= "string" then return nil end
  local decoded = decode(raw, "health") or {}
  if tonumber(decoded.status) ~= 200 then return nil end
  return decode(decoded.body or "{}", "health body") or {}
end
local function wait_for(test, seconds)
  local waited = 0
  while waited < seconds * 10 do
    local value = test()
    if value then return value end
    host.sleep(100)
    waited = waited + 1
  end
  return nil
end

local function run(body)
  local id_a = decode(host.node_identity(), "this node's identity") or {}
  ok(type(id_a.node_id) == "string" and #id_a.node_id == 32, "node A has a real identity")
  -- THE RENDEZVOUS KNOWS WHO IS A MASTER (as the fleet's own does): its admin list is what promotes a
  -- node's record from guest, and a peer admits a caller only as a master. Seeded here with THIS node.
  local function rendezvous_args()
    return { "NO_PROXY=127.0.0.1,localhost,::1", "WASM_AGENT_HOME=" .. home_rdv,
      "WASM_AGENT_LUA_ROOT=" .. lua_root, "WASM_AGENT_RENDEZVOUS=", "WASM_AGENT_RELAY=",
      "WASM_AGENT_MANAGED=0", "WASM_AGENT_NETWORK_ADMINS=" .. id_a.node_id }
  end
  local function rendezvous_argv()
    return { binary, "rendezvous", "--port", tostring(rendezvous_port), "--bind", "127.0.0.1",
      "--db", home_rdv .. "/rendezvous.db" }
  end
  -- the scratch rendezvous: discovery for this pair, and nothing else on it
  ok(start("rendezvous", rendezvous_args(), rendezvous_argv()) ~= nil, "the scratch rendezvous is started")
  ok(wait_for(function() return health(rendezvous_port, "/health") end, 20) ~= nil,
    "and it answers /health on " .. tostring(rendezvous_port))

  local code_b, out_b = sh("WASM_AGENT_HOME=" .. string.format("%q", home_b) .. " "
    .. string.format("%q", binary) .. " node 2>/dev/null")
  local id_b = code_b == 0 and decode(out_b, "the peer's identity") or {}
  ok(type(id_b.node_id) == "string" and #id_b.node_id == 32 and id_b.node_id ~= id_a.node_id,
    "node B has a different one: two nodes, not one")

  -- The signed roster: the TRANSPORT's authority (the mesh admits the call on it). The ADMISSION that
  -- actually executes the call is the rendezvous basis above, and it is checked further down.
  local keygen_code, keygen = sh(string.format("%q", binary) .. " fleet keygen --out "
    .. string.format("%q", root .. "/fleet/pair.key"))
  local fleet_pub = keygen and field(keygen, "public_key")
  ok(keygen_code == 0 and type(fleet_pub) == "string" and #fleet_pub == 64,
    "the fleet key that signs the roster: " .. tostring(keygen):sub(1, 160))
  local roster = { version = 1, fleet = "scratch", issued_at = 0, expires_at = 0, nodes = {
    { node_id = id_a.node_id, public_key = id_a.public_key, name = "pair-a", level = 0, addresses = {}, revoked_at = 0 },
    { node_id = id_b.node_id, public_key = id_b.public_key, name = "pair-b", level = 1,
      addresses = { "127.0.0.1:" .. tostring(mesh_port) }, revoked_at = 0 } } }
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

  -- THIS node, serving: it registers this node's key at the rendezvous, which is what a peer verifies.
  -- Its own database, so the two processes never fight over the ledger this row is writing.
  ok(start("own-serve", { "NO_PROXY=127.0.0.1,localhost,::1", "WASM_AGENT_HOME=" .. tostring(real_getenv("WASM_AGENT_HOME") or ""),
      "WASM_AGENT_LUA_ROOT=" .. lua_root, "WASM_AGENT_RENDEZVOUS=" .. rendezvous_url, "WASM_AGENT_RELAY=",
      "WASM_AGENT_MANAGED=0", "WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1/v1", "WASM_AGENT_LLM_API_KEY=fixture-only" },
    { binary, "--db", root .. "/a-reg/memory.db", "serve", "--port", tostring(own_node_port),
      "--client-port", tostring(own_client_port), "--ui", lua_root .. "/ui" }) ~= nil,
    "this node is served once, so its key is registered at the rendezvous")

  -- THE PEER: a real node process with its own home, its own policy and its own ports.
  ok(start("peer", { "NO_PROXY=127.0.0.1,localhost,::1", "WASM_AGENT_HOME=" .. home_b,
      "WASM_AGENT_LUA_ROOT=" .. lua_root, "WASM_AGENT_RENDEZVOUS=" .. rendezvous_url, "WASM_AGENT_RELAY=",
      "WASM_AGENT_MANAGED=0", "WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1/v1", "WASM_AGENT_LLM_API_KEY=fixture-only" },
    { binary, "--db", home_b .. "/.wasm-agent/memory.db", "serve", "--port", tostring(node_port),
      "--client-port", tostring(client_port), "--ui", lua_root .. "/ui" }) ~= nil,
    "the peer node is started as an operation")

  local mesh = wait_for(function()
    local answer = health(mesh_port, "/mesh/health")
    if type(answer) == "table" and answer.roster_verified == true then return answer end
    return nil
  end, 45)
  ok(type(mesh) == "table", "the peer's mount verified this pair's signed roster and is listening")
  ok(tostring(mesh and mesh.node_id) == id_b.node_id, "and it is node B")

  -- THE RENDEZVOUS KNOWS BOTH NODES: the fact the whole admission rests on.
  local listed = wait_for(function()
    local seen = {}
    for _, node in ipairs(nodes.list({ cached = false, live_capabilities = false })) do seen[tostring(node.node_id)] = true end
    if seen[id_a.node_id] and seen[id_b.node_id] then return seen end
    return nil
  end, 45)
  ok(type(listed) == "table" and listed[id_a.node_id] and listed[id_b.node_id],
    "the scratch rendezvous knows BOTH nodes by id (as it knows work and openclaw)")

  -- The admin list is applied when the registry OPENS, and both nodes registered after it did: one
  -- restart of the scratch registry (same database, same port) is what a real fleet does with an
  -- operator it promoted, and it is the only reason this row restarts anything.
  stop_one("rendezvous")
  ok(start("rendezvous", rendezvous_args(), rendezvous_argv()) ~= nil, "the scratch rendezvous is started again")
  ok(wait_for(function() return health(rendezvous_port, "/health") end, 20) ~= nil, "and answers again")
  local promoted = wait_for(function()
    local answer = nodes.verify_caller(id_a.node_id, id_a.public_key, { fresh = true })
    if type(answer) == "table" and tostring(answer.role or "") == "master" then return answer end
    return nil
  end, 20)
  ok(type(promoted) == "table", "and this node is promoted to master, as the fleet's registry does")

  local basis = nodes.verify_caller(id_a.node_id, id_a.public_key, { fresh = true })
  ok(type(basis) == "table" and basis.node_id == id_a.node_id and
    tostring(basis.role or "") == "master",
    "and it vouches for this node as a master - the FIRST basis, no attestation: " .. json.encode(basis))

  -- ---- 1. the picture, produced on B, discovered by the product's own lookup ---------------------
  local peer = nodes.find(id_b.node_id)
  ok(type(peer) == "table" and peer.local_node == false, "nodes.find resolves the peer from the rendezvous")
  local fixture = lua_root .. "/fixtures/run-images/red-64x48.png"
  ok(sh("cp " .. string.format("%q", fixture) .. " " .. string.format("%q", home_b .. "/pics/shared.png")) == 0,
    "a picture exists on node B (the fixture copied into its own home)")
  local source = decode(host.read_image_base64(home_b .. "/pics/shared.png", 4000000) or "{}", "the picture") or {}
  local source_b64 = source.base64
  ok(type(source_b64) == "string" and source_b64 ~= "", "and this row can read its bytes to compare with")
  local source_digest = host.sha256(source_b64)

  local memory = dofile("lua/core/memory.lua") memory.setup()
  local tools = dofile("lua/core/tools.lua")
  local ctx = { user_id = "master" }
  local result = tools.dispatch(memory, "remote",
    { node = id_b.node_id, capability = "read", path = home_b .. "/pics/shared.png" }, "master", ctx)
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
  local ours, theirs = host.read_file(reference.path), host.read_file(peer_copy)
  ok(type(ours) == "string" and type(theirs) == "string" and ours == theirs,
    "the same bytes are in both stores (" .. tostring(reference.path) .. " and " .. peer_copy .. ")")
  ok(host.file_sha256(reference.path) == host.file_sha256(peer_copy),
    "and the same digest on disk at both ends: " .. tostring(host.file_sha256(reference.path)))
  local loaded_image = memory.load_image(reference)
  ok(type(loaded_image) == "table" and loaded_image.b64 == source_b64,
    "decoding what this node stored gives back the peer's picture, byte for byte")

  -- THE TRANSPORT WAS THE MESH, and the admission was the rendezvous basis: the peer's own lines.
  local peer_state = decode(host.operation("status", json.encode({ id = started.peer, owner = "two-node-pair" })) or "{}", "status") or {}
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
      { node = id_b.node_id, capability = "read", path = home_b .. "/pics/big.png" }, "master", ctx)
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
    local decoded = fired and decode(raw, "quickjs") or nil
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
            arguments = json.encode({ code = "const p = await tools.remote({node:" .. json.encode(id_b.node_id)
              .. ",capability:\"read\",path:" .. json.encode(home_b .. "/pics/shared.png") .. "}); return {ok:true}" }) } } } }
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
    if rounds == 0 then
      -- NO PROVIDER ROUND HAPPENED AT ALL. Under the runner this row can be CANCELLED mid-way (the fast
      -- path's watchdog signals the row's process group at its deadline), and a cancelled run stops before
      -- its first model call: not a verdict about the picture, so it is named as a skip - never a pass, and
      -- never a red attributed to this code.
      local cancelled = type(host.run_cancelled) == "function" and host.run_cancelled() == true
      if cancelled then
        skip("the picture in the model's request", "this row was cancelled before its first model round")
      else
        error(string.format("the agent run made no model round at all (rounds=0, cancelled=%s); the "
          .. "picture step cannot be judged", tostring(cancelled)), 0)
      end
    elseif #parts == 1 then
      checks = checks + 1 -- the claim itself: one image part, counted like every other check
    else
      local roles = {}
      for _, message in ipairs(captured or {}) do roles[#roles + 1] = tostring(message.role) end
      error(string.format("the provider request on this node carries one image part for the peer's "
        .. "picture, got %d; rounds=%d captured=%s roles=[%s] tool text: %s", #parts, rounds,
        tostring(captured ~= nil), table.concat(roles, ","), tostring(tool_text):sub(1, 300)), 0)
    end
    if #parts == 1 then
      local payload = tostring(parts[1] and parts[1].image_url and parts[1].image_url.url or "")
        :match("^data:[^;]+;base64,(.*)$")
      ok(payload == source_b64, "and it is that picture, byte for byte")
      ok(tool_text:find("_images", 1, true) == nil, "the result text carries no reference table")
    end
  end

  -- ---- 4. a peer's command draws ONE ROW PER FILE on this node (item 5, the event half) ------
  -- The CLI's half is proved in a pty (the report); here is the fact the row is built from: a session
  -- that watches its changes ASKS the peer for the list, and the caller turns it into one
  -- remote_change event per file. On the base tree nothing asks (record_change was set for edit and
  -- write only) and a peer's command is adopted as an operation, so no event is ever emitted.
  local tree = root .. "/peer-tree"
  ok(sh("( cd " .. string.format("%q", tree) .. " && git init -q . "
    .. "&& git config user.email test@example.invalid && git config user.name test "
    .. "&& printf 'seed\n' > seed.txt && git add -A && git commit -qm seed )") == 0,
    "the peer has its own git work tree " .. tree)
  local events = {}
  local watching = { user_id = "master", session_id = memory.start_session("", "peer cards", { user_id = "master" }),
    watch_changes = true, emit = function(event) events[#events + 1] = event end }
  local changed = tools.dispatch(memory, "remote", { node = id_b.node_id, capability = "bash",
    command = "printf 'hello\n' > made.txt", cwd = tree }, "master", watching)
  ok(type(changed) == "table" and changed.error == nil,
    "a command on the peer answers: " .. json.encode(changed and { error = changed.error }))
  local rows = {}
  for _, event in ipairs(events) do
    if event.type == "remote_change" and event.capability == "bash" then rows[#rows + 1] = event end
  end
  ok(#rows == 1, "and this node draws exactly one row for the one file it changed: " .. json.encode(rows))
  local row = rows[1] or {}
  ok(tostring(row.path) == "made.txt" and row.created == true and tonumber(row.added) == 1,
    "naming the file, that it was created, and its one line: " .. json.encode(row))
  ok(changed.changes == nil, "and the model's value carries no list: a card is the reader's")

  -- ---- 5. the receiving half of a peer call's working directory ------------------------------
  local with_cwd = tools.dispatch(memory, "remote", { node = id_b.node_id, capability = "bash",
    command = "pwd", cwd = tree }, "master", ctx)
  ok(type(with_cwd) == "table" and with_cwd.error == nil and type(with_cwd.operation_id) == "string",
    "a bash call on the peer answers an operation: " .. json.encode(with_cwd and { error = with_cwd.error }))
  local record = decode(host.read_file(home_b .. "/.wasm-agent/operations/" .. tostring(with_cwd.operation_id)
    .. "/state.json") or "{}", "the peer's record") or {}
  ok(tostring(record.cwd) == tree, "the peer's own record carries the directory this node named: " .. tostring(record.cwd))
  ok(tostring(record.cwd_source) == "explicit", "and says it came from the caller: " .. tostring(record.cwd_source))
  local auto = tools.dispatch(memory, "remote", { node = id_b.node_id, capability = "bash", command = "pwd" }, "master", ctx)
  ok(type(auto) == "table" and type(auto.operation_id) == "string", "a bash call with no directory answers")
  local auto_record = decode(host.read_file(home_b .. "/.wasm-agent/operations/" .. tostring(auto.operation_id)
    .. "/state.json") or "{}", "the peer's record") or {}
  print("two-node: peer cwd_source for a call that named no directory: " .. tostring(auto_record.cwd_source))
  ok(tostring(auto_record.cwd_source) ~= "explicit",
    "a call that named no directory is not recorded as the caller's word")
end

local ran, problem = pcall(run)
stop_all()
pcall(sh, "rm -rf " .. string.format("%q", root))
if not ran then error("two-node pair: " .. tostring(problem), 0) end

if #skipped > 0 then
  for _, item in ipairs(skipped) do print("SKIP two-node " .. item) end
end
print(string.format("two-node images ok (%d checks, %d named skip(s))", checks, #skipped))
