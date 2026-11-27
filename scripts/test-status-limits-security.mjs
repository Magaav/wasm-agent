#!/usr/bin/env node
// THE LIMITS DOOR'S SECURITY, END TO END (Fable, 26/11).
//
// three facts, on the real binary:
//   1. a caller-given URL is refused by name and the host it names hears NOTHING (a listener here
//      counts every connection; zero is the assertion);
//   2. a provider that answers 302 to another origin is a FAILURE - no hop, so no credential - and
//      the other origin hears nothing either;
//   3. the provider key appears in no file the run wrote (a grep of the whole scratch home).
//
// Isolation is the pty rows': a scratch HOME that refuses to be the real ~/.wasm-agent, env -i with an
// allow-list, and a FAILURE (never a pass) when the run served nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-status-limits-security.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('status-limits-security: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-limits-sec-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('status-limits-security: refusing to run with HOME inside the real ' + REAL_HOME);
  process.exit(2);
}

let checks = 0, failed = 0;
function check(name, condition, detail = '') {
  checks += 1;
  if (condition) { console.log('ok - ' + name); return true; }
  failed += 1;
  console.log('FAIL - ' + name + (detail ? '\n       ' + String(detail).split('\n').join('\n       ') : ''));
  return false;
}

const KEY = 'stub-limits-key-9f2c';
let attackerHits = 0;
let otherOriginHits = 0;
let providerHits = 0;

// The origin a redirect would aim at: if it ever hears a request, a credential was chased.
const other = http.createServer((req, res) => { otherOriginHits += 1; res.writeHead(200); res.end('{}'); });
await new Promise(resolve => other.listen(0, '127.0.0.1', resolve));
const OTHER_PORT = other.address().port;

// The "attacker": the host a caller-given URL would name. It counts connections and never answers.
const attacker = http.createServer((req, res) => { attackerHits += 1; res.writeHead(200); res.end('{}'); });
attacker.on('connection', () => { attackerHits += 1; });
await new Promise(resolve => attacker.listen(0, '127.0.0.1', resolve));
const ATTACKER_PORT = attacker.address().port;

// The provider: /usage answers a 302 to the other origin, and nothing else.
const provider = http.createServer((req, res) => {
  providerHits += 1;
  const url = String(req.url || '');
  if (url.includes('/usage')) {
    // A body length, so the client does not wait for a body that never comes: a 302 is the answer.
    res.writeHead(302, {location: 'http://127.0.0.1:' + OTHER_PORT + '/v1/usage', 'content-length': '0'});
    res.end();
    return;
  }
  res.writeHead(200, {'content-type': 'application/json'});
  res.end('{"choices":[]}');
});
await new Promise(resolve => provider.listen(0, '127.0.0.1', resolve));
const PROVIDER_PORT = provider.address().port;

const ENV = {
  PATH: '/usr/bin:/bin',
  HOME,
  TERM: 'xterm-256color',
  LANG: 'C.UTF-8',
  WASM_AGENT_HOME: HOME,
  WASM_AGENT_LUA_ROOT: REPO,
  WASM_AGENT_PROVIDER: 'opencode-go',
  WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + PROVIDER_PORT,
  WASM_AGENT_LLM_API_KEY: KEY,
  WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE: path.join(WORK, 'no-models-store'),
  WASM_AGENT_RENDEZVOUS: '',
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  WA_SEC_ATTACKER: '127.0.0.1:' + ATTACKER_PORT,
  WA_SEC_PROVIDER: '127.0.0.1:' + PROVIDER_PORT,
};

try {
  // spawn (NOT spawnSync): the fixtures are servers in THIS process, and a synchronous child would
  // block the event loop that has to answer it.
  const {spawn} = await import('node:child_process');
  const child = spawn(BIN, ['--db', path.join(WORK, 'ledger.db')], {
    env: {...ENV, WA_SCRIPT: path.join(REPO, 'scripts/test-status-limits-security.lua')},
  });
  let out = '';
  child.stdout.on('data', chunk => { out += chunk; });
  child.stderr.on('data', chunk => { out += chunk; });
  const exit = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', code => resolve(code));
    setTimeout(() => { child.kill(); reject(new Error('the run did not finish in 120 s')); }, 120000);
  });
  check('the run exited cleanly', exit === 0, 'exit ' + exit + ': ' + out.slice(-800));
  const pass = out.includes('status limits security ok (');
  check('the interpreter half passed', pass, out.slice(-2000));
  check('a caller-given URL sent the host NOTHING', attackerHits === 0, 'connections seen: ' + attackerHits);
  check('the provider was asked for its limits at least once', providerHits >= 1, 'hits: ' + providerHits);
  check('a 302 to another origin sent it NOTHING', otherOriginHits === 0, 'connections seen: ' + otherOriginHits);

  // The key in no file the run wrote.
  const leaked = [];
  const walk = dir => {
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      if (!entry.isFile() || full === path.join(WORK, 'ledger.db')) continue;
      try { if (fs.readFileSync(full, 'utf8').includes(KEY)) leaked.push(full); } catch {}
    }
  };
  walk(HOME);
  check('the provider key appears in no file this run wrote', leaked.length === 0, leaked.join(', '));
  check('and not in what the run printed', !out.includes(KEY), 'the key was echoed in the output');
} catch (error) {
  check('the row ran to the end', false, error.message);
} finally {
  attacker.close(); other.close(); provider.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('status-limits-security: scratch kept for diagnosis: ' + WORK);
}

console.log('status limits security: ' + (checks - failed) + ' ok, ' + failed + ' failed, '
  + attackerHits + ' attacker connections, ' + otherOriginHits + ' redirect-origin connections, '
  + providerHits + ' provider requests');
process.exitCode = failed === 0 ? 0 : 1;
