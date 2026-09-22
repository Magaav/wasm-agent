// Real HTTP workers + real SQLite: a Lua error must roll back its transaction, a
// second writer must wait for the first, and repeatedly spawning/retiring read
// workers (each with its own connection) must not stall the database.
//
//   node scripts/test-sqlite-lifecycle.cjs [wa]
//
// The fixture replaces wa_reply in a copied Lua tree; no model, operator home or
// installed source is used.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), http = require('node:http');
const assert = require('node:assert/strict'), { spawn } = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || path.join(repo, 'rust/target/release/wa' + (process.platform === 'win32' ? '.exe' : '')));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-sqlite-life-')), source = path.join(root, 'source');
fs.cpSync(path.join(repo, 'lua'), path.join(source, 'lua'), { recursive: true });
fs.appendFileSync(path.join(source, 'lua/core/server.lua'), `
-- Fixture-only override. Never installed.
local function tx_exec(sql)
  local value = json.decode(host.sql_exec(sql, "[]"))
  if value.error then error(value.error) end
  return value
end
local function tx_query(sql)
  local value = json.decode(host.sql_query(sql, "[]"))
  if value.error then error(value.error) end
  return value
end
tx_exec("CREATE TABLE IF NOT EXISTS life(k TEXT PRIMARY KEY)")
local tx_root = host.paths().config
local function tx_wait(name)
  local deadline = host.monotonic_ms() + 8000
  while not host.read_file(tx_root .. "/" .. name) do
    if host.monotonic_ms() > deadline then error("fixture barrier timeout: " .. name) end
    host.sleep(10)
  end
end
function wa_reply(body, session, node)
  local request = json.decode(body)
  if request.text == "error-in-transaction" then
    tx_exec("BEGIN IMMEDIATE")
    tx_exec("INSERT INTO life(k) VALUES('E')")
    error("fixture_error_after_begin")
  end
  if request.text == "read" then
    return json.encode({ rows = tx_query("SELECT k FROM life ORDER BY k") })
  end
  if request.text == "hold" then
    tx_exec("BEGIN IMMEDIATE")
    tx_exec("INSERT INTO life(k) VALUES('H')")
    assert(host.write_file(tx_root .. "/H-open", "yes"))
    tx_wait("H-release")
    tx_exec("COMMIT")
    return json.encode({ committed = true })
  end
  if request.text == "release" then
    assert(host.write_file(tx_root .. "/H-release", "yes"))
    return json.encode({ released = true })
  end
  local write_key = request.text:match("^writer:(%w+)$")
  if write_key then
    tx_exec("BEGIN IMMEDIATE")
    tx_exec("INSERT INTO life(k) VALUES('" .. write_key .. "')")
    tx_exec("COMMIT")
    return json.encode({ wrote = true, key = write_key })
  end
  return json.encode({ ok = true })
end
`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let child, log, checks = 0;
(async () => {
  try {
    const reserved = http.createServer();
    await new Promise((r) => reserved.listen(0, '127.0.0.1', r));
    const port = reserved.address().port;
    await new Promise((r) => reserved.close(r));
    const system = /^(PATH|PATHEXT|SYSTEMROOT|WINDIR|SYSTEMDRIVE|COMSPEC|TEMP|TMP)$/i;
    const env = {
      ...Object.fromEntries(Object.entries(process.env).filter(([key]) => system.test(key))),
      HOME: root, USERPROFILE: root, LOCALAPPDATA: path.join(root, 'LocalAppData'), APPDATA: path.join(root, 'AppData'),
      WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: source, WASM_AGENT_RENDEZVOUS: '', WASM_AGENT_RELAY: '',
      WASM_AGENT_MANAGED: '0', WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:1',
      WASM_AGENT_LLM_API_KEY: 'fixture-only', WASM_AGENT_LLM_MODEL: 'fixture',
      // Force read workers to spawn on demand and retire quickly, so the churn is real.
      WASM_AGENT_WORKERS_MAX: '4', WASM_AGENT_WORKERS_IDLE_SECONDS: '1',
    };
    log = fs.openSync(path.join(root, 'node.log'), 'a');
    child = spawn(wa, ['--db', path.join(root, '.wasm-agent/memory.db'), 'serve', '--port', String(port), '--client-port', '0', '--ui', path.join(repo, 'ui')], { env, stdio: ['ignore', log, log], windowsHide: true });
    const base = 'http://127.0.0.1:' + port;
    async function until(fn, label) { const end = Date.now() + 12000; while (Date.now() < end) { if (await fn()) return; await sleep(20); } throw Error('deadline: ' + label); }
    await until(async () => { try { return (await fetch(base + '/health', { signal: AbortSignal.timeout(500) })).ok; } catch { return false; } }, 'node ready');
    async function chat(thread, text) {
      const r = await fetch(base + '/chat', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ thread, text }), signal: AbortSignal.timeout(12000) });
      const value = await r.json();
      return { status: r.status, value };
    }
    const ok = async (thread, text) => {
      const { status, value } = await chat(thread, text);
      assert.equal(status, 200, JSON.stringify(value));
      assert.ok(!value.error, JSON.stringify(value));
      return value;
    };

    // 1. A Lua error inside a transaction must roll it back and release the write lock.
    const failed = await chat('life-a', 'error-in-transaction');
    assert.ok(failed.value.error, 'the fixture error must surface: ' + JSON.stringify(failed.value));
    checks++;
    const afterError = await ok('life-b', 'read');
    assert.deepEqual(afterError.rows, [], 'the rolled-back row must not survive: ' + JSON.stringify(afterError.rows));
    checks++;
    const wrote = await ok('life-b', 'writer:W');
    assert.equal(wrote.wrote, true, 'another writer must proceed after the rollback');
    checks++;

    // 2. Repeatedly spawning and retiring read workers (each its own connection)
    // must not need the write lock or disturb committed state.
    for (let index = 0; index < 12; index++) {
      const response = await fetch(base + '/sessions', { signal: AbortSignal.timeout(3000) });
      assert.equal(response.status, 200, 'a read worker must answer');
    }
    await sleep(1500); // let the read workers retire (idle 1s), dropping their connections
    const afterChurn = await ok('life-b', 'read');
    assert.deepEqual(afterChurn.rows.map((row) => row.k).sort(), ['W'], 'churn must not change committed rows');
    checks++;

    // 3. A second writer waits for the first (busy timeout), and neither loses its row.
    const hold = ok('life-h', 'hold');
    hold.catch(() => {});
    await until(() => fs.existsSync(path.join(root, '.wasm-agent/H-open')), 'the holding writer to begin');
    const parallel = ok('life-f', 'writer:P');
    parallel.catch(() => {});
    await sleep(300);
    await ok('life-rel', 'release');
    const [held, parallelResult] = await Promise.all([hold, parallel]);
    assert.equal(held.committed, true, 'the holding writer must commit');
    assert.equal(parallelResult.wrote, true, 'the parallel writer must commit after waiting');
    checks += 2;
    const final = await ok('life-f', 'read');
    const keys = final.rows.map((row) => row.k).sort();
    assert.deepEqual(keys, ['H', 'P', 'W'], 'both committed writers must be present exactly once: ' + JSON.stringify(keys));
    checks++;

    fs.writeFileSync(path.join(root, 'verdict.json'), JSON.stringify({ suite: 'sqlite-lifecycle', checks, failed: 0, skipped: 0, ok: true }));
    console.log(`sqlite lifecycle ok (${checks} checks, 0 skipped; real workers and connections, no inference)\nevidence: ${root}`);
  } catch (error) {
    fs.writeFileSync(path.join(root, 'verdict.json'), JSON.stringify({ suite: 'sqlite-lifecycle', checks, failed: 1, skipped: 0, ok: false, error: String(error) }));
    console.error(error.stack);
    console.error('evidence: ' + root);
    process.exitCode = 1;
  } finally {
    if (child && child.exitCode === null) { child.kill(); await Promise.race([new Promise((r) => child.once('exit', r)), sleep(3000)]); }
    if (log !== undefined) fs.closeSync(log);
  }
})();
