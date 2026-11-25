// THE HARNESS BOTH /health ROWS SHARE: a REAL node in a scratch home, and a stub provider.
//
// Two rows now judge this node's own /health (scripts/test-node-wake-facts.cjs, the facts;
// scripts/test-health-wakes-rule.cjs, the rule every reader of them runs). They must agree about what a
// scratch node IS, or one of them will one day be green in a home that is not scratch, so the pieces live
// here once:
//
//   * the home refuses to be, hold, or sit inside the operator's store (the four refusals of
//     scripts/lib/scratch-home.sh, restated in JS because the node is spawned from here);
//   * the binary is a named one, never whatever PATH answers (a PATH `wa` is another tree's code);
//   * the provider is a stub on 127.0.0.1 - no account, no paid inference, no network;
//   * the environment is the caller's minus every WA_/WASM_AGENT_/provider/vault variable, so a credential in
//     the parent shell cannot reach the node.
const fs = require('fs'), os = require('os'), path = require('path'), http = require('http'), net = require('net');
const { spawn } = require('child_process');

const repoRoot = () => path.resolve(__dirname, '..', '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function refuse(why) { console.error('refused(' + why.split(':')[0] + '): ' + why); process.exit(2); }

function resolve(p) { try { return fs.realpathSync(p); } catch { return path.resolve(p); } }
const inside = (child, parent) => child === parent || child.startsWith(parent + path.sep);

/// Refuse a home that is the operator's, inside the operator's store, or above it.
function guardHome(home) {
  const opHome = resolve(os.homedir()), opStore = path.join(opHome, '.wasm-agent');
  if (!home) refuse('real_node_home: no scratch home was named');
  if (!path.isAbsolute(home)) refuse('real_node_home: ' + home + ' is not an absolute path');
  const resolved = resolve(home);
  if (resolved === opHome || inside(resolved, opStore)) {
    refuse('real_node_home: ' + resolved + ' is the operator home or inside the operator store ' + opStore);
  }
  if (inside(opStore, resolved)) refuse('real_node_home: ' + resolved + ' contains the operator store ' + opStore);
}

/// A scratch root OUTSIDE the operator store (scripts/lib/scratch-home.sh's order): on this node TMPDIR points
/// INTO ~/.wasm-agent, so the system temp directory is the one place a row's home may not be.
function scratchRoot() {
  const home = resolve(os.homedir()), store = path.join(home, '.wasm-agent'), root = repoRoot();
  const refuses = (dir) => dir === '/' || dir === home || inside(dir, store) || inside(store, dir)
    || inside(dir, resolve(root)) || dir === resolve(root);
  const candidates = [process.env.WA_TEST_ROOT, path.join(path.dirname(root), '.wa-scratch'),
    path.join(path.dirname(path.dirname(root)), '.wa-scratch'), os.tmpdir(), '/tmp'];
  for (const candidate of candidates) {
    if (!candidate || !path.isAbsolute(candidate)) continue;
    let dir;
    try { fs.mkdirSync(candidate, { recursive: true }); dir = fs.realpathSync(candidate); } catch { continue; }
    if (refuses(dir)) continue;
    try { fs.accessSync(dir, fs.constants.W_OK); } catch { continue; }
    try {
      const space = fs.statfsSync(dir);
      if (space.bavail * space.bsize < 4096 * 1024 * 1024) continue;
    } catch {}
    return dir;
  }
  refuse('real_node_home: no writable scratch root exists outside the operator store ' + store);
}

/// The `wa` this row runs: argv[2], then WA_BIN, then this tree's release binary. Never PATH.
function resolveBinary() {
  const root = repoRoot();
  for (const candidate of [process.argv[2], process.env.WA_BIN, path.join(root, 'rust/target/release/wa')]) {
    if (!candidate) continue;
    const abs = path.isAbsolute(candidate) ? candidate : path.resolve(candidate);
    try { fs.accessSync(abs, fs.constants.X_OK); return abs; } catch {}
  }
  refuse('no_wa_binary: no executable wa was named (argv[2], WA_BIN, or rust/target/release/wa)');
}

async function freePort() {
  return new Promise((r) => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)); }); });
}

