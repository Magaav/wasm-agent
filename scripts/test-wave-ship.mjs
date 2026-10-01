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
 console.log('wave shipping ok (5 checks, 0 skipped; private transitive literal import fixture)');
}finally{fs.rmSync(root,{recursive:true,force:true});}
