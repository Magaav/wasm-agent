#!/usr/bin/env node
// The lane boundary: ONE deterministic detector, run at a landing's exit and the next wave's entry.
//
// WHAT THIS IS. A wave has two boundaries - the exit of the landing that ends it, and the entry of the
// wave that follows - and both ask the same question: *is this repository in an ended state?* That
// question has one implementation in this project, `skills/git-orchestrator/scripts/audit.mjs verify
// <repo> origin/main`, which exits 0 only when every in-scope tip is integrated into the target, origin
// carries only `main`, and origin/main *is* the target. This module does not re-derive any of those
// checks: it runs the declared command, parses the audit's own JSON, and reports the facts by name. The
// wiring into the entrypoints is `scripts/wave-lifecycle.mjs` (create = the next wave's entry, the
// completion check = the landing's exit).
//
// WHAT A REPOSITORY DECLARES, AND WHAT AN ABSENT FILE MEANS. The requirement is the *repository's*, in
// `lane-policy.json` at its root: `contract`, `end_state`, `gate.on`, `deploy.when`, `checks.enter` and
// `checks.exit`. A repository that does not declare the file gets NO extra requirement from this module
// (`policy_present:false`, `requirements:[]`, nothing spawned) - that is a property with a test, not a
// sentence (`scripts/test-lane-boundary.mjs`, "an absent policy adds no requirement"). Fixture
// repositories, other projects and one-off lanes stay free, and a repository that wants the boundary
// enforced says so in a file that is versioned with the code it governs.
//
// WHY THE DETECTOR IS REQUIRED IN BOTH PHASES when a policy IS declared. Otherwise a repository could
// declare a boundary made only of checks it wrote itself, and "the same detector at both boundaries"
// would become a claim about a file rather than a property of the run. `lane_policy_invalid:checks.<phase>`
// names that refusal.
//
// Usage (the command form exists so an operator or a finisher can ask the same question without a module
// import; there is deliberately no second implementation behind it):
//   node scripts/lib/lane-boundary.mjs <repo> <enter|exit>
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath,pathToFileURL} from 'node:url';

export const BOUNDARY_PHASES=['enter','exit'];
const POLICY_FILE='lane-policy.json';

const isArgv=value=>Array.isArray(value) && value.length>0 && value.every(item=>typeof item==='string' && item.length>0);
const isCheckList=value=>Array.isArray(value) && value.length>0 && value.every(isArgv);

// A declared check IS the deterministic detector when it invokes the audit script's `verify` verb. The
// recognition is deliberately narrow: it does not follow shell wrappers, and a repository that hides the
// detector behind one gets a refusal rather than a guess.
export function detectorArgs(argv) {
  if(!isArgv(argv)) return false;
  return argv.includes('verify') && argv.some(item=>/(^|[\\/])audit\.mjs$/.test(item));
}

// Read and validate the repository's own declaration. Never throws: a malformed file is a named refusal,
// because a boundary that cannot be read must look like neither a pass nor a silence.
export function readPolicy(repo) {
  const file=path.join(path.resolve(repo),POLICY_FILE);
  if(!fs.existsSync(file)) return {present:false,file,policy:null,reasons:[]};
  let policy;
  try { policy=JSON.parse(fs.readFileSync(file,'utf8')); }
  catch(error) { return {present:true,file,policy:null,reasons:[`lane_policy_unreadable:${error.message}`]}; }
  const reasons=[];
  if(policy?.schema!==1) reasons.push('lane_policy_invalid:schema');
  if(typeof policy?.contract!=='string' || !policy.contract.trim()) reasons.push('lane_policy_invalid:contract');
  if(typeof policy?.end_state?.statement!=='string' || !policy.end_state.statement.trim()) reasons.push('lane_policy_invalid:end_state.statement');
  // The full gate is a RELEASE's, not a landing's (2026-10-02: `merge-lane.mjs` defaults to
  // `--gate-mode none`, and `wave-release.mjs` is what gates a tree and names it). A policy that says
  // otherwise is refused rather than reinterpreted.
  if(policy?.gate?.on!=='release') reasons.push('lane_policy_invalid:gate.on');
  if(typeof policy?.deploy?.when!=='string' || !policy.deploy.when.trim()) reasons.push('lane_policy_invalid:deploy.when');
  for(const phase of BOUNDARY_PHASES) {
    const checks=policy?.checks?.[phase];
    if(!isCheckList(checks)) { reasons.push(`lane_policy_invalid:checks.${phase}`); continue; }
    if(!checks.some(detectorArgs)) reasons.push(`lane_policy_invalid:checks.${phase}:audit_verify_required`);
  }
  return {present:true,file,policy,reasons};
}

