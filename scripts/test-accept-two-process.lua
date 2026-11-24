-- A SLOW RELAY, TWO REAL PROCESSES: the master is told NOT KNOWN YET, reads the id's phases, and the
-- node ends on the commit. Mission fleet-update-survives-a-slow-relay (G), review item c.
--
-- Why this row exists in this shape: a wire seam proved with a stub is not proved. On 24/11
-- `wa update work --tree --commit 53bb69b1` answered {error:"remote_refused", reason:"relay_request_timeout"}
-- - the node REFUSING, in words - twice, while the node had refused nothing: it was 108 s into a request
-- the relay had already given up on (the node's own answer came 66 s later). The fixes were (a) the node
-- accepts in milliseconds and runs the rest detached (lua/core/accepted.lua, lua/core/remote_update.lua),
-- and (b) a deadline is reported as NOT KNOWN YET with the id, never as a refusal (lua/core/nodes.lua).
-- This row proves both END TO END, with the product's own code on both sides of a real socket:
--
--   THIS PROCESS is the master: a real `wa`, its own HOME, the real lua/core/nodes.lua remote_call, the
--   real signed body and the real relay loop, over real host.http to a real relay process.
--   A PEER is a real `wa serve` (its own HOME, its own ports) running the real remote_update.serve, whose
--   accept starts a real detached child (`wa update --accept <id>`) through the node's own operation
--   manager.
--   A RELAY is a real process on a real port that forwards the signed call to the peer and WITHHOLDS the
--   answer for longer than the master's deadline, then answers the relay's own 504 - the shape
--   rust/wa-rendezvous answers when the deadline passes.
--   DISCOVERY AND AUTHORITY are the product's own: a scratch `wa rendezvous` that knows both nodes, this
--   node promoted to master in it, and a signed roster for the pair.
--
-- What is stubbed, and only this: the peer's installer (a fixture `wa-sentinel` script that answers the
-- real preflight shape and performs a queued deploy by recording the commit its tree is on) and the tree's
-- origin (a real bare git repo two commits long). Nothing here builds anything or touches the operator's
-- node: two scratch HOMEs, fresh loopback ports, its own rendezvous, and every process stopped by the
-- operation id that started it.
--
--   WA_SCRIPT=scripts/test-accept-two-process.lua wa --db <scratch>/t.db
--
-- Prints `accept two process ok`; a failed check raises.
io.stdout:setvbuf("line")
if not host then error("this row runs under the node (WA_SCRIPT), not plain Lua") end
local json = dofile("lua/vendor/json.lua")

local ready_url = nil
local relay_url = nil
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_RENDEZVOUS" and ready_url then return ready_url end
  if key == "WASM_AGENT_RELAY" and relay_url then return relay_url end
  return real_getenv(key)
end

-- ONE INSTANCE of each module for this process: a second instance would answer from a different table.
local original_dofile = dofile
local nodes = original_dofile("lua/core/nodes.lua")
local remote_update = original_dofile("lua/core/remote_update.lua")
local loaded = { ["lua/core/nodes.lua"] = nodes, ["lua/core/remote_update.lua"] = remote_update }
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
local why = guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if why then error("this row refuses to run (" .. why .. ")") end

