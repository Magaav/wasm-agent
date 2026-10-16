// Private source/embedded contract proof; no inference or real child admission.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {isolatedEnvironment} from './agent-benchmark-environment.mjs';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2), post = argv[0] === '--post';
if (post) argv.shift();
const [binary, out, baseline] = argv;
assert(binary && out && path.isAbsolute(binary) && path.isAbsolute(out));
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const describe = file => ({path: file, bytes: fs.statSync(file).size, sha256: sha(fs.readFileSync(file))});
if (post) {
  const receipt = JSON.parse(fs.readFileSync(path.join(out, 'receipt.json')));
  assert(receipt.ok && receipt.binary.path === binary && receipt.modes.length === 2);
  assert.deepEqual(receipt.modes.map(mode => mode.mode), ['source', 'embedded']);
  for (const mode of receipt.modes) assert(mode.exit === 0 && mode.signal === null && mode.skipped === 0 && Number.isSafeInteger(mode.checks) && mode.checks >= 40);
  assert(receipt.checks === receipt.modes.reduce((n, mode) => n + mode.checks, 0));
  for (const file of receipt.files) assert.deepEqual(describe(file.path), file, 'retained source/artifact drift: ' + file.path);
  console.log(JSON.stringify({ok: true, retained_hashes: true, checks: receipt.checks, inference_calls: 0}));
} else {
  assert(!fs.existsSync(out), 'fresh evidence required'); fs.mkdirSync(out, {recursive: true});
  const files = [describe(binary), ...['lua/core/tools.lua', 'lua/core/subagents.lua', 'lua/core/steering.lua',
    'lua/core/subscription_wire.lua', 'scripts/test-subagent-message-contract.lua',
    'scripts/test-subagent-message-contract.mjs'].map(file => describe(path.join(repo, file)))];
  const modes = [];
  function run(label, executable, source) {
    const home = path.join(out, label); fs.mkdirSync(home);
    const env = isolatedEnvironment(home, {WA_SCRIPT: path.join(repo, 'scripts/test-subagent-message-contract.lua'),
      WASM_AGENT_MANAGED: '0', WA_GRAPH_WATCH: '0', WASM_AGENT_LUA_ROOT: source ? repo : '',
      WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:1', WASM_AGENT_LLM_API_KEY: 'model-free-only'});
    const result = spawnSync(executable, ['--db', path.join(home, 'private.db')],
      {cwd: repo, env, timeout: 60000, windowsHide: true, maxBuffer: 8388608});
    for (const stream of ['stdout', 'stderr']) {
      const file = path.join(home, stream); fs.writeFileSync(file, result[stream] ?? Buffer.alloc(0)); files.push(describe(file));
    }
    const db = path.join(home, 'private.db'); if (fs.existsSync(db)) files.push(describe(db));
    return result;
  }
  if (baseline) {
    assert(path.isAbsolute(baseline)); files.push(describe(baseline));
    const result = run('old-embedded-negative', baseline, false);
    assert(result.status === 1 && result.stderr.toString().includes('recorded_id_reuse_help'), 'old schema/help must fail recorded-ID reuse contract');
  }
  for (const mode of ['source', 'embedded']) {
    const result = run(mode, binary, mode === 'source');
    assert.equal(result.status, 0, result.stderr?.toString() || String(result.error));
    const match = result.stdout.toString().match(/subagent message contract ok \((\d+) checks, 0 skipped\)/);
    assert(match && Number(match[1]) >= 40, 'missing or weakened contract verdict');
    modes.push({mode, checks: Number(match[1]), skipped: 0, exit: result.status, signal: result.signal});
  }
  const checks = modes.reduce((n, mode) => n + mode.checks, 0);
  const receipt = {ok: true, binary: describe(binary), files, modes, checks,
    old_embedded_negative: Boolean(baseline), inference_calls: 0, real_child_admissions: 0,
    continuation_executor: 'mock; native key forwarding only', steering_store: 'real private SQLite'};
  fs.writeFileSync(path.join(out, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify({ok: true, checks, skipped: 0, old_embedded_negative: Boolean(baseline), evidence: out}));
}
