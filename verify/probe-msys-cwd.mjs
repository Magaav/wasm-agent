#!/usr/bin/env node
// Does MSYS expose the shape a same-parent rename cannot see? Two questions:
//   7. a Git Bash spawned WITH cwd=<dir> (the way the lane spawns its gate: spawnSync('bash', ...,
//      {cwd: clone.dir})) - is that visible to the rename probe? to MSYS /proc?
//   8. does the same bash, after `cd`-ing inside, show up in /proc/<pid>/cwd?
import fs from 'node:fs';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';

const SCRATCH = 'C:/Users/Victor/.wasm-agent/wa-repair-c78ab73';
const BASH = 'C:\\Program Files\\Git\\bin\\bash.exe';
const root = fs.mkdtempSync(path.join(SCRATCH, 'probe2-'));
console.log(`scratch root: ${root}`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const mk = name => {
  const dir = path.join(root, name);
  fs.mkdirSync(path.join(dir, 'sub'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'sub', 'blob.bin'), Buffer.alloc(1024, 7));
  return dir;
};
function renameProbe(dir) {
  const probe = `${dir}.probe-${process.pid}`;
  try { fs.renameSync(dir, probe); fs.renameSync(probe, dir); return 'renamable (looks idle to a rename probe)'; }
  catch (error) { return `NOT renamable: ${error.code}`; }
}
// what MSYS /proc says about a pid's cwd and open files
const procDump = pid => spawnSync(BASH, ['-c', `for f in /proc/${pid}/cwd; do echo "$f -> $(readlink "$f")"; done; ls -l /proc/${pid}/fd 2>/dev/null | sed -n '2,6p'`], {encoding: 'utf8'}).stdout.trim();

console.log('\n7. bash spawned with cwd = the directory (the lane\'s own shape)');
{
  const dir = mk('wa-merge-lane-Gate00');
  const child = spawn(BASH, ['-c', 'echo started; sleep 60'], {cwd: dir, stdio: ['ignore', 'pipe', 'ignore']});
  await new Promise(r => child.stdout.on('data', () => r()));
  await sleep(300);
  console.log(`  child pid ${child.pid}`);
  console.log(`  rename probe: ${renameProbe(dir)}`);
  console.log(`  MSYS /proc says:\n${procDump(child.pid).split('\n').map(l => `    ${l}`).join('\n')}`);
  const rem = (() => { try { fs.rmSync(dir, {recursive: true, force: true}); return 'rm -rf SUCCEEDED'; } catch (e) { return `rm -rf refused: ${e.code}`; } })();
  console.log(`  ${rem}`);
  child.kill();
  await sleep(300);
}

console.log('\n8. bash that cd-ed inside the directory from elsewhere (the review\'s shape)');
{
  const dir = mk('wa-merge-lane-Gate01');
  const child = spawn(BASH, ['-c', `cd "$(cygpath -u '${dir}')" && echo started && sleep 60`], {stdio: ['ignore', 'pipe', 'ignore']});
  await new Promise(r => child.stdout.on('data', () => r()));
  await sleep(300);
  console.log(`  child pid ${child.pid}`);
  console.log(`  rename probe: ${renameProbe(dir)}`);
  console.log(`  MSYS /proc says:\n${procDump(child.pid).split('\n').map(l => `    ${l}`).join('\n')}`);
  child.kill();
  await sleep(300);
}

console.log(`\nleft: ${fs.readdirSync(root).join(', ')}`);
fs.rmSync(root, {recursive: true, force: true});
console.log(`scratch root removed: ${!fs.existsSync(root)}`);
