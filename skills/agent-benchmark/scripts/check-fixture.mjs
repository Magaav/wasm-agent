#!/usr/bin/env node
// Model-free scorer preflight for the proposed small telemetry repair.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';

const [repoArg,scratch]=process.argv.slice(2);
if(!repoArg || !scratch || !path.isAbsolute(repoArg) || !path.isAbsolute(scratch))
  throw Error('pass absolute source repo and evidence scratch directories');
const repo=fs.realpathSync(repoArg);
function run(exe,args,cwd=repo) {
  const r=spawnSync(exe,args,{cwd,encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:1024*1024});
  if(r.error) throw r.error;
  return r;
}
const fixture=JSON.parse(fs.readFileSync(path.join(repo,'benchmarks/agent-benchmark/telemetry-empty-payload.json'),'utf8'));
assert.equal(fixture.status,'candidate-awaiting-pi-qualification');
const base=run('git',['rev-parse',fixture.taskSource+'^{commit}']);assert.equal(base.status,0,base.stderr);
const root=fs.mkdtempSync(path.join(scratch,'telemetry-oracle-check-'));
const file='scripts/lib/token-audit.cjs',oracle=path.join(repo,'benchmarks/agent-benchmark',fixture.oracle);
try {
  for(const file of fixture.sourcePaths) {
    const original=run('git',['show',base.stdout.trim()+':'+file]);assert.equal(original.status,0,original.stderr);
    const dest=path.join(root,file);fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,original.stdout);
  }
  const bad=run(process.execPath,[oracle,root]);assert.equal(bad.status,1);assert.equal(JSON.parse(bad.stdout).pass,false);
  const target=path.join(root,file),old=fs.readFileSync(target,'utf8');
  const anchor="    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw Error('invalid_event_payload');";
  assert.equal(old.split(anchor).length,2);
  fs.writeFileSync(target,old.replace(anchor,"    if (Array.isArray(payload) && payload.length === 0) payload = {};\n"+anchor));
  const good=run(process.execPath,[oracle,root]);assert.equal(good.status,0,good.stdout+good.stderr);
  assert.equal(JSON.parse(good.stdout).pass,true);
  fs.writeFileSync(target,old.replace(anchor,"    if (Array.isArray(payload)) payload = {};\n"+anchor));
  const lax=run(process.execPath,[oracle,root]);assert.equal(lax.status,1);assert.equal(JSON.parse(lax.stdout).pass,false);
  const current=run(process.execPath,[oracle,repo]);assert.equal(current.status,0,current.stdout+current.stderr);
  console.log(JSON.stringify({ok:true,task_source:base.stdout.trim(),candidate_status:fixture.status,
    baseline_fails:true,known_repair_passes:true,accept_all_arrays_mutant_fails:true,current_source_passes:true,
    oracle_checks:JSON.parse(good.stdout).checks,pi_qualified:false,paid_calls:0,no_agent_executed:true,
    oracle_sha256:crypto.createHash('sha256').update(fs.readFileSync(oracle)).digest('hex')}));
} finally {fs.rmSync(root,{recursive:true,force:true});}
