// Real independent Lua runtimes/processes, no inference and no operator home.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const binary = path.resolve(process.argv[2] || process.env.WA_BIN || path.join(repo, 'rust/target/release/wa' + (process.platform === 'win32' ? '.exe' : '')));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-auth-sessions-'));
let checks = 0;
try {
  for (const name of ['a', 'b']) fs.mkdirSync(path.join(root, name), {recursive:true});
  const base = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(WASM_AGENT_|WA_|OPENAI_|OPENCODE_)/.test(k)));
  for (const phase of ['create', 'read', 'other-node', 'logout', 'revoked']) {
    const env = {...base, WASM_AGENT_HOME:path.join(root, phase === 'other-node' ? 'b' : 'a'), WASM_AGENT_LUA_ROOT:repo,
      WA_SCRIPT:path.join(repo,'scripts/test-auth-sessions.lua'), WA_AUTH_TEST_PHASE:phase, WA_AUTH_TEST_TOKEN_FILE:path.join(root,'credential')};
    const result = spawnSync(binary, ['--db',path.join(root,'auth.db')], {cwd:repo,env,encoding:'utf8',timeout:15000});
    assert.ifError(result.error);
    assert.equal(result.status, 0, `${phase}: ${result.stderr}\n${result.stdout}`);
    const count = result.stdout.split(/\r?\n/).filter(s => s.startsWith('ok auth ')).length;
    assert.ok(count > 0, `${phase} produced no evidence`);
    checks += count;
  }
  assert.equal(checks, 22, 'missing fixture evidence');
  console.log(`shared authentication ok (${checks} checks, 0 skipped; independent processes, zero inference)`);
} finally { fs.rmSync(root,{recursive:true,force:true}); }
