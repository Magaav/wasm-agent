// Remove the suspect return only in an isolated UI copy to test causality, not to propose a repair.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'../..'),binary=path.resolve(process.argv[2]);
const stage=fs.mkdtempSync(path.join(os.tmpdir(),'wa-review-fallback-'));
fs.cpSync(path.join(repo,'ui'),stage,{recursive:true});
const file=path.join(stage,'app.js'),text=fs.readFileSync(file,'utf8');
const guard="    if(!attached && pane.liveJournalAttached && pane.painted && journalError) {\n      pane.notice.textContent=journalError;\n      return;\n    }";
assert.ok(text.includes(guard));fs.writeFileSync(file,text.replace(guard,''));
try {
 const run=spawnSync(process.execPath,['review/original-native-ui/adversarial.cjs',binary,'--ui-root',stage],{cwd:repo,encoding:'utf8',windowsHide:true,timeout:180000,maxBuffer:16000000});
 const output=(run.stdout||'')+(run.stderr||'');fs.writeFileSync(path.join(__dirname,'fallback-causality.log'),output);
 assert.equal(run.status,0,output);
 const receipt=output.match(/evidence: ([^\r\n]+)/);assert.ok(receipt);
 const proof=JSON.parse(fs.readFileSync(receipt[1]));
 assert.ok(proof.review.fallback.pane.terminal,'removing only the return exposes the actual terminal ledger');
 assert.equal(proof.review.fallback.mainAfter,false,'main fallback defect remains independently present');
 assert.ok(proof.cleanup.fixture_home_removed&&proof.cleanup.ownedPids.every(p=>p.exited&&p.job.no_breakaway&&p.job.drained&&p.job.accounting.active_processes===0));
 fs.writeFileSync(path.join(__dirname,'fallback-causality.json'),JSON.stringify({receipt:receipt[1],exit:run.status,removed:'already-attached journal-error return',paneTerminal:proof.review.fallback.pane.terminal,mainTerminal:proof.review.fallback.mainAfter,productBytesChanged:false},null,2)+'\n');
}finally{
 assert.ok(path.resolve(stage).startsWith(path.resolve(os.tmpdir())+path.sep)&&path.basename(stage).startsWith('wa-review-fallback-'));fs.rmSync(stage,{recursive:true,force:true});
}
