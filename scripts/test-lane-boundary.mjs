// The lane boundary: one detector, two boundaries, and a repository's own declaration.
//
// WHAT THIS PROVES, in the order the owner asked for it.
//   * An ABSENT `lane-policy.json` adds no requirement - proven by running the boundary against a fixture
//     whose repository state the detector WOULD refuse (a non-main remote ref, incomplete integration) and
//     getting `ok:true`, `requirements:[]`. The very same fixture with the file in place is then refused
//     with the named detector facts, which is what makes "absent means no requirement" a measurement
//     rather than a claim about a branch of code.
//   * A PRESENT policy is the repository's declaration and is validated by name: `contract`, `end_state`,
//     `gate.on = release`, `deploy.when`, `checks.enter`/`checks.exit`, and - because the boundary is worth
//     having only if it is the SAME detector at both ends - a declared `audit.mjs verify` in each phase.
//   * The boundary does not re-derive any integration check: it runs the declared command and parses the
//     audit's own JSON. That is asserted against the module's source, because a re-derivation would be a
//     new git call in a file that has none.
//   * The wiring is in the two entrypoints the wave already has - `scripts/wave-lifecycle.mjs` create (the
//     next wave's entry) and its completion check (the landing's exit) - and it is exercised by RUNNING
//     them on a wave fixture: a refused entry, an admitted entry, a bootstrap entry (the recorded
//     exemption), a refused exit that blocks the wave durably, and a passing exit that completes it. An
//     earlier version of this file pinned the wiring by grepping the entrypoint's source text, which the
//     reviewer's `test-strength` finding correctly called out: that assertion would pass with the behaviour
//     removed.
//   * Retirement stays ONE command: the only non-test script in `scripts/` that deletes a remote ref is
//     `scripts/wave-retire.mjs`, and there is no second retirement implementation beside it.
//
// Hermetic: private Git repositories with local bare remotes, private SQLite wave stores and stand-in
// effect/proof drivers, no network, no model, no sentinel, no registered wave.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {spawnSync} from 'node:child_process';
import {boundary,readPolicy,detectorArgs,detectorFacts,BOUNDARY_PHASES} from './lib/lane-boundary.mjs';
import {create,advance,inspect} from './wave-lifecycle.mjs';

let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const here=path.resolve('.');
const roots=[];
function git(repo,...args) {
  const result=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});
  assert.equal(result.status,0,`git ${args.join(' ')}: ${result.stderr}`);
  return result.stdout.trim();
}
// A repository whose state the detector must refuse: origin carries a branch that is not main, and the
// branch tip is not contained in origin/main.
function fixture(name) {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),`wa-lane-boundary-${name}-`));
  roots.push(root);
  const repo=path.join(root,'canonical'),remote=path.join(root,'remote.git');
  fs.mkdirSync(repo,{recursive:true});
  git(repo,'init','-b','main');
  git(repo,'config','user.name','lane-boundary-fixture');
  git(repo,'config','user.email','lane-boundary@invalid');
  git(repo,'config','core.autocrlf','false');
  fs.writeFileSync(path.join(repo,'seed'),'fixture\n');
  git(repo,'add','.');
  git(repo,'commit','-m','fixture');
  git(root,'init','--bare',remote);
  git(repo,'remote','add','origin',remote);
  git(repo,'push','-u','origin','main');
  git(repo,'switch','-c','change/unmerged-fixture');
  fs.writeFileSync(path.join(repo,'branch.txt'),'unmerged\n');
  git(repo,'add','.');
  git(repo,'commit','-m','fixture: an unmerged tip');
  git(repo,'push','-u','origin','change/unmerged-fixture');
  git(repo,'switch','main');
  return {root,repo,remote};
}
// The repository's own declaration, with named parts replaced - so a case is a one-line edit and the file
// under test is still the real shape of a lane policy. `detector: 'real'` declares this repository's own
// audit script by absolute path (so the detector really runs against the fixture), `'stub'` declares a
// two-line stub that reports the detector's facts and exits 0, and `'none'` declares no detector at all.
function policy(repo,{gate='release',contract=true,end_state=true,deploy=true,detector='real',extraExit=null}={}) {
  const detectorCheck=detector==='real'?['node',path.join(here,'skills','git-orchestrator','scripts','audit.mjs'),'verify','.','origin/main']
    : detector==='stub'?['node','stub/audit.mjs','verify','.','origin/main']
    : ['node','-e','0'];
  const declared={
    schema:1,
    ...(contract?{contract:'what a lane must reach to be ended'}:{}),
    ...(end_state?{end_state:{statement:'origin carries only main'}}:{}),
    gate:{on:gate},
    ...(deploy?{deploy:{when:'after the release gate'}}:{}),
    remote:{main_only:true},
    checks:{
      enter:[detectorCheck],
      exit:[detectorCheck,...(extraExit?[extraExit]:[])],
    },
  };
  return declared;
}
function withPolicy(target,declared) {
  fs.writeFileSync(path.join(target,'lane-policy.json'),`${JSON.stringify(declared,null,2)}\n`);
}
function removal(target) {
  fs.rmSync(path.join(target,'lane-policy.json'),{force:true});
}

