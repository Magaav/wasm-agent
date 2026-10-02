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
//   * The wiring is in the two entrypoints the wave already has: `scripts/wave-lifecycle.mjs` create (the
//     next wave's entry) and its completion check (the landing's exit).
//   * Retirement stays ONE command: the only non-test script in `scripts/` that deletes a remote ref is
//     `scripts/wave-retire.mjs`, and there is no second retirement implementation beside it.
//
// Hermetic: one private Git repository with a local bare remote per case, no network, no model, no sentinel.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {boundary,readPolicy,detectorArgs,detectorFacts,BOUNDARY_PHASES} from './lib/lane-boundary.mjs';

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

  // ---------------------------------------------------------------- the two entrypoints are wired
  const lifecycle=fs.readFileSync('scripts/wave-lifecycle.mjs','utf8');
  const createBody=lifecycle.slice(lifecycle.indexOf('export function create'),lifecycle.indexOf('export async function advance'));
  const advanceBody=lifecycle.slice(lifecycle.indexOf('export async function advance'),lifecycle.indexOf('export function reconcile'));
  check(createBody.includes("boundary(manifest.repo,{phase:'enter'})"),"create() runs the boundary as the next wave's entry");
  check(createBody.includes('lane_boundary_enter_refused:'),'a refused entry is named, not silently admitted');
  check(advanceBody.includes("boundary(manifest.repo,{phase:'exit'})"),"the completion check runs the boundary as the landing's exit");
  check(advanceBody.includes('lane_boundary_exit_refused:'),'a refused exit blocks the wave by name');
  check(/convergence_failed:\$\{e\.message\}/.test(advanceBody),'the exit refusal blocks durably through the existing block path');

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
  console.log(`lane boundary ok (${checks} checks; absent policy adds no requirement and runs nothing, a declared one is refused by name, the detector is not re-derived, both entrypoints are wired, retirement stays one command)`);
} finally {
  for(const root of roots) {
    if(succeeded) fs.rmSync(root,{recursive:true,force:true});
    else console.error(`lane boundary fixtures retained: ${root}`);
  }
}
