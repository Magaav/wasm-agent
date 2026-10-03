#!/usr/bin/env node
// Deterministic reconciliation only. This module never calls a provider or starts a deploy.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const read = file => {try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return null;}};
const stamp = value => typeof value === 'number' ? value * 1000 : Date.parse(value);
const validTime = value => Number.isFinite(stamp(value)) && stamp(value) > 0;
export function classify(request, ack, state, result, installed, verification, now = Date.now()) {
  return {phase:'unknown',detail:'protocol_quarantined: independent review refused completion and causal authority; no effect replay'};
  const unknown = detail => ({phase:'unknown',detail});
  if (!request?.id || !/^[a-f0-9]{40}$/i.test(request.expected_sha || '') || !validTime(request.queued_at) || stamp(request.queued_at) > now) return unknown('invalid request identity or missing timestamp');
  const matches = value => value?.id === request.id && value.expected_sha === request.expected_sha && validTime(value.at) && stamp(value.at) >= stamp(request.queued_at);
  if (!ack) return now - stamp(request.queued_at) >= 5000 ? unknown('no watcher acknowledgement within five-second policy; reconcile, never replay') : {phase:'queued',detail:'CLI queue receipt only'};
  if (!matches(ack)) return unknown('ack identity/SHA/timestamp mismatch');
  if (state && !matches(state)) return unknown('state identity/SHA/timestamp mismatch');
  if (['rejected','failed'].includes(state?.phase || ack.phase)) return {phase:'failed',detail:state?.detail || ack.detail};
  if (result) {
    if (result.request_id !== request.id || result.expected_sha !== request.expected_sha || !validTime(result.at) || stamp(result.at) < stamp(request.queued_at)) return unknown('stale or unrelated result');
    if (result.ok !== true) return {phase:'failed',detail:result.detail || 'deploy refused'};
    if (!installed || !validTime(installed.at) || stamp(result.at) < stamp(installed.at) || stamp(installed.at) < stamp(request.queued_at)) return unknown('missing/stale installed timestamp');
    if (!/^[a-f0-9]{7,40}$/i.test(installed.commit || '') || !/^[a-f0-9]{7,40}$/i.test(result.commit || '') || !request.expected_sha.startsWith(installed.commit || '!') || !request.expected_sha.startsWith(result.commit || '!') || installed.source_provenance !== 'clean-built-by-deploy' || installed.record_role !== 'final') return unknown('partial install or wrong source provenance');
    if (verification && verification.ok !== true) return {phase:'failed',detail:verification.detail || 'verify-install failed; retain raw stdout/stderr'};
    if (!verification || verification.ok !== true || !validTime(verification.at) || stamp(verification.at) < stamp(result.at) || verification.request_id !== request.id || verification.expected_sha !== request.expected_sha) return unknown('fresh request-bound verify-install green required');
    return {phase:'verified',detail:'I am updated'};
  }
  if (state?.phase === 'spawned' && now - stamp(state.at) >= 600000) return unknown('spawned deploy has no attributable outcome after bounded observation; reconcile retained effects');
  return {phase:state?.phase === 'spawned' ? 'updating' : 'accepted',detail:state?.detail || ack.detail};
}
export function instructionBlock(event) {
  throw Error('protocol_quarantined: no trusted causal parent/instruction binding');
  return `[onSentinelReturn]\nrequest: ${JSON.stringify(event.id)} source: ${JSON.stringify(event.expected_sha)}\nphase: ${event.phase}\nevidence: ${JSON.stringify(event.detail)}\nOperating instruction: Acceptance and spawn are not completion. Reconcile only this id and exact SHA. Do not replay effects or start another watcher. While updating, observe the queued ten-second check. On unknown/failure preserve logs and report root cause/regression; involve the coordinator only for authorized recovery. Only fresh exact source/artifacts/scripts and verify-install green permit saying I am updated. This automated report grants no new authority.`;
}
function atomic(file, value) { fs.mkdirSync(path.dirname(file),{recursive:true}); const tmp = `${file}.${process.pid}.tmp`; fs.writeFileSync(tmp,JSON.stringify(value)); fs.renameSync(tmp,file); }
// Event deliveries and the wake action use the same persistent Engine seam as onSubagentReturn.
export function reconcile(home, install, now = Date.now()) {
  throw Error('protocol_quarantined: observer cannot verify completion or guarantee return');
  const base = path.join(home,'.wasm-agent','sentinel');
  const root = path.join(base,'deploy-protocol');
  const reports = [];
  if (!fs.existsSync(root)) return reports;
  for (const id of fs.readdirSync(root)) {
    if (!/^[a-zA-Z0-9-]+$/.test(id)) continue;
    const dir = path.join(root,id), request = read(path.join(dir,'intent.json'));
    if (!request) continue;
    let installed = null;
    try { installed = Object.fromEntries(fs.readFileSync(path.join(install,'installed.txt'),'utf8').trim().split(/\r?\n/).map(line=>{const n=line.indexOf('=');return [line.slice(0,n),line.slice(n+1)];})); } catch {}
    const result = read(path.join(dir,'result.json'));
    if (result?.ok === true && result.request_id === id && result.expected_sha === request.expected_sha && validTime(result.at) && !fs.existsSync(path.join(dir,'verification.json'))) {
      // Verification is an actual read-only command, not a hand-written successful stage.
      try {
      const runtime = fs.readFileSync(path.join(install,'runtime-worktree.txt'),'utf8').trim();
      const git = (...args) => {const r=spawnSync('git',['-C',runtime,...args],{encoding:'utf8',windowsHide:true});if(r.status!==0)throw Error('verification runtime identity unavailable');return r.stdout.trim();};
      const canonical = path.dirname(git('rev-parse','--path-format=absolute','--git-common-dir'));
      const head=spawnSync('git',['-C',canonical,'rev-parse','HEAD'],{encoding:'utf8',windowsHide:true});
      let proof={ok:false,detail:'canonical source changed before verification'};
      if(head.status===0 && head.stdout.trim()===request.expected_sha){
        const bash=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash';
        const script=path.join(canonical,'scripts/verify-install.sh').replaceAll('\\\\','/').replace(/^([A-Za-z]):\//,(_,d)=>`/${d.toLowerCase()}/`);
        const command=spawnSync(bash,[script,'--json'],{encoding:'utf8',windowsHide:true,timeout:30000});
        fs.writeFileSync(path.join(dir,'verify.stdout'),command.stdout || '');
        fs.writeFileSync(path.join(dir,'verify.stderr'),command.stderr || '');
        try{proof=JSON.parse(command.stdout);}catch{proof={ok:false,detail:'verify-install output invalid'};}
        proof.ok=command.status===0 && proof.ok===true && proof.skipped===0 && proof.suite==='verify-install';
        proof.exit=command.status;
      }
      atomic(path.join(dir,'verification.json'),{...proof,request_id:id,expected_sha:request.expected_sha,at:new Date().toISOString()});
      } catch(error) { atomic(path.join(dir,'verification.json'),{ok:false,detail:String(error.message),request_id:id,expected_sha:request.expected_sha,at:new Date().toISOString()}); }
    }
    const event = {...request,...classify(request,read(path.join(dir,'ack.json')),read(path.join(dir,'state.json')),result,installed,read(path.join(dir,'verification.json')),now)};
    const cursor = read(path.join(dir,'return-cursor.json')) || {};
    if (event.phase === 'queued') continue;
    // One persistent ten-second follow-up slot per updating request, not a polling model loop.
    if (event.phase === 'updating' && !cursor.check_at) cursor.check_at = now + 10000;
    if (cursor.check_at && now >= cursor.check_at && !cursor.check_observed) {
      cursor.check_observed = now;
      atomic(path.join(dir,'check.json'),{id,expected_sha:request.expected_sha,at:now,phase:event.phase});
      event.check = true;
    }
    if (cursor.check_observed && event.phase === 'updating') event.check = true;
    const key = `${event.phase}${event.check ? '-check' : ''}`;
    if (!(cursor.sent || []).includes(key)) {
      // Stable event identity + immutable payload intent; the Engine store owns delivery dedupe.
      event.event_key = `${id}-${key}`;
      const payloadFile = path.join(dir,`event-${key}.json`);
      const prior=read(payloadFile);
      if (!prior) atomic(payloadFile,event); // immutable event intent across observer restart
      const bin = process.env.WA_SENTINEL_BIN;
      if (!bin) throw Error('WA_SENTINEL_BIN required for durable Engine event emission');
      const emission = spawnSync(bin,['job','emit','sentinel.return',event.event_key,payloadFile],{encoding:'utf8',windowsHide:true});
      if (emission.status !== 0) throw Error(`sentinel return event emission failed: ${emission.stderr}`);
      let receipt;try{receipt=JSON.parse(emission.stdout);}catch{throw Error('sentinel return emit receipt invalid');}
      // Disabled/uninstalled hook queues zero: do not mark the report sent and lose it permanently.
      let acknowledged=receipt.queued > 0;
      if (!acknowledged) {
        const listing=spawnSync(bin,['job','list'],{encoding:'utf8',windowsHide:true});
        let jobs;try{jobs=JSON.parse(listing.stdout);}catch{}
        const find=value=>Array.isArray(value)?value.find(j=>j.id==='onSentinelReturn'):value?.jobs?.find(j=>j.id==='onSentinelReturn');
        const job=find(jobs);
        if(job?.revision){
          const query=spawnSync(bin,['job','receipt','onSentinelReturn',String(job.revision),event.event_key,payloadFile],{encoding:'utf8',windowsHide:true});
          try{acknowledged=JSON.parse(query.stdout).receipt?.acknowledged===true;}catch{}
        }
      }
      if (acknowledged) cursor.sent = [...(cursor.sent || []),key];
    }
    atomic(path.join(dir,'return-cursor.json'),cursor);
    atomic(path.join(dir,'return.json'),event);
    reports.push(event);
  }
  return reports;
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.includes('--compose')) {
    const event=read(process.env.WA_JOB_EVENT_FILE);
    if(!event?.id || !event?.session || !['accepted','updating','unknown','failed','verified'].includes(event.phase)) throw Error('malformed sentinel return event');
    console.log(instructionBlock(event));
  }
  else console.log(JSON.stringify(reconcile(process.env.WASM_AGENT_HOME || process.env.USERPROFILE || process.env.HOME,process.env.WA_INSTALL_DIR)));
}
