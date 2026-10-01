import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {evaluate} from './delivery-admission.mjs';
import {plan,runFocused,verifyFocused} from './producer-admission.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-focused-proof-'));
function git(...args){const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try {
  fs.mkdirSync(path.join(root,'scripts','lib'),{recursive:true});fs.mkdirSync(path.join(root,'tests'));
  for(const file of ['gate-check.mjs','gate-checks.mjs','producer-admission.mjs','lib/test-verdict.cjs'])fs.copyFileSync(`scripts/${file}`,path.join(root,'scripts',file));
  fs.writeFileSync(path.join(root,'tests','one.js'),"console.log('ALL PASS');\n");
  git('init','-q','--initial-branch','main');git('config','user.name','fixture');git('config','user.email','fixture@local');git('add','.');git('commit','-qm','base');git('update-ref','refs/remotes/origin/main','HEAD');git('switch','-qc','change/fixture');
  fs.appendFileSync(path.join(root,'tests','one.js'),'// narrow change\n');git('add','.');git('commit','-qm','narrow');
  assert.deepEqual(plan(root).checks,['js:one.js']);
  const result=await runFocused(root,{output:path.join(root,'.git','checks')});assert(result.admission_verified&&!result.gate_verified&&result.requires_combined_gate);
  const proof=JSON.parse(fs.readFileSync(result.receipt));assert(verifyFocused(root,proof).admission_verified);
  const tip=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}');
  const anchor=git('commit-tree',tree,'-p',tip,'-m','independent review\n\nAgent: codex session=reviewer');
  git('update-ref','refs/remotes/origin/review',anchor);git('update-ref','refs/remotes/origin/change/fixture',tip);
  const record={delivery:'change/fixture',branch:'change/fixture',producer:'producer',tip,tree,producer_checks:proof,
    review:{reviewer:'reviewer',commit:anchor,tip,tree,verdict:'passed',findings:[]}};
  const admitted=evaluate({repo:root,record});assert.equal(admitted.decision,'admitted');assert(admitted.requires_combined_gate&&!admitted.producer_checks.gate_verified);
  assert.equal(evaluate({repo:root,record:{...record,producer_checks:{...proof,passed:false}}}).condition,'producer_checks_verified');
  assert(!verifyFocused(root,{...proof,kind:'full'}).admission_verified);
  assert(!verifyFocused(root,{...proof,results:[]}).admission_verified);
  fs.appendFileSync(proof.results[0].log,'changed');assert(!verifyFocused(root,proof).admission_verified);
  fs.writeFileSync(path.join(root,'shared-runtime.rs'),'change');git('add','.');git('commit','-qm','shared runtime');
  assert(plan(root).full_required);assert(!(await runFocused(root)).admission_verified);
  assert(!verifyFocused(root,proof).admission_verified);
  fs.writeFileSync(path.join(root,'dirty'),'pending');await assert.rejects(runFocused(root),/clean/);
  fs.unlinkSync(path.join(root,'dirty'));
  git('switch','-qc','change/failure','origin/main');
  fs.writeFileSync(path.join(root,'tests','one.js'),"console.log('ALL PASS');process.exit(7);\n");git('add','.');git('commit','-qm','deliberate failure');
  const bad=await runFocused(root,{output:path.join(root,'.git','failure-checks')});
  assert(!bad.admission_verified&&!bad.gate_verified);
  const badProof=JSON.parse(fs.readFileSync(bad.receipt));assert.equal(badProof.results[0].exit,7);
  assert(!verifyFocused(root,badProof).admission_verified);
  console.log('producer admission ok (15 checks, 0 skipped)');
} finally {fs.rmSync(root,{recursive:true,force:true});}
