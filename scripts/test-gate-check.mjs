import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {executeChecks} from './gate-check.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-check-runner-'));
try {
  fs.mkdirSync(path.join(root,'tests'));
  const body=`const fs=require('node:fs');const h=process.env.WASM_AGENT_HOME; if(!h||process.env.OPENAI_API_KEY)process.exit(2);fs.writeFileSync(h+'/owned','fixture');setTimeout(()=>console.log('ALL PASS'),150);`;
  for(const name of ['one','two','three'])fs.writeFileSync(path.join(root,'tests',name+'.js'),body);
  fs.writeFileSync(path.join(root,'tests','failure.js'),"console.log('ALL PASS');process.exit(7);");
  fs.writeFileSync(path.join(root,'tests','silent.js'),"process.exit(0);");
  const result=await executeChecks(root,['js:one.js','js:two.js','js:three.js'],{jobs:2,output:path.join(root,'pass')});
  assert(result.passed&&result.results.length===3);assert.equal(new Set(result.results.map(r=>r.log)).size,3);
  assert.equal(new Set(result.results.map(r=>r.home)).size,3,'private home for every check');
  for(const row of result.results)assert(result.results.filter(other=>other.started_ms<=row.started_ms&&other.ended_ms>row.started_ms).length<=2,'hard width bound');
  await assert.rejects(executeChecks(root,['js:one.js'],{memoryMb:1}),/memory budget/);
  const failed=await executeChecks(root,['js:failure.js','js:silent.js','js:one.js'],{jobs:2,output:path.join(root,'fail')});
  assert(!failed.passed);assert.equal(failed.results[0].exit,7);assert.equal(failed.results[1].reason,'missing_terminal_verdict');assert(failed.results[2].passed,'independent checks still settle and keep attribution');
  await assert.rejects(executeChecks(root,['full']),/reservation/);
  await assert.rejects(executeChecks(root,['js:one.js'],{jobs:5}),/1..4/);
  await assert.rejects(executeChecks(root,['js:one.js','js:one.js']),/distinct/);
  console.log('gate check runner ok (12 checks, 0 skipped)');
} finally {fs.rmSync(root,{recursive:true,force:true});}