local checks = 0
local function ok(value, label, detail)
  checks = checks + 1
  if not value then error("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""), 2) end
  print("  ok: " .. label)
end
local function eq(got, want, label)
  ok(got == want, label, "got " .. tostring(got) .. ", want " .. tostring(want))
end

-- ---- the scratch tree, the binary and the ports ------------------------------------------------
local function sh(command, timeout)
  local raw = host.exec(command, "", timeout or 60, json.encode({ tool = "bash" }))
  local decoded = decode(raw or "{}") or {}
  return tonumber(decoded.code) or 1, tostring(decoded.stdout or ""), tostring(decoded.stderr or "")
end

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
  print("SKIP accept two process: every scratch candidate (TMPDIR, /tmp, GATE_ROOT) is inside a git checkout, and the fleet key this pair needs refuses one")
  return
end
scratch = tostring(scratch):gsub("/+$", "")
local root = scratch .. "/accept-pair-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local home_b = root .. "/b"
local home_rdv = root .. "/rdv"
local lua_root = host.getenv("WASM_AGENT_LUA_ROOT") or "."
lua_root = tostring(host.canonical_path(lua_root) or lua_root)
print("accept two process: the pair's tree is " .. root .. " (" .. tostring(scratch_why) .. ")")

local runtime = decode(host.runtime_info() or "{}") or {}
local binary = host.getenv("WA_FAST_BIN") or host.getenv("WA_TEST_BIN") or host.getenv("WA_BIN")
  or tostring(runtime.binary_path or "")
if binary == "" or not host.canonical_path(binary) then
  print("SKIP accept two process: no node binary to start a peer with (WA_BIN/WA_FAST_BIN, runtime_info().binary_path)")
  return
end

-- The node runtime the relay process runs on: the same resolver deploy.sh uses.
local function node_bin()
  local code, out = sh(". " .. string.format("%q", lua_root .. "/scripts/lib/node-runtime.sh")
    .. " >/dev/null 2>&1; wa_node_require 2>/dev/null")
  local path = tostring(out or ""):gsub("%s+$", ""):gsub("^%s+", "")
  return code == 0 and path ~= "" and path or nil
end
local node_program = node_bin()

local function free_port()
  local code, out = sh("python3 -c 'import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()'")
  local port = code == 0 and tonumber((tostring(out):gsub("%s", ""))) or nil
  if not port or port == 8799 then return nil end
  return port
end
local rdv_port, node_port, client_port, relay_port = free_port(), free_port(), free_port(), free_port()
local own_node_port, own_client_port = free_port(), free_port()
if not (rdv_port and node_port and client_port and relay_port and own_node_port and own_client_port) then
  print("SKIP accept two process: no free-port probe here (python3 is needed to ask the kernel)")
  return
end
ready_url = "http://127.0.0.1:" .. tostring(rdv_port)
relay_url = "http://127.0.0.1:" .. tostring(relay_port)

-- ---- the processes, all started the supported way ----------------------------------------------
local started = {}
local function start(name, env, args, cwd)
  local argv = {}
  for _, item in ipairs(env) do argv[#argv + 1] = item end
  for _, item in ipairs(args) do argv[#argv + 1] = item end
  local receipt = decode(host.operation("start", json.encode({ program = "/usr/bin/env", args = argv,
    cwd = cwd or lua_root, timeout_seconds = 900, owner = "accept-pair" })) or "{}", "operation start") or {}
  if receipt.operation_id then started[name] = receipt.operation_id end
  return receipt.operation_id
end
local function stop_all()
  for name, id in pairs(started) do
    pcall(host.operation, "cancel", json.encode({ id = id, owner = "accept-pair" }))
    for _ = 1, 20 do
      local state = decode(host.operation("status", json.encode({ id = id, owner = "accept-pair" })) or "{}", "status") or {}
      local settled = tostring(state.state)
      if settled == "cancelled" or settled == "failed" or settled == "completed" then break end
      host.sleep(100)
    end
    local state = decode(host.operation("status", json.encode({ id = id, owner = "accept-pair" })) or "{}", "status") or {}
    if tostring(state.state) ~= "cancelled" and tostring(state.state) ~= "failed" and tostring(state.state) ~= "completed" then
      local pid = tonumber(state.owner_process_id)
      if pid then sh("kill " .. tostring(pid) .. " 2>/dev/null") end
    end
    started[name] = nil
  end
end
local function health(port)
  local answered, raw = pcall(host.http, "GET", "http://127.0.0.1:" .. tostring(port) .. "/health", json.encode({}), "")
  if not answered or type(raw) ~= "string" then return nil end
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
local function field(text, name) return tostring(text):match('"' .. name .. '":"([^"]*)"') end
local function read_ok(path)
  local value = host.read_file(path)
  return type(value) == "string" and value or ""
end
local function listing(dir)
  local _, out = sh("ls -1 " .. string.format("%q", dir) .. " 2>/dev/null")
  local names = {}
  for line in tostring(out):gmatch("[^\r\n]+") do names[#names + 1] = line end
  return names
end

ok(sh("mkdir -p " .. string.format("%q %q %q %q %q %q", home_b .. "/.wasm-agent", home_rdv,
  root .. "/fleet", root .. "/b/install", root .. "/b/tree", root .. "/b/config")) == 0,
  "the scratch tree exists under the scratch root")

-- ---- the tree the peer deploys, and the installer that performs it ------------------------------
-- A REAL two-commit repository: the peer's tree starts on BASE and the request names TARGET, so the
-- accept's prepare_tree has to fast-forward it for real, and the installer records the commit the tree is
-- actually on.
local base, target = nil, nil
do
  local origin = root .. "/origin.git"
  local work = root .. "/b/tree"
  local code, out = sh(table.concat({
    "set -e",
    "git init -q --bare " .. string.format("%q", origin),
    "git init -q " .. string.format("%q", work),
    "cd " .. string.format("%q", work),
    "git config user.email row@example.invalid",
    "git config user.name row",
    "printf 'one' > file.txt",
    "git add file.txt",
    "git -c commit.gpgsign=false commit -qm base",
    "git remote add origin " .. string.format("%q", origin),
    "git push -q origin HEAD:refs/heads/main",
    "git rev-parse HEAD",
    "printf 'two' > file.txt",
    "git add file.txt",
    "git -c commit.gpgsign=false commit -qm target",
    "git push -q origin HEAD:refs/heads/main",
    -- origin/main has to exist as a remote-tracking ref: the peer's prepare_tree fetches origin and then
    -- asks for origin/main, and a repository whose remote was only pushed to has FETCH_HEAD and no such
    -- ref (measured here: the accept refused origin_main_unavailable).
    "git fetch -q origin",
    "git rev-parse HEAD",
    "git reset -q --hard HEAD~1",
    "git fetch -q origin",
  }, "\n"))
  -- Asked of the repository itself, not parsed out of a script's output: two facts, two questions.
  local _, base_out = sh("git -C " .. string.format("%q", work) .. " rev-parse HEAD")
  local _, target_out = sh("git -C " .. string.format("%q", work) .. " rev-parse origin/main")
  base = tostring(base_out):gsub("%s", "")
  target = tostring(target_out):gsub("%s", "")
  ok(code == 0 and type(base) == "string" and #base == 40 and type(target) == "string" and #target == 40,
    "the peer's tree is a real repository two commits long (BASE " .. tostring(base):sub(1, 8)
      .. " -> TARGET " .. tostring(target):sub(1, 8) .. ")", tostring(out):sub(-300))
end

local install = root .. "/b/install"
local box = root .. "/b/config/sentinel"
local sentinel = install .. "/wa-sentinel"
do
  local script = table.concat({
    "#!/bin/sh",
    "# THE PEER'S INSTALLER, as a fixture: the two verbs this node's own code calls, in the shapes the real",
    "# wa-sentinel answers them (preflight: the JSON measured on a live node; request deploy: the line a",
    "# queued deploy prints). Performing a deploy here means recording the commit the tree is on, which is",
    "# what the real installer's installed.txt and done/ record say.",
    "set -u",
    "case \"$1\" in",
    "  preflight)",
    "    printf '%s' '{\"capabilities\":{\"atomic_deploy_dedupe\":true,\"health_free\":true},\"inventory_error\":null,\"inventory_verified\":true,\"ownership\":\"watcher_lifetime_lock\",\"pending_deploys\":[],\"schema\":1,\"stop_file\":false,\"watcher\":\"running\",\"watcher_pid\":4242}'",
    "    exit 0 ;;",
    "  request)",
    "    verb=\"$2\"",
    "    [ \"$verb\" = \"deploy\" ] || exit 2",
    "    id=\"$(date +%s)-$(cat /proc/sys/kernel/random/uuid | cut -c1-8)\"",
    "    mkdir -p \"$BOX/requests\" \"$BOX/done\"",
    "    printf '{\"verb\":\"deploy\",\"id\":\"%s\"}' \"$id\" > \"$BOX/requests/$id.json\"",
    "    at=\"$(git -C \"$TREE\" rev-parse HEAD 2>/dev/null)\"",
    "    printf 'commit=%s\\nbranch=main\\n' \"$at\" > \"$INSTALL/installed.txt\"",
    "    printf '{\"ok\":true,\"phase\":\"completed\",\"detail\":\"fixture deploy %s\"}' \"$at\" > \"$BOX/done/$id.json\"",
    "    echo \"  requested deploy: $BOX/requests/$id.json\"",
    "    exit 0 ;;",
    "esac",
    "exit 2",
  }, "\n")
  ok(host.write_file(sentinel, script) == true, "the peer's installer fixture is written")
  ok(sh("chmod +x " .. string.format("%q", sentinel)) == 0, "and it is executable")
  ok(host.write_file(install .. "/runtime-worktree.txt", root .. "/b/tree\n") == true,
    "the peer's runtime tree is recorded")
  ok(host.write_file(install .. "/installed.txt", "commit=" .. base .. "\nbranch=main\n") == true,
    "and its install record starts on BASE")
end

-- ---- identities, the scratch rendezvous, and the pair's signed roster ---------------------------
local own = decode(host.node_identity(), "this node's identity") or {}
ok(type(own.node_id) == "string" and #own.node_id == 32, "this node has a real identity")
local function rendezvous_args()
  return { "NO_PROXY=127.0.0.1,localhost,::1", "WASM_AGENT_HOME=" .. home_rdv,
    "WASM_AGENT_LUA_ROOT=" .. lua_root, "WASM_AGENT_RENDEZVOUS=", "WASM_AGENT_RELAY=",
    "WASM_AGENT_MANAGED=0", "WASM_AGENT_NETWORK_ADMINS=" .. own.node_id }
end
local function rendezvous_argv()
  return { binary, "rendezvous", "--port", tostring(rdv_port), "--bind", "127.0.0.1",
    "--db", home_rdv .. "/rendezvous.db" }
end
ok(start("rendezvous", rendezvous_args(), rendezvous_argv()) ~= nil, "the scratch rendezvous is started")
ok(wait_for(function() return health(rdv_port) end, 25) ~= nil,
  "and it answers /health on " .. tostring(rdv_port))

-- THE SAME HOME THE PEER SERVES FROM: `wa node` reads (and creates) the node's key where its own
-- WASM_AGENT_HOME says, and a key made in a different directory is a different node (measured here: the
-- rendezvous listed a peer whose id no `wa node` in this row knew).
local code_b, out_b = sh("WASM_AGENT_HOME=" .. string.format("%q", home_b) .. " "
  .. string.format("%q", binary) .. " node 2>/dev/null")
local id_b = code_b == 0 and decode(out_b, "the peer's identity") or {}
ok(type(id_b.node_id) == "string" and #id_b.node_id == 32 and id_b.node_id ~= own.node_id,
  "the peer has its own identity: two nodes, not one")

local keygen_code, keygen = sh(string.format("%q", binary) .. " fleet keygen --out "
  .. string.format("%q", root .. "/fleet/pair.key"))
local fleet_pub = keygen and field(keygen, "public_key")
ok(keygen_code == 0 and type(fleet_pub) == "string" and #fleet_pub == 64,
  "the fleet key that signs the roster: " .. tostring(keygen):sub(1, 120))
local roster = { version = 1, fleet = "scratch", issued_at = 0, expires_at = 0, nodes = {
  { node_id = own.node_id, public_key = own.public_key, name = "pair-master", level = 0, addresses = {}, revoked_at = 0 },
  { node_id = id_b.node_id, public_key = id_b.public_key, name = "pair-peer", level = 1,
    addresses = { "127.0.0.1:" .. tostring(node_port) }, revoked_at = 0 } } }
ok(host.write_file(root .. "/roster.json", json.encode(roster)) == true, "the roster is written")
local sign_code, sign_out = sh(string.format("%q", binary) .. " fleet sign " .. string.format("%q", root .. "/roster.json")
  .. " --key " .. string.format("%q", root .. "/fleet/pair.key") .. " --expires-days 1")
ok(sign_code == 0 and tostring(sign_out):find('"ok":true', 1, true) ~= nil,
  "the roster is signed: " .. tostring(sign_out):sub(1, 160))
local signed = read_ok(root .. "/roster.signed.json")
ok(#signed > 0, "the signed roster is on disk")
ok(host.write_file(home_b .. "/.wasm-agent/mesh-roster.json", signed) == true,
  "the peer holds the signed roster")

-- ---- this node serves once, so the rendezvous knows the key it will vouch for -------------------
ok(start("own-serve", { "NO_PROXY=127.0.0.1,localhost,::1",
    "WASM_AGENT_HOME=" .. tostring(real_getenv("WASM_AGENT_HOME") or ""), "WASM_AGENT_LUA_ROOT=" .. lua_root,
    "WASM_AGENT_RENDEZVOUS=" .. ready_url, "WASM_AGENT_RELAY=", "WASM_AGENT_MANAGED=0",
    "WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1/v1", "WASM_AGENT_LLM_API_KEY=fixture-only" },
  { binary, "--db", root .. "/a-reg/memory.db", "serve", "--port", tostring(own_node_port),
    "--client-port", tostring(own_client_port), "--ui", lua_root .. "/ui" }) ~= nil,
  "this node is served once, so its key is registered at the rendezvous")

-- The peer: a real node process, its own home, own ports, its installer fixture and its tree.
ok(start("peer", { "NO_PROXY=127.0.0.1,localhost,::1", "HOME=" .. home_b,
    "WASM_AGENT_HOME=" .. home_b, "WA_INSTALL_DIR=" .. install,
    "WA_SENTINEL_DIR=" .. box, "BOX=" .. box, "INSTALL=" .. install, "TREE=" .. root .. "/b/tree",
    "WASM_AGENT_LUA_ROOT=" .. lua_root, "WASM_AGENT_RENDEZVOUS=" .. ready_url, "WASM_AGENT_RELAY=",
    "WASM_AGENT_MANAGED=0", "WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1/v1",
    "WASM_AGENT_LLM_API_KEY=fixture-only" },
  { binary, "--db", home_b .. "/.wasm-agent/memory.db", "serve", "--port", tostring(node_port),
    "--client-port", tostring(client_port), "--ui", lua_root .. "/ui" }) ~= nil,
  "the peer is started as a real node process")

-- ---- the relay: a real process that withholds the answer past the deadline ----------------------
local hold_ms = 6000
do
  local script = table.concat({
    "import http from 'node:http';",
    "const [port, nodePort, holdMs] = process.argv.slice(2).map(Number);",
    "const answers = new Map();",
    "let heldOnce = false;",
    "const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(body); };",
    "http.createServer((req, res) => {",
    "  const chunks = [];",
    "  req.on('data', (c) => chunks.push(c));",
    "  req.on('end', async () => {",
    "    const body = Buffer.concat(chunks).toString('utf8');",
    "    if (!req.url.startsWith('/relay/send')) return send(res, 404, JSON.stringify({ error: 'not_found' }));",
    "    let envelope; try { envelope = JSON.parse(body); } catch { return send(res, 400, JSON.stringify({ error: 'bad_request' })); }",
    "    const rid = String(envelope.rid || '');",
    "    if (answers.has(rid)) return send(res, 200, answers.get(rid));",
    "    let asked = {}; try { asked = JSON.parse(envelope.body || '{}'); } catch {}",
    "    const inner = asked.args || {};",
    "    const forwarded = await new Promise((resolve) => {",
    "      const up = http.request({ host: '127.0.0.1', port: nodePort, path: envelope.path,",
    "        method: envelope.method || 'POST',",
    "        headers: Object.assign({}, envelope.headers || {}, { 'content-length': Buffer.byteLength(envelope.body || '') }) },",
    "        (r) => { const out = []; r.on('data', (c) => out.push(c));",
    "          r.on('end', () => resolve({ status: r.statusCode, body: Buffer.concat(out).toString('utf8') })); });",
    "      up.on('error', () => resolve({ status: 502, body: JSON.stringify({ error: 'node_unreachable' }) }));",
    "      up.end(envelope.body || '');",
    "    });",
    "    const stored = JSON.stringify({ ok: true, status: forwarded.status, body: forwarded.body });",
    "    answers.set(rid, stored);",
    "    // THE DEADLINE: a REQUEST is withheld past the master's deadline and answered with the relay's own",
    "    // 504, exactly as rust/wa-rendezvous answers it; every other call is answered at once, and a retry",
    "    // of the same rid re-fetches what the node really said.",
    "    // ONE hold for the row: the call whose deadline the master has to survive. A retry (or any",
    "    // later call) is answered at once, so the row can also show that the same id starts nothing.",
    "    if (String(inner.action || '') === 'request' && !heldOnce) {",
    "      heldOnce = true;",
    "      await new Promise((r) => setTimeout(r, holdMs));",
    "      return send(res, 200, JSON.stringify({ ok: true, status: 504, body: JSON.stringify({",
    "        error: 'relay_request_timeout', id: rid, budget_ms: holdMs,",
    "        hint: 'the call passed the deadline its caller was given; no late result will be delivered' }) }));",
    "    }",
    "    return send(res, 200, stored);",
    "  });",
    "}).listen(port, '127.0.0.1', () => console.log('relay ' + port + ' -> ' + nodePort + ' hold ' + holdMs));",
  }, "\n")
  ok(host.write_file(root .. "/relay.mjs", script) == true, "the relay's own process script is written")
  ok(type(node_program) == "string" and node_program ~= "",
    "the node runtime the relay runs on: " .. tostring(node_program))
  ok(start("relay", {}, { node_program, root .. "/relay.mjs", tostring(relay_port), tostring(node_port),
    tostring(hold_ms) }) ~= nil,
    "the relay is started as its own process on port " .. tostring(relay_port))
  local up = wait_for(function()
    local answered, raw = pcall(host.http, "POST", relay_url .. "/relay/send", json.encode({}),
      '{"rid":"probe","to":"x","path":"/nope","body":"{}"}')
    if not answered or type(raw) ~= "string" then return nil end
    return true
  end, 25)
  ok(up ~= nil, "and it answers on " .. relay_url)
end

-- ---- 1. discovery and authority, the product's own -------------------------------------------
-- The roster is read fresh: a cached read taken before the peer registered is a fact about the cache, not
-- about the fleet (lua/core/nodes.lua keeps peers for a short TTL and keeps KNOWN peers through a failed
-- read, so asking once is not asking).
local seen
ok(wait_for(function()
  nodes.invalidate()
  local listed = nodes.list({ cached = false, live_capabilities = false })
  local ids = {}
  for _, node in ipairs(type(listed) == "table" and listed or {}) do ids[tostring(node.node_id)] = true end
  seen = listed
  if ids[own.node_id] and ids[id_b.node_id] then return true end
  return nil
end, 45) ~= nil, "the rendezvous knows BOTH nodes (this one and the peer)",
  "this=" .. tostring(own.node_id) .. " peer=" .. tostring(id_b.node_id)
    .. " seen=" .. json.encode((function()
      local ids = {}
      for _, node in ipairs(seen or {}) do ids[#ids + 1] = tostring(node.node_id) end
      return ids
    end)()))
nodes.invalidate()
local peer_found = nodes.find(id_b.node_id)
ok(type(peer_found) == "table" and tostring(peer_found.node_id) == tostring(id_b.node_id),
  "and the product's own lookup resolves the peer by id", json.encode(peer_found or {}))
local promoted = wait_for(function()
  local answer = nodes.verify_caller(own.node_id, own.public_key, { fresh = true })
  if type(answer) == "table" and tostring(answer.role or "") == "master" then return answer end
  return nil
end, 40)
ok(promoted ~= nil, "and the rendezvous vouches for THIS node as a master: " .. json.encode(promoted or {}))

-- ---- 2. the request: the relay's deadline is NOT a refusal --------------------------------------
-- One attempt, so the call this row measures is ONE round trip and the deadline answer is the one the
-- master has to read correctly (a retry with the same rid would re-fetch the node's own answer, which is
-- the right behaviour and not what this check is about).
nodes.RELAY_ATTEMPTS = 1
local started_at = host.now()
local reply = remote_update.request(nodes.remote_call, id_b.node_id, { commit = target, mode = "tree",
  reason = "accept two process row", session = "session-pair" })
local waited = host.now() - started_at
ok(type(reply) == "table", "the master gets an answer at all", json.encode(reply or {}))
eq(reply.not_known_yet, true, "a relayed deadline is reported as NOT KNOWN YET")
eq(reply.refused, false, "and it is explicitly not a refusal")
eq(reply.state, "unknown", "the state says so too")
ok(waited * 1000 >= hold_ms, "the relay really withheld the answer past the deadline ("
  .. tostring(waited) .. " s)", "hold_ms=" .. tostring(hold_ms))
local request_id = tostring(reply.id or "")
ok(#request_id > 8, "the answer carries the id the request was sent under: " .. request_id)

-- ---- 3. the node ACCEPTED it, and said so by that id --------------------------------------------
local function phase_now()
  return remote_update.status(nodes.remote_call, id_b.node_id, { id = request_id })
end
local accepted = wait_for(function()
  local phase = phase_now()
  if type(phase) == "table" and (phase.state == "accepted" or phase.state == "running"
    or phase.state == "queued" or phase.state == "installed") then return phase end
  return nil
end, 60)
ok(accepted ~= nil, "the request reads back by the id the caller holds: " .. json.encode(phase_now() or {}))

-- ---- 4. the update still completes: accepted -> queued -> installed ------------------------------
local settled = nil
do
  local deadline = host.now() + 120
  local last = nil
  while host.now() < deadline do
    local phase = phase_now()
    if type(phase) == "table" then
      if tostring(phase.state) ~= last then
        io.stderr:write("phase: " .. tostring(phase.state) .. " " .. tostring(phase.detail or "") .. "\n")
        last = tostring(phase.state)
      end
      if phase.state == "installed" or phase.state == "failed" then settled = phase break end
    end
    host.sleep(1)
  end
end
ok(settled ~= nil, "the phase settles", json.encode(phase_now() or {}))
eq(tostring(settled and settled.state), "installed", "and it is INSTALLED, not accepted forever")
ok(tostring((settled or {}).installed_commit or ""):sub(1, 8) == tostring(target):sub(1, 8),
  "installed.txt names the commit that was asked for: " .. tostring((settled or {}).installed_commit):sub(1, 12))

-- ---- 5. ONE deploy, and the node is on the commit -----------------------------------------------
local tree_head = (select(2, sh("git -C " .. string.format("%q", root .. "/b/tree") .. " rev-parse HEAD")) or ""):gsub("%s", "")
eq(tree_head, target, "the peer's own tree is on the requested commit")
local requests = listing(box .. "/requests")
eq(#requests, 1, "exactly ONE deploy request exists on the peer (" .. table.concat(requests, ", ") .. ")")
local installed_text = read_ok(install .. "/installed.txt")
ok(installed_text:find("commit=" .. target, 1, true) ~= nil, "and its install record names that commit")

-- ---- 6. the same id again starts nothing (the accept is idempotent by request id) ---------------
local retried = remote_update.request(nodes.remote_call, id_b.node_id, { commit = target, mode = "tree",
  reason = "accept two process row", session = "session-pair", id = request_id })
ok(type(retried) == "table" and retried.ok == true and retried.already == true,
  "a retry with the same request id is answered from the record", json.encode(retried or {}))
eq(#listing(box .. "/requests"), 1, "and no second deploy request was written")

stop_all()
print(string.format("accept two process ok (%d checks): %d s of relay hold, one deploy, the peer on %s",
  checks, math.floor(hold_ms / 1000), tostring(target):sub(1, 8)))