// ---------------------------------------------------------------- a wave fixture that reaches the boundary
// It satisfies everything `create`/`advance` ask for BEFORE the boundary: a canonical repository on main, a
// bare origin carrying main only, a valid combined-gate receipt for that tree, and stand-in
// land/deploy/retire drivers whose postconditions pass. Its lane policy is COMMITTED, so the tree stays clean
// - and the two declared checks after the detector read a flag file OUTSIDE the repository, which is how a
// phase is made to fail without dirtying the tree that the next `verify()` would judge.
const STUB_AUDIT="console.log(JSON.stringify({discovery_complete:true,integration_complete:true,origin_main_only:true,origin_main_matches_target:true}));\n";
const STUB_FLAG="import fs from 'node:fs';\n"+
  "if(fs.existsSync(process.argv[2])){console.error('declared check refused: '+process.argv[2]);process.exit(1);}\n"+
  "process.exit(0);\n";
const STUB_DRIVER=`const fs=require('fs'); const mode=process.argv[2];
  if(mode==='step') { fs.appendFileSync(process.argv[3],process.env.WA_WAVE_OPERATION_ID+'\\n'); console.log(JSON.stringify({ok:true,settled:true,cleanup:'self_exited',operation_id:process.env.WA_WAVE_OPERATION_ID})); }
  if(mode==='post') console.log(JSON.stringify({ok:true}));
  if(mode==='proof') console.log(JSON.stringify({ok:true,main:process.env.WA_WAVE_MAIN,wave_id:process.env.WA_WAVE_ID,complete:true,unresolved:[]}));`;