/// A stub OpenAI-compatible provider. `answer(body)` returns `{message, finish}`; the default answers
/// 'finished' to everything. Streaming and plain requests both work, as the node sends both.
function startMock(answer) {
  const decide = answer || (() => ({ message: { role: 'assistant', content: 'finished' }, finish: 'stop' }));
  const mock = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const body = JSON.parse(raw || '{}');
      const { message, finish } = decide(body);
      const usage = { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12 };
      if (body.stream) {
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        res.end('data: ' + JSON.stringify({ choices: [{ delta: message, finish_reason: finish }], usage }) + '\n\ndata: [DONE]\n\n');
      } else {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message, finish_reason: finish }], usage }));
      }
    });
  });
  return new Promise((r) => mock.listen(0, '127.0.0.1', () => r(mock)));
}

/// The environment a scratch node gets: the caller's, minus every credential and runtime path this project
/// owns. WASM_AGENT_HOME/DATA/DB/LUA_ROOT then point at the scratch home and this tree.
function nodeEnv(home, providerPort, extra) {
  const env = Object.fromEntries(Object.entries(process.env)
    .filter(([k]) => !/^(WA_|WASM_AGENT_|OPENAI_|ANTHROPIC_|OPENCODE_|VAULT_)/.test(k)));
  return { ...env, HOME: home, WASM_AGENT_HOME: home, WASM_AGENT_DATA: path.join(home, '.wasm-agent'),
    WASM_AGENT_DB: path.join(home, 'node.db'), WASM_AGENT_LUA_ROOT: repoRoot(), WASM_AGENT_MANAGED: '0',
    WASM_AGENT_RENDEZVOUS: '', WASM_AGENT_RELAY: '',
    WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + providerPort,
    WASM_AGENT_LLM_MODEL: 'fixture', WASM_AGENT_LLM_API_KEY: 'fixture', WASM_AGENT_MAX_TOOL_ROUNDS: '4',
    ...(extra || {}) };
}

/// Spawn the node and wait until /health answers. Returns the handles a row needs, and a `close` that stops it.
async function startNode({ bin, home, db, providerPort, extraEnv }) {
  const port = await freePort(), clientPort = await freePort();
  const log = fs.openSync(path.join(home, 'node.log'), 'a');
  const child = spawn(bin, ['serve', '--port', String(port), '--client-port', String(clientPort),
    '--ui', path.join(repoRoot(), 'ui'), '--db', db], {
    cwd: home, env: nodeEnv(home, providerPort, extraEnv), stdio: ['ignore', log, log], windowsHide: true,
  });
  const base = 'http://127.0.0.1:' + port;
  const get = async (route, body) => {
    const response = await fetch(base + route, { ...(body ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(30000) });
    return response.json();
  };
  const health = () => get('/health');
  const deadline = Date.now() + 60000;
  for (;;) {
    try { const body = await health(); if (body.ok !== undefined) break; } catch {}
    if (Date.now() > deadline) throw Error('the scratch node did not answer /health in 60 s (log: ' + path.join(home, 'node.log') + ')');
    await sleep(100);
  }
  return { child, port, base, get, health, close: async () => { child.kill(); await new Promise((r) => child.once('exit', r)); } };
}

/// Poll `fn` until it answers something truthy. A timeout is an ASSERTION, named as one: the landing gate
/// classifies a test by what its failure says, and a plain Error here would read as "unclassified".
async function until(fn, label, ms = 60000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > deadline) throw new Error('assertion failed: ' + label);
    await sleep(100);
  }
}

module.exports = { repoRoot, sleep, refuse, guardHome, scratchRoot, resolveBinary, freePort, startMock, startNode, until, nodeEnv };
