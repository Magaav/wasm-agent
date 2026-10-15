// Model-free launcher for the ACTUAL vault handler. No inherited credential env.
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import {isolatedEnvironment} from '../agent-benchmark-environment.mjs';
export async function startBenchmarkVault({repo, out, upstream}) {
  const python = process.env.WA_BENCHMARK_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
  const child = cp.spawn(python, ['-B', path.join(repo, 'scripts/fixtures/benchmark-vault.py'),
    path.join(repo, 'vault/wa_vault.py'), path.join(out, 'synthetic-vault-data'), upstream], {
    env: isolatedEnvironment(out), stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  let stdout = '', stderr = '';
  child.stdout.on('data', b => stdout += b); child.stderr.on('data', b => stderr += b);
  const closed = new Promise(resolve => {
    child.on('error', e => resolve({error: e.code}));
    child.on('close', (code, signal) => resolve({code, signal}));
  });
  async function close() {
    child.kill(); const exit = await closed;
    fs.writeFileSync(path.join(out, 'vault.stdout'), stdout);
    fs.writeFileSync(path.join(out, 'vault.stderr'), stderr);
    fs.writeFileSync(path.join(out, 'vault-exit.json'), JSON.stringify(exit));
  }
  for (let n = 0; n < 300; n++) {
    let ready; try { ready = JSON.parse(stdout.trim().split(/\r?\n/)[0]); } catch {}
    if (ready?.synthetic_only) return {url: 'http://127.0.0.1:' + ready.port, close};
    await new Promise(r => setTimeout(r, 10));
  }
  await close(); throw Error('synthetic actual-vault fixture failed to start; retained vault.stderr');
}