function waveFixture(name) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),`wa-lane-boundary-wave-${name}-`));
  roots.push(dir);
  const repo=path.join(dir,'canonical'),remote=path.join(dir,'remote.git'),executor=path.join(dir,'executor'),store=path.join(dir,'state');
  fs.mkdirSync(executor,{recursive:true});
  fs.mkdirSync(repo);
  git(repo,'init','-b','main');
  git(repo,'config','user.name','lane-boundary-fixture');
  git(repo,'config','user.email','lane-boundary@invalid');
  git(repo,'config','core.autocrlf','false');
  const enterFlag=path.join(dir,'enter.flag'),exitFlag=path.join(dir,'exit.flag');
  fs.mkdirSync(path.join(repo,'stub'));
  fs.writeFileSync(path.join(repo,'stub','audit.mjs'),STUB_AUDIT);
  fs.writeFileSync(path.join(repo,'stub','flag-check.mjs'),STUB_FLAG);
  fs.writeFileSync(path.join(repo,'lane-policy.json'),`${JSON.stringify({
    schema:1,contract:'fixture: what a lane must reach to be ended',end_state:{statement:'origin carries only main'},
    gate:{on:'release'},deploy:{when:'after the release gate'},remote:{main_only:true},
    checks:{enter:[['node','stub/audit.mjs','verify','.','origin/main'],['node','stub/flag-check.mjs',enterFlag]],
      exit:[['node','stub/audit.mjs','verify','.','origin/main'],['node','stub/flag-check.mjs',exitFlag]]},
  },null,2)}\n`);
  fs.mkdirSync(path.join(repo,'scripts'),{recursive:true});
  fs.mkdirSync(path.join(repo,'skills','parallel-evolution','scripts'),{recursive:true});
  fs.writeFileSync(path.join(repo,'skills','parallel-evolution','scripts','finish.mjs'),'// lane-boundary fixture gate driver\n');
  fs.writeFileSync(path.join(repo,'scripts','test.sh'),'#!/bin/sh\nprintf "smoke ok\\n"\n');
  fs.writeFileSync(path.join(repo,'seed'),'fixture\n');
  git(repo,'add','.');
  git(repo,'commit','-m','fixture: baseline, policy and gate');
  git(dir,'init','--bare',remote);
  git(repo,'remote','add','origin',remote);
  git(repo,'push','-u','origin','main');
  const head=git(repo,'rev-parse','HEAD'),tree=git(repo,'rev-parse','HEAD^{tree}');
  const driver=path.join(executor,'driver.cjs');
  fs.writeFileSync(driver,STUB_DRIVER);
  const effects=path.join(executor,'effects');
  const log=path.join(executor,'gate.log');
  fs.writeFileSync(log,'smoke ok\n');
  const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const shell=process.platform==='win32'?path.join(process.env.ProgramFiles||'C:/Program Files','Git','bin','bash.exe'):'bash';
  const receipt=path.join(executor,'gate.json');
  fs.writeFileSync(receipt,JSON.stringify({schema:1,passed:true,kind:'full',gate_ms:1,repo,head,tree,gate_exit:0,gate_runs:1,skipped:0,log,log_sha256:sha(log),shell,
    host:{hostname:os.hostname(),platform:process.platform,arch:os.arch()},
    runner:{path:path.join(repo,'skills','parallel-evolution','scripts','finish.mjs'),sha256:sha(path.join(repo,'skills','parallel-evolution','scripts','finish.mjs')),platform:process.platform},
    input_scope:{tree,command:'bash scripts/test.sh',gate_sha256:sha(path.join(repo,'scripts','test.sh'))}}));
  const manifest={id:name,owner:'fixture-owner',repo,executor_cwd:executor,bootstrap:false,gate_receipt:receipt,
    steps:['land','deploy','retire'].map(stage=>({name:stage,argv:[process.execPath,driver,'step',effects],post:{argv:[process.execPath,driver,'post']}})),
    verifiers:Object.fromEntries(['operations','claims','runtime','registries','deliveries','owners'].map(verifier=>[verifier,{argv:[process.execPath,driver,'proof']}]))};
  return {dir,repo,remote,executor,store,manifest,enterFlag,exitFlag,effects};
}
function waveRows(store) {
  const db=new DatabaseSync(path.join(store,'waves.sqlite'),{readOnly:true});
  try { return db.prepare('SELECT id,state,reason,receipt FROM waves').all(); } finally { db.close(); }
}

