// Execute exact normal-gate function/block bytes with a private gate_run recorder.
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-wiring-'));
const text=fs.readFileSync('scripts/test.sh','utf8');
const fn=text.slice(text.indexOf('run_proof_fixture() {'),text.indexOf('\ngate_phase_begin build'));
const expected=['test-wave-owner-refusal.mjs','test-wave-owner-mutations.mjs','test-wave-activity-corners.mjs','test-wave-derived-state.mjs','test-wave-activity-fix.mjs'];
function run(body,name){const record=path.join(root,name);const script=`set -eu\nSKIPPED=0\nDB='${root.replaceAll('\\','/')}/proof'\ngate_run(){ printf '%s\\n' "$*" >> '${record.replaceAll('\\','/')}'; "$@"; }\n${body}\n[ "$SKIPPED" = 0 ]\n`;
const r=spawnSync('bash',['-c',script],{encoding:'utf8',timeout:180000});const calls=fs.existsSync(record)?fs.readFileSync(record,'utf8'):'';return {r,calls};}
try{const baseline=run(fn,'baseline');assert.equal(baseline.r.status,0,baseline.r.stderr);for(const file of expected)assert.ok(baseline.calls.includes(file),`normal gate did not execute ${file}`);console.log(baseline.r.stdout);
// Removal is detected by actual recorded execution, not a coverage glob or source grep.
const line='run_proof_fixture waveOwner 53 node scripts/test-wave-owner-refusal.mjs';
const mutant=run(fn.replace(line,''),'removed');assert.equal(mutant.r.status,0,mutant.r.stderr);assert.throws(()=>assert.ok(mutant.calls.includes(expected[0])));console.log('wave gate wiring ok (5 required executions; removed callsite contract goes red; 0 skipped)');
}finally{fs.rmSync(root,{recursive:true,force:true});}
