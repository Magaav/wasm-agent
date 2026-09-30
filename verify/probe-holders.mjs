#!/usr/bin/env node
// Repair harness (not part of the review's set): which "this directory is in use" evidence exists on
// THIS machine? Four holder shapes x two decisions (a same-parent rename probe, and the destructive
// rm -rf the sweep actually performs). Nothing here touches any real temp family: the root is a
// mkdtemp under this repair's own scratch root.
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';

const SCRATCH = 'C:/Users/Victor/.wasm-agent/wa-repair-c78ab73';
const root = fs.mkdtempSync(path.join(SCRATCH, 'probe-'));
console.log(`scratch root: ${root}`);
const sleep = ms => new Promise(r => setTimeout(r, ms));

const mk = name => {
  const dir = path.join(root, name);
  fs.mkdirSync(path.join(dir, 'sub'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'sub', 'blob.bin'), Buffer.alloc(1024, 7));
  return dir;
};

// the probe a sweep would use: rename within the same parent, then back
function renameProbe(dir) {
  const probe = `${dir}.probe-${process.pid}`;
  try {
    fs.renameSync(dir, probe);
    try { fs.renameSync(probe, dir); return {renamable: true, back: true}; }
    catch (error) { return {renamable: true, back: false, back_error: error.code}; }
  } catch (error) {
    return {renamable: false, code: error.code, message: String(error.message).split('\n')[0]};
  }
}
function tryRemove(dir) {
  try { fs.rmSync(dir, {recursive: true, force: true}); return {removed: true, still_there: fs.existsSync(dir)}; }
  catch (error) { return {removed: false, code: error.code, message: String(error.message).split('\n')[0]}; }
}

async function probeCase(label, dir, holder) {
  if (!fs.existsSync(dir)) { console.log(`  ${label}: (dir gone)`); return; }
  console.log(`  ${label}: rename probe -> ${JSON.stringify(renameProbe(dir))}`);
  if (holder && holder.kill) holder.kill();
  await sleep(300);
  if (!fs.existsSync(dir)) { console.log('  (dir gone before the rm test)'); return; }
  console.log(`  ${label}: rm -rf -> ${JSON.stringify(tryRemove(dir))}`);
  if (fs.existsSync(dir)) fs.rmSync(dir, {recursive: true, force: true});
}

console.log('\n1. idle directory (nobody holds it)');
await probeCase('idle', mk('wa-merge-lane-Idle01'), null);

console.log('\n2. a native Windows process whose cwd IS the directory (node, process.chdir)');
{
  const dir = mk('wa-merge-lane-Node00');
  const child = spawn(process.execPath, ['-e', `process.chdir(${JSON.stringify(dir)}); console.log('cwd='+process.cwd()); setTimeout(()=>{},60000)`], {stdio: ['ignore', 'pipe', 'ignore']});
  await new Promise(r => child.stdout.on('data', () => r()));
  await probeCase('node cwd=dir', dir, child);
}

console.log('\n3. a native Windows process whose cwd is a SUBDIRECTORY of it (node)');
{
  const dir = mk('wa-merge-lane-Node01');
  const child = spawn(process.execPath, ['-e', `process.chdir(${JSON.stringify(path.join(dir, 'sub'))}); console.log('cwd='+process.cwd()); setTimeout(()=>{},60000)`], {stdio: ['ignore', 'pipe', 'ignore']});
  await new Promise(r => child.stdout.on('data', () => r()));
  await probeCase('node cwd=dir/sub', dir, child);
}

console.log('\n4. an MSYS/Cygwin process (Git Bash) whose cwd is the directory: cd "$dir" && sleep 60');
{
  const dir = mk('wa-merge-lane-Msys00');
  const child = spawn('C:\\Program Files\\Git\\bin\\bash.exe', ['-c', `cd "$(cygpath -u '${dir}')" && echo cwd=$(pwd) && sleep 60`], {stdio: ['ignore', 'pipe', 'ignore']});
  await new Promise(r => child.stdout.on('data', d => { if (String(d).includes('cwd=')) r(); }));
  await probeCase('msys bash cwd=dir', dir, child);
}

console.log('\n5. a native Windows process holding an OPEN FILE inside the directory (node)');
{
  const dir = mk('wa-merge-lane-File00');
  const child = spawn(process.execPath, ['-e', `const fs=require('fs');const fd=fs.openSync(${JSON.stringify(path.join(dir, 'sub', 'blob.bin'))},'r+');fs.fsyncSync(fd);console.log('held');setTimeout(()=>{},60000)`], {stdio: ['ignore', 'pipe', 'ignore']});
  await new Promise(r => child.stdout.on('data', () => r()));
  await probeCase('node open file inside', dir, child);
}

console.log('\n6. a native Windows exe whose cwd is the directory (cmd.exe), a second data point');
{
  const dir = mk('wa-merge-lane-Cmd000');
  const child = spawn('cmd.exe', ['/c', `cd /d "${dir}" && echo held && ping -n 60 127.0.0.1 > nul`], {stdio: ['ignore', 'pipe', 'ignore']});
  await new Promise(r => child.stdout.on('data', () => r()));
  await probeCase('cmd cwd=dir', dir, child);
}

console.log(`\nleft in scratch root: ${fs.readdirSync(root).join(', ')}`);
fs.rmSync(root, {recursive: true, force: true});
console.log(`scratch root removed: ${!fs.existsSync(root)}`);
