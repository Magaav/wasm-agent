import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {evaluate} from './delivery-admission.mjs';
import {hash} from './gate-check.mjs';
import {plan,runFocused,verifyFocused} from './producer-admission.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-focused-proof-'));
function git(...args){const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try {
  fs.mkdirSync(path.join(root,'scripts','lib'),{recursive:true});fs.mkdirSync(path.join(root,'tests'));fs.mkdirSync(path.join(root,'ui'));
  fs.writeFileSync(path.join(root,'ui','app.js'),'// fixture UI base\n');
  for(const name of ['test-selection-state.cjs','test-recovery-two-window.cjs'])fs.writeFileSync(path.join(root,'scripts',name),'// metadata proof fixture only\n');
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
  const originalLog=fs.readFileSync(proof.results[0].log);
  fs.writeFileSync(proof.results[0].log,'no terminal verdict\n');
  const matchingHash={...proof,results:proof.results.map(row=>({...row,log_sha256:hash(fs.readFileSync(row.log))}))};
  assert(!verifyFocused(root,matchingHash).admission_verified,'matching log hash cannot replace terminal verdict proof');
  fs.writeFileSync(proof.results[0].log,originalLog);
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
  if(process.platform==='win32') {
    git('switch','-qc','change/browser-proof','origin/main');fs.appendFileSync(path.join(root,'ui','app.js'),'// narrow UI change\n');git('add','.');git('commit','-qm','UI proof contract');
    const selected=plan(root),definitions=(await import('./gate-checks.mjs')).catalog(root);assert(!selected.full_required);
    const results=selected.checks.map(id=>{
      const c=definitions.find(c=>c.id===id),log=path.join(root,'.git',id.replaceAll(/[^a-z0-9.-]/gi,'_')+'.log');
      const text=c.verdict==='js'?'ALL PASS\n':c.verdict==='browser'?'  ok   UI structure, mid-run reload, startup recovery [stages: reload,startup-recovery,inspect-window,view-window]\n':c.proof_kind==='selection'?'selection state ok (9 checks, 0 skipped; fixture)\n':'two-window recovery ok (13 checks, 0 skipped; fixture)\n';
      fs.writeFileSync(log,text);return {id,log,log_sha256:hash(text),passed:true,exit:0,skipped:0,ms:0};
    });
    const synthetic={schema:1,kind:'producer-focused',tree:selected.tree,checks:selected.checks,passed:true,results,
      runner_identity:hash(fs.readFileSync('scripts/producer-admission.mjs'))+hash(fs.readFileSync(path.join(root,'scripts','gate-checks.mjs')))+hash(fs.readFileSync(path.join(root,'scripts','gate-check.mjs')))};
    assert(verifyFocused(root,synthetic).admission_verified,'synthetic valid per-kind log contract');
    const browser=synthetic.results.find(r=>r.id==='ui-browser');fs.writeFileSync(browser.log,'matching hash without browser terminal proof\n');browser.log_sha256=hash(fs.readFileSync(browser.log));
    assert(!verifyFocused(root,synthetic).admission_verified,'matching-hash browser log must independently carry terminal proof');
  }
  if(process.platform!=='win32')console.log('SKIP: browser receipt log contract requires Windows focused plan');
  console.log(`producer admission ok (${process.platform==='win32'?19:16} checks, ${process.platform==='win32'?0:1} skipped; synthetic per-kind log validation, not browser execution)`);
} finally {fs.rmSync(root,{recursive:true,force:true});}
