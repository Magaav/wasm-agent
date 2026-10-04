// Mutation of the NORMAL test entry, in a private copy with no Git history.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const repo=process.cwd(),root=fs.mkdtempSync(path.join(repo,'.ship-wave-mutation-'));
let checks=0;
const check=(value,label)=>{assert(value,label);checks++;console.log('PASS '+label);};
try {
 fs.cpSync(path.join(repo,'scripts'),path.join(root,'scripts'),{recursive:true});
 const run=()=>spawnSync(process.execPath,['scripts/test-wave-ship.mjs'],{cwd:root,encoding:'utf8',windowsHide:true});
 const patched=run();console.log('PATCHED NORMAL exit='+patched.status+'\n'+patched.stdout+patched.stderr);
 check(patched.status===0&&/^wave shipping ok \(21 checks, 0 skipped;/m.test(patched.stdout),'patched normal path without Git history passes');
 fs.copyFileSync(path.join(root,'scripts/fixtures/ship-wave-baseline.mjs'),path.join(root,'scripts/ship-wave.mjs'));
 const baseline=run();console.log('BASELINE NORMAL exit='+baseline.status+'\n'+baseline.stdout+baseline.stderr);
 check(baseline.status!==0&&baseline.stderr.includes('normal staged allocate JSON success'),'baseline normal path causally fails at consumer assertion');
 check(!/^wave shipping ok /m.test(baseline.stdout),'nested failure cannot emit wrapper PASS');
 console.log(`wave shipping mutation ok (${checks} checks, 0 skipped; private normal-path baseline mutation)`);
} finally {fs.rmSync(root,{recursive:true,force:true});}
