import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {executeChecks,checkVerdict} from './gate-check.mjs';
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
  const browser={verdict:'browser',subjects:['reload','startup-recovery','inspect-window','view-window']};
  const real='  ok   UI structure [stages: reload,startup-recovery,inspect-window,view-window]\n';
  assert(checkVerdict(browser,0,real).ok);
  for(const [exit,text] of [[0,'silent'],[7,real],[0,real+'FAIL evidence'],[0,real+real],
    [0,'  ok   UI structure, but startup recovery was skipped and the mid-run reload never ran\n'],
    [0,'  ok   UI structure [stages: reload,startup-recovery]\n'],
    [0,real+'fail: missing inspector\n'],[0,real+'dependency_missing: browser\n']])assert(!checkVerdict(browser,exit,text).ok);
  console.log('gate check runner ok (focused isolation and browser stage contract, 0 skipped)');
} finally {fs.rmSync(root,{recursive:true,force:true});}
