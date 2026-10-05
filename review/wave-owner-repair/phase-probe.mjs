// Private instrument: extend delivered corners with mixed-store all-four freeze matrix.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
const tip=path.resolve(process.argv[2]);const file=path.join(tip,'scripts/test-wave-activity-corners.mjs');const text=fs.readFileSync(file,'utf8');
const anchor="  // The pure case (no unfinished row) keeps its old, narrower refusal.";
assert.equal(text.split(anchor).length,2);
const extra=`  fs.writeFileSync(path.join(corner.store,'freeze.json'),JSON.stringify({wave_id:'younger'}));
  for(const phase of ['produce','allocate','land','admit']) {
    const result=checkAdmission(corner.repo,{phase});
    check(result.ok===false,'mixed newest-complete/older-unfinished freeze refuses '+phase);
    console.log('MIXED_FREEZE '+phase+' '+JSON.stringify(result));
  }
  fs.rmSync(path.join(corner.store,'freeze.json'));
`;
const instrument=path.join(tip,'scripts/reviewer-phase-probe.mjs');fs.writeFileSync(instrument,text.replace(anchor,extra+anchor));
try{const result=spawnSync(process.execPath,[instrument],{cwd:tip,encoding:'utf8',timeout:60000});process.stdout.write(result.stdout||'');process.stderr.write(result.stderr||'');assert.equal(result.status,0,result.error?.message||'phase matrix failed');}finally{fs.rmSync(instrument,{force:true});}
