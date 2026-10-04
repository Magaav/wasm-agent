const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const repo = path.resolve(__dirname, '..');
let bin = path.resolve(process.env.WA_BIN || path.join(repo, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));
if (!fs.existsSync(bin) && fs.existsSync(bin + '.exe')) bin += '.exe';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-json-parsing-'));
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)));
Object.assign(env, {WASM_AGENT_HOME:root, WASM_AGENT_LUA_ROOT:repo,
  WA_SCRIPT:path.join(__dirname, 'test-json-parsing.lua'), WASM_AGENT_MANAGED:'0',
  WASM_AGENT_RELAY:'', WASM_AGENT_RENDEZVOUS:''});
const embedded = process.argv.includes('--embedded');
if (embedded) delete env.WASM_AGENT_LUA_ROOT;
try {
  assert.ok(fs.existsSync(bin), 'Missing WA_BIN: ' + bin);
  const result = spawnSync(bin, ['--db', ':memory:'], {cwd:repo, env, encoding:'utf8', timeout:20000, windowsHide:true});
  const log = (result.stdout || '') + (result.stderr || '');
  assert.equal(result.status, 0, result.error?.message || log);
  const evidence = JSON.parse(result.stdout.trim());
  const expected = crypto.createHash('sha256').update(fs.readFileSync(path.join(repo, 'lua/vendor/json.lua'))).digest('hex');
  assert.equal(evidence.source, expected, 'The tested parser must match this exact source tree');
  assert.equal(evidence.checks, 18);
  assert.equal(evidence.skipped, 0);
  assert.ok(evidence.bytes > 2e6);
  assert.ok(evidence.cpu_seconds < 5);
  console.log(JSON.stringify({...evidence, embedded}));
  console.log('json parsing ok (18 checks, 0 skipped)');
} finally {
  fs.rmSync(root, {recursive:true, force:true});
}