let succeeded=false;
try {
  // ---------------------------------------------------------------- an absent file adds no requirement
  const absent=fixture('absent');
  const refsBefore=git(absent.repo,'for-each-ref','--format=%(objectname) %(refname)','refs/heads','refs/remotes');
  const untouched=boundary(absent.repo,{phase:'enter'});
  check(untouched.ok===true,'a repository with no lane-policy.json passes the boundary');
  check(untouched.policy_present===false,'the verdict says the policy is absent rather than guessing one');
  check(Array.isArray(untouched.requirements) && untouched.requirements.length===0,'an absent policy declares zero requirements');
  check(Array.isArray(untouched.detections) && untouched.detections.length===0,'an absent policy runs nothing at the boundary');
  check(/no lane-policy.json/.test(untouched.note),'the verdict names the absent file it read');
  check(git(absent.repo,'for-each-ref','--format=%(objectname) %(refname)','refs/heads','refs/remotes')===refsBefore,
    'the boundary of an absent policy changed no ref in the repository');
  check(!fs.existsSync(path.join(absent.repo,'.git','wa-finish-gate.json')),'no gate receipt was invented for it');

  // The control: the same repository, now declaring the policy. If the detector could not see the
  // unmerged origin branch, the two verdicts would be identical and the pair would prove nothing.
  fs.mkdirSync(path.join(absent.repo,'stub'),{recursive:true});
  fs.writeFileSync(path.join(absent.repo,'stub','audit.mjs'),
    "console.log(JSON.stringify({discovery_complete:true,integration_complete:true,origin_main_only:true,origin_main_matches_target:true}));\n");
  withPolicy(absent.repo,policy(absent.repo));
  const refused=boundary(absent.repo,{phase:'exit'});
  check(refused.ok===false,'the same repository WITH the declared detector is refused');
  check(refused.reasons.some(reason=>reason.startsWith('lane_boundary_check_failed:exit:')),'the refusal names the phase and the exact command');
  check(refused.reasons.some(reason=>reason.startsWith('lane_boundary_detector:')),'the refusal names the detected fact, not only the exit code');
  check(refused.reasons.some(reason=>/integration_incomplete|origin_not_main_only|discovery_incomplete/.test(reason)),
    'the detected fact is one of integration_complete / origin_main_only / origin_main_is_not_the_target');
  check(refused.detections[0].detector===true,'the declared audit.mjs verify is recognised as the deterministic detector');
  check(refused.detections[0].exit!==0,'the detector really exited nonzero against this fixture');

  // ---------------------------------------------------------------- the declared policy is validated by name
  const cases=[
    ['lane_policy_unreadable',()=>fs.writeFileSync(path.join(absent.repo,'lane-policy.json'),'{not json')],
    ['lane_policy_invalid:schema',()=>withPolicy(absent.repo,{...policy(absent.repo),schema:2})],
    ['lane_policy_invalid:contract',()=>withPolicy(absent.repo,policy(absent.repo,{contract:false}))],
    ['lane_policy_invalid:end_state.statement',()=>withPolicy(absent.repo,policy(absent.repo,{end_state:false}))],
    ['lane_policy_invalid:gate.on',()=>withPolicy(absent.repo,policy(absent.repo,{gate:'landing'}))],
    ['lane_policy_invalid:deploy.when',()=>withPolicy(absent.repo,policy(absent.repo,{deploy:false}))],
    ['lane_policy_invalid:checks.enter:audit_verify_required',()=>withPolicy(absent.repo,policy(absent.repo,{detector:'none'}))],
  ];
  for(const [reason,apply] of cases) {
    apply();
    const verdict=boundary(absent.repo,{phase:'enter'});
    // `lane_policy_unreadable` carries the parser's own message after a colon; every other case is an exact
    // reason token. Both are a named refusal, which is the property being asserted.
    check(verdict.ok===false && verdict.reasons.some(actual=>actual===reason || actual.startsWith(`${reason}:`)),
      `a malformed declaration is refused by name: ${reason}`);
  }
  // ... and a policy that declares the detector plus a check of its own is refused by the check's own argv.
  withPolicy(absent.repo,policy(absent.repo,{detector:'stub',extraExit:['node','-e','process.exit(7)']}));
  const extra=boundary(absent.repo,{phase:'exit'});
  check(extra.ok===false && extra.reasons.some(reason=>reason.includes("node -e process.exit(7)")),
    'a declared check that fails is refused with its own command named');
  check(extra.detections.length===2 && extra.detections[0].exit===0,'the declared checks run in order and the first one passed');
  withPolicy(absent.repo,policy(absent.repo,{detector:'stub'}));
  const passing=boundary(absent.repo,{phase:'enter'});
  check(passing.ok===true && passing.detections[0].detector===true,'a declared detector that exits 0 passes the boundary');
  check(passing.end_state?.statement && passing.gate?.on==='release' && passing.remote?.main_only===true,
    'a passing verdict carries the declaration it was made against');

  // ---------------------------------------------------------------- the detector is not re-derived here
  const moduleSource=fs.readFileSync('scripts/lib/lane-boundary.mjs','utf8');
  for(const plumbing of ['merge-base',"'ls-remote'",'rev-list','for-each-ref','origin/main_matches']) {
    check(!moduleSource.includes(plumbing),`the boundary module re-derives no integration check (${plumbing})`);
  }
  check(detectorArgs(['node','skills/git-orchestrator/scripts/audit.mjs','verify','.','origin/main']),'the audit verify invocation is recognised as the detector');
  check(!detectorArgs(['node','scripts/test.sh']),'an ordinary check is not mistaken for the detector');
  check(detectorFacts(JSON.stringify({discovery_complete:true,integration_complete:true,origin_main_only:true,origin_main_matches_target:true})).missing.length===0,
    'the detector report parses into named facts');
  check(detectorFacts(JSON.stringify({discovery_complete:true,integration_complete:false,origin_main_only:true,origin_main_matches_target:true}))
    .missing.includes('integration_incomplete'),'a false fact is named rather than summarised');

  // ---------------------------------------------------------------- this repository's own declaration
  const own=readPolicy(here);
  check(own.present===true && own.reasons.length===0,'this repository declares a lane policy that validates');
  check(own.policy.gate.on==='release','this repository declares the full gate on the release');
  check(own.policy.deploy.when.length>0,'this repository declares when a deploy may happen');
  check(typeof own.policy.contract==='string' && own.policy.contract.length>40,'the contract states what an ended lane is');
  check(typeof own.policy.end_state.statement==='string' && own.policy.end_state.statement.length>40,'the end state is stated in the file');
  for(const phase of BOUNDARY_PHASES) {
    check(own.policy.checks[phase].some(detectorArgs),`the declared ${phase} check is the deterministic detector`);
  }
  check(own.policy.remote.main_only===true,'this repository declares origin main-only (the push guard reads this)');

  // ---------------------------------------------------------------- the two entrypoints, RUN
  // An earlier version of this file asserted these by grepping `wave-lifecycle.mjs`'s source text. The
  // reviewer's `test-strength` finding was right: that would still pass with the behaviour removed. These
  // five cases run the real `create()`/`advance()` on a wave fixture, so the boundary's enforcement is
  // observed in the wave's own state and durable reasons.

  // (a) THE NEXT WAVE'S ENTRY, refused: the repository's declared enter check fails, so the wave is not
  //     admitted and no wave row exists to admit.
  const refusedEntry=waveFixture('enter-refused');
  fs.writeFileSync(refusedEntry.enterFlag,'the declared enter check fails\n');
  let entryError=null;
  try { create(refusedEntry.store,refusedEntry.manifest); } catch(error) { entryError=error; }
  check(entryError!==null,'a wave whose declared enter check fails is not admitted');
  check(/lane_boundary_enter_refused:/.test(entryError?.message || ''),'the refusal names the boundary and the phase');
  check(/lane_boundary_check_failed:enter:node stub\/flag-check\.mjs/.test(entryError?.message || ''),'the refusal names the exact failing check');
  check(/lane_boundary_check_stderr:declared check refused/.test(entryError?.message || ''),"the refusal carries the failing check's own words");
  check(waveRows(refusedEntry.store).length===0,'a refused entry admits no wave row at all');

  // (b) THE SAME ENTRY, PASSING: the same fixture without the flag admits the wave, and the receipt records
  //     the boundary verdict it was admitted against.
  const passingEntry=waveFixture('enter-passing');
  const admitted=create(passingEntry.store,passingEntry.manifest);
  check(admitted.ok===true && admitted.state==='pending','a wave is admitted when the declared enter check passes');
  check(admitted.boundary.ok===true && admitted.boundary.policy_present===true,'the admitted receipt carries the entry boundary verdict');
  check(admitted.boundary.checks.some(entry=>entry.detector===true),'the admitted receipt records the detector that ran');
  check(waveRows(passingEntry.store).length===1,'exactly one wave row exists after an admitted entry');

  // (c) THE BOOTSTRAP EXEMPTION, recorded as a property rather than left as prose (the reviewer's
  //     `bootstrap-exit-asymmetry`): a bootstrap entry RECORDS the verdict instead of being refused by it,
  //     because it exists for a repository whose baseline is already dirty. `advance()` has no such
  //     exemption, which case (d) exercises.
  const bootstrap=waveFixture('bootstrap-exempt');
  bootstrap.manifest.bootstrap=true;
  fs.writeFileSync(bootstrap.enterFlag,'the declared enter check fails\n');
  const bootstrapAdmitted=create(bootstrap.store,bootstrap.manifest);
  check(bootstrapAdmitted.ok===true,'a bootstrap entry is admitted even when its declared enter check fails');
  check(bootstrapAdmitted.boundary.ok===false,'...and its receipt records that the boundary refused');
  check(bootstrapAdmitted.boundary.reasons.some(reason=>reason.startsWith('lane_boundary_check_failed:enter:')),'...naming the failing check it was admitted over');

  // (d) THE LANDING'S EXIT, refused: every stage settles, the convergence proof passes, and then the
  //     repository's own exit check fails - so the wave is blocked by name instead of being called complete.
  const refusedExit=waveFixture('exit-refused');
  create(refusedExit.store,refusedExit.manifest);
  fs.writeFileSync(refusedExit.exitFlag,'the declared exit check fails\n');
  const blocked=await advance(refusedExit.store,'exit-refused');
  check(blocked.ok===false && blocked.state==='blocked','a failed exit boundary blocks the wave');
  const blockedRow=inspect(refusedExit.store,'exit-refused');
  check(blockedRow.state==='blocked','the block is durable, not only reported');
  check(/lane_boundary_exit_refused/.test(blockedRow.reason || ''),'the durable reason names the exit boundary');
  check(/lane_boundary_check_failed:exit:/.test(blockedRow.reason || ''),'the durable reason names the failing check');
  check(/lane_boundary_check_stderr:declared check refused/.test(blockedRow.reason || ''),'the durable reason keeps the failing check\'s own words');
  check(!blockedRow.receipt,'a blocked wave carries no completion receipt');
  check(fs.readFileSync(refusedExit.effects,'utf8').trim().split('\n').length===3,'all three ordered stages ran before the boundary judged the landing');

  // (e) THE SAME EXIT, PASSING: the wave completes and its receipt carries the boundary it passed.
  const passingExit=waveFixture('exit-passing');
  create(passingExit.store,passingExit.manifest);
  const completed=await advance(passingExit.store,'exit-passing');
  check(completed.ok===true,'a wave completes when both boundaries pass');
  check(completed.boundary.ok===true && completed.boundary.phase==='exit','the completion receipt carries the exit boundary verdict');
  const completedRow=inspect(passingExit.store,'exit-passing');
  check(completedRow.state==='complete','completion is durable');
  check(JSON.parse(completedRow.receipt).boundary.ok===true,'the durable receipt carries the exit boundary verdict too');

  // ---------------------------------------------------------------- retirement stays one command
  const scripts=fs.readdirSync('scripts');
  const retirementImplementations=scripts.filter(name=>/retire/i.test(name) && /\.(mjs|js|cjs|sh)$/.test(name) && !/^test-/.test(name));
  check(retirementImplementations.length===1 && retirementImplementations[0]==='wave-retire.mjs',
    `exactly one retirement implementation in scripts/ (found ${retirementImplementations.join(', ')})`);
  const remoteDeleters=[];
  for(const name of scripts.filter(name=>name.endsWith('.mjs') && !name.startsWith('test-'))) {
    const source=fs.readFileSync(path.join('scripts',name),'utf8');
    if(/'push',\s*'origin',\s*`:/.test(source) || /"push",\s*"origin",\s*`:/.test(source)) remoteDeleters.push(name);
  }
  check(remoteDeleters.length===1 && remoteDeleters[0]==='wave-retire.mjs',
    `the only non-test script that deletes a remote ref is the retirement engine (found ${remoteDeleters.join(', ')})`);
  const retireSource=fs.readFileSync('scripts/wave-retire.mjs','utf8');
  check(/usage: guard PLAN \| apply PLAN/.test(retireSource),'the retirement engine exposes one plan-driven command');
  check(!/^import .*retire/m.test(retireSource),'the retirement engine imports no second retirement implementation');

  succeeded=true;
  console.log(`lane boundary ok (${checks} checks; absent policy adds no requirement and runs nothing, a declared one is refused by name with the failing check's own words, both entrypoints are exercised end to end - refused entry, admitted entry, bootstrap exemption, blocked exit, completed exit - the detector is not re-derived, retirement stays one command)`);
} finally {
  for(const root of roots) {
    if(succeeded) fs.rmSync(root,{recursive:true,force:true});
    else console.error(`lane boundary fixtures retained: ${root}`);
  }
}
