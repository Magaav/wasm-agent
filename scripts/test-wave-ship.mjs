import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-ship-')),source=path.join(root,'source'),install=path.join(root,'install');
try{
 fs.mkdirSync(path.join(source,'scripts','lib'),{recursive:true});
 fs.writeFileSync(path.join(source,'scripts','wave-entry.mjs'),"import './lib/wave-one.mjs';\n");fs.writeFileSync(path.join(source,'scripts','lib','wave-one.mjs'),"import './wave-two.mjs';\n");fs.writeFileSync(path.join(source,'scripts','lib','wave-two.mjs'),'export const ready=true;\n');
 fs.writeFileSync(path.join(source,'scripts','wave-observe.lua'),'-- source/embedded module observation fixture\n');
 const run=()=>spawnSync(process.execPath,['scripts/ship-wave.mjs',source,install],{encoding:'utf8',windowsHide:true});
 assert.equal(run().status,0);assert(fs.existsSync(path.join(install,'scripts','lib','wave-two.mjs')));assert(fs.existsSync(path.join(install,'scripts','wave-observe.lua')));
 fs.unlinkSync(path.join(source,'scripts','lib','wave-two.mjs'));const failed=run();assert.notEqual(failed.status,0);assert(/dependency missing/.test(failed.stderr));
 // This is the normal test.sh entry: consumer closure must be tested here,
 // not only by an optional standalone invocation. Never emit PASS on child failure.
 const consumer=spawnSync(process.execPath,['scripts/test-ship-wave.mjs'],{encoding:'utf8',windowsHide:true});
 process.stdout.write(consumer.stdout||'');process.stderr.write(consumer.stderr||'');
 assert.equal(consumer.status,0,'staged normal admission/proof consumer suite failed');
 assert.match(consumer.stdout,/^ship wave ok \(14 checks, 0 skipped;/m);
 console.log('wave shipping ok (21 checks, 0 skipped; 5 import assertions, 14 consumer assertions, 2 wrapper assertions)');
}finally{fs.rmSync(root,{recursive:true,force:true});}
