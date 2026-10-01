import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fullProof,findFullProof} from './lib/full-gate-proof.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-full-proof-'));
try {
  const log=path.join(root,'gate.log');fs.writeFileSync(log,'checks\nsmoke ok (2 skipped)\n');
  const receipt={schema:1,tree:'a'.repeat(40),head:'b'.repeat(40),gate_exit:0,gate_runs:1,gate_ms:42,passed:true,skipped:2,log,
    log_sha256:crypto.createHash('sha256').update(fs.readFileSync(log)).digest('hex')};
  assert(fullProof(receipt,receipt.tree).verified);
  assert(!fullProof(receipt,'c'.repeat(40)).verified);
  for(const patch of [{gate_exit:7},{passed:false},{kind:'producer-focused'},{skipped:0},{gate_runs:0},{gate_ms:-1}])assert(!fullProof({...receipt,...patch},receipt.tree).verified);
  const git=(...args)=>{const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
  git('init','-q','--initial-branch','main');
  const bound={...receipt,repo:root};fs.writeFileSync(path.join(root,'.git','wa-combined-gate.json'),JSON.stringify(bound));
  assert(findFullProof(root,receipt.tree).verified,'combined-tree evidence is discoverable by deployment');
  assert(!findFullProof(root,'c'.repeat(40)).verified,'combined evidence never covers a changed source tree');
  fs.appendFileSync(log,'extra\n');assert(!fullProof(receipt,receipt.tree).verified);
  console.log('full gate proof ok (11 checks, 0 skipped)');
} finally{fs.rmSync(root,{recursive:true,force:true});}
