const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-naming-contract-'));
const git = (...args) => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
const put = (file, text) => { fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true }); fs.writeFileSync(path.join(root, file), text); };
let checks = 0;
const bash = process.platform === 'win32' ? path.join(process.env.ProgramFiles || 'C:/Program Files', 'Git/bin/bash.exe') : 'bash';
function run(status, pattern) {
  const r = spawnSync(bash, ['scripts/check-naming.sh'], { cwd: root, encoding: 'utf8', timeout: 15000 });
  assert.ifError(r.error);
  assert.equal(r.status, status, r.stdout + r.stderr); checks++;
  assert.match(r.stdout, pattern); checks++;
}
try {
  git('init', '-q'); git('config', 'core.autocrlf', 'false');
  put('scripts/check-naming.sh', fs.readFileSync(path.join(__dirname, 'check-naming.sh')));
  put('space name.lua', 'local run_id = 1\n');
  git('add', '.'); run(0, /naming ok \(1 files/);
  put('space name.lua', 'local turn_id = 1\n'); // naming-check: allow (mutation fixture)
  run(1, /space name\.lua still says/);
  put('space name.lua', 'local turn_id = 1 -- naming-check: allow (wire compatibility)\n'); // naming-check: allow (fixture)
  run(0, /naming ok/);
  put('lua/core/memory.lua', 'local function migrate_shape()\n  local turn_id = 1\nend\nlocal run_id = 1\n'); // naming-check: allow (migration fixture)
  git('add', '.'); run(0, /naming ok \(2 files/);
  fs.appendFileSync(path.join(root, 'lua/core/memory.lua'), 'local turn_id = 2\n'); // naming-check: allow (mutation after migration)
  run(1, /5:local/);
  put('lua/core/memory.lua', 'local run_id = 1\n');
  put('ARCHITECTURE.md', 'turn_id\n'); // naming-check: allow (documented historical name exemption fixture)
  put('tests/naming-migration.lua', 'turn_id\n'); // naming-check: allow (legacy schema fixture)
  put('asset.wasm', 'turn_id\n'); // naming-check: allow (binary exclusion fixture)
  git('add', '.'); run(0, /naming ok \(2 files/);
  console.log(`naming checker ok (${checks} checks, 0 skipped; real git fixtures and mutations)`);
} finally { fs.rmSync(root, { recursive: true, force: true }); }
