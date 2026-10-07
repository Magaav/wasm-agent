// Collect a native Node test run, not a guessed terminal format or reconstructed exit status.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export function tapSummary(stdout) {
  if (!/^TAP version 13\r?$/m.test(stdout) || !/^1\.\.\d+\r?$/m.test(stdout))
    throw Error('incomplete_or_non_tap_output');
  const summary={};
  for (const key of ['tests','pass','fail','cancelled','skipped','todo']) {
    const matches=[...stdout.matchAll(new RegExp('^# '+key+' (\\d+)\\r?$','gm'))];
    if (matches.length!==1) throw Error('missing_or_duplicate_tap_summary:'+key);
    summary[key]=Number(matches[0][1]);
    if (!Number.isSafeInteger(summary[key])) throw Error('invalid_tap_count:'+key);
  }
  if (summary.tests!==summary.pass+summary.fail+summary.cancelled+summary.skipped+summary.todo)
    throw Error('inconsistent_tap_counts');
  return summary;
}

export function runNodeTests({cwd,files,evidence,timeoutMs=60000}) {
  if (!cwd || !path.isAbsolute(cwd) || !evidence || !path.isAbsolute(evidence))
    throw Error('cwd_and_evidence_must_be_absolute');
  if (!Array.isArray(files) || !files.length || files.some(file=>typeof file!=='string'||!file))
    throw Error('explicit_test_files_required');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs<1 || timeoutMs>86400000)
    throw Error('invalid_timeout_ms');
  cwd=fs.realpathSync(cwd);
  // File selectors are not flags or shell globs. Resolve before launch; no arbitrary Node options.
  files=files.map(file=>fs.realpathSync(path.resolve(cwd,file)));
  if (files.some(file=>!fs.statSync(file).isFile())) throw Error('test_selector_must_be_a_file');
  fs.mkdirSync(evidence); // A fresh generation is mandatory; existing evidence is never overwritten.
  const args=['--test','--test-reporter=tap',...files];
  const started=new Date().toISOString();
  const result=spawnSync(process.execPath,args,{cwd,windowsHide:true,
    timeout:timeoutMs,maxBuffer:16*1024*1024});
  const stdout=result.stdout||Buffer.alloc(0),stderr=result.stderr||Buffer.alloc(0);
  fs.writeFileSync(path.join(evidence,'stdout.tap'),stdout,{flag:'wx'});
  fs.writeFileSync(path.join(evidence,'stderr.txt'),stderr,{flag:'wx'});
  let summary=null,summaryError=null;
  try {summary=tapSummary(stdout.toString('utf8'));} catch(error) {summaryError=error.message;}
  const completed=!result.error && result.signal===null && Number.isInteger(result.status);
  const ok=completed && result.status===0 && summary!==null && summary.tests>0 && summary.pass>0 && summary.fail===0 && summary.cancelled===0;
  const status=!ok ? 'failed_or_unverified' : summary.skipped || summary.todo ? 'passed_with_skips_or_todos' : 'passed';
  const sha=text=>crypto.createHash('sha256').update(text).digest('hex');
  const receipt={ok,status,reporter:'tap',started,at:new Date().toISOString(),cwd,
    executable:process.execPath,args,exit_code:result.status,signal:result.signal,
    process_completed:completed,process_error:result.error?.message||null,summary,summary_error:summaryError,
    evidence,stdout_sha256:sha(stdout),stderr_sha256:sha(stderr),full_release_gate:false};
  fs.writeFileSync(path.join(evidence,'receipt.json'),JSON.stringify(receipt,null,2)+'\n',{flag:'wx'});
  return receipt;
}

if (process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const [cwd,evidence,...files]=process.argv.slice(2);
    const receipt=runNodeTests({cwd,evidence,files});
    console.log(JSON.stringify(receipt));
    if (!receipt.ok) process.exitCode=1;
  } catch(error) {console.log(JSON.stringify({ok:false,error:error.message}));process.exitCode=1;}
}