// The facts behind the detector's exit code, named. `audit.mjs` reports `integration_complete`,
// `origin_main_only` and `origin_main_matches_target` separately, so a refusal says which fact failed
// instead of only quoting an exit status.
export function detectorFacts(stdout) {
  let report;
  try { report=JSON.parse(String(stdout)); }
  catch { return {parsed:false,missing:['detector_report_unparseable'],reason:'lane_boundary_detector_report_unparseable'}; }
  const facts={
    discovery_complete:report.discovery_complete===true,
    integration_complete:report.integration_complete===true,
    origin_main_only:report.origin_main_only===true,
    origin_main_matches_target:report.origin_main_matches_target===true,
    pending_tips:Number.isSafeInteger(report.pending_tips)?report.pending_tips:null,
    origin_heads:Array.isArray(report.origin_heads)?report.origin_heads:null,
    target:report.target,
    target_sha:report.target_sha,
    errors:Array.isArray(report.errors)?report.errors:[],
  };
  const missing=[];
  if(!facts.discovery_complete) missing.push('discovery_incomplete');
  if(!facts.integration_complete) missing.push('integration_incomplete');
  if(!facts.origin_main_only) missing.push('origin_not_main_only');
  if(!facts.origin_main_matches_target) missing.push('origin_main_is_not_the_target');
  return {parsed:true,facts,missing,reason:missing.length?`lane_boundary_detector:${missing.join(',')}`:null};
}

function run(argv,repo,{timeoutMs}) {
  const result=spawnSync(argv[0],argv.slice(1),{cwd:repo,encoding:'utf8',windowsHide:true,timeout:timeoutMs,maxBuffer:32*1024*1024});
  return {argv,exit:result.status,stdout:result.stdout || '',stderr:result.error?.message || result.stderr || ''};
}

/**
 * The boundary verdict for one phase. Never throws on a repository problem: it returns `ok:false` with
 * named reasons, so a caller can record the refusal instead of losing it to a stack trace.
 */
export function boundary(repo,{phase,timeoutMs=900000}={}) {
  const absolute=path.resolve(repo);
  if(!BOUNDARY_PHASES.includes(phase)) return {ok:false,schema:1,phase:String(phase),repo:absolute,
    reasons:[`lane_boundary_phase_required:${BOUNDARY_PHASES.join('|')}`]};
  const declared=readPolicy(absolute);
  if(!declared.present) {
    return {ok:true,schema:1,phase,repo:absolute,policy_present:false,policy_file:declared.file,requirements:[],detections:[],
      note:'no lane-policy.json in this repository: the boundary adds no requirement of its own (an absent file means no extra requirements)'};
  }
  if(declared.reasons.length) return {ok:false,schema:1,phase,repo:absolute,policy_present:true,policy_file:declared.file,
    reasons:declared.reasons,requirements:[]};
  const checks=declared.policy.checks[phase];
  const detections=[];
  for(const argv of checks) {
    const result=run(argv,absolute,{timeoutMs});
    const detection=detectorArgs(argv)?detectorFacts(result.stdout):null;
    detections.push({argv,exit:result.exit,detector:Boolean(detection),missing:detection?.missing ?? null,
      stdout_bytes:Buffer.byteLength(result.stdout,'utf8'),stderr:result.exit===0?'':String(result.stderr).slice(0,4000)});
    if(result.exit!==0) {
      const reasons=[`lane_boundary_check_failed:${phase}:${argv.join(' ')}`];
      if(detection?.reason) reasons.push(detection.reason);
      return {ok:false,schema:1,phase,repo:absolute,policy_present:true,policy_file:declared.file,checks:[...detections],
        reasons,detections,note:declared.policy.contract};
    }
  }
  return {ok:true,schema:1,phase,repo:absolute,policy_present:true,policy_file:declared.file,checks:detections,detections,
    end_state:declared.policy.end_state,gate:declared.policy.gate,deploy:declared.policy.deploy,remote:declared.policy.remote ?? null,
    note:declared.policy.contract};
}

/** Throw the named refusal. Callers that must record it use `boundary()` directly. */
export function assertBoundary(repo,{phase,timeoutMs}={}) {
  const verdict=boundary(repo,{phase,timeoutMs});
  if(!verdict.ok) throw Error(`lane_boundary_refused:${verdict.reasons.join('|')}`);
  return verdict;
}

if(process.argv[1] && import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href) {
  const [repo,phase]=process.argv.slice(2);
  const verdict=boundary(repo ?? '.',{phase});
  process.stdout.write(`${JSON.stringify(verdict,null,2)}\n`);
  process.exitCode=verdict.ok?0:1;
}
