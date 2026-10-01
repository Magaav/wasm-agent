import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const runner=path.resolve('skills/parallel-evolution/scripts/finish.mjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-finish checks '));
// A stand-in gate has no production reservation to inherit. Fence the queue as
// well as Git, even when invoked directly by a measurement or review test.sh.
const fixtureEnv={...process.env,WA_GATE_LANE_DIR:path.join(root,'gate-lane'),
  GATE_LANE_HELD:'',GATE_LANE_ORIGIN:'',WA_GATE_LANE_WAIT_SECONDS:'15',WA_GATE_LANE_SAMPLE_SECONDS:'0'};
const repo=path.join(root,'lane'),remote=path.join(root,'origin.git');
let checks=0;
function run(program,args,cwd=repo) {
  const r=spawnSync(program,args,{cwd,encoding:'utf8',windowsHide:true,env:fixtureEnv,timeout:60000});
  assert.equal(r.status,0,r.stderr || r.stdout); return r.stdout.trim();
}
const git=(...args)=>run('git',args);
const head=()=>git('rev-parse','HEAD');
const check=(condition,label)=>{assert.ok(condition,label);checks++;};
const finish=(mode,revision=head())=>JSON.parse(run(process.execPath,[runner,mode,repo,revision]));
try {
  fs.mkdirSync(repo);fs.mkdirSync(path.join(repo,'scripts'));
  fs.copyFileSync('scripts/gate-lane.mjs',path.join(repo,'scripts/gate-lane.mjs'));
  run('git',['init','--bare','-q',remote],root);
  git('init','-q','--initial-branch','main');git('config','user.name','fixture');git('config','user.email','fixture@local');
  fs.writeFileSync(path.join(repo,'scripts/test.sh'),"printf 'smoke ok (1 skipped)\\n'\n");
  git('add','.');git('commit','-qm','fixture');git('remote','add','origin',remote);git('push','-q','-u','origin','main');
  git('switch','-qc','lane');
  check(!finish('check').repository_ready,'a branch tracking main is not its own published branch');
  git('push','-q','-u','origin','lane');
  git('update-ref','refs/remotes/origin/draft',head());
  check(finish('check').repository_ready,'a clean published current branch merges');
  check(git('show-ref','--verify','--hash','refs/remotes/origin/draft')===head(),'refresh preserves stale local draft refs instead of pruning them');
  fs.writeFileSync(path.join(repo,'untracked'),'unfinished');
  check(!finish('check').repository_ready,'untracked work blocks completion');fs.unlinkSync(path.join(repo,'untracked'));
  check(!finish('check','0'.repeat(40)).repository_ready,'a moved or incorrect HEAD blocks completion');
  check(!finish('verify').gate_verified,'missing gate evidence is not a pass');
  const passed=finish('gate');check(passed.gate_verified && passed.skipped===1,'real command exit, verdict and skip count are recorded');
  check(Number.isFinite(passed.gate_ms) && passed.gate_ms>=0 && passed.gate_runs===1 && passed.gate_run_count===1,'the gate reports measured duration and one actual run');
  const auditScript=path.resolve('skills/git-orchestrator/scripts/audit.mjs');
  const auditSource=fs.readFileSync(auditScript,'utf8').replace('listPRs=githubPRs','listPRs=()=>[]');
  const fixtureAudit=path.join(root,'audit-fixture.mjs');fs.writeFileSync(fixtureAudit,auditSource);
  const audited=JSON.parse(run(process.execPath,[fixtureAudit,'audit',repo,'origin/main']));
  check(audited.gate_proof.status==='verified'&&audited.gate_proof.gate_ms===passed.gate_ms&&audited.counts.gate_run_count===0,'integration audit exposes reusable source-bound gate proof');
  const auditVerified=spawnSync(process.execPath,[fixtureAudit,'verify',repo,'origin/main'],{cwd:process.cwd(),encoding:'utf8',windowsHide:true});
  const verifyResult=JSON.parse(auditVerified.stdout);
  check(auditVerified.status===1&&verifyResult.source_gate_verified===true&&verifyResult.verification_complete===false,
    'verify recognizes exact-tree gate proof but still requires the main-only remote invariant');
  check(finish('verify').gate_verified,'passing evidence is readable and matches source');
  const reused=finish('gate');
  check(reused.gate_reused===true&&reused.gate_run_count===0&&reused.gate_ms===passed.gate_ms,'identical source reuses source-bound proof and reports zero gate reruns');
  const proof=JSON.parse(fs.readFileSync(path.join(repo,'.git/wa-finish-gate.json'),'utf8'));
  fs.appendFileSync(proof.log,'tampered');
  check(!finish('verify').gate_verified,'modified evidence fails verification');
  proof.gate_ms=undefined;
  fs.writeFileSync(path.join(repo,'.git/wa-finish-gate.json'),JSON.stringify(proof));
  check(!finish('verify').gate_verified,'legacy receipt without duration cannot claim measurement');
  proof.gate_ms=passed.gate_ms;proof.gate_exit=1;
  fs.writeFileSync(path.join(repo,'.git/wa-finish-gate.json'),JSON.stringify(proof));
  check(!finish('verify').gate_verified,'a passing receipt cannot hide a nonzero recorded gate exit');
  proof.gate_exit=0;proof.log_sha256='';
  fs.writeFileSync(path.join(repo,'.git/wa-finish-gate.json'),JSON.stringify(proof));
  const invalidProofAudit=spawnSync(process.execPath,[fixtureAudit,'audit',repo,'origin/main'],{cwd:process.cwd(),encoding:'utf8',windowsHide:true});
  check(JSON.parse(invalidProofAudit.stdout).gate_proof.status==='stale_or_invalid','integration audit refuses a modified source-bound gate receipt');
  check(finish('gate').gate_verified,'a verified rerun repairs evidence');
  git('commit','--allow-empty','-qm','same source, new metadata');
  check(!finish('check').repository_ready,'an unpushed commit blocks completion');
  git('push','-q');
  check(finish('verify').gate_verified,'an identical Git tree preserves test evidence across commit metadata changes');
  fs.writeFileSync(path.join(repo,'changed'),'new source');git('add','.');git('commit','-qm','new source');git('push','-q');
  check(!finish('verify').gate_verified,'changed source invalidates passing evidence');
  check(finish('gate').gate_verified,'new source requires a new verified gate');
  fs.writeFileSync(path.join(repo,'scripts/test.sh'),"printf 'smoke ok\\n'\nexit 3\n");
  git('add','.');git('commit','-qm','failing gate');git('push','-q');
  check(!finish('gate').gate_verified,'a printed passing verdict cannot hide nonzero exit');
  check(!fs.existsSync(path.join(repo,'.git/wa-finish-gate.json')),'failed rerun leaves no stale passing receipt');
  check(!finish('verify').gate_verified,'failed gate remains visibly unverified');
  git('switch','-q','main');fs.writeFileSync(path.join(repo,'main-change'),'incoming');git('add','.');git('commit','-qm','incoming');git('push','-q');
  git('switch','-q','lane');
  check(!finish('check').repository_ready,'a branch behind freshly fetched main cannot finish');
  const definition=finish('spell');
  check(definition.spells.length===2 && definition.composition.parts.length===2,'ready and gate compose into a closing spell');
  console.log(`parallel finish checks ok (${checks} checks, 0 skipped)`);
} finally {
  assert.equal(path.dirname(path.resolve(root)),path.resolve(os.tmpdir()));
  assert.ok(path.basename(root).startsWith('wa-finish checks '));
  fs.rmSync(root,{recursive:true,force:true});
}
